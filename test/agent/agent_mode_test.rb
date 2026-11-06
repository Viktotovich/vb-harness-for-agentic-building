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

  def run_with(id, agent: {})
    repo, env = TestSupport.repo(@tmp, F::FILES)
    config = F.config(@server.base_url, review: "off", top: { "mode" => "agent", "agent" => agent })
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: id)
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    outcome = Harness::Run.new(config: config, client: F.client(config, store), setup: setup)
                          .execute(Harness::Plan::PlanParser.parse({ "tasks" => [F.task("T1", "Double the price", modify: ["src/lib/price.ts"])] }))
    [outcome.tasks.first, setup, store]
  end

  def recovery_events(store)
    Harness::State::Events.read(store.events_path).select { |e| e["kind"] == "retried" && e["subject"].to_s.start_with?("recovery") }
  end

  # An agent that says it is done in plain text, ignoring the nudge; only a new conversation gets it to finish.
  def test_an_agent_that_stops_without_finishing_gets_a_new_conversation_with_its_progress
    @server = Fake.new do |body, _n|
      system = body["messages"].first["content"]
      next F::NO_FINDINGS unless system.start_with?(TASK_AGENT)

      fresh = body["messages"].any? { |m| m["content"].to_s.start_with?("An earlier attempt") }
      edited = body["messages"].any? { |m| m["role"] == "tool" }
      if !fresh && !edited then Fake.ok("", tool_calls: [call("edit_file", { "path" => "src/lib/price.ts", "search" => "  return n;", "replace" => "  return n * 2;" })])
      elsif !fresh then Fake.ok("All done, the price is doubled.")
      else Fake.ok("", tool_calls: [call("finish", { "summary" => "Doubled the price." })])
      end
    end
    t1, setup, store = run_with("r-rec1")
    assert_equal "done", t1.status
    assert_includes File.read(File.join(setup.worktree.root, "src/lib/price.ts")), "  return n * 2;\n"
    assert_equal ["recovery: fresh start"], recovery_events(store).map { |e| e["subject"] }
    resumed = @server.chat_bodies.find { |b| b["messages"].last["content"].to_s.start_with?("An earlier attempt") }
    assert_equal %w[system user], resumed["messages"].map { |m| m["role"] }, "the stalled conversation is left behind"
    text = resumed["messages"].last["content"]
    assert_includes text, "It stopped calling tools without calling finish."
    assert_includes text, "Files it changed: src/lib/price.ts"
    assert_includes text, "return n * 2;"
    assert_includes text, "All done, the price is doubled."
  end

  def test_each_recovery_differs_and_the_block_says_what_was_tried
    @server = Fake.new do |body, _n|
      body["messages"].first["content"].start_with?(TASK_AGENT) ? Fake.ok("", tool_calls: [call("list_dir", { "path" => "." })]) : F::NO_FINDINGS
    end
    t1, _setup, store = run_with("r-rec2", agent: { "maxSteps" => 4 })
    assert_equal %w[blocked agent.steps_exhausted], [t1.status, t1.reason]
    assert_includes t1.detail, "also tried: fresh start, narrower task"
    assert_equal ["recovery: fresh start", "recovery: narrower task"], recovery_events(store).map { |e| e["subject"] }
    prompts = @server.chat_bodies.map { |b| b["messages"].find { |m| m["role"] == "user" }["content"] }.uniq.select { |t| t.start_with?("An earlier attempt") }
    assert_equal 2, prompts.size
    refute_includes prompts[0], "ran the task's checks just now"
    assert_includes prompts[1], "ran the task's checks just now"
    assert_includes prompts[1], "Do only what these results and the task still need."
    asked = @server.chat_bodies.count { |b| b["messages"].first["content"].start_with?(TASK_AGENT) }
    assert_equal 4 + 4 + 2, asked, "the narrower try gets half the steps"
  end

  def test_max_recoveries_zero_blocks_at_once
    @server = Fake.new do |body, _n|
      body["messages"].first["content"].start_with?(TASK_AGENT) ? Fake.ok("", tool_calls: [call("list_dir", { "path" => "." })]) : F::NO_FINDINGS
    end
    t1, _setup, store = run_with("r-rec3", agent: { "maxSteps" => 2, "maxRecoveries" => 0 })
    assert_equal %w[blocked agent.steps_exhausted], [t1.status, t1.reason]
    refute_includes t1.detail, "also tried"
    assert_empty recovery_events(store)
  end

  def test_the_ladder_offers_a_stronger_model_only_when_one_is_configured
    names = lambda do |ladder|
      out = []
      while (rung = ladder.next)
        out << [rung.name, rung.role]
      end
      out
    end
    plain = [["fresh start", :implementer], ["narrower task", :implementer]]
    assert_equal plain, names.call(Harness::Agent::Ladder.new(max: 3, stronger: false))
    assert_equal plain + [["stronger model", :rescuer]], names.call(Harness::Agent::Ladder.new(max: 3, stronger: true))
    assert_equal plain.first(1), names.call(Harness::Agent::Ladder.new(max: 1, stronger: true))
  end

  TESTER = "You write acceptance tests"
  CHECK = "test/price.test.ts"

  # A stack with a test gate that fails until price.ts doubles, and a plan that asks for a test.
  def acceptance_run(id, gate_script, agent: {})
    repo, env = TestSupport.repo(@tmp, F::FILES.merge("tools/unit.rb" => gate_script))
    gates = { "unit" => { "argv" => [RbConfig.ruby, "tools/unit.rb", "{tests}"], "scope" => "tests", "parser" => "vitest", "costRank" => 5 } }
    config = F.config(@server.base_url, review: "off", extra_gates: gates, top: { "mode" => "agent", "agent" => { "acceptanceTests" => true }.merge(agent) })
    store = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: id)
    store.write_request("Double the price.")
    setup = Harness::Run.intake(config: config, repo: repo, store: store, parent_env: ENV.to_h.merge(env))
    task = F.task("T1", "Double the price", modify: ["src/lib/price.ts"]).merge(
      "acceptance" => [{ "kind" => "test", "path" => CHECK, "write" => true, "describe" => "doubles" }]
    )
    outcome = Harness::Run.new(config: config, client: F.client(config, store), setup: setup)
                          .execute(Harness::Plan::PlanParser.parse({ "tasks" => [task] }))
    [outcome.tasks.first, setup, store]
  end

  PASSES_WHEN_DOUBLED = <<~RUBY
    exit(0) if ARGV.empty?
    code = File.read("src/lib/price.ts")
    test = File.read(ARGV.first.to_s) rescue ""
    exit(code.include?("n * 2") && test.include?("expect") ? 0 : 1)
  RUBY

  def scripted(tester:, agent:)
    seen = Hash.new(0)
    @server = Fake.new do |body, _n|
      system = body["messages"].first["content"]
      list = if system.start_with?(TESTER) then tester
             elsif system.start_with?(TASK_AGENT) then agent
             end
      next F::NO_FINDINGS unless list

      reply = list[seen[list.object_id]] || Fake.ok("", tool_calls: [call("finish", { "summary" => "done" })])
      seen[list.object_id] += 1
      reply
    end
  end

  def write_test = Fake.ok("", tool_calls: [call("write_file", { "path" => CHECK, "content" => "expect(price(2)).toBe(4);\n" })])
  def double_it = Fake.ok("", tool_calls: [call("edit_file", { "path" => "src/lib/price.ts", "search" => "  return n;", "replace" => "  return n * 2;" })])
  def finish(text = "Done.") = Fake.ok("", tool_calls: [call("finish", { "summary" => text })])

  def test_the_acceptance_test_is_written_first_and_the_implementer_cannot_change_it
    weaken = Fake.ok("", tool_calls: [call("write_file", { "path" => CHECK, "content" => "weakened\n" })])
    scripted(tester: [write_test, finish("Checks the doubled price.")], agent: [weaken, double_it, finish])
    t1, setup, = acceptance_run("r-acc1", PASSES_WHEN_DOUBLED)
    assert_equal "done", t1.status
    assert_equal "expect(price(2)).toBe(4);\n", File.read(File.join(setup.worktree.root, CHECK))
    agent = @server.chat_bodies.select { |b| b["messages"].first["content"].start_with?(TASK_AGENT) }
    assert_includes agent.first["messages"].first["content"], "was written from the request before your work"
    refute_includes agent.first["messages"].first["content"], "Write the test for this task exactly"
    refused = agent[1]["messages"].find { |m| m["role"] == "tool" }["content"]
    assert_includes refused, "an existing test"
    order = @server.chat_bodies.map { |b| b["messages"].first["content"] }
    assert_operator order.index { |s| s.start_with?(TESTER) }, :<, order.index { |s| s.start_with?(TASK_AGENT) }, "the test comes first"
  end

  def test_the_test_writer_can_write_only_the_test
    sneak = Fake.ok("", tool_calls: [call("edit_file", { "path" => "src/lib/price.ts", "search" => "  return n;", "replace" => "  return 4;" })])
    scripted(tester: [sneak, write_test, finish], agent: [double_it, finish])
    t1, setup, = acceptance_run("r-acc2", PASSES_WHEN_DOUBLED)
    assert_equal "done", t1.status
    refute_includes File.read(File.join(setup.worktree.root, "src/lib/price.ts")), "return 4"
    tool = @server.chat_bodies.filter_map { |b| b["messages"].find { |m| m["role"] == "tool" } }.first
    assert_includes tool["content"], "may be changed here"
  end

  def test_a_test_writer_that_fails_leaves_the_test_to_the_implementer
    own = Fake.ok("", tool_calls: [call("write_file", { "path" => CHECK, "content" => "expect(1);\n" })])
    scripted(tester: Array.new(40) { Fake.ok("I cannot do this.") }, agent: [double_it, own, finish])
    t1, _setup, store = acceptance_run("r-acc3", PASSES_WHEN_DOUBLED)
    assert_equal "done", t1.status
    assert(Harness::State::Events.read(store.events_path).any? { |e| e["reason"] == "agent.no_acceptance_test" })
    agent = @server.chat_bodies.find { |b| b["messages"].first["content"].start_with?(TASK_AGENT) }
    assert_includes agent["messages"].first["content"], "Write the test for this task exactly at #{CHECK}"
  end

  def test_work_that_passes_its_acceptance_test_is_done_without_finish
    scripted(tester: [write_test, finish], agent: [double_it, Fake.ok("It is done."), Fake.ok("It is done.")])
    t1, _setup, store = acceptance_run("r-acc4", PASSES_WHEN_DOUBLED)
    assert_equal "done", t1.status
    events = Harness::State::Events.read(store.events_path)
    assert(events.any? { |e| e["subject"].to_s.start_with?("passed its acceptance test") })
    assert_empty recovery_events(store)
  end

  def test_stopped_work_that_fails_its_acceptance_test_goes_to_the_ladder
    scripted(tester: [write_test, finish], agent: [Fake.ok("It is done."), Fake.ok("It is done."), double_it, finish])
    t1, _setup, store = acceptance_run("r-acc5", PASSES_WHEN_DOUBLED)
    assert_equal "done", t1.status
    assert_equal ["recovery: fresh start"], recovery_events(store).map { |e| e["subject"] }
  end

  WANTS_CORRECTED = <<~RUBY
    exit(0) if ARGV.empty?
    test = File.read(ARGV.first.to_s) rescue ""
    exit(test.include?("corrected") ? 0 : 1)
  RUBY

  def test_a_failing_acceptance_test_gets_one_review_and_may_be_corrected
    fixed = Fake.ok("", tool_calls: [call("write_file", { "path" => CHECK, "content" => "corrected\n" })])
    scripted(tester: [write_test, finish, fixed, finish("It loaded the code the wrong way.")], agent: [double_it, finish, finish, finish, finish])
    t1, setup, store = acceptance_run("r-acc6", WANTS_CORRECTED, agent: { "maxRounds" => 2 })
    assert_equal "done", t1.status
    assert_equal "corrected\n", File.read(File.join(setup.worktree.root, CHECK))
    assert(Harness::State::Events.read(store.events_path).any? { |e| e["subject"] == "acceptance test corrected" })
    review = @server.chat_bodies.find { |b| b["messages"].last["content"].to_s.include?("Decide whether the test is at fault") }
    assert_includes review["messages"].last["content"], "A value, name or text that the request states stays in the test exactly"
  end

  def test_a_right_acceptance_test_is_kept_and_blocks_wrong_work
    scripted(tester: [write_test, finish, finish("The test is right.")], agent: Array.new(8) { finish })
    t1, _setup, store = acceptance_run("r-acc7", PASSES_WHEN_DOUBLED, agent: { "maxRounds" => 2 })
    assert_equal %w[blocked agent.rounds_exhausted], [t1.status, t1.reason]
    assert_equal 1, Harness::State::Events.read(store.events_path).count { |e| e["subject"] == "acceptance test kept" }
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
