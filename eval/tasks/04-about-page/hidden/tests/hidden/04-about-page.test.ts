import { expect, it } from "vitest";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import About from "../../src/pages/about.astro";

it("renders the about page in the base layout", async () => {
  const container = await AstroContainer.create();
  const html = await container.renderToString(About);
  expect(html).toContain("<title>About us</title>");
  expect(html).toMatch(/<h1[^>]*>\s*About us\s*<\/h1>/);
  expect(html).toContain("We build small, fast websites.");
});
