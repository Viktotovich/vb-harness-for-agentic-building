# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "time"

module Harness
  # Append-only action log at logs/YYYY-MM-DD.log (local date), one line per action
  # (port of REVIEWER src/log.js):
  #   <UTC ISO time> run=<id> task=<id> action=<what> outcome=<result> detail="<short text>"
  # Details are single-line, capped and token-scrubbed, so a diff or a credential cannot land in a log.
  class Log
    TOKEN_PATTERNS = [
      /\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
      /\bgithub_pat_[A-Za-z0-9_]{20,}\b/,
      /\b(?:Bearer|token)\s+[A-Za-z0-9._-]{16,}/i,
      /\bsk-[A-Za-z0-9-]{16,}\b/
    ].freeze
    MAX_DETAIL = 400

    # @param text [Object]
    # @return [String] text with token-shaped substrings replaced by [REDACTED]
    def self.redact(text)
      TOKEN_PATTERNS.reduce(text.to_s) { |s, re| s.gsub(re, "[REDACTED]") }
    end

    # @param dir [String] log directory, created on first write
    # @param clock [#call] returns the current Time
    # @param echo [IO, nil] also print each line here (the CLI passes $stderr)
    def initialize(dir:, clock: -> { Time.now }, echo: nil)
      @dir = dir
      @clock = clock
      @echo = echo
    end

    # @param action [String]
    # @param outcome [String]
    # @param detail [String]
    # @param run [String]
    # @param task [String]
    # @return [String] the line written
    def write(action:, outcome:, detail: "", run: "-", task: "-")
      t = @clock.call
      clean = self.class.redact(detail).gsub(/[\r\n\t]+/, " ")[0, MAX_DETAIL].tr('"', "'")
      line = "#{t.utc.iso8601(3)} run=#{run} task=#{task} action=#{action} outcome=#{outcome}"
      line += " detail=\"#{clean}\"" unless clean.empty?
      FileUtils.mkdir_p(@dir)
      File.write(File.join(@dir, "#{t.strftime('%Y-%m-%d')}.log"), "#{line}\n", mode: "a", encoding: "UTF-8")
      @echo&.puts(line)
      line
    end
  end
end
