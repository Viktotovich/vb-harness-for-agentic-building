# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# The check against the request: a gap goes to a confirming test, and only a failing test makes it a finding (I8).

require_relative "../test_helper"
require_relative "../support/review_run"
require "tmpdir"

class RequestCheckTest < Minitest::Test
  RR = TestSupport::ReviewRun
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer
  Coverage = Harness::Review::Coverage
  PRICE = "src/lib/price.ts"
  TEST = "tests/harness-confirm-T1-G1.test.txt"
  REQUEST = "Double the price and round it to cents."

  def setup
    @tmp = Dir.mktmpdir("harness-request-check-")
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def run_plan(replies, request: REQUEST, tasks: [F.task("T1", "Double the price", modify: [PRICE])])
    repo, @env = TestSupport.repo(@tmp, RR::FILES)
    @server = F.server(replies)
    config = RR.config(@server.base_url)
    @store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "rc")
    setup = Harness::Run.intake(config: config, repo: repo, store: @store, parent_env: ENV.to_h.merge(@env))
    @store.write_request(request) if request
    Harness::Run.new(config: config, client: F.client(config, @store), setup: setup).execute(Harness::Plan::PlanParser.parse({ "tasks" => tasks }))
  end

  def items(*list)
    Fake.ok(JSON.generate({ "items" => list }))
  end

  def item(status, requirement: "Round to cents.", why: "It returns n * 2 unrounded.")
    { "requirement" => requirement, "status" => status, "file" => PRICE, "why" => why }
  end

  def confirm(content)
    Fake.ok(JSON.generate({ "edits" => [], "tests" => [{ "op" => "create", "path" => TEST, "content" => content }], "notes" => "t" }))
  end

  def replies(request, confirm_reply = confirm("expect_includes src/lib/price.ts Math.round\n"))
    { "T1 implement" => F.replace(PRICE, "  return n;", "  return n * 2;"),
      "T1R1 implement" => F.replace(PRICE, "  return n * 2;", "  return Math.round(n * 2 * 100) / 100;"),
      "request" => request, "confirm" => confirm_reply }
  end

  def review
    JSON.parse(File.read(File.join(@store.task_dir("T1"), "review.json")))
  end

  def prompts(opening)
    @server.chat_bodies.select { |b| b["messages"].first["content"].start_with?(opening) }.map { |b| b["messages"].last["content"] }
  end

  def test_a_gap_a_failing_test_confirms_becomes_a_fix_task
    out = run_plan(replies(items(item("met", requirement: "Double the price."), item("missing"))))
    assert_empty @server.errors
    assert_equal [%w[T1 done], %w[T1R1 done]], out.tasks.map { |t| [t.id, t.status] }
    assert_includes File.read(File.join(out.worktree, PRICE)), "Math.round"
    found = review["findings"].first
    assert_equal ["G1", TEST, "request.gap", PRICE], found.values_at("id", "test", "reason", "file")
    assert_match(/\AThe request asks for this and the change does not do it: Round to cents\./, found["problem"])
    assert_empty prompts("You are an independent verifier"), "a failing test is the proof, so the verifier is not asked"
  end

  def test_a_gap_a_test_does_not_show_stays_a_question
    out = run_plan(replies(items(item("missing")), confirm("expect_includes src/lib/price.ts return\n")))
    assert_equal [%w[T1 done]], out.tasks.map { |t| [t.id, t.status] }
    assert_empty review["findings"], "no failing test, no finding (I8)"
    assert_equal [%w[G1 confirm.test_passes]], review["questions"].map { |q| [q["id"], q["reason"]] }
  end

  def test_met_and_elsewhere_items_make_no_claims
    run_plan(replies(items(item("met"), item("elsewhere"))))
    assert_empty review["findings"] + review["questions"]
    assert_empty prompts("You write one automated test")
  end

  def test_a_failed_check_is_recorded_and_the_review_goes_on
    out = run_plan(replies(Fake.ok(JSON.generate({ "items" => [item("maybe")] }))))
    assert_equal [%w[T1 done]], out.tasks.map { |t| [t.id, t.status] }
    assert(review["failures"].any? { |f| f.start_with?("request-check: ") }, review["failures"].inspect)
  end

  def test_a_run_without_a_request_has_no_check
    run_plan(replies(items(item("missing"))), request: nil)
    assert_empty prompts("You compare a code change")
  end

  def test_the_prompt_has_the_request_the_task_and_who_owns_the_rest
    tax = "src/lib/tax.ts"
    tasks = [F.task("T1", "Double the price", modify: [PRICE]), F.task("T2", "Raise the tax", modify: [tax], depends: ["T1"])]
    out = run_plan(replies(items(item("met"))).merge("T2 implement" => F.replace(tax, "0.2", "0.25")), tasks: tasks)
    assert_equal [%w[T1 done], %w[T2 done]], out.tasks.map { |t| [t.id, t.status] }
    first, _second, final = prompts("You compare a code change")
    assert_includes first, REQUEST
    assert_includes first, "T1: Double the price"
    assert_includes first, "T2: Raise the tax (#{tax})"
    assert_includes final, REQUEST
    refute_includes final, "This change is one task", "the final check holds the whole run to the whole request"
  end

  def test_a_fix_task_is_not_held_to_the_whole_request
    run_plan(replies(items(item("missing"))))
    bodies = prompts("You compare a code change")
    assert_equal 2, bodies.size, "T1 and the final review; not the fix task T1R1"
    assert_includes bodies.first, "The request:"
  end

  def test_parse_refuses_what_it_cannot_trust
    assert_raises(Harness::ParseError) { Coverage.parse([]) }
    assert_raises(Harness::ParseError) { Coverage.parse({ "items" => "none" }) }
    assert_raises(Harness::ParseError) { Coverage.parse({ "items" => ["x"] }) }
    assert_raises(Harness::ParseError) { Coverage.parse({ "items" => [item("maybe")] }) }
    assert_equal "missing", Coverage.parse({ "items" => [item("missing")] }).first.status
  end

  # A gap read from part of a diff could be in the part not shown.
  def test_a_diff_in_several_parts_is_skipped_and_says_so
    events = []
    ctx = Struct.new(:events) { def emit(stage, kind, **f) = events << [stage, kind, f] }.new(events)
    prepared = Harness::Review::Prepared.new(chunks: [1, 2], skipped: [], omitted: [])
    scope = Harness::Review::Scope.new(request: REQUEST, task: nil, others: [])
    assert_empty Coverage.new(ctx).call(scope, prepared, "the whole run", [])
    assert_equal ["review.discover", "skipped"], events.first.first(2)
    assert_match(/2 parts/, events.first.last[:detail])
  end
end
