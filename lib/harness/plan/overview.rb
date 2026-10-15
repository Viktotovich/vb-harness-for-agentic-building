# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../model/tokens"
require_relative "../repo/map"
require_relative "../repo/paths"
require_relative "../untrusted"

module Harness
  module Plan
    # The planner's view of the repository (DESIGN.md 5.3), from the context map: the file tree, the full text
    # of files whose path matches a word of the request, then signatures and summaries of their neighbours in
    # the import graph, packed to the budget.
    module Overview
      MAX_FILES = 400
      MAX_SUMMARIES = 8

      # @param root [String] worktree root
      # @param request [String] the feature request
      # @param budget [Integer] tokens for the whole overview
      # @param protected [Array<String>]
      # @param map [Repo::Map, nil] built here when not given
      # @param summarize [#call, nil] (path, content) -> one sentence; nil uses cached summaries only
      # @return [Array<String>] prompt sections, each fenced
      def self.sections(root:, request:, budget:, protected:, map: nil, summarize: nil)
        map ||= Repo::Map.new(root: root, protected: protected)
        paths = map.paths
        tree = paths.first(MAX_FILES).map { |rel| "#{rel} (#{map[rel].bytes} bytes)#{route(map[rel])}" }
        tree << "... and #{paths.size - MAX_FILES} more files" if paths.size > MAX_FILES
        out = ["Files in the repository:\n#{Untrusted.fence(tree.join("\n"))}"]
        used = Model::Tokens.estimate(out.first)
        add = lambda do |text|
          cost = Model::Tokens.estimate(text)
          next false if used + cost > budget

          out << text
          used += cost
          true
        end
        words = request.downcase.scan(/[a-z][a-z0-9]{3,}/).uniq
        named = paths.select { |rel| words.any? { |w| rel.downcase.include?(w) } }
        named.each { |rel| (text = file_section(root, rel, protected)) && add.call(text) }
        near = named.flat_map { |rel| map.related(rel, depth: 2) }.uniq - named
        near.each { |rel| add.call("Signature of #{rel}:\n#{Untrusted.fence(map.signature(rel))}") }
        lines = near.first(MAX_SUMMARIES).filter_map do |rel|
          text = summarize ? map.summary(rel) { |p, c| summarize.call(p, c) } : map.summary(rel)
          "#{rel}: #{text}" if text
        end
        add.call("Summaries of related files:\n#{Untrusted.fence(lines.join("\n"))}") unless lines.empty?
        out
      end

      # @return [String]
      def self.route(entry)
        entry.route ? ", route #{entry.route}" : ""
      end

      # @return [String, nil]
      def self.file_section(root, rel, protected)
        full = Repo::Paths.resolve_in_worktree(root, rel, protected: protected)
        "File #{rel}:\n#{Untrusted.fence(File.read(full, mode: 'rb').force_encoding(Encoding::UTF_8).scrub)}"
      rescue PathError
        nil
      end
      private_class_method :file_section, :route
    end
  end
end
