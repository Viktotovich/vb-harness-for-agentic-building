# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Port of the REVIEWER lock behaviour: one process per run, stale locks taken over.

require_relative "../test_helper"
require "json"
require "tmpdir"

class LockTest < Minitest::Test
  L = Harness::State::Lock

  def setup
    @dir = Dir.mktmpdir("harness-lock-")
    @path = File.join(@dir, "run", "harness.lock")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_acquire_and_release
    release = L.acquire(@path)
    refute_nil release
    assert_equal Process.pid, JSON.parse(File.read(@path))["pid"]
    assert_nil L.acquire(@path), "a live holder keeps the lock"
    release.call
    refute File.exist?(@path)
    refute_nil L.acquire(@path)
  end

  def test_a_lock_whose_process_is_gone_is_taken_over
    L.acquire(@path, pid: 999_999)
    refute_nil L.acquire(@path, alive: ->(pid) { pid != 999_999 })
  end

  def test_an_old_lock_is_stale
    L.acquire(@path)
    later = -> { Time.now + L::STALE_SEC + 60 }
    refute_nil L.acquire(@path, alive: ->(_) { true }, now: later)
  end

  def test_an_unreadable_lock_is_judged_by_age
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "garbage")
    assert_nil L.acquire(@path)
    refute_nil L.acquire(@path, now: -> { Time.now + L::STALE_SEC + 60 })
  end

  def test_alive_checks_a_real_process
    assert L.alive?(Process.pid)
    refute L.alive?(4_194_000 + rand(1000))
  end
end
