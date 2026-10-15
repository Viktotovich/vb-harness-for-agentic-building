# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# M3 acceptance: the per-task loop end to end on a tiny Astro-like repo with a fake model.

require_relative "../test_helper"
require_relative "../support/run_fixture"
require "tmpdir"

class LoopE2ETest < Minitest::Test
  F = TestSupport::RunFixture
  PRICE = "src/lib/price.ts"
  TAX = "src/lib/tax.ts"

  def setup
    @tmp = Dir.mktmpdir("harness-e2e-")
  end

  def teardown
    @result&.server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def run_plan(tasks, replies)
    @result = F.run(@tmp, { "tasks" => tasks }, replies)
  end

  def events
    Harness::State::Events.read(@result.store.events_path)
  end

  def wt(rel)
    File.read(File.join(@result.outcome.worktree, rel))
  end

  def git_log
    TestSupport.git!(@result.outcome.worktree, @result.env, "log", "--format=%s", "main..HEAD").lines.map(&:strip)
  end

  def test_implement_gate_fails_fix_passes_commit
    run_plan([F.task("T1", "Double the price", modify: [PRICE]), F.task("T2", "Raise the tax", modify: [TAX], depends: ["T1"])],
             { "T1 implement" => F.replace(PRICE, "  return n;", "  return n * 2; // BROKEN"),
               "T1 fix" => F.replace(PRICE, "  return n * 2; // BROKEN", "  return n * 2;"),
               "T2 implement" => F.replace(TAX, "export const rate = 0.2;", "export const rate = 0.25;") })
    o = @result.outcome
    assert_equal 0, o.exit_code
    t1, t2 = o.tasks
    assert_equal ["done", 1], [t1.status, t1.fix_rounds]
    assert_equal ["done", 0], [t2.status, t2.fix_rounds]
    assert_equal ["T2: Raise the tax", "T1: Double the price"], git_log
    assert_equal "export function price(n: number): number {\n  return n * 2;\n}\n", wt(PRICE)
    assert_equal [%w[build pass]], o.integration.map { |c| [c.gate, c.verdict] }

    # the user's checkout is untouched (I11)
    assert_equal F::FILES[PRICE], File.read(File.join(@result.repo, PRICE))

    # the events tell the story: implement, gate fails, fix, gate passes, commit
    t1_events = events.select { |e| e["task"] == "T1" }.map { |e| [e["stage"], e["kind"], e["reason"]].compact.join(" ") }
    assert_equal ["task.implement accepted", "task.apply accepted", "task.gates rejected gate.failed:typecheck",
                  "task.fix accepted", "task.apply accepted", "task.gates accepted", "task.commit done"],
                 t1_events.grep(/accepted|rejected|done/)
    summary = Harness::State::Events.summary(@result.store.events_path)
    assert_equal "done", summary.dig("tasks", "T1", "status")
    assert_equal 1, summary.dig("reasons", "gate.failed:typecheck")

    # the fixer saw the diagnostic, its source line and the diff, each inside the untrusted fence (I9)
    fix_user = @result.server.chat_bodies.find { |b| b["messages"].first["content"].start_with?("You fix") }["messages"].last["content"]
    assert_includes fix_user, "src/lib/price.ts:2:3 error ts(2322): Type 'string' is not assignable to type 'number'."
    assert_match(/>\s+2 \|   return n \* 2; \/\/ BROKEN/, fix_user)
    assert_includes fix_user, "+  return n * 2; // BROKEN"
    assert_equal 3 * 2 + 2, fix_user.scan(/<\/?untrusted-data id=/).size, "task, diagnostics, diff and one file, each fenced"
  end

  def test_blocked_task_saves_a_patch_and_skips_dependants
    run_plan([F.task("T1", "Double the price", modify: [PRICE]),
              F.task("T2", "Use the price", modify: [TAX], depends: ["T1"]),
              F.task("T3", "Raise the tax", modify: [TAX])],
             { "T1 implement" => F.replace(PRICE, "  return n;", "  return n * 2; // BROKEN"),
               "T1 fix" => F.replace(PRICE, "  return n * 2; // BROKEN", "  return n * 3; // BROKEN"),
               "T3 implement" => F.replace(TAX, "export const rate = 0.2;", "export const rate = 0.25;") })
    o = @result.outcome
    assert_equal 1, o.exit_code
    t1, t2, t3 = o.tasks.sort_by(&:id)
    assert_equal %w[blocked fix.same_errors_twice], [t1.status, t1.reason]
    assert_equal "skipped", t2.status
    assert_match(/depends on T1/, t2.detail)
    assert_equal "done", t3.status, "independent tasks continue"

    patch = File.read(File.join(@result.store.task_dir("T1"), "blocked.patch"))
    assert_includes patch, "+  return n * 3; // BROKEN"
    blocked = JSON.parse(File.read(File.join(@result.store.task_dir("T1"), "blocked.json")))
    assert_equal "fix.same_errors_twice", blocked["reason"]
    assert_equal F::FILES[PRICE], wt(PRICE), "the blocked task was reverted"
    assert_equal ["T3: Raise the tax"], git_log
    assert_equal "blocked", JSON.parse(File.read(File.join(@result.store.task_dir("T1"), "state.json")))["state"]
  end

  def test_fix_rounds_are_capped
    # every fix changes the error message ("Value 1 ...", "Value 2 ..."), so only the round cap stops it
    replies = { "T1 implement" => F.replace(PRICE, "  return n;", "  return n; // BROKEN 0"),
                "T1 fix" => (1..5).map { |i| F.replace(PRICE, "BROKEN #{i - 1}", "BROKEN #{i}") } }
    run_plan([F.task("T1", "Double the price", modify: [PRICE])], replies)
    t1 = @result.outcome.tasks.first
    assert_equal ["blocked", "fix.rounds_exhausted", 3], [t1.status, t1.reason, t1.fix_rounds]
    assert_equal 1 + 3, @result.server.chat_bodies.size, "implement plus maxFixRounds fixes"
  end

  def test_the_same_errors_after_a_fix_stop_early
    run_plan([F.task("T1", "Double the price", modify: [PRICE])],
             { "T1 implement" => F.replace(PRICE, "  return n;", "  return n; // BROKEN"),
               "T1 fix" => F.replace(PRICE, "  return n; // BROKEN", "\n  return n; // BROKEN") })
    t1 = @result.outcome.tasks.first
    assert_equal ["blocked", "fix.same_errors_twice", 1], [t1.status, t1.reason, t1.fix_rounds],
                 "a moved line with the same file, code and message is the same problem"
  end

  def test_rejected_edits_get_one_retry
    run_plan([F.task("T1", "Double the price", modify: [PRICE])],
             { "T1 implement" => F.replace(PRICE, "return n ;", "return n * 2;"),
               "T1 retry" => F.replace(PRICE, "  return n;", "  return n * 2;") })
    t1 = @result.outcome.tasks.first
    assert_equal "done", t1.status
    rejected = events.find { |e| e["kind"] == "rejected" && e["stage"] == "task.apply" }
    assert_equal "edit.search_not_found", rejected["reason"]
    retry_user = @result.server.chat_bodies.map { |b| b["messages"].last["content"] }.find { |u| u.include?("could not be applied") }
    assert_includes retry_user, "matched 0 times"
  end

  def test_an_edit_outside_the_task_files_blocks_after_the_retry
    run_plan([F.task("T1", "Double the price", modify: [PRICE])],
             { "T1 implement" => F.replace(TAX, "0.2", "0.3"), "T1 retry" => F.replace(TAX, "0.2", "0.3") })
    t1 = @result.outcome.tasks.first
    assert_equal %w[blocked edit.undeclared_path], [t1.status, t1.reason]
    assert_equal F::FILES[TAX], wt(TAX)
  end

  def test_unusable_model_output_blocks_the_task
    run_plan([F.task("T1", "Double the price", modify: [PRICE])], { "T1 implement" => TestSupport::FakeLlmServer.ok("I would edit price.ts") })
    t1 = @result.outcome.tasks.first
    assert_equal %w[blocked model.invalid_json], [t1.status, t1.reason]
    assert_equal 2, @result.server.chat_bodies.size, "one retry with thinking off, inside the client"
  end

  def test_the_prompt_carries_signatures_and_summaries_of_imported_files
    files = F::FILES.merge(PRICE => "import { rate } from \"./tax\";\n#{F::FILES[PRICE]}")
    @result = F.run(@tmp, { "tasks" => [F.task("T1", "Double the price", modify: [PRICE])] },
                    { "T1 implement" => F.replace(PRICE, "  return n;", "  return n * 2;"),
                      "summary" => TestSupport::FakeLlmServer.ok("Holds the tax rate.") }, files: files)
    assert_equal "done", @result.outcome.tasks.first.status
    user = @result.server.chat_bodies.find { |b| b["messages"].first["content"].start_with?("You make") }["messages"].last["content"]
    assert_match(/Signature of src\/lib\/tax\.ts:\n<untrusted-data id="\h+">\nsrc\/lib\/tax\.ts \(ts, \d+ bytes\)\nexports: rate/, user)
    assert_match(/Summaries of related files:\n<untrusted-data id="\h+">\nsrc\/lib\/tax\.ts: Holds the tax rate\./, user)
    refute_includes user, "File src/lib/tax.ts:", "a related file is shown by its surface, not in full"
  end
end
