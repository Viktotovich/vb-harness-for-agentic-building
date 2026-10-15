# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../repo/filters"

module Harness
  module Review
    # One diff line. kind: "+", "-", " " or "@" (a hunk header); new_line / old_line are file line numbers.
    DiffLine = Data.define(:kind, :text, :old_line, :new_line)

    # One file of a diff. truncated counts the lines left out to fit.
    class DiffFile
      attr_accessor :path, :old_path, :lines, :binary, :deleted, :added, :truncated

      # @param path [String]
      def initialize(path)
        @path = path
        @old_path = nil
        @lines = []
        @binary = false
        @deleted = false
        @added = false
        @truncated = 0
      end

      # @return [Array<DiffLine>] lines without hunk headers
      def code
        @lines.reject { |l| l.kind == "@" }
      end
    end

    # chunks: each holds files and their rendered text; skipped and omitted: [path, reason] pairs.
    Prepared = Data.define(:chunks, :skipped, :omitted)
    Chunk = Data.define(:files, :text, :lines, :chars)

    # Unified diffs for review: parsing with per-line numbers, filtering, rendering and chunking. Ported from
    # REVIEWER src/review/diff.js.
    module Diff
      DOC_EXT = /\.(?:md|mdx|txt|rst)\z/i
      SOURCE_EXT = /\.(?:astro|[cm]?[jt]sx?|rb|erb|py|go|rs|java|kt|php|vue|svelte|sql|sh|ps1)\z/i
      MAX_LINE_LEN = 1000

      # @param text [String] git diff output
      # @return [Array<DiffFile>]
      def self.parse(text)
        files = []
        cur = nil
        old_ln = new_ln = 0
        text.to_s.gsub("\r\n", "\n").split("\n").each do |raw|
          if raw.start_with?("diff --git ")
            m = raw.match(%r{\Adiff --git "?a/(.+?)"? "?b/(.+?)"?\z})
            cur = DiffFile.new(m ? m[2] : raw[11..])
            files << cur
            next
          end
          next unless cur

          if raw.start_with?("@@")
            m = raw.match(/\A@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/)
            old_ln = m ? m[1].to_i : 0
            new_ln = m ? m[2].to_i : 0
            cur.lines << DiffLine.new(kind: "@", text: raw, old_line: nil, new_line: nil)
            next
          end
          if cur.lines.empty?
            header(cur, raw)
            next
          end
          case raw[0]
          when "+"
            cur.lines << DiffLine.new(kind: "+", text: raw[1..], old_line: nil, new_line: new_ln)
            new_ln += 1
          when "-"
            cur.lines << DiffLine.new(kind: "-", text: raw[1..], old_line: old_ln, new_line: nil)
            old_ln += 1
          when " ", nil
            cur.lines << DiffLine.new(kind: " ", text: raw[1..].to_s, old_line: old_ln, new_line: new_ln)
            old_ln += 1
            new_ln += 1
          when "\\" then next # "\ No newline at end of file"
          else cur.binary = true if raw.start_with?("Binary files", "GIT binary patch")
          end
        end
        files
      end

      # Why a diff file is not reviewed, or nil.
      # @param file [DiffFile]
      # @return [String, nil]
      def self.skip_reason(file)
        return "binary" if file.binary

        reason = Repo::Filters.skip_reason(file.path)
        return reason if reason
        return "deleted" if file.deleted
        return "minified (very long lines)" if file.lines.any? { |l| l.text.size > MAX_LINE_LEN }

        nil
      end

      # A line as the model sees it: the new-file number first, so it never does hunk arithmetic.
      # @param line [DiffLine]
      # @return [String]
      def self.render_line(line)
        return line.text if line.kind == "@"

        "#{line.new_line.to_s.rjust(5)} #{line.kind}#{line.text}"
      end

      # @param file [DiffFile]
      # @return [String]
      def self.render(file)
        status = if file.added then " (new file)"
                 elsif file.old_path && file.old_path != file.path then " (renamed from #{file.old_path})"
                 else ""
                 end
        body = file.lines.map { |l| render_line(l) }
        body << "... [truncated: #{file.truncated} more diff lines of this file were not shown]" if file.truncated.positive?
        ["### FILE: #{file.path}#{status}", *body].join("\n")
      end

      # Filter and pack a diff into chunks, source first and prose last.
      # @param text [String]
      # @param max_lines [Integer]
      # @param max_chars [Integer]
      # @param max_chunks [Integer]
      # @return [Prepared]
      def self.prepare(text, max_lines:, max_chars:, max_chunks:)
        skipped = []
        reviewable = []
        parse(text).each do |f|
          reason = skip_reason(f) || (f.lines.empty? ? "no textual changes" : nil)
          reason ? skipped << [f.path, reason] : reviewable << f
        end
        reviewable = reviewable.each_with_index.sort_by { |f, i| [tier(f.path), i] }.map(&:first)
        chunks = []
        omitted = []
        cur = nil
        reviewable.each do |f|
          rendered = render(f)
          if rendered.count("\n") + 1 > max_lines || rendered.size > max_chars
            truncate!(f, max_lines, max_chars)
            rendered = render(f)
          end
          lines = rendered.count("\n") + 1
          if cur.nil? || cur[:lines] + lines > max_lines || cur[:chars] + rendered.size + 1 > max_chars
            if chunks.size >= max_chunks
              omitted << [f.path, "size cap (max chunks reached)"]
              next
            end
            cur = { files: [], parts: [], lines: 0, chars: 0 }
            chunks << cur
          end
          cur[:files] << f
          cur[:parts] << rendered
          cur[:lines] += lines
          cur[:chars] += rendered.size + 1
        end
        Prepared.new(chunks: chunks.map { |c| Chunk.new(files: c[:files], text: c[:parts].join("\n"), lines: c[:lines], chars: c[:chars]) },
                     skipped: skipped, omitted: omitted)
      end

      # @return [void]
      def self.header(cur, raw)
        if raw.start_with?("+++ ")
          p = strip_prefix(raw[4..].strip)
          cur.path = p if p
        elsif raw.start_with?("--- ")
          cur.old_path = strip_prefix(raw[4..].strip)
        elsif raw.start_with?("deleted file mode")
          cur.deleted = true
        elsif raw.start_with?("new file mode")
          cur.added = true
        elsif raw.start_with?("Binary files", "GIT binary patch")
          cur.binary = true
        end
      end

      # @return [String, nil]
      def self.strip_prefix(p)
        return nil if p.nil? || p == "/dev/null"

        p.delete_prefix('"').delete_suffix('"').sub(%r{\A[ab]/}, "")
      end

      # @return [void]
      def self.truncate!(file, max_lines, max_chars)
        kept = []
        chars = 200
        file.lines.each do |l|
          len = render_line(l).size + 1
          break if kept.size + 3 >= max_lines || chars + len > max_chars

          kept << l
          chars += len
        end
        file.truncated = file.lines.size - kept.size
        file.lines = kept
      end

      # @return [Integer] 0 source, 1 config and data, 2 docs
      def self.tier(path)
        return 2 if path.match?(DOC_EXT)

        path.match?(SOURCE_EXT) ? 0 : 1
      end
      private_class_method :header, :strip_prefix, :truncate!, :tier
    end
  end
end
