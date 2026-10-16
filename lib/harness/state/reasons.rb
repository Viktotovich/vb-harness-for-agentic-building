# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  module State
    # Reason codes for rejected or thrown-away output (DESIGN.md 10.3), with the human text the UI shows.
    # New codes are added here and to the tests together.
    module Reasons
      TEXT = {
        "model.invalid_json" => "reply was not valid JSON",
        "model.schema_mismatch" => "reply had the wrong shape",
        "model.empty" => "reply was empty",
        "model.thinking_exhausted" => "ran out of room while thinking",
        "model.truncated" => "reply was cut off",
        "model.context_overflow" => "request did not fit the context",
        "model.unavailable" => "model server unavailable",
        "harness.crashed" => "the harness stopped on an internal error",
        "plan.too_many_files" => "task touches too many files",
        "plan.missing_path" => "plan names a file that does not exist",
        "plan.path_exists" => "plan creates a file that already exists",
        "plan.protected_path" => "plan touches a protected path",
        "plan.cycle" => "tasks depend on each other in a cycle",
        "plan.no_acceptance" => "task has no gate or test to prove it",
        "plan.no_changes" => "task changes no files",
        "untrusted.instruction_like" => "instruction-like text in repository content",
        "plan.too_large_for_context" => "task too large for the context",
        "plan.unknown_gate" => "plan names a gate the stack does not define",
        "plan.gate_unavailable" => "plan names a gate that cannot run in this repository",
        "edit.search_not_found" => "edit search text not found",
        "edit.search_ambiguous" => "edit search text matched more than once",
        "edit.undeclared_path" => "edit to a file the task does not declare",
        "edit.protected_path" => "edit to a protected path",
        "edit.outside_worktree" => "edit outside the worktree",
        "edit.create_exists" => "create over an existing file",
        "fix.same_errors_twice" => "fix left the same errors",
        "fix.rounds_exhausted" => "fix rounds used up",
        "claim.failed_checks" => "claim failed basic checks",
        "verify.refuted_by_code" => "claim refuted by code",
        "verify.contradicted_by_docs" => "claim contradicted by docs",
        "verify.no_evidence" => "no evidence for the claim",
        "verify.unseen_code" => "depends on code not shown",
        "verify.requires_type_violation" => "needs a value its type forbids",
        "verify.abstained" => "verifier abstained",
        "support.docs_do_not_establish" => "docs do not establish the claim",
        "challenge.defence_holds" => "defence holds",
        "confirm.test_passes" => "confirming test passes",
        "confirm.test_not_writable" => "confirming test could not be written"
      }.freeze
      # gate.<what>:<gate name>, e.g. gate.failed:typecheck
      GATE = /\Agate\.(failed|timeout|skipped):([A-Za-z0-9_.-]{1,40})\z/
      GATE_TEXT = { "failed" => "failed", "timeout" => "timed out", "skipped" => "could not run" }.freeze

      # @param code [String]
      # @return [Boolean]
      def self.valid?(code)
        TEXT.key?(code) || code.to_s.match?(GATE)
      end

      # @param code [String]
      # @return [String] human text for the UI and report
      # @raise [ArgumentError] on an unknown code
      def self.text(code)
        return TEXT[code] if TEXT.key?(code)

        m = code.to_s.match(GATE) or raise ArgumentError, "unknown reason code #{code.inspect}"
        "#{m[2]} #{GATE_TEXT.fetch(m[1])}"
      end
    end
  end
end
