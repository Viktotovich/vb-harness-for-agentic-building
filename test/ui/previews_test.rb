# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Preview: the stack's dev server command with a free port, one per project or build, a few at most, all stopped
# with the app. A fake starter stands in for Exec.start.

require_relative "../test_helper"

class UIPreviewsTest < Minitest::Test
  # A process that stays "alive" until stopped.
  class FakeProcess
    attr_reader :argv, :chdir

    def initialize(argv, chdir)
      @argv = argv
      @chdir = chdir
      @alive = true
    end

    def alive? = @alive
    def output = "ready in 120 ms\n"
    def stop = @alive = false
  end

  def setup
    @started = []
    @ports = [5001, 5002, 5003, 5004].each
    @previews = Harness::UI::Previews.new(
      starter: ->(argv, chdir:, env:) { FakeProcess.new(argv, chdir).tap { |p| @started << [p, env] } },
      free_port: -> { @ports.next }
    )
  end

  def test_one_preview_per_key_with_the_port_filled_in
    argv = %w[npx astro dev --host 127.0.0.1 --port {port}]
    a = @previews.start("project:site", argv: argv, chdir: "/p/site", env: { "PATH" => "x" }, label: "site")
    assert_equal ["project:site", "http://127.0.0.1:5001/", true], a.values_at("key", "url", "alive")
    assert_equal %w[npx astro dev --host 127.0.0.1 --port 5001], @started.first[0].argv
    assert_equal "/p/site", @started.first[0].chdir
    again = @previews.start("project:site", argv: argv, chdir: "/p/site", env: {}, label: "site")
    assert_equal a["url"], again["url"], "asking again reuses the running one"
    assert_equal 1, @started.size

    @previews.start("run:r1", argv: argv, chdir: "/w/r1", env: {}, label: "build r1")
    @previews.start("run:r2", argv: argv, chdir: "/w/r2", env: {}, label: "build r2")
    assert_raises(Harness::ConfigError) { @previews.start("run:r3", argv: argv, chdir: "/w/r3", env: {}, label: "r3") }
    assert @previews.stop("run:r1")
    refute @previews.stop("run:r1")
    assert_equal %w[project:site run:r2], @previews.list.map { |p| p["key"] }

    @previews.stop_all
    assert_empty @previews.list
    assert(@started.all? { |p, _| !p.alive? }, "every dev server stops with the app")
  end
end
