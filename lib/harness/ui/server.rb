# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "securerandom"
require "socket"
require_relative "http"
require_relative "lan"

module Harness
  module UI
    # The local app's server on TCPServer (DESIGN.md 11.3, I15): bound to 127.0.0.1; requests for another Host are
    # refused (DNS rebinding); every POST needs the per-start token and the app's own Origin; no CORS headers; a
    # strict CSP on every response. One thread per connection.
    #
    # LAN mode (Lan, only with `harness ui --lan`) adds a second listener on this computer's private network address.
    # A device there must pair with the code shown on the computer before it gets anything but the pairing page, then
    # it carries a session cookie as well as the token. It may chat and run builds, but never run model-server
    # commands, add projects or change settings: those POSTs are refused before the app sees them.
    class Server
      HOST = "127.0.0.1"
      CSP = "default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; connect-src 'self'; " \
            "img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
      SECURITY = { "Content-Security-Policy" => CSP, "X-Content-Type-Options" => "nosniff", "Referrer-Policy" => "no-referrer",
                   "X-Frame-Options" => "DENY", "Cross-Origin-Opener-Policy" => "same-origin",
                   "Cross-Origin-Resource-Policy" => "same-origin" }.freeze
      # What a paired LAN device may POST: chats, replies, builds, answers, notes, stop and resume, the demo.
      LAN_POST = [%r{\A/api/chats\z}, %r{\A/api/chats/[\w-]+/(?:rename|delete|model|send)\z}, %r{\A/api/streams/\h{16}/stop\z},
                  %r{\A/api/runs/[\w-]+/(?:answer|stop|note|resume)\z}, %r{\A/api/demo\z}].freeze
      # What a LAN device may not even read: model servers and their commands, settings, the setup check.
      LAN_GET_DENIED = %r{\A/api/(?:providers|settings|doctor|lan|previews)(?:/|\z)}
      # What an unpaired LAN device may load: the pairing page and what it needs.
      PAIRING_FILES = %w[/pair.js /app.css /theme.css /fonts/InterVariable.woff2 /fonts/InterVariable-Italic.woff2].freeze
      PUBLIC = File.expand_path("public", __dir__)

      attr_reader :port, :token, :lan

      # @param app [#call] Request -> Response
      # @param port [Integer] 0 picks a free port
      # @param token [String]
      # @param log [#call, nil] (message) for errors
      # @param lan [Lan, nil] LAN mode, off when nil; its port is ignored and the server's is used
      # @param listen_lan [Boolean] false skips opening the LAN socket (tests call respond directly)
      def initialize(app:, port: 4567, token: SecureRandom.hex(32), log: nil, lan: nil, listen_lan: true)
        @app = app
        @token = token
        @log = log
        @server = TCPServer.new(HOST, port)
        @port = @server.addr[1]
        @lan = lan && Lan.new(ip: lan.ip, port: @port)
        @lan_server = @lan && listen_lan ? TCPServer.new(@lan.ip, @port) : nil
        @threads = []
      end

      # @return [String] e.g. http://127.0.0.1:4567/
      def url = "http://#{HOST}:#{@port}/"

      # Serve until stop is called.
      # @return [void]
      def run
        @lan_loop = Thread.new { accept(@lan_server, :lan) } if @lan_server
        accept(@server, :local)
      end

      # @return [Thread] the accept loop, running in the background
      def start
        @loop = Thread.new { run }
      end

      # @return [void]
      def stop
        @server.close unless @server.closed?
        stop_lan
        @loop&.join(2)
        @threads.each { |t| t.kill if t.alive? }
      end

      # The I15 checks, then the app.
      # @param request [Request]
      # @param via [Symbol] :local (127.0.0.1) or :lan
      # @return [Response]
      def respond(request, via: :local)
        return lan_respond(request) if via == :lan
        return Response.error(421, "unknown host") unless allowed_host?(request.headers["host"])
        return Response.error(405, "method not allowed") unless %w[GET POST].include?(request.method)

        if request.method == "POST"
          return Response.error(403, "missing or wrong token") unless token_ok?(request.headers["x-harness-token"])
          return Response.error(403, "cross-origin request") unless allowed_origin?(request.headers["origin"])
          return Response.error(400, "expected a JSON body") unless request.headers["content-type"].to_s.start_with?("application/json")
        end
        lan_route(request) || @app.call(request)
      end

      private

      def accept(socket, via)
        loop do
          client = socket.accept
          @threads.select!(&:alive?)
          @threads << Thread.new(client) { |c| handle(c, via) }
        rescue IOError, SystemCallError
          break if socket.closed?
        end
      end

      def handle(client, via)
        response = begin
          respond(HTTP.read(client), via: via)
        rescue HTTP::BadRequest => e
          Response.error(e.status, e.message)
        rescue StandardError => e
          @log&.call("ui: #{e.class}: #{e.message}")
          Response.error(500, "internal error")
        end
        HTTP.write(client, response, SECURITY)
      ensure
        client.close unless client.closed?
      end

      # The computer's own LAN controls: its banner (GET /api/lan), a new code, stop sharing. Never reachable from
      # the LAN; the caller has already checked Host, token and Origin.
      # @return [Response, nil] nil when the request is not one of them
      def lan_route(request)
        case [request.method, request.path]
        when ["GET", "/api/lan"] then Response.json(@lan ? @lan.to_json_hash : { "on" => false })
        when ["POST", "/api/lan/code"]
          return Response.error(409, "LAN mode is off") unless @lan&.on?

          @lan.new_code
          Response.json(@lan.to_json_hash)
        when ["POST", "/api/lan/stop"]
          stop_lan
          Response.json({ "on" => false })
        end
      end

      # A request that came in on the LAN address.
      # @return [Response]
      def lan_respond(request)
        return Response.error(403, "LAN mode is off") unless @lan&.on?
        return Response.error(421, "unknown host") unless request.headers["host"].to_s.downcase == "#{@lan.ip}:#{@port}"
        return Response.error(405, "method not allowed") unless %w[GET POST].include?(request.method)
        return pair(request) if request.method == "POST" && request.path == "/api/lan/pair"

        paired = @lan.paired?(request.headers["cookie"])
        if request.method == "GET"
          return pairing_page if !paired && request.path == "/"
          return static("pair.js", "text/javascript; charset=utf-8") if request.path == "/pair.js"
          return @app.call(request) if !paired && PAIRING_FILES.include?(request.path)
          return Response.error(401, "pair this device first") unless paired
          return Response.error(403, "only on the computer running the harness") if request.path.match?(LAN_GET_DENIED)

          return @app.call(request)
        end
        return Response.error(401, "pair this device first") unless paired
        return Response.error(403, "missing or wrong token") unless token_ok?(request.headers["x-harness-token"])
        return Response.error(403, "cross-origin request") unless request.headers["origin"].to_s.downcase == "http://#{@lan.ip}:#{@port}"
        return Response.error(400, "expected a JSON body") unless request.headers["content-type"].to_s.start_with?("application/json")
        return Response.error(403, "only on the computer running the harness") unless LAN_POST.any? { |re| re.match?(request.path) }

        @app.call(request)
      end

      # POST /api/lan/pair {"code": "123456"} from the pairing page: same Origin and a JSON body; no token yet.
      # @return [Response]
      def pair(request)
        return Response.error(403, "cross-origin request") unless request.headers["origin"].to_s.downcase == "http://#{@lan.ip}:#{@port}"
        return Response.error(400, "expected a JSON body") unless request.headers["content-type"].to_s.start_with?("application/json")

        data = request.json
        session = @lan.pair(data.is_a?(Hash) ? data["code"] : nil)
        r = Response.json({ "paired" => true })
        cookie = "#{Lan::COOKIE}=#{session}; Path=/; HttpOnly; SameSite=Strict"
        Response.new(status: r.status, headers: r.headers.merge("Set-Cookie" => cookie), body: r.body, stream: nil)
      rescue ConfigError => e
        Response.error(403, e.message)
      end

      def pairing_page
        static("pair.html", "text/html; charset=utf-8")
      end

      def static(file, type)
        Response.new(status: 200, headers: { "Content-Type" => type, "Cache-Control" => "no-cache" },
                     body: File.binread(File.join(PUBLIC, file)), stream: nil)
      end

      def stop_lan
        @lan&.stop
        @lan_server.close if @lan_server && !@lan_server.closed?
      end

      # @return [Array<String>]
      def origins = ["#{HOST}:#{@port}", "localhost:#{@port}"]

      def allowed_host?(host) = origins.include?(host.to_s.downcase)

      def allowed_origin?(origin) = origins.map { |o| "http://#{o}" }.include?(origin.to_s.downcase)

      def token_ok?(given)
        given.is_a?(String) && given.bytesize == @token.bytesize && secure_compare(given, @token)
      end

      def secure_compare(a, b)
        a.bytes.zip(b.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
      end
    end
  end
end
