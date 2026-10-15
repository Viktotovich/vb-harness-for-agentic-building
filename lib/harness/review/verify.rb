# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"

module Harness
  module Review
    # Verification and challenge helpers: excerpts, reply schemas and their parsers. Ported from REVIEWER
    # src/review/verify.js, with the DESIGN.md 8 fields depends_on_unseen, unseen and requires_type_violation, and
    # a challenge that abstains when its answer rests on code it could not see.
    module Verify
      EXCERPT_RADIUS = 14
      MIN_TRIGGER = 15
      CLAIM_TYPES = %w[framework-api language repository-logic security other].freeze
      VERDICTS = %w[accept reject abstain].freeze
      IMPACTS = %w[low medium high].freeze
      STRING_FIELDS = { "framework" => 40, "code_does" => 300, "code_quote" => 600, "preconditions" => 300, "trigger" => 300,
                        "refutation" => 300, "refutation_quote" => 600, "unseen" => 300, "reason" => 300 }.freeze
      VERDICT_FIELDS = %w[id claim_type framework code_does code_quote false_statements preconditions trigger refutation
                          refutation_quote citations impact depends_on_unseen unseen requires_type_violation verdict reason].freeze
      VERDICT_SCHEMA = {
        "type" => "object", "required" => ["verdicts"],
        "properties" => { "verdicts" => { "type" => "array", "items" => {
          "type" => "object", "required" => VERDICT_FIELDS,
          "properties" => STRING_FIELDS.keys.to_h { |k| [k, { "type" => "string" }] }.merge(
            "id" => { "type" => "integer" },
            "claim_type" => { "type" => "string", "enum" => CLAIM_TYPES },
            "false_statements" => { "type" => "array", "items" => { "type" => "string" } },
            "citations" => { "type" => "array", "items" => {
              "type" => "object", "required" => %w[evidence_id quote relation],
              "properties" => { "evidence_id" => { "type" => "string" }, "quote" => { "type" => "string" },
                                "relation" => { "type" => "string", "enum" => %w[supports contradicts] } }
            } },
            "impact" => { "type" => "string", "enum" => IMPACTS },
            "depends_on_unseen" => { "type" => "boolean" },
            "requires_type_violation" => { "type" => "boolean" },
            "verdict" => { "type" => "string", "enum" => VERDICTS }
          )
        } } }
      }.freeze
      CHALLENGE_SCHEMA = {
        "type" => "object", "required" => %w[defence defence_holds concede_reason unseen],
        "properties" => { "defence" => { "type" => "string" }, "defence_holds" => { "type" => "boolean" },
                          "concede_reason" => { "type" => "string" }, "unseen" => { "type" => "string" } }
      }.freeze
      SUPPORT_SCHEMA = {
        "type" => "object", "required" => %w[establishes reason],
        "properties" => { "establishes" => { "type" => "string", "enum" => %w[yes no partly] }, "reason" => { "type" => "string" } }
      }.freeze

      # result: survives | holds | abstain.
      Challenge = Data.define(:result, :why)

      # The numbered window around a cited line, as the verifier sees it.
      # @param file [DiffFile]
      # @param line [Integer]
      # @param radius [Integer]
      # @return [String]
      def self.excerpt(file, line, radius = EXCERPT_RADIUS)
        lines, cited = window(file, line, radius)
        lines.map { |l| "#{l.new_line.to_s.rjust(5)} #{l.kind}#{l.text}#{l.equal?(cited) ? '   <-- cited line' : ''}" }.join("\n")
      end

      # The same window as plain code: what quotes are checked against.
      # @return [String]
      def self.excerpt_code(file, line, radius = EXCERPT_RADIUS)
        return "" unless file

        window(file, line, radius).first.map(&:text).join("\n")
      end

      # A client parser for the verifier's final reply. Ids are remapped by position when the count matches but
      # the numbering does not.
      # @param obj [Object]
      # @param expected [Integer] number of claims
      # @return [Hash{Integer=>Hash}] verdicts by claim number, normalised
      # @raise [ParseError] when there is no verdicts list
      def self.parse_verdicts(obj, expected)
        raise ParseError, "the verifier reply has no verdicts list" unless obj.is_a?(Hash) && obj["verdicts"].is_a?(Array)

        list = obj["verdicts"].select { |v| v.is_a?(Hash) }.map(&:dup)
        ids = list.map { |v| v["id"] }
        ids_ok = ids.all? { |i| i.is_a?(Integer) && i.between?(1, expected) } && ids.uniq.size == ids.size
        list.each_with_index { |v, i| v["id"] = i + 1 } if !ids_ok && list.size == expected
        list.select { |v| v["id"].is_a?(Integer) }.to_h { |v| [v["id"], normalise(v)] }
      end

      # The claim survives only when the defence explicitly does not hold and a concrete failing scenario is given.
      # An answer that rests on code the challenger could not see abstains, never survives.
      # @param obj [Object]
      # @return [Challenge]
      def self.parse_challenge(obj)
        return Challenge.new(result: "holds", why: "challenge output unusable") unless obj.is_a?(Hash)

        unseen = obj["unseen"].is_a?(String) ? obj["unseen"].strip : ""
        return Challenge.new(result: "abstain", why: "depends on code not shown: #{unseen[0, 200]}") unless unseen.empty?

        concede = obj["concede_reason"].is_a?(String) ? obj["concede_reason"].strip : ""
        return Challenge.new(result: "survives", why: concede[0, 300]) if obj["defence_holds"] == false && concede.size >= MIN_TRIGGER

        Challenge.new(result: "holds", why: (obj["defence"].to_s.strip.empty? ? "defence holds" : obj["defence"].to_s.strip)[0, 300])
      end

      # @param obj [Object]
      # @return [Array(Boolean, String)] established, and why
      def self.parse_support(obj)
        return [false, "support check output unusable"] unless obj.is_a?(Hash)

        why = obj["reason"].is_a?(String) ? obj["reason"].strip[0, 200] : ""
        [obj["establishes"] == "yes" && why.size >= 15, why]
      end

      # @return [Hash]
      def self.normalise(v)
        out = STRING_FIELDS.to_h { |k, n| [k, v[k].is_a?(String) ? v[k].strip[0, n] : ""] }
        out["claim_type"] = CLAIM_TYPES.include?(v["claim_type"]) ? v["claim_type"] : "other"
        out["false_statements"] = v["false_statements"].is_a?(Array) ? v["false_statements"].grep(String).map { |s| s.strip[0, 200] }.reject(&:empty?) : nil
        out["citations"] = Array(v["citations"]).first(6).select { |c| c.is_a?(Hash) }.map do |c|
          { "evidence_id" => c["evidence_id"].to_s[0, 10], "quote" => c["quote"].to_s[0, 600], "relation" => c["relation"].to_s[0, 12] }
        end
        out["impact"] = IMPACTS.include?(v["impact"]) ? v["impact"] : nil
        out["verdict"] = VERDICTS.include?(v["verdict"]) ? v["verdict"] : "abstain"
        out["depends_on_unseen"] = v["depends_on_unseen"] == true
        out["requires_type_violation"] = v["requires_type_violation"] == true
        out
      end

      # @return [Array(Array<DiffLine>, DiffLine)]
      def self.window(file, line, radius)
        code = file.code
        idx = code.index { |l| l.new_line == line } || code.index { |l| l.old_line == line && l.kind == "-" } || 0
        [code[[idx - radius, 0].max..(idx + radius)] || [], code[idx]]
      end
      private_class_method :normalise, :window
    end
  end
end
