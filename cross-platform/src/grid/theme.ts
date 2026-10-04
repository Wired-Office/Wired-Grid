/** Wired Grid's visual identity: an emerald accent over neutral chrome. */
export interface GridTheme {
  dark: boolean;
  accent: string;
  selection: string;
  selectionFill: string;
  cellBackground: string;
  gridline: string;
  headerBackground: string;
  headerSelected: string;
  headerFullySelected: string;
  headerText: string;
  headerLine: string;
  cellText: string;
  linkText: string;
  frozenDivider: string;
}

const light: GridTheme = {
  dark: false,
  accent: "#178658",
  selection: "#178658",
  selectionFill: "rgba(23,134,88,0.13)",
  cellBackground: "#ffffff",
  gridline: "#dadcdb",
  headerBackground: "#f4f5f4",
  headerSelected: "#dbede3",
  headerFullySelected: "#178658",
  headerText: "#5c6361",
  headerLine: "#cccfcd",
  cellText: "#000000",
  linkText: "#0d66bf",
  frozenDivider: "#a9adab",
};

const dark: GridTheme = {
  dark: true,
  accent: "#54cc8f",
  selection: "#4dc785",
  selectionFill: "rgba(77,199,133,0.22)",
  cellBackground: "#1e1f1f",
  gridline: "#3d403f",
  headerBackground: "#2f3130",
  headerSelected: "#2e5240",
  headerFullySelected: "#3d9e6e",
  headerText: "#adb3b0",
  headerLine: "#474a49",
  cellText: "#e6e8e7",
  linkText: "#73b3ff",
  frozenDivider: "#6d716f",
};

const query = typeof window !== "undefined" && window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

export function currentTheme(): GridTheme {
  return query?.matches ? dark : light;
}

export function onThemeChange(listener: () => void) {
  query?.addEventListener?.("change", listener);
}

/** Colors for formula references while editing, in order. */
export const REFERENCE_COLORS = ["#2e70db", "#d94040", "#8c4dcc", "#1a9459", "#d9731a", "#bf338c", "#1a8ca6"];

/** Text font stacks: the workbook's font first, then each platform's closest match. */
export function fontStack(name: string): string {
  const quoted = `"${name.replace(/"/g, "")}"`;
  const lower = name.toLowerCase();
  const fallbacks = lower.includes("mono") || lower.includes("courier") || lower.includes("menlo") || lower.includes("consol")
    ? '"Cascadia Mono", Consolas, "DejaVu Sans Mono", "Liberation Mono", monospace'
    : lower.includes("times") || lower.includes("georgia") || lower.includes("serif") && !lower.includes("sans") || lower.includes("garamond") || lower.includes("cambria")
      ? '"Times New Roman", "Liberation Serif", "DejaVu Serif", serif'
      : 'Arial, "Liberation Sans", "Helvetica Neue", Helvetica, "Segoe UI", "Noto Sans", "DejaVu Sans", sans-serif';
  return `${quoted}, ${fallbacks}`;
}

export const UI_FONT = '"Segoe UI", system-ui, -apple-system, Ubuntu, Cantarell, "Noto Sans", sans-serif';
