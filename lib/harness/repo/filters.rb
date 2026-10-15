# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module Harness
  module Repo
    # Files the context map leaves out: binaries, lockfiles, build output, generated and minified files.
    # Ported from REVIEWER src/review/diff.js (skipReason).
    module Filters
      LOCKFILES = %w[package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock gemfile.lock
                     cargo.lock composer.lock poetry.lock pipfile.lock uv.lock go.sum flake.lock].freeze
      # Matched at any depth (packages/foo/node_modules/).
      GENERATED_DIRS = %w[dist/ .next/ .nuxt/ .astro/ .svelte-kit/ .turbo/ .vercel/ coverage/ node_modules/ vendor/bundle/
                          public/packs/ public/packs-test/ public/assets/ public/vite/ public/build/ __generated__/
                          .git/ .cache/].freeze
      # Only at the repository root: nested build/ or out/ folders can be real source.
      ROOT_ONLY_DIRS = %w[build/ out/ tmp/ target/ log/].freeze
      GENERATED_FILES = [
        %r{(?:\A|/)db/schema\.rb\z}, %r{(?:\A|/)db/structure\.sql\z}, /\.generated\.[a-z]+\z/, /\.snap\z/,
        # Migration tool metadata, written by the tool and not by hand.
        %r{(?:\A|/)meta/\d+_snapshot\.json\z}, %r{(?:\A|/)meta/_journal\.json\z}
      ].freeze
      MINIFIED = [/\.min\.(?:js|mjs|css)\z/, /\.map\z/, /-\h{8,}\.(?:js|css)\z/].freeze
      BINARY_EXT = /\.(?:png|jpe?g|gif|webp|avif|bmp|ico|icns|svg|pdf|zip|gz|tgz|bz2|xz|7z|rar|jar|wasm|woff2?|ttf|otf|eot|
                     mp3|mp4|mov|webm|wav|ogg|psd|ai|sketch|fig|exe|dll|so|dylib|bin|dat|db|sqlite3?)\z/x
      MAX_LINE_LEN = 1000

      # Why a path is left out by its name alone, or nil.
      # @param path [String] repository-relative, / or \ separators
      # @return [String, nil] "binary", "lockfile", "generated/build output", "generated" or "minified"
      def self.skip_reason(path)
        lower = path.tr("\\", "/").downcase
        base = lower.split("/").last.to_s
        return "binary" if lower.match?(BINARY_EXT)
        return "lockfile" if LOCKFILES.include?(base)
        return "generated/build output" if GENERATED_DIRS.any? { |d| lower.start_with?(d) || lower.include?("/#{d}") }
        return "generated/build output" if ROOT_ONLY_DIRS.any? { |d| lower.start_with?(d) }
        return "generated" if GENERATED_FILES.any? { |re| lower.match?(re) }
        return "minified" if MINIFIED.any? { |re| lower.match?(re) }

        nil
      end

      # Why a file is left out by its name or content, or nil.
      # @param path [String]
      # @param content [String]
      # @return [String, nil] skip_reason, "binary" for NUL bytes, or "minified (very long lines)"
      def self.content_skip_reason(path, content)
        reason = skip_reason(path)
        return reason if reason
        return "binary" if content.include?("\0")
        return "minified (very long lines)" if content.each_line.any? { |l| l.bytesize > MAX_LINE_LEN }

        nil
      end
    end
  end
end
