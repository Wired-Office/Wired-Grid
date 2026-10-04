import "./styles.css";
import { a1 } from "./model/address";
import { newWorkbook, getCell, type Workbook } from "./model/workbook";
import { WorkbookController, PASTE_TITLES, type FindOptions, type PasteMode } from "./engine/controller";
import { primaryRange } from "./engine/selection";
import { FORMATS, formatById, formatForName, readWorkbook, writeWorkbook, type FormatID } from "./formats";
import { readDelimited } from "./formats/delimited";
import { cssFont, fontMetrics, wrapLines } from "./grid/render";
import { GridView } from "./grid/view";
import {
  askToSave, basename, chooseFileToOpen, chooseSaveLocation, initialFile, isDesktop, onWindowClose, openURL,
  readFile, setWindowTitle, showMessage, writeFile,
} from "./platform";
import { printSheet } from "./print";
import { addRecentFile, onSettingsChange, settings, updateSettings } from "./settings";
import { BLANK, TEMPLATES } from "./templates";
import type { AppActions } from "./ui/actions";
import {
  aboutDialog, alertDialog, chartEditorDialog, conditionalFormatDialog, confirmDialog, defineNameDialog, fillSeriesDialog, formatCellsDialog,
  goToDialog, goToSpecialDialog, insertFunctionDialog, linkDialog, manageRulesDialog, nameManagerDialog, noteDialog, pageSetupDialog,
  promptNumber, settingsDialog, showDialog, sortDialog, statisticsDialog, templateChooser, textToColumnsDialog, updateDialog,
} from "./ui/dialogs";
import { FormulaBar } from "./ui/formulaBar";
import { buildMenubar, type MenuEntry } from "./ui/menubar";
import { closePopupMenu } from "./ui/popup";
import { Ribbon } from "./ui/ribbon";
import { SheetTabs } from "./ui/sheetTabs";
import { StatusBar } from "./ui/statusBar";
import { checkForUpdate, isCheckDue } from "./updates";
import { APP_VERSION, modKey, platformName } from "./version";
import { CHART_KINDS, CHART_KIND_TITLES } from "./model/workbook";
import { NUMBER_PRESETS } from "./ui/ribbon";

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

/** The open document. One window edits one workbook. */
const state = {
  path: null as string | null,
  name: "Untitled",
  format: "grid" as FormatID,
  /** The user agreed to keep saving a multi-sheet or formatted workbook as CSV/TSV. */
  flatConfirmed: false,
};

const controller = new WorkbookController(blankWorkbook());

function blankWorkbook(): Workbook {
  const workbook = newWorkbook(settings().defaultSheetCount);
  workbook.author = settings().authorName;
  return workbook;
}

// MARK: - Measuring text (AutoFit, wrapping)

const measure = document.createElement("canvas").getContext("2d")!;
controller.measurer = {
  width(text, style) {
    const { font } = cssFont(style, 1);
    measure.font = font;
    return measure.measureText(text).width;
  },
  lineHeight(style) {
    const { font, size } = cssFont(style, 1);
    const m = fontMetrics(measure, font, size);
    return m.ascent + m.descent;
  },
  wrappedHeight(text, style, width) {
    const { font, size } = cssFont(style, 1);
    measure.font = font;
    const m = fontMetrics(measure, font, size);
    return wrapLines(measure, text, width).length * (m.ascent + m.descent);
  },
};
controller.presenter = {
  alert: (message, info) => void alertDialog(message, info),
  confirm: (message, info, ok) => confirmDialog(message, info, ok),
};

// MARK: - Actions

