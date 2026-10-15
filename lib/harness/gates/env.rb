# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  module Gates
    # The environment for gate and git subprocesses (I5, DESIGN.md 9.3): an allowlisted base, NODE_*
    # variables, the names in config gateEnvAllow, and CI=1. Children run with unsetenv_others, so nothing
    # else reaches them.
    module Env
      BASE = %w[PATH PATHEXT HOME USERPROFILE SystemRoot COMSPEC TEMP TMP APPDATA LOCALAPPDATA LANG].freeze
      SECRET = /TOKEN|SECRET|KEY|PASSWORD|^GH_|^GITHUB_|^AWS_|^AZURE_|^GOOGLE_|^OPENAI_|^ANTHROPIC_/i
      # Fixed values: CI mode, and npx must never download a missing package on its own (I10).
      FIXED = { "CI" => "1", "npm_config_yes" => "false" }.freeze

      # @param parent [Hash{String=>String}, ENV] the harness's own environment
      # @param allow [Array<String>] config gateEnvAllow: names passed through even if they look secret
      # @return [Hash{String=>String}] the complete child environment
      def self.build(parent, allow: [])
        source = parent.to_h
        out = {}
        BASE.each { |name| (v = lookup(source, name)) && out[name] = v }
        source.each do |k, v|
          up = k.upcase
          next unless up.start_with?("NODE_")
          next if up == "NODE_OPTIONS" && !allowed?(k, allow)

          out[k] = v
        end
        allow.each { |name| (v = lookup(source, name)) && out[name] = v }
        out.reject! { |k, _| k.match?(SECRET) && !allowed?(k, allow) }
        out.merge(FIXED)
      end

      # @return [String, nil] the value for name, matched case-insensitively (Windows "Path")
      def self.lookup(source, name)
        return source[name] if source.key?(name)

        pair = source.find { |k, _| k.casecmp?(name) }
        pair && pair[1]
      end

      # @return [Boolean]
      def self.allowed?(name, allow)
        allow.any? { |a| a.casecmp?(name) }
      end
      private_class_method :lookup, :allowed?
    end
  end
end
