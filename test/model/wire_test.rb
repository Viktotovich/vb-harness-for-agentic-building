# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"

class WireTest < Minitest::Test
  W = Harness::Model::Wire

  # A field run blocked a task on invalid JSON at the first attempt. Repairs that cannot change the meaning are
  # tried before giving up; anything else still fails.
  def test_extract_json_repairs_stray_commas_and_nothing_else
    assert_equal({ "edits" => [1, 2] }, W.extract_json('{"edits": [1, 2,], }'))
    assert_equal({ "a" => 1, "b" => 2 }, W.extract_json('{"a": 1,, "b": 2}'))
    assert_equal({ "s" => "keep ,] and ,, here" }, W.extract_json('{"s": "keep ,] and ,, here",}'), "strings are untouched")
    assert_raises(JSON::ParserError) { W.extract_json('{"edits": [{"op": "create", "content": "half') }
    assert_raises(JSON::ParserError) { W.extract_json('{"a": "x" "b": 2}') }
  end

  def test_extract_json_handles_fences_and_prose
    assert_equal({ "a" => 1 }, W.extract_json('{"a":1}'))
    assert_equal({ "a" => 1 }, W.extract_json("```json\n{\"a\":1}\n```"))
    assert_equal([1, 2], W.extract_json("Sure, here:\n[1, 2]\nHope that helps."))
    assert_raises(JSON::ParserError) { W.extract_json("no json here") }
  end

  def test_split_thinking
    assert_equal ["answer", "<think>a</think>", false], W.split_thinking("<think>a</think> answer")
    answer, reasoning, open = W.split_thinking("<think>still going")
    assert_equal ["", true], [answer, open]
    assert_includes reasoning, "still going"
    assert_equal ["", "", false], W.split_thinking(nil)
  end

  def test_thinking_off_replaces_every_thinking_field
    body = { "model" => "m", "reasoning_effort" => "high", "thinking_budget_tokens" => 900 }
    assert_equal({ "model" => "m", "chat_template_kwargs" => { "enable_thinking" => false } },
                 W.thinking_off(body, "chat_template_kwargs"))
    assert_equal({ "model" => "m" }, W.thinking_off(body, "none"))
  end

  def test_thinking_on_follows_the_profile
    t = Harness::Model::Thinking.new(control: "probe", effort: "low", budget_tokens: 256)
    assert_equal({ "reasoning_effort" => "low" }, W.thinking_on(t, "reasoning_effort"))
    assert_equal({ "thinking_budget_tokens" => 256 }, W.thinking_on(t, "budget"))
    assert_equal({}, W.thinking_on(t, "chat_template_kwargs"))
  end

  # Port of REVIEWER flattenToolHistory.
  def test_flatten_tool_history
    history = [
      { "role" => "assistant", "content" => "checking",
        "tool_calls" => [{ "function" => { "name" => "find_symbol", "arguments" => '{"name":"Card"}' } }] },
      { "role" => "tool", "content" => "src/Card.astro:3" },
      { "role" => "user", "content" => "go on" }
    ]
    flat = W.flatten_tool_history(history)
    assert_equal [{ "role" => "assistant", "content" => "checking\nI called: find_symbol({\"name\":\"Card\"})" },
                  { "role" => "user", "content" => "Tool result:\nsrc/Card.astro:3" },
                  { "role" => "user", "content" => "go on" }], flat
  end
end
