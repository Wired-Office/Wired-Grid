import { FORMATS, type FormatID } from "./formats";

/**
 * Everything that touches the operating system goes through here. In the
 * Tauri app it uses native dialogs and the Rust backend; in a plain browser
 * (`npm run dev`) it falls back to file inputs and downloads so the editor
 * can be developed and tested without building the desktop app.
 */
export const isDesktop = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function tauri() {
  return {
    core: await import("@tauri-apps/api/core"),
    dialog: await import("@tauri-apps/plugin-dialog"),
  };
}

export interface OpenedFile {
  path: string | null;
  name: string;
  bytes: Uint8Array;
}

const filters = (ids: FormatID[]) =>
  FORMATS.filter((f) => ids.includes(f.id)).map((f) => ({ name: f.name, extensions: f.extensions }));

export async function chooseFileToOpen(only?: FormatID[]): Promise<OpenedFile | null> {
  const formats = only ? FORMATS.filter((f) => only.includes(f.id)) : FORMATS;
  if (isDesktop) {
    const { dialog } = await tauri();
    const all = formats.flatMap((f) => f.extensions);
    const path = await dialog.open({
      multiple: false,
      directory: false,
      filters: [{ name: only ? "Text Files" : "All Workbooks", extensions: all }, ...filters(formats.map((f) => f.id))],
    });
    if (typeof path !== "string") return null;
    return { path, name: basename(path), bytes: await readFile(path) };
  }
  return new Promise((resolve) => {
    const input = document.createElement("input");
    input.type = "file";
    input.accept = formats.flatMap((f) => f.extensions.map((e) => "." + e)).join(",");
    input.onchange = async () => {
      const file = input.files?.[0];
      resolve(file ? { path: null, name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) } : null);
    };
    input.oncancel = () => resolve(null);
    input.click();
  });
}


/** Asks where to save; returns the chosen path (desktop) or a file name (browser). */
export async function chooseSaveLocation(suggestedName: string, formats: FormatID[]): Promise<string | null> {
  if (isDesktop) {
    const { dialog } = await tauri();
    const path = await dialog.save({ defaultPath: suggestedName, filters: filters(formats) });
    return path ?? null;
  }
  const name = window.prompt("Save as", suggestedName);
  return name?.trim() || null;
}

export async function readFile(path: string): Promise<Uint8Array> {
  const { core } = await tauri();
  const buffer = await core.invoke<ArrayBuffer>("read_file", { path });
  return new Uint8Array(buffer);
}

export async function writeFile(path: string, bytes: Uint8Array): Promise<void> {
  if (isDesktop) {
    const { core } = await tauri();
    await core.invoke("write_file", bytes, { headers: { "x-path": encodeURIComponent(path) } });
    return;
  }
  const url = URL.createObjectURL(new Blob([bytes as BlobPart]));
  const link = document.createElement("a");
  link.href = url;
  link.download = basename(path);
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

export async function confirmDialog(message: string, options: { title?: string; ok?: string; cancel?: string } = {}): Promise<boolean> {
  if (isDesktop) {
    const { dialog } = await tauri();
    return dialog.ask(message, { title: options.title ?? "Wired Grid", kind: "warning", okLabel: options.ok, cancelLabel: options.cancel });
  }
  return window.confirm(message);
}

/** Save / Don't Save / Cancel. */
export async function askToSave(name: string): Promise<"save" | "discard" | "cancel"> {
  const message = `Do you want to save the changes you made to “${name}”?\n\nYour changes will be lost if you don't save them.`;
  if (isDesktop) {
    const { dialog } = await tauri();
    const result = await dialog.message(message, {
      title: "Wired Grid",
      kind: "warning",
      buttons: { yes: "Save", no: "Don't Save", cancel: "Cancel" },
    });
    if (result === "Yes" || result === "Save") return "save";
    if (result === "No" || result === "Don't Save") return "discard";
    return "cancel";
  }
  if (window.confirm(message + "\n\nOK saves, Cancel discards.")) return "save";
  return "discard";
}

export async function showMessage(message: string, kind: "info" | "warning" | "error" = "info"): Promise<void> {
  if (isDesktop) {
    const { dialog } = await tauri();
    await dialog.message(message, { title: "Wired Grid", kind });
    return;
  }
  window.alert(message);
}

export async function openURL(url: string): Promise<void> {
  if (isDesktop) {
    const { openUrl } = await import("@tauri-apps/plugin-opener");
    await openUrl(url);
    return;
  }
  window.open(url, "_blank", "noopener");
}

export async function setWindowTitle(title: string): Promise<void> {
  document.title = title;
  if (isDesktop) {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    await getCurrentWindow().setTitle(title);
  }
}

/** Runs `beforeClose` when the window is about to close; it returns false to keep it open. */
export async function onWindowClose(beforeClose: () => Promise<boolean>): Promise<void> {
  if (isDesktop) {
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    const win = getCurrentWindow();
    await win.onCloseRequested(async (event) => {
      event.preventDefault();
      if (await beforeClose()) await win.destroy();
    });
    return;
  }
  window.addEventListener("beforeunload", (event) => {
    if ((window as unknown as { __dirty?: boolean }).__dirty) event.preventDefault();
  });
}

/** A document passed on the command line (double-clicking a .grid file). */
export async function initialFile(): Promise<string | null> {
  if (!isDesktop) return null;
  const { core } = await tauri();
  return core.invoke<string | null>("initial_file");
}

/** How this copy was installed, to offer the right download: "windows", "appimage", "deb" or "other". */
export async function installKind(): Promise<string> {
  if (!isDesktop) return "other";
  const { core } = await tauri();
  return core.invoke<string>("install_kind");
}

export function basename(path: string): string {
  return path.split(/[\\/]/).pop() || path;
}
