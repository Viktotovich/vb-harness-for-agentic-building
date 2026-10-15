# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Log, records, tokens and SHA-256.

require_relative "test_helper"
require "fileutils"
require "json"
require "tmpdir"

class SupportLibsTest < Minitest::Test
  def test_log_line_format_and_daily_file
    Dir.mktmpdir do |dir|
      t = Time.new(2026, 10, 15, 12, 4, 37, "+00:00")
      log = Harness::Log.new(dir: dir, clock: -> { t })
      line = log.write(action: "task.apply", outcome: "rejected", detail: "line one\nline \"two\"", run: "r7", task: "T2")
      assert_equal "2026-10-15T12:04:37.000Z run=r7 task=T2 action=task.apply outcome=rejected detail=\"line one line 'two'\"", line
      assert_equal "#{line}\n", File.read(File.join(dir, "#{t.strftime('%Y-%m-%d')}.log"))
    end
  end

  def test_log_redacts_token_shaped_text_and_caps_detail
    secret = "Bearer #{'q' * 24}"
    assert_equal "auth [REDACTED]", Harness::Log.redact("auth #{secret}")
    Dir.mktmpdir do |dir|
      line = Harness::Log.new(dir: dir).write(action: "a", outcome: "o", detail: "x" * 1000)
      assert_equal 400, line[/detail="(x*)"/, 1].size
    end
  end

  def test_records_are_numbered_atomic_json
    Dir.mktmpdir do |dir|
      rec = Harness::State::Records.new(dir)
      a = rec.write(role: "planner", label: "plan/check 1", outcome: "ok")
      b = rec.write(role: "implementer", label: "T1", outcome: "ok")
      assert_equal %w[0001-planner-plan_check_1.json 0002-implementer-T1.json], [a, b].map { |p| File.basename(p) }
      assert_equal({ "role" => "planner", "label" => "plan/check 1", "outcome" => "ok" }, JSON.parse(File.read(a)))
      assert_empty Dir.glob(File.join(dir, "*.tmp"))
      assert_raises(ArgumentError) { rec.write(api_key: "x") }
    end
  end

  def test_token_estimates_are_pessimistic
    assert_equal 0, Harness::Model::Tokens.estimate("")
    assert_equal 4, Harness::Model::Tokens.estimate("a" * 12)
    assert_equal 8 + 1 + 1, Harness::Model::Tokens.estimate_messages([{ "content" => "abc" }, { "content" => "d" }])
    assert_equal(-1, Harness::Model::Tokens.budget(context: 100, prompt: 61, reserved: 40))
  end

  def test_sha256_matches_known_vectors_with_and_without_digest
    vectors = {
      "" => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "abc" => "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" =>
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    }
    vectors.each do |input, hex|
      assert_equal hex, Harness::Sha256.pure_hex(input)
      assert_equal hex, Harness::Sha256.hex(input)
    end
    long = "é" * 5000
    assert_equal Harness::Sha256.hex(long), Harness::Sha256.pure_hex(long)
  end
end
