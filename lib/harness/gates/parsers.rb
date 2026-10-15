# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "gate"

module Harness
  module Gates
    # Gate output to Diagnostics. Each parser: text, root -> Array<Diagnostic>. Output a parser cannot read
    # falls back to the last 60 lines as one diagnostic (DESIGN.md 6).
    module Parsers
      FALLBACK_LINES = 60

      # "src/a.ts(3,5): error TS2322: msg" (tsc) and "src/a.astro:3:5 - error ts(2322): msg" (tsc pretty, astro check)
      TSC_LINE = /^(?<file>(?:[A-Za-z]:)?[^\s:(][^:(]*?)(?:\((?<line>\d+),(?<col>\d+)\)|:(?<line2>\d+):(?<col2>\d+))\s*[:-]\s*
                  (?<sev>error|warning|hint)\s+(?<code>TS\d+|ts\(\d+\))?:?\s*(?<msg>.+)$/x
      # eslint "stylish": a file header line, then "  3:5  error  message  rule-id"
      ESLINT_ROW = /^\s+(?<line>\d+):(?<col>\d+)\s+(?<sev>error|warning)\s+(?<msg>.+?)(?:\s{2,}(?<rule>[@\w\/-]+))?\s*$/
      # vitest: " FAIL  tests/unit/x.test.ts > suite > case"
      VITEST_FAIL = /^\s*(?:FAIL|×|✗)\s+(?<file>\S+\.(?:test|spec)\.[cm]?[jt]sx?)(?:\s*>\s*(?<name>.+))?$/
      # playwright: "  1) [chromium] › tests/e2e/a.spec.ts:12:5 › page loads"
      PLAYWRIGHT_FAIL = /^\s*\d+\)\s+\[[^\]]+\]\s+›\s+(?<file>\S+?):(?<line>\d+):(?<col>\d+)\s+›\s+(?<name>.+)$/

      # @param name [String, nil] parser name from config
      # @param text [String] combined gate output
      # @param root [String] worktree root, to make paths relative
      # @return [Array<Diagnostic>] never empty for non-empty output
      def self.parse(name, text, root:)
        clean = text.gsub(/\e\[[0-9;]*m/, "").gsub("\r\n", "\n")
        found = case name
                when "tsc", "astro_check" then tsc(clean, root)
                when "eslint" then eslint(clean, root)
                when "vitest" then vitest(clean, root)
                when "playwright" then playwright(clean, root)
                else []
                end
        found.empty? ? fallback(clean) : found
      end

      # @return [Array<Diagnostic>]
      def self.fallback(text)
        tail = text.strip.lines.last(FALLBACK_LINES).join.strip
        return [] if tail.empty?

        [Diagnostic.new(file: nil, line: nil, col: nil, code: "output", message: tail, severity: "error")]
      end

      # @return [Array<Diagnostic>]
      def self.tsc(text, root)
        text.each_line.filter_map do |l|
          m = l.match(TSC_LINE) or next
          Diagnostic.new(file: rel(m[:file], root), line: (m[:line] || m[:line2]).to_i, col: (m[:col] || m[:col2]).to_i,
                         code: m[:code], message: m[:msg].strip, severity: m[:sev])
        end
      end

      # @return [Array<Diagnostic>]
      def self.eslint(text, root)
        file = nil
        text.each_line.filter_map do |l|
          if (m = l.match(ESLINT_ROW))
            next unless file

            Diagnostic.new(file: file, line: m[:line].to_i, col: m[:col].to_i, code: m[:rule], message: m[:msg].strip,
                           severity: m[:sev])
          else
            file = rel(l.strip, root) if l.match?(/\A\S/) && !l.start_with?("✖")
            nil
          end
        end
      end

      # @return [Array<Diagnostic>]
      def self.vitest(text, root)
        text.each_line.filter_map do |l|
          m = l.match(VITEST_FAIL) or next
          Diagnostic.new(file: rel(m[:file], root), line: nil, col: nil, code: "test", message: m[:name].to_s.strip,
                         severity: "error")
        end.uniq
      end

      # @return [Array<Diagnostic>]
      def self.playwright(text, root)
        text.each_line.filter_map do |l|
          m = l.match(PLAYWRIGHT_FAIL) or next
          Diagnostic.new(file: rel(m[:file], root), line: m[:line].to_i, col: m[:col].to_i, code: "test",
                         message: m[:name].strip, severity: "error")
        end.uniq(&:key)
      end

      # @return [String] path relative to root, "/" separators
      def self.rel(path, root)
        p = path.strip.tr("\\", "/")
        r = root.tr("\\", "/").chomp("/")
        p = p[(r.length + 1)..] if p.downcase.start_with?("#{r.downcase}/")
        p.delete_prefix("./")
      end
      private_class_method :fallback, :tsc, :eslint, :vitest, :playwright, :rel
    end
  end
end
