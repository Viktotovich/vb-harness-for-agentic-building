import { readFileSync } from "node:fs";
import { expect, it } from "vitest";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import Counter from "../../src/components/Counter.astro";

it("renders the element with its start value", async () => {
  const container = await AstroContainer.create();
  const html = await container.renderToString(Counter, { props: { start: 5 } });
  expect(html).toMatch(/<counter-button[^>]*data-start="5"/);
  expect(html).toMatch(/<button[^>]*>\s*5\s*<\/button>/);
});

it("defaults to zero and defines the element in a script", async () => {
  const container = await AstroContainer.create();
  const html = await container.renderToString(Counter);
  expect(html).toMatch(/data-start="0"/);
  const source = readFileSync("src/components/Counter.astro", "utf8");
  expect(source).toMatch(/customElements\.define\(\s*["']counter-button["']/);
});

it("is used on the home page", () => {
  const page = readFileSync("src/pages/index.astro", "utf8");
  expect(page).toMatch(/<Counter[^>]*start=\{3\}/);
});
