# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  # ASCII-only case handling for names that are ASCII by definition: HTTP header names, environment variable names,
  # path parts compared with a fixed list. Each works on a binary copy, so Ruby never runs the case mapping of a
  # legacy single-byte encoding (ISO-8859-x, Windows-125x). That code path held the ruby2shell heap overflow
  # (GHSA-34m4-m9fh-gqp5, Ruby 2.4 to 3.3.13, 3.4.12 and 4.0.9), reached by upcase, swapcase, downcase(:fold) and
  # casecmp?. lib/ calls those only through this module; test/ascii_test.rb scans for any other call.
  module Ascii
    # @param text [String, Symbol, nil]
    # @return [String] text with a-z turned into A-Z; every other byte unchanged; UTF-8 when the input was valid UTF-8
    def self.upcase(text)
      out = text.to_s.b.upcase
      utf8 = out.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : out
    end

    # @param text [String, Symbol, nil]
    # @return [String] text with its first byte upper-cased if it is a-z and the rest lower-cased (A-Z only)
    def self.capitalize(text)
      out = text.to_s.b.capitalize
      utf8 = out.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : out
    end

    # @param left [String, Symbol, nil]
    # @param right [String, Symbol, nil]
    # @return [Boolean] equal when A-Z and a-z are treated as the same; other bytes must match exactly
    def self.same?(left, right) = left.to_s.b.casecmp?(right.to_s.b)
  end
end
