# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "find"
require_relative "../model/tokens"
require_relative "../repo/paths"
require_relative "../untrusted"

module Harness
  module Plan
    # The planner's view of the repository until the context map (M5): the file list, and the full text of
    # files whose path matches a word of the request, packed to a share of the budget.
    module Overview
      SKIP_DIRS = %w[.git node_modules dist build .astro .next .cache coverage vendor .turbo out].freeze
      BINARY = /\.(?:png|jpe?g|gif|webp|avif|ico|svg|woff2?|ttf|otf|eot|mp4|webm|mp3|pdf|zip|gz|lock)\z/i
      MAX_FILES = 400

      # @param root [String] worktree root
      # @param request [String] the feature request
      # @param budget [Integer] tokens for the whole overview
      # @param protected [Array<String>]
      # @return [Array<String>] prompt sections, each fenced
      def self.sections(root:, request:, budget:, protected:)
        files = list(root)
        tree = files.first(MAX_FILES).map { |rel, bytes| "#{rel} (#{bytes} bytes)" }
        tree << "... and #{files.size - MAX_FILES} more files" if files.size > MAX_FILES
        out = ["Files in the repository:\n#{Untrusted.fence(tree.join("\n"))}"]
        used = Model::Tokens.estimate(out.first)
        words = request.downcase.scan(/[a-z][a-z0-9]{3,}/).uniq
        files.select { |rel, _| words.any? { |w| rel.downcase.include?(w) } }.each do |rel, _|
          text = file_section(root, rel, protected)
          next unless text

          cost = Model::Tokens.estimate(text)
          next if used + cost > budget

          out << text
          used += cost
        end
        out
      end

      # @return [Array<Array(String, Integer)>] relative paths and sizes, sorted
      def self.list(root)
        found = []
        base = File.realpath(root)
        Find.find(base) do |path|
          name = File.basename(path)
          if File.directory?(path)
            Find.prune if path != base && SKIP_DIRS.include?(name)
            next
          end
          rel = path.delete_prefix("#{base}/")
          found << [rel, File.size(path)] unless rel.match?(BINARY)
        end
        found.sort
      end

      # @return [String, nil]
      def self.file_section(root, rel, protected)
        full = Repo::Paths.resolve_in_worktree(root, rel, protected: protected)
        "File #{rel}:\n#{Untrusted.fence(File.read(full, mode: 'rb').force_encoding(Encoding::UTF_8).scrub)}"
      rescue PathError
        nil
      end
      private_class_method :file_section
    end
  end
end
