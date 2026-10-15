# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "minitest/autorun"
require_relative "../lib/harness"

module TestSupport
  ROOT = File.expand_path("..", __dir__)

  # Minimal output stream for code that only calls puts (stringio is not on the I14 allowlist).
  class Sink
    # @return [String] everything written so far
    attr_reader :string

    def initialize
      @string = +""
    end

    # @param lines [Array<Object>]
    # @return [nil]
    def puts(*lines)
      lines = [""] if lines.empty?
      lines.flatten.each { |l| @string << l.to_s << (l.to_s.end_with?("\n") ? "" : "\n") }
      nil
    end
  end

  # Capabilities a test client starts with; override per test with caps:.
  CAPS = {
    model_id: "test-model", context_tokens: 16_384, context_source: "models", structured_output: "json_schema",
    tool_calls: "native", thinking_control: "chat_template_kwargs", reasoning: "separate", prompt_tps: nil, gen_tps: nil
  }.freeze

  # @param base_url [String]
  # @param profile [Hash] extra profile JSON fields
  # @return [Harness::Config] one "default" profile behind every role
  def self.config(base_url, **profile)
    Harness::Config.parse({ "profiles" => { "default" => { "baseUrl" => base_url }.merge(profile.transform_keys(&:to_s)) } })
  end

  # A client against base_url with fixed capabilities (no probing), records and logs under dir.
  # @return [Harness::Model::Client]
  def self.client(base_url, dir, caps: {}, profile: {}, env: {})
    result = Harness::Model::Probe::Result.new(**CAPS.merge(caps))
    Harness::Model::Client.new(
      config: config(base_url, **profile), probe: ->(_profile) { result }, http: Harness::Model::Http.new,
      records: Harness::State::Records.new(File.join(dir, "records")), log: Harness::Log.new(dir: File.join(dir, "logs")),
      env: env, sleeper: ->(_seconds) {}
    )
  end

  # @return [Hash{String=>String}] a minimal environment for test subprocesses
  def self.child_env
    %w[PATH PATHEXT SystemRoot COMSPEC TEMP TMP TMPDIR HOME USERPROFILE LANG].each_with_object({}) do |k, env|
      env[k] = ENV[k] if ENV[k]
    end
  end
end