const actions: AppActions = {
  newWorkbook: () => void newDocument(),
  newFromTemplate: () => void chooseTemplate(),
  open: () => void openDocument(),
  save: () => void saveDocument(),
  saveAs: () => void saveDocumentAs(),
  exportAs: (format) => void exportAs(format),
  print: () => void printSheet(controller),
  importText: () => void importText(),
  pageSetup: async () => {
    const result = await pageSetupDialog(controller.sheet.pageSetup);
    if (result) controller.updatePageSetup(result);
    grid.focus();
  },
  copy: (cut) => copy(cut),
  paste: (mode) => void paste(mode),
  formatCells: async (tab) => { await formatCellsDialog(controller, tab); grid.focus(); },
  customSort: async () => { await sortDialog(controller); grid.focus(); },
  conditionalFormat: async (rule) => { await conditionalFormatDialog(controller, rule); grid.focus(); },
  manageRules: async () => { await manageRulesDialog(controller); grid.focus(); },
  nameManager: async () => { await nameManagerDialog(controller); grid.focus(); },
  defineName: async () => { await defineNameDialog(controller); grid.focus(); },
  goTo: async () => { await goToDialog(controller); grid.focus(); },
  goToSpecial: async () => { await goToSpecialDialog(controller); grid.focus(); },
  find: (replace) => showFind(replace),
  insertFunction: async (category) => {
    const editing = controller.isEditing;
    const name = await insertFunctionDialog(category);
    if (!name) { grid.focus(); return; }
    if (editing && controller.isEditing) formulaBar.insertText(`${name}(`);
    else grid.beginEditing({ initial: `=${name}()`, mode: "edit", selection: [name.length + 2, 0] });
  },
  insertLink: async () => {
    const a = controller.selection.active;
    const cell = getCell(controller.sheet, a.row, a.column);
    const result = await linkDialog(cell?.link ?? "", cell?.formula === undefined ? controller.displayText(a) : "");
    if (result === "remove") controller.clearHyperlinks();
    else if (result) controller.setLink(result.url, a, result.text);
    grid.focus();
  },
  editNote: async (address) => {
    const a = address ?? controller.selection.active;
    const current = controller.note(a) ?? "";
    const result = await noteDialog(current ? `Note for ${a1(a)}` : `New Note for ${a1(a)}`, current);
    if (result === "delete") controller.setNote(null, a);
    else if (result !== null) controller.setNote(result, a);
    grid.focus();
  },
  textToColumns: async () => {
    const delimiter = await textToColumnsDialog();
    if (delimiter) controller.textToColumns(delimiter);
    grid.focus();
  },
  columnWidth: async () => {
    const columns = controller.selectedColumnIndices;
    const width = await promptNumber("Column Width", "Width in pixels", grid.currentColumnWidth());
    if (width !== null) controller.setColumnWidth(width, columns);
    grid.focus();
  },
  rowHeight: async () => {
    const rows = controller.selectedRowIndices;
    const height = await promptNumber("Row Height", "Height in pixels", grid.currentRowHeight());
    if (height !== null) controller.setRowHeight(height, rows);
    grid.focus();
  },
  editChart: async (chart) => { await chartEditorDialog(controller, chart); grid.focus(); },
  fillSeries: async () => {
    const result = await fillSeriesDialog();
    if (result) controller.fillSeries(result.step, result.vertical);
    grid.focus();
  },
  statistics: async () => { await statisticsDialog(controller); grid.focus(); },
  settings: () => void openSettings(),
  about: async () => { await aboutDialog(); grid.focus(); },
  checkForUpdates: () => void checkUpdates(true),
  openURL: (url) => void openURL(url),
  focusGrid: () => { if (!controller.isEditing) grid.focus(); },
};

const grid = new GridView($("grid"), controller, {
  formatCells: () => actions.formatCells(),
  customSort: () => actions.customSort(),
  editNote: (a) => actions.editNote(a),
  defineName: () => actions.defineName(),
  promptColumnWidth: () => actions.columnWidth(),
  promptRowHeight: () => actions.rowHeight(),
  editChart: (chart) => actions.editChart(chart),
  openURL: (url) => actions.openURL(url),
  copy: (cut) => actions.copy(cut),
  paste: (mode) => actions.paste(mode),
  insertLink: () => actions.insertLink(),
});
const ribbon = new Ribbon($("ribbon"), controller, actions);
const formulaBar = new FormulaBar($("formula-bar"), controller, grid.editor, actions);
new SheetTabs($("sheet-tabs"), controller, actions);
const statusBar = new StatusBar($("statusbar"), controller);

let ribbonPending = false;
controller.subscribe((kind) => {
  if (kind === "scroll" || kind === "marquee") return;
  if (kind === "content" || kind === "load" || kind === "status") updateTitle();
  if (!ribbonPending) {
    ribbonPending = true;
    requestAnimationFrame(() => {
      ribbonPending = false;
      ribbon.refresh();
    });
  }
});

// MARK: - Document state

function updateTitle() {
  const dirty = controller.isDirty;
  (window as unknown as { __dirty?: boolean }).__dirty = dirty;
  void setWindowTitle(`${dirty ? "● " : ""}${state.name} — Wired Grid`);
}

const displayName = (path: string) => basename(path).replace(/\.[^.]+$/, "");

async function confirmDiscard(): Promise<boolean> {
  controller.commitEditingIfNeeded();
  if (!controller.isDirty) return true;
  const answer = await askToSave(state.name);
  if (answer === "cancel") return false;
  if (answer === "save") return saveDocument();
  return true;
}

function loadWorkbook(workbook: Workbook, options: { path: string | null; name: string; format: FormatID }) {
  Object.assign(state, { ...options, flatConfirmed: false });
  controller.load(workbook);
  updateTitle();
  grid.focus();
}

async function newDocument() {
  if (!(await confirmDiscard())) return;
  loadWorkbook(blankWorkbook(), { path: null, name: "Untitled", format: "grid" });
}

async function chooseTemplate() {
  const template = await templateChooser(TEMPLATES, isDesktop ? settings().recentFiles : [], (path) => void openPath(path), () => void openDocument());
  if (!template) {
    grid.focus();
    return;
  }
  if (!(await confirmDiscard())) return;
  loadWorkbook(template.build(), { path: null, name: template.id === BLANK.id ? "Untitled" : template.name, format: "grid" });
}

