# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  module Repo
    # Regex-level facts about one source file for the context map (DESIGN.md 5.2). Not a parser: good enough to
    # draw the import graph and to show a file's surface.
    module SourceParse
      LANGS = {
        ".ts" => "ts", ".tsx" => "ts", ".mts" => "ts", ".cts" => "ts",
        ".js" => "js", ".jsx" => "js", ".mjs" => "js", ".cjs" => "js",
        ".astro" => "astro", ".md" => "markdown", ".mdx" => "mdx", ".json" => "json",
        ".css" => "css", ".scss" => "css", ".rb" => "ruby", ".py" => "python"
      }.freeze
      SCRIPT = %w[ts js astro mdx].freeze

      IMPORT_PATTERNS = [
        /^\s*(?:import|export)\s[^'";]*?\sfrom\s*["']([^"'\n]+)["']/m,
        /^\s*import\s*["']([^"'\n]+)["']/,
        /\bimport\(\s*["']([^"'\n]+)["']\s*\)/,
        /\brequire\(\s*["']([^"'\n]+)["']\s*\)/
      ].freeze
      DECLARATION = /^\s*export\s+(?:declare\s+)?(default\s+)?(?:async\s+)?(?:abstract\s+)?
                     (?:function\*?|class|const|let|var|interface|type|enum)\s+([A-Za-z_$][\w$]*)/x
      EXPORT_LIST = /^\s*export\s+(?:type\s+)?\{([^}]*)\}/
      DEFAULT_EXPRESSION = /^\s*export\s+default\b/
      RUBY_DECLARATION = /^\s*(?:class|module|def)\s+(?:self\.)?([A-Z_a-z][\w:]*[?!]?)/
      PYTHON_DECLARATION = /^(?:async\s+)?(?:def|class)\s+([A-Za-z_]\w*)/
      PROPS_START = /^\s*(?:export\s+)?(?:interface\s+Props\b[^{\n]*|type\s+Props\s*=\s*)\{/
      STATIC_PATHS = /^\s*export\s+(?:async\s+function\s+getStaticPaths|function\s+getStaticPaths|const\s+getStaticPaths)\b/
      COLLECTION = /\bconst\s+([A-Za-z_$][\w$]*)\s*=\s*defineCollection\s*\(/
      MAX_DECLARATION = 200

      # @param path [String] repository-relative
      # @return [String] the language tag, "other" when unknown
      def self.lang(path)
        LANGS.fetch(File.extname(path).downcase, "other")
      end

      # @param path [String]
      # @param content [String]
      # @return [Hash] "imports" (raw specifiers), "exports" (names), "declarations" (export lines), and for
      #   Astro "props" (the Props type text or nil), "staticPaths"; "collections" for content config files
      def self.parse(path, content)
        lang = lang(path)
        code = lang == "astro" ? frontmatter(content) : content
        facts = { "imports" => [], "exports" => [], "declarations" => [] }
        case lang
        when *SCRIPT then script(code, facts)
        when "ruby" then declarations(code, RUBY_DECLARATION, facts)
        when "python" then declarations(code, PYTHON_DECLARATION, facts)
        end
        if lang == "astro"
          facts["exports"] |= ["default"]
          facts["props"] = props(code)
          facts["staticPaths"] = code.match?(STATIC_PATHS)
        end
        names = code.scan(COLLECTION).flatten
        facts["collections"] = names.uniq unless names.empty?
        facts
      end

      # The frontmatter of an .astro file: the script between the leading --- fences.
      # @param content [String]
      # @return [String]
      def self.frontmatter(content)
        m = content.match(/\A\s*---\s*\n(.*?)^---\s*$/m)
        m ? m[1] : ""
      end

      # @return [void]
      def self.script(code, facts)
        facts["imports"] = IMPORT_PATTERNS.flat_map { |re| code.scan(re).flatten }.uniq
        code.each_line do |line|
          if (m = line.match(DECLARATION))
            facts["exports"] << (m[1] ? "default" : m[2])
            facts["exports"] << m[2] if m[1]
          elsif (m = line.match(EXPORT_LIST))
            m[1].split(",").each do |item|
              name = item.strip.split(/\s+as\s+/).last.to_s.strip
              facts["exports"] << name unless name.empty?
            end
          elsif line.match?(DEFAULT_EXPRESSION)
            facts["exports"] << "default"
          else
            next
          end
          facts["declarations"] << line.strip[0, MAX_DECLARATION]
        end
        facts["exports"].uniq!
      end

      # @return [void]
      def self.declarations(code, pattern, facts)
        code.each_line do |line|
          next unless (m = line.match(pattern))

          facts["exports"] << m[1]
          facts["declarations"] << line.strip[0, MAX_DECLARATION]
        end
        facts["exports"].uniq!
      end

      # The Props type text, braces balanced, or nil.
      # @return [String, nil]
      def self.props(code)
        start = code =~ PROPS_START
        return nil unless start

        open = code.index("{", start)
        depth = 0
        code[open..].each_char.with_index do |ch, i|
          depth += 1 if ch == "{"
          depth -= 1 if ch == "}"
          return code[start..(open + i)].strip if depth.zero?
        end
        nil
      end
      private_class_method :script, :declarations, :props
    end
  end
end
