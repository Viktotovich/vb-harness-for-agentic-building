# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Agent mode's tools: reading, writing through Task::Edits (I2), checks only by configured name (I3), output fenced (I9).

require_relative "../test_helper"
require_relative "../support/run_fixture"
require "tmpdir"

class AgentToolboxTest < Minitest::Test
  F = TestSupport::RunFixture

  def setup
    @tmp = Dir.mktmpdir("harness-agent-tools-")
    @root = File.join(@tmp, "wt")
    F::FILES.merge(".env" => "SECRET=1\n", "src/big.ts" => "x\n" * 450).each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(@root, rel)))
      File.write(File.join(@root, rel), text)
    end
    ruby = RbConfig.ruby
    @config = Harness::Config.parse({
                                      "profiles" => { "default" => { "baseUrl" => "http://127.0.0.1:9/v1" } }, "mode" => "agent",
                                      "agent" => { "maxFilesPerTask" => 2,
                                                   "commands" => { "show" => { "argv" => [ruby, "-e", "puts File.read(ARGV[0])", "{file}"],
                                                                               "params" => { "file" => "path" }, "description" => "print a file" },
                                                                   "echo" => { "argv" => [ruby, "-e", "puts ARGV[0]", "{word}"], "params" => { "word" => "word" } } } },
                                      "stacks" => { "astro" => { "detect" => ["astro.config.mjs"], "protectedPaths" => [".env*", "tools/**"],
                                                                 "gates" => { "typecheck" => { "argv" => [ruby, "tools/typecheck.rb"], "parser" => "astro_check" },
                                                                              "format" => { "argv" => [ruby, "-e", "exit 1"], "blocking" => false } } } }
                                    })
    @stack = @config.stacks["astro"]
    @runner = Harness::Gates::Runner.new(root: @root, env: ENV.to_h)
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def box(writable: true)
    Harness::Agent::Toolbox.new(root: @root, protected: @stack.protected_paths, stack: @stack, settings: @config.agent,
                                runner: @runner, writable: writable)
  end

  def plain(text) = text.lines.reject { |l| l.start_with?("<untrusted-data") || l.start_with?("</untrusted-data") }.join

  def test_reading_lists_searches_and_pages_long_files
    t = box
    assert_includes plain(t.call("list_dir", { "path" => "." })), "src/"
    assert_includes plain(t.call("search", { "text" => "return n" })), "src/lib/price.ts:2:   return n;"
    first = plain(t.call("read_file", { "path" => "src/big.ts" }))
    assert_match(/lines 1-200 of 450/, first)
    assert_match(/read on from line 201/, first)
    assert_match(/\A<untrusted-data id="\h+">/, t.call("read_file", { "path" => "src/lib/price.ts" }), "I9: results are fenced")
  end

  def test_paths_outside_the_worktree_and_protected_paths_are_refused
    t = box
    assert_match(/error: .*outside|error: .*protected/, plain(t.call("read_file", { "path" => "../outside.txt" })))
    assert_match(/error: .*protected/, plain(t.call("read_file", { "path" => ".env" })))
    assert_match(/error: .*protected/, plain(t.call("write_file", { "path" => ".env.local", "content" => "x" })))
    refute(t.calls.any?(&:ok))
    refute_includes plain(t.call("search", { "text" => "SECRET" })), ".env", "protected files are not searched"
  end

  def test_writing_goes_through_edits_with_a_file_cap_and_appends_only_to_own_files
    t = box
    assert_match(/written/, plain(t.call("edit_file", { "path" => "src/lib/price.ts", "search" => "  return n;", "replace" => "  return n * 2;" })))
    assert_match(/error: search text matched 0 times/, plain(t.call("edit_file", { "path" => "src/lib/price.ts", "search" => "nope", "replace" => "x" })))
    assert_match(/error: .*was not created in this task/, plain(t.call("append_file", { "path" => "src/lib/tax.ts", "content" => "x" })))
    assert_match(/written/, plain(t.call("write_file", { "path" => "src/lib/total.ts", "content" => "export const a = 1;\n" })))
    assert_match(/written/, plain(t.call("append_file", { "path" => "src/lib/total.ts", "content" => "export const b = 2;\n" })))
    assert_equal "export const a = 1;\nexport const b = 2;\n", File.read(File.join(@root, "src/lib/total.ts"))
    assert_match(/at most 2 files/, plain(t.call("write_file", { "path" => "src/lib/third.ts", "content" => "x" })))
    assert_equal Set["src/lib/price.ts", "src/lib/total.ts"], t.touched
    assert_equal Set["src/lib/total.ts"], t.created
  end

  def test_the_investigating_agent_cannot_write
    t = box(writable: false)
    refute(t.definitions.any? { |d| d["function"]["name"] == "edit_file" })
    assert_match(/error: this agent only reads/, plain(t.call("write_file", { "path" => "x.ts", "content" => "x" })))
    refute File.exist?(File.join(@root, "x.ts"))
  end

  # I3: a command is chosen by its configured name; the model fills declared parameters, checked by kind.
  def test_commands_run_only_by_name_with_checked_parameters
    t = box
    assert_match(/command:show: passed.*export function price/m, plain(t.call("run_command", { "name" => "show", "params" => { "file" => "src/lib/price.ts" } })))
    assert_match(/error: file: .*does not exist/, plain(t.call("run_command", { "name" => "show", "params" => { "file" => "src/nope.ts" } })))
    assert_match(/error: file: .*(outside|protected)/, plain(t.call("run_command", { "name" => "show", "params" => { "file" => ".env" } })))
    assert_match(/error: word: .*not starting with -/, plain(t.call("run_command", { "name" => "echo", "params" => { "word" => "--version" } })))
    assert_match(/error: word: /, plain(t.call("run_command", { "name" => "echo", "params" => { "word" => "a; rm -rf ~" } })))
    assert_match(/error: no command named rm/, plain(t.call("run_command", { "name" => "rm", "params" => {} })))
    assert_match(/typecheck: passed/, plain(t.call("run_gate", { "name" => "typecheck" })))
    assert_match(/error: no gate named lint/, plain(t.call("run_gate", { "name" => "lint" })))
  end

  # A gate with blocking: false cannot stop a task, so the agent is told: a field run spent hours on a formatter.
  def test_a_failing_optional_gate_says_it_does_not_block
    t = box
    assert_match(/format: failed.*optional: it never blocks the task/m, plain(t.call("run_gate", { "name" => "format" })))
    refute_match(/optional/, plain(t.call("run_gate", { "name" => "typecheck" })))
    listing = t.definitions.find { |d| d["function"]["name"] == "run_gate" }["function"]["description"]
    assert_includes listing, "typecheck, format (optional)"
  end

  # An agent that may edit the checks' own configuration or existing tests could make failing gates pass without
  # fixing anything. Outside the files the plan names, those writes are refused; inside them, they are allowed.
  def test_check_configuration_and_existing_tests_are_off_limits_unless_planned
    { "tsconfig.json" => "{}", "vitest.config.ts" => "export default {};", ".eslintrc.json" => "{}", "tests/price.test.ts" => "test" }.each do |rel, text|
      FileUtils.mkdir_p(File.dirname(File.join(@root, rel)))
      File.write(File.join(@root, rel), text)
    end
    t = box
    %w[tsconfig.json vitest.config.ts .eslintrc.json package.json].each do |rel|
      assert_match(/error: #{Regexp.escape(rel)} is check configuration/, plain(t.call("write_file", { "path" => rel, "content" => "{}" })), rel)
    end
    assert_match(/error: tests\/price\.test\.ts is an existing test/, plain(t.call("edit_file", { "path" => "tests/price.test.ts", "search" => "test", "replace" => "skip" })))
    assert_match(/written/, plain(t.call("write_file", { "path" => "tests/new.test.ts", "content" => "test" })), "a new test is fine")
    assert_equal "{}", File.read(File.join(@root, "tsconfig.json"))
    planned = Harness::Agent::Toolbox.new(root: @root, protected: @stack.protected_paths, stack: @stack, settings: @config.agent,
                                          runner: @runner, writable: true, planned: ["tsconfig.json"])
    assert_match(/written/, plain(planned.call("write_file", { "path" => "tsconfig.json", "content" => "{\"strict\": true}" })), "the plan may name it")
  end

  # Eval runs: an agent wrote a new test, was refused when it tried to fix it, and spent its steps on new copies.
  def test_a_test_written_in_this_task_can_be_fixed_and_one_from_before_it_cannot
    File.write(File.join(@root, "tests-old.test.ts"), "test")
    t = box
    assert_match(/written/, plain(t.call("write_file", { "path" => "tests/new.test.ts", "content" => "first" })))
    assert_match(/written/, plain(t.call("write_file", { "path" => "tests/new.test.ts", "content" => "second" })), "a whole rewrite")
    assert_match(/written/, plain(t.call("edit_file", { "path" => "tests/new.test.ts", "search" => "second", "replace" => "third" })), "an edit")
    assert_equal "third", File.read(File.join(@root, "tests/new.test.ts"))
    assert_match(/is an existing test/, plain(t.call("write_file", { "path" => "tests-old.test.ts", "content" => "skip" })))
    assert_equal "test", File.read(File.join(@root, "tests-old.test.ts"))
    assert_match(/is an existing test/, plain(box.call("write_file", { "path" => "tests/new.test.ts", "content" => "skip" })),
                 "to the next task, it is an existing test")
    assert_equal "third", File.read(File.join(@root, "tests/new.test.ts"))
  end

  def test_large_files_are_not_read_and_protected_names_are_not_listed
    File.write(File.join(@root, "src/huge.txt"), "x" * (2 * 1024 * 1024 + 1))
    t = box
    assert_match(/error: src\/huge\.txt is 2048 KB; read_file opens files up to 2 MB/, plain(t.call("read_file", { "path" => "src/huge.txt" })))
    refute_includes plain(t.call("list_dir", { "path" => "." })).lines.map(&:strip), ".env", "a protected file's name is not shown"
  end

  # A word parameter is not a way out of the worktree.
  def test_word_parameters_cannot_name_places_outside_the_repository
    t = box
    ["/etc/passwd", "C:/Windows/win.ini", "~/secrets", "../outside", "a/../../b"].each do |w|
      assert_match(/\Aerror: word: /, plain(t.call("run_command", { "name" => "echo", "params" => { "word" => w } })), w)
    end
    assert_match(/error: word: must not name a place outside the repository/, plain(t.call("run_command", { "name" => "echo", "params" => { "word" => "/etc/passwd" } })))
    assert_match(/command:echo: passed/, plain(t.call("run_command", { "name" => "echo", "params" => { "word" => "price doubles" } })))
  end

  def test_commands_are_validated_in_config
    base = { "profiles" => { "default" => { "baseUrl" => "http://127.0.0.1:9/v1" } } }
    err = assert_raises(Harness::ParseError) { Harness::Config.parse(base.merge("agent" => { "commands" => { "x" => { "argv" => ["{prog}"], "params" => { "prog" => "word" } } } })) }
    assert_match(/the program cannot be a parameter/, err.message)
    err = assert_raises(Harness::ParseError) { Harness::Config.parse(base.merge("agent" => { "commands" => { "x" => { "argv" => %w[npx {f}] } } })) }
    assert_match(/\{f\} is not declared in params/, err.message)
    err = assert_raises(Harness::ParseError) { Harness::Config.parse(base.merge("mode" => "yolo")) }
    assert_match(/mode/, err.message)
  end
end
