# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"

module Harness
  module Review
    # A claim from discovery. found_by lists the discovery runs that proposed it; on_added_line is set by validation.
    Finding = Data.define(:file, :line, :severity, :confidence, :problem, :evidence, :mechanism, :preconditions,
                          :expected_actual, :unverified, :found_by, :on_added_line) do
      # @return [String] "file:line"
      def where = "#{file}:#{line}"
    end
    # A finding that failed the deterministic checks, with the fact fed back to the model.
    Rejection = Data.define(:finding, :reason, :fact)
    # Parsed discovery output.
    Discovery = Data.define(:summary, :findings, :suspicious)

    # Defensive parsing of discovery output and deterministic validation of every claim against the diff the
    # model was shown, on the assumption that the model hallucinates. Ported from REVIEWER src/review/findings.js.
    module Findings
      LEVELS = %w[low medium high].freeze
      LINE_TOLERANCE = 3
      MIN_EVIDENCE = 6
      MAX_FINDINGS = 8
      FIELDS = %w[file line severity confidence problem evidence mechanism preconditions expected_actual unverified].freeze
      SCHEMA = {
        "type" => "object", "required" => %w[summary findings suspicious],
        "properties" => {
          "summary" => { "type" => "string" },
          "findings" => { "type" => "array", "maxItems" => MAX_FINDINGS, "items" => {
            "type" => "object", "required" => FIELDS,
            "properties" => FIELDS.to_h { |f| [f, { "type" => f == "line" ? "integer" : "string" }] }
                                  .merge("severity" => { "type" => "string", "enum" => LEVELS },
                                         "confidence" => { "type" => "string", "enum" => LEVELS })
          } },
          "suspicious" => { "type" => "array", "items" => { "type" => "string" } }
        }
      }.freeze

      # A client parser: the reply's JSON value to a Discovery. Fields are typed leniently here; validate checks
      # them against the diff.
      # @param obj [Object] the reply's JSON value
      # @return [Discovery]
      # @raise [ParseError] when it is not an object
      def self.parse(obj)
        raise ParseError, "the review reply is not a JSON object" unless obj.is_a?(Hash)

        findings = (obj["findings"].is_a?(Array) ? obj["findings"] : []).select { |f| f.is_a?(Hash) }.map do |f|
          line = f["line"].is_a?(String) && f["line"].strip.match?(/\A\d+\z/) ? f["line"].strip.to_i : f["line"]
          Finding.new(file: str(f["file"], 300), line: line.is_a?(Integer) && line.positive? ? line : nil,
                      severity: level(f["severity"]), confidence: level(f["confidence"]), problem: str(f["problem"], 600),
                      evidence: str(f["evidence"], 400), mechanism: str(f["mechanism"], 400),
                      preconditions: str(f["preconditions"], 300), expected_actual: str(f["expected_actual"], 300),
                      unverified: str(f["unverified"], 300), found_by: [], on_added_line: false)
        end
        suspicious = (obj["suspicious"].is_a?(Array) ? obj["suspicious"] : []).map { |s| str(s, 200) }.reject(&:empty?).first(10)
        Discovery.new(summary: str(obj["summary"], 800), findings: findings, suspicious: suspicious)
      end

      # Keep a claim only if it names a shown file, its evidence is verbatim in that file's diff lines, and its
      # line is within 3 of the evidence (then snapped to it).
      # @param findings [Array<Finding>]
      # @param files [Array<DiffFile>]
      # @return [Array(Array<Finding>, Array<Rejection>)]
      def self.validate(findings, files)
        by_path = files.to_h { |f| [norm(f.path).downcase, f] }
        kept = []
        rejected = []
        seen = {}
        findings.each do |f|
          where = "#{f.file.empty? ? '(no file)' : f.file} line #{f.line || '(none)'}"
          reject = ->(reason, fact) { rejected << Rejection.new(finding: f, reason: reason, fact: "#{where}: #{fact}") }
          next reject.call("missing file", "no \"file\" given") if f.file.empty?
          next reject.call("missing or invalid line", "no valid positive integer \"line\" given") unless f.line
          next reject.call("missing problem", "no \"problem\" given") if f.problem.empty?

          file = by_path[norm(f.file).downcase]
          unless file
            next reject.call("file not in reviewed diff",
                             "\"#{clip(f.file)}\" is not one of the files you were shown (#{files.map(&:path).join(', ')})")
          end
          cands = candidates(f.evidence)
          next reject.call("evidence missing or too short", "evidence must be one full line of code copied verbatim from #{file.path}") if cands.empty?

          matches = evidence_lines(file, f.evidence, cands)
          if matches.empty?
            next reject.call("evidence not found in diff", "the evidence \"#{clip(f.evidence)}\" does not appear anywhere in the diff of #{file.path}")
          end

          best = matches.min_by { |l| (line_no(l) - f.line).abs }
          if (line_no(best) - f.line).abs > LINE_TOLERANCE
            next reject.call("line does not match evidence",
                             "you cited line #{f.line}, but the diff of #{file.path} only shows lines #{ranges(file)}, " \
                             "and your evidence is on line #{matches.first(3).map { |l| line_no(l) }.join(', ')}")
          end
          key = "#{file.path}:#{line_no(best)}:#{collapse(f.problem)[0, 40]}"
          next reject.call("duplicate", "duplicate of another finding") if seen[key]

          seen[key] = true
          kept << f.with(file: file.path, line: line_no(best), on_added_line: best.kind == "+")
          break if kept.size >= MAX_FINDINGS
        end
        [kept, rejected]
      end

      # Merge duplicates across discovery runs: same file, line within 3, and the same evidence or mostly the same
      # words. Agreement is recorded in found_by and is never evidence.
      # @param a [Array<Finding>]
      # @param b [Array<Finding>]
      # @return [Array<Finding>]
      def self.reconcile(a, b)
        out = a.dup
        b.each do |f|
          i = out.index do |g|
            next false if g.file != f.file || (g.line - f.line).abs > 3
            next true if g.evidence.strip == f.evidence.strip

            wa = words(g.problem)
            wb = words(f.problem)
            (wa & wb).size.fdiv([[wa.size, wb.size].min, 1].max) >= 0.5
          end
          if i
            out[i] = out[i].with(found_by: (out[i].found_by + f.found_by).uniq)
          else
            out << f
          end
        end
        out
      end

      # @return [String] new-file line ranges shown, e.g. "1-12, 40-55"
      def self.ranges(file)
        nums = file.lines.filter_map(&:new_line).sort
        return "no new-file lines" if nums.empty?

        nums.slice_when { |x, y| y != x + 1 }.map { |r| r.size == 1 ? r.first.to_s : "#{r.first}-#{r.last}" }.join(", ")
      end

      # @return [String]
      def self.str(v, max) = v.is_a?(String) ? v.strip[0, max] : ""

      # @return [String]
      def self.level(v)
        s = v.is_a?(String) ? v.strip.downcase : ""
        LEVELS.include?(s) ? s : "low"
      end

      # @return [String]
      def self.collapse(s) = s.to_s.gsub(/\s+/, " ").strip

      # @return [Array<String>]
      def self.candidates(evidence)
        lines = evidence.to_s.split(/\r?\n/)
        no_num = lines.map { |l| l.sub(/\A\s*\d+\s+(?=[+\- ])/, "") }
        no_marker = no_num.map { |l| l.sub(/\A[+\- ]/, "") }
        [lines, no_num, no_marker].map { |ls| collapse(ls.join("\n")) }.uniq.select { |c| c.size >= MIN_EVIDENCE }
      end

      # Lines holding the evidence; multi-line evidence anchors on its longest line.
      # @return [Array<DiffLine>]
      def self.evidence_lines(file, evidence, cands)
        code = file.code
        matches = code.select { |l| cands.any? { |c| collapse(l.text).include?(c) } }
        return matches unless matches.empty?

        hay = collapse(code.map(&:text).join("\n"))
        return [] unless cands.any? { |c| hay.include?(c) }

        longest = evidence.split(/\r?\n/).map { |l| collapse(l.sub(/\A\s*\d+\s+(?=[+\- ])/, "").sub(/\A[+\- ]/, "")) }.max_by(&:size)
        longest.to_s.empty? ? [] : code.select { |l| collapse(l.text).include?(longest) }
      end

      # @return [String]
      def self.norm(p) = p.to_s.tr("\\", "/").sub(%r{\A\.?/}, "").sub(%r{\A[ab]/}, "").strip

      # @return [Integer]
      def self.line_no(l) = l.new_line || l.old_line

      # @return [String]
      def self.clip(s, n = 80)
        t = collapse(s)
        t.size > n ? "#{t[0, n]}…" : t
      end

      # @return [Array<String>]
      def self.words(s) = s.to_s.downcase.scan(/[a-z0-9_]{4,}/).uniq
      private_class_method :str, :level, :collapse, :candidates, :evidence_lines, :norm, :line_no, :clip, :words
    end
  end
end
