# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../model/client"
require_relative "../model/tokens"
require_relative "../prompts"
require_relative "../task/edits"
require_relative "../repo/map"
require_relative "../task/gather"
require_relative "../task/summarizer"
require_relative "../untrusted"
require_relative "checks"
require_relative "overview"
require_relative "plan"

module Harness
  module Plan
    # Calls the planner role, checks the plan, and feeds failed checks back (DESIGN.md 5.3). At most
    # maxReplanRounds replans; after that the plan and its problems go to the user.
    class Planner
      ACCEPTANCE_SCHEMA = {
        "type" => "object", "required" => ["kind"],
        "properties" => { "kind" => { "type" => "string", "enum" => ACCEPTANCE_KINDS }, "gate" => { "type" => "string" },
                          "path" => { "type" => "string" }, "write" => { "type" => "boolean" },
                          "describe" => { "type" => "string" }, "text" => { "type" => "string" } }
      }.freeze
      STRINGS = { "type" => "array", "items" => { "type" => "string" } }.freeze
      SCHEMA = {
        "type" => "object", "required" => ["tasks"],
        "properties" => {
          "tasks" => { "type" => "array", "items" => {
            "type" => "object", "required" => %w[id title intent files acceptance],
            "properties" => { "id" => { "type" => "string" }, "title" => { "type" => "string" }, "intent" => { "type" => "string" },
                              "files" => { "type" => "object", "properties" => { "create" => STRINGS, "modify" => STRINGS, "read" => STRINGS } },
                              "dependsOn" => STRINGS, "acceptance" => { "type" => "array", "items" => ACCEPTANCE_SCHEMA } }
          } },
          "questions" => { "type" => "array", "items" => { "type" => "object", "required" => ["text"],
                                                           "properties" => { "text" => { "type" => "string" }, "blocking" => { "type" => "boolean" } } } }
        }
      }.freeze

      # plan: the last plan; rounds: replans used; issues: empty when the plan passed every check.
      Result = Data.define(:plan, :rounds, :issues)

      # @param client [Model::Client]
      # @param config [Config]
      # @param events [State::Events]
      # @param cache_dir [String, nil] the context map's cache (.cache/); nil disables it
      def initialize(client:, config:, events:, cache_dir: nil)
        @client = client
        @config = config
        @events = events
        @cache_dir = cache_dir
      end

      # @param request [String] the user's feature request
      # @param root [String] worktree root
      # @param stack [Gates::Stack]
      # @param answers [Array<Array(String, String)>] [question, answer] pairs from harness answer
      # @param unavailable [Hash{String=>String}] gates the baseline could not run here, with why; never offered
      # @return [Result]
      # @raise [ModelOutputError, ModelUnavailableError, ContextOverflowError]
      def call(request:, root:, stack:, answers: [], unavailable: {})
        @events.emit(stage: "plan", kind: "stage_started")
        test_gates = Checks.test_gates(stack)
        system = Prompts.render("planner_system", max_files: @config.limits.max_files_per_task,
                                                  gates: (stack.gates.keys - unavailable.keys).join(", "),
                                                  tests: test_gates.empty? || !(test_gates - unavailable.keys).empty?)
        user = first_prompt(system, request, root, stack, answers)
        check_budget = implementer_budget
        rounds = 0
        loop do
          plan = ask(system, user, rounds)
          issues = Checks.run(plan, root: root, max_files: @config.limits.max_files_per_task, protected: stack.protected_paths,
                                    gates: stack.gates.keys, budget: check_budget, unavailable: unavailable,
                                    test_gates: test_gates)
          report(issues)
          return finish(plan, rounds, issues) if issues.empty? || rounds >= @config.limits.max_replan_rounds

          rounds += 1
          @events.emit(stage: "plan", kind: "retried", detail: "replan #{rounds}: #{issues.size} problems")
          user = "#{first_prompt(system, request, root, stack, answers)}\n\n" +
                 Prompts.render("planner_replan", plan: Untrusted.fence(JSON.pretty_generate(plan.to_json_hash)),
                                                  issues: Untrusted.fence(issues.map { |i| "- #{i.message}" }.join("\n")))
        end
      end

      private

      # @return [String]
      def first_prompt(system, request, root, stack, answers)
        budget = Harness::Task::Gather.budget(client: @client, config: @config, role: :planner, system: system, schema: SCHEMA)
        budget -= Model::Tokens.estimate(request)
        map = Repo::Map.new(root: root, cache_dir: @cache_dir, protected: stack.protected_paths)
        sections = Overview.sections(root: root, request: request, budget: [budget * 2 / 3, 0].max, protected: stack.protected_paths,
                                     map: map, summarize: Harness::Task::Summarizer.new(client: @client, config: @config))
        unless answers.empty?
          qa = answers.map { |q, a| "Q: #{q}\nA: #{a}" }.join("\n\n")
          sections << "Answers to your earlier questions:\n#{Untrusted.fence(qa)}"
        end
        Prompts.render("planner_user", request: request, sections: sections)
      end

      # The implementer's budget, for the "fits the context" check.
      # @return [Integer]
      def implementer_budget
        system = Prompts.render("implement_system", rules: Prompts.render("edit_rules", files: "", tests: []))
        Harness::Task::Gather.budget(client: @client, config: @config, role: :implementer, system: system, schema: Harness::Task::EditSet::SCHEMA)
      end

      # @return [Plan]
      def ask(system, user, rounds)
        c = @client.complete(:planner, Model::Messages.new(system: system, user: user), label: "plan#{rounds}",
                                                                                         parser: PlanParser.method(:parse), schema: SCHEMA)
        @events.emit(stage: "plan", kind: "accepted", subject: "#{c.value.tasks.size} tasks", attempt: rounds + 1, model: c.model,
                     profile: c.profile, tokens: { "in" => c.usage[:in], "out" => c.usage[:out] }, ms: c.ms)
        c.value
      rescue ModelOutputError => e
        @events.emit(stage: "plan", kind: "rejected", reason: e.reason, detail: e.message[0, 300], attempt: rounds + 1)
        raise
      end

      # @return [void]
      def report(issues)
        @events.emit(stage: "plan.check", kind: "stage_started")
        issues.each do |i|
          @events.emit(stage: "plan.check", kind: "rejected", task: i.task, reason: i.reason, detail: i.message[0, 300])
        end
        @events.emit(stage: "plan.check", kind: "accepted", detail: "all checks passed") if issues.empty?
        @events.emit(stage: "plan.check", kind: "stage_finished")
      end

      # @return [Result]
      def finish(plan, rounds, issues)
        @events.emit(stage: "plan", kind: "stage_finished", detail: issues.empty? ? "#{plan.tasks.size} tasks" : "gave up after #{rounds} replans")
        Result.new(plan: plan, rounds: rounds, issues: issues)
      end
    end
  end
end
