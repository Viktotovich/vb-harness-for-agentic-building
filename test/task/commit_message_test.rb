# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"

class CommitMessageTest < Minitest::Test
  M = Harness::Task::CommitMessage
  P = Harness::Plan::PlanParser

  def task(**extra)
    raw = { "id" => "T1", "title" => "Add the Badge component", "intent" => "Add it.", "files" => { "create" => ["src/a.ts"] },
            "acceptance" => [{ "kind" => "gate", "gate" => "build" }] }.merge(extra.transform_keys(&:to_s))
    P.parse({ "tasks" => [raw] }).tasks.first
  end

  def build(t, template = M::DEFAULT_TRAILER)
    M.build(task: t, template: template, model: "some-model", version: "9.9.9", gates: %w[typecheck build])
  end

  def test_without_a_type_the_message_keeps_the_task_id
    assert_equal "T1: Add the Badge component\n\nGates passed: typecheck, build", build(task)
  end

  def test_a_type_gives_a_conventional_subject_with_a_lowercase_start
    assert_equal "feat: add the Badge component\n\nGates passed: typecheck, build", build(task(type: "feat"))
  end

  def test_an_acronym_keeps_its_case
    assert_equal "docs: README setup steps", M.subject(task(type: "docs", title: "README setup steps"))
  end

  def test_a_title_that_repeats_the_type_is_not_doubled
    assert_equal "fix: prices are rounded", M.subject(task(type: "fix", title: "Fix: Prices are rounded"))
  end

  def test_the_trailer_fills_every_placeholder
    msg = build(task(type: "fix"), "Commit by {model} from vb-harness {version}. {checks} checks passed ({gates})")
    assert_equal "Commit by some-model from vb-harness 9.9.9. 2 checks passed (typecheck, build)", msg.lines.last
  end

  def test_the_plan_rejects_an_unknown_type_and_keeps_a_known_one
    assert_raises(Harness::ParseError) { task(type: "feature") }
    t = task(type: "chore")
    assert_equal "chore", t.type
    assert_equal "chore", P.parse(Harness::Plan::Plan.new(tasks: [t], questions: []).to_json_hash).tasks.first.type
  end

  def test_config_parses_the_trailer_and_rejects_unknown_placeholders
    base = { "profiles" => { "default" => { "baseUrl" => "http://127.0.0.1:8080/v1" } } }
    assert_equal M::DEFAULT_TRAILER, Harness::Config.parse(base).commit_trailer
    assert_equal "By {model}", Harness::Config.parse(base.merge("commit" => { "trailer" => "By {model}" })).commit_trailer
    err = assert_raises(Harness::ParseError) { Harness::Config.parse(base.merge("commit" => { "trailer" => "{token}" })) }
    assert_match(/commit\.trailer/, err.message)
    assert_raises(Harness::ParseError) { Harness::Config.parse(base.merge("commit" => { "author" => "x" })) }
  end
end
