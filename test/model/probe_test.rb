# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require_relative "../support/fake_llm_server"
require "fileutils"
require "tmpdir"

class ProbeTest < Minitest::Test
  Fake = TestSupport::FakeLlmServer
  M = Harness::Model

  TOOL_CALL = { "id" => "1", "type" => "function",
                "function" => { "name" => "record_value", "arguments" => '{"value":42}' } }.freeze

  # A configurable fake: which response formats it honours, whether it calls tools, how it thinks,
  # and what it says about an oversize prompt.
  def fake(schema: true, object: true, tools: true, thinking: nil, overflow: nil, models: [{ "id" => "test-model" }])
    Fake.new(models: models) do |body, _n|
      prompt = body["messages"].last["content"]
      fmt = body.dig("response_format", "type")
      if prompt.start_with?("x x x")
        overflow ? Fake.error(400, overflow) : Fake.ok("fine")
      elsif fmt == "json_schema"
        schema ? Fake.ok('{"yes":true}') : Fake.error(400, "response_format json_schema is not supported")
      elsif fmt == "json_object"
        object ? Fake.ok('{ "yes": true }') : Fake.error(400, "response_format is not supported")
      elsif body["tools"]
        tools ? Fake.ok(nil, finish: "tool_calls", tool_calls: [TOOL_CALL]) : Fake.ok("I would call it with 42.")
      elsif prompt == "Reply with OK"
        thinking_reply(body, thinking)
      else
        reply = Fake.ok("1 2 3", usage: { "prompt_tokens" => 1000, "completion_tokens" => 100 })
        reply[1]["timings"] = { "prompt_per_second" => 812.5, "predicted_per_second" => 21.3 }
        reply
      end
    end.tap { |s| @servers << s }
  end

  # thinking: nil (never thinks), or the control that turns it off ("chat_template_kwargs" / "reasoning_effort").
  def thinking_reply(body, thinking)
    off = thinking && M::Wire::THINKING_OFF[thinking].all? { |k, v| body[k] == v }
    return Fake.ok("OK", usage: { "completion_tokens" => 2 }) if thinking.nil? || off

    Fake.ok("OK", usage: { "completion_tokens" => 350 }, reasoning_content: "Let me think about how to say OK...")
  end

  def setup
    @dir = Dir.mktmpdir("harness-probe-")
    @servers = []
  end

  def teardown
    @servers.each(&:stop)
    FileUtils.rm_rf(@dir)
  end

  def probe_for(srv, refresh: false, **profile)
    config = TestSupport.config(srv.base_url, **profile)
    probe = M::Probe.new(http: M::Http.new, cache_dir: File.join(@dir, ".cache"), env: {}, timeout: 10)
    probe.call(config.profiles["default"], refresh: refresh)
  end

  # --- structured output ---

  def test_picks_json_schema_when_the_server_enforces_it
    assert_equal "json_schema", probe_for(fake).structured_output
  end

  def test_falls_back_to_json_object
    assert_equal "json_object", probe_for(fake(schema: false)).structured_output
  end

  def test_falls_back_to_prompt
    assert_equal "prompt", probe_for(fake(schema: false, object: false)).structured_output
  end

  def test_a_server_that_ignores_response_format_is_not_json_schema
    srv = Fake.new { |body, _n| body["response_format"] ? Fake.ok("Yes, water is wet.") : Fake.ok("OK") }
    @servers << srv
    assert_equal "prompt", probe_for(srv).structured_output
  end

  # --- tools and thinking ---

  def test_tool_calls_native_or_none
    assert_equal "native", probe_for(fake).tool_calls
    assert_equal "none", probe_for(fake(tools: false, models: [{ "id" => "other" }])).tool_calls
  end

  def test_thinking_control_is_the_one_that_shortens_the_answer
    r = probe_for(fake(thinking: "chat_template_kwargs"))
    assert_equal "chat_template_kwargs", r.thinking_control
    assert_equal "separate", r.reasoning
    r = probe_for(fake(thinking: "reasoning_effort", models: [{ "id" => "m2" }]))
    assert_equal "reasoning_effort", r.thinking_control
  end

  def test_a_model_that_never_thinks_gets_no_thinking_control
    r = probe_for(fake)
    assert_equal "none", r.thinking_control
    assert_equal "none", r.reasoning
  end

  # --- context ---

  def test_context_from_the_models_listing
    [{ "meta" => { "n_ctx" => 32_768 } }, { "context_length" => 8000 }, { "max_model_len" => 65_536 }].each_with_index do |meta, i|
      r = probe_for(fake(models: [{ "id" => "m#{i}" }.merge(meta)]))
      assert_equal meta.values.first.is_a?(Hash) ? 32_768 : meta.values.first, r.context_tokens
      assert_equal "models", r.context_source
    end
  end

  def test_context_from_the_overflow_error
    r = probe_for(fake(overflow: "prompt (400000 tokens) + max tokens (1) exceeds the context (12288)"))
    assert_equal [12_288, "overflow"], [r.context_tokens, r.context_source]
  end

  def test_context_defaults_to_8192
    r = probe_for(fake)
    assert_equal [8192, "default"], [r.context_tokens, r.context_source]
  end

  def test_throughput_from_server_timings
    r = probe_for(fake)
    assert_equal [812.5, 21.3], [r.prompt_tps, r.gen_tps]
  end

  # --- model choice, overrides, cache ---

  def test_auto_picks_the_first_model_and_a_named_model_must_be_listed
    srv = fake(models: [{ "id" => "first" }, { "id" => "second" }])
    assert_equal "first", probe_for(srv).model_id
    assert_equal "second", probe_for(srv, model: "second").model_id
    assert_raises(Harness::ModelUnavailableError) { probe_for(srv, model: "missing") }
  end

  def test_profile_values_override_the_probe
    r = probe_for(fake, contextTokens: 4096, structuredOutput: "prompt", toolCalls: "none",
                        thinking: { "control" => "reasoning_effort" })
    assert_equal [4096, "profile"], [r.context_tokens, r.context_source]
    assert_equal %w[prompt none reasoning_effort], [r.structured_output, r.tool_calls, r.thinking_control]
  end

  def test_results_are_cached_per_server_and_model_metadata
    srv = fake
    first = probe_for(srv)
    chats = srv.chat_bodies.size
    assert_equal first, probe_for(srv)
    assert_equal chats, srv.chat_bodies.size, "a cached probe sends no chat requests"
    probe_for(srv, refresh: true)
    assert_operator srv.chat_bodies.size, :>, chats
    assert_equal 1, Dir.glob(File.join(@dir, ".cache", "probe", "*.json")).size
  end

  def test_changed_model_metadata_invalidates_the_cache
    probe_for(fake(models: [{ "id" => "m", "context_length" => 4096 }]))
    r = probe_for(fake(models: [{ "id" => "m", "context_length" => 8192 }]))
    assert_equal 8192, r.context_tokens
    assert_equal 2, Dir.glob(File.join(@dir, ".cache", "probe", "*.json")).size
  end

  def test_a_corrupt_cache_file_is_reprobed
    srv = fake
    probe_for(srv)
    File.write(Dir.glob(File.join(@dir, ".cache", "probe", "*.json")).first, '{"modelId": 3}')
    assert_equal "test-model", probe_for(srv).model_id
  end

  def test_unreachable_server_is_unavailable
    holder = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{holder.addr[1]}/v1"
    holder.close
    probe = M::Probe.new(http: M::Http.new(open_timeout: 2), cache_dir: File.join(@dir, ".cache"), env: {})
    assert_raises(Harness::ModelUnavailableError) { probe.call(TestSupport.config(url).profiles["default"]) }
  end

  def test_describe_in_plain_words
    r = M::Probe::Result.new(**TestSupport::CAPS, structured_output: "json_object", tool_calls: "none")
    assert_equal "16K context, JSON mode: yes, tools: no, thinking can be turned off", r.describe
  end
end
