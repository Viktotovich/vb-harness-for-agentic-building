# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

# Ported from REVIEWER test/diff.test.js (skipReason).

require_relative "../test_helper"

class FiltersTest < Minitest::Test
  F = Harness::Repo::Filters

  def test_paths_left_out_by_name
    {
      "dist/index.js" => "generated/build output",
      "packages/a/dist/x.js" => "generated/build output",
      "build/out.js" => "generated/build output",
      "src/build/helper.ts" => nil, # nested build/ folders are real source
      "assets/app.min.js" => "minified",
      "assets/app.js.map" => "minified",
      "yarn.lock" => "lockfile",
      "Gemfile.lock" => "lockfile",
      "db/schema.rb" => "generated",
      "drizzle/meta/0017_snapshot.json" => "generated",
      ".astro/types.d.ts" => "generated/build output",
      "node_modules/x/index.js" => "generated/build output",
      "public/logo.png" => "binary",
      "src\\Logo.SVG" => "binary",
      "app/models/user.rb" => nil,
      "src/pages/index.astro" => nil
    }.each { |path, reason| reason ? assert_equal(reason, F.skip_reason(path), path) : assert_nil(F.skip_reason(path), path) }
  end

  def test_content_reasons
    assert_equal "minified (very long lines)", F.content_skip_reason("src/a.js", "x" * 5000)
    assert_equal "binary", F.content_skip_reason("src/a.dat2", "a\0b")
    assert_equal "lockfile", F.content_skip_reason("pnpm-lock.yaml", "ok")
    assert_nil F.content_skip_reason("src/a.js", "const a = 1;\n")
  end
end