async function openDocument(file?: { path: string | null; name: string; bytes: Uint8Array }) {
  if (!(await confirmDiscard())) return;
  const chosen = file ?? (await chooseFileToOpen());
  if (!chosen) return;
  if (!formatForName(chosen.name) && !/\.(txt|tab)$/i.test(chosen.name)) {
    await showMessage(`Wired Grid can't open “${chosen.name}”. Supported formats: ${FORMATS.map((f) => "." + f.extensions[0]).join(", ")}.`, "error");
    return;
  }
  try {
    const { workbook, format } = readWorkbook(chosen.name, chosen.bytes);
    loadWorkbook(workbook, { path: chosen.path, name: displayName(chosen.name), format });
    if (chosen.path) addRecentFile(chosen.path);
  } catch (error) {
    await showMessage(`“${chosen.name}” couldn't be opened.\n\n${(error as Error).message}`, "error");
  }
}

async function openPath(path: string) {
  try {
    await openDocument({ path, name: basename(path), bytes: await readFile(path) });
  } catch (error) {
    updateSettings({ recentFiles: settings().recentFiles.filter((p) => p !== path) });
    await showMessage(`“${basename(path)}” couldn't be opened.\n\n${(error as Error).message}`, "error");
  }
}

async function saveDocument(): Promise<boolean> {
  controller.commitEditingIfNeeded();
  if (!state.path || !isDesktop) return saveDocumentAs();
  if (formatById(state.format).flat && !state.flatConfirmed && losesDataAsFlat()) {
    const choice = await showDialog(`Keep using the ${formatById(state.format).shortName} format?`,
      `${formatById(state.format).shortName} files keep only the active sheet's values. Formatting, formulas${controller.workbook.sheets.length > 1 ? ", other sheets" : ""} and charts are lost.`,
      [{ label: "Save as Grid…", value: "grid", left: true }, { label: "Cancel", value: "cancel" }, { label: `Use ${formatById(state.format).shortName}`, value: "keep", primary: true }]);
    if (choice === "grid") return saveDocumentAs("grid");
    if (choice !== "keep") return false;
    state.flatConfirmed = true;
  }
  return writeDocument(state.path, state.format);
}

function losesDataAsFlat(): boolean {
  const w = controller.workbook;
  if (w.sheets.length > 1) return true;
  for (const sheet of w.sheets) {
    if (sheet.charts.length || sheet.conditionalFormats.length) return true;
    for (const cell of sheet.cells.values()) if (cell.formula !== undefined || cell.style) return true;
  }
  return false;
}

async function saveDocumentAs(preferred?: FormatID): Promise<boolean> {
  controller.commitEditingIfNeeded();
  const first = preferred ?? (formatById(state.format).flat ? "grid" : state.format);
  const ordered: FormatID[] = [first, ...FORMATS.map((f) => f.id).filter((f) => f !== first)];
  const path = await chooseSaveLocation(`${state.name}.${formatById(first).extensions[0]}`, ordered);
  if (!path) return false;
  const format = formatForName(path)?.id ?? first;
  const finalPath = formatForName(path) ? path : `${path}.${formatById(format).extensions[0]}`;
  const ok = await writeDocument(finalPath, format);
  if (ok) {
    Object.assign(state, { path: isDesktop ? finalPath : null, name: displayName(finalPath), format, flatConfirmed: formatById(format).flat });
    if (isDesktop) addRecentFile(finalPath);
    updateTitle();
  }
  return ok;
}

async function writeDocument(path: string, format: FormatID): Promise<boolean> {
  try {
    const workbook = controller.workbookForSaving();
    await writeFile(path, writeWorkbook(workbook, format));
    controller.markSaved();
    updateTitle();
    return true;
  } catch (error) {
    await showMessage(`The workbook couldn't be saved.\n\n${(error as Error).message ?? error}`, "error");
    return false;
  }
}

async function exportAs(format: FormatID | "pdf") {
  controller.commitEditingIfNeeded();
  if (format === "pdf") {
    await showMessage(`To create a PDF, choose “${platformName() === "Windows" ? "Microsoft Print to PDF" : "Print to File (PDF)"}” as the printer in the next window.`);
    await printSheet(controller);
    return;
  }
  const info = formatById(format);
  const path = await chooseSaveLocation(`${state.name}.${info.extensions[0]}`, [format]);
  if (!path) return;
  try {
    await writeFile(path, writeWorkbook(controller.workbookForSaving(), format));
    if (info.flat) controller.flash(`Exported the values of “${controller.sheet.name}”`);
  } catch (error) {
    await showMessage(`The workbook couldn't be exported.\n\n${(error as Error).message}`, "error");
  }
}

/** Data ▸ From Text/CSV: pastes a file's rows at the active cell. */
async function importText() {
  const file = await chooseFileToOpen(["csv", "tsv"]);
  if (!file) return;
  const separator = /\.(tsv|tab)$/i.test(file.name) ? "\t" : /\.txt$/i.test(file.name) && new TextDecoder().decode(file.bytes.slice(0, 2000)).includes("\t") ? "\t" : ",";
  const imported = readDelimited(file.bytes, separator).sheets[0];
  const start = controller.selection.active;
  const used = [...imported.cells.keys()];
  if (!used.length) return;
  controller.changeSheet("Import Text", (sheet) => {
    for (const [key, cell] of imported.cells) {
      const row = Math.floor(key / 16384) + start.row, column = (key % 16384) + start.column;
      if (row < 1_048_576 && column < 16384) sheet.cells.set(row * 16384 + column, cell);
    }
    for (const [column, width] of imported.columnWidths) if (!sheet.columnWidths.has(column + start.column)) sheet.columnWidths.set(column + start.column, width);
  }, true);
  controller.flash(`Imported ${basename(file.name)}`);
  grid.focus();
}

