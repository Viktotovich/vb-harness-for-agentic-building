# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "errors"
require_relative "plan/checks"
require_relative "plan/plan"
require_relative "plan/planner"
require_relative "run"
require_relative "state/identity"
require_relative "state/lock"
require_relative "state/run_store"
require_relative "task/edits"
require_relative "task/gather"

module Harness
  # The run lifecycle behind harness run, answer and resume: intake, planning (with blocking questions),
  # execution, and picking a stopped run up again. One process per run at a time (harness.lock).
  #
  # Run statuses in run.json: planning, waiting (on answers), planned (--plan-only), plan_rejected, running,
  # done, failed, stopped, dry_run.
  class Pipeline
    EXIT_WAITING = 3

    # @return [Config]
    attr_reader :config

    # status: the run status; questions: blocking questions when waiting; issues: plan problems when rejected.
    # error: why planning failed, when it did (status "failed", no plan). dry_run: what a dry run found (see
    # #dry_run_result), nil otherwise.
    Result = Data.define(:run_id, :status, :exit_code, :outcome, :questions, :issues, :plan_path, :error, :dry_run) do
      def initialize(run_id:, status:, exit_code:, outcome:, questions:, issues:, plan_path:, error: nil, dry_run: nil) = super
    end

    # @param config [Config]
    # @param home [String] where runs/ lives (next to the config file)
    # @param env [Hash{String=>String}] the process environment
    # @param client_factory [#call] store -> Model::Client (records go into the run's folder)
    def initialize(config:, home:, env:, client_factory:)
      @config = config
      @runs_dir = File.join(home, "runs")
      @cache_dir = File.join(home, ".cache")
      @env = env
      @client_factory = client_factory
    end

    # Start a new run from a request (planner) or a plan.
    # @param repo [String]
    # @param request [String, nil] feature request text
    # @param plan_hash [Hash, nil] a plan in its JSON form (--from-plan)
    # @param plan_only [Boolean] stop after planning
    # @param run_id [String, nil] a new run id chosen by the caller (the app shows it before intake ends)
    # @param stop [#call, nil] -> Boolean; true ends the run "stopped" at the next safe point (see Run#execute)
    # @param dry_run [Boolean] stop after intake, the baseline and the checks of a given plan: no model call
    # @return [Result]
    # @raise [GitError, ConfigError, ParseError, ModelOutputError, ModelUnavailableError]
    def start(repo:, request: nil, plan_hash: nil, plan_only: false, run_id: nil, stop: nil, dry_run: false)
      raise ArgumentError, "give a request, a plan, or both" if request.nil? && plan_hash.nil?

      store = State::RunStore.new(runs_dir: @runs_dir, run_id: run_id || State::RunStore.new_run_id)
      raise ConfigError, "run #{run_id} already exists" if run_id && store.exist?
      locked(store) do
        setup = Run.intake(config: @config, repo: repo, store: store, parent_env: @env, cache_dir: @cache_dir)
        store.update_run({ "identity" => State::Identity.current(@config) })
        next dry_run_result(store, setup, request, plan_hash) if dry_run

        red = Array(store.read_run["baselineFailing"])
        next red_baseline_stop(store, red) if @config.require_green_baseline && !red.empty?

        client = Run.observe(@client_factory.call(store), setup.events)
        store.update_run({ "planOnly" => plan_only })
        store.write_request(request) if request
        if plan_hash
          # A hand-written plan with its request: the plan is run as given, and the request is still the context
          # the implementer, fixer and reviewers see for exact values (a field run lost it with --from-plan alone).
          planned(store, setup, client, check_given(setup, client, Plan::PlanParser.parse(plan_hash)), stop: stop)
        else
          plan_and_run(store, setup, client, request, [], stop: stop)
        end
      end
    end

    # Record answers to the blocking questions, replan with them, and continue.
    # @param run_id [String]
    # @param answers [Array<String>] one per blocking question, in order
    # @param stop [#call, nil] -> Boolean; true ends the run "stopped" at the next safe point (see Run#execute)
    # @param accept_changes [Boolean] continue although the harness version or prompts changed (State::Identity)
    # @return [Result]
    # @raise [ConfigError] when the run is not waiting, the number of answers is wrong, or what produced the run
    #   changed
    def answer(run_id, answers, stop: nil, accept_changes: false)
      store = store_for(run_id)
      locked(store) do
        run = store.read_run
        raise ConfigError, "run #{run_id} is not waiting for answers (status: #{run['status']})" unless run["status"] == "waiting"

        questions = Array(run["questions"])
        unless answers.size == questions.size
          raise ConfigError, "run #{run_id} has #{questions.size} blocking questions; got #{answers.size} answers"
        end

        warnings = State::Identity.check!(run["identity"], State::Identity.current(@config), accept: accept_changes)
        pairs = Array(run["answers"]) + questions.zip(answers)
        store.update_run({ "answers" => pairs, "questions" => [], "status" => "planning" })
        setup = Run.reattach(config: @config, store: store, parent_env: @env, cache_dir: @cache_dir)
        identity_changed(store, setup, warnings)
        client = Run.observe(@client_factory.call(store), setup.events)
        plan_and_run(store, setup, client, request_of(store), pairs, stop: stop)
      end
    end

    # @param run_id [String]
    # @return [Array<String>] the blocking questions a waiting run asks
    # @raise [ConfigError] when there is no such run
    def questions(run_id)
      Array(store_for(run_id).read_run["questions"])
    end

    # Continue a stopped or crashed run where it left off.
    # @param run_id [String]
    # @param stop [#call, nil] -> Boolean; true ends the run "stopped" at the next safe point (see Run#execute)
    # @param accept_changes [Boolean] continue although the harness version or prompts changed (State::Identity)
    # @return [Result]
    # @raise [ConfigError] when the run is unknown, a dry run, locked by another process, or what produced it changed
    def resume(run_id, stop: nil, accept_changes: false)
      store = store_for(run_id)
      locked(store) do
        run = store.read_run
        status = run["status"]
        return waiting_result(store, run) if status == "waiting"
        raise ConfigError, "run #{run_id} was a dry run and has no worktree; start a new run without --dry-run" if status == "dry_run"

        warnings = State::Identity.check!(run["identity"], State::Identity.current(@config), accept: accept_changes)
        setup = Run.reattach(config: @config, store: store, parent_env: @env, cache_dir: @cache_dir)
        identity_changed(store, setup, warnings)
        client = Run.observe(@client_factory.call(store), setup.events)
        if status == "planning" || !File.file?(store.plan_path)
          next plan_and_run(store, setup, client, request_of(store), Array(run["answers"]), stop: stop)
        end

        plan = Plan::PlanParser.parse(JSON.parse(File.read(store.plan_path, encoding: "UTF-8")))
        if %w[planned plan_rejected].include?(status)
          store.update_run({ "planOnly" => false })
          next planned(store, setup, client, check_given(setup, client, plan), stop: stop)
        end

        execute(store, setup, client, plan, resume: true, stop: stop)
      end
    end

    private

    # Record each accepted change as an event (the report lists them) and take the current identity, so the next
    # resume compares against what ran last (a run from before identities were recorded gets one here).
    # @return [void]
    def identity_changed(store, setup, warnings)
      warnings.each { |w| setup.events.emit(stage: "intake", kind: "accepted", subject: "identity", detail: w[0, 300]) }
      store.update_run({ "identity" => State::Identity.current(@config) })
    end

    # requireGreenBaseline: the run stops after intake, before any model call, and says which gates were red.
    # @return [Result]
    def red_baseline_stop(store, red)
      message = "the baseline already fails: #{red.join(', ')} (requireGreenBaseline); fix it, or run without the setting"
      store.update_run({ "status" => "failed", "exitCode" => 2, "error" => message })
      Result.new(run_id: store.run_id, status: "failed", exit_code: 2, outcome: nil, questions: [], issues: [],
                 plan_path: nil, error: message)
    end

    # Plan with the model, then go on as planned. A planner that never produced a usable plan ends the run "failed"
    # with the reason, so status, the report and --json say what happened instead of leaving it "planning".
    # @return [Result]
    def plan_and_run(store, setup, client, request, answers, stop: nil)
      result = plan_with_model(setup, client, request, answers)
      planned(store, setup, client, result, stop: stop)
    rescue ModelOutputError => e
      message = "planning failed: #{e.message}"[0, 500]
      store.update_run({ "status" => "failed", "exitCode" => 1, "error" => message })
      Result.new(run_id: store.run_id, status: "failed", exit_code: 1, outcome: nil, questions: [], issues: [],
                 plan_path: nil, error: message)
    end

    # @return [Plan::Planner::Result]
    def plan_with_model(setup, client, request, answers)
      Plan::Planner.new(client: client, config: @config, events: setup.events, cache_dir: @cache_dir)
                   .call(request: request, root: setup.worktree.root, stack: setup.stack, answers: answers,
                         unavailable: Plan::Checks.unavailable(setup.baseline))
    end

    # A dry run: intake and the baseline have run; a given plan is checked too, except against the context budget,
    # which needs the model. Nothing is planned or implemented, and the worktree is removed again (the branch stays,
    # like every run's). Exit 0 when nothing found would stop a real run, 1 for plan problems, 2 for a red baseline
    # with requireGreenBaseline.
    # @return [Result]
    def dry_run_result(store, setup, request, plan_hash)
      plan = plan_hash && Plan::PlanParser.parse(plan_hash)
      issues = plan ? check_given(setup, nil, plan, budget: nil).issues : []
      store.write_request(request) if request
      red = Array(store.read_run["baselineFailing"])
      found = {
        "stack" => setup.stack.name, "baseSha" => setup.worktree.base_sha, "branch" => setup.worktree.branch,
        "gates" => setup.baseline.values.map do |r|
          { "gate" => r.gate, "status" => r.status, "problems" => r.diagnostics.size, "reason" => r.reason }
        end,
        "baselineFailing" => red, "requireGreenBaseline" => @config.require_green_baseline,
        "next" => if plan then "run the plan's #{plan.tasks.size} task(s)"
                  elsif request then "plan the request with the model"
                  end
      }
      code = if !issues.empty? then 1
             elsif @config.require_green_baseline && !red.empty? then 2
             else 0
             end
      setup.worktree.remove(force: true)
      setup.events.emit(stage: "intake", kind: "accepted", subject: "dry run", detail: "stopped after intake and the checks: no model was called")
      store.update_run({ "status" => "dry_run", "exitCode" => code, "dryRun" => found })
      Result.new(run_id: store.run_id, status: "dry_run", exit_code: code, outcome: nil, questions: [], issues: issues,
                 plan_path: nil, dry_run: found)
    end

    # A plan from a file (or edited after --plan-only) is checked like a planner's, without replanning.
    # @param budget [Integer, nil, false] the implementer's context budget; false (the default) asks the model's
    #   profile for it, nil skips that check (a dry run calls no model)
    # @return [Plan::Planner::Result]
    def check_given(setup, client, plan, budget: false)
      if budget == false
        impl_system = Prompts.render("implement_system", rules: Prompts.render("edit_rules", files: "", tests: [], rewrite_bytes: @config.limits.whole_file_rewrite_max_bytes))
        budget = Task::Gather.budget(client: client, config: @config, role: :implementer, system: impl_system,
                                     schema: Task::EditSet::SCHEMA)
      end
      issues = Plan::Checks.run(plan, root: setup.worktree.root, max_files: @config.limits.max_files_per_task,
                                      protected: setup.stack.protected_paths, gates: setup.stack.gates.keys, budget: budget,
                                      unavailable: Plan::Checks.unavailable(setup.baseline),
                                      test_gates: Plan::Checks.test_gates(setup.stack))
      issues.each do |i|
        setup.events.emit(stage: "plan.check", kind: "rejected", task: i.task, reason: i.reason, detail: i.message[0, 300])
      end
      Plan::Planner::Result.new(plan: plan, rounds: 0, issues: issues)
    end

    # After planning: stop on problems, on blocking questions or for --plan-only; otherwise run the tasks.
    # @return [Result]
    def planned(store, setup, client, result, stop: nil)
      State.write_json(store.plan_path, result.plan.to_json_hash)
      unless result.issues.empty?
        store.update_run({ "status" => "plan_rejected", "exitCode" => 1 })
        return Result.new(run_id: store.run_id, status: "plan_rejected", exit_code: 1, outcome: nil, questions: [],
                          issues: result.issues, plan_path: store.plan_path)
      end

      blocking = result.plan.questions.select(&:blocking).map(&:text)
      unless blocking.empty?
        blocking.each { |q| setup.events.emit(stage: "plan", kind: "question", detail: q[0, 300]) }
        store.update_run({ "status" => "waiting", "questions" => blocking, "exitCode" => EXIT_WAITING })
        return waiting_result(store, store.read_run)
      end

      if store.read_run["planOnly"]
        store.update_run({ "status" => "planned", "exitCode" => 0 })
        return Result.new(run_id: store.run_id, status: "planned", exit_code: 0, outcome: nil, questions: [], issues: [],
                          plan_path: store.plan_path)
      end

      execute(store, setup, client, result.plan, resume: false, stop: stop)
    end

    # @return [Result]
    def execute(store, setup, client, plan, resume:, stop: nil)
      outcome = Run.new(config: @config, client: client, setup: setup, cache_dir: @cache_dir, stop: stop)
                   .execute(plan, resume: resume)
      Result.new(run_id: store.run_id, status: store.read_run["status"], exit_code: outcome.exit_code, outcome: outcome,
                 questions: [], issues: [], plan_path: store.plan_path)
    end

    # @return [Result]
    def waiting_result(store, run)
      Result.new(run_id: store.run_id, status: "waiting", exit_code: EXIT_WAITING, outcome: nil,
                 questions: Array(run["questions"]), issues: [], plan_path: store.plan_path)
    end

    # @return [String]
    # @raise [ConfigError]
    def request_of(store)
      store.read_request || raise(ConfigError, "run #{store.run_id} has no request.md to plan from")
    end

    # @return [State::RunStore]
    # @raise [ConfigError]
    def store_for(run_id)
      raise ConfigError, "run id #{run_id.inspect}: expected letters, digits, - or _" unless run_id.to_s.match?(Repo::Worktree::RUN_ID)

      store = State::RunStore.new(runs_dir: @runs_dir, run_id: run_id)
      raise ConfigError, "no run #{run_id} under #{File.basename(@runs_dir)}/" unless store.exist?

      store
    end

    # @return [Result]
    # @raise [ConfigError] when another process holds the run
    def locked(store)
      release = State::Lock.acquire(store.lock_path)
      raise ConfigError, "run #{store.run_id} is in use by another harness process" unless release

      begin
        yield
      ensure
        release.call
      end
    end
  end
end
