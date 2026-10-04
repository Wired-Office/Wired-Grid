import { installKind } from "./platform";
import { settings, updateSettings } from "./settings";
import { APP_VERSION } from "./version";

/** Same release feed as the Mac app: the latest GitHub release. */
export const RELEASES_URL = "https://api.github.com/repos/Wired-Office/Wired-Grid/releases/latest";
const DAY = 24 * 60 * 60 * 1000;

export interface Release {
  tag_name: string;
  name?: string;
  body?: string;
  html_url: string;
  draft: boolean;
  prerelease: boolean;
  assets: { name: string; browser_download_url: string }[];
}

export function parseVersion(tag: string): number[] | null {
  const core = /^[vV]?(\d+(?:\.\d+)*)/.exec(tag.trim());
  return core ? core[1].split(".").map(Number) : null;
}

export function compareVersions(a: number[], b: number[]): number {
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const d = (a[i] ?? 0) - (b[i] ?? 0);
    if (d) return Math.sign(d);
  }
  return 0;
}

/** The release to offer, or null when current, unusable, or skipped (unless the user asked). */
export function updateFrom(release: Release, current: string, skipped: string, userInitiated: boolean): Release | null {
  const version = parseVersion(release.tag_name);
  const mine = parseVersion(current);
  if (release.draft || release.prerelease || !version || !mine || compareVersions(mine, version) >= 0) return null;
  const skippedVersion = parseVersion(skipped);
  if (!userInitiated && skippedVersion && compareVersions(skippedVersion, version) === 0) return null;
  return release;
}

/** The installer for this kind of installation, or the release page. */
export function downloadURL(release: Release, kind: string): string {
  const find = (pattern: RegExp) => release.assets.find((a) => pattern.test(a.name))?.browser_download_url;
  switch (kind) {
    case "windows": return find(/\.exe$/i) ?? find(/\.msi$/i) ?? release.html_url;
    case "appimage": return find(/\.AppImage$/i) ?? release.html_url;
    case "deb": return find(/\.deb$/i) ?? find(/\.AppImage$/i) ?? release.html_url;
    default: return release.html_url;
  }
}

export interface UpdateOffer {
  release: Release;
  version: string;
  url: string;
}

/** Checks GitHub; `null` means up to date. Throws when the check fails. */
export async function checkForUpdate(userInitiated: boolean): Promise<UpdateOffer | null> {
  const response = await fetch(RELEASES_URL, { headers: { Accept: "application/vnd.github+json" } });
  if (!response.ok) throw new Error(`GitHub returned ${response.status}.`);
  const release = (await response.json()) as Release;
  updateSettings({ lastUpdateCheck: Date.now() });
  const offer = updateFrom(release, APP_VERSION, settings().skippedVersion, userInitiated);
  if (!offer) return null;
  return { release: offer, version: parseVersion(offer.tag_name)!.join("."), url: downloadURL(offer, await installKind()) };
}

export function isCheckDue(): boolean {
  return settings().checkForUpdates && Date.now() - settings().lastUpdateCheck >= DAY;
}
