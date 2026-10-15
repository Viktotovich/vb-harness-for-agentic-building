# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  module Model
    # Token estimates without a tokenizer. Deliberately pessimistic (about 3 bytes per token), so a
    # request that fits by estimate also fits on the server; the server's "at most N" and overflow
    # replies cover the rest.
    module Tokens
      BYTES_PER_TOKEN = 3.0
      MESSAGE_OVERHEAD = 4

      # @param text [String, nil]
      # @return [Integer]
      def self.estimate(text)
        return 0 if text.nil? || text.empty?

        (text.bytesize / BYTES_PER_TOKEN).ceil
      end

      # @param messages [Array<Hash>] chat messages with "content" (and optional "tool_calls")
      # @return [Integer]
      def self.estimate_messages(messages)
        messages.sum do |m|
          extra = m["tool_calls"] ? estimate(m["tool_calls"].to_s) : 0
          MESSAGE_OVERHEAD + estimate(m["content"].to_s) + extra
        end
      end

      # Room left for the prompt after the reserved output. Negative means the request does not fit.
      # @param context [Integer] the model's context size
      # @param prompt [Integer] estimated prompt tokens
      # @param reserved [Integer] output tokens reserved for the answer
      # @return [Integer]
      def self.budget(context:, prompt:, reserved:)
        context - prompt - reserved
      end
    end
  end
end
