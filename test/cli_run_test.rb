# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# harness run --from-plan through the CLI, with the real probe against a fake server.

require_relative "test_helper"
require_relative "support/run_fixture"
require "json"
require "tmpdir"

class CliRunTest < Minitest::Test
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer

  def setup
    @tmp = Dir.mktmpdir("harness-cli-run-")
    @repo, @git_env = TestSupport.repo(@tmp, F::FILES)
    plans = 0
    task = F.task("T1", "Double the price", modify: ["src/lib/price.ts"])
    @server = Fake.new do |body, _n|
      user = body["messages"].last["content"]
      if body["messages"].first["content"].start_with?("You plan")
        plans += 1
        questions = plans == 1 ? [{ "text" => "Which currency?", "blocking" => true }] : []
        Fake.ok(JSON.generate({ "tasks" => [task], "questions" => questions }))
      elsif user.include?("T1: Double the price")
        Fake.ok(JSON.generate({ "edits" => [{ "op" => "replace", "path" => "src/lib/price.ts", "search" => "  return n;",
                                              "replace" => "  return n * 2;" }] }))
      else
        Fake.ok("OK") # probe requests: no JSON mode, no tools, no thinking control
      end
    end
    @home = File.join(@tmp, "home")
    FileUtils.mkdir_p(@home)
    config = { "profiles" => { "default" => { "baseUrl" => @server.base_url } },
               "gateEnvAllow" => %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM],
               "stacks" => { "astro" => { "detect" => ["astro.config.mjs"],
                                          "gates" => { "typecheck" => { "argv" => [RbConfig.ruby, "tools/typecheck.rb"], "parser" => "astro_check" } },
                                          "alwaysGates" => ["typecheck"] } } }
    @config_path = File.join(@home, "config.json")
    File.write(@config_path, JSON.generate(config))
    @plan_path = File.join(@home, "plan.json")
    File.write(@plan_path, JSON.generate({ "tasks" => [F.task("T1", "Double the price", modify: ["src/lib/price.ts"])] }))
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@tmp)
  end

  def cli(*args)
    out = TestSupport::Sink.new
    err = TestSupport::Sink.new
    code = Harness::CLI.run(args, out: out, err: err, env: ENV.to_h.merge(@git_env))
    [code, out.string, err.string]
  end

  def test_run_from_plan_commits_on_the_run_branch
    code, out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", @config_path, "--json")
    assert_equal 0, code, err
    result = JSON.parse(out)
    assert_equal "done", result["tasks"].first["status"]
    assert_match(%r{\Aharness/r\d{8}-\d{6}-\h{4}\z}, result["branch"])
    run_dir = File.join(@home, "runs", result["run"])
    assert File.exist?(File.join(run_dir, "events.jsonl"))
    assert File.exist?(File.join(run_dir, "plan.json"))
    refute_empty Dir.glob(File.join(run_dir, "records", "*.json"))
    refute_empty Dir.glob(File.join(@home, ".cache", "probe", "*.json")), "the probe ran and was cached"
    assert_match(/action=model\.T1\.implement outcome=ok/, err, "progress lines go to stderr")
  end

  def test_errors_exit_with_code_2
    assert_equal 2, cli("run", "--from-plan", @plan_path, "--config", @config_path)[0], "missing --repo"
    code, _out, err = cli("run", "--repo", @repo, "--config", @config_path)
    assert_equal 2, code
    assert_match(/give --request, --from-plan, or both/, err)
    assert_equal 2, cli("resume", "--config", @config_path)[0], "resume needs a RUN_ID"
    code, _out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", File.join(@home, "missing.json"))
    assert_equal 2, code
    assert_match(/not found/, err)
    File.write(File.join(@repo, "dirty.txt"), "x")
    code, _out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", @config_path)
    assert_equal 2, code
    assert_match(/uncommitted changes/, err)
  end

  # A field run had to choose: --from-plan lost the request, which the implementer and reviewers use for exact
  # values. Both can be given; the plan runs as written and the request is kept.
  def test_a_plan_and_its_request_can_be_given_together
    request = File.join(@home, "request.md")
    File.write(request, "Double the price. The factor is exactly 2.")
    code, out, err = cli("run", "--repo", @repo, "--request", request, "--from-plan", @plan_path, "--config", @config_path, "--json")
    assert_equal 0, code, err
    run = JSON.parse(out)
    assert_equal "done", run["status"]
    assert_equal 0, @server.chat_bodies.count { |b| b["messages"].first["content"].start_with?("You plan") }, "the planner is not asked"
    implement = @server.chat_bodies.find { |b| b["messages"].last["content"].include?("T1: Double the price") }
    assert_includes implement["messages"].last["content"], "The factor is exactly 2."
  end

  # The dryRun key was parsed and then ignored. A dry run now runs intake, the baseline gates and the plan checks,
  # calls no model, and leaves no worktree.
  def test_a_dry_run_checks_everything_but_calls_no_model
    code, out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", @config_path, "--dry-run", "--json")
    assert_equal 0, code, err
    found = JSON.parse(out)
    assert_equal ["dry_run", 0], found.values_at("status", "exitCode")
    assert_equal "astro", found.dig("dryRun", "stack")
    assert_equal [%w[typecheck passed]], found.dig("dryRun", "gates").map { |g| g.values_at("gate", "status") }
    assert_equal "run the plan's 1 task(s)", found.dig("dryRun", "next")
    assert_empty @server.requests, "no model server request at all, not even the probe"
    run = JSON.parse(File.read(File.join(@home, "runs", found["run"], "run.json")))
    refute File.exist?(run["worktree"]), "the worktree is removed"

    code, out, = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", @config_path, "--dry-run")
    assert_equal 0, code
    assert_match(/: dry_run\n  stack: astro, base \h{12} \(no model was called\)\n  gate typecheck  passed\n  next, a real run would run the plan's 1 task\(s\)\n/, out)
    code, _out, err = cli("resume", found["run"], "--config", @config_path)
    assert_equal 2, code
    assert_match(/was a dry run and has no worktree/, err)

    bad = File.join(@home, "bad-plan.json")
    File.write(bad, JSON.generate({ "tasks" => [F.task("T1", "Edit a missing file", modify: ["src/nope.ts"])] }))
    code, out, = cli("run", "--repo", @repo, "--from-plan", bad, "--config", @config_path, "--dry-run", "--json")
    assert_equal [1, "plan.missing_path"], [code, JSON.parse(out)["issues"].first["reason"]], "plan problems show without a model"

    request = File.join(@home, "request.md")
    File.write(request, "Double the price.")
    File.write(@config_path, JSON.generate(JSON.parse(File.read(@config_path)).merge("dryRun" => true)))
    code, out, = cli("run", "--repo", @repo, "--request", request, "--config", @config_path, "--json")
    assert_equal [0, "dry_run", "plan the request with the model"], [code, JSON.parse(out)["status"], JSON.parse(out).dig("dryRun", "next")],
                 "\"dryRun\": true in the config makes run a dry run"
    assert_empty @server.requests
  end

  def test_review_can_be_set_on_the_command_line
    code, out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", @config_path, "--review", "off", "--json")
    assert_equal 0, code, err
    assert_equal "done", JSON.parse(out)["status"]
    reviews = @server.chat_bodies.count { |b| F::REVIEW_ROLES.any? { |o, _| b["messages"].first["content"].start_with?(o) } }
    assert_equal 0, reviews, "--review off makes no review calls"
    code, _out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", @config_path, "--review", "some")
    assert_equal 2, code
    assert_match(/invalid argument: --review some/, err)
  end

  # A field run: planning failed and --json printed nothing at all. It now prints the result with the reason.
  def test_a_planning_failure_prints_a_json_result_with_the_reason
    @server.stop
    @server = Fake.new { |body, _n| body["messages"].first["content"].start_with?("You plan") ? Fake.ok("not json") : Fake.ok("OK") }
    config = JSON.parse(File.read(@config_path))
    config["profiles"]["default"]["baseUrl"] = @server.base_url
    File.write(@config_path, JSON.generate(config))
    request = File.join(@home, "request.md")
    File.write(request, "Make prices double.")
    code, out, = cli("run", "--repo", @repo, "--request", request, "--config", @config_path, "--json")
    assert_equal 1, code
    result = JSON.parse(out)
    assert_equal "failed", result["status"]
    assert_match(/\Aplanning failed: /, result["error"])
  end

  def test_request_question_answer_build_through_the_cli
    request = File.join(@home, "request.md")
    File.write(request, "Make prices double.")
    code, out, = cli("run", "--repo", @repo, "--request", request, "--config", @config_path, "--json")
    assert_equal 3, code, "waiting on the user's answers"
    waiting = JSON.parse(out)
    assert_equal ["Which currency?"], waiting["questions"]

    answers = File.join(@home, "answers.json")
    File.write(answers, JSON.generate(["USD"]))
    code, out, err = cli("answer", waiting["run"], "--answers", answers, "--config", @config_path)
    assert_equal 0, code, err
    assert_match(/T1\s+done\s+commit \h{7}/, out)

    code, out, = cli("resume", waiting["run"], "--config", @config_path, "--json")
    assert_equal [0, "done"], [code, JSON.parse(out)["tasks"].first["status"]], "resuming a finished run changes nothing"
  end

  # A field run crashed after its prompts were edited mid-run. Each run now records what produced it, and answer
  # and resume stop when the harness version or the prompts changed, unless the change is accepted.
  def test_answer_and_resume_stop_when_what_produced_the_run_changed
    request = File.join(@home, "request.md")
    File.write(request, "Make prices double.")
    _, out, = cli("run", "--repo", @repo, "--request", request, "--config", @config_path, "--json")
    run_id = JSON.parse(out)["run"]
    run_json = File.join(@home, "runs", run_id, "run.json")
    identity = JSON.parse(File.read(run_json))["identity"]
    assert_equal [Harness::VERSION, Harness::State::Identity.prompts_digest], identity.values_at("harnessVersion", "prompts")
    assert_match(/\A\h{16}\z/, identity["config"])

    File.write(run_json, JSON.generate(JSON.parse(File.read(run_json)).tap { |r| r["identity"]["prompts"] = "0000000000000000" }))
    answers = File.join(@home, "answers.json")
    File.write(answers, JSON.generate(["USD"]))
    code, _out, err = cli("answer", run_id, "--answers", answers, "--config", @config_path)
    assert_equal 2, code
    assert_match(/the prompt files \(0000000000000000 then, \h{16} now\) changed since this run started/, err)
    assert_match(/pass --accept-changes to continue anyway/, err)
    assert_equal "waiting", JSON.parse(File.read(run_json))["status"], "nothing changed"

    code, _out, err = cli("answer", run_id, "--answers", answers, "--config", @config_path, "--accept-changes")
    assert_equal 0, code, err
    events = Harness::State::Events.read(File.join(@home, "runs", run_id, "events.jsonl"))
    assert(events.any? { |e| e["subject"] == "identity" && e["detail"].match?(/\Athe prompt files \(.+\) changed; continuing \(--accept-changes\)\z/) })
    assert_equal Harness::State::Identity.prompts_digest, JSON.parse(File.read(run_json)).dig("identity", "prompts"), "the identity is updated"

    File.write(run_json, JSON.generate(JSON.parse(File.read(run_json)).tap { |r| r["identity"]["harnessVersion"] = "0.0.1" }))
    code, _out, err = cli("resume", run_id, "--config", @config_path)
    assert_equal 2, code
    assert_match(/the harness version \(0\.0\.1 then, #{Regexp.escape(Harness::VERSION)} now\) changed/, err)

    File.write(run_json, JSON.generate(JSON.parse(File.read(run_json)).tap { |r| r["identity"]["harnessVersion"] = Harness::VERSION }))
    cfg = JSON.parse(File.read(@config_path))
    cfg["profiles"]["default"]["timeoutSec"] = 1200
    File.write(@config_path, JSON.generate(cfg))
    code, _out, err = cli("resume", run_id, "--config", @config_path, "--review", "off")
    assert_equal 0, code, "a changed config only warns: #{err}"
    events = Harness::State::Events.read(File.join(@home, "runs", run_id, "events.jsonl"))
    assert(events.any? { |e| e["subject"] == "identity" && e["detail"].start_with?("the config changed") })
  end

  def test_answers_can_be_typed_on_stdin
    request = File.join(@home, "request.md")
    File.write(request, "Make prices double.")
    _, out, = cli("run", "--repo", @repo, "--request", request, "--config", @config_path, "--json")
    run_id = JSON.parse(out)["run"]
    input = Struct.new(:lines) { def gets = lines.shift }.new(["USD\n"])
    err = TestSupport::Sink.new
    code = Harness::CLI.run(["answer", run_id, "--config", @config_path], out: TestSupport::Sink.new, err: err,
                                                                          env: ENV.to_h.merge(@git_env), input: input)
    assert_equal 0, code, err.string
    assert_includes err.string, "Q: Which currency?"
  end
end
