# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "errors"
require_relative "plan/checks"
require_relative "plan/plan"
require_relative "plan/planner"
require_relative "run"
require_relative "state/lock"
require_relative "state/run_store"
require_relative "task/edits"
require_relative "task/gather"

module Harness
  # The run lifecycle behind harness run, answer and resume: intake, planning (with blocking questions),
  # execution, and picking a stopped run up again. One process per run at a time (harness.lock).
  #
  # Run statuses in run.json: planning, waiting (on answers), planned (--plan-only), plan_rejected, running,
  # done, failed, stopped.
  class Pipeline
    EXIT_WAITING = 3

    # status: the run status; questions: blocking questions when waiting; issues: plan problems when rejected.
    Result = Data.define(:run_id, :status, :exit_code, :outcome, :questions, :issues, :plan_path)

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
    # @return [Result]
    # @raise [GitError, ConfigError, ParseError, ModelOutputError, ModelUnavailableError]
    def start(repo:, request: nil, plan_hash: nil, plan_only: false, run_id: nil)
      raise ArgumentError, "give a request or a plan" if request.nil? == plan_hash.nil?

      store = State::RunStore.new(runs_dir: @runs_dir, run_id: run_id || State::RunStore.new_run_id)
      raise ConfigError, "run #{run_id} already exists" if run_id && store.exist?
      locked(store) do
        setup = Run.intake(config: @config, repo: repo, store: store, parent_env: @env, cache_dir: @cache_dir)
        client = Run.observe(@client_factory.call(store), setup.events)
        store.update_run({ "planOnly" => plan_only })
        if request
          store.write_request(request)
          planned(store, setup, client, plan_with_model(setup, client, request, []))
        else
          planned(store, setup, client, check_given(setup, client, Plan::PlanParser.parse(plan_hash)))
        end
      end
    end

    # Record answers to the blocking questions, replan with them, and continue.
    # @param run_id [String]
    # @param answers [Array<String>] one per blocking question, in order
    # @return [Result]
    # @raise [ConfigError] when the run is not waiting, or the number of answers is wrong
    def answer(run_id, answers)
      store = store_for(run_id)
      locked(store) do
        run = store.read_run
        raise ConfigError, "run #{run_id} is not waiting for answers (status: #{run['status']})" unless run["status"] == "waiting"

        questions = Array(run["questions"])
        unless answers.size == questions.size
          raise ConfigError, "run #{run_id} has #{questions.size} blocking questions; got #{answers.size} answers"
        end

        pairs = Array(run["answers"]) + questions.zip(answers)
        store.update_run({ "answers" => pairs, "questions" => [], "status" => "planning" })
        setup = Run.reattach(config: @config, store: store, parent_env: @env, cache_dir: @cache_dir)
        client = Run.observe(@client_factory.call(store), setup.events)
        planned(store, setup, client, plan_with_model(setup, client, request_of(store), pairs))
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
    # @return [Result]
    # @raise [ConfigError] when the run is unknown, waiting for answers, or locked by another process
    def resume(run_id)
      store = store_for(run_id)
      locked(store) do
        run = store.read_run
        status = run["status"]
        return waiting_result(store, run) if status == "waiting"

        setup = Run.reattach(config: @config, store: store, parent_env: @env, cache_dir: @cache_dir)
        client = Run.observe(@client_factory.call(store), setup.events)
        if status == "planning" || !File.file?(store.plan_path)
          next planned(store, setup, client, plan_with_model(setup, client, request_of(store), Array(run["answers"])))
        end

        plan = Plan::PlanParser.parse(JSON.parse(File.read(store.plan_path, encoding: "UTF-8")))
        if %w[planned plan_rejected].include?(status)
          store.update_run({ "planOnly" => false })
          next planned(store, setup, client, check_given(setup, client, plan))
        end

        execute(store, setup, client, plan, resume: true)
      end
    end

    private

    # @return [Plan::Planner::Result]
    def plan_with_model(setup, client, request, answers)
      Plan::Planner.new(client: client, config: @config, events: setup.events, cache_dir: @cache_dir)
                   .call(request: request, root: setup.worktree.root, stack: setup.stack, answers: answers,
                         unavailable: Plan::Checks.unavailable(setup.baseline))
    end

    # A plan from a file (or edited after --plan-only) is checked like a planner's, without replanning.
    # @return [Plan::Planner::Result]
    def check_given(setup, client, plan)
      impl_system = Prompts.render("implement_system", rules: Prompts.render("edit_rules", files: "", tests: [], rewrite_bytes: @config.limits.whole_file_rewrite_max_bytes))
      budget = Task::Gather.budget(client: client, config: @config, role: :implementer, system: impl_system,
                                   schema: Task::EditSet::SCHEMA)
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
    def planned(store, setup, client, result)
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

      execute(store, setup, client, result.plan, resume: false)
    end

    # @return [Result]
    def execute(store, setup, client, plan, resume:)
      outcome = Run.new(config: @config, client: client, setup: setup, cache_dir: @cache_dir).execute(plan, resume: resume)
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
