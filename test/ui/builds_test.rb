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

  # A pipeline that rewrites run.json many times, as a busy run does, then finishes.
  class BusyPipeline
    def initialize(runs_dir, writes)
      @runs_dir = runs_dir
      @writes = writes
    end

    def start(run_id:, **)
      store = Harness::State::RunStore.new(runs_dir: @runs_dir, run_id: run_id)
      @writes.times { |i| store.write_run({ "status" => "running", "step" => i, "pad" => "x" * 2000 }) }
      store.update_run({ "status" => "done", "exitCode" => 0 })
    end
  end

  # Collects what the events stream sends.
  class Recorder
    attr_reader :sent

    def initialize = @sent = []

    def event(name, data, id: nil)
      @sent << [name, data, id]
      true
    end

    def closed? = false
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

  # Regression: on Windows, reading run.json while another thread renames a new copy over it raises EACCES on either
  # side. The stream then ended with no events at all, or the run crashed. Both sides now ride out the moment.
  def test_the_stream_survives_run_json_being_rewritten_while_it_reads
    builds = Harness::UI::Builds.new(runs_dir: @runs, pipeline: -> { BusyPipeline.new(@runs, 3000) }, sleeper: ->(_) { Thread.pass })
    id = builds.start(request: "build it", repo: @tmp)
    store = Harness::State::RunStore.new(runs_dir: @runs, run_id: id)
    deadline = Time.now + 5
    Thread.pass until store.exist? || Time.now > deadline
    sse = Recorder.new

    builds.events(id, 0, sse)

    assert_equal ["end", { "status" => "done" }], sse.sent.last.first(2)
    assert_equal({ "status" => "done", "exitCode" => 0 }, store.read_run.slice("status", "exitCode"), "the writer never crashed")
    refute(sse.sent.any? { |name, _| name == "failed" })
  end
end
