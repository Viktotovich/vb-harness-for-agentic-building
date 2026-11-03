# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Steering a running agent: notes reach it between turns, once; its question waits for the user's answer; the
# CLI and the app write the notes.

require_relative "../test_helper"
require_relative "../support/run_fixture"
require "json"
require "tmpdir"

class AgentSteeringTest < Minitest::Test
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer
  TASK_AGENT = "You are a careful software engineer"

  def setup
    @tmp = Dir.mktmpdir("harness-agent-steer-")
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def store(id = "r1")
    s = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: id)
    s.write_run({ "status" => "running", "mode" => "agent" })
    s
  end

  def events(s) = Harness::State::Events.new(path: s.events_path, run_id: s.run_id)

  def test_notes_reach_the_agent_once_and_a_question_waits_for_an_answer
    s = store
    notes = Harness::State::Notes.new(s.dir)
    notes.add("Use the existing Button component.")
    answered = false
    sleeper = lambda do |_|
      notes.add("Info, the default.") unless answered
      answered = true
    end
    box = Harness::Agent::Mailbox.new(store: s, events: events(s), task_id: "T1", timeout: 5, sleeper: sleeper)
    assert_equal ["Use the existing Button component."], box.fresh
    assert_empty box.fresh, "a note is delivered once"
    assert_equal "The user answered: Info, the default.", box.ask("Which tone should the badge use by default?")
    assert_nil s.read_run["agentQuestion"], "the question is cleared once answered"
    assert_equal 2, s.read_run["notesRead"]
    kinds = Harness::State::Events.read(s.events_path).map { |e| [e["kind"], e["subject"]] }
    assert_includes kinds, ["question", "agent question"]
    assert_includes kinds, ["accepted", "note from the user"]

    quiet = Harness::Agent::Mailbox.new(store: s, events: events(s), task_id: "T1", timeout: 2, sleeper: ->(_) {})
    assert_match(/\ANo answer came within 2 seconds\. Decide yourself/, quiet.ask("Anything?"))
    assert_nil Harness::Agent::Mailbox.new(store: s, events: events(s), task_id: "T1", timeout: 0).asker, "askTimeoutSec 0 turns asking off"
    assert_raises(Harness::ParseError) { notes.add("   ") }

    many = Harness::State::Notes.new(File.join(@tmp, "many")).tap { FileUtils.mkdir_p(File.join(@tmp, "many")) }
    8.times.map { |i| Thread.new { many.add("note #{i}") } }.each(&:join)
    assert_equal (1..8).to_a, many.read.map { |n| n["seq"] }.sort, "notes sent at once never share a number"
  end

  def call(name, args, id = "c1")
    { "id" => id, "type" => "function", "function" => { "name" => name, "arguments" => JSON.generate(args) } }
  end

  # The agent asks; the user answers with a note while the run waits; the answer and a steering note both reach it.
  def test_the_agent_asks_and_gets_the_users_answer_mid_task
    script = [
      Fake.ok("", tool_calls: [call("ask_user", { "question" => "Double, or triple?" })]),
      Fake.ok("", tool_calls: [call("edit_file", { "path" => "src/lib/price.ts", "search" => "  return n;", "replace" => "  return n * 2;" })]),
      Fake.ok("", tool_calls: [call("finish", { "summary" => "Doubled, as answered." })])
    ]
    seen = 0
    @server = Fake.new do |body, _n|
      if body["messages"].first["content"].start_with?(TASK_AGENT)
        seen += 1
        script[seen - 1] || Fake.ok("", tool_calls: [call("finish", { "summary" => "done" })])
      else F::NO_FINDINGS
      end
    end
    repo, env = TestSupport.repo(@tmp, F::FILES)
    config = F.config(@server.base_url, review: "off", top: { "mode" => "agent", "agent" => { "askTimeoutSec" => 30 } })
    s = Harness::State::RunStore.new(runs_dir: File.join(@tmp, "runs"), run_id: "r2")
    setup = Harness::Run.intake(config: config, repo: repo, store: s, parent_env: ENV.to_h.merge(env))
    s.update_run({ "mode" => "agent" })
    answerer = Thread.new do
      200.times do
        q = s.read_run["agentQuestion"]
        if q
          Harness::State::Notes.new(s.dir).add("Double.")
          break
        end
        sleep 0.1
      end
    end
    outcome = Harness::Run.new(config: config, client: F.client(config, s), setup: setup)
                          .execute(Harness::Plan::PlanParser.parse({ "tasks" => [F.task("T1", "Change the price", modify: ["src/lib/price.ts"])] }))
    answerer.join
    assert_equal "done", outcome.tasks.first.status
    answer_turn = @server.chat_bodies.find { |b| b["messages"].any? { |m| m["role"] == "tool" && m["content"].to_s.include?("The user answered: Double.") } }
    assert answer_turn, "the answer came back as the ask_user result"
  end

  def test_steer_writes_a_note_and_says_what_it_answers
    home = File.join(@tmp, "home")
    s = Harness::State::RunStore.new(runs_dir: File.join(home, "runs"), run_id: "r20261103-100000-abcd")
    s.write_run({ "status" => "running", "mode" => "agent", "agentQuestion" => { "task" => "T1", "text" => "Double, or triple?" } })
    out = TestSupport::Sink.new
    err = TestSupport::Sink.new
    code = Harness::CLI.run(["steer", s.run_id, "Double", "it.", "--config", File.join(home, "config.json")], out: out, err: err)
    assert_equal 0, code, err.string
    assert_equal "note 1 answers the agent's question (T1): Double, or triple?\n", out.string
    assert_equal ["Double it."], Harness::State::Notes.new(s.dir).read.map { |n| n["text"] }
    s.write_run({ "status" => "done", "mode" => "pipeline" })
    err = TestSupport::Sink.new
    Harness::CLI.run(["steer", s.run_id, "late", "--config", File.join(home, "config.json")], out: TestSupport::Sink.new, err: err)
    assert_match(/run r20261103-100000-abcd is done and not in agent mode; only a running agent-mode run reads notes/, err.string)
    assert_equal 2, Harness::CLI.run(["steer", "r20261103-100000-ffff", "x", "--config", File.join(home, "config.json")], out: out, err: TestSupport::Sink.new)
    assert_equal 2, Harness::CLI.run(["steer", s.run_id], out: out, err: TestSupport::Sink.new), "a note needs text"
  end
end
