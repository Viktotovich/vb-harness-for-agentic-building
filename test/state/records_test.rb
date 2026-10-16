# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

class StateFilesTest < Minitest::Test
  S = Harness::State

  def setup
    @dir = Dir.mktmpdir("harness-state-files-")
    @path = File.join(@dir, "run.json")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_a_passing_eacces_is_retried
    pauses = []
    calls = 0
    value = S.sharing_safe(sleeper: ->(s) { pauses << s }) do
      calls += 1
      raise Errno::EACCES, "run.json" if calls < 3

      "read"
    end
    assert_equal ["read", 3, [S::SHARING_PAUSE] * 2], [value, calls, pauses]
  end

  def test_a_lasting_eacces_still_raises
    calls = 0
    assert_raises(Errno::EACCES) { S.sharing_safe(sleeper: ->(_) {}) { (calls += 1) && raise(Errno::EACCES, "run.json") } }
    assert_equal S::SHARING_RETRIES + 1, calls
  end

  def test_a_missing_file_raises_at_once_but_one_mid_rename_is_waited_for
    pauses = []
    assert_raises(Errno::ENOENT) { S.read_json(@path, sleeper: ->(s) { pauses << s }) }
    assert_empty pauses, "nothing is being written, so there is nothing to wait for"

    File.write("#{@path}.tmp", '{"status":"done"}')
    renamer = ->(_) { File.rename("#{@path}.tmp", @path) }
    assert_equal({ "status" => "done" }, S.read_json(@path, sleeper: renamer))
  end

  # The real race: on Windows a reader and a renaming writer each hit EACCES now and then.
  def test_reads_and_atomic_writes_of_one_file_never_fail_together
    S.write_json(@path, { "i" => 0 })
    errors = Queue.new
    writer = Thread.new do
      1.upto(1500) { |i| S.write_json(@path, { "i" => i, "pad" => "x" * 2000 }) }
    rescue StandardError => e
      errors << e
    end
    while writer.alive?
      begin
        S.read_json(@path)
      rescue StandardError => e
        errors << e
      end
    end
    writer.join
    assert_empty Array.new(errors.size) { errors.pop }.map { |e| "#{e.class}: #{e.message}" }
    assert_equal 1500, S.read_json(@path)["i"]
  end
end
