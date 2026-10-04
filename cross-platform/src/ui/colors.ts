/** Color pickers for fills, text, tabs and borders. */

/** Theme colors in Excel's arrangement: a row of base colors and lighter/darker shades below. */
const BASE = ["#FFFFFF", "#000000", "#E7E6E6", "#44546A", "#1E8E5A", "#2F6FDB", "#F29D38", "#D9534F", "#8E5BD6", "#17A2B8"];
const STANDARD = ["#C00000", "#FF0000", "#FFC000", "#FFFF00", "#92D050", "#00B050", "#00B0F0", "#0070C0", "#002060", "#7030A0"];

function shade(hex: string, amount: number): string {
  const n = parseInt(hex.slice(1), 16);
  const channel = (v: number) => Math.round(amount >= 0 ? v + (255 - v) * amount : v * (1 + amount));
  const r = channel((n >> 16) & 255), g = channel((n >> 8) & 255), b = channel(n & 255);
  return "#" + [r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("").toUpperCase();
}

export const THEME_GRID: string[][] = [BASE, ...[0.8, 0.6, 0.4, -0.25, -0.5].map((a) => BASE.map((c, i) => (i === 0 ? shade("#FFFFFF", -Math.abs(a) * 0.5) : i === 1 ? shade("#000000", Math.abs(a)) : shade(c, a))))];

let openPalette: HTMLElement | null = null;

export function closePalette() {
  openPalette?.remove();
  openPalette = null;
}

/** Shows a color palette under `anchor`. `clearLabel` adds a "No Fill"/"Automatic" button (picks undefined). */
export function showPalette(anchor: HTMLElement, clearLabel: string, onPick: (color: string | undefined) => void) {
  closePalette();
  const palette = document.createElement("div");
  palette.className = "palette";
  const clear = document.createElement("button");
  clear.className = "wide";
  clear.textContent = clearLabel;
  clear.addEventListener("click", () => { closePalette(); onPick(undefined); });
  palette.append(clear);
  const label = (text: string) => {
    const el = document.createElement("div");
    el.className = "label";
    el.textContent = text;
    palette.append(el);
  };
  const swatch = (color: string) => {
    const b = document.createElement("button");
    b.style.background = color;
    b.title = color;
    b.addEventListener("click", () => { closePalette(); onPick(color); });
    palette.append(b);
  };
  label("Theme Colors");
  THEME_GRID.forEach((row) => row.forEach(swatch));
  label("Standard Colors");
  STANDARD.forEach(swatch);
  const more = document.createElement("button");
  more.className = "wide";
  more.textContent = "More Colors…";
  const input = document.createElement("input");
  input.type = "color";
  input.style.cssText = "position:absolute;opacity:0;pointer-events:none;width:0;height:0";
  input.addEventListener("change", () => { closePalette(); onPick(input.value.toUpperCase()); });
  more.addEventListener("click", () => input.click());
  palette.append(more, input);
  document.body.append(palette);
  const rect = anchor.getBoundingClientRect();
  const left = Math.min(rect.left, window.innerWidth - palette.offsetWidth - 8);
  palette.style.left = `${Math.max(8, left)}px`;
  palette.style.top = `${rect.bottom + 4}px`;
  openPalette = palette;
  const outside = (event: MouseEvent) => {
    if (!palette.contains(event.target as Node) && event.target !== anchor) {
      closePalette();
      document.removeEventListener("mousedown", outside, true);
    }
  };
  setTimeout(() => document.addEventListener("mousedown", outside, true), 0);
}
