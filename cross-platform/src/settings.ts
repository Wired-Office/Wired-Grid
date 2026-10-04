/** App preferences, stored per machine. */
export type EnterDirection = "down" | "right" | "up" | "left" | "none";

export interface Settings {
  showTemplateChooserOnLaunch: boolean;
  defaultFontName: string;
  defaultFontSize: number;
  /** Where the selection moves after pressing Enter. */
  enterDirection: EnterDirection;
  showFormulaBar: boolean;
  showStatusBar: boolean;
  /** Suggest earlier entries from the same column while typing. */
  autoComplete: boolean;
  /** Show function suggestions and argument hints while typing formulas. */
  functionHints: boolean;
  authorName: string;
  defaultSheetCount: number;
  checkForUpdates: boolean;
  lastUpdateCheck: number;
  skippedVersion: string;
  recentFiles: string[];
}

const KEY = "wiredgrid.settings";

const defaults: Settings = {
  showTemplateChooserOnLaunch: true,
  defaultFontName: "Helvetica Neue",
  defaultFontSize: 12,
  enterDirection: "down",
  showFormulaBar: true,
  showStatusBar: true,
  autoComplete: true,
  functionHints: true,
  authorName: "",
  defaultSheetCount: 1,
  checkForUpdates: true,
  lastUpdateCheck: 0,
  skippedVersion: "",
  recentFiles: [],
};

let current: Settings = load();
const listeners = new Set<(settings: Settings) => void>();

function load(): Settings {
  try {
    return { ...defaults, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") };
  } catch {
    return { ...defaults };
  }
}

export function settings(): Settings {
  return current;
}

export function updateSettings(change: Partial<Settings>) {
  current = { ...current, ...change };
  try {
    localStorage.setItem(KEY, JSON.stringify(current));
  } catch {
    // Settings still apply for this session.
  }
  listeners.forEach((listener) => listener(current));
}

export function onSettingsChange(listener: (settings: Settings) => void) {
  listeners.add(listener);
}

export function addRecentFile(path: string) {
  const recent = [path, ...settings().recentFiles.filter((p) => p !== path)].slice(0, 10);
  updateSettings({ recentFiles: recent });
}
