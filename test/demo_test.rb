# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# harness demo: the real pipeline on a bundled project, answered by a scripted model on 127.0.0.1.

require_relative "test_helper"
require "json"
require "tmpdir"

class DemoTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("hd-")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_the_demo_runs_a_whole_build_with_a_fix_round_and_marks_its_report
    out = TestSupport::Sink.new
    err = TestSupport::Sink.new
    code = Harness::CLI.run(["demo", "--config", File.join(@tmp, "config.json"), "--json"], out: out, err: err, env: ENV.to_h)
    assert_equal 0, code, err.string
    result = JSON.parse(out.string)
    assert_equal "done", result["status"]
    run = JSON.parse(File.read(File.join(@tmp, "demo", "runs", result["run"], "run.json")))
    assert run["demo"]
    t1 = JSON.parse(File.read(File.join(@tmp, "demo", "runs", result["run"], "tasks", "T1", "state.json")))
    assert_equal 1, t1["fixRounds"], "the scripted first edit fails the check and the fix passes"
    report = File.read(result["report"])
    assert_includes report, "- **Demo:** a scripted model answered, not a real one."
    assert_match(/\| T2 \| Add total\(\) with tax \| done \|/, report)
    refute File.exist?(File.join(@tmp, "config.json")), "the demo has its own config in demo/"
    assert File.file?(File.join(@tmp, "demo", "config.json"))
    assert_includes err.string, "no real model runs"
  end

  def test_the_scripted_model_answers_each_step_and_only_that
    server = Harness::Demo::Server.new
    plan = JSON.parse(server.reply({ "messages" => [{ "content" => "You plan a feature" }, { "content" => "x" }] }))
    assert_equal %w[T1 T2], plan["tasks"].map { |t| t["id"] }
    fix = JSON.parse(server.reply({ "messages" => [{ "content" => "You fix a change" }, { "content" => "T1: Double the price" }] }))
    assert_equal "  return n * 2;", fix["edits"].first["replace"]
    assert_equal "OK", server.reply({ "messages" => [{ "content" => "Say OK" }] }), "the capability probe gets plain text"
    assert_match(%r{\Ahttp://127\.0\.0\.1:\d+/v1\z}, server.base_url, "only on this machine")
  ensure
    server&.stop
  end
end
