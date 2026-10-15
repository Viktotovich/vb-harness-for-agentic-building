import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { collections } from "../../src/content.config";

it("defines a blog collection whose schema coerces dates and defaults draft", () => {
  const schema = (collections.blog as any).schema;
  const parsed = schema.parse({ title: "Hi", date: "2026-01-02" });
  expect(parsed.date).toBeInstanceOf(Date);
  expect(parsed.draft).toBe(false);
  expect(schema.safeParse({ date: "2026-01-02" }).success).toBe(false);
});

it("has two posts with frontmatter", () => {
  for (const name of ["hello", "second"]) {
    const text = readFileSync(`src/content/blog/${name}.md`, "utf8");
    expect(text).toMatch(/^---\n[\s\S]*title:[\s\S]*date:[\s\S]*\n---/);
  }
});
