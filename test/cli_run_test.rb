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
    code, _out, err = cli("run", "--repo", @repo, "--request", @plan_path, "--from-plan", @plan_path, "--config", @config_path)
    assert_equal 2, code
    assert_match(/exactly one of --request and --from-plan/, err)
    assert_equal 2, cli("resume", "--config", @config_path)[0], "resume needs a RUN_ID"
    code, _out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", File.join(@home, "missing.json"))
    assert_equal 2, code
    assert_match(/not found/, err)
    File.write(File.join(@repo, "dirty.txt"), "x")
    code, _out, err = cli("run", "--repo", @repo, "--from-plan", @plan_path, "--config", @config_path)
    assert_equal 2, code
    assert_match(/uncommitted changes/, err)
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
