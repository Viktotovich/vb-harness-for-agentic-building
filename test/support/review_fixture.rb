# frozen_string_literal: true
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 V and Bruno LLC

module TestSupport
  # Diffs and docs for the review tests (ported from REVIEWER test/helpers.js and test/evidence.test.js).
  module ReviewFixture
    SAMPLE_DIFF = <<~'DIFF'
      diff --git a/app/models/user.rb b/app/models/user.rb
      index 1111111..2222222 100644
      --- a/app/models/user.rb
      +++ b/app/models/user.rb
      @@ -1,5 +1,7 @@
       class User < ApplicationRecord
         def full_name
      -    "#{first_name} #{last_name}"
      +    first_name + " " + last_name
         end
      +
      +  def admin? = role == "admin"
       end
      diff --git a/package-lock.json b/package-lock.json
      index 4444444..5555555 100644
      --- a/package-lock.json
      +++ b/package-lock.json
      @@ -1,3 +1,3 @@
       {
      -  "x": 1
      +  "x": 2
       }
      diff --git a/public/logo.png b/public/logo.png
      new file mode 100644
      index 0000000..3333333
      Binary files /dev/null and b/public/logo.png differ
    DIFF

    HTML_COMPONENTS = <<~'MD'
      ---
      title: Components
      ---
      import Since from '~/components/Since.astro';

      ## HTML Components

      Astro supports importing and using `.html` files as components.

      A `<slot />` element inside an HTML component will work as it would in an Astro component. In order to use the HTML Web Component Slot element instead, add `is:inline` to your `<slot>` element.

      ```html
      ## not a heading inside a code fence
      ```
    MD

    DIRECTIVES = <<~'MD'
      ---
      title: Template directives reference
      ---

      ### `client:only`

      <Since v="7.3.0" />

      `client:only={string}` skips HTML server rendering, and renders only on the client. You must pass the component's correct framework as a value.

      <Since v="13.6.0" pkg="@astrojs/cloudflare" />
    MD

    # A fake docs checkout documenting major 7.
    # @return [String] its root
    def self.docs(dir)
      en = File.join(dir, "src", "content", "docs", "en")
      { "basics/astro-components.mdx" => HTML_COMPONENTS, "reference/directives-reference.mdx" => DIRECTIVES,
        "guides/upgrade-to/v7.mdx" => "---\ntitle: Upgrade to v7\n---\n\n## Breaking changes\n\nSome text about upgrading to Astro 7 here.\n" }
        .each do |rel, text|
          FileUtils.mkdir_p(File.dirname(File.join(en, rel)))
          File.binwrite(File.join(en, rel), text)
        end
      dir
    end

    # @return [Array<Harness::Review::DiffFile>]
    def self.files(diff = SAMPLE_DIFF)
      Harness::Review::Diff.prepare(diff, max_lines: 600, max_chars: 28_000, max_chunks: 2).chunks.first.files
    end

    # @return [Harness::Review::Finding]
    def self.finding(**over)
      Harness::Review::Finding.new(**{ file: "app/models/user.rb", line: 3, severity: "high", confidence: "high",
                                       problem: "Raises NoMethodError when last_name is nil.", evidence: 'first_name + " " + last_name',
                                       mechanism: "", preconditions: "", expected_actual: "", unverified: "", found_by: [],
                                       on_added_line: false }.merge(over))
    end
  end
end
