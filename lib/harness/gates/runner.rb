# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"
require_relative "../exec"
require_relative "../parse"
require_relative "../repo/paths"
require_relative "gate"
require_relative "parsers"

module Harness
  module Gates
    # Outcome of one gate run. status: passed | failed | timeout | skipped. A skipped gate always has a
    # reason and never counts as passed (I6).
    Result = Data.define(:gate, :status, :exit_code, :diagnostics, :reason, :ms, :argv) do
      # @return [Boolean] true only for status "passed"
      def passed?
        status == "passed"
      end

      # @return [Hash] JSON form for baseline.json and gates-<round>.json
      def to_json_hash
        { "gate" => gate, "status" => status, "exitCode" => exit_code, "reason" => reason, "ms" => ms, "argv" => argv,
          "diagnostics" => diagnostics.map { |d| d.to_h.transform_keys(&:to_s) } }
      end
    end

    # JSON parsing for Result (resume and baseline files).
    class Result
      STATUSES = %w[passed failed timeout skipped].freeze

      # @param raw [Hash]
      # @return [Result]
      # @raise [ParseError]
      def self.parse(raw)
        h = Parse.hash!(raw, "gate result")
        status = Parse.enum!(h["status"], "gate result.status", STATUSES)
        diags = h.fetch("diagnostics", [])
        Parse.fail!("gate result.diagnostics", "array", diags) unless diags.is_a?(Array)
        new(gate: Parse.str!(h["gate"], "gate result.gate"), status: status, exit_code: h["exitCode"],
            diagnostics: diags.map { |d| Diagnostic.new(**Diagnostic.members.to_h { |m| [m, Parse.hash!(d, "diagnostic")[m.to_s]] }) },
            reason: h["reason"], ms: h["ms"], argv: h.fetch("argv", []))
      end
    end

    # Runs configured gates through Harness::Exec (I3) with the scrubbed environment (I5).
    class Runner
      # Output that means the tool itself is missing, even though a launcher (npx, cmd) started.
      MISSING_TOOL = Regexp.union(
        "could not determine executable to run", "canceled due to missing packages", "npm error code E404",
        "is not recognized as an internal or external command", "command not found",
        # npx --offline --no (the default gates): a package that is not installed fails here, with no network
        "npm error code ENOTCACHED", "cache mode is 'only-if-cached'"
      )
      # Output that means the gate could not run here, though its tool is installed: the operating system's
      # application-control policy blocked a binary (a field run's Astro compiler), or the tool cannot parse the
      # touched file type (prettier without its Astro plugin). Neither is a problem in the model's code.
      CANNOT_RUN = {
        "blocked by the system's policy" => Regexp.union("Application Control policy has blocked", "blocked by group policy",
                                                           "blocked by your organization"),
        "the tool cannot check these files" => Regexp.union("No parser could be inferred")
      }.freeze

      # @param root [String] worktree root
      # @param env [Hash{String=>String}] from Env.build
      # @param max_output [Integer] maxGateOutputBytes, per stream
      def initialize(root:, env:, max_output: 204_800)
        @root = root
        @env = env
        @max_output = max_output
      end

      # @param gate [Gate]
      # @param files [Array<String>] touched files (relative), for {files}
      # @param tests [Array<String>] test files (relative), for {tests}; empty runs the whole suite
      # @return [Result]
      def run(gate, files: [], tests: [])
        argv = expand(gate.argv, files, tests)
        return skipped(gate, "no files to check", gate.argv) if argv.nil?

        r = Exec.run(argv, chdir: @root, env: @env, timeout: gate.timeout_sec, max_output: @max_output)
        output = "#{r.stdout}\n#{r.stderr}"
        return result(gate, "timeout", r, [], "timed out after #{gate.timeout_sec}s") if r.timed_out
        return result(gate, "passed", r, [], nil) if r.success?
        return skipped(gate, "tool not installed: #{output[MISSING_TOOL]}", argv) if output.match?(MISSING_TOOL)

        CANNOT_RUN.each { |why, pattern| return skipped(gate, "#{why}: #{output.lines.find { |l| l.match?(pattern) }.to_s.strip[0, 200]}", argv) if output.match?(pattern) }

        result(gate, "failed", r, Parsers.parse(gate.parser, output, root: @root), nil)
      rescue CommandNotFoundError => e
        skipped(gate, "command not found: #{argv&.first} (#{e.class.name.split('::').last})", argv || gate.argv)
      rescue UnsafeArgumentError, PathError => e
        skipped(gate, e.message, argv || gate.argv)
      end

      private

      # {files} and {tests} become separate argv entries. Returns nil when {files} has nothing to check;
      # an empty {tests} is dropped so the whole suite runs.
      # @return [Array<String>, nil]
      def expand(argv, files, tests)
        return nil if argv.include?("{files}") && files.empty?

        argv.flat_map do |a|
          case a
          when "{files}" then files.map { |f| safe_path(f) }
          when "{tests}" then tests.map { |f| safe_path(f) }
          else [a]
          end
        end
      end

      # A normalized relative path that a tool cannot mistake for an option.
      # @return [String]
      def safe_path(path)
        rel = Repo::Paths.normalize(path)
        rel.start_with?("-") ? "./#{rel}" : rel
      end

      # @return [Result]
      def result(gate, status, r, diagnostics, reason)
        Result.new(gate: gate.name, status: status, exit_code: r.exit_code, diagnostics: diagnostics, reason: reason,
                   ms: r.ms, argv: r.argv)
      end

      # @return [Result]
      def skipped(gate, reason, argv)
        Result.new(gate: gate.name, status: "skipped", exit_code: nil, diagnostics: [], reason: reason, ms: 0, argv: argv)
      end
    end
  end
end
