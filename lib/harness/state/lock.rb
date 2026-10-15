# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "json"
require "time"

module Harness
  module State
    # One process per run (and so per worktree), ported from REVIEWER src/lock.js. A lock whose process is
    # gone, or which is older than 15 hours, is stale and taken over.
    module Lock
      STALE_SEC = 15 * 60 * 60

      # @param path [String] e.g. runs/<runId>/harness.lock
      # @param pid [Integer]
      # @param alive [#call] pid -> Boolean
      # @param now [#call] returns the current Time
      # @return [Proc, nil] release callback, or nil when another live process holds the lock
      def self.acquire(path, pid: Process.pid, alive: method(:alive?), now: -> { Time.now })
        FileUtils.mkdir_p(File.dirname(path))
        2.times do
          File.open(path, File::WRONLY | File::CREAT | File::EXCL) do |f|
            f.write(JSON.generate({ "pid" => pid, "at" => now.call.utc.iso8601 }))
          end
          return -> { FileUtils.rm_f(path) }
        rescue Errno::EEXIST
          return nil unless stale?(path, alive, now)

          FileUtils.rm_f(path)
        end
        nil
      end

      # @param pid [Integer]
      # @return [Boolean]
      def self.alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # @return [Boolean]
      def self.stale?(path, alive, now)
        holder = begin
          JSON.parse(File.read(path, encoding: "UTF-8"))
        rescue JSON::ParserError, Errno::ENOENT
          nil
        end
        pid = holder.is_a?(Hash) ? holder["pid"] : nil
        return true if pid.is_a?(Integer) && !alive.call(pid)

        now.call - File.mtime(path) > STALE_SEC
      rescue Errno::ENOENT
        true
      end
      private_class_method :stale?
    end
  end
end