// MARK: - Clipboard (menus and ribbon; keyboard shortcuts use the native events)

function copy(cut: boolean) {
  const payload = controller.copySelection(cut);
  if (!payload) return;
  try {
    const item = new ClipboardItem({ "text/plain": new Blob([payload.text], { type: "text/plain" }), "text/html": new Blob([payload.html], { type: "text/html" }) });
    navigator.clipboard.write([item]).catch(() => navigator.clipboard.writeText(payload.text).catch(() => undefined));
  } catch {
    navigator.clipboard?.writeText(payload.text).catch(() => undefined);
  }
  grid.focus();
}

async function paste(mode: PasteMode) {
  let text: string | null = null;
  try {
    text = await navigator.clipboard.readText();
  } catch {
    // Without clipboard access, our own copied cells still paste.
  }
  if (text === null && !controller.clipboard) {
    await showMessage(`Use ${key("V")} to paste.`);
    return;
  }
  controller.paste(mode, text ?? undefined);
  grid.focus();
}

// MARK: - Find & Replace

const findBar = $("findbar");
const findInput = $<HTMLInputElement>("find-input");
const replaceInput = $<HTMLInputElement>("replace-input");

function findOptions(): FindOptions {
  return {
    text: findInput.value, replacement: replaceInput.value, matchCase: $<HTMLInputElement>("find-case").checked,
    entireCell: $<HTMLInputElement>("find-whole").checked, searchFormulas: true, wholeWorkbook: $<HTMLInputElement>("find-workbook").checked,
  };
}

function showFind(replace: boolean) {
  controller.commitEditingIfNeeded();
  findBar.hidden = false;
  findBar.classList.toggle("replacing", replace || findBar.classList.contains("replacing"));
  findInput.focus();
  findInput.select();
  updateFindCount();
}

function hideFind() {
  findBar.hidden = true;
  findBar.classList.remove("replacing");
  grid.focus();
}

function updateFindCount() {
  const options = findOptions();
  const count = options.text ? controller.findAll(options).length : 0;
  $("find-count").textContent = !options.text ? "" : count ? `${count} found` : "Not found";
}

findInput.addEventListener("input", updateFindCount);
for (const id of ["find-case", "find-whole", "find-workbook"]) $(id).addEventListener("change", updateFindCount);
findInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    if (!controller.findNext(findOptions(), event.shiftKey)) $("find-count").textContent = "Not found";
  } else if (event.key === "Escape") {
    event.preventDefault();
    hideFind();
  }
});
replaceInput.addEventListener("keydown", (event) => {
  if (event.key === "Escape") hideFind();
  if (event.key === "Enter") { event.preventDefault(); controller.replaceCurrent(findOptions()); updateFindCount(); }
});
findBar.addEventListener("click", (event) => {
  const action = (event.target as HTMLElement).closest("button")?.dataset.find;
  switch (action) {
    case "next": controller.findNext(findOptions()); break;
    case "prev": controller.findNext(findOptions(), true); break;
    case "replace": controller.replaceCurrent(findOptions()); break;
    case "replace-all": {
      const count = controller.replaceAll(findOptions());
      $("find-count").textContent = `Replaced ${count}`;
      return;
    }
    case "close": hideFind(); return;
  }
  updateFindCount();
});

// MARK: - Banner (updates)

function showBanner(message: string, buttons: { label: string; primary?: boolean; run: () => void }[]) {
  const banner = $("banner");
  banner.replaceChildren();
  const text = document.createElement("span");
  text.className = "message";
  text.textContent = message;
  banner.append(text);
  for (const b of buttons) {
    const button = document.createElement("button");
    button.textContent = b.label;
    if (b.primary) button.className = "primary";
    button.addEventListener("click", b.run);
    banner.append(button);
  }
  const close = document.createElement("button");
  close.className = "close";
  close.textContent = "×";
  close.setAttribute("aria-label", "Dismiss");
  close.addEventListener("click", hideBanner);
  banner.append(close);
  banner.hidden = false;
}

function hideBanner() {
  $("banner").hidden = true;
}

async function checkUpdates(userInitiated: boolean) {
  try {
    const offer = await checkForUpdate(userInitiated);
    if (!offer) {
      if (userInitiated) await showDialog("You're up to date", `Wired Grid ${APP_VERSION} is the newest version available.`, [{ label: "OK", value: "ok", primary: true }]);
      return;
    }
    const decide = async () => {
      const choice = await updateDialog(offer.version, offer.release.body ?? "");
      if (choice === "download") { hideBanner(); void openURL(offer.url); }
      if (choice === "skip") { hideBanner(); updateSettings({ skippedVersion: offer.version }); }
    };
    if (userInitiated) await decide();
    else showBanner(`Wired Grid ${offer.version} is available.`, [
      { label: "What's New", run: decide },
      { label: "Download", primary: true, run: () => { hideBanner(); void openURL(offer.url); } },
    ]);
  } catch (error) {
    if (userInitiated) await showMessage(`Couldn't check for updates.\n\n${(error as Error).message}`, "warning");
  }
}

