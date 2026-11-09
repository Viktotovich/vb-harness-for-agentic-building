# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Replies cut off at the output limit: an answer is continued where it stopped, and reasoning that ran out of room
# is carried into the retry instead of thrown away. A slow local model spent two hours on one 8,000-token reply;
# discarding it cost all of that.

require_relative "../test_helper"
require_relative "../support/fake_llm_server"
require "fileutils"
require "tmpdir"

class ContinuationTest < Minitest::Test
  Fake = TestSupport::FakeLlmServer
  M = Harness::Model
  C = M::Client

  def setup
    @dir = Dir.mktmpdir("harness-continue-")
    @servers = []
  end

  def teardown
    @servers.each(&:stop)
    FileUtils.rm_rf(@dir)
  end

  def server(replies = nil, &handler)
    Fake.new(replies: replies, &handler).tap { |s| @servers << s }
  end

  def client(srv, caps: {}, profile: {})
    TestSupport.client(srv.base_url, @dir, caps: { continuation: "prefill" }.merge(caps), profile: profile)
  end

  def ask(client, role: :implementer)
    msgs = M::Messages.new(system: "You write code.", user: "Do the task.")
    client.complete(role, msgs, label: "T1.implement", parser: ->(v) { v }, schema: { "type" => "object" })
  end

  def cut(text) = Fake.ok(text, finish: "length")

  # --- continuing a cut-off answer ---

  def test_a_cut_off_answer_is_continued_and_joined
    srv = server([cut('{"edits": [1, '), Fake.ok("2, 3]}")])
    out = ask(client(srv))
    assert_equal({ "edits" => [1, 2, 3] }, out.value)
    refute out.retried_without_thinking, "nothing was thrown away"
    first, second = srv.chat_bodies
    assert_equal 2, srv.chat_bodies.size
    assert_equal({ "role" => "assistant", "content" => '{"edits": [1, ' }, second["messages"].last)
    assert_equal first["messages"], second["messages"][0...-1], "the conversation is the same up to the answer"
    assert_nil second["response_format"], "a grammar would restart at its root"
    assert_equal({ "enable_thinking" => false }, second["chat_template_kwargs"])
    assert_equal first["max_tokens"], second["max_tokens"]
  end

  def test_the_join_keeps_spaces_at_the_cut_exactly
    srv = server([cut("{\"note\": \"two "), Fake.ok(" spaces\"}")])
    assert_equal({ "note" => "two  spaces" }, ask(client(srv)).value)
  end

  def test_a_server_that_repeats_the_started_answer_is_not_doubled
    srv = server([cut('{"a": [1, '), Fake.ok('{"a": [1, 2]}')])
    assert_equal({ "a" => [1, 2] }, ask(client(srv)).value)
  end

  def test_think_blocks_are_not_part_of_the_continued_answer
    srv = server([cut("<think>plan it</think>{\"a\": "), Fake.ok("1}")])
    assert_equal({ "a" => 1 }, ask(client(srv)).value)
    assert_equal '{"a": ', srv.chat_bodies[1]["messages"].last["content"]
  end

  def test_a_long_answer_is_continued_several_times
    srv = server([cut('{"a": ['), cut("1, "), cut("2, "), Fake.ok("3]}")])
    assert_equal({ "a" => [1, 2, 3] }, ask(client(srv)).value)
    assert_equal 4, srv.chat_bodies.size
    assert_equal '{"a": [1, 2, ', srv.chat_bodies[3]["messages"].last["content"]
  end

  def test_after_the_last_continuation_the_client_asks_again
    srv = server([cut('{"a": ['), cut("1, "), cut("2, "), cut("3, "), Fake.ok("{}")])
    out = ask(client(srv))
    assert_equal({}, out.value)
    assert out.retried_without_thinking
    assert_equal 1 + C::MAX_CONTINUATIONS + 1, srv.chat_bodies.size
    refute_equal "assistant", srv.chat_bodies.last["messages"].last["role"], "the retry starts a new answer"
  end

  def test_a_continuation_that_would_not_fit_the_context_is_not_sent
    srv = server([cut("{\"a\": \"#{'x' * 1500}"), Fake.ok("{}")])
    ask(client(srv, caps: { context_tokens: 1000 }, profile: { "maxOutputTokens" => 500 }))
    assert_equal 2, srv.chat_bodies.size
    refute_equal "assistant", srv.chat_bodies[1]["messages"].last["role"]
  end

  def test_a_refused_continuation_falls_back_to_asking_again
    srv = server([cut('{"a": ['), Fake.error(400, "assistant prefill is not supported"), Fake.ok("{}")])
    out = ask(client(srv))
    assert_equal({}, out.value)
    assert_equal 3, srv.chat_bodies.size
  end

  def test_a_continued_answer_that_is_still_wrong_is_retried
    parser = ->(v) { v["edits"].is_a?(Array) ? v : raise(Harness::ParseError, "edits: expected array") }
    srv = server([cut('{"edits": '), Fake.ok('"none"}'), Fake.ok('{"edits": []}')])
    msgs = M::Messages.new(system: "s", user: "u")
    out = client(srv).complete(:implementer, msgs, label: "T1.implement", parser: parser, schema: { "type" => "object" })
    assert_equal({ "edits" => [] }, out.value)
    assert_equal 3, srv.chat_bodies.size
  end

  def test_the_continue_final_message_mode_sends_its_fields
    srv = server([cut('{"a": '), Fake.ok("1}")])
    ask(client(srv, caps: { continuation: "continue_final_message" }))
    second = srv.chat_bodies[1]
    assert_equal true, second["continue_final_message"]
    assert_equal false, second["add_generation_prompt"]
  end

  def test_a_server_that_cannot_continue_is_asked_again_as_before
    srv = server([cut('{"a": '), Fake.ok("{}")])
    out = ask(client(srv, caps: { continuation: "none" }))
    assert out.retried_without_thinking
    assert_equal "user", srv.chat_bodies[1]["messages"].last["role"]
  end

  def test_a_finished_reply_that_is_not_json_is_not_continued
    srv = server([Fake.ok("Sure! {broken"), Fake.ok("{}")])
    ask(client(srv))
    assert_equal "user", srv.chat_bodies[1]["messages"].last["role"]
  end

  # --- reasoning carried into the retry ---

  def thought(n = 900) = "Step one: read the file. " * (n / 25)

  def test_reasoning_that_ran_out_of_room_is_carried_into_the_retry
    srv = server([Fake.ok(nil, finish: "length", reasoning_content: thought), Fake.ok("{}")])
    out = ask(client(srv))
    assert out.retried_without_thinking
    user = srv.chat_bodies[1]["messages"].last["content"]
    assert user.start_with?("Do the task.\n\n#{C::CARRY_NOTE}\n<reasoning>\n"), user[0, 200]
    assert_includes user, thought.strip
    assert_equal({ "enable_thinking" => false }, srv.chat_bodies[1]["chat_template_kwargs"])
  end

  def test_inline_reasoning_is_carried_without_its_tags
    srv = server([cut("<think>#{thought}"), Fake.ok("{}")])
    ask(client(srv))
    user = srv.chat_bodies[1]["messages"].last["content"]
    assert_includes user, thought.strip
    refute_includes user, "<think>"
  end

  def test_carried_reasoning_is_cut_from_the_start_to_fit
    long = "#{'early idea. ' * 400}the final conclusion"
    srv = server([Fake.ok(nil, finish: "length", reasoning_content: long), Fake.ok("{}")])
    ask(client(srv, caps: { context_tokens: 2000 }, profile: { "maxOutputTokens" => 500 }))
    body = srv.chat_bodies[1]
    notes = body["messages"].last["content"][%r{<reasoning>\n(.*)\n</reasoning>}m, 1]
    assert notes.start_with?("..."), "the start is left out"
    assert notes.end_with?("the final conclusion"), "the latest reasoning is kept"
    prompt = M::Tokens.estimate_messages(body["messages"])
    assert prompt + 500 <= 2000, "the retry fits the context (#{prompt} + 500)"
  end

  def test_short_reasoning_is_not_carried
    srv = server([Fake.ok(nil, finish: "length", reasoning_content: "hmm"), Fake.ok("{}")])
    ask(client(srv))
    assert_equal "Do the task.", srv.chat_bodies[1]["messages"].last["content"]
  end

  def test_a_role_keeps_thinking_when_carried_reasoning_lets_it_answer
    exhausted = Fake.ok(nil, finish: "length", reasoning_content: thought)
    srv = server([exhausted, Fake.ok("{}"), exhausted, Fake.ok("{}"), Fake.ok("{}")])
    c = client(srv)
    2.times { ask(c) }
    ask(c)
    assert_nil srv.chat_bodies[4]["chat_template_kwargs"], "the third call still thinks"
  end

  def test_a_role_stops_thinking_when_even_the_carried_retry_fails
    exhausted = Fake.ok(nil, finish: "length", reasoning_content: thought)
    srv = server([exhausted, exhausted, exhausted, exhausted, Fake.ok("{}")])
    c = client(srv)
    2.times { assert_raises(Harness::ModelOutputError) { ask(c) } }
    ask(c)
    assert_equal({ "enable_thinking" => false }, srv.chat_bodies[4]["chat_template_kwargs"])
  end

  def test_the_discard_event_says_the_reasoning_was_kept
    srv = server([Fake.ok(nil, finish: "length", reasoning_content: thought), Fake.ok("{}")])
    c = client(srv)
    seen = []
    c.on_discard = ->(**e) { seen << e }
    ask(c)
    assert_equal "model.thinking_exhausted", seen.first[:reason]
    assert_match(/retried with thinking off, keeping its reasoning/, seen.first[:message])
  end
end
