# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "socket"

module TestSupport
  # A fake OpenAI-compatible server on 127.0.0.1 with an OS-picked port (DESIGN.md section 2).
  # GET .../models lists `models`; POST .../chat/completions is answered by the handler block, or by
  # `replies` in order (the last one repeats). Every request is recorded.
  class FakeLlmServer
    Request = Data.define(:method, :path, :headers, :body)

    attr_reader :requests

    # @param models [Array<Hash>] entries of GET /models "data"
    # @param replies [Array<Array(Integer, Object)>] [status, body] answers for chat completions
    # @yieldparam body [Hash] the chat request body
    # @yieldparam n [Integer] 0-based index of this chat request
    # @yieldreturn [Array(Integer, Object)] [status, body]
    def initialize(models: [{ "id" => "test-model" }], replies: nil, &handler)
      @models = models
      @replies = replies
      @handler = handler
      @requests = []
      @mutex = Mutex.new
      @server = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { serve }
    end

    # @return [String] e.g. http://127.0.0.1:54321/v1
    def base_url
      "http://127.0.0.1:#{@server.addr[1]}/v1"
    end

    # @return [Array<Hash>] bodies of the chat requests, in order
    def chat_bodies
      @mutex.synchronize { @requests.select { |r| r.path.end_with?("/chat/completions") }.map(&:body) }
    end

    # @return [void]
    def stop
      @thread.kill
      @server.close
    rescue IOError
      nil
    end

    # @param content [String, nil]
    # @param finish [String]
    # @param usage [Hash]
    # @param extra [Hash] more message fields (tool_calls, reasoning_content)
    # @return [Array(Integer, Hash)] a successful chat reply
    def self.ok(content, finish: "stop", usage: { "prompt_tokens" => 10, "completion_tokens" => 5 }, **extra)
      message = { "role" => "assistant", "content" => content }.merge(extra.transform_keys(&:to_s))
      [200, { "choices" => [{ "message" => message, "finish_reason" => finish }], "usage" => usage }]
    end

    # @return [Array(Integer, Hash)] an error reply in the OpenAI shape
    def self.error(status, message)
      [status, { "error" => { "message" => message } }]
    end

    private

    def serve
      loop do
        client = @server.accept
        handle(client)
      rescue IOError, SystemCallError
        break if @server.closed?
      ensure
        client&.close
      end
    end

    def handle(client)
      method, path = client.gets.to_s.split
      headers = read_headers(client)
      raw = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
      body = raw.to_s.empty? ? nil : JSON.parse(raw)
      req = Request.new(method: method, path: path, headers: headers, body: body)
      n = @mutex.synchronize do
        @requests << req
        @requests.count { |r| r.path.end_with?("/chat/completions") } - 1
      end
      status, payload = route(req, n)
      respond(client, status, payload)
    end

    def read_headers(client)
      headers = {}
      while (line = client.gets) && line != "\r\n"
        k, v = line.split(":", 2)
        headers[k.strip.downcase] = v.to_s.strip
      end
      headers
    end

    def route(req, n)
      return [200, { "object" => "list", "data" => @models }] if req.method == "GET" && req.path.end_with?("/models")
      return [404, { "error" => { "message" => "not found" } }] unless req.path.end_with?("/chat/completions")
      return @handler.call(req.body, n) if @handler
      return @replies[[n, @replies.size - 1].min] if @replies

      self.class.ok("OK")
    end

    def respond(client, status, payload)
      text = payload.is_a?(String) ? payload : JSON.generate(payload)
      client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{text.bytesize}\r\nConnection: close\r\n\r\n#{text}")
    end
  end
end
