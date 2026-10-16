# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

class UIBuildsTest < Minitest::Test
  # A pipeline that gets as far as "running" and then raises, like a bug deep in a task.
  class CrashingPipeline
    def initialize(runs_dir)
      @runs_dir = runs_dir
    end

    def start(run_id:, **)
      Harness::State::RunStore.new(runs_dir: @runs_dir, run_id: run_id).write_run({ "status" => "running" })
      raise ArgumentError, "comparison of Array with Array failed"
    end
  end

  def setup
    @tmp = Dir.mktmpdir("harness-builds-")
    @runs = File.join(@tmp, "runs")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def test_a_run_whose_thread_raises_is_marked_failed_not_left_running
    builds = Harness::UI::Builds.new(runs_dir: @runs, pipeline: -> { CrashingPipeline.new(@runs) })
    id = builds.start(request: "build it", repo: @tmp)
    store = Harness::State::RunStore.new(runs_dir: @runs, run_id: id)
    deadline = Time.now + 5
    sleep 0.02 until store.read_run["status"] == "failed" || Time.now > deadline

    run = store.read_run
    assert_equal ["failed", 1, "comparison of Array with Array failed"], run.values_at("status", "exitCode", "error")
    event = Harness::State::Events.read(store.events_path).last
    assert_equal %w[report rejected harness.crashed], event.values_at("stage", "kind", "reason")
    assert_equal "the harness stopped on an internal error", Harness::State::Reasons.text("harness.crashed")
  end
end
