# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "net/http"
require "uri"
require_relative "../errors"
require_relative "http"
require_relative "probe"
require_relative "wire"

module Harness
  module Model
    # Streaming chat completions for the app's Chat mode (DESIGN.md 11.3): text and thinking arrive as separate
    # pieces, whether the server sends reasoning in its own field or inline in <think> tags. The caller can stop a
    # stream between pieces.
    class Stream
      THINK_OPEN = "<think>"
      THINK_CLOSE = "</think>"

      # One piece of a reply. kind: "text" or "thinking".
      Piece = Data.define(:kind, :text)

      # @param env [Hash{String=>String}] for the profile's apiKeyEnv (I12)
      # @param open_timeout [Numeric]
      def initialize(env: ENV, open_timeout: 5)
        @env = env
        @open_timeout = open_timeout
      end

      # @param profile [Profile]
      # @param model [String] the model id to ask for
      # @param messages [Array<Hash>] chat messages
      # @param max_tokens [Integer]
      # @param stop [#call] returns true when the user pressed Stop
      # @param thinking_off [String, nil] a probed thinking control to turn thinking off with, or nil to leave it
      # @yieldparam piece [Piece]
      # @return [String] why it ended: "stop", "length", "stopped" (by the user) or another finish reason
      # @raise [ModelUnavailableError] when the server cannot be reached or answers with an error
      def call(profile:, model:, messages:, max_tokens:, stop: -> { false }, thinking_off: nil, &on_piece)
        uri = URI("#{profile.base_url}/chat/completions")
        body = { "model" => model, "messages" => messages, "stream" => true, "max_tokens" => max_tokens }
        body["temperature"] = profile.temperature unless profile.temperature.nil?
        body = Wire.thinking_off(body, thinking_off) if thinking_off
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        Probe.headers(profile, @env).each { |k, v| req[k] = v }
        req.body = JSON.generate(body)
        finish = nil
        splitter = InlineThinking.new
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: @open_timeout,
                                            read_timeout: profile.timeout_sec) do |http|
          http.request(req) do |res|
            unless res.code.to_i.between?(200, 299)
              raise ModelUnavailableError, "HTTP #{res.code}: #{Http::Response.new(status: res.code.to_i, body: res.body.to_s, json: nil).error_text[0, 300]}"
            end

            buffer = +""
            res.read_body do |chunk|
              return "stopped" if stop.call

              buffer << chunk.force_encoding(Encoding::UTF_8)
              while (nl = buffer.index("\n"))
                line = buffer.slice!(0..nl).strip
                next unless line.start_with?("data:")

                data = line.delete_prefix("data:").strip
                next finish ||= "stop" if data == "[DONE]"

                finish = emit(data, splitter, finish, &on_piece)
              end
            end
          end
        end
        finish || "stop"
      rescue *Http::NETWORK_ERRORS => e
        raise ModelUnavailableError, "streaming from #{profile.base_url} failed (#{e.class.name.split('::').last})"
      end

      private

      # @return [String, nil] the finish reason, once known
      def emit(data, splitter, finish, &on_piece)
        event = JSON.parse(data)
        choice = event.is_a?(Hash) ? Array(event["choices"]).first : nil
        return finish unless choice.is_a?(Hash)

        delta = choice["delta"].is_a?(Hash) ? choice["delta"] : {}
        reasoning = delta["reasoning_content"] || delta["reasoning"]
        on_piece.call(Piece.new(kind: "thinking", text: reasoning)) if reasoning.is_a?(String) && !reasoning.empty?
        splitter.feed(delta["content"].to_s).each { |p| on_piece.call(p) } if delta["content"].is_a?(String)
        choice["finish_reason"] || finish
      rescue JSON::ParserError
        finish
      end

      # Splits streamed content at <think> and </think>, which may arrive cut across pieces.
      class InlineThinking
        def initialize
          @inside = false
          @pending = +""
        end

        # @param text [String]
        # @return [Array<Piece>]
        def feed(text)
          @pending << text
          out = []
          loop do
            tag = @inside ? THINK_CLOSE : THINK_OPEN
            if (i = @pending.index(tag))
              out << Piece.new(kind: kind, text: @pending[0...i]) if i.positive?
              @pending = @pending[(i + tag.size)..]
              @inside = !@inside
              next
            end
            keep = partial_tag(tag)
            emit = @pending[0...(@pending.size - keep)]
            out << Piece.new(kind: kind, text: emit) unless emit.empty?
            @pending = @pending[(@pending.size - keep)..]
            break
          end
          out
        end

        private

        def kind = @inside ? "thinking" : "text"

        # Length of a suffix that could be the start of tag.
        def partial_tag(tag)
          (1...tag.size).reverse_each.find { |n| @pending.end_with?(tag[0, n]) } || 0
        end
      end
    end
  end
end
