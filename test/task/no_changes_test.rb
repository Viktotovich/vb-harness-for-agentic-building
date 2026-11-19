# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# A planned task that changes nothing is not done (a field run committed one as done after its agent could not delete
# the file it was asked to remove), and a task can delete the files it declares, in both modes.

require_relative "../test_helper"
require_relative "../support/run_fixture"
require "json"
require "tmpdir"

class NoChangesTest < Minitest::Test
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer
  PRICE = "src/lib/price.ts"
  TAX = "src/lib/tax.ts"
  TASK_AGENT = "You are a careful software engineer"

  def setup
    @tmp = Dir.mktmpdir("harness-no-changes-")
  end

  def teardown
    @r&.server&.stop
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def same = F.replace(PRICE, "  return n;", "  return n;")
  def double = F.replace(PRICE, "  return n;", "  return n * 2;")

  def events
    Harness::State::Events.read(@r.store.events_path)
  end

  def log
    TestSupport.git!(@r.outcome.worktree, @r.env, "log", "--format=%s")
  end

  # --- pipeline mode ---

  def test_an_empty_diff_gets_a_fix_round_and_then_blocks_with_a_plain_reason
    @r = F.run(@tmp, { "tasks" => [F.task("T1", "Double", modify: [PRICE])] }, { "T1 implement" => same, "T1 fix" => same }, review: "off")
    t1 = @r.outcome.tasks.first
    assert_equal ["blocked", "task.no_changes", 1], [t1.status, t1.reason, t1.fix_rounds]
    assert_nil t1.commit
    assert_equal 1, @r.outcome.exit_code
    assert_match(/the task made no changes to src\/lib\/price\.ts, even after a round that asked for them/, t1.detail)
    assert_equal "the task made no changes", Harness::State::Reasons.text("task.no_changes")
    refute_includes log, "T1: Double"
    fix = @r.server.chat_bodies.find { |b| b["messages"].first["content"].start_with?("You fix") }
    assert fix, "the empty diff went to a fix round"
    assert_includes fix["messages"].last["content"], "the task made no changes: none of its files (src/lib/price.ts) differ"
    rejected = events.select { |e| e["reason"] == "task.no_changes" }
    assert_equal [%w[task.apply rejected], %w[task.apply rejected], %w[task.commit blocked]], rejected.map { |e| [e["stage"], e["kind"]] }
    assert_includes Harness::Report::Render.markdown(@r.store), "Double (it made no changes)"
  end

  def test_an_empty_diff_that_the_fix_round_fills_is_done
    @r = F.run(@tmp, { "tasks" => [F.task("T1", "Double", modify: [PRICE])] }, { "T1 implement" => same, "T1 fix" => double }, review: "off")
    t1 = @r.outcome.tasks.first
    assert_equal ["done", 1], [t1.status, t1.fix_rounds]
    refute_nil t1.commit
    assert_includes log, "T1: Double"
  end

  # A fixer that undoes a broken change leaves nothing; with its last round used, the task is blocked at once.
  def test_a_fix_that_reverts_everything_with_no_round_left_blocks_at_once
    repo, env = TestSupport.repo(@tmp, F::FILES)
    @server = F.server({ "T1 implement" => F.replace(PRICE, "  return n;", "  return n; // BROKEN 3"),
                         "T1 fix" => F.replace(PRICE, "  return n; // BROKEN 3", "  return n;") })
    config = F.config(@server.base_url, review: "off", top: { "maxFixRounds" => 1 })
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "r1")
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    t1 = Harness::Run.new(config: config, client: F.client(config, store), setup: setup)
                     .execute(Harness::Plan::PlanParser.parse({ "tasks" => [F.task("T1", "Double", modify: [PRICE])] })).tasks.first
    assert_equal ["blocked", "task.no_changes", 1], [t1.status, t1.reason, t1.fix_rounds]
    assert_match(/no round was left/, t1.detail)
  end

  def test_a_pipeline_task_deletes_a_file_it_lists_under_delete
    task = { "id" => "T1", "title" => "Remove the tax", "intent" => "Remove the tax module.", "files" => { "delete" => [TAX] },
             "acceptance" => [{ "kind" => "gate", "gate" => "typecheck" }] }
    reply = Fake.ok(JSON.generate({ "edits" => [{ "op" => "delete", "path" => TAX }], "notes" => "removed" }))
    @r = F.run(@tmp, { "tasks" => [task] }, { "T1 implement" => reply }, review: "off")
    t1 = @r.outcome.tasks.first
    assert_equal "done", t1.status, t1.detail
    refute File.exist?(File.join(@r.outcome.worktree, TAX))
    assert_includes TestSupport.git!(@r.outcome.worktree, @r.env, "show", "--name-status", "--format=", "HEAD"), "D\t#{TAX}"
    implement = @r.server.chat_bodies.find { |b| b["messages"].first["content"].include?("Delete these files") }
    assert implement, "the implementer is told which files to delete"
  end

  # --- agent mode ---

  def call(name, args) = { "id" => "c1", "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }

  def agent_run(script, task)
    seen = 0
    @server = Fake.new do |body, _n|
      if body["messages"].first["content"].start_with?(TASK_AGENT)
        reply = script[seen] || script.last
        seen += 1
        reply
      else F::NO_FINDINGS
      end
    end
    repo, env = TestSupport.repo(@tmp, F::FILES)
    config = F.config(@server.base_url, review: "off", top: { "mode" => "agent" })
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "a1")
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    outcome = Harness::Run.new(config: config, client: F.client(config, store), setup: setup)
                          .execute(Harness::Plan::PlanParser.parse({ "tasks" => [task] }))
    [outcome.tasks.first, setup, env]
  end

  def delete_task
    { "id" => "T1", "title" => "Remove the tax", "intent" => "Remove the tax module.", "files" => { "delete" => [TAX] },
      "acceptance" => [{ "kind" => "gate", "gate" => "typecheck" }] }
  end

  def finish = Fake.ok("", tool_calls: [call("finish", { "summary" => "Done." })])

  def test_an_agent_deletes_a_file_its_task_lists
    t1, setup, env = agent_run([Fake.ok("", tool_calls: [call("delete_file", { "path" => TAX })]), finish], delete_task)
    assert_equal "done", t1.status, t1.detail
    refute File.exist?(File.join(setup.worktree.root, TAX))
    assert_includes TestSupport.git!(setup.worktree.root, env, "show", "--name-status", "--format=", "HEAD"), "D\t#{TAX}"
    tools = @server.chat_bodies.first["tools"].to_a.map { |d| d.dig("function", "name") }
    assert_includes tools, "delete_file"
    assert_includes @server.chat_bodies.first["messages"].first["content"], "The task removes these files: #{TAX}"
  end

  def test_an_agent_that_changes_nothing_is_told_once_and_then_blocked
    t1, setup, env = agent_run([finish], delete_task)
    assert_equal %w[blocked task.no_changes], [t1.status, t1.reason]
    assert File.exist?(File.join(setup.worktree.root, TAX))
    refute_includes TestSupport.git!(setup.worktree.root, env, "log", "--format=%s"), "T1: Remove the tax"
    told = @server.chat_bodies.select { |b| b["messages"].last["content"].to_s.include?("The harness found no changes") }
    assert_equal 1, told.size, "one round that says why"
    assert_includes told.first["messages"].last["content"], "delete_file removes a file"
  end

  def test_an_agent_told_about_its_empty_diff_can_still_finish_the_task
    script = [finish, Fake.ok("", tool_calls: [call("delete_file", { "path" => TAX })]), finish]
    t1, setup, = agent_run(script, delete_task)
    assert_equal ["done", 1], [t1.status, t1.fix_rounds]
    refute File.exist?(File.join(setup.worktree.root, TAX))
  end
end
