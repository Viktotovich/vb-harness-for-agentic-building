# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"

module Harness
  module State
    # Writes runs/<runId>/records/<n>-<role>-<label>.json, one file per model attempt (DESIGN.md 10.1).
    # Records hold metadata only: never API keys or headers (I12).
    class Records
      FIELDS = %i[role label profile model prompt_hash usage ms finish_reason outcome error_class].freeze

      # @param dir [String] the records directory
      def initialize(dir)
        @dir = dir
        @count = 0
        @mutex = Mutex.new
      end

      # @param fields [Hash] keys from FIELDS; others are refused
      # @return [String] path of the record written
      # @raise [ArgumentError] on an unknown field
      def write(**fields)
        unknown = fields.keys - FIELDS
        raise ArgumentError, "record: unknown fields #{unknown.join(', ')}" unless unknown.empty?

        n = @mutex.synchronize { @count += 1 }
        name = format("%<n>04d-%<role>s-%<label>s.json", n: n, role: slug(fields[:role]), label: slug(fields[:label]))
        path = File.join(@dir, name)
        State.write_json(path, fields.transform_keys(&:to_s))
        path
      end

      private

      # @return [String]
      def slug(value)
        value.to_s.gsub(/[^A-Za-z0-9._-]+/, "_")[0, 60]
      end
    end

    # Atomic JSON write: <file>.tmp, then rename (DESIGN.md 10.1).
    # @param path [String]
    # @param data [Object] JSON-serializable
    # @return [void]
    def self.write_json(path, data)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.write(tmp, "#{JSON.pretty_generate(data)}\n", encoding: "UTF-8")
      File.rename(tmp, path)
    end
  end
end
