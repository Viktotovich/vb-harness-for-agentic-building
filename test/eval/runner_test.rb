# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# M7 acceptance (DESIGN.md 13): an eval table produced for two different profile mappings, here two fake model
# servers, one that solves the task and one that does not.

require_relative "../test_helper"
require_relative "../support/review_run"
require "json"
require "tmpdir"

class EvalRunnerTest < Minitest::Test
  RR = TestSupport::ReviewRun
  F = TestSupport::RunFixture
  PRICE = "src/lib/price.ts"
  TASK = F.task("T1", "Double the price", modify: [PRICE])

  def setup
    @tmp = Dir.mktmpdir("harness-eval-")
    @repo, @git_env = TestSupport.repo(@tmp, RR::FILES)
    @env = ENV.to_h.merge(@git_env).merge("EVAL_REPO" => @repo)
    @good = F.server({ "plan" => F.plan_reply([TASK]), "T1 implement" => F.replace(PRICE, "  return n;", "  return n * 2;") })
    broken = F.replace(PRICE, "  return n;", "  return n * 3; // BROKEN 9")
    @weak = F.server({ "plan" => F.plan_reply([TASK]), "T1 implement" => broken, "T1 fix" => F.replace(PRICE, "BROKEN 9", "BROKEN 9") })
    @tasks = File.join(@tmp, "tasks")
    write_task("01-double", "$EVAL_REPO\nHEAD\n", "expect_includes src/lib/price.ts n * 2\n")
    write_task("02-pinned", "${EVAL_REPO}\n#{TestSupport.git!(@repo, @git_env, 'rev-parse', 'HEAD').strip[0, 10]}\n",
               "expect_includes src/lib/price.ts return n * 2;\n")
    File.write(File.join(@tmp, "config.json"), JSON.generate(RR.raw_config(@good.base_url)))
    File.write(File.join(@tmp, "map.json"), JSON.generate({
                                                            "good" => {},
                                                            "weak" => { "profiles" => { "weak" => { "baseUrl" => @weak.base_url, "maxOutputTokens" => 1000, "timeoutSec" => 30 } },
                                                                        "roles" => Harness::Model::ROLES.to_h { |r| [r.to_s, "weak"] } }
                                                          }))
  end

  def teardown
    [@good, @weak].each(&:stop)
    FileUtils.rm_rf(@tmp)
  end

  def write_task(id, ref, hidden)
    dir = File.join(@tasks, id)
    FileUtils.mkdir_p(File.join(dir, "hidden", "tests", "hidden"))
    File.write(File.join(dir, "request.md"), "Double the price.\n")
    File.write(File.join(dir, "repo.ref"), "# the prepared repository\n#{ref}")
    File.write(File.join(dir, "hidden", "tests", "hidden", "#{id}.test.txt"), hidden)
  end

  def eval_cli(*args)
    out = TestSupport::Sink.new
    err = TestSupport::Sink.new
    factory = lambda do |config, home|
      Harness::Pipeline.new(config: config, home: home, env: @env, client_factory: ->(store) { F.client(config, store) })
    end
    code = Harness::CLI::EvalCommand.call(["--config", File.join(@tmp, "config.json"), "--tasks", File.join(@tasks, "*"), *args],
                                          out: out, err: err, env: @env, pipeline_for: factory)
    [code, out.string, err.string]
  end

  def test_a_table_per_profile_mapping
    code, out, err = eval_cli("--profile-map", File.join(@tmp, "map.json"))
    assert_equal 0, code, err
    good = out[/## Mapping: good\n(.*?)(?=## Mapping|\z)/m, 1]
    weak = out[/## Mapping: weak\n(.*?)(?=## Mapping|\z)/m, 1]
    assert_match(/^\| 01-double \| yes \| yes \| 0 \| 0\/0 \| 0 \| \d+ \| \d+s \|  \|$/, good)
    assert_match(/^\| 02-pinned \| yes \| yes \|/, good)
    assert_match(/^\| \*\*all\*\* \| 2\/2 \| 2\/2 \| 0 \| - \| 0 \|/, good)
    assert_match(/^\| 01-double \| no \| no \| 0 \| 0\/0 \| 1 \| \d+ \| \d+s \| hidden tests failed \|$/, weak)
    assert_match(/^\| \*\*all\*\* \| 0\/2 \| 0\/2 \|/, weak)
    assert_match(/^\| implementer \| \d+ \| \d+s \|$/, good)
    assert_empty TestSupport.git!(@repo, @git_env, "status", "--porcelain"), "the prepared repository stays clean"
    refute(Dir.exist?(File.join(@tmp, ".harness-worktrees")) && !Dir.empty?(File.join(@tmp, ".harness-worktrees")), "worktrees are removed")
    assert_equal 2, Dir.children(File.join(@tmp, "eval-out", "weak", "runs")).size
  end

  def test_json_scores_and_a_pinned_commit_that_moved
    File.write(File.join(@tasks, "02-pinned", "repo.ref"), "$EVAL_REPO\n0000000000\n")
    code, out, = eval_cli("--json")
    assert_equal 1, code, "a task that could not run makes the exit code 1"
    scores = JSON.parse(out)["config"]
    assert_equal [["01-double", true], ["02-pinned", false]], scores.map { |s| [s["task"], s["solved"]] }
    assert_match(/repo\.ref pins 0000000000/, scores[1]["note"])
  end

  def test_remote_refs_and_unset_variables_are_refused
    File.write(File.join(@tasks, "01-double", "repo.ref"), "https://example.com/repo.git\nHEAD\n")
    code, _out, err = eval_cli
    assert_equal 2, code
    assert_match(/is a remote; clone it yourself/, err)
    File.write(File.join(@tasks, "01-double", "repo.ref"), "$NOT_SET_ANYWHERE\nHEAD\n")
    _code, _out, err = eval_cli
    assert_match(/set NOT_SET_ANYWHERE to the prepared repository/, err)
  end

  def test_the_shipped_tasks_load
    tasks = Harness::Eval::Runner.load_tasks(File.join(TestSupport::ROOT, "eval", "tasks", "*"), root: File.join(TestSupport::ROOT, "eval"),
                                                                                                 env: { "HARNESS_EVAL_ASTRO" => "/path/to/astro-mini" })
    assert_equal 10, tasks.size
    assert(tasks.all? { |t| t.hidden.size == 1 && t.hidden.first.start_with?("tests/hidden/") && t.commit == "HEAD" })
    assert(tasks.all? { |t| t.request.size > 80 })
  end
end
