# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "minitest/autorun"
require_relative "../lib/harness"

module TestSupport
  ROOT = File.expand_path("..", __dir__)

  # Minimal output stream for code that only calls puts (stringio is not on the I14 allowlist).
  class Sink
    # @return [String] everything written so far
    attr_reader :string

    def initialize
      @string = +""
    end

    # @param lines [Array<Object>]
    # @return [nil]
    def puts(*lines)
      lines = [""] if lines.empty?
      lines.flatten.each { |l| @string << l.to_s << (l.to_s.end_with?("\n") ? "" : "\n") }
      nil
    end
  end

  # @return [Hash{String=>String}] a minimal environment for test subprocesses
  def self.child_env
    %w[PATH PATHEXT SystemRoot COMSPEC TEMP TMP TMPDIR HOME USERPROFILE LANG].each_with_object({}) do |k, env|
      env[k] = ENV[k] if ENV[k]
    end
  end
end
