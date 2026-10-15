# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"

module Harness
  module Model
    # Request and reply details shared by the probe and the client. Nothing here depends on which model
    # answers: each thinking control is a generic request parameter, chosen by the probe or the profile.
    module Wire
      # Request fields that turn thinking off, per control.
      THINKING_OFF = {
        "chat_template_kwargs" => { "chat_template_kwargs" => { "enable_thinking" => false } },
        "reasoning_effort" => { "reasoning_effort" => "none" },
        "budget" => { "thinking_budget_tokens" => 0 },
        "none" => {}
      }.freeze
      THINKING_KEYS = %w[chat_template_kwargs reasoning_effort thinking_budget_tokens].freeze
      THINK_BLOCK = %r{<think>.*?</think>}m
      # A Markdown code fence (three backticks, written as \x60 so lib/ has no backtick characters, I3).
      CODE_FENCE = /\x60{3}(?:json)?\s*\n(.*?)\n?\x60{3}/m

      module_function

      # Fields for a normal request: thinking as the profile configures it.
      # @param thinking [Thinking] the profile's thinking settings
      # @param control [String] the effective control (profile value, or the probe's when "probe")
      # @return [Hash]
      def thinking_on(thinking, control)
        case control
        when "reasoning_effort" then { "reasoning_effort" => thinking.effort }
        when "budget" then thinking.budget_tokens ? { "thinking_budget_tokens" => thinking.budget_tokens } : {}
        else {}
        end
      end

      # @param body [Hash] a request body
      # @param control [String]
      # @return [Hash] the body with thinking turned off through control
      def thinking_off(body, control)
        body.except(*THINKING_KEYS).merge(THINKING_OFF.fetch(control, {}))
      end

      # Separate inline reasoning from the answer.
      # @param content [String, nil]
      # @return [Array(String, String, Boolean)] answer, reasoning text, true if a think block never closed
      def split_thinking(content)
        text = content.to_s
        reasoning = text.scan(THINK_BLOCK).join("\n")
        answer = text.gsub(THINK_BLOCK, "")
        open = answer.index("<think>")
        return [answer[0...open].strip, "#{reasoning}#{answer[open..]}", true] if open

        [answer.strip, reasoning, false]
      end

      # Parse JSON from a reply that may be wrapped in a code fence or surrounded by prose.
      # @param text [String]
      # @return [Object]
      # @raise [JSON::ParserError]
      def extract_json(text)
        s = text.strip
        fenced = s.match(CODE_FENCE)
        s = fenced[1].strip if fenced
        JSON.parse(s)
      rescue JSON::ParserError
        start = s.index(/[{\[]/)
        stop = s.rindex(/[}\]]/)
        raise if start.nil? || stop.nil? || stop <= start

        JSON.parse(s[start..stop])
      end

      # Rewrite tool use as plain text (port of REVIEWER flattenToolHistory). A JSON-only request must not
      # invite another tool call, and models without tool support must never see "tool" messages.
      # @param messages [Array<Hash>]
      # @return [Array<Hash>]
      def flatten_tool_history(messages)
        messages.map do |m|
          if m["role"] == "assistant" && m["tool_calls"].is_a?(Array) && !m["tool_calls"].empty?
            asked = m["tool_calls"].map { |tc| describe_call(tc) }
            content = [m["content"], "I called: #{asked.join(', ')}"].reject { |c| c.nil? || c.empty? }.join("\n")
            { "role" => "assistant", "content" => content }
          elsif m["role"] == "tool"
            { "role" => "user", "content" => "Tool result:\n#{m['content']}" }
          else
            m
          end
        end
      end

      # @param call [Hash] an OpenAI tool call
      # @return [String] e.g. read_file({"path":"src/a.ts"})
      def describe_call(call)
        fn = call.is_a?(Hash) ? call["function"] || {} : {}
        "#{fn['name'].to_s[0, 40]}(#{fn['arguments'].to_s[0, 160]})"
      end
    end
  end
end
