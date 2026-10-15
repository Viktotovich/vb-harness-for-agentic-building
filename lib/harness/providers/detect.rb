# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../exec"
require_relative "../model/http"

module Harness
  module Providers
    # One provider as found on this machine. up: its server answered; models: ids it serves (LM Studio, custom)
    # or has pulled (Ollama); cli: argv prefix of its command-line tool, or nil; error: why it is not usable.
    Provider = Data.define(:kind, :label, :base_url, :up, :models, :cli, :error) do
      # @return [Hash]
      def to_json_hash
        { "kind" => kind, "label" => label, "baseUrl" => base_url, "up" => up, "models" => models, "cli" => !cli.nil?, "error" => error }
      end
    end

    # Provider detection for onboarding (DESIGN.md 11.2): LM Studio and Ollama are looked for in parallel, each
    # with a 2 s timeout; a custom OpenAI-compatible URL is probed on request. Nothing is installed or started here.
    module Detect
      TIMEOUT = 2
      LMSTUDIO_URL = "http://127.0.0.1:1234/v1"
      OLLAMA_URL = "http://127.0.0.1:11434"

      # @param http [Model::Http]
      # @param env [Hash{String=>String}] PATH, PATHEXT and the home folder, to find lms and ollama
      # @param clis [Hash{String=>Array<String>}] argv prefixes to use instead of looking ("lms", "ollama")
      # @param urls [Hash{String=>String}] base URLs to use instead of the defaults ("lmstudio", "ollama"), for tests
      # @return [Array<Provider>] LM Studio, then Ollama
      def self.local(http:, env: ENV, clis: {}, urls: {})
        lms = urls.fetch("lmstudio", LMSTUDIO_URL)
        oll = urls.fetch("ollama", OLLAMA_URL)
        [Thread.new { lmstudio(http, env, clis, lms) }, Thread.new { ollama(http, env, clis, oll) }].map(&:value)
      end

      # @param http [Model::Http]
      # @param base_url [String] an OpenAI-compatible base URL
      # @param key [String, nil] the API key, read by the caller from the env var the user named (I12)
      # @return [Provider]
      def self.custom(http:, base_url:, key: nil)
        ids, error = list_models(http, base_url, key ? { "Authorization" => "Bearer #{key}" } : {})
        Provider.new(kind: "custom", label: "Custom", base_url: base_url, up: error.nil?, models: ids, cli: nil, error: error)
      end

      # @return [Provider]
      def self.lmstudio(http, env, clis, url)
        ids, error = list_models(http, url, {})
        cli = clis["lms"] || find_cli("lms", env, home_bin(env, ".lmstudio", "lms"))
        error ||= "no model is loaded" if ids.empty?
        Provider.new(kind: "lmstudio", label: "LM Studio", base_url: url, up: ids.any? || error == "no model is loaded",
                     models: ids, cli: cli, error: error)
      end

      # @return [Provider]
      def self.ollama(http, env, clis, url)
        res = http.get("#{url}/api/tags", timeout: TIMEOUT)
        names = res.ok? && res.json.is_a?(Hash) ? Array(res.json["models"]).filter_map { |m| m["name"] if m.is_a?(Hash) } : []
        error = res.ok? ? (names.empty? ? "no model is pulled" : nil) : "HTTP #{res.status}"
        Provider.new(kind: "ollama", label: "Ollama", base_url: "#{url}/v1", up: res.ok?, models: names,
                     cli: clis["ollama"] || find_cli("ollama", env, nil), error: error)
      rescue ModelUnavailableError => e
        Provider.new(kind: "ollama", label: "Ollama", base_url: "#{url}/v1", up: false, models: [],
                     cli: clis["ollama"] || find_cli("ollama", env, nil), error: e.message)
      end

      # @return [Array(Array<String>, String)] model ids, and an error or nil
      def self.list_models(http, base_url, headers)
        res = http.get("#{base_url}/models", headers: headers, timeout: TIMEOUT)
        return [[], "HTTP #{res.status}: #{res.error_text[0, 200]}"] unless res.ok?

        [Array(res.json.is_a?(Hash) ? res.json["data"] : nil).filter_map { |m| m["id"] if m.is_a?(Hash) && m["id"].is_a?(String) }, nil]
      rescue ModelUnavailableError => e
        [[], e.message]
      end

      # @return [Array<String>, nil] the tool as an argv prefix
      def self.find_cli(name, env, fallback)
        found = Exec.resolve(name, path: env["PATH"] || env["Path"], pathext: env["PATHEXT"])
        return [found] if found

        fallback && File.file?(fallback) ? [fallback] : nil
      end

      # @return [String, nil] e.g. ~/.lmstudio/bin/lms(.exe)
      def self.home_bin(env, dir, name)
        home = env["USERPROFILE"] || env["HOME"]
        return nil unless home

        File.join(home, dir, "bin", Exec.windows? ? "#{name}.exe" : name)
      end
      private_class_method :lmstudio, :ollama, :list_models, :find_cli, :home_bin
    end
  end
end
