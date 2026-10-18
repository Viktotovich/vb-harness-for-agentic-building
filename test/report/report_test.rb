# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# DESIGN.md 10.2 and 11.5: report.md and harness status, built from a run's files.

require_relative "../test_helper"
require_relative "../support/review_run"
require "json"
require "tmpdir"

class ReportTest < Minitest::Test
  RR = TestSupport::ReviewRun
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer
  PRICE = "src/lib/price.ts"
  CLAIM = RR.claim(PRICE, 2, "Prices are not rounded | to cents\n## so fractional amounts <b>reach</b> the page.", "return n * 2;")
  WEAK = RR.claim(PRICE, 2, "Doubling may overflow for huge prices.", "return n * 2;")

  def setup
    @tmp = Dir.mktmpdir("harness-report-")
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  # Runs T1 under the review fixture. confirm: one confirm reply per claim, in order.
  def run_plan(tasks, replies)
    repo, @env = TestSupport.repo(@tmp, RR::FILES)
    @server = F.server(replies)
    config = RR.config(@server.base_url)
    @store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "home", "runs"), run_id: "r20261016-120000-abcd")
    setup = Harness::Run.intake(config: config, repo: repo, store: @store, parent_env: ENV.to_h.merge(@env))
    Harness::Run.new(config: config, client: F.client(config, @store), setup: setup).execute(Harness::Plan::PlanParser.parse({ "tasks" => tasks }))
  end

  def report
    File.read(File.join(@store.dir, "report.md"))
  end

  def section(name)
    report[/^## #{name}\n(.*?)(?=^## |\z)/m, 1]
  end

  def confirmed_and_question_run
    confirm = [Fake.ok(JSON.generate({ "edits" => [], "tests" => [{ "op" => "create", "path" => "tests/harness-confirm-T1-C1.test.txt",
                                                                     "content" => "expect_includes src/lib/price.ts Math.round\n" }], "notes" => "t" })),
               Fake.ok(JSON.generate({ "edits" => [], "tests" => [{ "op" => "create", "path" => "tests/harness-confirm-T1-C2.test.txt",
                                                                     "content" => "expect_includes src/lib/price.ts n * 2\n" }], "notes" => "t" }))]
    run_plan([F.task("T1", "Double | the price", modify: [PRICE])],
             { "T1 implement" => F.replace(PRICE, "  return n;", "  return n * 2;"),
               "T1R1 implement" => F.replace(PRICE, "  return n * 2;", "  return Math.round(n * 2 * 100) / 100;"),
               "review" => [RR.discovery([CLAIM, WEAK.merge("line" => 2)]), RR.discovery([])],
               "verify" => [Fake.ok("DONE"), Fake.ok(JSON.generate({ "verdicts" => [RR.verdict(1, "return n * 2;"), RR.verdict(2, "return n * 2;")] }))],
               "challenge" => [Fake.ok("DONE"), Fake.ok(JSON.generate({ "defence" => "none", "defence_holds" => false, "unseen" => "",
                                                                        "concede_reason" => "price(0.333) returns 0.666, not 0.67." }))],
               "confirm" => confirm })
  end

  def test_the_report_has_every_section_and_only_confirmed_findings
    out = confirmed_and_question_run
    assert_equal 0, out.exit_code
    %w[Tasks Gates\ against\ the\ baseline Findings Questions Blocked\ tasks Rejections Cost].each do |name|
      assert_match(/^## #{name}$/, report, name)
    end
    assert_match(/- Status: \*\*done\*\* \(exit code 0\)/, report)
    assert_match(/\| T1 \| Double \\\| the price \| done \| `\h{7}` \| 0 \| typecheck passed \|/, report, "titles cannot add table cells")
    assert_match(/\| T1R1 \| .* \| done \|/, report)
    findings = section("Findings")
    assert_includes findings, "`src/lib/price.ts:2`"
    assert_includes findings, "test `tests/harness-confirm-T1-C1.test.txt`"
    assert_includes findings, "Prices are not rounded \\| to cents ## so fractional amounts &lt;b&gt;reach&lt;/b&gt; the page."
    refute_includes findings, "overflow", "I8: an unconfirmed claim is never a finding"
    assert_includes section("Questions"), "Unconfirmed claim (T1, `src/lib/price.ts:2`, confirming test passes): Doubling may overflow"
    refute_match(/^## so fractional/, report, "model text cannot add headings")
    assert_match(/\| reviewer \| default \| \d+ \| \d+ \| \d+ \| (\d+|-) \|/, section("Cost"))
    assert_includes section("Cost"), "Models: `test-model`"
    assert_includes section("Cost"), "A reply cut off at the length limit counts its whole output allowance"
    assert_match(/\| unit \| passed \| passed \(pass\) \|/, section("Gates against the baseline"))
  end

  def test_blocked_tasks_and_rejections
    broken = F.replace(PRICE, "  return n;", "  return n * 2; // BROKEN 4")
    run_plan([F.task("T1", "Double", modify: [PRICE])], { "T1 implement" => broken, "T1 fix" => F.replace(PRICE, "BROKEN 4", "BROKEN 4") })
    blocked = section("Blocked tasks")
    assert_match(/- \*\*T1\*\*: #{Harness::State::Reasons.text("fix.same_errors_twice")}\. Patch: `tasks\/T1\/blocked\.patch`\./, blocked)
    assert_match(%r{  - typecheck: `src/lib/price\.ts:2` Value 4 is not a number\.}, blocked)
    rejections = section("Rejections")
    assert_match(/\| \d+ \| typecheck failed \| `gate\.failed:typecheck` \| task\.gates \|/, rejections)
    assert_match(/- `gate\.failed:typecheck` \(T1\): "/, rejections)
    assert_match(/- Status: \*\*failed\*\* \(exit code 1\)/, report)
  end

  def test_status_shows_tasks_marks_and_the_reasons
    broken = F.replace(PRICE, "  return n;", "  return n * 2; // BROKEN 4")
    run_plan([F.task("T1", "Double", modify: [PRICE]), F.task("T2", "Tax", modify: ["src/lib/tax.ts"], depends: ["T1"])],
             { "T1 implement" => broken, "T1 fix" => F.replace(PRICE, "BROKEN 4", "BROKEN 4") })
    text = Harness::Report::Status.render(@store)
    assert_match(/\ARun r20261016-120000-abcd · failed · \d+s · \d+ tok$/, text.lines.first)
    assert_match(/^Plan ✓ ── Tasks 2\/2 ✓ ── Integration ✓ ── Final review ○ ── Report ✓$/, text)
    assert_match(/^T1    Double\s+✕ blocked: .+ \(tasks\/T1\/blocked\.patch\)$/, text)
    assert_match(/^T2    Tax\s+↷ skipped: depends on T1/, text)
    assert_match(/^Outputs  \d+ produced · \d+ accepted · \d+ rejected \(\d+%\)$/, text)
    assert_match(/^\s+\d+  typecheck failed\s+task\.gates$/, text)
  end

  def test_status_of_a_running_task_shows_its_sub_stages
    @store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "r1")
    @store.write_run({ "status" => "running" })
    Harness::State.write_json(@store.plan_path, { "tasks" => [F.task("T1", "Card", modify: [PRICE]), F.task("T2", "Page", modify: [PRICE], depends: ["T1"])] })
    @store.write_task_state("T1", { "id" => "T1", "state" => "reviewing", "fixRounds" => 1 })
    events = Harness::State::Events.new(path: @store.events_path, run_id: "r1")
    %w[task.gather task.implement task.apply task.gates task.fix review.discover review.verify review.challenge].each do |stage|
      events.emit(stage: stage, kind: "stage_started", task: "T1", attempt: 2)
    end
    text = Harness::Report::Status.render(@store)
    assert_match(/^T1    Card\s+● review › challenge   \(attempt 2\)$/, text)
    assert_includes text, "gather ✓ implement ✓ apply ✓ gates ✓ fix ✓ review: discover ✓ verify ✓ judge ○ support ○ challenge ● confirm-test ○"
    assert_match(/^T2    Page\s+○ waiting on T1$/, text)
    refute Harness::Report::Status.finished?(@store)
  end

  def test_cli_status_and_report
    confirmed_and_question_run
    config = File.join(@tmp, "home", "config.json")
    File.write(config, "{}")
    out = TestSupport::Sink.new
    assert_equal 0, Harness::CLI.run(["status", "--config", config], out: out, err: TestSupport::Sink.new)
    assert_match(/\ARun r20261016-120000-abcd · done/, out.string, "the newest run by default")
    out = TestSupport::Sink.new
    File.delete(File.join(@store.dir, "report.md"))
    assert_equal 0, Harness::CLI.run(["report", @store.run_id, "--config", config, "--json"], out: out, err: TestSupport::Sink.new)
    assert_equal File.join(@store.dir, "report.md"), JSON.parse(out.string)["report"]
    assert File.file?(File.join(@store.dir, "report.md"))
    err = TestSupport::Sink.new
    assert_equal 2, Harness::CLI.run(["report", "nope", "--config", config], out: TestSupport::Sink.new, err: err)
    assert_match(/no run nope/, err.string)
    json = TestSupport::Sink.new
    Harness::CLI.run(["status", @store.run_id, "--config", config, "--json"], out: json, err: TestSupport::Sink.new)
    assert_equal "done", JSON.parse(json.string)["status"]
  end
end
