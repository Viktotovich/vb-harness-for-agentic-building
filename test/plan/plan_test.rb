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
end
