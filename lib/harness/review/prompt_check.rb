# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../untrusted"

module Harness
  module Review
    # Deterministic checks on every assembled review prompt before it is sent. A failed check fails that stage;
    # it is never bypassed. Ported from REVIEWER src/review/prompt-check.js.
    module PromptCheck
      PRESUMPTIVE = [
        /there (?:is|are) (?:a |some )?(?:bugs?|defects?|issues?) in/i,
        /find (?:at least|\d+|all the) (?:bugs?|defects?|issues?)/i,
        /you must (?:report|find) (?:a|at least)/i
      ].freeze
      OPEN = /<#{Untrusted::TAG} id="(\h+)">/
      CLOSE = %r{</#{Untrusted::TAG} id="(\h+)">}

      # @param stage [String] "discovery", "verify", "challenge" or "support"
      # @param system [String]
      # @param user [String]
      # @param files [Array<String>] paths that must appear as "### FILE: <path>"
      # @param claims [Array<String>] claim texts that must appear
      # @return [Array<String>] problems; empty when the prompt may be sent
      def self.problems(stage, system:, user:, files: [], claims: [])
        all = "#{system}\n#{user}"
        out = []
        opens = all.scan(OPEN).flatten
        out << "no untrusted-data fence" if opens.empty? && stage != "challenge"
        out << "untrusted-data fences are unbalanced or mismatched" if opens != all.scan(CLOSE).flatten
        out << "system prompt does not declare repository content untrusted" unless system.match?(/untrusted/i)
        out << "system prompt presumes that a defect exists" if PRESUMPTIVE.any? { |re| system.match?(re) }
        out << "discovery prompt does not say an empty result is valid" if stage == "discovery" && !system.match?(/"findings":\s*\[\]/)
        out << "framework version line missing" if %w[discovery verify].include?(stage) && !all.include?("Framework: ")
        files.each { |f| out << "file #{f} missing from prompt (truncated?)" unless all.include?("### FILE: #{f}") }
        out << "a claim to verify is missing from the prompt" unless claims.all? { |c| all.include?(c) }
        if stage == "verify" && all.match?(/\b(?:severity|confidence)\s*:\s*(?:low|medium|high)\b/i)
          out << "verify prompt leaks the original reviewer's severity/confidence"
        end
        out
      end
    end
  end
end
