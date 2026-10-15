# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "securerandom"
require "socket"
require_relative "http"

module Harness
  module UI
    # The local app's server on TCPServer (DESIGN.md 11.3, I15): bound to 127.0.0.1 only, with no option to change
    # it; requests for another Host are refused (DNS rebinding); every POST needs the per-start token and the app's
    # own Origin; no CORS headers; a strict CSP on every response. One thread per connection.
    class Server
      HOST = "127.0.0.1"
      CSP = "default-src 'self'; script-src 'self'; style-src 'self'; font-src 'self'; connect-src 'self'; " \
            "img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
      SECURITY = { "Content-Security-Policy" => CSP, "X-Content-Type-Options" => "nosniff", "Referrer-Policy" => "no-referrer",
                   "X-Frame-Options" => "DENY", "Cross-Origin-Opener-Policy" => "same-origin",
                   "Cross-Origin-Resource-Policy" => "same-origin" }.freeze

      attr_reader :port, :token

      # @param app [#call] Request -> Response
      # @param port [Integer] 0 picks a free port
      # @param token [String]
      # @param log [#call, nil] (message) for errors
      def initialize(app:, port: 4567, token: SecureRandom.hex(32), log: nil)
        @app = app
        @token = token
        @log = log
        @server = TCPServer.new(HOST, port)
        @port = @server.addr[1]
        @threads = []
      end

      # @return [String] e.g. http://127.0.0.1:4567/
      def url = "http://#{HOST}:#{@port}/"

      # Serve until stop is called.
      # @return [void]
      def run
        loop do
          client = @server.accept
          @threads.select!(&:alive?)
          @threads << Thread.new(client) { |c| handle(c) }
        rescue IOError, SystemCallError
          break if @server.closed?
        end
      end

      # @return [Thread] the accept loop, running in the background
      def start
        @loop = Thread.new { run }
      end

      # @return [void]
      def stop
        @server.close unless @server.closed?
        @loop&.join(2)
        @threads.each { |t| t.kill if t.alive? }
      end

      # The I15 checks, then the app.
      # @param request [Request]
      # @return [Response]
      def respond(request)
        return Response.error(421, "unknown host") unless allowed_host?(request.headers["host"])
        return Response.error(405, "method not allowed") unless %w[GET POST].include?(request.method)

        if request.method == "POST"
          return Response.error(403, "missing or wrong token") unless token_ok?(request.headers["x-harness-token"])
          return Response.error(403, "cross-origin request") unless allowed_origin?(request.headers["origin"])
          return Response.error(400, "expected a JSON body") unless request.headers["content-type"].to_s.start_with?("application/json")
        end
        @app.call(request)
      end

      private

      def handle(client)
        response = begin
          respond(HTTP.read(client))
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
