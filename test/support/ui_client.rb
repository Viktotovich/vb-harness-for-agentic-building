# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "socket"

module TestSupport
  # Raw HTTP against the app server, so tests control every header (Host, Origin, token).
  module UIClient
    Reply = Data.define(:status, :headers, :body) do
      # @return [Object]
      def json = JSON.parse(body)

      # @return [Array<Array(String, Hash)>] [event, data] pairs of an SSE body
      def events
        body.split("\n\n").filter_map do |block|
          name = block[/^event: (.+)$/, 1]
          data = block[/^data: (.+)$/, 1]
          [name, JSON.parse(data)] if name && data
        end
      end
    end

    # @param port [Integer]
    # @param method [String]
    # @param path [String]
    # @param headers [Hash{String=>String}] sent as given; Host defaults to the app's own
    # @param body [Object, nil] sent as JSON
    # @return [Reply]
    def self.request(port, method, path, headers: {}, body: nil)
      payload = body.nil? ? "" : JSON.generate(body)
      head = { "Host" => "127.0.0.1:#{port}" }.merge(headers)
      head["Content-Length"] = payload.bytesize.to_s unless payload.empty?
      sock = TCPSocket.new("127.0.0.1", port)
      sock.write("#{method} #{path} HTTP/1.1\r\n#{head.map { |k, v| "#{k}: #{v}\r\n" }.join}\r\n#{payload}")
      raw = sock.read
      sock.close
      top, rest = raw.split("\r\n\r\n", 2)
      status = top[/\AHTTP\/1\.1 (\d+)/, 1].to_i
      fields = top.lines.drop(1).to_h { |l| k, v = l.split(":", 2); [k.strip.downcase, v.to_s.strip] }
      Reply.new(status: status, headers: fields, body: rest.to_s.force_encoding(Encoding::UTF_8))
    end

    # A POST the app accepts: token, same origin, JSON.
    # @return [Reply]
    def self.post(port, token, path, body = {})
      request(port, "POST", path, body: body, headers: { "X-Harness-Token" => token, "Origin" => "http://127.0.0.1:#{port}",
                                                         "Content-Type" => "application/json" })
    end
  end
end
