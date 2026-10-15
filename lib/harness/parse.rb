# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "errors"

module Harness
  # Small checks shared by every parser. Each raises ParseError naming the exact path,
  # e.g. "profiles.default.maxOutputTokens: expected integer >= 16, got \"lots\"".
  module Parse
    module_function

    # @param value [Object]
    # @param path [String]
    # @return [Hash]
    # @raise [ParseError]
    def hash!(value, path)
      fail!(path, "object", value) unless value.is_a?(Hash)
      value
    end

    # @param value [Object]
    # @param path [String]
    # @param min [Integer, nil]
    # @return [Integer]
    # @raise [ParseError]
    def int!(value, path, min: nil)
      ok = value.is_a?(Integer) && (min.nil? || value >= min)
      fail!(path, min ? "integer >= #{min}" : "integer", value) unless ok
      value
    end

    # @param value [Object]
    # @param path [String]
    # @return [String]
    # @raise [ParseError]
    def str!(value, path)
      fail!(path, "non-empty string", value) unless value.is_a?(String) && !value.strip.empty?
      value
    end

    # @param value [Object]
    # @param path [String]
    # @return [Boolean]
    # @raise [ParseError]
    def bool!(value, path)
      fail!(path, "true or false", value) unless [true, false].include?(value)
      value
    end

    # @param value [Object]
    # @param path [String]
    # @param allowed [Array<String>]
    # @return [String]
    # @raise [ParseError]
    def enum!(value, path, allowed)
      fail!(path, "one of #{allowed.join(', ')}", value) unless allowed.include?(value)
      value
    end

    # @param value [Object]
    # @param path [String]
    # @return [Array<String>]
    # @raise [ParseError]
    def strings!(value, path)
      fail!(path, "array of strings", value) unless value.is_a?(Array) && value.all?(String)
      value
    end

    # @param hash [Hash]
    # @param allowed [Array<String>]
    # @param path [String] prefix for the message; "" at the top level
    # @return [void]
    # @raise [ParseError] on a key not in allowed (keys starting with "_" are comments and ignored)
    def known_keys!(hash, allowed, path)
      extra = hash.keys.reject { |k| allowed.include?(k) || k.to_s.start_with?("_") }
      return if extra.empty?

      raise ParseError, "#{join(path, extra.first)}: unknown key (allowed: #{allowed.join(', ')})"
    end

    # @param path [String]
    # @param key [String, Integer]
    # @return [String]
    def join(path, key)
      return "#{path}[#{key}]" if key.is_a?(Integer)

      path.empty? ? key.to_s : "#{path}.#{key}"
    end

    # @param path [String]
    # @param expected [String]
    # @param value [Object]
    # @raise [ParseError] always
    def fail!(path, expected, value)
      shown = value.nil? ? "nil" : value.inspect
      shown = "#{shown[0, 60]}..." if shown.length > 60
      raise ParseError, "#{path}: expected #{expected}, got #{shown}"
    end
  end
end
