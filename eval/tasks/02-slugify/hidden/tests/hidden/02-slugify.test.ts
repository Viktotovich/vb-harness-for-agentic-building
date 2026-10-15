import { expect, it } from "vitest";
import { slugify } from "../../src/lib/slug";

it("slugifies text", () => {
  expect(slugify("  Hello, World!  ")).toBe("hello-world");
  expect(slugify("Astro 5 -- Tips")).toBe("astro-5-tips");
  expect(slugify("---")).toBe("");
  expect(slugify("already-a-slug")).toBe("already-a-slug");
});
