# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "config"
require_relative "errors"
require_relative "exec"
require_relative "gates/env"
require_relative "model/http"
require_relative "providers/detect"
require_relative "repo/git"
require_relative "repo/worktree"
require_relative "run"
require_relative "version"

module Harness
  # harness doctor and the app's Check setup: every reason a run would not start, found in one pass, each with
  # what to do. Nothing is written, installed or started, and no model is asked to generate: a server is only
  # asked for its model list. Keys are never read into the output, only whether the named variable is set (I12).
  class Doctor
    # One check. area: what was checked; ok: false for a problem; detail: what was found; fix: what to do, or nil.
    Check = Data.define(:area, :ok, :detail, :fix) do
      # @return [Hash]
      def to_json_hash = { "area" => area, "ok" => ok, "detail" => detail, "fix" => fix }
    end

    MIN_RUBY = "3.3"

    # @param config_path [String]
    # @param env [Hash{String=>String}]
    # @param repo [String, nil] the repository to check, or nil to skip the repository checks
    # @param http [Model::Http]
    def initialize(config_path:, env:, repo: nil, http: Model::Http.new)
      @config_path = config_path
      @env = env.to_h
      @repo = repo
      @http = http
    end

    # @return [Array<Check>] in a stable order: tools, config, models, repository, gates
    def checks
      out = [ruby, git]
      config = load_config(out)
      return out unless config

      models(config, out)
      repository(config, out) if @repo
      out
    end

    # @param checks [Array<Check>]
    # @return [Boolean] no problem found
    def self.ready?(checks) = checks.all?(&:ok)

    private

    # @return [Check]
    def ruby
      ok = Gem::Version.new(RUBY_VERSION) >= Gem::Version.new(MIN_RUBY)
      Check.new(area: "ruby", ok: ok, detail: "Ruby #{RUBY_VERSION}", fix: ok ? nil : "install Ruby #{MIN_RUBY} or newer")
    end

    # Found on PATH only: doctor starts no process (I4 keeps those to known places).
    # @return [Check]
    def git
      path = Exec.resolve("git", path: @env["PATH"] || @env["Path"], pathext: @env["PATHEXT"])
      return Check.new(area: "git", ok: false, detail: "git was not found on PATH", fix: "install git") unless path

      Check.new(area: "git", ok: true, detail: "git found (#{path})", fix: nil)
    end

    # @return [Config, nil]
    def load_config(out)
      config = Config.load(@config_path, env: @env)
      out << Check.new(area: "config", ok: true, detail: File.basename(@config_path), fix: nil)
      config
    rescue ParseError, ConfigError => e
      out << Check.new(area: "config", ok: false, detail: e.message, fix: "run `harness init`, or fix the file")
      nil
    end

    # Each profile a role uses: its server answers, the model is there, the key's variable is set.
    # @return [void]
    def models(config, out)
      used = config.roles.group_by { |_, name| name }.transform_values { |pairs| pairs.map(&:first) }
      used.each do |name, roles|
        profile = config.profiles.fetch(name)
        who = "#{name} (#{roles.join(', ')})"
        key = profile.api_key_env && @env[profile.api_key_env]
        if profile.api_key_env && key.to_s.empty?
          out << Check.new(area: "model", ok: false, detail: "#{who}: #{profile.api_key_env} is not set",
                           fix: "set the environment variable #{profile.api_key_env} to the server's key")
          next
        end
        out << model_check(profile, who, key)
      end
    end

    # @return [Check]
    def model_check(profile, who, key)
      found = Providers::Detect.custom(http: @http, base_url: profile.base_url, key: key)
      unless found.up
        return Check.new(area: "model", ok: false, detail: "#{who}: #{profile.base_url} did not answer (#{found.error.to_s[0, 160]})",
                         fix: "start the model server, or fix baseUrl in #{File.basename(@config_path)}")
      end
      if found.models.empty?
        return Check.new(area: "model", ok: false, detail: "#{who}: #{profile.base_url} lists no model",
                         fix: "load a model on the server")
      end
      if profile.model != "auto" && !found.models.include?(profile.model)
        return Check.new(area: "model", ok: false, detail: "#{who}: #{profile.model} is not among the server's models (#{found.models.first(5).join(', ')})",
                         fix: "load #{profile.model} on the server, or choose one it lists")
      end

      Check.new(area: "model", ok: true, detail: "#{who}: #{profile.model == 'auto' ? "auto, #{found.models.size} model(s) listed" : profile.model} at #{profile.base_url}",
                fix: nil)
    end

    # The checks intake runs, then whether each gate's tool is there.
    # @return [void]
    def repository(config, out)
      env = Gates::Env.build(@env, allow: config.gate_env_allow)
      git = Repo::Git.new(env: env)
      top = Repo::Worktree.top_level(@repo, git)
      problems = Run.problems(config, top, git)
      problems.each { |_, message| out << Check.new(area: "repository", ok: false, detail: message, fix: nil) }
      stack = begin
        Run.detect_stack(config, top)
      rescue ConfigError
        nil
      end
      out << Check.new(area: "repository", ok: true, detail: "#{top}: git, clean, stack #{stack&.name}", fix: nil) if problems.empty?
      stack&.gates&.each_value { |gate| out << gate_check(gate, top, env) }
    rescue GitError => e
      out << Check.new(area: "repository", ok: false, detail: e.message, fix: "give the folder of a git repository")
    end

    # A gate's command is on PATH; for `npx -- tool`, the tool is in the project's node_modules/.bin.
    # @return [Check]
    def gate_check(gate, top, env)
      cmd = gate.argv.first
      unless Exec.resolve(cmd, path: env["PATH"] || env["Path"], pathext: env["PATHEXT"]) || File.file?(File.join(top, cmd))
        return Check.new(area: "gate", ok: false, detail: "#{gate.name}: #{cmd} was not found", fix: "install #{cmd}, or change the gate's argv")
      end

      sep = gate.argv.index("--")
      tool = sep && File.basename(cmd, ".*") == "npx" ? gate.argv[sep + 1] : nil
      # Without node_modules the dependency check above already says what to run.
      if tool && File.directory?(File.join(top, "node_modules"))
        bins = [tool, "#{tool}.cmd"].map { |name| File.join(top, "node_modules", ".bin", name) }
        unless bins.any? { |b| File.file?(b) }
          optional = gate.blocking == false
          return Check.new(area: "gate", ok: optional, detail: "#{gate.name}: #{tool} is not installed in the project",
                           fix: "add #{tool} to the project's dependencies and install them#{optional ? ' (this gate does not block)' : ''}")
        end
      end

      Check.new(area: "gate", ok: true, detail: "#{gate.name}: #{tool || File.basename(cmd)} found", fix: nil)
    end
  end
end
