# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Agent mode end to end against a scripted model that calls tools: the task agent investigates, edits, runs the
# checks, and is sent back by the harness when its finish was premature (I7). The investigating agent's findings
# reach the planner, fenced.

require_relative "../test_helper"
require_relative "../support/run_fixture"
require "json"
require "tmpdir"

class AgentModeTest < Minitest::Test
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer
  TASK_AGENT = "You are a careful software engineer"
  INVESTIGATOR = "You investigate a code repository"

  def setup
    @tmp = Dir.mktmpdir("harness-agent-mode-")
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def call(name, args, id = "c1")
    { "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }
  end

  # The scripted task agent: reads, makes an edit that breaks the check, finishes anyway; when the harness sends
  # it back with the failure, it fixes the edit, runs the check and finishes again.
  def task_agent_script
    [
      Fake.ok("", tool_calls: [call("read_file", { "path" => "src/lib/price.ts" })]),
      Fake.ok("", tool_calls: [call("edit_file", { "path" => "src/lib/price.ts", "search" => "  return n;", "replace" => "  return n * 2; // BROKEN 4" })]),
      Fake.ok("", tool_calls: [call("finish", { "summary" => "Doubled the price." })]),
      Fake.ok("", tool_calls: [call("edit_file", { "path" => "src/lib/price.ts", "search" => "  return n * 2; // BROKEN 4", "replace" => "  return n * 2;" })]),
      Fake.ok("", tool_calls: [call("run_gate", { "name" => "typecheck" })]),
      Fake.ok("", tool_calls: [call("finish", { "summary" => "Doubled the price; the type check passes." })])
    ]
  end

  def server(investigation: [], plan: nil)
    script = { TASK_AGENT => task_agent_script, INVESTIGATOR => investigation }
    seen = Hash.new(0)
    @plans = []
    @server = Fake.new do |body, _n|
      system = body["messages"].first["content"]
      key = script.keys.find { |k| system.start_with?(k) }
      if key
        reply = script[key][seen[key]] || Fake.ok("", tool_calls: [call("finish", { "summary" => "done" })])
        seen[key] += 1
        reply
      elsif system.start_with?("You plan")
        @plans << body["messages"].last["content"]
        Fake.ok(JSON.generate(plan))
      elsif system.start_with?("You summarize") then Fake.ok("A source file.")
      else F::NO_FINDINGS
      end
    end
  end

  def test_a_premature_finish_is_sent_back_and_only_passing_gates_complete_the_task
    server
    repo, env = TestSupport.repo(@tmp, F::FILES)
    config = F.config(@server.base_url, review: "off", top: { "mode" => "agent" })
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "r1")
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    outcome = Harness::Run.new(config: config, client: F.client(config, store), setup: setup)
                          .execute(Harness::Plan::PlanParser.parse({ "tasks" => [F.task("T1", "Double the price", modify: ["src/lib/price.ts"])] }))
    t1 = outcome.tasks.first
    assert_equal ["done", 1], [t1.status, t1.fix_rounds], "the harness's own gate run sent the agent back once"
    assert_includes File.read(File.join(setup.worktree.root, "src/lib/price.ts")), "  return n * 2;\n"
    refute_includes File.read(File.join(setup.worktree.root, "src/lib/price.ts")), "BROKEN"
    events = Harness::State::Events.read(store.events_path)
    subjects = events.map { |e| [e["stage"], e["kind"], e["subject"].to_s[0, 14]] }
    assert_includes subjects, ["task.gather", "accepted", "read_file: src"]
    assert_includes subjects, ["task.apply", "accepted", "edit_file: src"]
    assert(events.any? { |e| e["stage"] == "task.gates" && e["subject"].to_s.start_with?("run_gate") }, "the agent ran the check itself")
    assert(events.any? { |e| e["stage"] == "task.fix" && e["kind"] == "stage_started" })
    sent_back = @server.chat_bodies.find { |b| b["messages"].last["content"].to_s.include?("The harness ran the task's checks and they fail") }
    assert sent_back, "the failure went back to the same conversation"
    assert_operator sent_back["messages"].size, :>, 4, "with the history the agent had built"
  end

  def test_an_agent_that_never_finishes_blocks_the_task
    @server = Fake.new do |body, _n|
      system = body["messages"].first["content"]
      if system.start_with?(TASK_AGENT) then Fake.ok("", tool_calls: [call("list_dir", { "path" => "." })])
      else F::NO_FINDINGS
      end
    end
    repo, env = TestSupport.repo(@tmp, F::FILES)
    config = F.config(@server.base_url, review: "off", top: { "mode" => "agent", "agent" => { "maxSteps" => 3 } })
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "r2")
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    outcome = Harness::Run.new(config: config, client: F.client(config, store), setup: setup)
                          .execute(Harness::Plan::PlanParser.parse({ "tasks" => [F.task("T1", "Double the price", modify: ["src/lib/price.ts"])] }))
    assert_equal %w[blocked agent.steps_exhausted], [outcome.tasks.first.status, outcome.tasks.first.reason]
    assert_equal "the agent ran out of steps before finishing", Harness::State::Reasons.text("agent.steps_exhausted")
  end

  # Models without native tool calls work by a JSON reply protocol, one tool per reply, and never see tools.
  def test_a_model_without_tool_calls_uses_the_json_protocol
    replies = [Fake.ok(JSON.generate({ "tool" => "list_dir", "args" => { "path" => "." } })),
               Fake.ok(JSON.generate({ "tool" => "finish", "args" => { "summary" => "Looked around." } }))]
    @server = Fake.new(replies: replies)
    config = F.config(@server.base_url, top: { "mode" => "agent" })
    root = File.join(@tmp, "wt")
    FileUtils.mkdir_p(File.join(root, "src"))
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "r3")
    client = Harness::Model::Client.new(config: config, probe: ->(_) { Harness::Model::Probe::Result.new(**TestSupport::CAPS.merge(tool_calls: "none")) },
                                        http: Harness::Model::Http.new, records: Harness::State::Records.new(store.records_dir), env: {}, sleeper: ->(_) {})
    toolbox = Harness::Agent::Toolbox.new(root: root, protected: [], stack: config.stacks["astro"], settings: config.agent)
    session = Harness::Agent::Session.new(client: client, role: :planner, system: "You look.", toolbox: toolbox, label: "t")
    result = session.run("Look at the repository.", max_steps: 5)
    assert_equal ["Looked around.", 2, false], [result.finished, result.steps, result.exhausted]
    bodies = @server.chat_bodies
    assert(bodies.none? { |b| b.key?("tools") }, "no tools offered to a model that cannot call them")
    assert_includes bodies.first["messages"].first["content"], "Reply with only one JSON object per message"
    assert_match(/\AResult of list_dir:\n<untrusted-data/, bodies.last["messages"].last["content"])
  end

  def test_the_investigation_reaches_the_planner_fenced
    plan = { "tasks" => [F.task("T1", "Double the price", modify: ["src/lib/price.ts"])], "questions" => [] }
    investigation = [Fake.ok("", tool_calls: [call("list_dir", { "path" => "src" })]),
                     Fake.ok("", tool_calls: [call("finish", { "summary" => "price() lives in src/lib/price.ts and returns n unchanged." })])]
    server(investigation: investigation, plan: plan)
    setup = F.pipeline(@tmp, {}, top: { "mode" => "agent" })
    setup.server.stop
    pipeline = Harness::Pipeline.new(config: F.config(@server.base_url, top: { "mode" => "agent" }), home: File.join(@tmp, "home"), env: ENV.to_h.merge(setup.env),
                                     client_factory: ->(store) { F.client(F.config(@server.base_url, top: { "mode" => "agent" }), store) })
    result = pipeline.start(repo: setup.repo, request: "Make prices double.", plan_only: true)
    assert_equal "planned", result.status
    prompt = @plans.first
    assert_match(/What an agent found by reading this repository before planning.*\n<untrusted-data id="\h+">\nprice\(\) lives in src\/lib\/price\.ts/m, prompt)
    saved = File.join(File.join(@tmp, "home", "runs", result.run_id), "investigation.md")
    assert_equal "price() lives in src/lib/price.ts and returns n unchanged.", File.read(saved)
    events = Harness::State::Events.read(File.join(@tmp, "home", "runs", result.run_id, "events.jsonl"))
    assert(events.any? { |e| e["stage"] == "map" && e["subject"].to_s.start_with?("list_dir") })
  end
end
