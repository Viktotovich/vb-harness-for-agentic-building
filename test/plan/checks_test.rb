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
    { "src/a.ts" => "export const a = 1;\n", "src/b.ts" => "b", "src/big.ts" => "x" * 30_000, ".env" => "SECRET=1" }.each do |rel, text|
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

  def issues(*tasks, budget: nil)
    plan = Harness::Plan::PlanParser.parse({ "tasks" => tasks })
    C.run(plan, root: @root, max_files: 3, protected: [".env*"], gates: %w[typecheck lint], budget: budget)
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
    assert_includes Harness::Prompts.render("planner_system", max_files: 3, gates: "typecheck"), "Do not plan tasks that only inspect"
  end

  # Shakedown bug 2: a test the task writes is one of its files, and its exact path reaches the implementer.
  def test_a_written_test_path_joins_the_tasks_files
    written = { "kind" => "test", "path" => "tests/a.test.ts", "write" => true, "describe" => "a is 1" }
    plan = Harness::Plan::PlanParser.parse({ "tasks" => [task("T1", acceptance: [written])] })
    t = plan.tasks.first
    assert_equal ["tests/a.test.ts"], t.files.create
    assert_includes t.writable, "tests/a.test.ts"
    assert_empty issues(task("T1", acceptance: [written]))
    rules = Harness::Prompts.render("edit_rules", files: t.writable.join(", "), tests: t.test_paths)
    assert_includes rules, "Edit only these files: src/a.ts, tests/a.test.ts."
    assert_includes rules, "Write the test for this task exactly at tests/a.test.ts"
    i = only(issues(task("T2", acceptance: [written.merge("path" => "src/b.ts")])))
    assert_equal "plan.path_exists", i.reason, "an existing file named as a new test must be listed under modify"
    assert_empty issues(task("T3", files: { "modify" => %w[src/a.ts src/b.ts] }, acceptance: [written.merge("path" => "src/b.ts")]))
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
    assert_equal ["plan.missing_path", "T1: src/nope.ts does not exist (files.modify); only existing files can be modified or read"],
                 [i.reason, i.message]
    assert_equal "plan.missing_path", only(issues(task("T1", files: { "modify" => ["src/a.ts"], "read" => ["src/gone.ts"] }))).reason
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
