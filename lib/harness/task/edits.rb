# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"
require_relative "../errors"
require_relative "../parse"
require_relative "../repo/paths"

module Harness
  module Task
    # One file edit from the implementer or fixer (DESIGN.md 5.4 step 2).
    Edit = Data.define(:op, :path, :content, :search, :replace)

    # The implementer's reply: edits, test edits and untrusted notes.
    EditSet = Data.define(:edits, :tests, :notes) do
      # @return [Array<Edit>] edits followed by tests
      def all
        edits + tests
      end
    end

    # Parsing for EditSet.
    class EditSet
      OPS = %w[create replace delete].freeze
      EDIT_SCHEMA = {
        "type" => "object", "required" => %w[op path],
        "properties" => { "op" => { "type" => "string", "enum" => OPS }, "path" => { "type" => "string" },
                          "content" => { "type" => "string" }, "search" => { "type" => "string" },
                          "replace" => { "type" => "string" } }
      }.freeze
      # JSON schema of the implementer's and fixer's reply, sent to the server or put into the prompt.
      SCHEMA = {
        "type" => "object", "required" => ["edits"],
        "properties" => { "edits" => { "type" => "array", "items" => EDIT_SCHEMA },
                          "tests" => { "type" => "array", "items" => EDIT_SCHEMA }, "notes" => { "type" => "string" } }
      }.freeze

      # @param raw [Hash] model JSON
      # @return [EditSet]
      # @raise [ParseError] with the exact path, e.g. "edits[1].search: expected non-empty string, got nil"
      def self.parse(raw)
        h = Parse.hash!(raw, "reply")
        Parse.known_keys!(h, %w[edits tests notes], "")
        edits = parse_list(h.fetch("edits", nil), "edits")
        tests = parse_list(h.fetch("tests", []), "tests")
        notes = h["notes"].nil? ? "" : h["notes"]
        Parse.fail!("notes", "string", notes) unless notes.is_a?(String)
        raise ParseError, "edits: the reply contains no edits" if edits.empty? && tests.empty?

        new(edits: edits.freeze, tests: tests.freeze, notes: notes)
      end

      # @return [Array<Edit>]
      def self.parse_list(raw, path)
        Parse.fail!(path, "array", raw) unless raw.is_a?(Array)
        raw.each_with_index.map { |e, i| parse_edit(e, "#{path}[#{i}]") }
      end

      # @return [Edit]
      def self.parse_edit(raw, path)
        h = Parse.hash!(raw, path)
        op = Parse.enum!(h["op"], "#{path}.op", OPS)
        allowed = { "create" => %w[op path content], "replace" => %w[op path search replace], "delete" => %w[op path] }
        Parse.known_keys!(h, allowed.fetch(op), path)
        file = Parse.str!(h["path"], "#{path}.path")
        case op
        when "create"
          Parse.fail!("#{path}.content", "string", h["content"]) unless h["content"].is_a?(String)
          Edit.new(op: op, path: file, content: h["content"], search: nil, replace: nil)
        when "replace"
          Parse.fail!("#{path}.replace", "string", h["replace"]) unless h["replace"].is_a?(String)
          Edit.new(op: op, path: file, content: nil, search: Parse.str!(h["search"], "#{path}.search"), replace: h["replace"])
        else
          Edit.new(op: op, path: file, content: nil, search: nil, replace: nil)
        end
      end
      private_class_method :parse_list, :parse_edit
    end

    # Applies an EditSet to the worktree, all or nothing (DESIGN.md 5.4 step 3).
    module Edits
      # A refused edit, with a reason code from DESIGN.md 10.3 and a message for the model.
      Rejection = Data.define(:edit, :reason, :message)
      # written: relative paths changed; created: relative paths that did not exist before.
      Result = Data.define(:written, :created, :rejections) do
        # @return [Boolean]
        def ok?
          rejections.empty?
        end
      end

      # @param root [String] worktree root
      # @param edit_set [EditSet]
      # @param modify [Array<String>] the task's files.modify
      # @param create [Array<String>] the task's files.create (plus test paths it may write)
      # @param protected [Array<String>] protectedPaths globs
      # @param rewrite_max_bytes [Integer] wholeFileRewriteMaxBytes
      # @return [Result] nothing is written unless every edit is accepted
      def self.apply(root:, edit_set:, modify:, create:, protected: [], rewrite_max_bytes: 4096)
        declared_modify = modify.filter_map { |p| declared_path(p) }
        declared = (declared_modify + create.filter_map { |p| declared_path(p) }).uniq
        files = {}       # rel => {full:, before: String|nil, after: String|nil, eol:}
        rejections = []
        edit_set.all.each do |edit|
          rejection = stage(edit, root, files, declared, declared_modify, protected, rewrite_max_bytes)
          rejections << rejection if rejection
        end
        return Result.new(written: [], created: [], rejections: rejections) unless rejections.empty?

        write_all(files)
        changed = files.reject { |_, f| f[:before] == f[:after] }
        Result.new(written: changed.keys.sort, created: changed.select { |_, f| f[:before].nil? }.keys.sort, rejections: [])
      end

      # A declared path in normalized form; an invalid one declares nothing (plan checks report it).
      # @return [String, nil]
      def self.declared_path(path)
        Repo::Paths.normalize(path)
      rescue PathError
        nil
      end

      # Check one edit and apply it to the in-memory copy.
      # @return [Rejection, nil]
      def self.stage(edit, root, files, declared, declared_modify, protected, rewrite_max_bytes)
        rel = Repo::Paths.normalize(edit.path)
        full = Repo::Paths.resolve_in_worktree(root, rel, protected: protected)
        unless declared.include?(rel)
          return Rejection.new(edit: edit, reason: "edit.undeclared_path",
                               message: "#{rel} is not one of this task's files (#{declared.join(', ')}); the plan must list it")
        end
        f = files[rel] ||= load(full).merge(root: root, rel: rel, protected: protected)
        case edit.op
        when "create" then stage_create(edit, rel, f, declared_modify, rewrite_max_bytes)
        when "replace" then stage_replace(edit, rel, f)
        else stage_delete(edit, rel, f)
        end
      rescue PathError => e
        Rejection.new(edit: edit, reason: e.reason, message: e.message)
      end

      # @return [Hash]
      def self.load(full)
        raise PathError.new("#{File.basename(full)} is a directory", reason: "edit.outside_worktree") if File.directory?(full)

        before = File.file?(full) ? File.binread(full).force_encoding(Encoding::UTF_8) : nil
        eol = before&.include?("\r\n") ? "\r\n" : "\n"
        { full: full, before: before, after: before, eol: eol }
      end

      # @return [Rejection, nil]
      def self.stage_create(edit, rel, f, declared_modify, rewrite_max_bytes)
        if f[:after]
          small = f[:before].nil? || f[:before].bytesize < rewrite_max_bytes
          unless small && declared_modify.include?(rel)
            return Rejection.new(edit: edit, reason: "edit.create_exists",
                                 message: "#{rel} already exists; use replace edits (whole-file rewrites are allowed only " \
                                          "for files under #{rewrite_max_bytes} bytes listed in files.modify)")
          end
        end
        f[:after] = f[:before].nil? ? edit.content : edit.content.gsub(/\r?\n/, f[:eol])
        nil
      end

      # search must match exactly once; only line endings are normalized.
      # @return [Rejection, nil]
      def self.stage_replace(edit, rel, f)
        if f[:after].nil?
          return Rejection.new(edit: edit, reason: "edit.search_not_found", message: "#{rel} does not exist")
        end

        text = f[:after].gsub("\r\n", "\n")
        search = edit.search.gsub("\r\n", "\n")
        count = occurrences(text, search)
        return mismatch(edit, rel, text, search, count) unless count == 1

        replaced = text.sub(search) { edit.replace.gsub("\r\n", "\n") }
        f[:after] = f[:eol] == "\n" ? replaced : replaced.gsub("\n", f[:eol])
        nil
      end

      # @return [Rejection, nil]
      def self.stage_delete(edit, rel, f)
        return Rejection.new(edit: edit, reason: "edit.search_not_found", message: "#{rel} does not exist") if f[:after].nil?

        f[:after] = nil
        nil
      end

      # @return [Integer] occurrences, overlapping ones included
      def self.occurrences(text, search)
        count = 0
        pos = 0
        while (i = text.index(search, pos))
          count += 1
          pos = i + 1
        end
        count
      end

      # @return [Rejection]
      def self.mismatch(edit, rel, text, search, count)
        if count.zero?
          Rejection.new(edit: edit, reason: "edit.search_not_found",
                        message: "search text matched 0 times in #{rel}. Closest lines:\n#{closest_lines(text, search)}")
        else
          Rejection.new(edit: edit, reason: "edit.search_ambiguous",
                        message: "search text matched #{count} times in #{rel}; include more surrounding lines so it matches once")
        end
      end

      # The file lines most similar to the first non-blank line of the search text.
      # @param text [String]
      # @param search [String]
      # @param limit [Integer]
      # @return [String] "  12: line" entries
      def self.closest_lines(text, search, limit: 3)
        wanted = search.lines.map(&:strip).find { |l| !l.empty? } || ""
        scored = text.lines.each_with_index.map { |line, i| [similarity(wanted, line.strip), i + 1, line.rstrip] }
        best = scored.select { |s, _, _| s.positive? }.max_by(limit) { |s, n, _| [s, -n] }
        return "  (no similar lines)" if best.empty?

        best.sort_by { |_, n, _| n }.map { |_, n, line| "  #{n}: #{line[0, 160]}" }.join("\n")
      end

      # Dice coefficient over character bigrams.
      # @return [Float] 0.0 to 1.0
      def self.similarity(a, b)
        return 0.0 if a.length < 2 || b.length < 2

        x = a.chars.each_cons(2).map(&:join).tally
        y = b.chars.each_cons(2).map(&:join).tally
        shared = x.sum { |bigram, n| [n, y.fetch(bigram, 0)].min }
        (2.0 * shared) / (a.length + b.length - 2)
      end

      # Write every changed file; on any failure restore what was already written, then raise.
      # @return [void]
      def self.write_all(files)
        done = []
        files.each_value do |f|
          next if f[:before] == f[:after]

          write_one(f)
          done << f
        end
      rescue SystemCallError, IOError, PathError
        done.each { |f| write_one(f.merge(after: f[:before])) }
        raise
      end

      # The I2 check runs again right before the write.
      # @return [void]
      def self.write_one(f)
        Repo::Paths.resolve_in_worktree(f[:root], f[:rel], protected: f[:protected])
        if f[:after].nil?
          FileUtils.rm_f(f[:full])
        else
          FileUtils.mkdir_p(File.dirname(f[:full]))
          File.binwrite(f[:full], f[:after])
        end
      end
      private_class_method :declared_path, :stage, :load, :stage_create, :stage_replace, :stage_delete, :occurrences, :mismatch,
                           :similarity, :write_all, :write_one
    end
  end
end
