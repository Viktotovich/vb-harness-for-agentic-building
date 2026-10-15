# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "errors"
require_relative "gates/baseline"
require_relative "gates/env"
require_relative "gates/runner"
require_relative "plan/plan"
require_relative "repo/git"
require_relative "repo/worktree"
require_relative "state/events"
require_relative "state/run_store"
require_relative "task/loop"

module Harness
  # One run of the pipeline (DESIGN.md 5): intake, the task queue, integration gates. Planning (M4), the final
  # review (M6) and the report (M7) plug in later.
  class Run
    # What intake produces.
    Setup = Data.define(:worktree, :stack, :runner, :baseline, :events, :store, :env)
    # exit_code: 0 all done and integration green, 1 blocked or regressed, 2 environment problem.
    Outcome = Data.define(:run_id, :tasks, :integration, :exit_code, :branch, :worktree)

    # Intake (DESIGN.md 5.1): clean repo, worktree, stack, baseline.
    # @param config [Config]
    # @param repo [String]
    # @param store [State::RunStore]
    # @param parent_env [Hash{String=>String}]
    # @return [Setup]
    # @raise [GitError] on a dirty or missing repository
    # @raise [ConfigError] when no configured stack matches the repository
    def self.intake(config:, repo:, store:, parent_env: ENV)
      events = State::Events.new(path: store.events_path, run_id: store.run_id)
      events.emit(stage: "intake", kind: "stage_started")
      env = Gates::Env.build(parent_env, allow: config.gate_env_allow)
      worktree = Repo::Worktree.create(repo: repo, run_id: store.run_id, git: Repo::Git.new(env: env))
      stack = detect_stack(config, worktree.root)
      runner = Gates::Runner.new(root: worktree.root, env: env, max_output: config.limits.max_gate_output_bytes)
      baseline = Gates::Baseline.run(runner, stack.gates)
      Gates::Baseline.save(store.baseline_path, baseline)
      baseline.each_value do |r|
        next unless r.status == "skipped"

        events.emit(stage: "intake", kind: "rejected", subject: r.gate, reason: "gate.skipped:#{r.gate}", detail: r.reason.to_s[0, 300])
      end
      store.write_run({ "status" => "running", "repo" => worktree.repo, "worktree" => worktree.root, "branch" => worktree.branch,
                        "baseSha" => worktree.base_sha, "stack" => stack.name })
      events.emit(stage: "intake", kind: "stage_finished", detail: "stack #{stack.name}, base #{worktree.base_sha[0, 12]}")
      Setup.new(worktree: worktree, stack: stack, runner: runner, baseline: baseline, events: events, store: store, env: env)
    end

    # @param config [Config]
    # @param root [String]
    # @return [Gates::Stack]
    # @raise [ConfigError]
    def self.detect_stack(config, root)
      if config.stack != "auto"
        return config.stacks.fetch(config.stack) { raise ConfigError, "stack #{config.stack.inspect} is not configured" }
      end

      found = config.stacks.values.find { |s| s.detect.any? { |f| File.exist?(File.join(root, f)) } }
      found || raise(ConfigError, "no configured stack matches this repository (stacks: #{config.stacks.keys.join(', ')})")
    end

    # @param config [Config]
    # @param client [Model::Client]
    # @param setup [Setup]
    # @param reviewer [#call, nil]
    def initialize(config:, client:, setup:, reviewer: nil)
      @config = config
      @setup = setup
      @ctx = Task::Context.new(client: client, config: config, worktree: setup.worktree, stack: setup.stack,
                               runner: setup.runner, baseline: setup.baseline, events: setup.events, store: setup.store,
                               reviewer: reviewer)
    end

    # Run every task in dependency order. Dependants of a task that is not done are skipped; independent
    # tasks continue. A model outage stops the queue.
    # @param plan [Plan::Plan]
    # @return [Outcome]
    def execute(plan)
      State.write_json(@setup.store.plan_path, plan.to_json_hash)
      outcomes = {}
      stopped = false
      plan.ordered.each do |task|
        if stopped
          outcomes[task.id] = skip(task, "the model server is unavailable")
          next
        end
        missing = task.depends_on.find { |d| outcomes[d]&.status != "done" }
        if missing
          outcomes[task.id] = skip(task, "depends on #{missing}, which is #{outcomes[missing]&.status || 'not done'}")
          next
        end
        done = outcomes.values.select { |o| o.status == "done" }.map { |o| "#{o.id}: #{plan.task(o.id).title}" }
        outcomes[task.id] = Task::Loop.new(@ctx).run(task, done: done)
        stopped = outcomes[task.id].reason == "model.unavailable"
      end
      integration = stopped ? [] : run_integration
      finish(outcomes, integration, stopped)
    end

    private

    # @return [Task::Outcome]
    def skip(task, why)
      @setup.events.emit(stage: "task.gather", kind: "skipped", task: task.id, subject: "task", detail: why)
      @setup.store.write_task_state(task.id, { "id" => task.id, "state" => "skipped", "reason" => why })
      Task::Outcome.new(id: task.id, status: "skipped", commit: nil, fix_rounds: 0, reason: nil, detail: why, gates: [])
    end

    # Integration gates and the full unit suite, compared with the baseline (DESIGN.md 5.5).
    # @return [Array<Gates::Baseline::Comparison>]
    def run_integration
      events = @setup.events
      events.emit(stage: "integration", kind: "stage_started")
      gates = @setup.stack.gates.values.select { |g| g.phase == "integration" || g.scope == "tests" }.sort_by(&:cost_rank)
      comparisons = gates.map do |g|
        cmp = Gates::Baseline.compare(@setup.runner.run(g), @setup.baseline[g.name])
        if cmp.ok?
          events.emit(stage: "integration", kind: "accepted", subject: g.name, detail: cmp.verdict, ms: cmp.current.ms)
        else
          kind = { "skipped" => "skipped", "timeout" => "timeout" }.fetch(cmp.current.status, "failed")
          events.emit(stage: "integration", kind: "rejected", subject: g.name, reason: "gate.#{kind}:#{g.name}",
                      detail: (cmp.current.reason || "#{cmp.new_diagnostics.size} new problems").to_s[0, 300], ms: cmp.current.ms)
        end
        cmp
      end
      events.emit(stage: "integration", kind: "stage_finished")
      comparisons
    end

    # @return [Outcome]
    def finish(outcomes, integration, stopped)
      green = outcomes.values.all? { |o| o.status == "done" } && integration.all? { |c| c.ok? || !blocking?(c.gate) }
      code = if stopped then 2
             elsif green then 0
             else 1
             end
      @setup.store.write_run({ "status" => %w[done failed stopped][[0, 1, 2].index(code)], "exitCode" => code,
                               "repo" => @setup.worktree.repo, "worktree" => @setup.worktree.root,
                               "branch" => @setup.worktree.branch, "baseSha" => @setup.worktree.base_sha,
                               "stack" => @setup.stack.name, "head" => @setup.worktree.head })
      Outcome.new(run_id: @setup.store.run_id, tasks: outcomes.values, integration: integration, exit_code: code,
                  branch: @setup.worktree.branch, worktree: @setup.worktree.root)
    end

    # @return [Boolean]
    def blocking?(gate_name)
      @setup.stack.gates[gate_name]&.blocking != false
    end
  end
end
