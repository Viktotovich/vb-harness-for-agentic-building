# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require_relative "../test_helper"
require_relative "../support/map_fixture"
require "json"
require "tmpdir"

class MapTest < Minitest::Test
  MF = TestSupport::MapFixture

  def setup
    @tmp = Dir.mktmpdir("harness-map-")
    @root = MF.write(File.join(@tmp, "wt"))
    @cache = File.join(@tmp, "cache")
  end

  def teardown
    FileUtils.rm_rf(@tmp)
  end

  def map
    @map ||= Harness::Repo::Map.new(root: @root, cache_dir: @cache, protected: MF::PROTECTED)
  end

  def test_filtered_and_protected_files_are_not_in_the_map
    assert_equal %w[lib/util.rb src/components/Price.astro src/content.config.ts src/lib/format.ts src/lib/price.ts
                    src/lib/tax.ts src/pages/_draft.astro src/pages/blog/[slug].astro src/pages/index.astro], map.paths
    assert_equal "minified (very long lines)", map.skipped["src/lib/wide.js"]
    assert_equal "lockfile", map.skipped["package-lock.json"]
    assert_nil map.signature(".env"), "protected files are never described"
  end

  def test_imports_resolve_relative_aliased_and_js_specifiers
    assert_equal ["src/lib/tax.ts"], map["src/lib/price.ts"].imports
    assert_equal ["src/lib/price.ts"], map["src/lib/format.ts"].imports, "./price.js names price.ts; packages are dropped"
    assert_equal ["src/lib/format.ts"], map["src/components/Price.astro"].imports, "~/ is src/"
    assert_equal ["src/components/Price.astro"], map["src/pages/index.astro"].imports
    assert_equal ["src/lib/format.ts"], map.importers("src/lib/price.ts")
  end

  def test_related_walks_both_directions_nearest_first
    assert_equal %w[src/lib/format.ts src/lib/tax.ts], map.related("src/lib/price.ts", depth: 1)
    assert_equal %w[src/lib/format.ts src/lib/tax.ts src/components/Price.astro], map.related("src/lib/price.ts", depth: 2)
    assert_equal %w[src/components/Price.astro src/lib/format.ts src/lib/price.ts src/lib/tax.ts],
                 map.related("src/pages/index.astro", depth: 4)
    assert_empty map.related("lib/util.rb", depth: 3)
  end

  def test_signatures_show_the_surface_not_the_body
    sig = map.signature("src/lib/price.ts")
    assert_includes sig, "imports: src/lib/tax.ts"
    assert_includes sig, "exports: price, ZERO"
    assert_includes sig, "export function price(n: number): number {"
    refute_includes sig, "return n"
    assert_includes map.signature("src/lib/format.ts"), "exports: default, format, cost, z"
    astro = map.signature("src/components/Price.astro")
    assert_includes astro, "exports: default"
    assert_includes astro, "interface Props {\n  amount: number;\n  label?: { text: string };\n}"
    assert_includes map.signature("lib/util.rb"), "def self.round(x) = x.round"
  end

  def test_astro_routes_static_paths_and_collections
    assert_equal "/", map["src/pages/index.astro"].route
    assert_equal "/blog/[slug]", map["src/pages/blog/[slug].astro"].route
    assert map["src/pages/blog/[slug].astro"].static_paths
    assert_nil map["src/pages/_draft.astro"].route, "underscore files are not routes"
    assert_nil map["src/lib/price.ts"].route
    assert_equal({ "blog" => "src/content.config.ts" }, map.collections)
  end

  def test_find_symbol
    assert_equal ["src/lib/tax.ts"], map.find_symbol("rate")
    assert_equal ["src/lib/format.ts"], map.find_symbol("cost")
    assert_empty map.find_symbol("missing")
  end

  def test_the_cache_is_keyed_by_content_and_rescans_parse_only_changes
    map
    entries = Dir.glob(File.join(@cache, "map", "*.json"))
    assert_equal 9, entries.size
    hacked = entries.find { |f| JSON.parse(File.read(f))["exports"] == %w[rate Rate] }
    File.write(hacked, JSON.generate({ "imports" => [], "exports" => ["fromCache"], "declarations" => [] }))
    File.write(File.join(@root, "src/lib/price.ts"), "export const price = 1;\n")
    map.scan
    assert_equal ["fromCache"], map["src/lib/tax.ts"].exports, "unchanged files come from the cache"
    assert_empty map["src/lib/price.ts"].imports, "changed files are parsed again"
    assert_equal 10, Dir.glob(File.join(@cache, "map", "*.json")).size
  end

  def test_summaries_are_made_once_per_content
    calls = []
    make = ->(path, content) { calls << path && "Computes #{path} from #{content.bytesize} bytes." }
    first = map.summary("src/lib/tax.ts") { |p, c| make.call(p, c) }
    assert_match(/\AComputes src\/lib\/tax\.ts/, first)
    again = Harness::Repo::Map.new(root: @root, cache_dir: @cache, protected: MF::PROTECTED)
    assert_equal first, again.summary("src/lib/tax.ts") { |p, c| make.call(p, c) }
    assert_equal 1, calls.size
    assert_nil map.summary("src/lib/price.ts"), "no block and nothing cached"
    assert_nil map.summary(".env") { |p, c| make.call(p, c) }
  end
end
