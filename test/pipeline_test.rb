# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# M4 acceptance: planning with replans and its cap, blocking questions and answers, --plan-only, and
# resuming a run from each task state.

require_relative "test_helper"
require_relative "support/run_fixture"
require "json"
require "tmpdir"

class PipelineTest < Minitest::Test
  F = TestSupport::RunFixture
  PRICE = "src/lib/price.ts"
  GOOD = F.replace(PRICE, "  return n;", "  return n * 2;")
  DOUBLED = "export function price(n: number): number {\n  return n * 2;\n}\n"

  def setup
    @tmp = Dir.mktmpdir("harness-pipeline-")
  end

  def teardown
    @fx&.server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def fixture(replies)
    @fx = F.pipeline(@tmp, replies)
  end

  def t1(**over)
    F.task("T1", "Double the price", modify: [PRICE]).merge(over.transform_keys(&:to_s))
  end

  def store(result)
    Harness::State::RunStore.new(runs_dir: @fx.runs_dir, run_id: result.run_id)
  end

  def bodies(kind)
    @fx.server.chat_bodies.select { |b| b["messages"].first["content"].start_with?(kind) }
  end

  def worktree_file(result, rel)
    File.read(File.join(store(result).read_run["worktree"], rel))
  end

  # --- planning ---

  def test_a_request_is_planned_and_built
    fixture({ "plan" => F.plan_reply([t1]), "T1 implement" => GOOD })
    r = @fx.pipeline.start(repo: @fx.repo, request: "Make the price double.")
    assert_equal [0, "done"], [r.exit_code, r.status]
    assert_equal "done", r.outcome.tasks.first.status
    planner_user = bodies("You plan").first["messages"].last["content"]
    assert_includes planner_user, "Make the price double."
    assert_match(%r{<untrusted-data id="\h+">\n.*src/lib/price\.ts \(\d+ bytes\)}m, planner_user, "the file list is fenced")
    assert_includes planner_user, "File src/lib/price.ts:", "files named like the request are included"
    assert_equal "Make the price double.", store(r).read_request
  end

  def test_a_discarded_planner_reply_is_counted_as_a_plan_rejection
    truncated = TestSupport::FakeLlmServer.error(502, "structured output was incomplete (finish_reason=length)")
    fixture({ "plan" => [truncated, F.plan_reply([t1])], "T1 implement" => GOOD })
    r = @fx.pipeline.start(repo: @fx.repo, request: "Make the price double.")
    assert_equal [0, "done"], [r.exit_code, r.status]
    events = Harness::State::Events.read(store(r).events_path)
    rejected = events.select { |e| e["kind"] == "rejected" }
    assert_equal [["plan", "model.truncated", "plan0"]], rejected.map { |e| e.values_at("stage", "reason", "subject") }
    assert_match(/retried with thinking off/, rejected.first["detail"])
    fold = Harness::State::Events.fold(events)
    assert_equal 1, fold["reasons"]["model.truncated"]
    assert_equal 1, fold["stages"]["plan"]["rejected"]
  end

  def test_failed_checks_are_fed_back_and_the_plan_is_corrected
    bad = t1(files: { "modify" => ["src/lib/missing.ts"] })
    fixture({ "plan" => [F.plan_reply([bad]), F.plan_reply([t1])], "T1 implement" => GOOD })
    r = @fx.pipeline.start(repo: @fx.repo, request: "Double the price.")
    assert_equal 0, r.exit_code
    second = bodies("You plan")[1]["messages"].last["content"]
    assert_match(/It failed these checks:\n<untrusted-data id="\h+">\n- T1: src\/lib\/missing.ts does not exist/, second)
    events = Harness::State::Events.read(store(r).events_path)
    assert(events.any? { |e| e["reason"] == "plan.missing_path" })
    assert(events.any? { |e| e["stage"] == "plan" && e["kind"] == "retried" })
  end

  def test_replans_are_capped_and_the_plan_goes_to_the_user
    bad = t1(acceptance: [{ "kind" => "assert", "text" => "looks fine" }])
    fixture({ "plan" => F.plan_reply([bad]) })
    r = @fx.pipeline.start(repo: @fx.repo, request: "Double the price.")
    assert_equal [1, "plan_rejected"], [r.exit_code, r.status]
    assert_equal 1 + 2, bodies("You plan").size, "the first plan and maxReplanRounds replans"
    assert_equal ["plan.no_acceptance"], r.issues.map(&:reason)
    assert File.exist?(r.plan_path), "the plan is saved for the user to read"
    assert_empty bodies("You make"), "nothing is built from a rejected plan"
  end

  # --- questions ---

  def test_blocking_questions_pause_and_answers_resume
    question = [{ "text" => "Which currency?", "blocking" => true }, { "text" => "Round up?", "blocking" => false }]
    fixture({ "plan" => [F.plan_reply([t1], questions: question), F.plan_reply([t1])], "T1 implement" => GOOD })
    r = @fx.pipeline.start(repo: @fx.repo, request: "Show prices.")
    assert_equal [3, "waiting", ["Which currency?"]], [r.exit_code, r.status, r.questions]
    assert_equal ["Which currency?"], @fx.pipeline.questions(r.run_id)
    assert_equal 3, @fx.pipeline.resume(r.run_id).exit_code, "resume waits for the answers"
    assert_raises(Harness::ConfigError) { @fx.pipeline.answer(r.run_id, %w[USD extra]) }

    done = @fx.pipeline.answer(r.run_id, ["USD"])
    assert_equal [0, "done"], [done.exit_code, done.status]
    replan = bodies("You plan").last["messages"].last["content"]
    assert_match(/Answers to your earlier questions:\n<untrusted-data id="\h+">\nQ: Which currency\?\nA: USD/, replan)
    assert_raises(Harness::ConfigError) { @fx.pipeline.answer(r.run_id, ["again"]) }
  end

  # --- plan only, then resume ---

  def test_plan_only_then_an_edited_plan_is_built_on_resume
    fixture({ "plan" => F.plan_reply([t1]), "T1 implement" => GOOD })
    r = @fx.pipeline.start(repo: @fx.repo, request: "Double the price.", plan_only: true)
    assert_equal [0, "planned"], [r.exit_code, r.status]
    assert_empty bodies("You make")
    plan = JSON.parse(File.read(r.plan_path))
    plan["tasks"][0]["title"] = "Double the price, edited"
    File.write(r.plan_path, JSON.generate(plan))
    done = @fx.pipeline.resume(r.run_id)
    assert_equal 0, done.exit_code
    assert_includes bodies("You make").first["messages"].last["content"], "T1: Double the price, edited"
  end

  # --- resume from each task state ---

  # A planned run that stopped while T1 was in state, with the worktree as that state would leave it.
  def interrupted(state, worktree_change: nil, extra: {})
    fixture({ "T1 implement" => GOOD })
    r = @fx.pipeline.start(repo: @fx.repo, plan_hash: { "tasks" => [t1] }, plan_only: true)
    s = store(r)
    s.update_run({ "status" => "running", "planOnly" => false })
    wt = s.read_run["worktree"]
    worktree_change&.call(wt)
    s.write_task_state("T1", { "id" => "T1", "state" => state, "fixRounds" => 0, "touched" => [PRICE], "created" => [] }.merge(extra)) if state
    [r, s, wt]
  end

  def commits(wt)
    TestSupport.git!(wt, @fx.env, "log", "--format=%s", "main..HEAD").lines.map(&:strip)
  end

  def test_resume_from_states_before_the_edits_starts_the_task_over
    [nil, "pending", "gathering", "implementing", "applying"].each do |state|
      teardown
      setup
      stray = lambda do |wt|
        File.write(File.join(wt, PRICE), "half-written")
        File.write(File.join(wt, "src/lib/stray.ts"), "partial")
      end
      r, s, wt = interrupted(state, worktree_change: stray, extra: { "created" => ["src/lib/stray.ts"] })
      out = @fx.pipeline.resume(r.run_id)
      assert_equal 0, out.exit_code, state.inspect
      assert_equal 1, bodies("You make").size, "#{state.inspect}: implemented again"
      assert_equal DOUBLED, File.read(File.join(wt, PRICE))
      refute File.exist?(File.join(wt, "src/lib/stray.ts")), "#{state.inspect}: partial work reverted"
      assert_equal ["T1: Double the price"], commits(wt)
      assert_equal "done", s.read_task_state("T1")["state"]
    end
  end

  def test_resume_after_the_edits_continues_at_the_gates
    %w[applied gating fixing reviewing committing].each do |state|
      teardown
      setup
      r, s, wt = interrupted(state, worktree_change: ->(dir) { File.write(File.join(dir, PRICE), DOUBLED) })
      out = @fx.pipeline.resume(r.run_id)
      assert_equal 0, out.exit_code, state
      assert_empty bodies("You make"), "#{state}: no new model call"
      assert_equal ["T1: Double the price"], commits(wt), state
      assert_equal "done", s.read_task_state("T1")["state"]
    end
  end

  def test_resume_after_the_commit_landed_does_not_commit_again
    land = lambda do |wt|
      File.write(File.join(wt, PRICE), DOUBLED)
      TestSupport.git!(wt, @fx.env, "add", "-A")
      TestSupport.git!(wt, @fx.env, "commit", "-q", "-m", "T1: Double the price")
    end
    r, s, wt = interrupted("committing", worktree_change: land)
    assert_equal 0, @fx.pipeline.resume(r.run_id).exit_code
    assert_equal ["T1: Double the price"], commits(wt)
    assert_equal "done", s.read_task_state("T1")["state"]
    assert_empty bodies("You make")
  end

  def test_finished_tasks_keep_their_outcome_on_resume
    r, = interrupted("done", extra: { "commit" => "abc1234" })
    out = @fx.pipeline.resume(r.run_id)
    assert_equal [0, "abc1234"], [out.exit_code, out.outcome.tasks.first.commit]
    assert_empty bodies("You make")

    teardown
    setup
    r, = interrupted("blocked", extra: { "reason" => "fix.same_errors_twice" })
    out = @fx.pipeline.resume(r.run_id)
    assert_equal [1, "blocked"], [out.exit_code, out.outcome.tasks.first.status]
    assert_empty bodies("You make")
  end

  def test_a_task_stopped_by_a_model_outage_runs_again
    r, = interrupted("blocked", extra: { "reason" => "model.unavailable" })
    out = @fx.pipeline.resume(r.run_id)
    assert_equal [0, "done"], [out.exit_code, out.outcome.tasks.first.status]
    assert_equal 1, bodies("You make").size
  end

  # --- one process per run ---

  def test_a_run_in_use_cannot_be_resumed
    r, s, = interrupted(nil)
    release = Harness::State::Lock.acquire(s.lock_path)
    err = assert_raises(Harness::ConfigError) { @fx.pipeline.resume(r.run_id) }
    assert_match(/in use by another harness process/, err.message)
    release.call
    assert_equal 0, @fx.pipeline.resume(r.run_id).exit_code
  end

  def test_unknown_runs_are_refused
    fixture({})
    assert_raises(Harness::ConfigError) { @fx.pipeline.resume("r-missing") }
    assert_raises(Harness::ConfigError) { @fx.pipeline.resume("../escape") }
  end
end
