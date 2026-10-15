import { existsSync } from "node:fs";
import { expect, it } from "vitest";
import { sortPosts } from "../../src/lib/posts";
import { collections } from "../../src/content.config";

const post = (title: string, date: string, draft = false) => ({ id: title, data: { title, date: new Date(date), draft } });

it("drops drafts and sorts newest first", () => {
  const out = sortPosts([post("old", "2026-01-01"), post("draft", "2026-03-01", true), post("new", "2026-02-01")]);
  expect(out.map((p: any) => p.data.title)).toEqual(["new", "old"]);
});

it("has the collection and both pages", () => {
  expect((collections as any).blog).toBeDefined();
  expect(existsSync("src/pages/blog/index.astro")).toBe(true);
  expect(existsSync("src/pages/blog/[id].astro")).toBe(true);
});
