# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "find"
require "json"
require_relative "../state/records"
require_relative "text_index"

module Harness
  module Evidence
    # A searchable index of a local official docs checkout (English pages). Pages are split into sections at
    # headings, with file path and line range, so every excerpt can be checked by opening the file. The
    # documented version is read from the docs themselves, never from the folder name. Ported from REVIEWER
    # src/evidence/local-docs.js.
    class LocalDocs
      MAX_SECTION_CHARS = 4000
      CONTENT = "src/content/docs"
      SINCE = /<Since\s+v="(\d+\.\d+\.\d+)"\s*\/>/
      UPGRADE = %r{\Aen/guides/upgrade-to/v(\d+)\.mdx?\z}

      attr_reader :commit, :major, :documents_up_to, :sections

      # @param root [String] the docs checkout
      # @param cache_dir [String, nil] .cache/; the index is cached per docs commit
      # @return [LocalDocs, nil] nil when the checkout is missing
      def self.load(root:, cache_dir: nil)
        en = File.join(root, CONTENT, "en")
        return nil unless File.directory?(en)

        commit = read_commit(root)
        cache = cache_dir && commit != "unknown" ? File.join(cache_dir, "docs-local-#{commit[0, 12]}.json") : nil
        data = cache && File.file?(cache) ? JSON.parse(File.read(cache, encoding: "UTF-8")) : build(root, commit)
        State.write_json(cache, data) if cache && !File.file?(cache)
        new(data)
      end

      # @param data [Hash] "commit", "version" {"latestSince", "latestUpgradeGuide"}, "docs"
      def initialize(data)
        @commit = data["commit"]
        @documents_up_to = data.dig("version", "latestSince")
        @major = @documents_up_to.split(".").first.to_i
        @major = data.dig("version", "latestUpgradeGuide").to_i if @major.zero?
        @sections = data["docs"]
        @index = TextIndex.new(@sections)
      end

      # @param query [String]
      # @param k [Integer]
      # @return [Array<TextIndex::Hit>]
      def search(query, k = 5)
        @index.search(query, k)
      end

      # Split a page into heading sections with line ranges; headings inside code fences are not headings.
      # @param rel [String] path under src/content/docs
      # @param content [String]
      # @return [Array<Hash>]
      def self.sectionize(rel, content)
        lines = content.gsub("\r\n", "\n").split("\n", -1)
        title = (content[/^title:\s*(.+)$/, 1] || rel).sub(/\A['"]/, "").sub(/['"]\z/, "")
        slug = rel.sub(%r{\Aen/}, "").sub(/\.mdx?\z/, "").sub(%r{/index\z}, "")
        start = 0
        if lines[0] == "---"
          close = (1...lines.size).find { |i| lines[i] == "---" }
          start = close + 1 if close
        end
        sections = []
        heading = title
        flush = lambda do |from, to|
          body = lines[from...to].reject { |l| l.match?(/\Aimport\s.+from\s/) }.join("\n").strip
          next if body.size < 20

          sections << { "path" => rel, "slug" => slug, "title" => title, "heading" => heading,
                        "anchor" => heading == title ? "" : slugify(heading), "lineStart" => from + 1, "lineEnd" => to,
                        "text" => "#{heading}\n#{body}"[0, MAX_SECTION_CHARS] }
        end
        in_fence = false
        (start...lines.size).each do |i|
          in_fence = !in_fence if lines[i].match?(/\A\s*(?:\x60{3}|~~~)/)
          m = !in_fence && lines[i].match(/\A(\#{2,4})\s+(.+)\z/)
          next unless m

          flush.call(start, i)
          start = i
          heading = m[2].sub(/\{#[^}]+\}\s*\z/, "").strip
        end
        flush.call(start, lines.size)
        sections
      end

      # @param s [String]
      # @return [String] a docs anchor
      def self.slugify(s)
        s.downcase.delete("\x60").gsub(/[^a-z0-9\s:-]/, "").strip.gsub(/[\s:]+/, "-")
      end

      # @return [Hash]
      def self.build(root, commit)
        base = File.join(root, CONTENT)
        since = "0.0.0"
        upgrade = 0
        docs = []
        Find.find(File.join(base, "en")) do |path|
          next unless File.file?(path) && path.match?(/\.mdx?\z/)

          rel = path.delete_prefix("#{base}/")
          content = File.read(path, encoding: "UTF-8").scrub
          content.scan(SINCE) { |(v)| since = v if (v.split(".").map(&:to_i) <=> since.split(".").map(&:to_i)).positive? }
          upgrade = [upgrade, rel[UPGRADE, 1].to_i].max
          docs.concat(sectionize(rel, content))
        end
        { "commit" => commit, "version" => { "latestSince" => since, "latestUpgradeGuide" => upgrade }, "docs" => docs }
      end

      # The checkout's HEAD commit, read from .git without running git.
      # @return [String]
      def self.read_commit(root)
        head = File.read(File.join(root, ".git", "HEAD")).strip
        return head if head.match?(/\A\h{40}\z/)

        ref = head.sub(/\Aref:\s*/, "")
        loose = File.join(root, ".git", *ref.split("/"))
        return File.read(loose).strip if File.file?(loose)

        line = File.read(File.join(root, ".git", "packed-refs")).lines.find { |l| l.strip.end_with?(" #{ref}") }
        line ? line.split(" ").first : "unknown"
      rescue SystemCallError
        "unknown"
      end
      private_class_method :build, :read_commit
    end
  end
end
