# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# The robust caller's recovery paths, against a fake OpenAI-compatible server
# (port of REVIEWER test/llm.test.js and test/overflow.test.js).

require_relative "../test_helper"
require_relative "../support/fake_llm_server"
require "fileutils"
require "tmpdir"

class ClientTest < Minitest::Test
  Fake = TestSupport::FakeLlmServer
  M = Harness::Model

  INCOMPLETE = Fake.error(502, "structured output was incomplete (finish_reason=length); increase the output budget")
  BAD_JSON = Fake.error(502, "model did not return valid JSON: Expecting ',' delimiter")

  def setup
    @dir = Dir.mktmpdir("harness-client-")
    @servers = []
  end

  def teardown
    @servers.each(&:stop)
    FileUtils.rm_rf(@dir)
  end

  def server(replies = nil, &handler)
    Fake.new(replies: replies, &handler).tap { |s| @servers << s }
  end

  def client(srv, **opts)
    TestSupport.client(srv.base_url, @dir, **opts)
  end

  def msgs(user = "x", history: [])
    M::Messages.new(system: "You check things.", user: user, history: history)
  end

  def ask(client, **opts)
    client.complete(:reviewer, msgs, label: "check", parser: ->(v) { v }, schema: { "type" => "object" }, **opts)
  end

  # --- retry without thinking ---

  [["the budget runs out while thinking", INCOMPLETE],
   ["the server rejects malformed JSON", BAD_JSON],
   ["the answer is empty", Fake.ok(nil, finish: "length")],
   ["the reply is not JSON", Fake.ok("Sure! Here it is: {broken")]].each_with_index do |(name, failure), i|
    define_method("test_retry_without_thinking_#{i}_when_#{name.tr(' ', '_')}") do
      srv = server([failure, Fake.ok('{"findings":[]}')])
      out = ask(client(srv, profile: { "maxOutputTokens" => 800 }))
      assert_equal({ "findings" => [] }, out.value)
      assert out.retried_without_thinking
      first, second = srv.chat_bodies
      assert_equal 2, srv.chat_bodies.size
      assert_nil first["chat_template_kwargs"]
      assert_equal({ "enable_thinking" => false }, second["chat_template_kwargs"])
      assert_equal 800, first["max_tokens"]
      assert_equal 800, second["max_tokens"], "the retry keeps the whole output allowance"
      assert second["response_format"], "the retry still asks for the same JSON schema"
    end
  end

  def test_retry_uses_the_probed_control
    srv = server([INCOMPLETE, Fake.ok("{}")])
    ask(client(srv, caps: { thinking_control: "reasoning_effort" }, profile: { "thinking" => { "effort" => "medium" } }))
    first, second = srv.chat_bodies
    assert_equal "medium", first["reasoning_effort"]
    assert_equal "none", second["reasoning_effort"]
    assert_nil second["chat_template_kwargs"]
  end

  def test_the_retry_happens_at_most_once
    srv = server([INCOMPLETE, INCOMPLETE, Fake.ok("{}")])
    err = assert_raises(Harness::ModelOutputError) { ask(client(srv)) }
    assert_equal "model.truncated", err.reason
    assert_equal 2, srv.chat_bodies.size
  end

  def test_a_good_answer_is_never_retried
    srv = server([Fake.ok('{"a":1}')])
    out = ask(client(srv))
    refute out.retried_without_thinking
    assert_equal 1, srv.chat_bodies.size
    assert_equal({ in: 10, out: 5, thinking: 0 }, out.usage)
    assert_equal "test-model", out.model
    assert_equal "default", out.profile
  end

  def test_tool_calls_are_not_mistaken_for_an_empty_answer_when_tools_were_offered
    call = { "id" => "t1", "type" => "function", "function" => { "name" => "read_file", "arguments" => "{}" } }
    srv = server([Fake.ok(nil, finish: "tool_calls", tool_calls: [call])])
    out = client(srv).complete(:reviewer, msgs, label: "lookup", tools: [{ "type" => "function" }])
    refute out.retried_without_thinking
    assert_equal [call], out.tool_calls
  end

  def test_a_tool_call_where_json_was_required_is_unusable_output_not_unavailable
    srv = server([Fake.error(502, "structured output was incomplete (finish_reason=tool_calls); increase the output budget")])
    err = assert_raises(Harness::ModelOutputError) { ask(client(srv)) }
    refute_kind_of Harness::ModelUnavailableError, err
  end

  # A live run spent about three minutes on each verifier reply that thought until it ran out of room, then
  # answered in seconds with thinking off. After two of those, the role starts with thinking off.
  def test_a_role_that_keeps_running_out_of_room_thinking_stops_thinking
    srv = server([INCOMPLETE, Fake.ok("{}"), INCOMPLETE, Fake.ok("{}"), Fake.ok("{}"), Fake.ok("{}")])
    c = client(srv)
    2.times { assert ask(c).retried_without_thinking }
    third = ask(c)
    refute third.retried_without_thinking, "no reply was thrown away"
    assert_equal({ "enable_thinking" => false }, srv.chat_bodies[4]["chat_template_kwargs"], "the third call starts with thinking off")
    c.complete(:planner, msgs, label: "plan", parser: ->(v) { v }, schema: { "type" => "object" })
    assert_nil srv.chat_bodies[5]["chat_template_kwargs"], "other roles still think"
  end

  # A field run: the first reply was cut off and the retry with thinking off came back with no edits, which was
  # reported as a shape problem. The cause is the size of the answer, so that is the reason kept.
  def test_a_cut_off_reply_whose_retry_also_fails_is_reported_as_out_of_room
    parser = ->(v) { v["edits"].is_a?(Array) && !v["edits"].empty? ? v : raise(Harness::ParseError, "edits: the reply contains no edits") }
    srv = server([INCOMPLETE, Fake.ok('{"edits": []}')])
    err = assert_raises(Harness::ModelOutputError) do
      client(srv).complete(:implementer, msgs, label: "T1.implement", parser: parser, schema: { "type" => "object" })
    end
    assert_equal "model.truncated", err.reason
    assert_match(/did not fit in maxOutputTokens: .*the retry with thinking off then failed: edits: the reply contains no edits/, err.message)
  end

  # A field report: two cut-off implementer replies took nearly five minutes and the report showed 59 tokens out.
  # A reply cut off at the length limit generated its whole allowance, and thinking is counted on its own.
  def test_a_cut_off_reply_counts_its_whole_output_allowance_and_thinking_is_counted
    srv = server([INCOMPLETE, Fake.ok('{"a": 1}', usage: { "prompt_tokens" => 10, "completion_tokens" => 40,
                                                          "completion_tokens_details" => { "reasoning_tokens" => 30 } })])
    out = ask(client(srv, profile: { "maxOutputTokens" => 800 }))
    assert_equal 800 + 40, out.usage[:out], "the cut-off reply counts 800, the answer its own 40"
    assert_equal 30, out.usage[:thinking]
    records = Dir[File.join(@dir, "**", "*.json")].map { |f| JSON.parse(File.read(f)) }.select { |r| r["usage"] }
    assert_equal [800, 40], records.map { |r| r.dig("usage", "out") }.sort.reverse
    assert_equal [30], records.map { |r| r.dig("usage", "thinking") }.compact
    text = Fake.ok('{"a": 1}', usage: {}, reasoning_content: "x" * 300)
    assert_equal 100, ask(client(server([text]))).usage[:thinking], "reasoning text is estimated when not counted"
  end

  def test_inline_thinking_is_stripped_before_parsing
    srv = server([Fake.ok("<think>let me see</think>\n```json\n{\"a\": 1}\n```")])
    assert_equal({ "a" => 1 }, ask(client(srv)).value)
  end

  def test_thinking_that_never_ends_is_thinking_exhausted
    srv = server([Fake.ok("<think>step 1, step 2", finish: "length")])
    err = assert_raises(Harness::ModelOutputError) { ask(client(srv)) }
    assert_equal "model.thinking_exhausted", err.reason
  end

  def test_parser_errors_become_schema_mismatch_after_one_retry
    parser = ->(v) { v["tasks"].is_a?(Array) ? v : raise(Harness::ParseError, "tasks: expected array, got nil") }
    srv = server([Fake.ok('{"x":1}')])
    err = assert_raises(Harness::ModelOutputError) do
      client(srv).complete(:planner, msgs, label: "plan", parser: parser, schema: { "type" => "object" })
    end
    assert_equal "model.schema_mismatch", err.reason
    assert_includes err.message, "tasks: expected array"
    assert_equal 2, srv.chat_bodies.size
  end

  # --- output room and context ---

  def test_only_the_output_allowance_is_shrunk_to_the_room_left
    refusal = Fake.error(400, "request exceeds the context window: prompt (9000 tokens) + max tokens (4800) exceeds " \
                              "the context (16384); requests are never truncated. Send a smaller max_tokens (at most 3200 here)")
    srv = server([refusal, Fake.ok("{}")])
    ask(client(srv, profile: { "maxOutputTokens" => 4800 }))
    assert_equal [4800, 3200], srv.chat_bodies.map { |b| b["max_tokens"] }
  end

  def test_the_at_most_shrink_happens_once_then_overflow
    refusal = Fake.error(400, "prompt + max tokens exceeds the context; max_tokens must be at most 300")
    srv = server([refusal])
    assert_raises(Harness::ContextOverflowError) { ask(client(srv, profile: { "maxOutputTokens" => 4800 })) }
    assert_equal [4800, 300], srv.chat_bodies.map { |b| b["max_tokens"] }
  end

  def test_an_overflow_message_is_context_overflow_not_unavailable
    lm_studio = [400, { "error" => "Engine protocol predict stream returned an error: " \
                                   "{'code':500,'message':'Context size has been exceeded.','type':'server_error'}" }]
    srv = server([lm_studio])
    err = assert_raises(Harness::ContextOverflowError) { ask(client(srv)) }
    refute_kind_of Harness::ModelUnavailableError, err
  end

  def test_a_request_that_cannot_fit_is_refused_before_sending
    srv = server
    err = assert_raises(Harness::ContextOverflowError) do
      client(srv, caps: { context_tokens: 1000 }, profile: { "maxOutputTokens" => 500 })
        .complete(:implementer, msgs("y" * 3000), label: "big")
    end
    assert_match(/the context is 1000/, err.message)
    assert_empty srv.chat_bodies, "the client never trims silently, and never sends what cannot fit"
  end

  # --- availability ---

  [429, 503].each do |status|
    define_method("test_http_#{status}_is_retried_then_unavailable") do
      srv = server([Fake.error(status, "busy")])
      assert_raises(Harness::ModelUnavailableError) { ask(client(srv)) }
      assert_equal 3, srv.chat_bodies.size
    end
  end

  def test_busy_then_ok_recovers
    srv = server([Fake.error(429, "busy"), Fake.ok("{}")])
    refute_nil ask(client(srv))
  end

  def test_a_real_server_error_is_unavailable
    srv = server([Fake.error(500, "engine crashed")])
    err = assert_raises(Harness::ModelUnavailableError) { ask(client(srv)) }
    assert_includes err.message, "engine crashed"
    assert_equal 1, srv.chat_bodies.size
  end

  def test_connection_refused_is_retried_then_unavailable
    port_holder = TCPServer.new("127.0.0.1", 0)
    url = "http://127.0.0.1:#{port_holder.addr[1]}/v1"
    port_holder.close
    waits = []
    c = Harness::Model::Client.new(
      config: TestSupport.config(url), probe: ->(_) { Harness::Model::Probe::Result.new(**TestSupport::CAPS) },
      http: Harness::Model::Http.new(open_timeout: 2), sleeper: ->(s) { waits << s }, env: {}
    )
    assert_raises(Harness::ModelUnavailableError) { ask(c) }
    assert_equal [1, 2], waits, "three tries with backoff"
  end

  # --- structured output modes and prompts ---

  def test_json_schema_mode_sends_the_schema_to_the_server
    srv = server([Fake.ok("{}")])
    ask(client(srv))
    fmt = srv.chat_bodies.first["response_format"]
    assert_equal "json_schema", fmt["type"]
    assert_equal({ "type" => "object" }, fmt.dig("json_schema", "schema"))
  end

  def test_prompt_mode_puts_the_schema_in_the_system_prompt
    srv = server([Fake.ok("Here you go:\n```json\n{\"a\": 2}\n```")])
    out = ask(client(srv, caps: { structured_output: "prompt" }))
    body = srv.chat_bodies.first
    assert_nil body["response_format"]
    assert_includes body["messages"].first["content"], "Reply with only JSON matching this schema:\n{\"type\":\"object\"}"
    assert_equal({ "a" => 2 }, out.value)
  end

  def test_json_object_mode_sends_json_object_and_the_schema_text
    srv = server([Fake.ok("{}")])
    ask(client(srv, caps: { structured_output: "json_object" }))
    body = srv.chat_bodies.first
    assert_equal({ "type" => "json_object" }, body["response_format"])
    assert_includes body["messages"].first["content"], "Reply with only JSON matching this schema"
  end

  def test_prompt_notes_are_appended_last
    srv = server([Fake.ok("{}")])
    ask(client(srv, caps: { structured_output: "prompt" }, profile: { "promptNotes" => "Keep answers short." }))
    assert srv.chat_bodies.first["messages"].first["content"].end_with?("\n\nKeep answers short.")
  end

  def test_plain_text_calls_need_no_json
    srv = server([Fake.ok("Hello there.")])
    out = client(srv).complete(:summarizer, msgs, label: "chat")
    assert_equal "Hello there.", out.text
    assert_nil out.value
    assert_nil srv.chat_bodies.first["response_format"]
  end

  # --- tool history ---

  def history
    [{ "role" => "assistant", "content" => "",
       "tool_calls" => [{ "id" => "1", "function" => { "name" => "read_file", "arguments" => '{"path":"a.ts"}' } }] },
     { "role" => "tool", "tool_call_id" => "1", "content" => "export const a = 1;" }]
  end

  def test_a_json_only_call_after_tool_use_sees_flattened_history
    srv = server([Fake.ok("{}")])
    client(srv).complete(:verifier, msgs(history: history), label: "final", parser: ->(v) { v })
    roles = srv.chat_bodies.first["messages"].map { |m| m["role"] }
    assert_equal %w[system assistant user user], roles
    assert_includes srv.chat_bodies.first["messages"][1]["content"], 'I called: read_file({"path":"a.ts"})'
    refute(srv.chat_bodies.first["messages"].any? { |m| m.key?("tool_calls") })
  end

  def test_native_tool_calls_keep_tool_messages
    srv = server([Fake.ok("done")])
    client(srv).complete(:verifier, msgs(history: history), label: "lookup", tools: [{ "type" => "function" }])
    body = srv.chat_bodies.first
    assert_equal %w[system assistant tool user], body["messages"].map { |m| m["role"] }
    assert body["tools"]
  end

  def test_profiles_without_tool_support_never_see_tool_messages
    srv = server([Fake.ok("done")])
    client(srv, caps: { tool_calls: "none" }).complete(:verifier, msgs(history: history), label: "lookup",
                                                                                        tools: [{ "type" => "function" }])
    body = srv.chat_bodies.first
    refute_includes body["messages"].map { |m| m["role"] }, "tool"
    assert_nil body["tools"]
  end

  # --- records ---

  def test_every_request_is_recorded
    srv = server([INCOMPLETE, Fake.ok("{}")])
    ask(client(srv))
    files = Dir.glob(File.join(@dir, "records", "*.json")).sort
    assert_equal 2, files.size
    first = JSON.parse(File.read(files.first))
    assert_equal %w[error error_class finish_reason label model ms outcome profile prompt_hash role status usage], first.keys.sort
    assert_equal "model.truncated", first["outcome"]
    assert_equal "ok", JSON.parse(File.read(files.last))["outcome"]
    assert_match(/\A\h{64}\z/, first["prompt_hash"])
    assert_match(/action=model\.check outcome=ok/, File.read(Dir.glob(File.join(@dir, "logs", "*.log")).first))
  end

  def test_a_failed_request_records_the_status_and_the_server_error
    srv = server([INCOMPLETE, Fake.ok("{}")])
    ask(client(srv))
    first, last = Dir.glob(File.join(@dir, "records", "*.json")).sort.map { |f| JSON.parse(File.read(f)) }
    assert_equal 502, first["status"]
    assert_includes first["error"], "structured output was incomplete"
    assert_nil last["error"]
  end

  def test_a_key_echoed_in_a_server_error_is_redacted_from_the_record
    fake_key = "sk-#{'a' * 24}"
    srv = server([Fake.error(500, "bad key #{fake_key}")])
    assert_raises(Harness::ModelUnavailableError) { ask(client(srv)) }
    Dir.glob(File.join(@dir, "{records,logs}", "*")).each { |f| refute_includes File.read(f), fake_key }
  end

  def test_log_lines_name_the_run_and_the_task
    srv = server([Fake.ok("{}")])
    c = Harness::Model::Client.new(config: TestSupport.config(srv.base_url),
                                   probe: ->(_) { Harness::Model::Probe::Result.new(**TestSupport::CAPS) },
                                   http: Harness::Model::Http.new, log: Harness::Log.new(dir: File.join(@dir, "logs")),
                                   env: {}, run_id: "r20260101-000000-0001")
    c.complete(:implementer, msgs, label: "T2R1.fix1", parser: ->(v) { v }, schema: { "type" => "object" })
    assert_match(/run=r20260101-000000-0001 task=T2R1 action=model\.T2R1\.fix1 outcome=ok/,
                 File.read(Dir.glob(File.join(@dir, "logs", "*.log")).first))
  end

  def test_a_discarded_reply_is_reported_before_the_retry
    srv = server([INCOMPLETE, Fake.ok("{}")])
    c = client(srv)
    seen = []
    c.on_discard = ->(**info) { seen << info.merge(calls: srv.chat_bodies.size) }
    ask(c)
    assert_equal 1, seen.size
    assert_equal [:reviewer, "check", "model.truncated", 1], seen.first.values_at(:role, :label, :reason, :calls)
    assert_match(/retried with thinking off/, seen.first[:message])
  end

  def test_a_good_reply_reports_no_discard
    srv = server([Fake.ok("{}")])
    c = client(srv)
    seen = []
    c.on_discard = ->(**info) { seen << info }
    ask(c)
    assert_empty seen
  end

  # --- split and retry ---

  def test_complete_each_uses_one_call_when_the_batch_parses
    srv = server([Fake.ok('{"items":[{"n":1},{"n":2}]}')])
    out = client(srv).complete_each(:reviewer, %w[a b], label: "sum", parser: ->(v) { v["n"] }, schema: { "type" => "object" }) do |items|
      msgs(items.join(","))
    end
    assert_equal [1, 2], out.map(&:value)
    assert_equal 1, srv.chat_bodies.size
    assert_equal 2, srv.chat_bodies.first.dig("response_format", "json_schema", "schema", "properties", "items", "maxItems")
  end

  def test_complete_each_splits_a_bad_batch_into_single_calls
    srv = server do |body, _n|
      user = body["messages"].last["content"]
      case user
      when "a,b" then Fake.ok('{"items":[{"n":1}]}') # wrong length: the batch is unusable
      when "a" then Fake.ok('{"n":1}')
      else Fake.ok("not json")
      end
    end
    out = client(srv).complete_each(:reviewer, %w[a b], label: "sum", parser: ->(v) { v.fetch("n") }, schema: nil) do |items|
      msgs(items.join(","))
    end
    assert_equal 1, out[0].value
    assert_kind_of Harness::ModelOutputError, out[1]
    assert_equal 2 + 1 + 2, srv.chat_bodies.size, "batch + retry, item a, item b + retry"
  end
end
