# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require "tmpdir"

class EditsTest < Minitest::Test
  T = Harness::Task

  def setup
    @root = Dir.mktmpdir("harness-edits-")
    write("src/card.ts", "export function card() {\n  return 1;\n}\n")
    write("src/twice.ts", "const x = 1;\nconst x = 1;\n")
    write("src/crlf.ts", "line one\r\nline two\r\n")
    write("src/big.ts", "x" * 5000)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def write(rel, content)
    full = File.join(@root, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.binwrite(full, content)
  end

  def read(rel)
    File.binread(File.join(@root, rel))
  end

  def set(*edits)
    T::EditSet.parse({ "edits" => edits, "notes" => "untrusted" })
  end

  def apply(edit_set, modify: %w[src/card.ts src/twice.ts src/crlf.ts src/big.ts], create: %w[src/new.ts])
    T::Edits.apply(root: @root, edit_set: edit_set, modify: modify, create: create,
                   protected: [".env*", "**/*.lock"], rewrite_max_bytes: 4096)
  end

  def replace(path, search, with)
    { "op" => "replace", "path" => path, "search" => search, "replace" => with }
  end

  # --- replace: 0, 1, 2 matches ---

  def test_replace_with_one_match_is_applied
    r = apply(set(replace("src/card.ts", "  return 1;", "  return 2;")))
    assert r.ok?
    assert_equal ["src/card.ts"], r.written
    assert_equal "export function card() {\n  return 2;\n}\n", read("src/card.ts")
  end

  def test_replace_with_no_match_is_rejected_with_the_closest_lines
    r = apply(set(replace("src/card.ts", "  return one;", "  return 2;")))
    refute r.ok?
    rej = r.rejections.first
    assert_equal "edit.search_not_found", rej.reason
    assert_includes rej.message, "matched 0 times in src/card.ts"
    assert_includes rej.message, "2:   return 1;"
    assert_equal "export function card() {\n  return 1;\n}\n", read("src/card.ts")
  end

  def test_replace_with_two_matches_is_rejected_as_ambiguous
    r = apply(set(replace("src/twice.ts", "const x = 1;", "const y = 1;")))
    assert_equal "edit.search_ambiguous", r.rejections.first.reason
    assert_includes r.rejections.first.message, "matched 2 times"
  end

  def test_line_endings_are_the_only_normalization
    r = apply(set(replace("src/crlf.ts", "line one\nline two", "line 1\nline 2")))
    assert r.ok?
    assert_equal "line 1\r\nline 2\r\n", read("src/crlf.ts"), "the file keeps its CRLF line endings"
    r = apply(set(replace("src/card.ts", "return  1;", "x")))
    assert_equal "edit.search_not_found", r.rejections.first.reason, "whitespace is not normalized"
  end

  def test_edits_to_one_file_apply_in_order
    r = apply(set(replace("src/card.ts", "return 1;", "return 2;"), replace("src/card.ts", "return 2;", "return 3;")))
    assert r.ok?
    assert_includes read("src/card.ts"), "return 3;"
  end

  # --- create ---

  def test_create_a_declared_new_file
    r = apply(set({ "op" => "create", "path" => "src/new.ts", "content" => "export const n = 1;\n" }))
    assert_equal [["src/new.ts"], ["src/new.ts"]], [r.written, r.created]
    assert_equal "export const n = 1;\n", read("src/new.ts")
  end

  def test_create_over_an_existing_file
    small = apply(set({ "op" => "create", "path" => "src/card.ts", "content" => "rewritten\n" }))
    assert small.ok?, "a small file listed in files.modify may be rewritten whole"
    big = apply(set({ "op" => "create", "path" => "src/big.ts", "content" => "y" }))
    assert_equal "edit.create_exists", big.rejections.first.reason
    write("src/other.ts", "x")
    undeclared_modify = apply(set({ "op" => "create", "path" => "src/other.ts", "content" => "y" }),
                              modify: [], create: %w[src/other.ts])
    assert_equal "edit.create_exists", undeclared_modify.rejections.first.reason
  end

  def test_delete
    r = apply(set({ "op" => "delete", "path" => "src/twice.ts" }))
    assert r.ok?
    refute File.exist?(File.join(@root, "src/twice.ts"))
    assert_equal "edit.search_not_found", apply(set({ "op" => "delete", "path" => "src/new.ts" })).rejections.first.reason
  end

  # --- refusals ---

  def test_undeclared_protected_and_outside_paths_are_rejected
    r = apply(set({ "op" => "create", "path" => "src/sneaky.ts", "content" => "x" },
                  { "op" => "create", "path" => ".env", "content" => "x" },
                  { "op" => "create", "path" => "../escape.ts", "content" => "x" }),
              create: %w[src/new.ts .env ../escape.ts].first(2))
    assert_equal %w[edit.undeclared_path edit.protected_path edit.outside_worktree], r.rejections.map(&:reason)
    refute File.exist?(File.join(@root, "src/sneaky.ts"))
    refute File.exist?(File.join(File.dirname(@root), "escape.ts"))
  end

  # --- atomicity ---

  def test_one_rejected_edit_means_nothing_is_written
    r = apply(set(replace("src/card.ts", "return 1;", "return 2;"), replace("src/twice.ts", "nope", "x")))
    assert_equal 1, r.rejections.size
    assert_empty r.written
    assert_includes read("src/card.ts"), "return 1;"
  end

  def test_a_write_failure_restores_files_already_written
    write("src/lone.ts", "a\n")
    edits = set(replace("src/lone.ts", "a", "b"), { "op" => "create", "path" => "src/lone.ts/child.ts", "content" => "x" })
    assert_raises(SystemCallError) { apply(edits, modify: %w[src/lone.ts], create: %w[src/lone.ts/child.ts]) }
    assert_equal "a\n", read("src/lone.ts")
  end

  # --- parsing ---

  def test_edit_set_parse_errors_name_the_field
    msg = ->(raw) { assert_raises(Harness::ParseError) { T::EditSet.parse(raw) }.message }
    assert_equal "edits[0].search: expected non-empty string, got nil",
                 msg.call({ "edits" => [{ "op" => "replace", "path" => "a", "replace" => "b" }] })
    assert_match(/\Aedits\[0\].op: expected one of create, replace, delete/, msg.call({ "edits" => [{ "op" => "move" }] }))
    assert_match(/\Aedits\[0\].search: unknown key/, msg.call({ "edits" => [{ "op" => "create", "path" => "a", "content" => "", "search" => "x" }] }))
    assert_equal "edits: the reply contains no edits", msg.call({ "edits" => [] })
    assert_equal "edits: expected array, got nil", msg.call({ "notes" => "hi" })
  end

  def test_test_edits_are_applied_with_the_others
    set = T::EditSet.parse({ "edits" => [], "tests" => [{ "op" => "create", "path" => "tests/unit/x.test.ts", "content" => "t" }] })
    r = apply(set, create: %w[tests/unit/x.test.ts])
    assert_equal ["tests/unit/x.test.ts"], r.written
  end
end
