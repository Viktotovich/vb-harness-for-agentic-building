# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "time"
require_relative "../errors"

module Harness
  module State
    # Notes from the user to a running agent-mode run, in runs/<runId>/notes.jsonl: steering ("use the existing
    # Button component") and answers to an agent's question. Written by `harness steer` and the app, read by the
    # run between agent turns. A note is the user's own words, so the agent sees it as an instruction, not as
    # untrusted data.
    class Notes
      MAX_CHARS = 4000

      # @param dir [String] the run's folder
      def initialize(dir)
        @path = File.join(dir, "notes.jsonl")
      end

      # @param text [String]
      # @param clock [#call]
      # @return [Integer] the note's number
      # @raise [ParseError] for an empty note
      def add(text, clock: -> { Time.now })
        text = text.to_s.strip
        raise ParseError, "the note is empty" if text.empty?

        # Numbered under the lock, so two notes sent at once (the app and harness steer) never share a number.
        File.open(@path, "a+", encoding: "UTF-8") do |f|
          f.flock(File::LOCK_EX)
          f.rewind
          seq = f.each_line.count + 1
          f.seek(0, IO::SEEK_END)
          f.puts(JSON.generate({ "seq" => seq, "at" => clock.call.utc.iso8601, "text" => text[0, MAX_CHARS] }))
          seq
        end
      end

      # @param after [Integer] notes with a higher number only
      # @return [Array<Hash>] {"seq", "at", "text"}
      def read(after: 0)
        return [] unless File.file?(@path)

        File.readlines(@path, encoding: "UTF-8").filter_map do |line|
          note = JSON.parse(line)
          note if note.is_a?(Hash) && note["seq"].to_i > after
        rescue JSON::ParserError
          nil
        end
      end
    end
  end
end