async function openSettings() {
  await settingsDialog(() => void checkUpdates(true));
  grid.focus();
}

// MARK: - Menus

const mod = modKey();
const isMac = mod === "⌘";
const key = (k: string) => (isMac ? `⌘${k}` : `Ctrl+${k}`);
const shiftKey = (k: string) => (isMac ? `⇧⌘${k}` : `Ctrl+Shift+${k}`);
const c = controller;

buildMenubar($("menubar"), [
  {
    label: "File",
    items: (): MenuEntry[] => [
      { label: "New", shortcut: key("N"), action: () => void newDocument() },
      { label: "New from Template…", shortcut: shiftKey("N"), action: () => void chooseTemplate() },
      { label: "Open…", shortcut: key("O"), action: () => void openDocument() },
      { label: "Open Recent", submenu: isDesktop ? settings().recentFiles.map((path) => ({ label: basename(path), action: () => void openPath(path) })) : [] },
      "-",
      { label: "Save", shortcut: key("S"), action: () => void saveDocument() },
      { label: "Save As…", shortcut: shiftKey("S"), action: () => void saveDocumentAs() },
      "-",
      { label: "Import Text/CSV…", action: () => void importText() },
      { label: "Export To", submenu: [
        { label: "PDF…", action: () => void exportAs("pdf") },
        ...FORMATS.filter((f) => f.id !== "grid").map((f) => ({ label: `${f.name}…`, action: () => void exportAs(f.id) })),
      ] },
      "-",
      { label: "Page Setup…", action: () => actions.pageSetup() },
      { label: "Print…", shortcut: key("P"), action: () => void printSheet(c) },
      ...(isDesktop ? ["-" as const, { label: "Quit", shortcut: isMac ? "⌘Q" : "Alt+F4", action: () => window.close() }] : []),
    ],
  },
  {
    label: "Edit",
    items: () => [
      { label: c.canUndo ? `Undo ${c.undoName}` : "Undo", shortcut: key("Z"), enabled: c.canUndo, action: () => c.undo() },
      { label: c.canRedo ? `Redo ${c.redoName}` : "Redo", shortcut: isMac ? "⇧⌘Z" : "Ctrl+Y", enabled: c.canRedo, action: () => c.redo() },
      "-",
      { label: "Cut", shortcut: key("X"), action: () => copy(true) },
      { label: "Copy", shortcut: key("C"), action: () => copy(false) },
      { label: "Paste", shortcut: key("V"), action: () => void paste("all") },
      { label: "Paste Special", submenu: (["values", "formats", "transpose", "formulas", "valuesAndNumberFormats", "noBorders", "columnWidths", "link"] as PasteMode[])
        .map((mode) => ({ label: PASTE_TITLES[mode], shortcut: mode === "values" ? shiftKey("V") : undefined, action: () => void paste(mode) })) },
      { label: "Delete", shortcut: "Del", action: () => c.clearContents() },
      { label: "Select All", shortcut: key("A"), action: () => c.selectAll() },
      "-",
      { label: "Fill", submenu: [
        { label: "Down", shortcut: key("D"), action: () => c.fill(true) },
        { label: "Right", shortcut: key("R"), action: () => c.fill(false) },
        { label: "Series…", action: () => actions.fillSeries() },
      ] },
      { label: "Clear", submenu: [
        { label: "All", action: () => c.clearAll() },
        { label: "Formats", action: () => c.clearFormats() },
        { label: "Contents", action: () => c.clearContents() },
        { label: "Notes", action: () => c.clearNotes() },
        { label: "Hyperlinks", action: () => c.clearHyperlinks() },
      ] },
      { label: "Edit Cell", shortcut: "F2", action: () => grid.beginEditing({ mode: "edit" }) },
      "-",
      { label: "Find…", shortcut: key("F"), action: () => showFind(false) },
      { label: "Replace…", shortcut: isMac ? "⌥⌘F" : "Ctrl+H", action: () => showFind(true) },
      { label: "Go To…", shortcut: isMac ? "⌃G" : "Ctrl+G", action: () => actions.goTo() },
      "-",
      { label: "Settings…", shortcut: key(","), action: () => void openSettings() },
    ],
  },
  {
    label: "View",
    items: () => [
      { label: "Zoom In", shortcut: key("+"), action: () => c.setZoom(c.sheet.zoom * 1.25) },
      { label: "Zoom Out", shortcut: key("−"), action: () => c.setZoom(c.sheet.zoom / 1.25) },
      { label: "Actual Size", action: () => c.setZoom(1) },
      { label: "Zoom to Selection", action: () => zoomToSelection() },
      "-",
      { label: "Formula Bar", checked: settings().showFormulaBar, action: () => formulaBar.toggleVisibility() },
      { label: "Status Bar", checked: settings().showStatusBar, action: () => { updateSettings({ showStatusBar: !settings().showStatusBar }); statusBar.applyVisibility(); } },
      { label: "Collapse Ribbon", action: () => ribbon.toggleCollapsed() },
      { label: "Gridlines", checked: c.sheet.showGridlines, action: () => c.toggleGridlines() },
      { label: "Headings", checked: c.sheet.showHeadings, action: () => c.toggleHeadings() },
      { label: "Formulas", checked: c.showFormulas, shortcut: isMac ? "⌃`" : "Ctrl+`", action: () => c.toggleShowFormulas() },
      "-",
      { label: c.hasFrozenPanes ? "Unfreeze Panes" : "Freeze Panes", action: () => c.freezePanes() },
      { label: "Freeze Top Row", action: () => c.freezeTopRow() },
      { label: "Freeze First Column", action: () => c.freezeFirstColumn() },
      "-",
      { label: "Ribbon Tab", submenu: ribbon.tabs.map(([id, title]) => ({ label: title, action: () => ribbon.showTab(id) })) },
    ],
  },
  {
    label: "Insert",
    items: () => [
      { label: "Rows", shortcut: isMac ? "⇧⌘+" : "Ctrl++", action: () => c.insertSheetRows() },
      { label: "Columns", action: () => c.insertSheetColumns() },
      { label: "Cells (Shift Down)", action: () => c.insertCells(true) },
      { label: "Sheet", shortcut: "Shift+F11", action: () => c.addSheet() },
      "-",
      { label: "Chart", submenu: CHART_KINDS.map((kind) => ({ label: CHART_KIND_TITLES[kind], action: () => c.insertChart(kind) })) },
      { label: "Function…", shortcut: "Shift+F3", action: () => actions.insertFunction() },
      { label: "AutoSum", shortcut: "Alt+=", action: () => c.autoSum() },
      { label: "Note", shortcut: "Shift+F2", action: () => actions.editNote() },
      { label: "Hyperlink…", shortcut: key("K"), action: () => actions.insertLink() },
      { label: "Name…", action: () => actions.defineName() },
      "-",
      { label: "Today's Date", shortcut: key(";"), action: () => c.insertCurrentDate() },
      { label: "Current Time", shortcut: shiftKey(";"), action: () => c.insertCurrentTime() },
    ],
  },
  {
    label: "Format",
    items: () => {
      const style = c.activeStyle;
      return [
        { label: "Cells…", shortcut: key("1"), action: () => actions.formatCells() },
        "-",
        { label: "Font", submenu: [
          { label: "Bold", shortcut: key("B"), checked: !!style.bold, action: () => c.toggleBold() },
          { label: "Italic", shortcut: key("I"), checked: !!style.italic, action: () => c.toggleItalic() },
          { label: "Underline", shortcut: key("U"), checked: !!style.underline, action: () => c.toggleUnderline() },
          { label: "Strikethrough", shortcut: key("5"), checked: !!style.strikethrough, action: () => c.toggleStrikethrough() },
          "-",
          { label: "Bigger", shortcut: shiftKey(">"), action: () => c.growFont(true) },
          { label: "Smaller", shortcut: shiftKey("<"), action: () => c.growFont(false) },
        ] },
        { label: "Alignment", submenu: [
          { label: "Align Left", checked: style.horizontal === "left", action: () => c.setHorizontalAlignment("left") },
          { label: "Center", checked: style.horizontal === "center", action: () => c.setHorizontalAlignment("center") },
          { label: "Align Right", checked: style.horizontal === "right", action: () => c.setHorizontalAlignment("right") },
          "-",
          { label: "Wrap Text", checked: !!style.wrap, action: () => c.toggleWrap() },
          { label: "Merge & Center", checked: c.selectionIsMerged, action: () => void c.merge("mergeAndCenter") },
        ] },
        { label: "Number", submenu: [
          ...NUMBER_PRESETS.map(([label, code]) => ({ label, checked: (style.numberFormat ?? "General") === code, action: () => c.setNumberFormat(code) })),
          "-",
          { label: "Increase Decimal", action: () => c.adjustDecimals(1) },
          { label: "Decrease Decimal", action: () => c.adjustDecimals(-1) },
        ] },
        "-",
        { label: "Row", submenu: [
          { label: "Height…", action: () => actions.rowHeight() },
          { label: "AutoFit", action: () => c.autoFitRows(c.selectedRowIndices) },
          { label: "Hide", shortcut: key("9"), action: () => c.hideRows() },
          { label: "Unhide", shortcut: shiftKey("9"), action: () => c.unhideRows() },
        ] },
        { label: "Column", submenu: [
          { label: "Width…", action: () => actions.columnWidth() },
          { label: "AutoFit Selection", action: () => c.autoFitColumns(c.selectedColumnIndices) },
          { label: "Hide", shortcut: key("0"), action: () => c.hideColumns() },
          { label: "Unhide", shortcut: shiftKey("0"), action: () => c.unhideColumns() },
        ] },
        { label: "Sheet", submenu: [
          { label: "Rename", action: () => document.dispatchEvent(new CustomEvent("wg-rename-sheet")) },
          { label: "Duplicate", action: () => c.duplicateSheet(c.activeSheetIndex) },
          { label: "Delete", enabled: c.workbook.sheets.length > 1, action: () => void c.deleteSheet(c.activeSheetIndex) },
          "-",
          { label: "Next Sheet", shortcut: isMac ? "⌥⇟" : "Ctrl+PgDn", action: () => c.activateSheet(c.activeSheetIndex + 1) },
          { label: "Previous Sheet", shortcut: isMac ? "⌥⇞" : "Ctrl+PgUp", action: () => c.activateSheet(c.activeSheetIndex - 1) },
        ] },
        "-",
        { label: "Conditional Formatting…", action: () => actions.conditionalFormat() },
        { label: "Manage Rules…", action: () => actions.manageRules() },
      ];
    },
  },
  {
    label: "Data",
    items: () => [
      { label: "Sort Ascending", action: () => c.quickSort(true) },
      { label: "Sort Descending", action: () => c.quickSort(false) },
      { label: "Custom Sort…", action: () => actions.customSort() },
      "-",
      { label: "Filter", checked: !!c.sheet.filter, shortcut: shiftKey("L"), action: () => c.toggleFilter() },
      { label: "Clear Filter", enabled: !!c.sheet.filter?.criteria.size, action: () => c.clearFilters() },
      { label: "Reapply Filter", enabled: !!c.sheet.filter, action: () => c.reapplyFilter() },
      "-",
      { label: "Text to Columns…", action: () => actions.textToColumns() },
      { label: "Remove Duplicates", action: () => c.removeDuplicates() },
      "-",
      { label: "Calculate Now", shortcut: "F9", action: () => c.recalculate() },
    ],
  },
  {
    label: "Help",
    items: () => [
      { label: "Function Reference", action: () => actions.insertFunction() },
      { label: "Keyboard Shortcuts", action: () => void showShortcuts() },
      "-",
      { label: "Check for Updates…", action: () => void checkUpdates(true) },
      { label: "Wired Grid on GitHub", action: () => void openURL("https://github.com/Wired-Office/Wired-Grid") },
      { label: "About Wired Grid", action: () => actions.about() },
    ],
  },
], () => grid.focus());

