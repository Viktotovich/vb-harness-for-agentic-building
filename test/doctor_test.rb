# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# harness doctor: every reason a run would not start, in one list, without a model call.

require_relative "test_helper"
require_relative "support/run_fixture"
require "json"
require "tmpdir"

class DoctorTest < Minitest::Test
  F = TestSupport::RunFixture
  Fake = TestSupport::FakeLlmServer

  def setup
    @tmp = Dir.mktmpdir("harness-doctor-")
    @server = Fake.new(models: [{ "id" => "small" }, { "id" => "large" }])
    @home = File.join(@tmp, "home")
    FileUtils.mkdir_p(@home)
    @config_path = File.join(@home, "config.json")
    # A stand-in npx, so the gate checks do not depend on Node being installed.
    @bin = File.join(@tmp, "bin")
    FileUtils.mkdir_p(@bin)
    %w[npx npx.cmd].each { |n| File.write(File.join(@bin, n), "") }
    File.chmod(0o755, File.join(@bin, "npx"))
    @path = [@bin, ENV.fetch("PATH", ENV.fetch("Path", ""))].join(File::PATH_SEPARATOR)
  end

  def teardown
    @server.stop
    FileUtils.rm_rf(@tmp)
  end

  def write_config(profile: {}, stack: {})
    stacks = { "astro" => { "detect" => ["astro.config.mjs"], "dependencyDirs" => ["node_modules"],
                            "gates" => { "typecheck" => { "argv" => [RbConfig.ruby, "tools/typecheck.rb"] },
                                         "lint" => { "argv" => %w[npx --offline --no -- eslint {files}], "scope" => "touched" },
                                         "format" => { "argv" => %w[npx --offline --no -- prettier --check {files}], "scope" => "touched", "blocking" => false } } }.merge(stack) }
    File.write(@config_path, JSON.generate({ "profiles" => { "default" => { "baseUrl" => @server.base_url }.merge(profile) },
                                             "gateEnvAllow" => %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM], "stacks" => stacks }))
  end

  def doctor(env: {}, repo: nil)
    out = TestSupport::Sink.new
    code = Harness::CLI.run(["doctor", "--config", @config_path, *(repo ? ["--repo", repo] : []), "--json"], out: out,
                            err: TestSupport::Sink.new, env: base_env.merge(env))
    [code, JSON.parse(out.string)]
  end

  def base_env = ENV.to_h.reject { |k, _| k.casecmp?("PATH") }.merge("PATH" => @path).merge(@git_env || {})

  def by_area(result, area) = result["checks"].select { |c| c["area"] == area }

  def test_a_ready_setup_lists_every_check_and_calls_no_model
    repo, @git_env = TestSupport.repo(@tmp, F::FILES.merge(".gitignore" => "node_modules/\n"))
    FileUtils.mkdir_p(File.join(repo, "node_modules", ".bin"))
    %w[eslint prettier].each { |t| File.write(File.join(repo, "node_modules", ".bin", t), "") }
    write_config
    code, result = doctor(repo: repo)
    assert_equal [0, true], [code, result["ready"]], result.inspect
    assert_equal %w[ruby git config model repository gate gate gate], result["checks"].map { |c| c["area"] }
    assert_match(/auto, 2 model\(s\) listed/, by_area(result, "model").first["detail"])
    assert_match(/git, clean, stack astro/, by_area(result, "repository").first["detail"])
    assert_equal ["typecheck: ruby found", "lint: eslint found", "format: prettier found"],
                 by_area(result, "gate").map { |c| c["detail"].sub(/ruby\S* found/, "ruby found") }
    assert(@server.requests.all? { |r| r.path.end_with?("/models") }, "only the model list is asked for")

    out = TestSupport::Sink.new
    Harness::CLI.run(["doctor", "--config", @config_path], out: out, err: TestSupport::Sink.new, env: base_env)
    assert_match(/^  ok    config     config\.json$/, out.string)
    assert_match(/^Ready \(give --repo PATH to check a repository too\)\./, out.string)
  end

  def test_every_problem_is_listed_with_what_to_do
    repo, @git_env = TestSupport.repo(@tmp, F::FILES.merge(".gitignore" => "node_modules/\n"))
    File.write(File.join(repo, "notes.txt"), "uncommitted")
    write_config(profile: { "model" => "missing-model" })
    code, result = doctor(repo: repo)
    assert_equal [2, false], [code, result["ready"]]
    model = by_area(result, "model").first
    assert_match(/missing-model is not among the server's models \(small, large\)/, model["detail"])
    assert_equal "load missing-model on the server, or choose one it lists", model["fix"]
    details = by_area(result, "repository").map { |c| c["detail"] }
    assert_equal 2, details.size, "intake's problems, all of them"
    assert_match(/uncommitted changes/, details[0])
    assert_match(/node_modules is missing/, details[1])
    refute(by_area(result, "gate").any? { |c| c["detail"].include?("eslint is not installed") }, "the missing folder is said once")

    out = TestSupport::Sink.new
    Harness::CLI.run(["doctor", "--config", @config_path, "--repo", repo], out: out, err: TestSupport::Sink.new, env: base_env)
    assert_match(/^  FIX   model      default .*\n              -> load missing-model on the server/, out.string)
    assert_match(/^Not ready: 3 problems to fix\.$/, out.string)
  end

  def test_a_missing_tool_a_missing_key_and_a_missing_config
    repo, @git_env = TestSupport.repo(@tmp, F::FILES.merge(".gitignore" => "node_modules/\n"))
    FileUtils.mkdir_p(File.join(repo, "node_modules", ".bin"))
    File.write(File.join(repo, "node_modules", ".bin", "eslint"), "")
    write_config(profile: { "apiKeyEnv" => "DOCTOR_TEST_KEY" })
    code, result = doctor(repo: repo, env: { "DOCTOR_TEST_KEY" => "" })
    assert_equal 2, code
    assert_equal "default (planner, implementer, fixer, reviewer, verifier, summarizer): DOCTOR_TEST_KEY is not set",
                 by_area(result, "model").first["detail"]
    format = by_area(result, "gate").find { |c| c["detail"].start_with?("format") }
    assert_equal [true, "format: prettier is not installed in the project"], format.values_at("ok", "detail"),
                 "a gate that does not block is reported, not counted as a problem"
    _, result = doctor(repo: repo, env: { "DOCTOR_TEST_KEY" => "secret-value" })
    refute_includes JSON.generate(result), "secret-value", "I12: a key never reaches the output"
    assert_equal "Bearer secret-value", @server.requests.last.headers["authorization"]

    File.delete(@config_path)
    code, result = doctor
    assert_equal 2, code
    assert_equal ["config", false, "run `harness init`, or fix the file"], by_area(result, "config").first.values_at("area", "ok", "fix")
    assert_equal %w[ruby git config], result["checks"].map { |c| c["area"] }, "nothing that needs a config runs without one"
  end
end
