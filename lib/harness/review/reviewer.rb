# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../evidence/local_docs"
require_relative "../evidence/retrieve"
require_relative "../evidence/version"
require_relative "../plan/plan"
require_relative "confirm"
require_relative "pipeline"

module Harness
  module Review
    # A follow-up fix task made from a confirmed claim, and the failing test it must make pass.
    FollowUp = Data.define(:task, :test_path, :test_content)

    # The review hook of the task loop and the final review (DESIGN.md 5.4 step 6, 5.5, 8). Review never blocks a
    # commit: claims confirmed by a failing test become follow-up fix tasks (at most maxReviewFixTasks per task),
    # and everything else is recorded for the report. Only confirmed claims are findings (I8).
    class Reviewer
      TYPE_PARSERS = %w[tsc astro_check].freeze
      FOLLOW_UP_ID = /R\d+\z/

      # @param client [Model::Client]
      # @param config [Config]
      # @param worktree [Repo::Worktree]
      # @param stack [Gates::Stack]
      # @param runner [Gates::Runner]
      # @param baseline [Hash{String=>Gates::Result}]
      # @param events [State::Events]
      # @param store [State::RunStore]
      # @param map [Repo::Map, nil]
      # @param cache_dir [String, nil]
      def initialize(client:, config:, worktree:, stack:, runner:, baseline:, events:, store:, map: nil, cache_dir: nil)
        @client = client
        @config = config
        @worktree = worktree
        @stack = stack
        @runner = runner
        @baseline = baseline
        @events = events
        @store = store
        @map = map
        @framework, @retriever = evidence(cache_dir)
        @follow_ups = {}
      end

      # Review one task's change before its commit.
      # @param task [Plan::Task]
      # @param diff [String]
      # @param gates [Array<Gates::Baseline::Comparison>] the task's last gate results
      # @return [Hash] the review record, also saved as tasks/<id>/review.json
      def call(task:, diff:, gates:)
        record = review(task.id, diff, "task #{task.id}", typecheck_passed?(gates), task.id)
        confirmed = record.delete(:confirmed)
        # A follow-up's own confirmed claims are recorded but make no further tasks, so fixes do not chain.
        unless task.id.match?(FOLLOW_UP_ID)
          @follow_ups[task.id] = confirmed.first(@config.limits.max_review_fix_tasks).each_with_index.map do |c, i|
            follow_up(task, c, i + 1)
          end
        end
        @store.write_task_file(task.id, "review.json", record)
        record
      rescue ModelUnavailableError => e
        @events.emit(stage: "review.discover", kind: "rejected", task: task.id, reason: "model.unavailable", detail: e.message[0, 300])
        {}
      end

      # @param task_id [String]
      # @return [Array<FollowUp>] confirmed claims of that task, as fix tasks; each is returned once
      def follow_ups(task_id)
        @follow_ups.delete(task_id) || []
      end

      # The review of the whole run's diff after integration. Confirmed claims are findings in the report; no
      # follow-up tasks are made at this point.
      # @param diff [String]
      # @param typecheck_passed [Boolean]
      # @return [Hash] the review record, also saved as final_review.json
      def final(diff:, typecheck_passed:)
        @events.emit(stage: "final_review", kind: "stage_started")
        record = review(nil, diff, "the whole run", typecheck_passed, "final")
        record.delete(:confirmed)
        State.write_json(@store.final_review_path, record)
        @events.emit(stage: "final_review", kind: "stage_finished",
                     detail: "#{record['findings'].size} findings, #{record['questions'].size} questions")
        record
      rescue ModelUnavailableError => e
        @events.emit(stage: "final_review", kind: "rejected", reason: "model.unavailable", detail: e.message[0, 300])
        {}
      end

      private

      # @return [Hash]
      def review(task_id, diff, subject, typecheck_passed, name)
        ctx = Context.new(client: @client, config: @config, events: @events, task: task_id, label: "#{name}.review",
                          root: @worktree.root, protected: @stack.protected_paths, map: @map, framework: @framework,
                          retriever: @retriever)
        result = Pipeline.new(ctx).call(diff: diff, subject: subject, typecheck_passed: typecheck_passed)
        confirm = Confirm.new(ctx: ctx, stack: @stack, runner: @runner, baseline: @baseline, root: @worktree.root, name: name)
        confirmations = result.accepted.map { |c| confirm.call(c) }
        confirmed = confirmations.select { |c| c.status == "confirmed" }
        {
          "summary" => result.summary,
          "findings" => confirmed.map { |c| claim_json(c.claim).merge("test" => c.test_path) },
          "questions" => confirmations.reject { |c| c.status == "confirmed" }.map { |c| claim_json(c.claim).merge("reason" => c.reason, "detail" => c.detail) },
          "abstained" => result.claims.select { |c| c.outcome == "abstain" }.map { |c| claim_json(c) },
          "rejected" => result.claims.select { |c| c.outcome == "reject" }.map { |c| claim_json(c) },
          "suspicious" => result.suspicious,
          "failures" => result.failures,
          :confirmed => confirmed
        }
      end

      # @return [Hash]
      def claim_json(c)
        f = c.finding
        { "id" => c.id, "file" => f.file, "line" => f.line, "severity" => c.severity, "problem" => f.problem,
          "outcome" => c.outcome, "reason" => c.reason, "reasons" => c.reasons, "foundBy" => f.found_by,
          "citations" => c.citations.map { |x| { "id" => x.evidence.id, "ref" => x.evidence.ref, "url" => x.evidence.url, "quote" => x.quote } } }
      end

      # @return [FollowUp]
      def follow_up(task, confirmation, n)
        c = confirmation.claim
        acceptance = [Plan::Acceptance.new(kind: "test", gate: nil, path: confirmation.test_path, write: true,
                                           describe: "fails while the defect is present", text: nil)]
        acceptance += task.acceptance.select { |a| a.kind == "gate" }
        fix = Plan::Task.new(id: "#{task.id}R#{n}", title: "Fix: #{c.finding.problem[0, 80]}",
                             intent: "A review of #{task.id} found this defect, and the test #{confirmation.test_path} confirms it: " \
                                     "#{c.finding.problem} Make that test pass without weakening it.",
                             files: Plan::Files.new(create: [], modify: [c.finding.file], read: []),
                             depends_on: [task.id], acceptance: acceptance)
        FollowUp.new(task: fix, test_path: confirmation.test_path, test_content: confirmation.test_content)
      end

      # The typecheck passed when every gate with a type-checking parser was ok.
      # @return [Boolean]
      def typecheck_passed?(gates)
        typed = gates.select { |cmp| TYPE_PARSERS.include?(@stack.gates[cmp.gate]&.parser) }
        !typed.empty? && typed.all?(&:ok?)
      end

      # @return [Array(Evidence::Framework, Evidence::Retriever)]
      def evidence(cache_dir)
        name = @stack.framework["name"] || @stack.name
        package = @stack.framework["lockfilePackage"] || @stack.name
        framework = Evidence::Version.detect(@worktree.root, name: name, package: package)
        local = @stack.docs["local"].is_a?(String) ? Evidence::LocalDocs.load(root: @stack.docs["local"], cache_dir: cache_dir) : nil
        retriever = local ? Evidence::Retriever.new(framework: framework, local_docs: local, site_url: @stack.docs["siteUrl"]) : nil
        [framework, retriever]
      end
    end
  end
end