function zoomToSelection() {
  const r = c.boundedToContent(primaryRange(c.selection));
  let width = 0, height = 0;
  for (let col = r.start.column; col <= Math.min(r.end.column, r.start.column + 200); col++) width += c.sheet.columnWidths.get(col) ?? 80;
  for (let row = r.start.row; row <= Math.min(r.end.row, r.start.row + 2000); row++) height += c.sheet.rowHeights.get(row) ?? 21;
  const view = grid.scroller;
  const zoom = Math.min((view.clientWidth - 60) / Math.max(width, 1), (view.clientHeight - 40) / Math.max(height, 1));
  c.setZoom(Math.max(0.1, Math.min(4, zoom)));
  c.selectRange(primaryRange(c.selection), c.selection.active);
}

async function showShortcuts() {
  const k = (x: string) => key(x);
  const rows: [string, string][] = [
    ["Edit the active cell", "F2 or double-click"], ["Enter and move down / up", "Enter / Shift+Enter"], ["Enter and move right / left", "Tab / Shift+Tab"],
    ["Fill the selection with the entry", k("Enter")], ["New line in a cell", "Alt+Enter"], ["Toggle $ in references", "F4"],
    ["Jump to the edge of the data", `${k("Arrow")}`], ["Extend the selection", "Shift+Arrow"], ["Select column / row", `${k("Space")} / Shift+Space`],
    ["Select all", k("A")], ["Fill down / right", `${k("D")} / ${k("R")}`], ["AutoSum", "Alt+="],
    ["Bold / italic / underline", `${k("B")} / ${k("I")} / ${k("U")}`], ["Format Cells", k("1")], ["Insert link", k("K")],
    ["Today's date / time", `${k(";")} / ${shiftKey(";")}`], ["Filter", shiftKey("L")], ["Show formulas", "Ctrl+`"],
    ["Next / previous sheet", "Ctrl+PgDn / Ctrl+PgUp"], ["New sheet", "Shift+F11"], ["Zoom", `${k("+")} / ${k("−")} or ${k("scroll")}`],
  ];
  const body = document.createElement("div");
  body.innerHTML = `<div class="list-box" style="max-height:420px">${rows.map(([a, b]) => `<div class="item"><span class="grow">${a}</span><span class="muted">${b}</span></div>`).join("")}</div>`;
  await showDialog("Keyboard Shortcuts", body, [{ label: "OK", value: "ok", primary: true }], { width: "wide" });
  grid.focus();
}

