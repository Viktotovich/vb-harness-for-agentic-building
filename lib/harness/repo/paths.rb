# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../errors"

module Harness
  module Repo
    # Path guard for every read tool and every write (I2, DESIGN.md 9.1).
    module Paths
      OUTSIDE = "edit.outside_worktree"
      PROTECTED = "edit.protected_path"
      FNM_FLAGS = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB | File::FNM_SYSCASE
      # Protected in every stack, whatever the config says: git's own data, and hook managers that git or a
      # package manager would run (I3).
      ALWAYS_PROTECTED = %w[.git .husky].freeze
      # Windows short (8.3) names such as GIT~1 alias a long name and could reach a protected path.
      SHORT_NAME = /~\d/

      # @param root [String] the worktree root
      # @param path [String] a relative path from a model, plan or config
      # @param protected [Array<String>] glob patterns relative to root (config protectedPaths)
      # @return [String] the absolute path inside the worktree
      # @raise [PathError] when the path is absolute, escapes the root (also through symlinks), or is protected
      def self.resolve_in_worktree(root, path, protected: [])
        rel = normalize(path)
        real_root = File.realpath(root)
        full = File.join(real_root, rel)
        check_real_location!(full, real_root, path)
        if protected?(rel, protected)
          raise PathError.new("#{path.inspect} is a protected path", reason: PROTECTED)
        end

        full
      end

      # Normalize a relative path: forward slashes, no "." segments, ".." resolved without leaving the root.
      # @param path [Object]
      # @return [String] e.g. "src/pages/index.astro"
      # @raise [PathError]
      def self.normalize(path)
        refuse!(path, "expected a non-empty relative path") unless path.is_a?(String) && !path.strip.empty?
        refuse!(path, "contains a NUL byte") if path.include?("\0")
        s = path.tr("\\", "/")
        refuse!(path, "absolute paths are refused") if s.start_with?("/", "~") || s.match?(/\A[A-Za-z]:/)
        parts = s.split("/").each_with_object([]) do |seg, acc|
          next if seg.empty? || seg == "."
          refuse!(path, "a path segment contains ':'") if seg.include?(":")
          # Windows drops trailing dots and spaces, so ".git." and ".git " name .git.
          refuse!(path, "a path segment ends with a dot or a space") if seg != ".." && seg.match?(/[. ]\z/)
          refuse!(path, "a path segment looks like a Windows short name (~N)") if seg.match?(SHORT_NAME)
          if seg == ".."
            refuse!(path, "escapes the worktree") if acc.empty?
            acc.pop
          else
            acc << seg
          end
        end
        refuse!(path, "names the worktree root itself") if parts.empty?
        parts.join("/")
      end

      # @param rel [String] normalized relative path
      # @param patterns [Array<String>]
      # @return [Boolean] true for .git, .husky and anything below them, or a match of any pattern
      def self.protected?(rel, patterns)
        first = rel.split("/").first.to_s
        return true if ALWAYS_PROTECTED.any? { |p| first.casecmp?(p) }

        patterns.any? do |pat|
          File.fnmatch?(pat, rel, FNM_FLAGS) ||
            (pat.end_with?("/**") && File.fnmatch?("#{pat}/*", rel, FNM_FLAGS))
        end
      end

      # The real path of the deepest existing ancestor (symlinks resolved) must stay inside the root.
      # @return [void]
      # @raise [PathError]
      def self.check_real_location!(full, real_root, original)
        probe = full
        probe = File.dirname(probe) until File.exist?(probe) || File.symlink?(probe) || probe == real_root
        real = begin
          File.realpath(probe)
        rescue SystemCallError
          refuse!(original, "is a symlink whose target does not exist")
        end
        refuse!(original, "resolves outside the worktree") unless inside?(real, real_root)
      end

      # @return [Boolean]
      def self.inside?(real, real_root)
        a = real.tr("\\", "/")
        b = real_root.tr("\\", "/").chomp("/")
        a, b = a.downcase, b.downcase if File::ALT_SEPARATOR
        a == b || a.start_with?("#{b}/")
      end

      # @raise [PathError] always
      def self.refuse!(path, why)
        raise PathError.new("#{path.inspect[0, 120]}: #{why}", reason: OUTSIDE)
      end
      private_class_method :check_real_location!, :inside?, :refuse!
    end
  end
end
