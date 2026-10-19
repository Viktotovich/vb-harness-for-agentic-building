# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../config"
require_relative "../errors"
require_relative "../modes"
require_relative "../state/records"

module Harness
  module Providers
    # Writes a chosen provider and model into config.json as a profile (DESIGN.md 11.2). The model id comes from
    # the server; nothing about specific models is built in (I1). The first provider set up takes every role, and a
    # new config starts in the default mode (Modes::DEFAULT), as `harness init` does.
    module Setup
      EXAMPLE = File.expand_path("../../../config.example.json", __dir__)
      NAME = /\A[a-z][a-z0-9-]{0,31}\z/
      KEY_ENV = /\A[A-Z_][A-Z0-9_]{0,63}\z/

      # @param path [String] config.json
      # @param name [String] profile name, e.g. "lmstudio"
      # @param base_url [String]
      # @param model [String] an id the server listed, or "auto"
      # @param key_env [String, nil] the env var holding the key (never the key, I12)
      # @param second [Boolean] write it as the second model (profile Modes::SECOND), for the planner and reviewers
      # @return [Hash] the written config
      # @raise [ParseError] when the result is not a valid config, or a second model comes before a first
      def self.use(path:, name:, base_url:, model:, key_env: nil, second: false)
        raise ParseError, "profile name #{name.inspect}" unless name.match?(NAME)
        raise ParseError, "apiKeyEnv must name an env var, not hold a key" if key_env && !key_env.match?(KEY_ENV)

        fresh = !File.file?(path)
        raise ParseError, "set up a first model before a second one" if fresh && second

        name = Modes::SECOND if second
        cfg = JSON.parse(File.read(fresh ? EXAMPLE : path, encoding: "UTF-8"))
        template = JSON.parse(File.read(EXAMPLE, encoding: "UTF-8"))["profiles"]["default"]
        profile = (cfg["profiles"][name] || template).merge("baseUrl" => base_url.chomp("/"), "model" => model, "apiKeyEnv" => key_env)
        if fresh
          cfg["profiles"] = { name => profile }
          cfg["roles"] = cfg["roles"].transform_values { name }
          Modes.apply(cfg, Modes::DEFAULT)
        else
          cfg["profiles"][name] = profile
        end
        Modes.assign_second(cfg, name) if second
        write(path, cfg)
      end

      # Change the mode, or which profile the planner and reviewers use, from the app's Settings.
      # @param path [String] config.json, which must exist
      # @param mode [String, nil] a Modes::ALL key; nil leaves the mode alone
      # @param second [String, nil, false] a profile name; nil for the implementer's own; false leaves it alone
      # @return [Hash] the written config
      # @raise [ParseError] for an unknown mode or profile
      # @raise [ConfigError] when there is no config yet
      def self.update(path:, mode: nil, second: false)
        raise ConfigError, "set up a model provider first (Settings)" unless File.file?(path)

        cfg = JSON.parse(File.read(path, encoding: "UTF-8"))
        Modes.apply(cfg, mode) if mode
        Modes.assign_second(cfg, second) unless second == false
        write(path, cfg)
      end

      # @return [Hash] cfg, after it parsed as a valid config
      def self.write(path, cfg)
        Config.parse(cfg)
        State.write_json(path, cfg)
        cfg
      end
      private_class_method :write
    end
  end
end