// MARK: - Keyboard shortcuts

window.addEventListener("keydown", (event) => {
  if (event.defaultPrevented || document.querySelector("dialog[open]")) return;
  const target = event.target as HTMLElement;
  const inField = target instanceof HTMLInputElement || (target instanceof HTMLTextAreaElement && !target.classList.contains("cell-editor-input") && !target.classList.contains("formula-field"));
  const editing = c.isEditing;
  const ctrl = isMac ? event.metaKey : event.ctrlKey;
  const k = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  const run = (fn: () => void) => {
    event.preventDefault();
    closePopupMenu();
    fn();
  };

  // Document commands work everywhere.
  if (ctrl && !event.altKey) {
    if (k === "n" && !event.shiftKey) return run(() => void newDocument());
    if (k === "n" && event.shiftKey) return run(() => void chooseTemplate());
    if (k === "o") return run(() => void openDocument());
    if (k === "s") return run(() => void (event.shiftKey ? saveDocumentAs() : saveDocument()));
    if (k === "p") return run(() => void printSheet(c));
    if (k === ",") return run(() => void openSettings());
  }
  if (inField || editing) {
    if (editing && event.key === "F3" && event.shiftKey) run(() => actions.insertFunction());
    return;
  }
  if (event.key === "F9") return run(() => c.recalculate());
  if (event.key === "F5") return run(() => actions.goTo());
  if (event.key === "F2" && event.shiftKey) return run(() => actions.editNote());
  if (event.key === "F3" && event.shiftKey) return run(() => actions.insertFunction());
  if (event.key === "F11" && event.shiftKey) return run(() => c.addSheet());
  if (event.altKey && !ctrl && (event.key === "=" || event.code === "Equal")) return run(() => c.autoSum());
  if (!ctrl) return;
  if (event.key === "PageDown") return run(() => c.activateSheet(c.activeSheetIndex + 1));
  if (event.key === "PageUp") return run(() => c.activateSheet(c.activeSheetIndex - 1));
  if (event.altKey && k === "v") return run(() => void paste("formats"));
  if (event.shiftKey) {
    switch (event.code) {
      case "KeyZ": return run(() => c.redo());
      case "KeyV": return run(() => void paste("values"));
      case "KeyL": return run(() => c.toggleFilter());
      case "KeyF": return isMac ? undefined : run(() => showFind(true));
      case "Digit5": return run(() => c.setNumberFormat("0%"));
      case "Digit4": return run(() => c.setNumberFormat("$#,##0.00"));
      case "Digit1": return run(() => c.setNumberFormat("#,##0.00"));
      case "Digit3": return run(() => c.setNumberFormat("d-mmm-yy"));
      case "Digit9": return run(() => c.unhideRows());
      case "Digit0": return run(() => c.unhideColumns());
      case "Semicolon": return run(() => c.insertCurrentTime());
      case "Period": return run(() => c.growFont(true));
      case "Comma": return run(() => c.growFont(false));
      case "Equal": return run(() => c.insertForSelection());
      default: return;
    }
  }
  switch (k) {
    case "z": return run(() => c.undo());
    case "y": return run(() => c.redo());
    case "a": return run(() => c.selectAll());
    case "d": return run(() => c.fill(true));
    case "r": return run(() => c.fill(false));
    case "f": return run(() => showFind(false));
    case "h": return run(() => showFind(true));
    case "g": return run(() => actions.goTo());
    case "b": return run(() => c.toggleBold());
    case "i": return run(() => c.toggleItalic());
    case "u": return run(() => c.toggleUnderline());
    case "5": return run(() => c.toggleStrikethrough());
    case "1": return run(() => actions.formatCells());
    case "k": return run(() => actions.insertLink());
    case ";": return run(() => c.insertCurrentDate());
    case "9": return run(() => c.hideRows());
    case "0": return run(() => c.hideColumns());
    case "`": return run(() => c.toggleShowFormulas());
    case "-": return run(() => c.deleteForSelection());
    case "+": case "=": return run(() => c.setZoom(c.sheet.zoom * 1.25));
    default: return;
  }
});

