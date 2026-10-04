import pkg from "../package.json";

export const APP_VERSION: string = pkg.version.replace(/\.0$/, "");

export type Platform = "Windows" | "Linux" | "macOS";

export function platformName(): Platform {
  const ua = typeof navigator === "undefined" ? "" : navigator.userAgent;
  if (/Windows/i.test(ua)) return "Windows";
  if (/Mac OS X|Macintosh/i.test(ua)) return "macOS";
  return "Linux";
}

/** "Ctrl" on Windows and Linux, "⌘" on macOS, for shortcut hints. */
export const modKey = () => (platformName() === "macOS" ? "⌘" : "Ctrl+");
