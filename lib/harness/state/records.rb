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
      FIELDS = %i[role label profile model prompt_hash usage ms finish_reason outcome error_class status error].freeze

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
      sharing_safe { File.write(tmp, "#{JSON.pretty_generate(data)}\n", encoding: "UTF-8") }
      sharing_safe { File.rename(tmp, path) }
    end

    # Read a JSON file that another thread may be replacing with write_json. On Windows the file can look missing
    # for a moment mid-rename; that is retried while the rename is visibly under way, a missing file raises at once.
    # @param path [String]
    # @param sleeper [#call] (seconds)
    # @return [Object]
    # @raise [Errno::ENOENT, JSON::ParserError, SystemCallError]
    def self.read_json(path, sleeper: ->(s) { sleep(s) })
      attempts = 0
      begin
        JSON.parse(sharing_safe(sleeper: sleeper) { File.read(path, encoding: "UTF-8") })
      rescue Errno::ENOENT
        attempts += 1
        raise if attempts > SHARING_RETRIES || !(File.exist?("#{path}.tmp") || File.exist?(path))

        sleeper.call(SHARING_PAUSE)
        retry
      end
    end

    SHARING_RETRIES = 100
    SHARING_PAUSE = 0.01

    # On Windows a rename over a file fails while another thread has it open, and opening it fails while the rename
    # is under way: both raise EACCES for a moment (the UI's event stream reads run.json while the run rewrites it).
    # Retry briefly; a lasting EACCES (a real permission problem) still raises.
    # @param sleeper [#call] (seconds)
    # @yieldreturn [Object]
    # @return [Object] the block's value
    # @raise [Errno::EACCES] when it lasts past the retries
    def self.sharing_safe(sleeper: ->(s) { sleep(s) })
      attempts = 0
      begin
        yield
      rescue Errno::EACCES
        attempts += 1
        raise if attempts > SHARING_RETRIES

        sleeper.call(SHARING_PAUSE)
        retry
      end
    end
  end
end
