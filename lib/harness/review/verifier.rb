# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../model/client"
require_relative "../prompts"
require_relative "../untrusted"
require_relative "gate"
require_relative "prompt_check"
require_relative "tools"
require_relative "verify"

module Harness
  module Review
    # A candidate after verification. outcome: accept | reject | abstain; reason: the reason code that decided it.
    Claim = Data.define(:id, :finding, :outcome, :reason, :reasons, :severity, :verdict, :citations, :excerpt)

    # Run 2 and the checks after it (DESIGN.md 8): adversarial verification with fetch tools, the gate, the
    # support check for docs-backed accepts, and a challenge on every accept. Failures abstain; they never
    # accept or reject.
    class Verifier
      BATCH = 3
      SUPPORT_PASSAGES = 2
      FRAMEWORK_QUERY = /\b(?:Astro\.[A-Za-z.]+|astro:[a-z-]+|(?:client|server|is|set|transition):[a-z-]+|getStaticPaths|getCollection|
                          getEntry|defineCollection|defineConfig|defineMiddleware|defineAction|import\.meta\.glob|prerender|<slot|slot)\b/x

      # @param ctx [Context]
      def initialize(ctx)
        @ctx = ctx
      end

      # @param candidates [Array<Array(String, Finding)>] claim ids and claims
      # @param files [Array<DiffFile>]
      # @param typecheck_passed [Boolean]
      # @return [Array<Claim>]
      def call(candidates, files, typecheck_passed:)
        @files = files.to_h { |f| [f.path, f] }
        @typecheck_passed = typecheck_passed
        out = []
        refuted = 0
        queue = candidates.each_slice(BATCH).to_a
        while (batch = queue.shift)
          if (why = stop_reason(refuted))
            # A field run spent 68 verifier calls (48 minutes) on one task's review and found nothing. The claims
            # left are not dropped: they are recorded as abstained, with the reason, and the report lists them.
            @ctx.emit("review.verify", "skipped", detail: "#{why}; #{queue.flatten(1).size + batch.size} claims left unverified")
            (batch + queue.flatten(1)).each { |id, f| out << conclude(id, f, nil, abstained(why)) }
            break
          end
          verdicts = verify_batch(batch)
          if verdicts.is_a?(String)
            if batch.size > 1
              @ctx.emit("review.verify", "split", detail: "#{verdicts[0, 200]}; retrying the #{batch.size} claims one at a time")
              queue.unshift(*batch.map { |c| [c] })
            else
              out.concat(batch.map { |id, f| conclude(id, f, nil, Decision.new(outcome: "abstain", reason: "verify.abstained", reasons: [verdicts], citations: [], code_quote_valid: false, framework_claim: false)) })
            end
            next
          end
          batch.each_with_index do |(id, f), i|
            verdict, seen = verdicts[i]
            decision = Gate.decide(finding: f, verdict: verdict, seen: seen, evidence: ->(e) { @ctx.retriever&.get(e) },
                                   framework: @ctx.framework.name.to_s, typecheck_passed: typecheck_passed)
            why = decision.outcome == "accept" ? stop_reason(refuted) : nil
            decision = abstained(why) if why
            decision = support(id, f, verdict, decision) if decision.outcome == "accept"
            decision = challenge(id, f, decision) if decision.outcome == "accept"
            refuted = decision.outcome == "reject" ? refuted + 1 : 0
            out << conclude(id, f, verdict, decision)
          end
        end
        out
      end

      private

      # Why the review should stop verifying, or nil: the run's verifier budget is spent, or the last claims were
      # all refuted, which says the discovery step is guessing.
      # @return [String, nil]
      def stop_reason(refuted)
        limits = @ctx.config.limits
        if @ctx.client.respond_to?(:calls) && @ctx.client.calls[:verifier] >= limits.max_verifier_calls
          return "the run's verifier budget (maxVerifierCalls #{limits.max_verifier_calls}) is spent"
        end
        return "#{refuted} claims in a row were refuted (maxRefutedInARow)" if refuted >= limits.max_refuted_in_a_row

        nil
      end

      # @return [Decision]
      def abstained(why)
        Decision.new(outcome: "abstain", reason: "verify.abstained", reasons: [why], citations: [], code_quote_valid: false,
                     framework_claim: false)
      end

      # @return [Array<Array(Hash, String)>, String] per claim [verdict, code seen], or why the batch failed
      def verify_batch(batch)
        system = Prompts.render("verify_system", notes: @ctx.notes)
        claims = batch.each_with_index.map { |(_, f), i| claim_block(i + 1, f) }.join("\n\n")
        user = Prompts.render("verify_user", framework: @ctx.framework.line, count: batch.size,
                                             claims: Untrusted.fence(claims), prefetched: prefetch(batch))
        problems = PromptCheck.problems("verify", system: system, user: user, claims: batch.map { |_, f| f.problem })
        return "verification prompt check failed: #{problems.join('; ')}" unless problems.empty?

        @ctx.emit("review.verify", "stage_started", subject: batch.map(&:first).join(","))
        toolbox = @ctx.toolbox
        research = ToolLoop.run(client: @ctx.client, role: :verifier, system: system, user: user, label: "#{@ctx.label}.verify",
                                toolbox: toolbox, max_calls: @ctx.config.limits.max_lookups)
        history = research.history + [{ "role" => "assistant", "content" => research.text.to_s.empty? ? "DONE" : research.text }]
        c = @ctx.client.complete(:verifier, Model::Messages.new(system: system, user: Prompts.render("verify_final"), history: history),
                                 label: "#{@ctx.label}.verify", schema: Verify::VERDICT_SCHEMA,
                                 parser: ->(o) { Verify.parse_verdicts(o, batch.size) })
        @ctx.emit("review.verify", "stage_finished", detail: "#{toolbox.calls.size} lookups", tokens: { "in" => c.usage[:in], "out" => c.usage[:out] }, ms: c.ms)
        batch.each_index.map do |i|
          f = batch[i][1]
          [c.value[i + 1], "#{Verify.excerpt_code(@files[f.file], f.line)}\n#{toolbox.seen}"]
        end
      rescue ModelOutputError, ContextOverflowError => e
        "verification failed: #{e.message[0, 200]}"
      end

      # @return [String]
      def claim_block(n, f)
        [
          "CLAIM #{n}", "file: #{f.file}", "line: #{f.line}", "claimed problem: #{f.problem}",
          f.mechanism.empty? ? nil : "claimed mechanism: #{f.mechanism}",
          f.preconditions.empty? ? nil : "claimed preconditions: #{f.preconditions}",
          "excerpt (new-file line number, then + added / - removed / space unchanged):",
          @files[f.file] ? Verify.excerpt(@files[f.file], f.line) : "(not in the change)"
        ].compact.join("\n")
      end

      # Version-matched docs for framework claims, fetched by trusted code so verification does not depend on the
      # model choosing to look.
      # @return [String]
      def prefetch(batch)
        return "" unless @ctx.retriever

        parts = batch.filter_map do |_, f|
          next unless Gate.framework_claim?(f, nil, @ctx.framework.name.to_s)

          ids = "#{f.problem} #{f.evidence}".scan(FRAMEWORK_QUERY).uniq.join(" ")
          Evidence::Retriever.format(@ctx.retriever.lookup(query: ids.empty? ? f.problem[0, 160] : ids))
        end
        parts.empty? ? "" : Untrusted.fence(parts.join("\n"))
      end

      # An accept that rests on docs needs an independent call to say the passage establishes the claim.
      # @return [Decision]
      def support(id, f, verdict, decision)
        cites = decision.citations.select { |c| c.relation == "supports" && c.evidence.version_matched }
        return decision if cites.empty?

        cites.first(SUPPORT_PASSAGES).each do |cite|
          data = ["CLAIM: #{f.problem}", "CODE: #{verdict['code_quote']}",
                  "DOCUMENTATION (#{cite.evidence.docs_version}, #{cite.evidence.url || cite.evidence.ref}):", cite.evidence.excerpt].join("\n")
          c = @ctx.client.complete(:verifier, Model::Messages.new(system: Prompts.render("support_system"), user: Untrusted.fence(data)),
                                   label: "#{@ctx.label}.support", schema: Verify::SUPPORT_SCHEMA)
          ok, why = Verify.parse_support(c.value)
          if ok
            @ctx.emit("review.support", "accepted", subject: subject(id, f), detail: "#{cite.evidence.id}: #{why}")
            return decision.with(reasons: decision.reasons + ["support check: #{cite.evidence.id} establishes it (#{why})"])
          end
        rescue ModelOutputError, ContextOverflowError
          next
        end
        @ctx.emit("review.support", "rejected", subject: subject(id, f), reason: "support.docs_do_not_establish")
        decision.with(outcome: "abstain", reason: "support.docs_do_not_establish",
                      reasons: ["support check: the cited documentation is related but does not establish this claim"] + decision.reasons)
      end

      # Every accept must survive a fresh call that argues for the code, with the same fetch tools.
      # @return [Decision]
      def challenge(id, f, decision)
        file = @files[f.file]
        return abstain(decision, "challenge.defence_holds", "no code excerpt to challenge against") unless file

        report = Untrusted.fence(["file: #{f.file}", "line: #{f.line}", "report: #{f.problem}", "code:", Verify.excerpt(file, f.line)].join("\n"))
        system = Prompts.render("challenge_system")
        research = ToolLoop.run(client: @ctx.client, role: :verifier, system: system, user: Prompts.render("challenge_user", report: report),
                                label: "#{@ctx.label}.challenge", toolbox: @ctx.toolbox, max_calls: @ctx.config.limits.max_lookups)
        history = research.history + [{ "role" => "assistant", "content" => research.text.to_s.empty? ? "DONE" : research.text }]
        c = @ctx.client.complete(:verifier, Model::Messages.new(system: system, user: Prompts.render("challenge_final"), history: history),
                                 label: "#{@ctx.label}.challenge", schema: Verify::CHALLENGE_SCHEMA)
        result = Verify.parse_challenge(c.value)
        case result.result
        when "survives"
          @ctx.emit("review.challenge", "accepted", subject: subject(id, f), detail: result.why[0, 300])
          decision.with(reasons: decision.reasons + ["challenge: survived (#{result.why})"])
        when "abstain"
          @ctx.emit("review.challenge", "rejected", subject: subject(id, f), reason: "verify.unseen_code", detail: result.why[0, 300])
          abstain(decision, "verify.unseen_code", "challenge: #{result.why}")
        else
          @ctx.emit("review.challenge", "rejected", subject: subject(id, f), reason: "challenge.defence_holds", detail: result.why[0, 300])
          abstain(decision, "challenge.defence_holds", "challenge: the defence holds (#{result.why})")
        end
      rescue ModelOutputError, ContextOverflowError => e
        @ctx.emit("review.challenge", "rejected", subject: subject(id, f), reason: "challenge.defence_holds", detail: "challenge failed: #{e.message[0, 200]}")
        abstain(decision, "challenge.defence_holds", "challenge failed: #{e.message[0, 200]}")
      end

      # @return [Decision]
      def abstain(decision, reason, why)
        decision.with(outcome: "abstain", reason: reason, reasons: [why] + decision.reasons)
      end

      # @return [Claim]
      def conclude(id, f, verdict, decision)
        kind = decision.outcome == "accept" ? "accepted" : "rejected"
        @ctx.emit("review.judge", kind, subject: subject(id, f), reason: decision.reason, detail: decision.reasons.first.to_s[0, 300])
        Claim.new(id: id, finding: f, outcome: decision.outcome, reason: decision.reason, reasons: decision.reasons,
                  severity: Gate.demonstrated_severity(f, verdict), verdict: verdict, citations: decision.citations,
                  excerpt: @files[f.file] ? Verify.excerpt(@files[f.file], f.line) : "")
      end

      # @return [String]
      def subject(id, f) = "claim #{id} (#{f.where})"
    end
  end
end
