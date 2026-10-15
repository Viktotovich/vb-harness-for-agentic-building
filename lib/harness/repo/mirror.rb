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
      # @param from [String] the folder in the user's repository
      # @param to [String] the same folder in the worktree
      # @return [Integer, nil] files mirrored, or nil when there is nothing to mirror or the target exists
      def self.link(from, to)
        return nil unless File.directory?(from) && !File.symlink?(from)
        return nil if File.exist?(to)

        base = File.expand_path(from)
        count = 0
        Find.find(base) do |path|
          rel = path.delete_prefix(base).delete_prefix("/")
          dest = rel.empty? ? to : File.join(to, rel)
          if File.symlink?(path)
            relink(path, dest)
            count += 1
          elsif File.directory?(path)
            FileUtils.mkdir_p(dest)
          elsif File.file?(path)
            hard_link(path, dest)
            count += 1
          end
        end
        count
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
