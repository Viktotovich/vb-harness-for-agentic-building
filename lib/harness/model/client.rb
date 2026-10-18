# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../sha256"
require "json"
require_relative "../errors"
require_relative "../parse"
require_relative "probe"
require_relative "tokens"
require_relative "wire"

module Harness
  module Model
    # system and user are strings; history is an Array of chat message hashes (may be empty).
    Messages = Data.define(:system, :user, :history) do
      # @param system [String]
      # @param user [String]
      # @param history [Array<Hash>]
      def initialize(system:, user:, history: [])
        super
      end
    end

    # usage is {in: Integer, out: Integer} summed over every request this call made; value is the parser's
    # result, or nil when no parser was given; tool_calls are present only when tools were offered.
    Completion = Data.define(:text, :value, :usage, :ms, :retried_without_thinking, :model, :profile, :tool_calls)

    # The robust caller (DESIGN.md 4.4), a port of REVIEWER src/llm/lmstudio.js: fit the request, send,
    # classify, retry once with thinking off, and record every request.
    class Client
      BAD_OUTPUT_RE = /structured output was incomplete|did not return valid JSON|could not validate structured output/i
      OVERFLOW_RE = /context (?:size|length|window)[^.]{0,40}exceed|exceed[^.]{0,40}context|too many tokens|n_ctx/i
      AT_MOST_RE = /at most (\d+)/i
      BUSY_STATUSES = [429, 503].freeze
      TRIES = 3

      Good = Data.define(:text, :value, :tool_calls)
      Bad = Data.define(:reason, :message)
      Call = Data.define(:role, :label, :profile, :caps)
      # A label that starts with a task id ("T1.implement", "T1R1.fix2") names that task in log lines.
      TASK_LABEL = /\A(T\d+(?:R\d+)?)\./
      # Replies that ran out of output room. After THINKING_STRIKES of them with thinking on, a role asks with
      # thinking off from the start: each one had cost a whole output allowance of thinking before the retry.
      OUT_OF_ROOM = %w[model.thinking_exhausted model.truncated].freeze
      THINKING_STRIKES = 2

      # @param config [Config]
      # @param probe [Probe, #call] returns a Probe::Result for a profile
      # @param http [Http]
      # @param records [State::Records, nil]
      # @param log [Log, nil]
      # @param env [Hash{String=>String}] where apiKeyEnv is looked up (I12)
      # @param sleeper [#call] waits n seconds between retries
      # @param backoff [Array<Numeric>] seconds before the 2nd, 3rd... try
      # @param clock [#call] monotonic seconds
      # @param run_id [String, nil] written into log lines
      def initialize(config:, probe:, http:, records: nil, log: nil, env: ENV, sleeper: ->(s) { sleep(s) },
                     backoff: [1, 2], clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, run_id: nil)
        @run_id = run_id
        @config = config
        @probe = probe
        @http = http
        @records = records
        @log = log
        @env = env
        @sleeper = sleeper
        @backoff = backoff
        @clock = clock
        @caps = {}
        @strikes = Hash.new(0)
      end

      # Called with (role:, label:, reason:, message:) for every reply the client throws away and retries, so the
      # run's event log counts it (DESIGN.md 10.3). Final failures are raised and the caller records them.
      # @return [#call, nil]
      attr_accessor :on_discard

      # @param role [Symbol] one of ROLES
      # @return [Probe::Result] the probed capabilities of the role's profile (probed once per client)
      # @raise [ModelUnavailableError]
      def capabilities(role)
        profile = @config.profile_for(role)
        @caps[profile.name] ||= @probe.call(profile)
      end

      # @param role [Symbol] one of ROLES
      # @param messages [Messages]
      # @param label [String] step name, used in records and logs
      # @param parser [#call, nil] e.g. Plan.method(:parse); required when a JSON reply is expected
      # @param schema [Hash, nil] JSON schema sent to the server, or put into the prompt
      # @param tools [Array<Hash>, nil] sent only when the profile has native tool calls
      # @param max_output_tokens [Integer, nil]
      # @return [Completion]
      # @raise [ModelOutputError, ModelUnavailableError, ContextOverflowError]
      def complete(role, messages, label:, parser: nil, schema: nil, tools: nil, max_output_tokens: nil)
        profile = @config.profile_for(role)
        caps = capabilities(role)
        call = Call.new(role: role, label: label, profile: profile, caps: caps)
        json = !parser.nil? || !schema.nil?
        native = !tools.nil? && !tools.empty? && caps.tool_calls == "native"
        body = build_body(call, messages, schema, json, native ? tools : nil, max_output_tokens || profile.max_output_tokens)
        thinking = caps.thinking_control != "none" && @strikes[role] < THINKING_STRIKES
        body = Wire.thinking_off(body, caps.thinking_control) unless thinking
        started = @clock.call
        usage = { in: 0, out: 0 }
        outcome = attempt(call, body, usage, json, parser, native)
        retried = outcome.is_a?(Bad)
        strike(call, outcome.reason) if retried && thinking
        @on_discard&.call(role: role, label: label, reason: outcome.reason,
                          message: "#{outcome.message[0, 200]}; #{thinking ? 'retried with thinking off' : 'retried'}") if retried
        first = outcome
        outcome = attempt(call, Wire.thinking_off(body, caps.thinking_control), usage, json, parser, native) if retried
        raise out_of_room(label, first, outcome) if outcome.is_a?(Bad) && OUT_OF_ROOM.include?(first.reason)
        raise ModelOutputError.new("#{label}: #{outcome.message}", reason: outcome.reason) if outcome.is_a?(Bad)

        Completion.new(text: outcome.text, value: outcome.value, usage: usage, ms: ms_since(started),
                       retried_without_thinking: retried, model: caps.model_id, profile: profile.name,
                       tool_calls: outcome.tool_calls)
      end

      # Split-and-retry over a batch: one call for all items, and on ModelOutputError (or a context
      # overflow) one call per item.
      # @param role [Symbol]
      # @param items [Array<Object>]
      # @param label [String]
      # @param parser [#call] parses one item's reply
      # @param schema [Hash, nil] schema of one item's reply
      # @yieldparam batch [Array<Object>] the items to put in one prompt
      # @yieldreturn [Messages]
      # @return [Array<Completion, ModelOutputError>] in item order
      # @raise [ModelUnavailableError, ContextOverflowError] when a single item cannot be sent
      def complete_each(role, items, label:, parser:, schema:, &build_messages)
        raise ArgumentError, "complete_each needs a block that builds Messages" unless build_messages

        if items.size > 1
          begin
            batch = complete(role, build_messages.call(items), label: "#{label}.batch",
                                                               parser: batch_parser(parser, items.size), schema: batch_schema(schema, items.size))
            return batch.value.map { |v| batch.with(value: v) }
          rescue ModelOutputError, ContextOverflowError
            nil # fall through to one call per item
          end
        end
        items.each_with_index.map do |item, i|
          complete(role, build_messages.call([item]), label: "#{label}.#{i + 1}", parser: parser, schema: schema)
        rescue ModelOutputError => e
          e
        end
      end

      private

      # Fit the request (step 1) and build it for the probed modes (step 2).
      # @return [Hash]
      # @raise [ContextOverflowError]
      def build_body(call, messages, schema, json, tools, reserved)
        caps = call.caps
        wire = wire_messages(messages, call.profile, caps, schema, json, flatten: tools.nil?)
        prompt = Tokens.estimate_messages(wire) + Tokens.estimate(tools ? JSON.generate(tools) : nil) +
                 (caps.structured_output == "json_schema" && schema ? Tokens.estimate(JSON.generate(schema)) : 0)
        if Tokens.budget(context: caps.context_tokens, prompt: prompt, reserved: reserved).negative?
          raise ContextOverflowError, "#{call.label}: needs ~#{prompt} prompt tokens + #{reserved} output tokens, " \
                                      "the context is #{caps.context_tokens}"
        end
        body = { "model" => caps.model_id, "messages" => wire, "max_tokens" => reserved, "stream" => false }
        body["temperature"] = call.profile.temperature unless call.profile.temperature.nil?
        body["tools"] = tools if tools
        format = response_format(caps.structured_output, schema, json)
        body["response_format"] = format if format
        body.merge(Wire.thinking_on(call.profile.thinking, caps.thinking_control))
      end

      # @return [Array<Hash>]
      def wire_messages(messages, profile, caps, schema, json, flatten:)
        system = messages.system.to_s
        if json && caps.structured_output != "json_schema"
          system += schema ? "\n\nReply with only JSON matching this schema:\n#{JSON.generate(schema)}" : "\n\nReply with only JSON."
        end
        system += "\n\n#{profile.prompt_notes}" if profile.prompt_notes
        history = messages.history.map { |m| m.transform_keys(&:to_s) }
        history = Wire.flatten_tool_history(history) if flatten || caps.tool_calls != "native"
        [{ "role" => "system", "content" => system }, *history, { "role" => "user", "content" => messages.user.to_s }]
      end

      # @return [Hash, nil]
      def response_format(mode, schema, json)
        return nil unless json
        return { "type" => "json_schema", "json_schema" => { "name" => "output", "strict" => true, "schema" => schema } } if mode == "json_schema" && schema
        return { "type" => "json_object" } if mode == "json_object"

        nil
      end

      # Send one request (step 3) and classify the reply.
      # @return [Good, Bad]
      # @raise [ModelUnavailableError, ContextOverflowError]
      def attempt(call, body, usage, json, parser, tools_offered)
        res, started = post_with_retry(call, body, usage)
        room = res.ok? ? nil : res.error_text[AT_MOST_RE, 1]&.to_i
        if room&.positive? && room < body["max_tokens"]
          record(call, body, res, started, "shrink:#{room}", nil)
          body = body.merge("max_tokens" => room)
          res, started = post_with_retry(call, body, usage)
        end
        if !res.ok? && res.error_text.match?(OVERFLOW_RE)
          record(call, body, res, started, "overflow", "ContextOverflowError")
          raise ContextOverflowError, "#{call.label}: the prompt exceeds the model's context window"
        end
        outcome = classify(call, res, json, parser, tools_offered)
        record(call, body, res, started, outcome.is_a?(Bad) ? outcome.reason : "ok",
               outcome.is_a?(Bad) ? "ModelOutputError" : nil)
        outcome
      end

      # Connection refused, timeout, HTTP 429/503: retry with backoff, then ModelUnavailableError.
      # @return [Array(Http::Response, Float)] the response and when its request started
      def post_with_retry(call, body, usage)
        url = "#{call.profile.base_url}/chat/completions"
        headers = Probe.headers(call.profile, @env)
        (1..TRIES).each do |try|
          started = @clock.call
          begin
            res = @http.post(url, body, headers: headers, timeout: call.profile.timeout_sec)
          rescue ModelUnavailableError => e
            record(call, body, nil, started, "unavailable", "ModelUnavailableError")
            raise ModelUnavailableError, "#{call.label}: #{e.message}" if try == TRIES
          else
            add_usage(usage, body, res)
            return [res, started] unless BUSY_STATUSES.include?(res.status)

            record(call, body, res, started, "busy:#{res.status}", "ModelUnavailableError")
            raise ModelUnavailableError, "#{call.label}: server busy (HTTP #{res.status})" if try == TRIES
          end
          @sleeper.call(@backoff[try - 1] || @backoff.last || 1)
        end
      end

      # @return [Good, Bad]
      # @raise [ModelUnavailableError] on an HTTP error that is not about the output
      def classify(call, res, json, parser, tools_offered)
        unless res.ok?
          text = res.error_text
          unless text.match?(BAD_OUTPUT_RE)
            raise ModelUnavailableError, "#{call.label}: HTTP #{res.status}: #{text[0, 200]}"
          end

          return Bad.new(reason: text.match?(/incomplete/i) ? "model.truncated" : "model.invalid_json",
                         message: "the server rejected the output: #{text[0, 200]}")
        end
        choice = res.json.is_a?(Hash) ? res.json.dig("choices", 0) : nil
        msg = choice.is_a?(Hash) ? choice["message"] : nil
        return Bad.new(reason: "model.empty", message: "no message in the reply") unless msg.is_a?(Hash)

        classify_message(msg, choice["finish_reason"], json, parser, tools_offered)
      end

      # @return [Good, Bad]
      def classify_message(msg, finish, json, parser, tools_offered)
        calls = msg["tool_calls"].is_a?(Array) ? msg["tool_calls"] : []
        answer, inline, open = Wire.split_thinking(msg["content"])
        unless calls.empty?
          return Good.new(text: answer, value: nil, tool_calls: calls) if tools_offered

          return Bad.new(reason: "model.schema_mismatch", message: "a tool call where an answer was required")
        end
        if answer.empty?
          separate = [msg["reasoning_content"], msg["reasoning"]].any? { |r| r.is_a?(String) && !r.empty? }
          thinking = open || !inline.empty? || separate
          reason = if finish == "length" then thinking ? "model.thinking_exhausted" : "model.truncated"
                   else "model.empty"
                   end
          return Bad.new(reason: reason, message: "no answer (finish_reason=#{finish.inspect})")
        end
        return Good.new(text: answer, value: nil, tool_calls: []) unless json

        parse_answer(answer, finish, parser)
      end

      # @return [Good, Bad]
      def parse_answer(answer, finish, parser)
        value = Wire.extract_json(answer)
        value = parser.call(value) if parser
        Good.new(text: answer, value: value, tool_calls: [])
      rescue JSON::ParserError
        Bad.new(reason: finish == "length" ? "model.truncated" : "model.invalid_json", message: "the reply is not valid JSON")
      rescue ParseError => e
        Bad.new(reason: "model.schema_mismatch", message: e.message)
      end

      # @return [#call] parses {"items": [...]} with exactly n entries, each through parser
      def batch_parser(parser, n)
        lambda do |value|
          list = value.is_a?(Hash) ? value["items"] : value
          Parse.fail!("items", "array of #{n} entries", list) unless list.is_a?(Array) && list.size == n
          list.each_with_index.map do |item, i|
            parser.call(item)
          rescue ParseError => e
            raise ParseError, "items[#{i}]: #{e.message}"
          end
        end
      end

      # @return [Hash]
      def batch_schema(schema, n)
        { "type" => "object", "additionalProperties" => false, "required" => ["items"],
          "properties" => { "items" => { "type" => "array", "items" => schema || {}, "minItems" => n, "maxItems" => n } } }
      end

      # @return [void]
      def add_usage(usage, body, res)
        u = res.json.is_a?(Hash) && res.json["usage"].is_a?(Hash) ? res.json["usage"] : {}
        content = res.json.is_a?(Hash) ? res.json.dig("choices", 0, "message", "content") : nil
        usage[:in] += u["prompt_tokens"].is_a?(Integer) ? u["prompt_tokens"] : Tokens.estimate_messages(body["messages"])
        usage[:out] += u["completion_tokens"].is_a?(Integer) ? u["completion_tokens"] : Tokens.estimate(content.to_s)
      end

      # One record and one log line per request (step 6). Never includes headers or keys (I12).
      # @return [void]
      def record(call, body, res, started, outcome, error_class)
        ms = ms_since(started)
        u = res&.json.is_a?(Hash) && res.json["usage"].is_a?(Hash) ? res.json["usage"] : {}
        finish = res&.json.is_a?(Hash) ? res.json.dig("choices", 0, "finish_reason") : nil
        error = res && !res.ok? ? Log.redact(res.error_text).gsub(/\s+/, " ")[0, 300] : nil
        @records&.write(role: call.role.to_s, label: call.label, profile: call.profile.name, model: call.caps.model_id,
                        prompt_hash: Sha256.hex(JSON.generate(body["messages"])),
                        usage: { "in" => u["prompt_tokens"], "out" => u["completion_tokens"] }, ms: ms,
                        finish_reason: finish, outcome: outcome, error_class: error_class, status: res&.status, error: error)
        @log&.write(action: "model.#{call.label}", outcome: outcome, run: @run_id || "-", task: call.label[TASK_LABEL, 1] || "-",
                    detail: "role=#{call.role} profile=#{call.profile.name} model=#{call.caps.model_id} " \
                            "status=#{res&.status || '-'} ms=#{ms}#{error ? " error=#{error[0, 120]}" : ''}")
      end

      # @return [Integer]
      def ms_since(started)
        ((@clock.call - started) * 1000).round
      end

      # The first reply ran out of output room and the retry failed too. A field run's retry returned "no edits",
      # which read as a shape problem; the cause is the size of the answer, so the error keeps that reason.
      # @return [ModelOutputError]
      def out_of_room(label, first, second)
        ModelOutputError.new("#{label}: the answer did not fit in maxOutputTokens: #{first.message}; " \
                             "the retry with thinking off then failed: #{second.message}", reason: first.reason)
      end

      # Count a reply that ran out of room with thinking on; at THINKING_STRIKES the role stops thinking.
      # @return [void]
      def strike(call, reason)
        return unless OUT_OF_ROOM.include?(reason)

        @strikes[call.role] += 1
        return unless @strikes[call.role] == THINKING_STRIKES

        @log&.write(action: "model.thinking", outcome: "off", run: @run_id || "-", task: call.label[TASK_LABEL, 1] || "-",
                    detail: "role=#{call.role} asks with thinking off from now on: #{THINKING_STRIKES} replies ran out of room thinking")
      end
    end
  end
end