// Custom events from the ribbon and tabs.
document.addEventListener("wg-toggle-formula-bar", () => formulaBar.toggleVisibility());
document.addEventListener("wg-zoom-selection", () => zoomToSelection());
document.addEventListener("wg-insert-function", (e) => formulaBar.insertText(`${(e as CustomEvent<string>).detail}(`));
document.addEventListener("wg-insert-text", (e) => formulaBar.insertText((e as CustomEvent<string>).detail));

// Drop a workbook onto the window to open it.
window.addEventListener("dragover", (event) => {
  if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
});
window.addEventListener("drop", (event) => {
  const file = event.dataTransfer?.files[0];
  if (!file || !formatForName(file.name)) return;
  event.preventDefault();
  void file.arrayBuffer().then((buffer) => openDocument({ path: null, name: file.name, bytes: new Uint8Array(buffer) }));
});

onSettingsChange(() => {
  formulaBar.applyVisibility();
  statusBar.applyVisibility();
});

// MARK: - Start

async function start() {
  updateTitle();
  grid.focus();
  await onWindowClose(async () => {
    controller.commitEditingIfNeeded();
    return confirmDiscard();
  });
  const path = await initialFile();
  if (path) await openPath(path);
  else if (settings().showTemplateChooserOnLaunch) await chooseTemplate();
  const scheduleUpdateCheck = () => { if (isCheckDue()) void checkUpdates(false); };
  setTimeout(scheduleUpdateCheck, 5000);
  setInterval(scheduleUpdateCheck, 60 * 60 * 1000);
}

void start();

// Handle for debugging in development builds only.
if (import.meta.env.DEV) (window as unknown as { __wg: unknown }).__wg = { controller, grid, state };

