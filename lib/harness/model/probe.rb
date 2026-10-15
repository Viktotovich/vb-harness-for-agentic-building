# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../sha256"
require "json"
require_relative "../errors"
require_relative "../parse"
require_relative "../state/records"
require_relative "tokens"
require_relative "wire"

module Harness
  module Model
    # Capability probe (DESIGN.md 4.3): what a (baseUrl, model id) pair can do, found with tiny requests and
    # cached in .cache/probe/<sha256>.json. Profile values other than "probe" override the result.
    class Probe
      DEFAULT_CONTEXT = 8192

      Result = Data.define(:model_id, :context_tokens, :context_source, :structured_output, :tool_calls,
                           :thinking_control, :reasoning, :prompt_tps, :gen_tps)

      # Cache (de)serialisation and the plain-words summary shown after onboarding.
      class Result
        KEYS = %w[modelId contextTokens contextSource structuredOutput toolCalls thinkingControl reasoning
                  promptTps genTps].freeze

        # @param raw [Hash] cached JSON
        # @return [Result]
        # @raise [ParseError]
        def self.parse(raw)
          h = Parse.hash!(raw, "probe")
          tps = ->(k) { h[k].nil? ? nil : (h[k].is_a?(Numeric) ? h[k] : Parse.fail!("probe.#{k}", "number", h[k])) }
          new(model_id: Parse.str!(h["modelId"], "probe.modelId"),
              context_tokens: Parse.int!(h["contextTokens"], "probe.contextTokens", min: 1),
              context_source: Parse.enum!(h["contextSource"], "probe.contextSource", %w[models overflow default profile]),
              structured_output: Parse.enum!(h["structuredOutput"], "probe.structuredOutput", %w[json_schema json_object prompt]),
              tool_calls: Parse.enum!(h["toolCalls"], "probe.toolCalls", %w[native none]),
              thinking_control: Parse.enum!(h["thinkingControl"], "probe.thinkingControl", Wire::THINKING_OFF.keys),
              reasoning: Parse.enum!(h["reasoning"], "probe.reasoning", %w[separate inline none]),
              prompt_tps: tps.call("promptTps"), gen_tps: tps.call("genTps"))
        end

        # @return [Hash] JSON form, camelCase keys
        def to_json_hash
          KEYS.zip(to_h.values).to_h
        end

        # @return [String] e.g. "16K context, JSON mode: yes, tools: no, thinking can be turned off"
        def describe
          ctx = context_tokens >= 1024 ? "#{context_tokens / 1024}K" : context_tokens.to_s
          json = structured_output == "prompt" ? "no (JSON by instruction)" : "yes"
          think = thinking_control == "none" ? "no thinking control found" : "thinking can be turned off"
          "#{ctx} context, JSON mode: #{json}, tools: #{tool_calls == 'native' ? 'yes' : 'no'}, #{think}"
        end
      end

      CONTEXT_PATTERNS = [
        /maximum context length is (\d{3,8})/i,
        /n_ctx\D{0,20}(\d{3,8})/i,
        /context \((\d{3,8})\)/i,
        /context[ _](?:size|length|window)\D{0,30}(\d{3,8})/i
      ].freeze
      JSON_PROMPT = "Is water wet? Answer with the field yes."
      JSON_SCHEMA = { "type" => "object", "properties" => { "yes" => { "type" => "boolean" } },
                      "required" => ["yes"], "additionalProperties" => false }.freeze
      TOOL = { "type" => "function", "function" => {
        "name" => "record_value", "description" => "Record a number.",
        "parameters" => { "type" => "object", "properties" => { "value" => { "type" => "integer" } },
                          "required" => ["value"] }
      } }.freeze
      FILLER = "The quick brown fox jumps over the lazy dog near the quiet river bank. "

      # @param http [Http]
      # @param cache_dir [String] directory holding probe/<sha256>.json
      # @param env [Hash{String=>String}] where apiKeyEnv is looked up (I12)
      # @param timeout [Numeric] seconds per probe request
      # @param clock [#call] monotonic seconds
      def initialize(http:, cache_dir:, env: ENV, timeout: 120, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @http = http
        @cache_dir = cache_dir
        @env = env
        @timeout = timeout
        @clock = clock
      end

      # @param profile [Profile]
      # @param refresh [Boolean] ignore the cache
      # @return [Result] probe result with the profile's overrides applied
      # @raise [ModelUnavailableError] when GET /models fails or the configured model is not listed
      def call(profile, refresh: false)
        entry = model_entry(profile)
        path = File.join(@cache_dir, "probe", "#{Sha256.hex(JSON.generate([profile.base_url, entry]))}.json")
        result = (!refresh && read_cache(path)) || probe(profile, entry).tap { |r| State.write_json(path, r.to_json_hash) }
        apply_profile(profile, result)
      end

      # @param profile [Profile]
      # @return [Hash{String=>String}] Authorization header when the profile names a key variable
      def self.headers(profile, env)
        key = profile.api_key_env && env[profile.api_key_env]
        key.nil? || key.empty? ? {} : { "Authorization" => "Bearer #{key}" }
      end

      private

      # @return [Hash] the /models entry for the profile's model
      def model_entry(profile)
        res = @http.get("#{profile.base_url}/models", headers: Probe.headers(profile, @env), timeout: [@timeout, 30].min)
        data = res.json.is_a?(Hash) ? res.json["data"] : nil
        unless res.ok? && data.is_a?(Array) && data.all? { |m| m.is_a?(Hash) && m["id"].is_a?(String) }
          raise ModelUnavailableError, "GET /models returned HTTP #{res.status} without a model list"
        end
        raise ModelUnavailableError, "the server lists no models" if data.empty?
        return data.first if profile.model == "auto"

        data.find { |m| m["id"] == profile.model } ||
          raise(ModelUnavailableError, "model #{profile.model.inspect} is not listed by the server")
      end

      # @return [Result, nil]
      def read_cache(path)
        Result.parse(JSON.parse(File.read(path, encoding: "UTF-8")))
      rescue Errno::ENOENT, JSON::ParserError, ParseError
        nil
      end

      # @return [Result]
      def probe(profile, entry)
        id = entry["id"]
        context, source = context_of(profile, id, entry)
        control, reasoning = thinking_of(profile, id)
        off = Wire::THINKING_OFF.fetch(control)
        prompt_tps, gen_tps = throughput(profile, id, off)
        Result.new(model_id: id, context_tokens: context, context_source: source,
                   structured_output: structured_of(profile, id, off), tool_calls: tools_of(profile, id, off),
                   thinking_control: control, reasoning: reasoning, prompt_tps: prompt_tps, gen_tps: gen_tps)
      end

      # @return [Result]
      def apply_profile(profile, r)
        ctx = profile.context_tokens
        r.with(
          context_tokens: ctx == "probe" ? r.context_tokens : ctx,
          context_source: ctx == "probe" ? r.context_source : "profile",
          structured_output: profile.structured_output == "probe" ? r.structured_output : profile.structured_output,
          tool_calls: profile.tool_calls == "probe" ? r.tool_calls : profile.tool_calls,
          thinking_control: profile.thinking.control == "probe" ? r.thinking_control : profile.thinking.control
        )
      end

      # One chat request; nil when the server could not be reached.
      # @return [Http::Response, nil]
      def chat(profile, id, prompt, extra, max_tokens)
        body = { "model" => id, "messages" => [{ "role" => "user", "content" => prompt }],
                 "max_tokens" => max_tokens, "stream" => false }.merge(extra)
        @http.post("#{profile.base_url}/chat/completions", body, headers: Probe.headers(profile, @env), timeout: @timeout)
      rescue ModelUnavailableError
        nil
      end

      # @return [Hash, nil] choices[0].message of a successful reply
      def message(res)
        return nil unless res&.ok? && res.json.is_a?(Hash)

        msg = res.json.dig("choices", 0, "message")
        msg.is_a?(Hash) ? msg : nil
      end

      # @return [Array(Integer, String)] context size and where it came from
      def context_of(profile, id, entry)
        meta = entry["meta"].is_a?(Hash) ? entry["meta"]["n_ctx"] : nil
        listed = [meta, entry["context_length"], entry["max_model_len"], entry["loaded_context_length"]]
                 .find { |v| v.is_a?(Integer) && v.positive? }
        return [listed, "models"] if listed

        res = chat(profile, id, "x " * 400_000, {}, 1)
        text = res && !res.ok? ? res.error_text : ""
        found = CONTEXT_PATTERNS.lazy.filter_map { |re| text[re, 1]&.to_i }.first
        found ? [found, "overflow"] : [DEFAULT_CONTEXT, "default"]
      end

      # "Reply with OK" once plainly and once per control set to off; the shortest non-empty answer wins.
      # @return [Array(String, String)] thinking control and where reasoning appears
      def thinking_of(profile, id)
        base = chat(profile, id, "Reply with OK", {}, 400)
        base_len = answer_length(base)
        best = Wire::THINKING_OFF.keys.reject { |c| c == "none" }.filter_map do |control|
          len = answer_length(chat(profile, id, "Reply with OK", Wire::THINKING_OFF[control], 400))
          [control, len] if len
        end.min_by { |_, len| len }
        control = best && (base_len.nil? || best[1] < base_len * 0.8) ? best[0] : "none"
        [control, reasoning_of(message(base))]
      end

      # @return [Integer, nil] completion tokens of a usable answer, nil when there is none
      def answer_length(res)
        msg = message(res)
        return nil unless msg

        answer, inline, = Wire.split_thinking(msg["content"])
        return nil if answer.empty?

        used = res.json.dig("usage", "completion_tokens")
        used.is_a?(Integer) ? used : Tokens.estimate("#{msg['content']}#{msg['reasoning_content']}#{inline}")
      end

      # @return [String] separate, inline or none
      def reasoning_of(msg)
        return "none" unless msg
        return "separate" if [msg["reasoning_content"], msg["reasoning"]].any? { |r| r.is_a?(String) && !r.empty? }

        msg["content"].to_s.include?("<think>") ? "inline" : "none"
      end

      # @return [String] json_schema, json_object or prompt
      def structured_of(profile, id, off)
        schema = { "type" => "json_schema", "json_schema" => { "name" => "probe", "strict" => true, "schema" => JSON_SCHEMA } }
        return "json_schema" if json_reply?(chat(profile, id, JSON_PROMPT, off.merge("response_format" => schema), 200))

        object_prompt = "#{JSON_PROMPT} Reply in JSON with a boolean field named yes."
        return "json_object" if json_reply?(chat(profile, id, object_prompt, off.merge("response_format" => { "type" => "json_object" }), 200))

        "prompt"
      end

      # @return [Boolean] the reply is exactly a JSON object with a boolean "yes"
      def json_reply?(res)
        msg = message(res)
        return false unless msg

        value = JSON.parse(Wire.split_thinking(msg["content"]).first)
        value.is_a?(Hash) && [true, false].include?(value["yes"])
      rescue JSON::ParserError
        false
      end

      # @return [String] native or none
      def tools_of(profile, id, off)
        msg = message(chat(profile, id, "Call the record_value tool with value 42.", off.merge("tools" => [TOOL]), 200))
        calls = msg && msg["tool_calls"]
        ok = calls.is_a?(Array) && calls.any? { |c| c.is_a?(Hash) && c.dig("function", "name") == "record_value" }
        ok ? "native" : "none"
      end

      # @return [Array(Float, Float)] prompt and generation tokens per second (nil when unknown)
      def throughput(profile, id, off)
        started = @clock.call
        res = chat(profile, id, "#{FILLER * 55}\nCount from 1 to 40, separated by spaces.", off, 160)
        secs = @clock.call - started
        return [nil, nil] unless message(res)

        timings = res.json["timings"].is_a?(Hash) ? res.json["timings"] : {}
        out = res.json.dig("usage", "completion_tokens")
        gen = timings["predicted_per_second"] || (out.is_a?(Integer) && secs.positive? ? out / secs : nil)
        [timings["prompt_per_second"]&.to_f&.round(1), gen&.to_f&.round(1)]
      end
    end
  end
end
