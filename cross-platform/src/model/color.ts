import type { Color } from "./workbook";

export function parseColor(hex: string): [number, number, number] {
  const h = hex.replace(/^#/, "");
  const n = parseInt(h.length === 8 ? h.slice(2) : h.slice(0, 6), 16) || 0;
  return [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff];
}

export function toHex(r: number, g: number, b: number): Color {
  const c = (v: number) => Math.round(Math.min(Math.max(v, 0), 255)).toString(16).padStart(2, "0").toUpperCase();
  return "#" + c(r) + c(g) + c(b);
}

/** "#RRGGBB" from "#rrggbb", "RRGGBB" or Excel's "AARRGGBB"; null for anything else. */
export function normalizeColor(text: string | undefined | null): Color | null {
  if (!text) return null;
  const digits = text.trim().replace(/^#/, "");
  if (!/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(digits)) return null;
  const rgb = digits.length === 8 ? digits.slice(2) : digits;
  return "#" + rgb.toUpperCase();
}

/** Relative luminance, used to pick legible text over fills. */
export function luminance(color: Color): number {
  const [r, g, b] = parseColor(color);
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

export function mixColors(a: Color, b: Color, t: number): Color {
  const p = parseColor(a), q = parseColor(b);
  return toHex(p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t);
}

export const tableBandColor = (header: Color) => mixColors(header, "#FFFFFF", 0.84);
