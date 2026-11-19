# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# ruby2shell (GHSA-34m4-m9fh-gqp5): a one-byte heap overflow in Ruby's case mapping of legacy single-byte encodings,
# reached by upcase, swapcase, downcase(:fold) and casecmp? on a string with 21 or more "ß". The harness never
# runs that code path: lib/ changes case only through Harness::Ascii, which works on binary copies.

require_relative "test_helper"
require_relative "../lib/harness/ascii"
require_relative "../lib/harness/doctor"

class AsciiTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  # Any call that can reach a case mapping. Plain downcase cannot (ß lowercases to itself), so it stays allowed.
  RISKY = /(?<!\bAscii)\.(?:upcase|swapcase|capitalize|casecmp)(?![A-Za-z0-9_])|:fold\b/
  HELPER = "lib/harness/ascii.rb"

  # 30 "ß" in each affected family: past the 20-byte slack in the output buffer.
  def legacy_strings
    %w[ISO-8859-1 ISO-8859-15 Windows-1252 Windows-1250].map { |enc| ("\xDF".b * 30 + "abc").force_encoding(enc) }
  end

  def test_upcase_touches_only_a_to_z
    assert_equal "NODE_ENV", Harness::Ascii.upcase("node_env")
    assert_equal Encoding::UTF_8, Harness::Ascii.upcase("node_env").encoding
    assert_equal "ÄBC", Harness::Ascii.upcase("Äbc"), "non-ASCII letters are left as they are"
    legacy_strings.each do |s|
      out = Harness::Ascii.upcase(s)
      assert_equal ("\xDF".b * 30) + "ABC", out.b, "#{s.encoding}: ß must stay one byte"
    end
  end

  def test_same_compares_without_case_mapping
    assert Harness::Ascii.same?("Content-Length", "content-length")
    assert Harness::Ascii.same?("Path", "PATH")
    refute Harness::Ascii.same?("PATH", "PATHEXT")
    legacy_strings.each do |s|
      assert Harness::Ascii.same?(s, s.dup), s.encoding.to_s
      refute Harness::Ascii.same?(s, "content-length"), s.encoding.to_s
    end
  end

  def test_capitalize_touches_only_a_to_z
    assert_equal "Frame", Harness::Ascii.capitalize("FRAME")
    assert_equal "Run `npm install` there", Harness::Ascii.capitalize("run `npm install` there")
    legacy_strings.each { |s| assert_equal 33, Harness::Ascii.capitalize(s).bytesize, s.encoding.to_s }
  end

  def test_lib_changes_case_only_through_ascii
    files = Dir.glob(File.join(ROOT, "{lib,exe}", "**", "*")).select { |f| File.file?(f) && (f.end_with?(".rb") || f.include?("/exe/")) }
    refute_empty files
    hits = files.flat_map do |f|
      rel = f.delete_prefix("#{ROOT}/")
      next [] if rel == HELPER

      File.read(f, mode: "rb").force_encoding(Encoding::UTF_8).scrub.each_line.with_index(1).filter_map do |line, n|
        "#{rel}:#{n}: #{line.strip}" if !line.lstrip.start_with?("#") && line.match?(RISKY)
      end
    end
    assert_empty hits, "use Harness::Ascii instead (ruby2shell, GHSA-34m4-m9fh-gqp5):\n#{hits.join("\n")}"
  end

  def test_scan_catches_each_risky_call
    ["x.upcase", "x.upcase!", "x.swapcase", "x.capitalize", "a.casecmp?(b)", "a.casecmp(b)", "x.downcase(:fold)"].each do |code|
      assert_match RISKY, code
    end
    refute_match RISKY, "x.downcase"
    refute_match RISKY, "Ascii.upcase(x)"
    refute_match RISKY, "Harness::Ascii.same?(a, b)"
  end

  def test_doctor_names_the_fixed_release
    { "3.3.0" => "3.3.14", "3.3.13" => "3.3.14", "3.4.6" => "3.4.13", "3.4.12" => "3.4.13", "4.0.0" => "4.0.10",
      "4.0.9" => "4.0.10" }.each { |v, fixed| assert_equal fixed, Harness::Doctor.ruby2shell_upgrade(v), v }
    %w[3.3.14 3.4.13 3.4.20 4.0.10 4.1.0 4.1.0.preview1].each { |v| assert_nil Harness::Doctor.ruby2shell_upgrade(v), v }
  end
end
