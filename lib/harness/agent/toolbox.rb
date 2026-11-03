# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require "set"
require_relative "../errors"
require_relative "../gates/gate"
require_relative "../repo/atomic_file"
require_relative "../repo/filters"
require_relative "../repo/paths"
require_relative "../task/edits"
require_relative "../untrusted"
require_relative "settings"

module Harness
  module Agent
    # The tools an agent works with. Reading: read_file, list_dir, search, find_symbol. Writing (task agents only):
    # edit_file, write_file, append_file. Checking: run_gate (the stack's gates) and run_command (commands declared
    # in config, I3). Plus view_diff and finish. Every write goes through Task::Edits, so I2 and protectedPaths hold;
    # every result is fenced as untrusted (I9); no tool runs a command string a model wrote.
    class Toolbox
      READ_LINES = 200
      SEARCH_HITS = 40
      SEARCH_FILE_BYTES = 512 * 1024
      LIST_ENTRIES = 200
      # Whole-file rewrites an agent may make of an existing file: larger than the pipeline's, since the agent can
      # read the file first and its result is checked by the same gates.
      REWRITE_MAX_BYTES = 64 * 1024
      PARAM_WORD = %r{\A[A-Za-z0-9_.:/@][A-Za-z0-9_.:/@ -]{0,119}\z}

      # Every tool call, for the record and the events.
      Call = Data.define(:tool, :args, :ok, :outcome)

      # @return [Array<Call>]
      attr_reader :calls
      # @return [Set<String>] files written in this task, and those it created
      attr_reader :touched, :created
      # @return [String, nil] the agent's summary when it called finish
      attr_reader :finished

      # @param root [String] worktree root
      # @param protected [Array<String>]
      # @param runner [Gates::Runner, nil] nil: no gates or commands (investigation without them)
      # @param stack [Gates::Stack]
      # @param settings [Settings]
      # @param worktree [Repo::Worktree, nil] for view_diff
      # @param map [Repo::Map, nil] for find_symbol
      # @param writable [Boolean] false for the investigation agent
      # @param tests [Array<String>] the task's test files, for gates with {tests}
      def initialize(root:, protected:, stack:, settings:, runner: nil, worktree: nil, map: nil, writable: false, tests: [])
        @root = root
        @protected = protected
        @runner = runner
        @stack = stack
        @settings = settings
        @worktree = worktree
        @map = map
        @writable = writable
        @tests = tests
        @calls = []
        @touched = Set.new
        @created = Set.new
        @finished = nil
      end

      # @return [Array<Hash>] OpenAI tool definitions
      def definitions
        defs = [
          tool("read_file", "Read lines of a file in the repository (at most #{READ_LINES} per call; ask for the next range to read on).",
               { "path" => str, "start_line" => int, "end_line" => int }, %w[path]),
          tool("list_dir", "List the files and folders in a folder of the repository (\".\" for the top).", { "path" => str }, %w[path]),
          tool("search", "Find a piece of text in the repository's files. Returns path:line: text for each hit. Optional " \
                         "path limits it to a folder or file.", { "text" => str, "path" => str }, %w[text]),
          tool("find_symbol", "Find where a function, class, type, component or constant is defined.", { "name" => str }, %w[name])
        ]
        if @writable
          defs << tool("edit_file", "Replace one exact piece of text in an existing file. search must appear exactly once; read the " \
                                    "file first and copy it exactly.", { "path" => str, "search" => str, "replace" => str }, %w[path search replace])
          defs << tool("write_file", "Create a file, or rewrite an existing one whole (up to #{REWRITE_MAX_BYTES / 1024} KB). For a long " \
                                     "new file, write the first part here and add the rest with append_file.",
                       { "path" => str, "content" => str }, %w[path content])
          defs << tool("append_file", "Add text to the end of a file you created in this task.", { "path" => str, "content" => str }, %w[path content])
          defs << tool("view_diff", "Show your changes so far as a diff.", {}, [])
        end
        if @runner
          defs << tool("run_gate", "Run one of the project's checks on your changes: #{@stack.gates.keys.join(', ')}. Returns pass or " \
                                   "fail, the problems found and the end of the output.", { "name" => str }, %w[name])
          unless @settings.commands.empty?
            listing = @settings.commands.values.map { |c| "#{c.name}(#{c.params.keys.join(', ')}): #{c.description}" }.join("; ")
            defs << tool("run_command", "Run a command the project allows: #{listing}. Give its name and its parameters.",
                         { "name" => str, "params" => { "type" => "object" } }, %w[name])
          end
        end
        defs << tool("finish", @writable ? "Say you are done, with a short summary of what you changed and why. The harness then runs " \
                                           "the project's checks itself." : "Hand in your findings.",
                     { "summary" => str }, %w[summary])
        defs
      end

      # Run one tool call. Unknown tools and bad arguments get an error text, never an exception.
      # @param name [String]
      # @param args [Object]
      # @return [String] the fenced result
      def call(name, args)
        args = {} unless args.is_a?(Hash)
        text = dispatch(name.to_s, args)
        ok = !text.start_with?("error:")
        @calls << Call.new(tool: name.to_s[0, 40], args: args.transform_values { |v| v.to_s[0, 120] }, ok: ok,
                           outcome: text.lines.first.to_s.strip[0, 160])
        Untrusted.fence(text)
      rescue PathError => e
        @calls << Call.new(tool: name.to_s[0, 40], args: {}, ok: false, outcome: e.message[0, 160])
        Untrusted.fence("error: #{e.message}")
      end

      # Forget a finish, when the harness sends the agent back to work.
      # @return [void]
      def reset_finish
        @finished = nil
      end

      # @return [Boolean] whether the tool writes files
      def self.write_tool?(name) = %w[edit_file write_file append_file].include?(name)

      private

      def dispatch(name, args)
        case name
        when "read_file" then read_file(args["path"], args["start_line"], args["end_line"])
        when "list_dir" then list_dir(args["path"])
        when "search" then search(args["text"], args["path"])
        when "find_symbol" then find_symbol(args["name"])
        when "edit_file" then writable { edit_file(args["path"], args["search"], args["replace"]) }
        when "write_file" then writable { write_file(args["path"], args["content"]) }
        when "append_file" then writable { append_file(args["path"], args["content"]) }
        when "view_diff" then writable { view_diff }
        when "run_gate" then run_gate(args["name"])
        when "run_command" then run_command(args["name"], args["params"])
        when "finish"
          @finished = args["summary"].to_s.strip.empty? ? "(no summary)" : args["summary"].to_s[0, 4000]
          "finished"
        else "error: unknown tool #{name[0, 40].inspect}"
        end
      end

      def writable
        @writable ? yield : "error: this agent only reads; it cannot change files"
      end

      def tool(name, description, properties, required)
        { "type" => "function", "function" => { "name" => name, "description" => description,
                                                 "parameters" => { "type" => "object", "properties" => properties, "required" => required } } }
      end

      def str = { "type" => "string" }
      def int = { "type" => "integer" }

      # --- reading ---

      def read_file(path, from, to)
        full = Repo::Paths.resolve_in_worktree(@root, path.to_s, protected: @protected)
        return "error: #{path} does not exist" unless File.file?(full)

        lines = File.binread(full).force_encoding(Encoding::UTF_8).scrub.lines
        from = [from.to_i, 1].max
        to = to.to_i.zero? ? from + READ_LINES - 1 : to.to_i
        to = [[to, from].max, from + READ_LINES - 1, lines.size].min
        return "#{path}: empty file" if lines.empty?
        return "error: #{path} has #{lines.size} lines" if from > lines.size

        body = lines[(from - 1)..(to - 1)].each_with_index.map { |l, i| "#{(from + i).to_s.rjust(5)}  #{l.chomp}" }
        more = to < lines.size ? "\n(#{lines.size - to} more lines; read on from line #{to + 1})" : ""
        "#{path} lines #{from}-#{to} of #{lines.size}:\n#{body.join("\n")}#{more}"
      end

      def list_dir(path)
        rel = path.to_s.strip.empty? || path.to_s.strip == "." ? "" : Repo::Paths.normalize(path.to_s)
        full = rel.empty? ? File.realpath(@root) : Repo::Paths.resolve_in_worktree(@root, rel, protected: @protected)
        return "error: #{path} is not a folder" unless File.directory?(full)

        entries = Dir.children(full).sort.reject { |e| e == ".git" || generated?(rel.empty? ? e : "#{rel}/#{e}") }
        lines = entries.first(LIST_ENTRIES).map { |e| File.directory?(File.join(full, e)) ? "#{e}/" : e }
        more = entries.size > LIST_ENTRIES ? "\n(#{entries.size - LIST_ENTRIES} more)" : ""
        "#{rel.empty? ? '.' : rel}:\n#{lines.join("\n")}#{more}"
      end

      def search(text, path)
        needle = text.to_s
        return "error: give the text to search for (at least 2 characters)" if needle.strip.length < 2

        base = path.to_s.strip.empty? ? "" : Repo::Paths.normalize(path.to_s)
        hits = []
        files(base).each do |rel|
          File.binread(File.join(@root, rel)).force_encoding(Encoding::UTF_8).scrub.each_line.with_index(1) do |line, n|
            next unless line.include?(needle)

            hits << "#{rel}:#{n}: #{line.chomp[0, 200]}"
            break if hits.size >= SEARCH_HITS
          end
          break if hits.size >= SEARCH_HITS
        end
        return "no match for #{needle[0, 80].inspect}#{base.empty? ? '' : " in #{base}"}" if hits.empty?

        "#{hits.size}#{hits.size >= SEARCH_HITS ? '+' : ''} matches:\n#{hits.join("\n")}"
      end

      def find_symbol(name)
        name = name.to_s.strip
        return "error: give a symbol name" unless name.match?(/\A[A-Za-z_$][\w$]{0,80}\z/)

        if @map
          found = @map.find_symbol(name)
          return found.first(3).map { |rel| @map.signature(rel) }.join("\n\n") unless found.empty?
        end
        defs = search_definitions(name)
        defs.empty? ? "#{name}: no definition found" : defs.join("\n")
      end

      # Lines that look like a definition of name, for stacks without a context map.
      # @return [Array<String>]
      def search_definitions(name)
        pattern = /\b(?:def|class|module|function|const|let|var|type|interface|enum|struct|fn|func)\s+#{Regexp.escape(name)}\b/
        out = []
        files("").each do |rel|
          File.binread(File.join(@root, rel)).force_encoding(Encoding::UTF_8).scrub.each_line.with_index(1) do |line, n|
            out << "#{rel}:#{n}: #{line.strip[0, 200]}" if line.match?(pattern)
          end
          break if out.size >= 10
        end
        out.first(10)
      end

      # Text files under base, generated folders and protected paths left out.
      # @return [Array<String>]
      def files(base)
        root = File.realpath(@root)
        start = base.empty? ? root : Repo::Paths.resolve_in_worktree(@root, base, protected: @protected)
        return [base] if File.file?(start)

        Dir.glob("**/*", File::FNM_DOTMATCH, base: start).filter_map do |r|
          rel = base.empty? ? r : "#{base}/#{r}"
          full = File.join(start, r)
          next if r.split("/").include?(".git") || generated?(rel) || !File.file?(full) || File.size(full) > SEARCH_FILE_BYTES
          next if Repo::Paths.protected?(rel, @protected)

          rel
        end.sort
      end

      # @return [Boolean]
      def generated?(rel)
        Repo::Filters::GENERATED_DIRS.any? { |d| "#{rel}/".start_with?(d) || rel.include?("/#{d}") }
      end

      # --- writing (I2 through Task::Edits) ---

      def edit_file(path, search, replace)
        return "error: search must be the exact text to replace" if search.to_s.empty?

        apply(Task::Edit.new(op: "replace", path: path.to_s, content: nil, search: search.to_s, replace: replace.to_s), modify: true)
      end

      def write_file(path, content)
        apply(Task::Edit.new(op: "create", path: path.to_s, content: content.to_s, search: nil, replace: nil), modify: true)
      end

      def append_file(path, content)
        rel = Repo::Paths.normalize(path.to_s)
        return "error: #{rel} was not created in this task; append_file only extends files you created" unless @created.include?(rel)

        full = Repo::Paths.resolve_in_worktree(@root, rel, protected: @protected)
        current = File.binread(full).force_encoding(Encoding::UTF_8)
        apply(Task::Edit.new(op: "create", path: rel, content: current + content.to_s, search: nil, replace: nil), modify: true)
      end

      # @return [String]
      def apply(edit, modify:)
        rel = Repo::Paths.normalize(edit.path)
        if !@touched.include?(rel) && @touched.size >= @settings.max_files_per_task
          return "error: this task may change at most #{@settings.max_files_per_task} files (#{@touched.to_a.sort.join(', ')}); " \
                 "finish, and leave the rest to another task"
        end
        result = Task::Edits.apply(root: @root, edit_set: Task::EditSet.new(edits: [edit], tests: [], notes: ""),
                                   modify: modify ? [rel] : [], create: [rel], protected: @protected,
                                   rewrite_max_bytes: REWRITE_MAX_BYTES, own: @created.to_a)
        return "error: #{result.rejections.first.message}" unless result.ok?

        @touched.merge(result.written)
        @created.merge(result.created)
        result.written.empty? ? "#{rel}: no change" : "#{rel}: written (#{File.size(File.join(@root, rel))} bytes)"
      end

      def view_diff
        return "error: no worktree" unless @worktree

        diff = @worktree.patch(context: 3)
        return "no changes yet" if diff.strip.empty?

        diff.length > 20_000 ? "#{diff[0, 20_000]}\n… (diff cut at 20000 characters)" : diff
      end

      # --- checking (I3: configured gates and commands only) ---

      def run_gate(name)
        gate = @stack.gates[name.to_s]
        return "error: no gate named #{name.to_s[0, 40]}; use one of #{@stack.gates.keys.join(', ')}" unless gate

        files = @touched.select { |rel| File.file?(File.join(@root, rel)) }.sort
        result, output = @runner.run_with_output(gate, files: files, tests: @tests)
        describe(result, output)
      end

      def run_command(name, params)
        command = @settings.commands[name.to_s]
        return "error: no command named #{name.to_s[0, 40]}; use one of #{@settings.commands.keys.join(', ')}" unless command

        values = params.is_a?(Hash) ? params : {}
        argv = command.argv.map do |a|
          key = a[/\A\{([a-z][a-z0-9_]*)\}\z/, 1]
          key ? param(command, key, values[key]) : a
        end
        gate = Gates::Gate.new(name: "command:#{command.name}", argv: argv, scope: "project", parser: nil, blocking: false,
                               cost_rank: 0, phase: "task", timeout_sec: command.timeout_sec)
        result, output = @runner.run_with_output(gate)
        describe(result, output)
      rescue ArgumentError => e
        "error: #{e.message}"
      end

      # A parameter value the command declared, checked by its kind; never a flag or a path outside the worktree.
      # @return [String]
      # @raise [ArgumentError]
      def param(command, key, value)
        kind = command.params.fetch(key)
        value = value.to_s.strip
        raise ArgumentError, "#{command.name} needs #{key}" if value.empty?

        case kind
        when "path"
          rel = Repo::Paths.normalize(value)
          full = Repo::Paths.resolve_in_worktree(@root, rel, protected: @protected)
          raise ArgumentError, "#{key}: #{rel} does not exist" unless File.exist?(full)

          rel.start_with?("-") ? "./#{rel}" : rel
        else
          raise ArgumentError, "#{key}: letters, digits and . _ : / @ - only, not starting with -" unless value.match?(PARAM_WORD)

          value
        end
      rescue PathError => e
        raise ArgumentError, "#{key}: #{e.message}"
      end

      # @return [String]
      def describe(result, output)
        head = "#{result.gate}: #{result.status}#{result.reason ? " (#{result.reason})" : ''}"
        problems = result.diagnostics.first(20).map { |d| "- #{[d.file, d.line].compact.join(':')}: #{d.message}" }
        [head, *problems, output.empty? ? nil : "output (end):\n#{output}"].compact.join("\n")
      end
    end
  end
end
