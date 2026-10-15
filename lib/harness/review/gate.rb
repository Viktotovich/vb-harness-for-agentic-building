# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  module Review
    # A docs citation that passed the verbatim check. relation: "supports" or "contradicts".
    Citation = Data.define(:evidence, :quote, :relation)
    # outcome: accept | reject | abstain. reason: the reason code (DESIGN.md 10.3) for reject and abstain.
    Decision = Data.define(:outcome, :reason, :reasons, :citations, :code_quote_valid, :framework_claim)

    # The evidence gate: code, not a model, decides whether a claim survives verification. Ported from REVIEWER
    # src/review/gate.js, with two rules from DESIGN.md 8:
    # - a verdict whose reasoning depends on code that was neither shown nor fetched abstains (verify.unseen_code);
    # - a claim that needs a value outside its declared type is rejected when the typecheck gate passed
    #   (verify.requires_type_violation).
    # accept needs a verifier "accept", no contradicted statement, a code quote verbatim in the code the verifier
    # saw, a concrete trigger, and, for a framework claim, a verbatim version-matched docs citation that supports
    # it. reject needs checkable evidence: a verbatim refutation quote or a contradicting docs citation. Model
    # confidence and agreement between runs never count.
    module Gate
      MIN_QUOTE = 12
      MIN_TRIGGER = 15
      # Claim markers per framework (lowercase name). A marked claim needs docs to be accepted.
      MARKERS = {
        "astro" => /\bAstro\.[a-z]|astro:[a-z]|\b(?:client|server|is|set|transition|define):[a-z]|getStaticPaths|getCollection|
                   getEntry|defineCollection|defineConfig|defineMiddleware|defineAction|content\.config|import\.meta\.glob|
                   \bprerender\b|<slot\b|\bslot=|\bastro\b/xi
      }.freeze
      LANGUAGE = /\A(?:none|language|javascript|typescript|js|ts)?\z/i
      RANK = { "low" => 1, "medium" => 2, "high" => 3 }.freeze

      # @param finding [Finding]
      # @param verdict [Hash, nil]
      # @param framework [String] the stack's framework name
      # @return [Boolean] whether the claim is about the stack's framework
      def self.framework_claim?(finding, verdict, framework)
        markers = MARKERS[framework.to_s.downcase]
        if markers
          return true if finding.problem.match?(markers)
          return true if finding.file.end_with?(".#{framework.to_s.downcase}") && "#{finding.problem} #{finding.evidence}".match?(markers)
        end
        verdict&.fetch("claim_type", nil) == "framework-api" && !framework.to_s.empty? &&
          verdict["framework"].to_s.downcase.include?(framework.to_s.downcase)
      end

      # @return [Boolean] a claim about another library, for which no docs source exists
      def self.other_framework?(finding, verdict, framework)
        verdict&.fetch("claim_type", nil) == "framework-api" && !framework_claim?(finding, verdict, framework) &&
          !verdict["framework"].to_s.strip.match?(LANGUAGE)
      end

      # Is quote verbatim (whitespace-normalised) inside text? A code quote may skip lines when every quoted line
      # appears in order.
      # @param quote [String, nil]
      # @param text [String]
      # @param code [Boolean]
      # @return [Boolean]
      def self.quote_in?(quote, text, code: false)
        plain = ->(s) { code ? s.to_s : s.to_s.gsub(/[\x60*_]+/, "") }
        q = squash(plain.call(code ? strip_code(quote) : quote))
        return false if q.size < MIN_QUOTE
        return true if squash(plain.call(text)).include?(q)
        return false unless code

        quoted = strip_code(quote).split(/\r?\n/).map { |l| squash(l) }.reject(&:empty?)
        return false if quoted.size < 2

        lines = text.to_s.split(/\r?\n/).map { |l| squash(l) }
        at = 0
        quoted.all? do |ql|
          idx = (at...lines.size).find { |i| lines[i].include?(ql) }
          at = idx + 1 if idx
          idx
        end
      end

      # @param finding [Finding]
      # @param verdict [Hash, nil] parsed verifier output for this claim
      # @param seen [String] the code the verifier saw: the excerpt and every fetched file range
      # @param evidence [#call] id -> Evidence::Record or nil
      # @param framework [String]
      # @param typecheck_passed [Boolean]
      # @return [Decision]
      def self.decide(finding:, verdict:, seen:, evidence:, framework:, typecheck_passed:)
        fw = framework_claim?(finding, verdict, framework)
        return decision("abstain", "verify.abstained", ["verification did not produce a usable verdict"], [], false, fw) unless verdict

        notes = []
        citations = cite(verdict, evidence, notes)
        matched = ->(c) { c.evidence.source_type == "official-docs" && c.evidence.version_matched }
        supports = citations.select { |c| c.relation == "supports" && matched.call(c) }
        contradicts = citations.select { |c| c.relation == "contradicts" && matched.call(c) }
        quote_ok = quote_in?(verdict["code_quote"], seen, code: true)
        refuted = quote_in?(verdict["refutation_quote"], seen, code: true)
        make = ->(outcome, reason, reasons) { decision(outcome, reason, reasons + notes, citations, quote_ok, fw) }

        if verdict["requires_type_violation"] == true && typecheck_passed
          return make.call("reject", "verify.requires_type_violation",
                           ["the failure needs a value outside its declared type, and the typecheck gate passed"])
        end

        case verdict["verdict"]
        when "reject"
          return make.call("reject", "verify.contradicted_by_docs", ["contradicted by version-matched docs (#{contradicts.map { |c| c.evidence.id }.join(', ')})"]) unless contradicts.empty?
          return make.call("reject", "verify.refuted_by_code", ["refuted by code the verifier saw"]) if refuted

          false_statements = Array(verdict["false_statements"])
          why = false_statements.empty? ? "the verifier rejected the claim without grounded evidence" : "the verifier says the claim is false (#{false_statements.join('; ')[0, 200]}) but gave no checkable evidence"
          make.call("abstain", "verify.no_evidence", [why])
        when "accept"
          if verdict["depends_on_unseen"] == true
            return make.call("abstain", "verify.unseen_code", ["depends on code not shown or fetched: #{verdict['unseen'].to_s[0, 200]}"])
          end

          reasons = accept_problems(verdict, quote_ok, supports, contradicts, fw, other_framework?(finding, verdict, framework))
          return make.call("accept", nil, ["all evidence requirements met"]) if reasons.empty?

          reason = contradicts.empty? ? "verify.no_evidence" : "verify.contradicted_by_docs"
          make.call("abstain", reason, reasons)
        else
          make.call("abstain", verdict["depends_on_unseen"] == true ? "verify.unseen_code" : "verify.abstained",
                    ["verifier abstained#{verdict['reason'].to_s.empty? ? '' : ": #{verdict['reason'].to_s[0, 200]}"}"])
        end
      end

      # Published severity never exceeds the impact the verifier demonstrated.
      # @param finding [Finding]
      # @param verdict [Hash, nil]
      # @return [String]
      def self.demonstrated_severity(finding, verdict)
        impact = RANK.key?(verdict&.fetch("impact", nil)) ? verdict["impact"] : "low"
        RANK.fetch(finding.severity, 1) <= RANK[impact] ? finding.severity : impact
      end

      # @return [Array<String>]
      def self.accept_problems(verdict, quote_ok, supports, contradicts, framework_claim, other)
        reasons = []
        fs = verdict["false_statements"]
        if !fs.is_a?(Array) then reasons << "no false_statements list"
        elsif !fs.empty? then reasons << "verifier lists contradicted statements: #{fs.join('; ')[0, 200]}"
        end
        reasons << "code_quote is not verbatim in the code the verifier saw" unless quote_ok
        trigger = verdict["trigger"].to_s.strip.size >= MIN_TRIGGER
        docs = !supports.empty? && verdict["preconditions"].to_s.strip.size >= MIN_TRIGGER
        reasons << "no concrete trigger" unless trigger || docs
        reasons << "framework claim without a verbatim, version-matched docs citation that supports it" if framework_claim && supports.empty?
        reasons << "version-matched docs contradict it (#{contradicts.map { |c| c.evidence.id }.join(', ')})" unless contradicts.empty?
        reasons << "claim depends on #{verdict['framework'].to_s[0, 40]} behaviour; no documentation source is available for it" if other
        reasons
      end

      # @return [Array<Citation>] citations whose quote is verbatim in the cited record
      def self.cite(verdict, evidence, notes)
        Array(verdict["citations"]).filter_map do |c|
          next unless c.is_a?(Hash)

          rec = evidence.call(c["evidence_id"].to_s)
          relation = %w[supports contradicts].include?(c["relation"]) ? c["relation"] : nil
          if rec.nil? then notes << "citation #{c['evidence_id']} does not exist (ignored)"
          elsif relation.nil? then notes << "citation #{rec.id} has no supports/contradicts relation (ignored)"
          elsif !quote_in?(c["quote"], rec.excerpt) then notes << "citation #{rec.id}: quoted text is not in the retrieved passage (ignored)"
          else next Citation.new(evidence: rec, quote: squash(c["quote"])[0, 300], relation: relation)
          end
          nil
        end
      end

      # @return [Decision]
      def self.decision(outcome, reason, reasons, citations, quote_ok, fw)
        Decision.new(outcome: outcome, reason: reason, reasons: reasons, citations: citations, code_quote_valid: quote_ok,
                     framework_claim: fw)
      end

      # @return [String]
      def self.squash(s) = s.to_s.gsub(/\s+/, " ").strip

      # Quoted diff lines without their number and +/- marker.
      # @return [String]
      def self.strip_code(q)
        q.to_s.split(/\r?\n/).map { |l| l.sub(/\A\s*\d+\s+(?=[+\- ])/, "").sub(/\A[+\- ]/, "") }.join("\n")
      end
      private_class_method :accept_problems, :cite, :decision, :squash, :strip_code
    end
  end
end
