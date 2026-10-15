# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "find"
require "json"
require "fileutils"
require_relative "../sha256"
require_relative "../state/records"
require_relative "filters"
require_relative "paths"
require_relative "source_parse"

module Harness
  module Repo
    # One file of the context map (DESIGN.md 5.2). imports holds resolved repository paths; route is set for
    # pages under src/pages; collections maps a content collection name to the file defining its schema.
    FileEntry = Data.define(:path, :bytes, :lang, :hash, :imports, :exports, :declarations, :props, :static_paths,
                            :collections, :route)

    # The context map: every source file's imports, exports and surface, the import graph and its reverse.
    # Incremental: parse results are cached in <cache_dir>/map/ by content hash, so a rescan reads files but
    # parses only the changed ones. Protected and filtered files are never in the map.
    class Map
      RESOLVE_EXTS = %w[.ts .tsx .js .jsx .mjs .astro .md .mdx .json].freeze
      ALIASES = { "~/" => "src/", "@/" => "src/" }.freeze
      MAX_BYTES = 1_000_000
      PAGES = "src/pages/"
      ROUTE_EXTS = %w[.astro .md .mdx .ts .js .html].freeze

      attr_reader :entries, :skipped

      # @param root [String] worktree root
      # @param cache_dir [String, nil] directory holding map/<sha256>.json; nil disables the cache
      # @param protected [Array<String>] protectedPaths patterns
      def initialize(root:, cache_dir: nil, protected: [])
        @root = File.realpath(root)
        @cache_dir = cache_dir && File.join(cache_dir, "map")
        @protected = protected
        scan
      end

      # Read the tree again, reparsing only files whose content changed.
      # @return [self]
      def scan
        @entries = {}
        @skipped = {}
        raw = {}
        each_file do |rel, content|
          reason = Filters.content_skip_reason(rel, content)
          next @skipped[rel] = reason if reason

          hash = Sha256.hex(content)
          facts = cached_facts(rel, content, hash)
          raw[rel] = [content.bytesize, hash, facts]
        end
        raw.each do |rel, (bytes, hash, facts)|
          imports = facts["imports"].filter_map { |spec| resolve(rel, spec, raw) }.uniq
          @entries[rel] = FileEntry.new(path: rel, bytes: bytes, lang: SourceParse.lang(rel), hash: hash, imports: imports,
                                        exports: facts["exports"], declarations: facts["declarations"],
                                        props: facts["props"], static_paths: facts["staticPaths"] == true,
                                        collections: facts["collections"] || [], route: route(rel))
        end
        build_reverse
        self
      end

      # @param path [String]
      # @return [FileEntry, nil]
      def [](path)
        @entries[path]
      end

      # @return [Array<String>] repository paths in the map, sorted
      def paths
        @entries.keys.sort
      end

      # @param path [String]
      # @return [Array<String>] files that import path
      def importers(path)
        @reverse.fetch(path, [])
      end

      # Files within depth steps of path in the import graph, either direction, nearest first.
      # @param path [String]
      # @param depth [Integer]
      # @return [Array<String>] without path itself; ties sorted by name
      def related(path, depth: 1)
        seen = { path => 0 }
        frontier = [path]
        depth.times do |d|
          frontier = frontier.flat_map { |p| neighbours(p) }.uniq.reject { |p| seen.key?(p) }.sort
          frontier.each { |p| seen[p] = d + 1 }
        end
        seen.except(path).sort_by { |p, d| [d, p] }.map(&:first)
      end

      # The surface of a file: what it exports and how, for prompts that need to use it without its body.
      # @param path [String]
      # @return [String, nil] nil for a file not in the map
      def signature(path)
        e = @entries[path]
        return nil unless e

        lines = ["#{e.path} (#{e.lang}, #{e.bytes} bytes)"]
        lines << "route: #{e.route}" if e.route
        lines << "getStaticPaths: yes" if e.static_paths
        lines << "imports: #{e.imports.join(', ')}" unless e.imports.empty?
        lines << "exports: #{e.exports.join(', ')}" unless e.exports.empty?
        lines << "content collections: #{e.collections.join(', ')}" unless e.collections.empty?
        lines << e.props if e.props
        lines.concat(e.declarations)
        lines.join("\n")
      end

      # @param name [String] an exported symbol
      # @return [Array<String>] files that export it, sorted
      def find_symbol(name)
        @entries.values.select { |e| e.exports.include?(name) }.map(&:path).sort
      end

      # @return [Hash{String=>String}] content collection name => file that defines it
      def collections
        @entries.values.flat_map { |e| e.collections.map { |c| [c, e.path] } }.sort.to_h
      end

      # A one-sentence summary of a file, made on first use and cached by content hash (DESIGN.md 5.2: lazily,
      # only for files the planner or the gatherer touches).
      # @param path [String]
      # @yieldparam path [String]
      # @yieldparam content [String]
      # @yieldreturn [String, nil] the summary, nil when none could be made
      # @return [String, nil] nil for a file not in the map, or when the block gave none
      def summary(path)
        e = @entries[path]
        return nil unless e

        file = @cache_dir && File.join(@cache_dir, "summary-#{e.hash}.txt")
        return File.read(file, encoding: "UTF-8") if file && File.file?(file)
        return nil unless block_given?

        text = yield(path, File.binread(File.join(@root, path)).force_encoding(Encoding::UTF_8).scrub)
        text = text.to_s.strip.lines.first.to_s.strip[0, 300]
        return nil if text.empty?

        if file
          FileUtils.mkdir_p(@cache_dir)
          File.write(file, text, encoding: "UTF-8")
        end
        text
      end

      private

      def each_file
        Find.find(@root) do |full|
          rel = full.delete_prefix("#{@root}/")
          if File.directory?(full)
            Find.prune if full != @root && Filters.skip_reason("#{rel}/")
            next
          end
          next if !File.file?(full) || Paths.protected?(rel, @protected)

          size = File.size(full)
          next @skipped[rel] = "too large" if size > MAX_BYTES

          yield rel, File.binread(full).force_encoding(Encoding::UTF_8).scrub
        end
      end

      def cached_facts(rel, content, hash)
        return SourceParse.parse(rel, content) unless @cache_dir

        key = Sha256.hex("#{SourceParse.lang(rel)}\0#{hash}")
        file = File.join(@cache_dir, "#{key}.json")
        if File.file?(file)
          begin
            return JSON.parse(File.read(file))
          rescue JSON::ParserError
            nil # a damaged cache entry is parsed again
          end
        end
        facts = SourceParse.parse(rel, content)
        FileUtils.mkdir_p(@cache_dir)
        State.write_json(file, facts)
        facts
      end

      # A relative or aliased specifier to a mapped path; packages and unknown files give nil.
      def resolve(from, spec, known)
        prefix = ALIASES.keys.find { |a| spec.start_with?(a) }
        base = if prefix then ALIASES[prefix] + spec.delete_prefix(prefix)
               elsif spec.start_with?(".") then File.join(File.dirname(from), spec)
               else return nil
               end
        target = File.expand_path(base.split("?").first, "/").delete_prefix("/").sub(/\A[A-Za-z]:\//, "")
        candidates = [target] + RESOLVE_EXTS.map { |x| target + x } + RESOLVE_EXTS.map { |x| "#{target}/index#{x}" }
        candidates << target.sub(/\.js\z/, ".ts") << target.sub(/\.jsx\z/, ".tsx") if target.match?(/\.jsx?\z/)
        candidates.find { |c| c != from && known.key?(c) }
      end

      def route(rel)
        return nil unless rel.start_with?(PAGES) && ROUTE_EXTS.include?(File.extname(rel))
        return nil if File.basename(rel).start_with?("_")

        path = rel.delete_prefix(PAGES).delete_suffix(File.extname(rel)).sub(%r{(?:\A|/)index\z}, "")
        "/#{path}"
      end

      def build_reverse
        @reverse = Hash.new { |h, k| h[k] = [] }
        @entries.each_value { |e| e.imports.each { |i| @reverse[i] << e.path } }
        @reverse.each_value(&:sort!)
        @reverse.default_proc = nil
      end

      def neighbours(path)
        ((@entries[path]&.imports || []) + importers(path)).uniq
      end
    end
  end
end
