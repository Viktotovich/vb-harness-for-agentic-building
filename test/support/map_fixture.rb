# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

require "fileutils"

module TestSupport
  # A small Astro-like tree for the context map and packing tests.
  module MapFixture
    FILES = {
      "src/lib/tax.ts" => "export const rate = 0.2;\nexport type Rate = number;\n",
      "src/lib/price.ts" => <<~TS,
        import { rate } from "./tax";

        export function price(n: number): number {
          return n * (1 + rate);
        }
        export const ZERO = 0;
      TS
      "src/lib/format.ts" => <<~TS,
        import { price } from "./price.js";
        import { z } from "zod";

        export default function format(n: number): string {
          return price(n).toFixed(2);
        }
        export { price as cost, z };
      TS
      "src/components/Price.astro" => <<~ASTRO,
        ---
        import format from "~/lib/format";
        interface Props {
          amount: number;
          label?: { text: string };
        }
        const { amount } = Astro.props;
        ---
        <span>{format(amount)}</span>
      ASTRO
      "src/pages/index.astro" => "---\nimport Price from \"../components/Price.astro\";\n---\n<Price amount={1} />\n",
      "src/pages/blog/[slug].astro" => "---\nexport async function getStaticPaths() { return []; }\n---\n<h1>post</h1>\n",
      "src/pages/_draft.astro" => "<p>draft</p>\n",
      "src/content.config.ts" => <<~TS,
        import { defineCollection, z } from "astro:content";
        const blog = defineCollection({ schema: z.object({ title: z.string() }) });
        export const collections = { blog };
      TS
      "lib/util.rb" => "module Util\n  def self.round(x) = x.round\nend\n",
      "dist/bundle.js" => "built\n",
      "package-lock.json" => "{}\n",
      "public/vendor.min.js" => "min\n",
      "src/lib/wide.js" => "#{'x' * 2000}\n",
      ".env" => "SECRET=placeholder\n",
      "tools/check.ts" => "export const tool = 1;\n"
    }.freeze
    PROTECTED = [".env*", "tools/**"].freeze

    # @param dir [String]
    # @return [String] the root, with FILES written
    def self.write(dir)
      FILES.each do |rel, text|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.binwrite(full, text)
      end
      dir
    end
  end
end
