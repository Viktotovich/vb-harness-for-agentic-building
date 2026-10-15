# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# M8 acceptance: the events fold against a recorded events.jsonl (counts per stage and reason, rejection rate), and
# every reason code has human text.

require_relative "../test_helper"
require "json"

class EventsFoldTest < Minitest::Test
  FIXTURE = File.join(TestSupport::ROOT, "test", "fixtures", "events.jsonl")
  E = Harness::State::Events
  R = Harness::State::Reasons

  def test_the_recorded_run_folds_to_known_counts
    fold = E.fold(E.read(FIXTURE))
    assert_equal 24, fold["seq"]
    assert_equal({ "produced" => 12, "accepted" => 7, "rejected" => 5, "tokensIn" => 6100, "tokensOut" => 1300,
                   "rejectionRate" => 0.4167, "elapsedMs" => 754_000 }, fold["totals"])
    assert_equal({ "edit.search_not_found" => 1, "gate.failed:typecheck" => 1, "verify.refuted_by_code" => 2,
                   "verify.unseen_code" => 1 }, fold["reasons"])
    assert_equal({ "started" => 1, "accepted" => 2, "rejected" => 2, "ms" => 0 }, fold["stages"]["review.judge"])
    assert_equal({ "started" => 2, "accepted" => 1, "rejected" => 1, "ms" => 41_000 }, fold["stages"]["task.gates"])
    assert_equal({ "stage" => "task.commit", "status" => "done", "attempts" => 2 }, fold["tasks"]["T1"])
    assert_equal({ "stage" => "review.judge", "status" => "running", "attempts" => 1 }, fold["tasks"]["T2"])
  end

  def test_replay_from_a_seq_returns_only_later_events
    assert_equal (11..24).to_a, E.read(FIXTURE, after: 10).map { |e| e["seq"] }
    assert_empty E.read(FIXTURE, after: 24)
  end

  def test_every_reason_code_has_human_text
    design = %w[model.invalid_json model.schema_mismatch model.empty model.thinking_exhausted model.truncated
                model.context_overflow model.unavailable plan.too_many_files plan.missing_path plan.path_exists
                plan.protected_path plan.cycle plan.no_acceptance plan.too_large_for_context edit.search_not_found
                edit.search_ambiguous edit.undeclared_path edit.protected_path edit.outside_worktree edit.create_exists
                fix.same_errors_twice fix.rounds_exhausted claim.failed_checks verify.refuted_by_code
                verify.contradicted_by_docs verify.no_evidence verify.unseen_code verify.requires_type_violation
                verify.abstained support.docs_do_not_establish challenge.defence_holds confirm.test_passes
                confirm.test_not_writable]
    used = Dir.glob(File.join(TestSupport::ROOT, "lib", "**", "*.rb")).flat_map do |f|
      File.read(f).scan(/reason: "([a-z_]+\.[a-z_]+)"/).flatten + File.read(f).scan(/"((?:verify|confirm|support|challenge|claim)\.[a-z_]+)"/).flatten
    end.uniq
    (design + used).uniq.each do |code|
      text = R.text(code)
      refute_empty text.to_s, code
      refute_equal code, text, "#{code} has no human text"
    end
    %w[gate.failed:typecheck gate.timeout:build gate.skipped:lint].each { |c| assert_match(/typecheck|build|lint/, R.text(c)) }
  end
end
