# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../model/client"
require_relative "../untrusted"
require_relative "toolbox"

module Harness
  module Agent
    # One agent conversation: the model calls tools from a Toolbox until it calls finish or runs out of steps.
    # Profiles with native tool calls use them; the others use a JSON reply protocol (one tool per reply), as the
    # reviewer's tool loop does (DESIGN.md 8.1). The conversation is kept, so the harness can send the agent back
    # with what its own checks found (#continue) and the agent keeps everything it already read.
    class Session
      NUDGE = "Use the tools to do the work. When it is done, call finish with a short summary."
      EMULATED = <<~TEXT
        You work by calling tools. Reply with only one JSON object per message:
          {"tool": "<name>", "args": {...}}   to call a tool, or
          {"tool": "finish", "args": {"summary": "..."}}   when you are done.
        Tools:
      TEXT
      # Tool results older than this many are cut to their first line when the conversation grows long.
      KEEP_RESULTS = 12
      # Characters per estimated token, for deciding when to trim: deliberately pessimistic.
      CHARS_PER_TOKEN = 3

      # finished: the agent's summary, or nil when it stopped without finishing; steps: tool calls used so far;
      # exhausted: it stopped because its step budget ran out.
      Result = Data.define(:finished, :steps, :text, :exhausted)

      # @return [Integer] tool calls used so far
      attr_reader :steps

      # @param client [Model::Client]
      # @param role [Symbol]
      # @param system [String]
      # @param toolbox [Toolbox]
      # @param label [String] step name for records, e.g. "T1.agent"
      # @param on_step [#call, nil] (kind, detail_hash) -> void, for events: :turn after each model reply, :tool after
      #   each tool call
      def initialize(client:, role:, system:, toolbox:, label:, on_step: nil)
        @client = client
        @role = role
        @toolbox = toolbox
        @label = label
        @on_step = on_step || ->(*) {}
        @native = client.capabilities(role).tool_calls == "native"
        @system = @native ? system : "#{system}\n\n#{EMULATED}#{listing}"
        @history = []
        @steps = 0
        @turns = 0
      end

      # Start with the task, or go on with a note from the harness (what its checks found).
      # @param prompt [String]
      # @param max_steps [Integer] tool calls allowed in this stretch
      # @return [Result]
      # @raise [ModelOutputError, ContextOverflowError, ModelUnavailableError]
      def run(prompt, max_steps:)
        budget = @steps + max_steps
        nudged = false
        loop do
          reply = turn(prompt, budget)
          return Result.new(finished: nil, steps: @steps, text: reply[:text], exhausted: true) if reply[:exhausted]

          calls = reply[:calls]
          if calls.empty?
            return Result.new(finished: nil, steps: @steps, text: reply[:text], exhausted: false) if nudged

            nudged = true
            prompt = NUDGE
            next
          end
          results = calls.map do |name, args, id|
            out = if @steps >= budget then Untrusted.fence("error: step limit reached; call finish with what you have")
                  else
                    @steps += 1
                    r = @toolbox.call(name, args)
                    @on_step.call(:tool, { tool: name, ok: @toolbox.calls.last&.ok, outcome: @toolbox.calls.last&.outcome })
                    r
                  end
            [name, id, out]
          end
          if calls.any? { |n, *| n == "finish" } && @toolbox.finished
            return Result.new(finished: @toolbox.finished, steps: @steps, text: reply[:text], exhausted: false)
          end

          prompt = record_results(results)
        end
      end

      # Go on after the harness found a problem the agent must fix.
      # @param note [String] what was found, already fenced where it holds untrusted text
      # @param max_steps [Integer]
      # @return [Result]
      def continue(note, max_steps:)
        @toolbox.reset_finish
        run(note, max_steps: max_steps)
      end

      private

      # One model reply. Returns the tool calls it made ([name, args, id]), or exhausted: true when the step budget
      # is used up (no further call is made: unfinished work is not finished by asking once more).
      # @return [Hash]
      def turn(prompt, budget)
        return { exhausted: true, text: "" } if @steps >= budget

        trim!
        @turns += 1
        if @native
          c = @client.complete(@role, Model::Messages.new(system: @system, user: prompt, history: @history), label: "#{@label}.#{@turns}",
                                                                                                         tools: @toolbox.definitions)
          @history << { "role" => "user", "content" => prompt }
          @on_step.call(:turn, { model: c.model, profile: c.profile, tokens: c.usage, ms: c.ms })
          calls = Array(c.tool_calls).filter_map do |tc|
            fn = tc.is_a?(Hash) ? tc["function"] || {} : {}
            next unless fn["name"].is_a?(String)

            [fn["name"], arguments(fn["arguments"]), tc["id"].to_s]
          end
          @history << { "role" => "assistant", "content" => c.text.to_s, "tool_calls" => c.tool_calls } unless calls.empty?
          @history << { "role" => "assistant", "content" => c.text.to_s } if calls.empty?
          { calls: calls, text: c.text.to_s }
        else
          c = @client.complete(@role, Model::Messages.new(system: @system, user: prompt, history: @history), label: "#{@label}.#{@turns}",
                                                                                                         parser: method(:tool_request))
          @history << { "role" => "user", "content" => prompt } << { "role" => "assistant", "content" => c.text.to_s }
          @on_step.call(:turn, { model: c.model, profile: c.profile, tokens: c.usage, ms: c.ms })
          { calls: [[c.value["tool"], c.value["args"], nil]], text: c.text.to_s }
        end
      end

      # @return [String] the next prompt (emulated) or "" after appending tool messages (native)
      def record_results(results)
        if @native
          results.each { |_, id, out| @history << { "role" => "tool", "tool_call_id" => id, "content" => out } }
          "Continue."
        else
          name, _, out = results.first
          "Result of #{name}:\n#{out}"
        end
      end

      # Long conversations: cut older tool results to their first line, so the context holds the recent work.
      # @return [void]
      def trim!
        limit = @client.capabilities(@role).context_tokens * CHARS_PER_TOKEN / 2
        size = @system.size + @history.sum { |m| m["content"].to_s.size }
        return if size <= limit

        results = @history.each_index.select { |i| result_message?(@history[i]) }
        results[0...-KEEP_RESULTS].each do |i|
          m = @history[i]
          first = m["content"].to_s.lines.reject { |l| l.start_with?("<") }.first.to_s.strip[0, 160]
          m["content"] = "(earlier result, trimmed: #{first})"
        end
      end

      # @return [Boolean]
      def result_message?(m)
        m["role"] == "tool" || (m["role"] == "user" && m["content"].to_s.start_with?("Result of "))
      end

      # @return [String] the tool list for the JSON protocol
      def listing
        @toolbox.definitions.map do |d|
          f = d["function"]
          "- #{f['name']}(#{f['parameters']['properties'].keys.join(', ')}): #{f['description']}"
        end.join("\n")
      end

      # @param obj [Object] the model's JSON reply
      # @return [Hash] {"tool", "args"}
      # @raise [ParseError]
      def tool_request(obj)
        raise ParseError, "expected {\"tool\": \"<name>\", \"args\": {...}}" unless obj.is_a?(Hash) && obj["tool"].is_a?(String)

        { "tool" => obj["tool"], "args" => obj["args"].is_a?(Hash) ? obj["args"] : {} }
      end

      # @return [Hash]
      def arguments(raw)
        raw.is_a?(Hash) ? raw : JSON.parse(raw.to_s)
      rescue JSON::ParserError
        {}
      end
    end
  end
end
