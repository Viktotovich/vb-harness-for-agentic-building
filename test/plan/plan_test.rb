# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"

class PlanTest < Minitest::Test
  P = Harness::Plan::PlanParser

  def task(id, depends: [], **extra)
    { "id" => id, "title" => "Task #{id}", "intent" => "Do #{id}.", "files" => { "modify" => ["src/#{id}.ts"] },
      "dependsOn" => depends, "acceptance" => [{ "kind" => "gate", "gate" => "typecheck" }] }.merge(extra.transform_keys(&:to_s))
  end

  def error(raw)
    assert_raises(Harness::ParseError) { P.parse(raw) }.message
  end

  def test_parses_the_spec_example
    plan = P.parse({ "tasks" => [task("T1", acceptance: [
                                        { "kind" => "gate", "gate" => "typecheck" },
                                        { "kind" => "test", "path" => "tests/unit/x.test.ts", "write" => true, "describe" => "x works" },
                                        { "kind" => "assert", "text" => "no layout shift" }
                                      ])],
                     "questions" => [{ "text" => "Which currency?", "blocking" => true }] })
    t = plan.tasks.first
    assert_equal ["tests/unit/x.test.ts"], t.test_paths
    assert_equal %w[src/T1.ts tests/unit/x.test.ts], t.writable
    assert_equal ["check typecheck passes", "test tests/unit/x.test.ts (write it): x works", "review: no layout shift"],
                 t.acceptance.map(&:summary)
    assert plan.questions.first.blocking
    assert_equal plan, P.parse(plan.to_json_hash)
  end

  def test_precise_errors
    assert_equal "tasks[0].files.modify: expected array of strings, got nil",
                 error({ "tasks" => [task("T1", "files" => { "modify" => nil })] })
    assert_equal "tasks[1].id: duplicate id T1", error({ "tasks" => [task("T1"), task("T1")] })
    assert_equal "tasks[0].dependsOn: no task T9", error({ "tasks" => [task("T1", depends: ["T9"])] })
    assert_match(/\Atasks\[0\].acceptance\[0\].kind: expected one of gate, test, assert/,
                 error({ "tasks" => [task("T1", "acceptance" => [{ "kind" => "vibe" }])] }))
    assert_match(/\Atasks\[0\].id: expected id like T1/, error({ "tasks" => [task("../T1")] }))
  end

  def test_order_follows_dependencies_and_finds_cycles
    plan = P.parse({ "tasks" => [task("T2", depends: ["T1"]), task("T1"), task("T3", depends: ["T2"])] })
    assert_equal %w[T1 T2 T3], plan.ordered.map(&:id)
    assert_equal %w[T2 T3], plan.dependants("T1")
    cyclic = P.parse({ "tasks" => [task("T1", depends: ["T2"]), task("T2", depends: ["T1"])] })
    assert_match(/dependency cycle among T1, T2/, assert_raises(Harness::ParseError) { cyclic.ordered }.message)
  end

  def linked_plan(*tasks)
    raw = tasks.map do |id, create, read, deps|
      { "id" => id, "title" => id, "intent" => "#{id}.", "files" => { "create" => create, "modify" => [], "read" => read },
        "dependsOn" => deps, "acceptance" => [{ "kind" => "gate", "gate" => "typecheck" }] }
    end
    P.parse({ "tasks" => raw, "questions" => [] }).linked
  end

  def test_a_task_gets_the_dependency_on_the_one_task_that_creates_what_it_reads
    plan = linked_plan(["T1", ["a.ts"], [], []], ["T2", [], ["a.ts"], []], ["T3", [], ["a.ts", "b.ts"], []])
    assert_equal [[], ["T1"], ["T1"]], plan.tasks.map(&:depends_on)
  end

  def test_a_dependency_already_implied_is_not_repeated
    plan = linked_plan(["T1", ["a.ts"], [], []], ["T2", ["b.ts"], [], ["T1"]], ["T3", [], ["a.ts"], ["T2"]])
    assert_equal ["T2"], plan.task("T3").depends_on
  end

  def test_two_creators_or_a_cycle_are_left_for_the_checks
    two = linked_plan(["T1", ["a.ts"], [], []], ["T2", ["a.ts"], [], []], ["T3", [], ["a.ts"], []])
    assert_empty two.task("T3").depends_on
    cycle = linked_plan(["T1", ["a.ts"], ["b.ts"], []], ["T2", ["b.ts"], ["a.ts"], []])
    assert_equal 1, cycle.tasks.sum { |t| t.depends_on.size }, "one way round is fine; the other would be a cycle"
    assert_equal cycle.tasks.size, cycle.ordered.size
  end
end
