# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../evidence/retrieve"
require_relative "../model/client"
require_relative "../model/tokens"
require_relative "../prompts"
require_relative "../task/gather"
require_relative "../untrusted"
require_relative "diff"
require_relative "findings"
require_relative "prompt_check"
require_relative "tools"
require_relative "verifier"

module Harness
  module Review
    # What the review stages share. task: the task id for events, nil in the final review.
    class Context
      attr_reader :client, :config, :label, :framework, :retriever, :notes

      # @param client [Model::Client]
      # @param config [Config]
      # @param events [State::Events]
      # @param task [String, nil]
      # @param label [String] prefix for model call labels
      # @param root [String] worktree root
      # @param protected [Array<String>]
      # @param map [Repo::Map, nil]
      # @param framework [Evidence::Framework]
      # @param retriever [Evidence::Retriever, nil]
      # @param notes [Array<String>] the stack's reviewNotes
      def initialize(client:, config:, events:, task:, label:, root:, protected:, map:, framework:, retriever:, notes: [])
        @client = client
        @config = config
        @events = events
        @task = task
        @label = label
        @root = root
        @protected = protected
        @map = map
        @framework = framework
        @retriever = retriever
        @notes = notes
      end

      # @return [Toolbox] a fresh one: each conversation has its own record of what it saw
      def toolbox
        Toolbox.new(root: @root, protected: @protected, map: @map, retriever: @retriever)
      end

      # @return [void]
      def emit(stage, kind, **fields)
        @events.emit(stage: stage, kind: kind, task: @task, **fields)
      end
    end

    # summary: from the first discovery run; accepted: claims that passed verification, the gate, the support
    # check and the challenge (candidates, not findings: only a failing test makes a finding, I8).
    Result = Data.define(:summary, :claims, :suspicious, :failures) do
      # @return [Array<Claim>]
      def accepted = claims.select { |c| c.outcome == "accept" }
    end

    # The review pipeline, ported from REVIEWER src/review/pipeline.js: two independent discovery passes with
    # deterministic checks and one re-evaluation, reconcile, then the Verifier. The input is a task diff (or the
    # run's diff for the final review).
    class Pipeline
      REEVALUATION_ROUNDS = 1
      MAX_CHUNKS = 6
      MAX_CHUNK_LINES = 1500
      DOCS_TERMS = 4
      DOCS_EXCERPT = 700
      API_IN_CODE = /\b(?:client|server|is|set|transition|define):[a-z][a-z-]*|\bAstro\.[a-zA-Z]+|astro:[a-z-]+|astro\/(?:zod|loaders|container)|
                     getStaticPaths|getCollection|getEntry|defineCollection|defineLiveCollection|defineAction|defineMiddleware|
                     import\.meta\.glob|<slot\b/x

      # @param ctx [Context]
      def initialize(ctx)
        @ctx = ctx
      end

      # @param diff [String] unified diff
      # @param subject [String] e.g. "task T1: Add the pricing card"
      # @param typecheck_passed [Boolean]
      # @return [Result]
      # @raise [ModelUnavailableError]
      def call(diff:, subject:, typecheck_passed:)
        failures = []
        @summary = nil
        @suspicious = []
        rules = Prompts.render("review_rules", notes: @ctx.notes)
        systems = [Prompts.render("review_system", rules: rules), Prompts.render("review_independent_system", rules: rules)]
        prepared = Diff.prepare(diff, max_lines: MAX_CHUNK_LINES, max_chars: chunk_chars(systems.first), max_chunks: MAX_CHUNKS)
        prepared.skipped.each { |path, why| @ctx.emit("review.discover", "skipped", subject: path, detail: why) }
        prepared.omitted.each { |path, why| @ctx.emit("review.discover", "skipped", subject: path, detail: why) }
        files = prepared.chunks.flat_map(&:files)
        docs = docs_for_change(files)
        runs = systems.each_with_index.map do |system, i|
          prepared.chunks.each_with_index.flat_map do |chunk, n|
            discover(system, chunk, n, prepared, subject, docs, "discovery-#{i + 1}", failures)
          end
        end
        candidates = Findings.reconcile(runs[0], runs[1])
        @ctx.emit("review.reconcile", "stage_finished", detail: "run1=#{runs[0].size} run2=#{runs[1].size} distinct=#{candidates.size}")
        ids = candidates.each_with_index.map { |f, i| ["C#{i + 1}", f] }
        claims = ids.empty? ? [] : Verifier.new(@ctx).call(ids, files, typecheck_passed: typecheck_passed)
        Result.new(summary: @summary.to_s, claims: claims, suspicious: @suspicious.uniq, failures: failures)
      end

      private

      # One discovery run over one chunk: ask, check, re-evaluate once with the facts.
      # @return [Array<Finding>]
      def discover(system, chunk, n, prepared, subject, docs, run, failures)
        not_shown = (prepared.skipped + prepared.omitted).first(30).map { |p, why| "#{p} (#{why})" }.join(", ")
        user = Prompts.render("review_user", framework: @ctx.framework.line, docs: docs, part: n + 1, parts: prepared.chunks.size,
                                             subject: subject, files: chunk.files.map(&:path).join(", "), not_shown: not_shown,
                                             diff: Untrusted.fence(chunk.text))
        problems = PromptCheck.problems("discovery", system: system, user: user, files: chunk.files.map(&:path))
        unless problems.empty?
          failures << "#{run}: prompt check failed: #{problems.join('; ')}"
          @ctx.emit("review.discover", "rejected", subject: run, reason: "claim.failed_checks", detail: failures.last[0, 300])
          return []
        end
        @ctx.emit("review.discover", "stage_started", subject: run)
        c = ask(system, user, [], run)
        kept, rejected = Findings.validate(c.value.findings, chunk.files)
        REEVALUATION_ROUNDS.times do
          break if rejected.empty?

          rejected.each { |r| @ctx.emit("review.discover", "rejected", subject: run, reason: "claim.failed_checks", detail: r.fact[0, 300]) }
          history = [{ "role" => "user", "content" => user }, { "role" => "assistant", "content" => c.text }]
          facts = rejected.first(12).each_with_index.map { |r, i| "#{i + 1}. #{r.fact}" }.join("\n")
          c = ask(system, Prompts.render("review_reeval", facts: Untrusted.fence(facts)), history, "#{run}.reevaluate")
          kept, rejected = Findings.validate(c.value.findings, chunk.files)
        end
        rejected.each { |r| @ctx.emit("review.discover", "rejected", subject: run, reason: "claim.failed_checks", detail: r.fact[0, 300]) }
        @summary ||= c.value.summary
        @suspicious.concat(Untrusted.filter_model_suspicious(c.value.suspicious, chunk.text))
        @ctx.emit("review.discover", "stage_finished", subject: run, detail: "#{kept.size} claims passed the checks")
        kept.map { |f| f.with(found_by: [run]) }
      rescue ModelOutputError, ContextOverflowError => e
        failures << "#{run}: #{e.message[0, 200]}"
        @ctx.emit("review.discover", "rejected", subject: run, reason: e.is_a?(ModelOutputError) ? e.reason : "model.context_overflow",
                                                 detail: e.message[0, 300])
        []
      end

      # @return [Model::Completion]
      def ask(system, user, history, label)
        @ctx.client.complete(:reviewer, Model::Messages.new(system: system, user: user, history: history), label: "#{@ctx.label}.#{label}",
                                                                                                          schema: Findings::SCHEMA, parser: Findings.method(:parse))
      end

      # Room for one chunk of diff, from the reviewer's context.
      # @return [Integer]
      def chunk_chars(system)
        budget = Task::Gather.budget(client: @ctx.client, config: @ctx.config, role: :reviewer, system: system, schema: Findings::SCHEMA)
        [(budget * 0.6 * Model::Tokens::BYTES_PER_TOKEN).to_i, 2000].max
      end

      # Version-matched docs for the framework APIs the changed code uses, looked up by trusted code. Context for
      # discovery only, never evidence by itself.
      # @return [String]
      def docs_for_change(files)
        return "" unless @ctx.retriever

        code = files.flat_map { |f| f.code.reject { |l| l.kind == "-" }.map(&:text) }.join("\n")
        terms = code.scan(API_IN_CODE).map { |t| t.delete_prefix("<") }.uniq.first(DOCS_TERMS)
        parts = terms.filter_map do |t|
          r = @ctx.retriever.lookup(query: t)
          recs = r.evidence.select(&:version_matched).first(1).map { |e| e.with(excerpt: e.excerpt[0, DOCS_EXCERPT]) }
          Evidence::Retriever.format(r.with(evidence: recs, notes: [])) unless recs.empty?
        end
        parts.empty? ? "" : Untrusted.fence(parts.join("\n"))
      end
    end
  end
end
