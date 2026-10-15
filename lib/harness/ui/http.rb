# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "uri"

module Harness
  module UI
    # A parsed request. path has no query; query holds decoded parameters; headers have lowercase names.
    Request = Data.define(:method, :path, :query, :headers, :body) do
      # @return [Object, nil] the JSON body, or nil when it is not JSON
      def json
        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end
    end

    # A response: status, headers and a String body, or a streaming block that receives an SSE writer.
    Response = Data.define(:status, :headers, :body, :stream) do
      # @param status [Integer]
      # @param data [Object]
      # @return [Response]
      def self.json(data, status: 200)
        new(status: status, headers: { "Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store" },
            body: JSON.generate(data), stream: nil)
      end

      # @return [Response]
      def self.text(text, status: 200, type: "text/plain; charset=utf-8")
        new(status: status, headers: { "Content-Type" => type }, body: text, stream: nil)
      end

      # @return [Response] {"error": message}
      def self.error(status, message)
        json({ "error" => message }, status: status)
      end

      # @yieldparam sse [SSE]
      # @return [Response]
      def self.sse(&block)
        new(status: 200, headers: { "Content-Type" => "text/event-stream; charset=utf-8", "Cache-Control" => "no-store" },
            body: nil, stream: block)
      end
    end

    # Writes server-sent events. closed? turns true once the browser goes away.
    class SSE
      # @param io [IO]
      def initialize(io)
        @io = io
        @closed = false
      end

      # @param event [String]
      # @param data [Object] sent as JSON
      # @param id [Integer, nil]
      # @return [Boolean] false when the connection is gone
      def event(event, data, id: nil)
        return false if @closed

        @io.write("#{id ? "id: #{id}\n" : ''}event: #{event}\ndata: #{JSON.generate(data)}\n\n")
        true
      rescue IOError, SystemCallError
        @closed = true
        false
      end

      # @return [Boolean]
      def closed? = @closed
    end

    # Minimal HTTP/1.1 for the local app: one request per connection, bounded sizes, no keep-alive.
    module HTTP
      MAX_HEADER = 16 * 1024
      MAX_BODY = 1024 * 1024
      READ_TIMEOUT = 10
      REASONS = { 200 => "OK", 204 => "No Content", 400 => "Bad Request", 403 => "Forbidden", 404 => "Not Found",
                  405 => "Method Not Allowed", 409 => "Conflict", 413 => "Payload Too Large", 421 => "Misdirected Request",
                  500 => "Internal Server Error", 503 => "Service Unavailable" }.freeze

      # Raised for a request that cannot be read.
      class BadRequest < StandardError
        # @return [Integer]
        attr_reader :status

        def initialize(status, message)
          super(message)
          @status = status
        end
      end

      # @param io [IO]
      # @return [Request]
      # @raise [BadRequest]
      def self.read(io)
        head = +""
        until head.include?("\r\n\r\n")
          raise BadRequest.new(400, "timed out") unless io.wait_readable(READ_TIMEOUT)

          chunk = io.readpartial(1024)
          head << chunk
          raise BadRequest.new(413, "headers too large") if head.bytesize > MAX_HEADER
        end
        head, rest = head.split("\r\n\r\n", 2)
        line, *fields = head.split("\r\n")
        method, target, = line.to_s.split(" ")
        raise BadRequest.new(400, "bad request line") unless method && target&.start_with?("/")

        headers = fields.to_h do |f|
          k, v = f.split(":", 2)
          [k.to_s.strip.downcase, v.to_s.strip]
        end
        length = headers["content-length"].to_i
        raise BadRequest.new(413, "body too large") if length > MAX_BODY

        body = rest.to_s.b
        while body.bytesize < length
          raise BadRequest.new(400, "timed out") unless io.wait_readable(READ_TIMEOUT)

          body << io.readpartial([length - body.bytesize, 65_536].min)
        end
        path, query = target.split("?", 2)
        Request.new(method: method, path: URI.decode_www_form_component(path), query: URI.decode_www_form(query.to_s).to_h,
                    headers: headers, body: body.byteslice(0, length).force_encoding(Encoding::UTF_8))
      rescue EOFError, ArgumentError
        raise BadRequest.new(400, "bad request")
      end

      # @param io [IO]
      # @param response [Response]
      # @param security [Hash{String=>String}] headers sent on every response
      # @return [void]
      def self.write(io, response, security)
        headers = security.merge(response.headers).merge("Connection" => "close")
        headers["Content-Length"] = response.body.bytesize.to_s if response.body
        io.write("HTTP/1.1 #{response.status} #{REASONS.fetch(response.status, 'OK')}\r\n")
        headers.each { |k, v| io.write("#{k}: #{v}\r\n") }
        io.write("\r\n")
        io.write(response.body) if response.body
        response.stream&.call(SSE.new(io))
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
