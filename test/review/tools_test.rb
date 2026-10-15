# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# DESIGN.md 8.1: read_file and find_symbol are read-only, guarded by I2 and fenced (I9); the tool loop runs natively
# or through the JSON lookup protocol, capped at maxLookups.

require_relative "../test_helper"
require_relative "../support/fake_llm_server"
require_relative "../support/map_fixture"
require "json"
require "tmpdir"

class ToolsTest < Minitest::Test
  Fake = TestSupport::FakeLlmServer
  MF = TestSupport::MapFixture
  FENCED = %r{\A<untrusted-data id="\h+">\n.*\n</untrusted-data id="\h+">\z}m

  def setup
    @tmp = Dir.mktmpdir("harness-tools-")
    @root = MF.write(File.join(@tmp, "wt"))
    @map = Harness::Repo::Map.new(root: @root, protected: MF::PROTECTED)
    @box = Harness::Review::Toolbox.new(root: @root, protected: MF::PROTECTED, map: @map)
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@tmp)
  end

  def test_read_file_is_numbered_fenced_and_remembered
    out = @box.call("read_file", { "path" => "src/lib/price.ts", "start_line" => 3, "end_line" => 4 })
    assert_match FENCED, out
    assert_includes out, "src/lib/price.ts lines 3-4 of 6:\n    3  export function price(n: number): number {"
    assert_includes @box.seen, "return n * (1 + rate);"
    refute_includes @box.seen, "import { rate }", "only the fetched lines count as seen"
  end

  def test_read_file_refuses_protected_and_outside_paths
    [".env", "tools/check.ts", "../outside.txt", "/etc/passwd", ".git/config", ".git./config"].each do |path|
      out = @box.call("read_file", { "path" => path, "start_line" => 1, "end_line" => 5 })
      assert_match(/error: /, out, path)
      refute_includes out, "SECRET", path
    end
    assert_empty @box.seen
  end

  def test_find_symbol_shows_declarations_and_unknown_tools_get_an_error
    out = @box.call("find_symbol", { "name" => "rate" })
    assert_includes out, "src/lib/tax.ts (ts"
    assert_includes out, "export const rate = 0.2;"
    assert_match(/not exported by any file/, @box.call("find_symbol", { "name" => "nothing" }))
    assert_match(/no symbol name/, @box.call("find_symbol", { "name" => "a b; rm" }))
    assert_match(/unknown tool "run_shell"/, @box.call("run_shell", { "cmd" => "ls" }))
    assert_equal %w[read_file find_symbol], @box.definitions.map { |d| d["function"]["name"] }, "no docs tool without docs"
  end

  def client(caps)
    TestSupport.client(@server.base_url, @tmp, caps: caps)
  end

  def test_native_loop_runs_tools_until_the_cap_and_then_answers
    @server = Fake.new do |body, _n|
      if body["tools"]
        Fake.ok("", tool_calls: [{ "id" => "c1", "type" => "function",
                                   "function" => { "name" => "find_symbol", "arguments" => JSON.generate({ "name" => "rate" }) } }])
      else
        Fake.ok("DONE")
      end
    end
    r = Harness::Review::ToolLoop.run(client: client({}), role: :verifier, system: "s untrusted", user: "u", label: "t",
                                      toolbox: @box, max_calls: 2)
    assert_equal "DONE", r.text
    assert_equal 2, @box.calls.size, "capped at max_calls"
    assert_equal [true, true, false], @server.chat_bodies.map { |b| b.key?("tools") }
    tool_msgs = r.history.select { |m| m["role"] == "tool" }
    assert(tool_msgs.all? { |m| m["content"].match?(FENCED) })
  end

  def test_emulated_loop_uses_the_json_lookup_protocol
    replies = [{ "lookup" => { "tool" => "read_file", "args" => { "path" => "src/lib/tax.ts", "start_line" => 1, "end_line" => 1 } } },
               { "done" => true }]
    @server = Fake.new { |_body, n| Fake.ok(JSON.generate(replies[[n, 1].min])) }
    r = Harness::Review::ToolLoop.run(client: client(tool_calls: "none"), role: :verifier, system: "s", user: "u", label: "t",
                                      toolbox: @box, max_calls: 6)
    assert_equal "DONE", r.text
    assert_equal ["read_file"], @box.calls.map(&:tool)
    refute(@server.chat_bodies.any? { |b| b.key?("tools") }, "no tools are sent to a profile without tool calls")
    assert_includes @server.chat_bodies.first["messages"].first["content"], '{"lookup": {"tool": "<name>"'
    assert_includes @server.chat_bodies.last["messages"].last["content"], "Tool result:\n<untrusted-data"
  end
end
