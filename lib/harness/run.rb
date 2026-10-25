# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"
require_relative "errors"
require_relative "gates/baseline"
require_relative "gates/env"
require_relative "gates/runner"
require_relative "plan/plan"
require_relative "repo/atomic_file"
require_relative "repo/git"
require_relative "repo/map"
require_relative "repo/mirror"
require_relative "repo/paths"
require_relative "report/render"
require_relative "review/reviewer"
require_relative "repo/worktree"
require_relative "state/events"
require_relative "state/run_store"
require_relative "task/loop"
require_relative "task/summarizer"

module Harness
  # One run of the pipeline (DESIGN.md 5): intake, the task queue, integration gates. Planning (M4), the final
  # review (M6) and the report (M7) plug in later.
  class Run
    # What intake produces.
    Setup = Data.define(:worktree, :stack, :runner, :baseline, :events, :store, :env)
    # exit_code: 0 all done and integration green, 1 blocked or regressed, 2 environment problem.
    Outcome = Data.define(:run_id, :tasks, :integration, :exit_code, :branch, :worktree)

    # Blocking gates that already fail before the run. Tasks are still judged only on new problems, but a field run
    # planned and implemented on a red type check, so every task's gate output was noisy: say so up front.
    # @return [Array<String>] the gates' names
    def self.red_baseline(stack, baseline, events)
      baseline.filter_map do |name, r|
        next unless %w[failed timeout].include?(r.status) && stack.gates[name]&.blocking != false

        events.emit(stage: "intake", kind: "rejected", subject: name, reason: "gate.#{r.status}:#{name}",
                    detail: "fails before the run (#{r.diagnostics.size} problems): tasks are judged only on new problems, " \
                            "but fix the baseline first if you can")
        name
      end
    end

    # Intake (DESIGN.md 5.1): clean repo, worktree, stack, baseline.
    # @param config [Config]
    # @param repo [String]
    # @param store [State::RunStore]
    # @param parent_env [Hash{String=>String}]
    # @param cache_dir [String, nil] .cache/, for the empty git hooks directory
    # @param workspaces [String, nil] where worktrees go; default workspaces/ next to runs/
    # @return [Setup]
    # @raise [GitError] on a dirty or missing repository
    # @raise [ConfigError] when no configured stack matches the repository, or its dependencies are not installed
    def self.intake(config:, repo:, store:, parent_env: ENV, cache_dir: nil, workspaces: nil)
      events = State::Events.new(path: store.events_path, run_id: store.run_id)
      events.emit(stage: "intake", kind: "stage_started")
      env = Gates::Env.build(parent_env, allow: config.gate_env_allow)
      workspaces ||= File.join(File.dirname(File.dirname(store.dir)), "workspaces")
      git = Repo::Git.new(env: env, cache_dir: cache_dir)
      readiness!(config, Repo::Worktree.top_level(repo, git), git)
      worktree = Repo::Worktree.create(repo: repo, run_id: store.run_id, git: git, workspaces: workspaces)
      stack = detect_stack(config, worktree.root)
      stack.dependency_dirs.each do |dir|
        m = Repo::Mirror.link(File.join(worktree.repo, dir), File.join(worktree.root, dir))
        next unless m

        skipped = m.skipped.empty? ? "" : "; #{m.skipped.size} could not be linked (first: #{m.skipped.first})"
        events.emit(stage: "intake", kind: "accepted", subject: dir, detail: "#{m.files} files linked into the worktree#{skipped}"[0, 300])
      end
      runner = Gates::Runner.new(root: worktree.root, env: env, max_output: config.limits.max_gate_output_bytes)
      baseline = Gates::Baseline.run(runner, stack.gates)
      Gates::Baseline.save(store.baseline_path, baseline)
      baseline.each_value do |r|
        next unless r.status == "skipped"

        events.emit(stage: "intake", kind: "rejected", subject: r.gate, reason: "gate.skipped:#{r.gate}", detail: r.reason.to_s[0, 300])
      end
      red = red_baseline(stack, baseline, events)
      store.update_run({ "status" => "planning", "repo" => worktree.repo, "worktree" => worktree.root, "branch" => worktree.branch,
                        "baseSha" => worktree.base_sha, "stack" => stack.name, "baselineFailing" => red })
      events.emit(stage: "intake", kind: "stage_finished", detail: "stack #{stack.name}, base #{worktree.base_sha[0, 12]}")
      Setup.new(worktree: worktree, stack: stack, runner: runner, baseline: baseline, events: events, store: store, env: env)
    end

    # Lockfiles that name the package manager which installs node_modules, first match wins.
    NODE_LOCKFILES = { "pnpm-lock.yaml" => "pnpm", "yarn.lock" => "yarn", "bun.lock" => "bun", "bun.lockb" => "bun" }.freeze

    # Everything that would stop the run, checked in the user's checkout before the worktree exists (so a stop
    # leaves no branch behind), and reported together, so fixing one problem never just uncovers the next. One
    # problem keeps its own error and message.
    # @param config [Config]
    # @param top [String] the repository's top-level folder
    # @param git [Repo::Git]
    # @return [void]
    # @raise [GitError] when the only problem is uncommitted changes
    # @raise [ConfigError] for any other problem, or several, one per line
    def self.readiness!(config, top, git)
      problems = problems(config, top, git)
      return if problems.empty?
      raise problems[0][0], problems[0][1] if problems.size == 1

      raise ConfigError, "#{problems.size} problems stop this run:\n#{problems.map { |_, m| "  - #{m}" }.join("\n")}"
    end

    # The checks behind #readiness!, also run by `harness doctor`.
    # @param config [Config]
    # @param top [String] the repository's top-level folder
    # @param git [Repo::Git]
    # @return [Array<Array(Class, String)>] the error class and message of each problem, in a stable order
    def self.problems(config, top, git)
      out = []
      out << [GitError, Repo::Worktree::DIRTY] unless git.run(%w[status --porcelain --untracked-files=all], chdir: top).strip.empty?
      begin
        missing = dependency_problem(detect_stack(config, top), top)
        out << [ConfigError, missing] if missing
      rescue ConfigError => e
        out << [ConfigError, e.message]
      end
      out
    end

    # Every dependencyDirs folder must exist in the user's checkout. Without it the project's tools are missing,
    # so every gate is skipped as "tool not installed" and the plan check refuses each task that needs one; a
    # field run only found out at the end. Nothing is installed here (I10): the message says what to run.
    # @param stack [Gates::Stack]
    # @param top [String] the repository's top-level folder
    # @return [String, nil] the missing folders and the install command, or nil when all are there
    def self.dependency_problem(stack, top)
      missing = stack.dependency_dirs.reject { |d| File.directory?(File.join(top, d)) }
      return nil if missing.empty?

      how = if missing.include?("node_modules")
              manager = stack.package_manager
              manager = NODE_LOCKFILES.find { |f, _| File.file?(File.join(top, f)) }&.last || "npm" if manager == "auto"
              "run `#{manager} install` there"
            else
              "install the project's dependencies there"
            end
      "#{missing.join(', ')} #{missing.size == 1 ? 'is' : 'are'} missing in #{top}: the project's " \
        "dependencies are not installed, so its checks cannot run. #{how.capitalize}, then start the run again"
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
    # @param review [Boolean] run the review (DESIGN.md 8) on every task and on the whole run
    # @param cache_dir [String, nil] the context map's cache (.cache/); nil disables it
    # @param stop [#call, nil] -> Boolean, asked between tasks: true ends the run "stopped" so resume can continue it
    def initialize(config:, client:, setup:, review: true, cache_dir: nil, stop: nil)
      @config = config
      @setup = setup
      @stop = stop || -> { false }
      self.class.observe(client, setup.events) if client.respond_to?(:on_discard) && client.on_discard.nil?
      map = Repo::Map.new(root: setup.worktree.root, cache_dir: cache_dir, protected: setup.stack.protected_paths)
      @reviewer = if review && config.review != "off"
                    Review::Reviewer.new(client: client, config: config, worktree: setup.worktree, stack: setup.stack,
                                         runner: setup.runner, baseline: setup.baseline, events: setup.events,
                                         store: setup.store, map: map, cache_dir: cache_dir)
                  end
      @ctx = Task::Context.new(client: client, config: config, worktree: setup.worktree, stack: setup.stack,
                               runner: setup.runner, baseline: setup.baseline, events: setup.events, store: setup.store,
                               reviewer: @reviewer, map: map, summarizer: Task::Summarizer.new(client: client, config: config))
    end

    # The stage each role's discarded replies are counted under (DESIGN.md 10.3).
    DISCARD_STAGE = { planner: "plan", implementer: "task.implement", fixer: "task.fix", reviewer: "review.discover",
                      verifier: "review.verify", summarizer: "map" }.freeze

    # Connect a client's discarded replies to the run's event log, so the report counts them.
    # @param client [Model::Client]
    # @param events [State::Events]
    # @return [Model::Client]
    def self.observe(client, events)
      return client unless client.respond_to?(:on_discard=)

      client.on_discard = lambda do |role:, label:, reason:, message:|
        events.emit(stage: DISCARD_STAGE.fetch(role, "plan"), kind: "rejected", task: label[Model::Client::TASK_LABEL, 1],
                    subject: label, reason: reason, detail: message[0, 300])
      end
      client
    end

    # Reattach to a run started earlier (resume and answer): its worktree, stack, baseline and event log.
    # @param config [Config]
    # @param store [State::RunStore]
    # @param parent_env [Hash{String=>String}]
    # @param cache_dir [String, nil] .cache/, for the empty git hooks directory
    # @return [Setup]
    # @raise [ConfigError] when the run or its worktree is gone
    def self.reattach(config:, store:, parent_env: ENV, cache_dir: nil)
      run = store.read_run
      raise ConfigError, "no run #{store.run_id}" if run.empty?
      raise ConfigError, "the worktree of run #{store.run_id} is gone (#{run['worktree']})" unless File.directory?(run["worktree"].to_s)

      env = Gates::Env.build(parent_env, allow: config.gate_env_allow)
      worktree = Repo::Worktree.new(repo: run["repo"], root: run["worktree"], branch: run["branch"], base_sha: run["baseSha"],
                                    git: Repo::Git.new(env: env, cache_dir: cache_dir))
      stack = config.stacks.fetch(run["stack"]) { raise ConfigError, "stack #{run['stack']} is no longer configured" }
      runner = Gates::Runner.new(root: worktree.root, env: env, max_output: config.limits.max_gate_output_bytes)
      Setup.new(worktree: worktree, stack: stack, runner: runner, baseline: Gates::Baseline.load(store.baseline_path),
                events: State::Events.new(path: store.events_path, run_id: store.run_id), store: store, env: env)
    end

    # Run every task in dependency order. Dependants of a task that is not done are skipped; independent
    # tasks continue. A model outage stops the queue, and so does a stop request: it is checked before each task,
    # before integration and before the final review, never in the middle of a task, so committed work stays.
    # @param plan [Plan::Plan]
    # @param resume [Boolean] continue each task from its saved state instead of starting fresh
    # @return [Outcome]
    def execute(plan, resume: false)
      State.write_json(@setup.store.plan_path, plan.to_json_hash)
      @setup.store.update_run({ "status" => "running" })
      outcomes = {}
      halt = nil # why the queue stopped, or nil
      queue = plan.ordered
      while (task = queue.shift)
        halt ||= STOPPED_BY_USER if @stop.call
        if halt
          outcomes[task.id] = skip(task, halt)
          next
        end
        missing = task.depends_on.find { |d| outcomes[d]&.status != "done" }
        if missing
          outcomes[task.id] = skip(task, "depends on #{missing}, which is #{outcomes[missing]&.status || 'not done'}")
          next
        end
        done = outcomes.values.select { |o| o.status == "done" }.map { |o| "#{o.id}: #{plan.task(o.id).title}" }
        saved = resume ? @setup.store.read_task_state(task.id) : nil
        # A stop before the task saved any state can still leave edits behind: start from the last commit.
        @setup.worktree.revert! if resume && %w[pending skipped].include?(saved&.fetch("state", nil) || "pending") && @setup.worktree.dirty?
        seed(task)
        outcomes[task.id] = run_task(task, done, saved)
        halt = "the model server is unavailable" if outcomes[task.id].reason == "model.unavailable"
        follow = outcomes[task.id].status == "done" ? add_follow_ups(plan, task) : []
        plan = plan.with(tasks: plan.tasks + follow) unless follow.empty?
        queue.unshift(*follow)
      end
      halt ||= STOPPED_BY_USER if @stop.call
      integration = halt ? [] : run_integration
      halt ||= STOPPED_BY_USER if @stop.call
      final_review(integration) unless halt
      finish(outcomes, halt ? [] : integration, !halt.nil?)
    end

    STOPPED_BY_USER = "stopped by the user; harness resume continues the run"

    private

    # Confirmed review claims of a finished task become fix tasks that run next. Each keeps its failing test in
    # tasks/<id>/confirm-test.json until it runs, and the plan on disk lists it, so a resumed run has it too.
    # @return [Array<Plan::Task>]
    def add_follow_ups(plan, task)
      return [] unless @reviewer

      ups = @reviewer.follow_ups(task.id).reject { |u| plan.task(u.task.id) }
      ups.each do |u|
        @setup.store.write_task_file(u.task.id, "confirm-test.json", { "path" => u.test_path, "content" => u.test_content })
        @setup.events.emit(stage: "review.confirm_test", kind: "split", task: task.id, subject: u.task.id,
                           detail: "fix task for a claim confirmed by #{u.test_path}")
      end
      tasks = ups.map(&:task)
      State.write_json(@setup.store.plan_path, plan.with(tasks: plan.tasks + tasks).to_json_hash) unless tasks.empty?
      tasks
    end

    # Write a follow-up task's failing test into the worktree before the task runs.
    # @return [void]
    def seed(task)
      file = File.join(@setup.store.task_dir(task.id), "confirm-test.json")
      return unless File.file?(file)

      saved = JSON.parse(File.read(file, encoding: "UTF-8"))
      full = Repo::Paths.resolve_in_worktree(@setup.worktree.root, saved["path"], protected: @setup.stack.protected_paths)
      return if File.file?(full)

      Repo::AtomicFile.write(full, saved["content"].to_s)
    end

    # The review of everything the run committed (DESIGN.md 5.5 step 2).
    # @return [void]
    def final_review(integration)
      return unless @reviewer && @setup.worktree.head != @setup.worktree.base_sha

      typecheck = @setup.stack.gates.values.select { |g| Review::Reviewer::TYPE_PARSERS.include?(g.parser) }.map(&:name)
      results = integration.select { |c| typecheck.include?(c.gate) }
      passed = results.empty? ? @setup.baseline.values.any? { |r| typecheck.include?(r.gate) && r.passed? } : results.all?(&:ok?)
      @reviewer.final(diff: @setup.worktree.range_patch(context: Task::Loop::REVIEW_CONTEXT), typecheck_passed: passed)
    end

    # Finished tasks keep their outcome on resume; skipped tasks and those stopped by a model outage run again.
    # @return [Task::Outcome]
    def run_task(task, done, saved)
      loop_ = Task::Loop.new(@ctx)
      case saved&.fetch("state", nil)
      when nil, "pending", "skipped" then loop_.run(task, done: done)
      when "done"
        Task::Outcome.new(id: task.id, status: "done", commit: saved["commit"], fix_rounds: saved["fixRounds"].to_i,
                          reason: nil, detail: "finished before resume", gates: [])
      when "blocked"
        return loop_.run(task, done: done) if saved["reason"] == "model.unavailable"

        Task::Outcome.new(id: task.id, status: "blocked", commit: nil, fix_rounds: saved["fixRounds"].to_i,
                          reason: saved["reason"], detail: "blocked before resume", gates: [])
      else loop_.resume(task, saved, done: done)
      end
    end

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
        elsif skipped_at_baseline?(cmp)
          events.emit(stage: "integration", kind: "skipped", subject: g.name,
                      detail: "could not run at baseline either: #{cmp.current.reason}"[0, 300], ms: cmp.current.ms)
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
      green = outcomes.values.all? { |o| o.status == "done" } &&
              integration.all? { |c| c.ok? || !blocking?(c.gate) || skipped_at_baseline?(c) }
      code = if stopped then 2
             elsif green then 0
             else 1
             end
      @setup.store.update_run({ "status" => %w[done failed stopped][code], "exitCode" => code, "head" => @setup.worktree.head })
      State.write_json(File.join(@setup.store.dir, "integration.json"),
                       integration.map { |c| { "gate" => c.gate, "verdict" => c.verdict, "status" => c.current.status, "reason" => c.current.reason } })
      @setup.events.emit(stage: "report", kind: "stage_started")
      path = Report::Render.write(@setup.store)
      @setup.events.emit(stage: "report", kind: "stage_finished", detail: File.basename(path))
      Outcome.new(run_id: @setup.store.run_id, tasks: outcomes.values, integration: integration, exit_code: code,
                  branch: @setup.worktree.branch, worktree: @setup.worktree.root)
    end

    # A gate whose tool is missing now and was missing at intake says nothing about this run's changes.
    # @param cmp [Gates::Baseline::Comparison]
    # @return [Boolean]
    def skipped_at_baseline?(cmp)
      cmp.verdict == "skipped" && @setup.baseline[cmp.gate]&.status == "skipped"
    end

    # @return [Boolean]
    def blocking?(gate_name)
      @setup.stack.gates[gate_name]&.blocking != false
    end
  end
end
