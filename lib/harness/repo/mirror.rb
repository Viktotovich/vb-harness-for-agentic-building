# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require "find"

module Harness
  module Repo
    # Mirrors a git-ignored dependency folder (node_modules) from the user's repository into a worktree, so the
    # project's own tools can run there. Files are hard links where the file system allows them (fast, no extra
    # space) and copies otherwise; symlinks are recreated, or copied when that is not allowed. The user's folder
    # is only read. Nothing is installed (I10).
    module Mirror
      # Tool caches inside a dependency folder: rebuilt by the tools themselves, and they change while tools run.
      CACHES = %w[.vite .cache .astro .turbo].freeze

      # What a mirror did: files mirrored, and files that could not be (gone, unreadable or a path too long).
      Result = Data.define(:files, :skipped)

      # @param from [String] the folder in the user's repository
      # @param to [String] the same folder in the worktree
      # @return [Result, nil] nil when there is nothing to mirror or the target exists
      def self.link(from, to)
        return nil unless File.directory?(from) && !File.symlink?(from)
        return nil if File.exist?(to)

        base = File.expand_path(from)
        files = 0
        skipped = []
        Find.find(base) do |path|
          rel = path.delete_prefix(base).delete_prefix("/")
          Find.prune if File.directory?(path) && CACHES.include?(File.basename(path)) && !rel.empty?
          dest = rel.empty? ? to : File.join(to, rel)
          begin
            if File.symlink?(path)
              relink(path, dest)
              files += 1
            elsif File.directory?(path)
              FileUtils.mkdir_p(dest)
            elsif File.file?(path)
              hard_link(path, dest)
              files += 1
            end
          rescue SystemCallError, IOError
            skipped << rel
          end
        end
        Result.new(files: files, skipped: skipped)
      end

      # @return [void]
      def self.hard_link(path, dest)
        File.link(path, dest)
      rescue SystemCallError, NotImplementedError
        FileUtils.cp(path, dest, preserve: true)
      end

      # @return [void]
      def self.relink(path, dest)
        File.symlink(File.readlink(path), dest)
      rescue SystemCallError, NotImplementedError
        real = File.realpath(path)
        File.directory?(real) ? FileUtils.cp_r(real, dest) : FileUtils.cp(real, dest)
      end
      private_class_method :hard_link, :relink
    end
  end
end
