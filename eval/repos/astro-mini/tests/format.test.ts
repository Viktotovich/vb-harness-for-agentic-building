import { describe, expect, it } from "vitest";
import { formatPrice } from "../src/lib/format";

describe("formatPrice", () => {
  it("formats cents as dollars", () => {
    expect(formatPrice(900)).toBe("$9.00");
    expect(formatPrice(5)).toBe("$0.05");
  });
});
