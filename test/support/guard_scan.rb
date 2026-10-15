# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "find"

module TestSupport
  # Text scans behind the guardrail tests. They live under test/ so that the
  # patterns themselves never appear in lib/ (I1, I3).
  module GuardScan
    Hit = Data.define(:file, :line, :text, :rule)

    # I1: model names, ids and vendors. Matched case-insensitively at the start of a word, so a
    # provider name such as "ollama" does not count as the model family it contains.
    MODEL_WORDS = %w[qwen tiel swift gemma llama gpt claude mistral deepseek nemotron].freeze
    MODEL_RE = /(?<![a-z0-9])(?:#{MODEL_WORDS.join('|')})/i

    # I3: ways to start a process other than Harness::Exec. Applied to code with comments and
    # string literals blanked out, except RAW_SHELL_RULES which need the literal.
    SHELL_RULES = {
      "backtick" => /`/,
      "%x literal" => /%x[^\w\s]/,
      "system/spawn/exec call" => /(?<![\w.:@$])(?:system|spawn|exec)(?![\w:?!=])\s*(?:\(|\[|%|S\b|[a-z_@$])/,
      "Kernel process call" => /\bKernel\s*\.\s*(?:system|spawn|exec|open)\b/,
      "Process.spawn/exec" => /\bProcess\s*\.\s*(?:spawn|exec)\b/,
      "IO.popen" => /\bIO\s*\.\s*popen\b/,
      "Open3" => /\bOpen3\s*\./,
      "fork" => /(?<![\w.:@$])fork\b(?!:)/
    }.freeze
    RAW_SHELL_RULES = {
      "open with pipe" => /\bopen\s*\(?\s*["']\|/,
      "IO read with pipe" => /\bIO\s*\.\s*(?:read|readlines|write|foreach|binread)\s*\(?\s*["']\|/
    }.freeze
    EXEC_FILE = "lib/harness/exec.rb"

    # I13: home paths and secrets. Built from pieces so this file does not match itself.
    HOME_RE = Regexp.new("[A-Za-z]:" + "\\\\+Us" + "ers\\\\+|/ho" + "me/|/Us" + "ers/")
    SECRET_RE = Regexp.new(
      [
        "gh" + "p_[A-Za-z0-9]{10,}",
        "github" + "_pat_[A-Za-z0-9_]{10,}",
        "(?<![A-Za-z0-9])s" + "k-[A-Za-z0-9_-]{16,}",
        "AK" + "IA[0-9A-Z]{16}",
        "-----" + "BEGIN "
      ].join("|")
    )

    # I14: the require allowlist from DESIGN.md section 2.
    REQUIRE_ALLOW = %w[
      json net/http uri open3 optparse fileutils pathname digest securerandom time timeout find
      tempfile tmpdir socket erb set shellwords minitest/autorun
    ].freeze
    REQUIRE_RE = /^\s*require\b\s*\(?\s*(?<arg>\S[^\n#]*)/

    module_function

    # @param root [String] repository root
    # @param dirs [Array<String>] directories relative to root
    # @return [Array<String>] relative paths of regular files below dirs
    def files_in(root, dirs)
      dirs.flat_map do |dir|
        base = File.join(root, dir)
        next [] unless File.directory?(base)

        out = []
        Find.find(base) { |p| out << p.delete_prefix("#{root}/") if File.file?(p) }
        out
      end.sort
    end

    # @param path [String]
    # @return [Boolean] true for a file with NUL bytes (fonts, images), which holds no code
    def binary?(path)
      File.binread(path, 8192).include?("\0")
    end

    # Blank comments and simple string literals so rules see only code.
    # String contents become the single token S.
    # @param line [String]
    # @return [String]
    def code_only(line)
      return "" if line.lstrip.start_with?("#")

      line.gsub(/"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/, "S").sub(/\s#\s.*\z/, "")
    end

    # @param text [String] file content
    # @param file [String] label for hits
    # @return [Array<Hit>]
    def model_name_hits(text, file)
      each_line(text).filter_map do |line, n|
        m = line.match(MODEL_RE)
        Hit.new(file: file, line: n, text: line.strip, rule: "model name #{m[0].downcase}") if m
      end
    end

    # @param text [String]
    # @param file [String] relative path; exec.rb may use Open3.popen3 only
    # @return [Array<Hit>]
    def shell_hits(text, file)
      in_exec = file == EXEC_FILE
      each_line(text).flat_map do |line, n|
        code = code_only(line)
        hits = SHELL_RULES.filter_map do |rule, re|
          next if in_exec && rule == "Open3" && code.match?(/\bOpen3\.popen3\(/) && !code.match?(/\bOpen3\.(?!popen3\()/)
          next unless code.match?(re)

          Hit.new(file: file, line: n, text: line.strip, rule: rule)
        end
        hits + RAW_SHELL_RULES.filter_map do |rule, re|
          Hit.new(file: file, line: n, text: line.strip, rule: rule) if line.match?(re) && !line.lstrip.start_with?("#")
        end
      end
    end

    # @param text [String]
    # @param file [String]
    # @return [Array<Hit>]
    def leak_hits(text, file)
      each_line(text).flat_map do |line, n|
        [[HOME_RE, "home path"], [SECRET_RE, "secret pattern"]].filter_map do |re, rule|
          Hit.new(file: file, line: n, text: line.strip[0, 120], rule: rule) if line.match?(re)
        end
      end
    end

    # @param text [String]
    # @param file [String]
    # @return [Array<Hit>]
    def require_hits(text, file)
      each_line(text).filter_map do |line, n|
        m = line.match(REQUIRE_RE)
        next unless m

        lit = m[:arg].strip.match(/\A["']([^"']+)["']\)?\s*(?:if|unless|\z)/)
        rule = if lit.nil? then "dynamic require"
               elsif !REQUIRE_ALLOW.include?(lit[1]) then "require #{lit[1]} not in allowlist"
               end
        Hit.new(file: file, line: n, text: line.strip, rule: rule) if rule
      end
    end

    # @param text [String]
    # @return [Enumerator] of [line, 1-based number]
    def each_line(text)
      text.each_line.with_index(1)
    end
  end
end
