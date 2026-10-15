# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../parse"

module Harness
  module Model
    ROLES = %i[planner implementer fixer reviewer verifier summarizer].freeze
    # Roles that fall back to another role when config["roles"] does not name them (DESIGN.md 4.1).
    ROLE_DEFAULTS = { fixer: :implementer, verifier: :reviewer, summarizer: :implementer }.freeze

    THINKING_CONTROLS = %w[probe chat_template_kwargs reasoning_effort budget none].freeze
    STRUCTURED_MODES = %w[probe json_schema json_object prompt].freeze
    TOOL_MODES = %w[probe native none].freeze

    PROFILE_KEYS = %w[baseUrl model apiKeyEnv contextTokens maxOutputTokens temperature thinking structuredOutput
                      toolCalls concurrency timeoutSec promptNotes swap fallback].freeze
    ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/

    Thinking = Data.define(:control, :effort, :budget_tokens)
    Swap = Data.define(:start, :stop, :ready_timeout_sec)

    # One model endpoint and how to talk to it (DESIGN.md 4.2). Values set to "probe" come from the probe.
    Profile = Data.define(
      :name, :base_url, :model, :api_key_env, :context_tokens, :max_output_tokens, :temperature, :thinking,
      :structured_output, :tool_calls, :concurrency, :timeout_sec, :prompt_notes, :swap, :fallback
    ) do
      # Parse one entry of config["profiles"].
      # @param name [String] profile name
      # @param raw [Hash] JSON object
      # @return [Profile]
      # @raise [ParseError]
      def self.parse(name, raw)
        path = "profiles.#{name}"
        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, PROFILE_KEYS, path)
        new(
          name: name,
          base_url: parse_url(h["baseUrl"], "#{path}.baseUrl"),
          model: Parse.str!(h.fetch("model", "auto"), "#{path}.model"),
          api_key_env: parse_key_env(h["apiKeyEnv"], "#{path}.apiKeyEnv"),
          context_tokens: probe_or_int(h.fetch("contextTokens", "probe"), "#{path}.contextTokens", 256),
          max_output_tokens: Parse.int!(h.fetch("maxOutputTokens", 4000), "#{path}.maxOutputTokens", min: 16),
          temperature: parse_temperature(h["temperature"], "#{path}.temperature"),
          thinking: parse_thinking(h.fetch("thinking", {}), "#{path}.thinking"),
          structured_output: Parse.enum!(h.fetch("structuredOutput", "probe"), "#{path}.structuredOutput",
                                         STRUCTURED_MODES),
          tool_calls: Parse.enum!(h.fetch("toolCalls", "probe"), "#{path}.toolCalls", TOOL_MODES),
          concurrency: Parse.int!(h.fetch("concurrency", 1), "#{path}.concurrency", min: 1),
          timeout_sec: Parse.int!(h.fetch("timeoutSec", 900), "#{path}.timeoutSec", min: 1),
          prompt_notes: h["promptNotes"].nil? ? nil : Parse.str!(h["promptNotes"], "#{path}.promptNotes"),
          swap: parse_swap(h.fetch("swap", {}), "#{path}.swap"),
          fallback: h["fallback"].nil? ? nil : Parse.str!(h["fallback"], "#{path}.fallback")
        )
      end

      # @return [String] base URL without trailing slash
      def self.parse_url(value, path)
        Parse.fail!(path, "http(s) URL", value) unless value.is_a?(String) && value.match?(%r{\Ahttps?://[^\s/]+})
        value.sub(%r{/+\z}, "")
      end

      # @return [String, nil] the NAME of an environment variable (I12), never the key itself
      def self.parse_key_env(value, path)
        return nil if value.nil?
        return value if value.is_a?(String) && value.match?(ENV_NAME)

        raise ParseError, "#{path}: expected the name of an environment variable that holds the key " \
                          "(letters, digits, underscore), not the key itself"
      end

      # @return [String, Integer] "probe" or an integer >= min
      def self.probe_or_int(value, path, min)
        value == "probe" ? value : Parse.int!(value, path, min: min)
      end

      # @return [Float, Integer, nil]
      def self.parse_temperature(value, path)
        return nil if value.nil?

        Parse.fail!(path, "number between 0 and 2, or null", value) unless value.is_a?(Numeric) && value.between?(0, 2)
        value
      end

      # @return [Thinking]
      def self.parse_thinking(raw, path)
        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, %w[control effort budgetTokens], path)
        budget = h["budgetTokens"]
        Thinking.new(
          control: Parse.enum!(h.fetch("control", "probe"), "#{path}.control", THINKING_CONTROLS),
          effort: Parse.str!(h.fetch("effort", "low"), "#{path}.effort"),
          budget_tokens: budget.nil? ? nil : Parse.int!(budget, "#{path}.budgetTokens", min: 0)
        )
      end

      # @return [Swap] start and stop are argv arrays from config, never model output
      def self.parse_swap(raw, path)
        h = Parse.hash!(raw, path)
        Parse.known_keys!(h, %w[start stop readyTimeoutSec], path)
        argv = lambda do |key|
          v = h[key]
          next nil if v.nil?

          Parse.strings!(v, "#{path}.#{key}")
          Parse.fail!("#{path}.#{key}", "non-empty argv array", v) if v.empty?
          v.dup.freeze
        end
        Swap.new(start: argv.call("start"), stop: argv.call("stop"),
                 ready_timeout_sec: Parse.int!(h.fetch("readyTimeoutSec", 300), "#{path}.readyTimeoutSec", min: 1))
      end
      private_class_method :parse_url, :parse_key_env, :probe_or_int, :parse_temperature, :parse_thinking,
                           :parse_swap
    end

    # Resolves a role to its profile name (DESIGN.md 4.1). Code never branches on which model is behind a role.
    module Roles
      # @param raw [Hash, nil] config["roles"]
      # @param profile_names [Array<String>]
      # @return [Hash{Symbol=>String}] every role mapped to an existing profile
      # @raise [ParseError]
      def self.parse(raw, profile_names)
        h = Parse.hash!(raw || {}, "roles")
        Parse.known_keys!(h, ROLES.map(&:to_s), "roles")
        h.each { |role, name| check_name!(name, "roles.#{role}", profile_names) }
        ROLES.to_h { |role| [role, resolve(role, h, profile_names)] }
      end

      # @return [String]
      def self.resolve(role, h, profile_names)
        named = h[role.to_s]
        return named if named

        fallback = ROLE_DEFAULTS[role]
        return resolve(fallback, h, profile_names) if fallback
        return "default" if profile_names.include?("default")

        raise ParseError, "roles.#{role}: not set, and there is no profile named \"default\""
      end

      # @return [void]
      def self.check_name!(name, path, profile_names)
        Parse.str!(name, path)
        return if profile_names.include?(name)

        raise ParseError, "#{path}: no profile named #{name.inspect} (profiles: #{profile_names.join(', ')})"
      end
      private_class_method :resolve
    end
  end
end
