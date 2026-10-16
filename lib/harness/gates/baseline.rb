# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../state/records"
require_relative "runner"

module Harness
  module Gates
    # Baseline run at intake and comparison afterwards (DESIGN.md 5.1, 5.4 step 4). A check that already
    # fails at baseline is compared, not blocking: only new diagnostics block (I7).
    module Baseline
      # verdict: pass | baseline_same | regressed | skipped
      Comparison = Data.define(:gate, :verdict, :new_diagnostics, :current) do
        # @return [Boolean] true when this gate does not stop the task: it passed, or fails exactly as at baseline
        def ok?
          %w[pass baseline_same].include?(verdict)
        end
      end

      # Run every gate that does not need touched files (scope project or tests, both phases).
      # @param runner [Runner]
      # @param gates [Hash{String=>Gate}]
      # @return [Hash{String=>Result}]
      def self.run(runner, gates)
        gates.values.reject { |g| g.scope == "touched" }.sort_by(&:cost_rank).to_h { |g| [g.name, runner.run(g)] }
      end

      # @param path [String] runs/<runId>/baseline.json
      # @param results [Hash{String=>Result}]
      # @return [void]
      def self.save(path, results)
        State.write_json(path, results.transform_values(&:to_json_hash))
      end

      # @param path [String]
      # @return [Hash{String=>Result}]
      # @raise [ParseError]
      def self.load(path)
        raw = JSON.parse(File.read(path, encoding: "UTF-8"))
        Parse.hash!(raw, "baseline").transform_values { |r| Result.parse(r) }
      rescue JSON::ParserError => e
        raise ParseError, "baseline: not valid JSON (#{e.message.lines.first.strip})"
      end

      # @param current [Result]
      # @param baseline [Result, nil] the same gate at baseline, nil when it was not run then
      # @return [Comparison]
      def self.compare(current, baseline)
        return comparison(current, "skipped", []) if current.status == "skipped"
        return comparison(current, "pass", []) if current.passed?
        return comparison(current, "regressed", current.diagnostics) unless baseline_failed?(baseline)
        return same_status(current, baseline) if current.status == "timeout" || baseline.status == "timeout"
        return same_exit(current, baseline) if unparsed?(current) && unparsed?(baseline)

        added = new_diagnostics(current.diagnostics, baseline.diagnostics)
        comparison(current, added.empty? ? "baseline_same" : "regressed", added)
      end

      # Diagnostics in current that baseline does not have, counted as a multiset by file, code and message.
      # Unparsed output is compared with its volatile text normalised.
      # @param current [Array<Diagnostic>]
      # @param baseline [Array<Diagnostic>]
      # @return [Array<Diagnostic>]
      def self.new_diagnostics(current, baseline)
        left = baseline.map { |d| key(d) }.tally
        current.reject do |d|
          k = key(d)
          next false unless left.fetch(k, 0).positive?

          left[k] -= 1
          true
        end
      end

      VOLATILE = [
        [/\e\[[0-9;]*[A-Za-z]/, ""],                                                  # ANSI colours
        [/\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/, "<time>"], # ISO dates
        [/\b\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\b/, "<time>"],                              # clock times like 03:08:43
        [/\b\d+(?:\.\d+)?\s?(?:ms|s|sec|seconds|m|min)\b/, "<duration>"],              # "in 8.01s", "120ms"
        [/\b\d+(?:\.\d+)?\s?(?:B|kB|KB|KiB|MB|MiB)\b/, "<size>"],                      # build sizes
        [/\br\d{8}-\d{6}-\h{4}\b/, "<run>"],                                          # run ids
        [%r{(?:[A-Za-z]:)?[\\/][^\s:"'()]*(?:\.harness-worktrees|workspaces)[\\/][^\s:"'()]+}, "<worktree>"], # worktree paths
        [%r{(?:[A-Za-z]:[\\/]|/(?:tmp|var|private|Users|home)/)[^\s:"'()]+}, "<path>"], # absolute and temp paths
        [/\.[A-Za-z0-9_-]{6,12}(?=\.(?:m?js|css|map)\b)/, ".<hash>"],                 # bundler hashes: index.BkZ3c9aQ.js
        [/\b\h{8,}\b/, "<hash>"]                                                       # content hashes in file names
      ].freeze

      # Text with timestamps, durations, sizes, run ids, paths and hashes replaced, so two runs of a failing tool
      # compare equal when only those differ.
      # @param text [String]
      # @return [String]
      def self.normalize(text)
        VOLATILE.reduce(text.to_s) { |s, (re, to)| s.gsub(re, to) }.gsub(/[ \t]+/, " ").strip
      end

      # @return [Array]
      def self.key(d)
        d.code == "output" ? [d.file, d.code, normalize(d.message)] : d.key
      end

      # Output no parser understood: only the fallback tail.
      # @return [Boolean]
      def self.unparsed?(result)
        !result.diagnostics.empty? && result.diagnostics.all? { |d| d.code == "output" && d.file.nil? }
      end

      # Two unparsed failures are the same when they end with the same exit status and their output tails match once
      # volatile text (times, durations, sizes, paths, run ids, hashes) is normalised. A changed count such as
      # "3 tests failed" -> "4 tests failed" still regresses.
      # @return [Comparison]
      def self.same_exit(current, baseline)
        same = current.exit_code == baseline.exit_code &&
               normalize(current.diagnostics.map(&:message).join("\n")) == normalize(baseline.diagnostics.map(&:message).join("\n"))
        comparison(current, same ? "baseline_same" : "regressed", same ? [] : current.diagnostics)
      end

      # @return [Boolean]
      def self.baseline_failed?(baseline)
        !baseline.nil? && %w[failed timeout].include?(baseline.status)
      end

      # @return [Comparison]
      def self.same_status(current, baseline)
        comparison(current, current.status == baseline.status ? "baseline_same" : "regressed", current.diagnostics)
      end

      # @return [Comparison]
      def self.comparison(current, verdict, added)
        Comparison.new(gate: current.gate, verdict: verdict, new_diagnostics: added, current: current)
      end
      private_class_method :baseline_failed?, :same_status, :comparison, :key, :unparsed?, :same_exit
    end
  end
end
