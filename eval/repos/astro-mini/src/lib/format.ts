/** Formats a whole number of cents as US dollars, e.g. 900 -> "$9.00". */
export function formatPrice(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}
