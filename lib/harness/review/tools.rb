# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "json"
require_relative "../errors"
require_relative "../evidence/retrieve"
require_relative "../repo/paths"
require_relative "../untrusted"

module Harness
  module Review
    # Read-only fetch tools for the verifier and the challenge (DESIGN.md 8.1): read_file and find_symbol over the
    # worktree, guarded by I2, and lookup_docs over the evidence retriever. Every result is fenced (I9). The code
    # a tool returns is kept, so the gate can check quotes against everything the model saw.
    class Toolbox
      MAX_LINES = 120
      MAX_SYMBOL_FILES = 3

      # Every fetch, for the record: tool name, its arguments and a short outcome.
      Call = Data.define(:tool, :args, :outcome)

      attr_reader :calls

      # @param root [String] worktree root
      # @param protected [Array<String>]
      # @param map [Repo::Map, nil]
      # @param retriever [Evidence::Retriever, nil]
      def initialize(root:, protected:, map: nil, retriever: nil)
        @root = root
        @protected = protected
        @map = map
        @retriever = retriever
        @calls = []
        @seen = []
      end

      # @return [String] the code fetched so far
      def seen = @seen.join("\n")

      # @return [Array<Hash>] OpenAI tool definitions
      def definitions
        defs = [
          tool("read_file", "Read lines of a file in the repository, to check code a claim depends on. At most #{MAX_LINES} lines per call.",
               { "path" => { "type" => "string" }, "start_line" => { "type" => "integer" }, "end_line" => { "type" => "integer" } },
               %w[path start_line end_line]),
          tool("find_symbol", "Find where a type, function, component or constant is exported, and show its declaration.",
               { "name" => { "type" => "string" } }, ["name"])
        ]
        return defs unless @retriever

        defs << tool("lookup_docs", "Search the official framework documentation for the version the code uses. Pass a short query " \
                                    "such as an API name or directive, not a URL.",
                     { "query" => { "type" => "string" }, "latest" => { "type" => "boolean" } }, ["query"])
      end

      # Run one tool call. Unknown tools and bad arguments get an error text, never an exception.
      # @param name [String]
      # @param args [Object] parsed arguments
      # @return [String] the fenced result
      def call(name, args)
        args = {} unless args.is_a?(Hash)
        text = case name
               when "read_file" then read_file(args["path"], args["start_line"], args["end_line"])
               when "find_symbol" then find_symbol(args["name"])
               when "lookup_docs" then lookup_docs(args["query"], args["latest"] == true)
               else "error: unknown tool #{name.to_s[0, 40].inspect}"
               end
        @calls << Call.new(tool: name.to_s[0, 40], args: args.transform_values { |v| v.to_s[0, 120] }, outcome: text.lines.first.to_s.strip[0, 120])
        Untrusted.fence(text)
      end

      private

      def tool(name, description, properties, required)
        { "type" => "function", "function" => { "name" => name, "description" => description,
                                                 "parameters" => { "type" => "object", "properties" => properties, "required" => required } } }
      end

      def read_file(path, from, to)
        full = Repo::Paths.resolve_in_worktree(@root, path.to_s, protected: @protected)
        return "error: #{path} does not exist" unless File.file?(full)

        lines = File.read(full, mode: "rb").force_encoding(Encoding::UTF_8).scrub.lines
        from = [from.to_i, 1].max
        to = [[to.to_i, from].max, from + MAX_LINES - 1, lines.size].min
        return "error: #{path} has #{lines.size} lines" if from > lines.size

        chunk = lines[(from - 1)..(to - 1)]
        @seen << chunk.join
        (["#{path} lines #{from}-#{to} of #{lines.size}:"] + chunk.each_with_index.map { |l, i| "#{(from + i).to_s.rjust(5)}  #{l.chomp}" }).join("\n")
      rescue PathError => e
        "error: #{e.message}"
      end

      def find_symbol(name)
        name = name.to_s.strip
        return "error: no symbol name given" unless name.match?(/\A[A-Za-z_$][\w$]{0,80}\z/)
        return "error: no context map" unless @map

        files = @map.find_symbol(name)
        return "#{name}: not exported by any file in the repository" if files.empty?

        files.first(MAX_SYMBOL_FILES).map do |rel|
          sig = @map.signature(rel)
          @seen << sig
          sig
        end.join("\n\n")
      end

      def lookup_docs(query, latest)
        return "error: no documentation source is configured" unless @retriever

        Evidence::Retriever.format(@retriever.lookup(query: query, latest: latest))
      end
    end

    # The research conversation from REVIEWER src/review/tool-loop.js: the model may call tools up to max_calls
    # times, then answers. Profiles without native tool calls use a JSON reply protocol instead (DESIGN.md 8.1).
    module ToolLoop
      CONTINUE = "Continue: call another tool if you still need evidence, or reply with the single word DONE."
      EMULATED = <<~TEXT
        You can look things up. To call a tool, reply with only {"lookup": {"tool": "<name>", "args": {...}}}. When you have the evidence you need, reply with only {"done": true}.
        Tools:
      TEXT

      # history: the conversation so far as chat messages (the first user message included); text: the last reply.
      Research = Data.define(:history, :text)

      # @param client [Model::Client]
      # @param role [Symbol]
      # @param system [String]
      # @param user [String]
      # @param label [String]
      # @param toolbox [Toolbox]
      # @param max_calls [Integer]
      # @return [Research]
      # @raise [ModelOutputError, ContextOverflowError, ModelUnavailableError]
      def self.run(client:, role:, system:, user:, label:, toolbox:, max_calls:)
        if client.capabilities(role).tool_calls == "native"
          native(client, role, system, user, label, toolbox, max_calls)
        else
          emulated(client, role, system, user, label, toolbox, max_calls)
        end
      end

      # @return [Research]
      def self.native(client, role, system, user, label, toolbox, max_calls)
        history = []
        prompt = user
        used = 0
        loop do
          tools = used < max_calls ? toolbox.definitions : nil
          c = client.complete(role, Model::Messages.new(system: system, user: prompt, history: history), label: "#{label}.research", tools: tools)
          history << { "role" => "user", "content" => prompt }
          return Research.new(history: history, text: c.text) if tools.nil? || c.tool_calls.empty?

          history << { "role" => "assistant", "content" => c.text.to_s, "tool_calls" => c.tool_calls }
          c.tool_calls.each do |tc|
            fn = tc.is_a?(Hash) ? tc["function"] || {} : {}
            content = if used >= max_calls then "error: lookup limit reached; answer with the evidence you have"
                      else
                        used += 1
                        toolbox.call(fn["name"], arguments(fn["arguments"]))
                      end
            history << { "role" => "tool", "tool_call_id" => tc["id"].to_s, "content" => content }
          end
          prompt = CONTINUE
        end
      end

      # @return [Research]
      def self.emulated(client, role, system, user, label, toolbox, max_calls)
        listing = toolbox.definitions.map { |d| "- #{d['function']['name']}(#{d['function']['parameters']['properties'].keys.join(', ')}): #{d['function']['description']}" }
        system = "#{system}\n\n#{EMULATED}#{listing.join("\n")}"
        history = []
        prompt = user
        max_calls.times do
          c = client.complete(role, Model::Messages.new(system: system, user: prompt, history: history), label: "#{label}.research",
                                                                                                    parser: method(:lookup_request))
          history << { "role" => "user", "content" => prompt } << { "role" => "assistant", "content" => c.text.to_s }
          return Research.new(history: history, text: "DONE") unless c.value

          prompt = "Tool result:\n#{toolbox.call(c.value['tool'], c.value['args'])}\n\n#{CONTINUE.sub('reply with the single word DONE', 'reply with {"done": true}')}"
        end
        history << { "role" => "user", "content" => prompt }
        Research.new(history: history, text: "")
      end

      # @param obj [Object]
      # @return [Hash, nil] {"tool", "args"} or nil for done
      # @raise [ParseError]
      def self.lookup_request(obj)
        raise ParseError, "expected {\"lookup\": ...} or {\"done\": true}" unless obj.is_a?(Hash)
        return nil if obj["done"] == true || !obj.key?("lookup")

        l = obj["lookup"]
        raise ParseError, "lookup must be an object with a tool name" unless l.is_a?(Hash) && l["tool"].is_a?(String)

        { "tool" => l["tool"], "args" => l["args"].is_a?(Hash) ? l["args"] : {} }
      end

      # @return [Hash]
      def self.arguments(raw)
        raw.is_a?(Hash) ? raw : JSON.parse(raw.to_s)
      rescue JSON::ParserError
        {}
      end
      private_class_method :native, :emulated, :arguments
    end
  end
end
