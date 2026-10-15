# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"
require_relative "../config"
require_relative "../errors"
require_relative "../gates/baseline"
require_relative "../gates/env"
require_relative "../gates/runner"
require_relative "../repo/atomic_file"
require_relative "../repo/git"
require_relative "../repo/paths"
require_relative "../repo/worktree"
require_relative "../state/run_store"

module Harness
  module Eval
    # One eval task: eval/tasks/<id>/ with request.md, repo.ref and hidden/ (DESIGN.md 12).
    Task = Data.define(:id, :dir, :request, :repo, :commit, :hidden)

    # What one task scored under one profile mapping.
    Score = Data.define(:task, :mapping, :status, :solved, :no_fix, :regressions, :findings, :claims, :fix_rounds,
                        :tokens, :ms, :roles, :note)

    # Runs the eval tasks under each profile mapping and scores them from the run's own files. Hidden tests are
    # copied into the worktree only after the run finishes, and run with the stack's test gate.
    class Runner
      # @param raw_config [Hash] the base config as JSON, which mappings override
      # @param env [Hash{String=>String}]
      # @param out_dir [String] where each mapping's runs go
      # @param pipeline_for [#call] (config, home) -> Pipeline
      # @param keep [Boolean] keep worktrees for inspection
      def initialize(raw_config:, env:, out_dir:, pipeline_for:, keep: false)
        @raw = raw_config
        @env = env
        @out = out_dir
        @pipeline_for = pipeline_for
        @keep = keep
      end

      # @param tasks_glob [String] e.g. "eval/tasks/*"
      # @param root [String] the eval folder, against which repo.ref paths resolve
      # @return [Array<Task>]
      # @raise [ConfigError]
      def self.load_tasks(tasks_glob, root:, env: ENV)
        Dir.glob(tasks_glob).select { |d| File.directory?(d) }.sort.map do |dir|
          id = File.basename(dir)
          ref = File.read(File.join(dir, "repo.ref"), encoding: "UTF-8").lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
          raise ConfigError, "#{id}/repo.ref: expected a path and a commit" unless ref.size == 2

          hidden = Dir.glob("**/*", base: File.join(dir, "hidden")).select { |f| File.file?(File.join(dir, "hidden", f)) }.sort
          Task.new(id: id, dir: dir, request: File.read(File.join(dir, "request.md"), encoding: "UTF-8"),
                   repo: resolve_repo(ref[0], root, env, id), commit: ref[1], hidden: hidden)
        rescue Errno::ENOENT => e
          raise ConfigError, "#{id}: #{e.message.sub(/ @ .*/, '')}"
        end
      end

      # @param mappings [Hash{String=>Hash}] mapping name -> {"roles" => {...}, "profiles" => {...}}
      # @param tasks [Array<Task>]
      # @return [Hash{String=>Array<Score>}]
      def call(mappings, tasks)
        mappings.to_h do |name, over|
          config = Config.parse(merged(over))
          [name, tasks.map { |t| score(name, config, t) }]
        end
      end

      # @param results [Hash{String=>Array<Score>}]
      # @return [String] one markdown table per mapping, then tokens and time per role
      def self.table(results)
        results.flat_map do |name, scores|
          rows = scores.map do |s|
            "| #{s.task} | #{s.solved ? 'yes' : 'no'} | #{s.no_fix ? 'yes' : 'no'} | #{s.regressions} | #{s.findings}/#{s.claims} | " \
              "#{s.fix_rounds} | #{s.tokens} | #{(s.ms / 1000.0).round}s | #{s.note} |"
          end
          solved = scores.count(&:solved)
          claims = scores.sum(&:claims)
          total = "| **all** | #{solved}/#{scores.size} | #{scores.count(&:no_fix)}/#{scores.size} | #{scores.sum(&:regressions)} | " \
                  "#{claims.zero? ? '-' : "#{(100.0 * scores.sum(&:findings) / claims).round}%"} | #{scores.sum(&:fix_rounds)} | " \
                  "#{scores.sum(&:tokens)} | #{(scores.sum(&:ms) / 1000.0).round}s | |"
          roles = scores.flat_map { |s| s.roles.to_a }.group_by(&:first).sort.map do |role, pairs|
            "| #{role} | #{pairs.sum { |_, v| v['tokens'] }} | #{(pairs.sum { |_, v| v['ms'] } / 1000.0).round}s |"
          end
          ["## Mapping: #{name}", "",
           "| Task | Solved | Solved without fixes | Regressions | Findings confirmed | Fix rounds | Tokens | Time | Note |",
           "| --- | --- | --- | --- | --- | --- | --- | --- | --- |", *rows, total, "",
           "| Role | Tokens | Time |", "| --- | --- | --- |", *roles, ""]
        end.join("\n")
      end

      # @return [String]
      def self.resolve_repo(spec, root, env, id)
        if spec.match?(%r{\A[a-z][a-z0-9+.-]*://|\A[\w.-]+@[\w.-]+:}i)
          raise ConfigError, "#{id}/repo.ref: #{spec} is a remote; clone it yourself and point repo.ref at the local path"
        end

        path = spec.gsub(/\$\{?([A-Z_][A-Z0-9_]*)\}?/) do
          env.fetch(Regexp.last_match(1)) { raise ConfigError, "#{id}/repo.ref: set #{Regexp.last_match(1)} to the prepared repository" }
        end
        File.expand_path(path, root)
      end
      private_class_method :resolve_repo

      private

      # @return [Hash]
      def merged(over)
        cfg = JSON.parse(JSON.generate(@raw))
        cfg["profiles"] = cfg.fetch("profiles", {}).merge(over.fetch("profiles", {}))
        cfg["roles"] = cfg.fetch("roles", {}).merge(over.fetch("roles", {}))
        cfg
      end

      # @return [Score]
      def score(mapping, config, task)
        check_commit!(config, task)
        home = File.join(@out, mapping)
        result = @pipeline_for.call(config, home).start(repo: task.repo, request: task.request)
        store = State::RunStore.new(runs_dir: File.join(home, "runs"), run_id: result.run_id)
        run = store.read_run
        solved, note = hidden_tests(config, task, run)
        finish(mapping, task, store, result, solved, note)
      rescue ConfigError, GitError, ParseError, ModelUnavailableError, ModelOutputError, ContextOverflowError => e
        Score.new(task: task.id, mapping: mapping, status: "error", solved: false, no_fix: false, regressions: 0, findings: 0,
                  claims: 0, fix_rounds: 0, tokens: 0, ms: 0, roles: {}, note: e.message.gsub(/\s+/, " ")[0, 120].gsub("|", "/"))
      end

      # @return [void]
      # @raise [ConfigError] when the repository is not at the pinned commit
      def check_commit!(config, task)
        return if task.commit == "HEAD"

        head = git(config).run(%w[rev-parse HEAD], chdir: task.repo).strip
        raise ConfigError, "#{task.id}: repo.ref pins #{task.commit[0, 12]}, the repository is at #{head[0, 12]}" unless head.start_with?(task.commit)
      end

      # Copy hidden/ into the finished worktree and run the stack's test gate on just those files.
      # @return [Array(Boolean, String)] solved, and a note
      def hidden_tests(config, task, run)
        return [false, "run #{run['status']}"] unless %w[done failed].include?(run["status"]) && File.directory?(run["worktree"].to_s)

        stack = config.stacks.fetch(run["stack"])
        gate = stack.gates.values.find { |g| g.scope == "tests" && g.phase == "task" } ||
               stack.gates.values.find { |g| g.scope == "tests" }
        return [false, "the stack has no test gate"] unless gate
        return [false, "no hidden tests"] if task.hidden.empty?

        task.hidden.each do |rel|
          dest = Repo::Paths.resolve_in_worktree(run["worktree"], rel, protected: stack.protected_paths)
          Repo::AtomicFile.write(dest, File.binread(File.join(task.dir, "hidden", rel)))
        end
        env = Gates::Env.build(@env, allow: config.gate_env_allow)
        r = Gates::Runner.new(root: run["worktree"], env: env, max_output: config.limits.max_gate_output_bytes).run(gate, tests: task.hidden)
        [r.passed?, r.passed? ? "" : "hidden tests #{r.status}"]
      ensure
        remove_worktree(config, run) unless @keep
      end

      # @return [Score]
      def finish(mapping, task, store, result, solved, note)
        plan = read_json(store.plan_path, { "tasks" => [] })
        states = Array(plan["tasks"]).map { |t| store.read_task_state(t["id"]) || {} }
        fix = states.sum { |s| s["fixRounds"].to_i }
        integration = read_json(File.join(store.dir, "integration.json"), [])
        reviews = Dir.glob(File.join(store.dir, "tasks", "*", "review.json")) + [store.final_review_path]
        found, claims = reviews.select { |f| File.file?(f) }.map { |f| JSON.parse(File.read(f)) }.reduce([0, 0]) do |(a, b), r|
          f = Array(r["findings"]).size
          [a + f, b + f + Array(r["questions"]).count { |q| q["reason"].to_s.start_with?("confirm.") }]
        end
        records = Dir.glob(File.join(store.records_dir, "*.json")).map { |f| JSON.parse(File.read(f)) }
        roles = records.group_by { |r| r["role"] }.transform_values do |rs|
          { "tokens" => rs.sum { |r| r.dig("usage", "in").to_i + r.dig("usage", "out").to_i }, "ms" => rs.sum { |r| r["ms"].to_i } }
        end
        Score.new(task: task.id, mapping: mapping, status: result.status, solved: solved, no_fix: solved && fix.zero?,
                  regressions: integration.count { |c| c["verdict"] == "regressed" }, findings: found, claims: claims,
                  fix_rounds: fix, tokens: roles.values.sum { |v| v["tokens"] }, ms: roles.values.sum { |v| v["ms"] },
                  roles: roles, note: note)
      end

      # @return [Object]
      def read_json(path, default)
        JSON.parse(File.read(path, encoding: "UTF-8"))
      rescue Errno::ENOENT, JSON::ParserError
        default
      end

      # @return [void]
      def remove_worktree(config, run)
        return unless run && File.directory?(run["worktree"].to_s)

        Repo::Worktree.new(repo: run["repo"], root: run["worktree"], branch: run["branch"], base_sha: run["baseSha"],
                           git: git(config)).remove(force: true)
      rescue GitError
        nil
      end

      # @return [Repo::Git]
      def git(config)
        Repo::Git.new(env: Gates::Env.build(@env, allow: config.gate_env_allow), cache_dir: File.join(@out, ".cache"))
      end
    end
  end
end
