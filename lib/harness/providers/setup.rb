# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../config"
require_relative "../errors"
require_relative "../state/records"

module Harness
  module Providers
    # Writes a chosen provider and model into config.json as a profile (DESIGN.md 11.2). The model id comes from
    # the server; nothing about specific models is built in (I1). The first provider set up takes every role.
    module Setup
      EXAMPLE = File.expand_path("../../../config.example.json", __dir__)
      NAME = /\A[a-z][a-z0-9-]{0,31}\z/
      KEY_ENV = /\A[A-Z_][A-Z0-9_]{0,63}\z/

      # @param path [String] config.json
      # @param name [String] profile name, e.g. "lmstudio"
      # @param base_url [String]
      # @param model [String] an id the server listed, or "auto"
      # @param key_env [String, nil] the env var holding the key (never the key, I12)
      # @return [Hash] the written config
      # @raise [ParseError] when the result is not a valid config
      def self.use(path:, name:, base_url:, model:, key_env: nil)
        raise ParseError, "profile name #{name.inspect}" unless name.match?(NAME)
        raise ParseError, "apiKeyEnv must name an env var, not hold a key" if key_env && !key_env.match?(KEY_ENV)

        fresh = !File.file?(path)
        cfg = JSON.parse(File.read(fresh ? EXAMPLE : path, encoding: "UTF-8"))
        template = JSON.parse(File.read(EXAMPLE, encoding: "UTF-8"))["profiles"]["default"]
        profile = (cfg["profiles"][name] || template).merge("baseUrl" => base_url.chomp("/"), "model" => model, "apiKeyEnv" => key_env)
        if fresh
          cfg["profiles"] = { name => profile }
          cfg["roles"] = cfg["roles"].transform_values { name }
        else
          cfg["profiles"][name] = profile
        end
        Config.parse(cfg)
        State.write_json(path, cfg)
        cfg
      end
    end
  end
end
