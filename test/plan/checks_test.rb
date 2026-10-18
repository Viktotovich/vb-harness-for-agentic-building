# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Every plan-check message (DESIGN.md 5.3, M4 acceptance).

require_relative "../test_helper"
require "tmpdir"

class ChecksTest < Minitest::Test
  C = Harness::Plan::Checks

  def setup
    @root = Dir.mktmpdir("harness-checks-")
    { "src/a.ts" => "export const a = 1;\n", "src/b.ts" => "b", "src/b.test.ts" => "b", "src/big.ts" => "x" * 30_000, ".env" => "SECRET=1" }.each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(@root, rel)))
      File.write(File.join(@root, rel), text)
    end
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def task(id, files: { "modify" => ["src/a.ts"] }, depends: [], acceptance: [{ "kind" => "gate", "gate" => "typecheck" }])
    { "id" => id, "title" => "Task #{id}", "intent" => "Do it.", "files" => files, "dependsOn" => depends, "acceptance" => acceptance }
  end

  def issues(*tasks, budget: nil, unavailable: {}, test_gates: [])
    plan = Harness::Plan::PlanParser.parse({ "tasks" => tasks })
    C.run(plan, root: @root, max_files: 3, protected: [".env*"], gates: %w[typecheck lint], budget: budget,
                unavailable: unavailable, test_gates: test_gates)
  end

  def only(list)
    assert_equal 1, list.size, list.map(&:message).inspect
    list.first
  end

  def test_a_good_plan_passes
    assert_empty issues(task("T1"), task("T2", files: { "create" => ["src/c.ts"], "read" => ["src/b.ts"] }, depends: ["T1"]), budget: 10_000)
  end

  # Shakedown bug 1: a real planner produced an inspection-only task, which no gate can prove.
  def test_a_task_that_changes_no_files_is_rejected
    i = only(issues(task("T1", files: { "read" => ["src/a.ts"] })))
    assert_equal "plan.no_changes", i.reason
    assert_match(/T1 creates and modifies no files\. Every task must change something: fold the inspection into the task that writes/, i.message)
    assert_equal "task changes no files", Harness::State::Reasons.text("plan.no_changes")
    assert_includes Harness::Prompts.render("planner_system", max_files: 3, gates: "typecheck", tests: true), "Do not plan tasks that only inspect"
  end

  # Shakedown bug 2: a test the task writes is one of its files, and its exact path reaches the implementer.
  def test_a_written_test_path_joins_the_tasks_files
    written = { "kind" => "test", "path" => "tests/a.test.ts", "write" => true, "describe" => "a is 1" }
    plan = Harness::Plan::PlanParser.parse({ "tasks" => [task("T1", acceptance: [written])] })
    t = plan.tasks.first
    assert_equal ["tests/a.test.ts"], t.files.create
    assert_includes t.writable, "tests/a.test.ts"
    assert_empty issues(task("T1", acceptance: [written]))
    rules = Harness::Prompts.render("edit_rules", files: t.writable.join(", "), tests: t.test_paths, rewrite_bytes: 4096)
    assert_includes rules, "Edit only these files: src/a.ts, tests/a.test.ts."
    assert_includes rules, "Write the test for this task exactly at tests/a.test.ts"
    i = only(issues(task("T2", acceptance: [written.merge("path" => "src/b.test.ts")])))
    assert_equal "plan.path_exists", i.reason, "an existing file named as a new test must be listed under modify"
    assert_empty issues(task("T3", files: { "modify" => %w[src/a.ts src/b.test.ts] }, acceptance: [written.merge("path" => "src/b.test.ts")]))
    i = only(issues(task("T4", files: { "modify" => %w[src/a.ts src/b.ts], "create" => %w[src/c.ts] }, acceptance: [written])))
    assert_equal "plan.too_many_files", i.reason, "the written test counts toward maxFilesPerTask"
  end

  def test_too_many_files
    i = only(issues(task("T3", files: { "modify" => %w[src/a.ts src/b.ts], "create" => %w[src/c.ts src/d.ts] })))
    assert_equal "plan.too_many_files", i.reason
    assert_equal "T3 creates or modifies 4 files; the limit is 3 per task. Split it into smaller tasks", i.message
  end

  def test_missing_path
    i = only(issues(task("T1", files: { "modify" => ["src/nope.ts"] })))
    assert_equal ["plan.missing_path", "T1: src/nope.ts does not exist (files.modify) and no task it depends on creates it; " \
                                       "add the task that creates it to dependsOn, or list only existing files"],
                 [i.reason, i.message]
    assert_equal "plan.missing_path", only(issues(task("T1", files: { "modify" => ["src/a.ts"], "read" => ["src/gone.ts"] }))).reason
  end

  # A live run: T1 created a stylesheet and later tasks read it; the check refused files that did not exist yet.
  def test_a_file_an_earlier_task_creates_can_be_read_or_modified
    t1 = task("T1", files: { "create" => ["src/styles/global.css"] })
    t2 = task("T2", files: { "create" => ["src/Header.astro"], "read" => ["src/styles/global.css"] }, depends: ["T1"])
    t3 = task("T3", files: { "modify" => ["src/styles/global.css", "src/Header.astro"] }, depends: ["T2"])
    assert_empty issues(t1, t2, t3, budget: 10_000), "dependencies count transitively: T3 needs T2, which needs T1"
    stray = task("T4", files: { "create" => ["src/x.ts"], "read" => ["src/styles/global.css"] })
    i = only(issues(t1, stray))
    assert_equal ["plan.missing_path", "T4"], [i.reason, i.task], "without dependsOn the file may not exist yet when T4 runs"
    assert_includes Harness::Prompts.render("planner_system", max_files: 3, gates: "typecheck", tests: true),
                    "files that a task in \"dependsOn\" creates"
  end

  # A live run: the planner proved a stylesheet task with the unit gate, whose tool the repository does not have;
  # the task was blocked at its gates and every task after it was skipped. The plan check now says so up front.
  def test_a_gate_the_baseline_could_not_run_is_refused
    missing = { "lint" => "tool not installed: canceled due to missing packages" }
    i = only(issues(task("T1", acceptance: [{ "kind" => "gate", "gate" => "lint" }]), unavailable: missing))
    assert_equal "plan.gate_unavailable", i.reason
    assert_equal "T1: the lint gate cannot run in this repository (tool not installed: canceled due to missing packages); " \
                 "use one of typecheck", i.message
    assert_equal "plan names a gate that cannot run in this repository", Harness::State::Reasons.text("plan.gate_unavailable")
    test_item = { "kind" => "test", "path" => "src/a.test.ts", "write" => false, "describe" => "a is 1" }
    i = only(issues(task("T2", acceptance: [test_item]), unavailable: missing, test_gates: ["lint"]))
    assert_match(/T2: tests cannot run in this repository \(lint: tool not installed/, i.message)
    assert_empty issues(task("T3", acceptance: [test_item]), test_gates: ["lint"]), "tests are fine when their gate runs"
    no_tests = 'use "gate" and "assert" items only, never "test"'
    assert_includes Harness::Prompts.render("planner_system", max_files: 3, gates: "typecheck", tests: false), no_tests
    refute_includes Harness::Prompts.render("planner_system", max_files: 3, gates: "typecheck", tests: true), no_tests
  end

  # A field plan proved an .astro page with {"kind": "test", "path": "src/pages/admin/index.astro"}: the page itself
  # as its test, so the unit gate ran the test runner on a page. Test items must name test files.
  def test_a_test_item_must_name_a_test_file
    page = { "kind" => "test", "path" => "src/pages/admin/index.astro", "write" => true, "describe" => "it renders" }
    i = only(issues(task("T1", files: { "modify" => ["src/a.ts"] }, acceptance: [page])))
    assert_equal "plan.not_a_test_file", i.reason
    assert_match(/T1: the test item's path src\/pages\/admin\/index\.astro is not a test file/, i.message)
    assert_equal "plan names a test that is not a test file", Harness::State::Reasons.text("plan.not_a_test_file")
    %w[tests/a.test.ts src/lib/price.spec.js test/unit/price.ts e2e/home.ts src/__tests__/a.tsx lib/price_test.rb].each do |path|
      ok = { "kind" => "test", "path" => path, "write" => true, "describe" => "x" }
      assert_empty issues(task("T1", files: { "modify" => ["src/a.ts"] }, acceptance: [ok])), "#{path} is a test file"
    end
  end

  def test_unavailable_gates_come_from_the_baseline
    result = ->(status, reason) { Harness::Gates::Result.new(gate: "g", status: status, exit_code: nil, diagnostics: [], reason: reason, ms: 0, argv: []) }
    baseline = { "unit" => result.call("skipped", "tool not installed"), "build" => result.call("passed", nil) }
    assert_equal({ "unit" => "tool not installed" }, C.unavailable(baseline))
  end

  def test_path_exists
    i = only(issues(task("T1", files: { "create" => ["src/a.ts"] })))
    assert_equal ["plan.path_exists", "T1: src/a.ts already exists (files.create); list it under files.modify instead"], [i.reason, i.message]
  end

  def test_protected_and_outside_paths
    i = only(issues(task("T1", files: { "modify" => [".env"] })))
    assert_equal ["plan.protected_path", "T1: .env is a protected path and cannot be part of a task"], [i.reason, i.message]
    i = only(issues(task("T1", files: { "create" => ["../outside.ts"] })))
    assert_equal ["plan.protected_path", "T1: ../outside.ts is outside the repository and cannot be part of a task"], [i.reason, i.message]
  end

  def test_cycle
    i = only(issues(task("T1", depends: ["T2"]), task("T2", depends: ["T1"])))
    assert_equal ["plan.cycle", nil], [i.reason, i.task]
    assert_equal "tasks T1, T2 depend on each other in a cycle; remove a dependency so they can run in order", i.message
  end

  def test_no_acceptance_and_unknown_gate
    i = only(issues(task("T1", acceptance: [{ "kind" => "assert", "text" => "looks right" }])))
    assert_equal ["plan.no_acceptance", "T1 has no acceptance item of kind gate or test; add one so the task can be proven"],
                 [i.reason, i.message]
    i = only(issues(task("T1", acceptance: [{ "kind" => "gate", "gate" => "vibes" }])))
    assert_equal ["plan.unknown_gate", "T1: there is no gate named vibes; use one of typecheck, lint"], [i.reason, i.message]
  end

  def test_too_large_for_context
    i = only(issues(task("T3", files: { "modify" => ["src/big.ts"] }), budget: 2000))
    assert_equal "plan.too_large_for_context", i.reason
    assert_match(/\Asplit T3: its files need ~\d+ tokens, the budget is 2000\z/, i.message)
    assert_empty issues(task("T3", files: { "modify" => ["src/big.ts"] }), budget: 20_000)
  end
end
