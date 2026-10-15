# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# DESIGN.md 8.4-8.5: a claim confirmed by a failing test becomes a fix task in the same run, with that test as its
# acceptance; review never blocks the commit it reviewed.

require_relative "../test_helper"
require_relative "../support/review_run"
require "tmpdir"

class FollowUpTest < Minitest::Test
  RR = TestSupport::ReviewRun
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer
  PRICE = "src/lib/price.ts"
  TEST = "tests/harness-confirm-T1-C1.test.txt"
  CLAIM = RR.claim(PRICE, 2, "Prices are not rounded to cents, so fractional amounts reach the page.", "return n * 2;")

  def setup
    @tmp = Dir.mktmpdir("harness-follow-up-")
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def run_plan(replies)
    repo, @env = TestSupport.repo(@tmp, RR::FILES)
    @server = F.server(replies)
    config = RR.config(@server.base_url)
    @store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "fu")
    setup = Harness::Run.intake(config: config, repo: repo, store: @store, parent_env: ENV.to_h.merge(@env))
    Harness::Run.new(config: config, client: F.client(config, @store), setup: setup)
                .execute(Harness::Plan::PlanParser.parse({ "tasks" => [F.task("T1", "Double the price", modify: [PRICE])] }))
  end

  def replies(confirm)
    {
      "T1 implement" => F.replace(PRICE, "  return n;", "  return n * 2;"),
      "T1R1 implement" => F.replace(PRICE, "  return n * 2;", "  return Math.round(n * 2 * 100) / 100;"),
      "review" => [RR.discovery([CLAIM]), RR.discovery([])],
      "verify" => [Fake.ok("DONE"), Fake.ok(JSON.generate({ "verdicts" => [RR.verdict(1, "return n * 2;")] }))],
      "challenge" => [Fake.ok("DONE"), Fake.ok(JSON.generate({ "defence" => "none", "defence_holds" => false, "unseen" => "",
                                                               "concede_reason" => "price(0.333) returns 0.666, not 0.67." }))],
      "confirm" => confirm
    }
  end

  def confirm_reply(content)
    Fake.ok(JSON.generate({ "edits" => [], "tests" => [{ "op" => "create", "path" => TEST, "content" => content }], "notes" => "t" }))
  end

  def test_a_confirmed_claim_becomes_a_fix_task_that_must_pass_its_test
    out = run_plan(replies(confirm_reply("expect_includes src/lib/price.ts Math.round\n")))
    assert_empty @server.errors
    assert_equal [%w[T1 done], %w[T1R1 done]], out.tasks.map { |t| [t.id, t.status] }
    assert_equal 0, out.exit_code
    log = TestSupport.git!(out.worktree, @env, "log", "--format=%s", "main..HEAD").lines.map(&:strip)
    assert_equal 2, log.size
    assert_equal "T1: Double the price", log.last, "the reviewed task was committed first: review does not block"
    assert_match(/\AT1R1: Fix: Prices are not rounded/, log.first)
    assert_equal "expect_includes src/lib/price.ts Math.round\n", File.read(File.join(out.worktree, TEST)), "the test is committed with the fix"
    assert_includes File.read(File.join(out.worktree, PRICE)), "Math.round"

    review = JSON.parse(File.read(File.join(@store.task_dir("T1"), "review.json")))
    assert_equal [["C1", TEST]], review["findings"].map { |f| [f["id"], f["test"]] }
    plan = JSON.parse(File.read(@store.plan_path))
    assert_equal %w[T1 T1R1], plan["tasks"].map { |t| t["id"] }, "a resumed run knows the fix task"
    assert_equal [{ "kind" => "test", "path" => TEST, "write" => true, "describe" => "fails while the defect is present" },
                  { "kind" => "gate", "gate" => "typecheck" }], plan["tasks"][1]["acceptance"]
    assert File.file?(@store.final_review_path)
  end

  def test_a_test_that_cannot_be_written_leaves_a_question_and_no_task
    out = run_plan(replies(Fake.ok(JSON.generate({ "edits" => [], "tests" => [], "notes" => "no runner for this" }))))
    assert_equal [%w[T1 done]], out.tasks.map { |t| [t.id, t.status] }
    review = JSON.parse(File.read(File.join(@store.task_dir("T1"), "review.json")))
    assert_empty review["findings"]
    assert_equal [%w[C1 confirm.test_not_writable]], review["questions"].map { |q| [q["id"], q["reason"]] }
  end
end
