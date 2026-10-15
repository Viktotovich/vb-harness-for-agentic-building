# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "securerandom"
require "time"
require_relative "../errors"
require_relative "../state/records"

module Harness
  module UI
    # Chats saved as chats/<id>.json (git-ignored, DESIGN.md 11.3). A message has a role: "user", "assistant",
    # "note" (such as a model switch) or "build" (a Build-mode run, with its runId).
    class Chats
      ID = /\Ac\d{8}-\d{6}-\h{6}\z/
      TITLE_MAX = 60
      MAX_TEXT = 200_000

      # @param dir [String] the chats folder
      # @param clock [#call]
      def initialize(dir, clock: -> { Time.now })
        @dir = dir
        @clock = clock
        @mutex = Mutex.new
      end

      # @return [Array<Hash>] id, title and updated, newest first
      def list
        return [] unless File.directory?(@dir)

        Dir.glob(File.join(@dir, "*.json")).filter_map { |f| read_file(f) }
           .map { |c| c.slice("id", "title", "updated") }.sort_by { |c| c["updated"].to_s }.reverse
      end

      # @param model [Hash, nil] {"profile", "model"}
      # @return [Hash] the new chat
      def create(model: nil)
        now = @clock.call
        chat = { "id" => "c#{now.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(3)}", "title" => "New chat", "model" => model,
                 "messages" => [], "summary" => nil, "created" => now.utc.iso8601, "updated" => now.utc.iso8601 }
        save(chat)
      end

      # @param id [String]
      # @return [Hash]
      # @raise [ConfigError] for an unknown or malformed id
      def get(id)
        raise ConfigError, "no chat #{id.to_s[0, 40]}" unless id.is_a?(String) && id.match?(ID)

        read_file(path(id)) || raise(ConfigError, "no chat #{id}")
      end

      # Change a chat under the lock and save it.
      # @param id [String]
      # @yieldparam chat [Hash]
      # @return [Hash] the saved chat
      def update(id)
        @mutex.synchronize do
          chat = get(id)
          yield chat
          chat["updated"] = @clock.call.utc.iso8601
          save(chat)
        end
      end

      # @param id [String]
      # @param message [Hash]
      # @return [Integer] the message's index
      def append(id, message)
        index = nil
        update(id) do |chat|
          msg = message.merge("at" => @clock.call.utc.iso8601)
          msg["content"] = msg["content"].to_s[0, MAX_TEXT] if msg.key?("content")
          chat["messages"] << msg
          index = chat["messages"].size - 1
          if chat["title"] == "New chat" && msg["role"] == "user"
            first = msg["content"].to_s.gsub(/\s+/, " ").strip
            chat["title"] = first.size > TITLE_MAX ? "#{first[0, TITLE_MAX]}…" : first
          end
        end
        index
      end

      # @param id [String]
      # @param title [String]
      # @return [Hash]
      # @raise [ParseError]
      def rename(id, title)
        t = title.to_s.gsub(/\s+/, " ").strip
        raise ParseError, "a title of 1-#{TITLE_MAX * 2} characters" unless t.size.between?(1, TITLE_MAX * 2)

        update(id) { |c| c["title"] = t }
      end

      # @param id [String]
      # @return [void]
      def delete(id)
        get(id)
        @mutex.synchronize { File.delete(path(id)) }
      end

      private

      def path(id) = File.join(@dir, "#{id}.json")

      def save(chat)
        State.write_json(path(chat["id"]), chat)
        chat
      end

      def read_file(file)
        data = JSON.parse(File.read(file, encoding: "UTF-8"))
        data.is_a?(Hash) && data["id"].to_s.match?(ID) ? data : nil
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end
    end
  end
end
