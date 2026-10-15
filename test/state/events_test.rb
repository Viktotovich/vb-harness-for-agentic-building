# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

class EventsTest < Minitest::Test
  S = Harness::State

  def setup
    @dir = Dir.mktmpdir("harness-events-")
    @path = File.join(@dir, "events.jsonl")
    @t = Time.utc(2026, 10, 15, 12, 0, 0)
    @events = S::Events.new(path: @path, run_id: "r7", clock: -> { @t += 1 })
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_events_are_appended_with_increasing_seq
    @events.emit(stage: "task.apply", kind: "rejected", task: "T2", subject: "replace src/a.ts", reason: "edit.search_not_found")
    @events.emit(stage: "task.gates", kind: "rejected", task: "T2", reason: "gate.failed:typecheck", ms: 1200)
    all = S::Events.read(@path)
    assert_equal [1, 2], all.map { |e| e["seq"] }
    assert_equal({ "seq" => 1, "at" => "2026-10-15T12:00:01Z", "run" => "r7", "stage" => "task.apply", "kind" => "rejected",
                   "task" => "T2", "subject" => "replace src/a.ts", "reason" => "edit.search_not_found" }, all.first)
    assert_equal [2], S::Events.read(@path, after: 1).map { |e| e["seq"] }
    assert_equal 3, S::Events.new(path: @path, run_id: "r7").emit(stage: "report", kind: "done")["seq"], "seq continues after a restart"
  end

  def test_unknown_stage_kind_reason_or_field_is_refused
    assert_raises(ArgumentError) { @events.emit(stage: "task.dance", kind: "done") }
    assert_raises(ArgumentError) { @events.emit(stage: "task.apply", kind: "maybe") }
    assert_raises(ArgumentError) { @events.emit(stage: "task.apply", kind: "rejected", reason: "edit.vibes") }
    assert_raises(ArgumentError) { @events.emit(stage: "task.apply", kind: "rejected", secret: "x") }
  end

  def test_a_torn_last_line_is_ignored
    @events.emit(stage: "intake", kind: "stage_started")
    File.write(@path, "{\"seq\": 2, \"st", mode: "a")
    assert_equal [1], S::Events.read(@path).map { |e| e["seq"] }
  end

  def test_summary_folds_counts_reasons_tasks_and_rejection_rate
    @events.emit(stage: "task.implement", kind: "stage_started", task: "T1")
    @events.emit(stage: "task.implement", kind: "accepted", task: "T1", tokens: { "in" => 100, "out" => 40 })
    @events.emit(stage: "task.apply", kind: "rejected", task: "T1", reason: "edit.search_not_found")
    @events.emit(stage: "task.apply", kind: "rejected", task: "T1", reason: "edit.search_not_found")
    @events.emit(stage: "task.gates", kind: "accepted", task: "T1", ms: 500)
    @events.emit(stage: "task.commit", kind: "done", task: "T1", subject: "task")
    @events.emit(stage: "task.gather", kind: "skipped", task: "T2", subject: "task")
    s = S::Events.summary(@path)
    assert_equal({ "produced" => 4, "accepted" => 2, "rejected" => 2, "tokensIn" => 100, "tokensOut" => 40,
                   "rejectionRate" => 0.5, "elapsedMs" => 6000 }, s["totals"])
    assert_equal({ "edit.search_not_found" => 2 }, s["reasons"])
    assert_equal %w[done skipped], [s.dig("tasks", "T1", "status"), s.dig("tasks", "T2", "status")]
    assert_equal 500, s.dig("stages", "task.gates", "ms")
    assert File.exist?(File.join(@dir, "summary.json"))
    @events.emit(stage: "report", kind: "done")
    assert_equal 8, S::Events.summary(@path)["seq"], "a stale cache is rebuilt"
  end

  def test_every_reason_code_has_human_text
    S::Reasons::TEXT.each_key { |code| refute_empty S::Reasons.text(code) }
    assert_equal "typecheck failed", S::Reasons.text("gate.failed:typecheck")
    assert_equal "e2e could not run", S::Reasons.text("gate.skipped:e2e")
    assert_raises(ArgumentError) { S::Reasons.text("made.up") }
  end
end
