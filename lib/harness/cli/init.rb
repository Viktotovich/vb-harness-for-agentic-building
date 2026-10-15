# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "uri"
require_relative "../config"
require_relative "../errors"
require_relative "../model/http"
require_relative "../state/records"

module Harness
  module CLI
    # harness init: write config.json from config.example.json, asking a few questions. The questions are ported
    # from REVIEWER src/setup/wizard.js (endpoint, model, docs); the target repository is given per run, so it is
    # not asked. Provider detection arrives with onboarding (M8). Keys are never typed in: only the name of the
    # env var that holds one (I12).
    class Init
      # Raised when input ends before the questions are answered.
      class Cancelled < StandardError; end

      ENV_NAME = /\A[A-Z_][A-Z0-9_]{0,63}\z/
      CONTEXT = /\A(?:probe|\d{3,7})\z/
      EXAMPLE = File.expand_path("../../../config.example.json", __dir__)

      # @param input [#gets]
      # @param out [IO] where questions and the summary go
      # @param http [Model::Http]
      # @param path [String] the config.json to write
      # @param env [Hash{String=>String}] read only for the key named by apiKeyEnv, to list the server's models
      def initialize(input:, out:, path:, http: Model::Http.new, env: ENV)
        @input = input
        @out = out
        @http = http
        @path = path
        @env = env
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
        profile["baseUrl"] = ask("Server URL", profile["baseUrl"]) { |s| url_problem(s) }.chomp("/")
        key = ask("Name of the env var holding an API key (empty if the server needs none)", profile["apiKeyEnv"].to_s) do |s|
          s.empty? || s.match?(ENV_NAME) ? nil : "an env var name such as MY_SERVER_KEY, not the key itself"
        end
        profile["apiKeyEnv"] = key.empty? ? nil : key
        profile["model"] = pick_model(profile["baseUrl"], profile["model"], profile["apiKeyEnv"])
        context = ask("Context length in tokens, or \"probe\" to measure it", profile["contextTokens"].to_s) { |s| s.match?(CONTEXT) ? nil : "a number, or probe" }
        profile["contextTokens"] = context == "probe" ? "probe" : context.to_i

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
        summary(profile, docs)
        return 1 unless yes?("Write #{File.basename(@path)}", true)

        State.write_json(@path, cfg)
        say "Wrote #{@path}"
        0
      end

      private

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
      def summary(profile, docs)
        say "\nSummary"
        say "  server       #{profile['baseUrl']}"
        say "  model        #{profile['model']}"
        say "  context      #{profile['contextTokens']}"
        say "  api key env  #{profile['apiKeyEnv'] || 'none'}"
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
