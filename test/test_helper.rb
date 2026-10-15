# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "minitest/autorun"
require_relative "../lib/harness"
require "fileutils"

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

    # @param parts [Array<Object>]
    # @return [nil]
    def print(*parts)
      parts.each { |p| @string << p.to_s }
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

  # Environment for git in tests: the gate env, with the user's global and system git config ignored.
  # @param dir [String] where an empty global config file is written
  # @return [Hash{String=>String}]
  def self.git_env(dir)
    empty = File.join(dir, "empty.gitconfig")
    File.write(empty, "") unless File.exist?(empty)
    Harness::Gates::Env.build(ENV).merge("GIT_CONFIG_GLOBAL" => empty, "GIT_CONFIG_NOSYSTEM" => "1")
  end

  # @return [String] stdout
  def self.git!(dir, env, *args)
    r = Harness::Exec.run(["git", *args], chdir: dir, env: env, timeout: 60)
    raise "git #{args.join(' ')} failed: #{r.stderr}" unless r.success?

    r.stdout
  end

  # A committed fixture repository at <parent>/repo.
  # @param parent [String]
  # @param files [Hash{String=>String}] relative path => content
  # @return [Array(String, Hash)] repo dir and the git env to use with it
  def self.repo(parent, files = { "README.md" => "# fixture\n" })
    dir = File.join(parent, "repo")
    FileUtils.mkdir_p(dir)
    env = git_env(parent)
    git!(dir, env, "init", "-q", "-b", "main")
    { "user.name" => "Harness Test", "user.email" => "test@example.invalid", "core.autocrlf" => "false",
      "commit.gpgsign" => "false" }.each { |k, v| git!(dir, env, "config", k, v) }
    files.each do |path, content|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.binwrite(full, content)
    end
    git!(dir, env, "add", "-A")
    git!(dir, env, "commit", "-q", "-m", "init")
    [dir, env]
  end

  # @return [Hash{String=>String}] a minimal environment for test subprocesses
  def self.child_env
    %w[PATH PATHEXT SystemRoot COMSPEC TEMP TMP TMPDIR HOME USERPROFILE LANG].each_with_object({}) do |k, env|
      env[k] = ENV[k] if ENV[k]
    end
  end
end
