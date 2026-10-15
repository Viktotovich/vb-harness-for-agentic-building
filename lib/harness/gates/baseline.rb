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

        added = new_diagnostics(current.diagnostics, baseline.diagnostics)
        comparison(current, added.empty? ? "baseline_same" : "regressed", added)
      end

      # Diagnostics in current that baseline does not have, counted as a multiset by file, code and message.
      # @param current [Array<Diagnostic>]
      # @param baseline [Array<Diagnostic>]
      # @return [Array<Diagnostic>]
      def self.new_diagnostics(current, baseline)
        left = baseline.map(&:key).tally
        current.reject do |d|
          next false unless left.fetch(d.key, 0).positive?

          left[d.key] -= 1
          true
        end
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
      private_class_method :baseline_failed?, :same_status, :comparison
    end
  end
end
