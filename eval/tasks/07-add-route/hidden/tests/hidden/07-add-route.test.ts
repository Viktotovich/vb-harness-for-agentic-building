import { expect, it } from "vitest";
import { GET } from "../../src/pages/api/add";

const call = (query: string) => {
  const url = new URL(`http://localhost/api/add${query}`);
  return (GET as any)({ url, request: new Request(url) }) as Promise<Response>;
};

it("adds two numbers", async () => {
  const res = await call("?a=1&b=2.5");
  expect(res.status).toBe(200);
  expect(await res.json()).toEqual({ sum: 3.5 });
});

it("refuses bad input", async () => {
  for (const q of ["?a=1", "?a=x&b=2", "", "?a=Infinity&b=1"]) {
    const res = await call(q);
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "a and b must be numbers" });
  }
});
