# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "uri"
require_relative "../config"
require_relative "../errors"
require_relative "../model/http"
require_relative "../providers/detect"
require_relative "../state/records"

module Harness
  module CLI
    # harness init: write config.json from config.example.json, asking a few questions. The questions are ported
    # from REVIEWER src/setup/wizard.js (endpoint, model, docs); the target repository is given per run, so it is
    # not asked. LM Studio and Ollama found on this machine are offered first. Keys are never typed in: only the name of the
    # env var that holds one (I12). Then a mode (Careful, Balanced or Quick, see MODES) and whether a second model
    # takes the planner and reviewers.
    class Init
      # Raised when input ends before the questions are answered.
      class Cancelled < StandardError; end

      ENV_NAME = /\A[A-Z_][A-Z0-9_]{0,63}\z/
      CONTEXT = /\A(?:probe|\d{3,7})\z/
      EXAMPLE = File.expand_path("../../../config.example.json", __dir__)
      # Presets for how careful a run is: a name, what it means, and the settings it writes. Any value can still be
      # edited in config.json afterwards.
      MODES = {
        "careful" => ["Careful", "review every task and the whole run, and stop when the repository's own checks " \
                                 "already fail before the run", { "review" => "full", "requireGreenBaseline" => true, "maxFixRounds" => 3 }],
        "balanced" => ["Balanced", "skip the review of small tasks that pass their checks first time; the whole run " \
                                   "is still reviewed", { "review" => "light", "requireGreenBaseline" => false, "maxFixRounds" => 3 }],
        "quick" => ["Quick", "no review and fewer fix rounds, for trying things out",
                    { "review" => "off", "requireGreenBaseline" => false, "maxFixRounds" => 2 }]
      }.freeze
      DEFAULT_MODE = "balanced"
      # With two models, these roles use the second one; the implementer, fixer and summarizer keep the first.
      SECOND_ROLES = %w[planner reviewer verifier].freeze
      SECOND = "planning"

      # @param input [#gets]
      # @param out [IO] where questions and the summary go
      # @param http [Model::Http]
      # @param path [String] the config.json to write
      # @param env [Hash{String=>String}] read only for the key named by apiKeyEnv, to list the server's models
      # @param detect [#call, nil] -> Array<Providers::Provider>; nil looks for LM Studio and Ollama
      def initialize(input:, out:, path:, http: Model::Http.new, env: ENV, detect: nil)
        @input = input
        @out = out
        @http = http
        @path = path
        @env = env
        @detect = detect || -> { Providers::Detect.local(http: @http, env: @env) }
      end

      # @return [Integer] exit code: 0 written, 1 not written
      # @raise [Cancelled] when input ends
      # @raise [ParseError] when the result would not be a valid config
      def call
        template = JSON.parse(File.read(EXAMPLE, encoding: "UTF-8"))
        base = template
        if File.file?(@path)
          current = JSON.parse(File.read(@path, encoding: "UTF-8"))
          base = current if yes?("#{File.basename(@path)} already exists. Use its values as the defaults", true)
        end
        cfg = JSON.parse(JSON.generate(base))
        profile = cfg["profiles"]["default"] ||= JSON.parse(JSON.generate(template["profiles"]["default"]))

        say "\nModel server (any OpenAI-compatible endpoint, such as LM Studio or Ollama)"
        found = @detect.call.select(&:up)
        found.each { |p| say "  Found #{p.label} at #{p.base_url} (#{p.models.empty? ? p.error : "#{p.models.size} models"})" }
        default_url = base.equal?(template) && found.first ? found.first.base_url : profile["baseUrl"]
        profile["baseUrl"] = ask("Server URL", default_url) { |s| url_problem(s) }.chomp("/")
        profile["apiKeyEnv"] = ask_key_env(profile["apiKeyEnv"])
        profile["model"] = pick_model(profile["baseUrl"], profile["model"], profile["apiKeyEnv"])
        context = ask("Context length in tokens, or \"probe\" to measure it", profile["contextTokens"].to_s) { |s| s.match?(CONTEXT) ? nil : "a number, or probe" }
        profile["contextTokens"] = context == "probe" ? "probe" : context.to_i
        mode = pick_mode(cfg, base.equal?(template))
        second = pick_models(cfg, profile)

        say "\nDocumentation (optional). Without a local docs checkout, framework claims in reviews abstain instead of"
        say "being confirmed, because nothing can check them."
        docs = cfg.dig("stacks", "astro", "docs")
        if docs
          local = ask("Path to a checkout of the framework docs (empty to skip)", docs["local"].to_s) do |s|
            s.empty? || File.directory?(File.join(s, "src", "content", "docs", "en")) ? nil : "no src/content/docs/en there; check the path"
          end
          docs["local"] = local.empty? ? nil : local
        end

        Config.parse(cfg) # raises on anything invalid, before writing
        summary(cfg, profile, docs, mode, second)
        return 1 unless yes?("Write #{File.basename(@path)}", true)

        State.write_json(@path, cfg)
        say "Wrote #{@path}"
        0
      end

      private

      # @param current [String, nil]
      # @return [String, nil] the name of the env var that holds the key, never the key (I12)
      def ask_key_env(current)
        key = ask("Name of the env var holding an API key (empty if the server needs none)", current.to_s) do |s|
          s.empty? || s.match?(ENV_NAME) ? nil : "an env var name such as MY_SERVER_KEY, not the key itself"
        end
        key.empty? ? nil : key
      end

      # Writes a preset's settings into cfg. An existing config whose settings match no preset can keep them.
      # @param cfg [Hash]
      # @param fresh [Boolean] cfg comes from the example, not an existing config.json
      # @return [String, nil] the preset chosen, nil when the current settings were kept
      def pick_mode(cfg, fresh)
        keys = MODES.keys
        current = keys.find { |k| MODES[k][2].all? { |f, v| cfg[f] == v } } unless fresh
        options = MODES.values.map { |name, text, _| "#{name}: #{text}" }
        keep = !fresh && current.nil?
        options << "Keep the current settings (review #{cfg['review'] || 'full'})" if keep
        default = keep ? options.size : keys.index(current || DEFAULT_MODE) + 1
        say "\nHow careful should runs be?"
        options.each_with_index { |o, i| say "  #{i + 1}) #{o}" }
        n = ask("Mode", default.to_s) { |s| s.match?(/\A\d+\z/) && s.to_i.between?(1, options.size) ? nil : "pick 1-#{options.size}" }.to_i
        return nil if n > keys.size

        cfg.merge!(MODES[keys[n - 1]][2])
        keys[n - 1]
      end

      # One model for every role, or a second one (often larger) for the planner and reviewers.
      # @param cfg [Hash]
      # @param profile [Hash] the first model's profile, already answered
      # @return [String, nil] the second profile's name, nil for one model
      def pick_models(cfg, profile)
        roles = cfg["roles"] ||= {}
        now = roles["planner"] if roles["planner"] && roles["planner"] != "default" && cfg["profiles"][roles["planner"]]
        say "\nOne model for everything, or a second model for planning and review?"
        say "  1) One model for every role"
        say "  2) Two models: the planner and reviewers use the second (often a larger one), the implementer and fixer the first"
        n = ask("Models", now ? "2" : "1") { |s| %w[1 2].include?(s) ? nil : "pick 1-2" }
        return one_model(cfg, roles) if n == "1"

        name = now || SECOND
        second = cfg["profiles"][name] ||= JSON.parse(JSON.generate(profile)).merge("contextTokens" => "probe")
        say "\nThe second model (planner, reviewer and verifier)"
        second["baseUrl"] = ask("Server URL", second["baseUrl"]) { |s| url_problem(s) }.chomp("/")
        second["apiKeyEnv"] = ask_key_env(second["apiKeyEnv"])
        second["model"] = pick_model(second["baseUrl"], second["model"], second["apiKeyEnv"])
        if second.values_at("baseUrl", "model") == profile.values_at("baseUrl", "model")
          say "  That is the first model again, so every role uses it."
          return one_model(cfg, roles)
        end
        SECOND_ROLES.each { |r| roles[r] = name }
        name
      end

      # @return [nil]
      def one_model(cfg, roles)
        SECOND_ROLES.each { |r| roles[r] = "default" }
        cfg["profiles"].delete(SECOND) unless roles.value?(SECOND)
        nil
      end

      # @return [String]
      def pick_model(base_url, current, key_env)
        key = key_env && @env[key_env]
        res = @http.get("#{base_url}/models", headers: key ? { "Authorization" => "Bearer #{key}" } : {}, timeout: 5)
        ids = res.ok? && res.json.is_a?(Hash) ? Array(res.json["data"]).filter_map { |m| m["id"] if m.is_a?(Hash) } : []
        if ids.empty?
          say "  Could not list models (#{res.ok? ? 'none found' : res.error_text}). Type the model id the server uses, or auto."
          return ask("Model id", current.to_s.empty? ? "auto" : current) { |s| s.empty? ? "required" : nil }
        end

        options = ids + ["auto (whichever model the server has loaded at run time)"]
        default = current == "auto" || !ids.include?(current) ? options.size : ids.index(current) + 1
        say "Models the server has:"
        options.each_with_index { |o, i| say "  #{i + 1}) #{o}" }
        n = ask("Model", default.to_s) { |s| s.match?(/\A\d+\z/) && s.to_i.between?(1, options.size) ? nil : "pick 1-#{options.size}" }.to_i
        n == options.size ? "auto" : ids[n - 1]
      rescue ModelUnavailableError, SystemCallError => e
        say "  Could not reach the server (#{e.message[0, 120]}). Type the model id, or auto."
        ask("Model id", current.to_s.empty? ? "auto" : current) { |s| s.empty? ? "required" : nil }
      end

      # @return [String, nil]
      def url_problem(s)
        uri = URI.parse(s)
        %w[http https].include?(uri.scheme) && uri.host ? nil : "an http(s) URL such as http://127.0.0.1:8080/v1"
      rescue URI::InvalidURIError
        "not a URL"
      end

      # @return [void]
      def summary(cfg, profile, docs, mode, second)
        say "\nSummary"
        say "  server       #{profile['baseUrl']}"
        say "  model        #{profile['model']}"
        say "  context      #{profile['contextTokens']}"
        say "  api key env  #{profile['apiKeyEnv'] || 'none'}"
        if second
          p = cfg["profiles"][second]
          say "  second model #{p['model']} at #{p['baseUrl']} (#{SECOND_ROLES.join(', ')})"
        end
        say "  mode         #{mode ? MODES[mode][0] : 'current settings'} (review #{cfg['review'] || 'full'})"
        say "  docs         #{docs && docs['local'] ? docs['local'] : 'none (framework claims will abstain)'}"
      end

      # Asks until the block returns nil (no problem) for the answer.
      # @return [String]
      # @raise [Cancelled]
      def ask(question, default)
        loop do
          shown = default.to_s.empty? ? "" : " [#{default}]"
          @out.print("#{question}#{shown}: ")
          line = @input.gets
          raise Cancelled, "init cancelled (input ended)" if line.nil?

          answer = line.strip
          answer = default.to_s if answer.empty?
          problem = block_given? ? yield(answer) : nil
          return answer unless problem

          say "  #{problem}"
        end
      end

      # @return [Boolean]
      def yes?(question, default)
        ask("#{question} (y/n)", default ? "y" : "n") { |s| s.match?(/\A(?:y|yes|n|no)\z/i) ? nil : "answer y or n" }.match?(/\Ay/i)
      end

      # @return [void]
      def say(text)
        @out.puts(text)
      end
    end
  end
end
