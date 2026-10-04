import { a1, clampAddress, isSingleCell, quotedSheetName, range, rangeA1, type CellAddress, type CellRange } from "../model/address";
import { luminance } from "../model/color";
import { mergeContaining, sheetIndexNamed, styleAt } from "../model/workbook";
import { referenceRange, tokenize } from "../formula/lexer";
import { toggleAbsolute } from "../formula/rewriter";
import type { WorkbookController } from "../engine/controller";
import { cssFont, fontMetrics, wrapLines } from "./render";
import type { GridGeometry } from "./geometry";
import { analyzeFormula, FunctionHints } from "./hints";
import { currentTheme, REFERENCE_COLORS } from "./theme";

/** What the editor needs from the grid view. */
export interface EditorHost {
  geometry(): GridGeometry;
  overlay: HTMLElement;
  measureContext: CanvasRenderingContext2D;
  setReferenceHighlights(h: { sheet: number; range: CellRange; color: string }[]): void;
  scrollToCell(a: CellAddress): void;
  redraw(): void;
}

/** The formula bar's side of a shared editing session. */
export interface FormulaBarLink {
  showEditingText(text: string): void;
  endEditing(): void;
  focusField(): void;
  /** The formula bar's field while it has focus. */
  activeField(): HTMLTextAreaElement | null;
  syncHighlights(text: string): void;
}

type Mode = "enter" | "edit";

const escapeHTML = (s: string) => s.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!);

/** Formula text as HTML with each reference colored like its box on the grid. */
export function highlightedFormulaHTML(text: string): { html: string; references: { sheet?: string; range: CellRange; color: string }[] } {
  const references: { sheet?: string; range: CellRange; color: string }[] = [];
  if (!text.startsWith("=")) return { html: escapeHTML(text) + "​", references };
  let tokens;
  try {
    tokens = tokenize(text.slice(1));
  } catch {
    return { html: escapeHTML(text) + "​", references };
  }
  let html = "=";
  let cursor = 1;
  const assigned = new Map<string, string>();
  for (const token of tokens) {
    const kind = token.kind;
    if (kind.t !== "cell" && kind.t !== "range") continue;
    const start = token.start + 1;
    html += escapeHTML(text.slice(cursor, start));
    const key = token.text.replace(/\$/g, "").toUpperCase();
    let color = assigned.get(key);
    if (!color) {
      color = REFERENCE_COLORS[assigned.size % REFERENCE_COLORS.length];
      assigned.set(key, color);
    }
    html += `<span style="color:${color}">${escapeHTML(token.text)}</span>`;
    cursor = start + token.length;
    const r = kind.t === "cell" ? range({ row: kind.ref.row, column: kind.ref.column }) : referenceRange(kind.ref);
    references.push({ sheet: kind.ref.sheet, range: r, color });
  }
  html += escapeHTML(text.slice(cursor));
  return { html: html + "​", references };
}

/**
 * One editing session at a time: the in-cell editor and the formula bar share
 * the text, and clicking cells while typing a formula inserts references.
 *
 * The editor's textarea also receives keystrokes while you're not editing
 * (it sits, invisible, over the active cell), so typing starts an entry and
 * input methods for accented and Asian text work.
 */
export class CellEditor {
  readonly input: HTMLTextAreaElement;
  private readonly backdrop: HTMLDivElement;
  private readonly wrapper: HTMLDivElement;
  readonly hints: FunctionHints;
  formulaBar: FormulaBarLink | null = null;

  address: CellAddress = { row: 0, column: 0 };
  sheetIndex = 0;
  mode: Mode = "enter";
  /** The reference inserted by pointing, so the next click replaces it: [start, length]. */
  private pointRange: [number, number] | null = null;
  private pointCursor: CellAddress | null = null;
  private pointAnchor: CellAddress | null = null;
  private insertingReference = false;
  private lastEditWasInsertion = false;

  constructor(private controller: WorkbookController, private host: EditorHost) {
    this.wrapper = document.createElement("div");
    this.wrapper.className = "cell-editor";
    this.backdrop = document.createElement("div");
    this.backdrop.className = "cell-editor-backdrop";
    this.input = document.createElement("textarea");
    this.input.className = "cell-editor-input";
    this.input.spellcheck = false;
    this.input.setAttribute("autocomplete", "off");
    this.input.setAttribute("autocapitalize", "off");
    this.input.setAttribute("aria-label", "Cell");
    this.input.wrap = "off";
    this.wrapper.append(this.backdrop, this.input);
    host.overlay.append(this.wrapper);
    this.hints = new FunctionHints(document.body);
    this.hints.onAccept = (spec, start, end) => this.acceptSuggestion(spec.name, start, end);

    this.input.addEventListener("input", (event) => this.handleInput(event as InputEvent));
    this.input.addEventListener("select", () => this.updateHints());
    this.input.addEventListener("click", () => this.updateHints());
    this.input.addEventListener("keyup", (event) => {
      if (["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key) && this.isActive) this.updateHints();
    });
    this.input.addEventListener("compositionstart", () => {
      if (!this.isActive) this.begin({ mode: "enter", keepText: true });
    });
    this.input.addEventListener("blur", () => {
      // Clicking away (to a toolbar control) keeps the session; the formula bar may take over.
      setTimeout(() => {
        const active = document.activeElement;
        if (this.isActive && active !== this.input && !this.formulaBar?.activeField() && !(active instanceof HTMLElement && active.closest(".dialog, dialog, .menu-items"))) {
          this.hints.hide();
        }
      }, 0);
    });
    this.parkInput();
  }

  get isActive() {
    return this.controller.isEditing;
  }

  get text(): string {
    return this.formulaBar?.activeField()?.value ?? this.input.value;
  }

  get isFormula() {
    return this.text.startsWith("=");
  }

  /** The textarea typing goes to right now. */
  get activeField(): HTMLTextAreaElement {
    return this.formulaBar?.activeField() ?? this.input;
  }

  // MARK: Lifecycle

  begin(options: { initial?: string; mode: Mode; caret?: number; selection?: [number, number]; focusFormulaBar?: boolean; keepText?: boolean }) {
    if (this.isActive) return;
    const c = this.controller;
    const sheet = c.sheet;
    this.address = mergeContaining(sheet, c.selection.active)?.start ?? c.selection.active;
    this.sheetIndex = c.activeSheetIndex;
    this.mode = options.mode;
    this.pointRange = null;
    this.pointCursor = null;
    this.pointAnchor = null;
    const startText = options.keepText ? this.input.value : options.initial ?? c.inputText(this.address);

    const style = styleAt(sheet, this.address.row, this.address.column);
    const zoom = sheet.zoom;
    const theme = currentTheme();
    const { font } = cssFont(style, zoom);
    const fill = style.fillColor ?? theme.cellBackground;
    const text = style.textColor ?? (style.fillColor ? (luminance(style.fillColor) < 0.45 ? "#FFFFFF" : "#000000") : theme.cellText);
    for (const el of [this.input, this.backdrop]) el.style.font = font;
    this.wrapper.style.background = fill;
    this.backdrop.style.color = text;
    this.input.style.caretColor = text;
    this.wrapper.style.setProperty("--editor-border", theme.selection);
    if (!options.keepText) this.input.value = startText;

    c.commitEditingHandler = () => this.commit({});
    c.cancelEditingHandler = () => this.cancel();
    c.setEditing(true);
    this.wrapper.classList.add("editing");
    this.positionEditor();
    this.formulaBar?.showEditingText(startText);

    if (options.focusFormulaBar) {
      this.formulaBar?.focusField();
    } else {
      this.input.focus({ preventScroll: true });
      if (options.selection) this.input.setSelectionRange(options.selection[0], options.selection[0] + options.selection[1]);
      else if (options.caret !== undefined) this.input.setSelectionRange(options.caret, options.caret);
      else if (!options.keepText) this.input.setSelectionRange(startText.length, startText.length);
    }
    this.refreshDecorations();
    this.host.redraw();
  }

  /** Commits the entry; `move` is [rows, columns] to move afterwards. Returns false when the entry was rejected. */
  commit(options: { move?: [number, number]; fillSelection?: boolean; reverseEnter?: boolean; useEnterDirection?: boolean }): boolean {
    if (!this.isActive) return true;
    const c = this.controller;
    const entry = this.text;
    // Formulas must be committed on the sheet they were started on.
    if (c.activeSheetIndex !== this.sheetIndex) c.activateSheet(this.sheetIndex);
    const original = c.inputText(this.address);
    if (entry !== original || options.fillSelection) {
      if (!c.setInput(entry, this.address, !!options.fillSelection)) {
        this.input.focus();
        return false;
      }
    }
    this.end();
    if (options.useEnterDirection) {
      c.moveAfterEnter(!!options.reverseEnter);
    } else if (options.move) {
      const [rows, columns] = options.move;
      if (rows !== 0 || columns !== 0) {
        if (c.isSingleCellSelected || (rows !== 0 && columns !== 0)) c.moveSelection(rows, columns, false);
        else c.advanceWithinSelection(rows + columns > 0, rows !== 0);
      }
    }
    return true;
  }

  cancel() {
    if (this.isActive) this.end();
  }

  private end() {
    this.hints.hide();
    this.controller.commitEditingHandler = null;
    this.controller.cancelEditingHandler = null;
    this.wrapper.classList.remove("editing");
    this.input.value = "";
    this.backdrop.innerHTML = "";
    this.host.setReferenceHighlights([]);
    this.controller.setEditing(false);
    this.formulaBar?.endEditing();
    this.parkInput();
    this.focus();
    this.host.redraw();
  }

  /** Puts keyboard focus back on the grid. */
  focus() {
    this.input.focus({ preventScroll: true });
  }

  /** While not editing, the input waits invisibly over the active cell (so IME windows appear there). */
  parkInput() {
    if (this.isActive) return;
    const g = this.host.geometry();
    const a = this.controller.selection.active;
    const r = g.cellRect(a);
    const x = Math.min(Math.max(r.x, g.headerWidth), Math.max(g.width - 20, 0));
    const y = Math.min(Math.max(r.y, g.headerHeight), Math.max(g.height - 20, 0));
    Object.assign(this.wrapper.style, { left: `${x}px`, top: `${y}px`, width: "2px", height: `${Math.max(r.height, 16)}px` });
  }

  // MARK: Layout

  positionEditor() {
    if (!this.isActive) {
      this.parkInput();
      return;
    }
    const g = this.host.geometry();
    const c = this.controller;
    const sheet = c.sheet;
    const merged = mergeContaining(sheet, this.address) ?? range(this.address);
    const cell = g.rangeRect(merged);
    const style = styleAt(sheet, this.address.row, this.address.column);
    const { font, size } = cssFont(style, sheet.zoom);
    const ctx = this.host.measureContext;
    ctx.font = font;
    const metrics = fontMetrics(ctx, font, size);
    const lineHeight = Math.ceil(metrics.ascent + metrics.descent) + 1;
    const lines = this.input.value.split("\n");
    const textWidth = Math.max(...lines.map((l) => ctx.measureText(l).width)) + 14;
    const maxWidth = Math.max(g.width - cell.x - 4, cell.width);
    const wraps = !!style.wrap || textWidth > maxWidth;
    let width = Math.max(cell.width + 2, Math.min(textWidth, maxWidth));
    if (wraps) width = style.wrap ? cell.width + 2 : maxWidth;
    const lineCount = wraps ? wrapLines(ctx, this.input.value, width - 10).length : lines.length;
    const padY = Math.max(2, 3 * sheet.zoom);
    const height = Math.max(cell.height + 2, lineCount * lineHeight + padY * 2 + 2);
    const wrapMode = wraps ? "pre-wrap" : "pre";
    for (const el of [this.input, this.backdrop]) {
      el.style.whiteSpace = wrapMode;
      el.style.lineHeight = `${lineHeight}px`;
      el.style.padding = `${padY}px 3px`;
    }
    this.input.wrap = wraps ? "soft" : "off";
    Object.assign(this.wrapper.style, {
      left: `${cell.x - 1}px`,
      top: `${cell.y - 1}px`,
      width: `${width}px`,
      height: `${Math.min(height, Math.max(g.height - cell.y, cell.height + 2))}px`,
    });
  }

  // MARK: Text changes

  private handleInput(event: InputEvent) {
    if (!this.isActive) {
      // Typing over a cell starts an entry that replaces it.
      this.begin({ mode: "enter", keepText: true });
    }
    this.lastEditWasInsertion = (event.inputType?.startsWith("insert") ?? true) && event.inputType !== "insertFromPaste";
    this.textChanged();
  }

  private textChanged() {
    if (!this.insertingReference) {
      this.pointRange = null;
      this.pointCursor = null;
    }
    this.formulaBar?.showEditingText(this.input.value);
    this.applyAutoComplete();
    this.positionEditor();
    this.refreshDecorations();
  }

  /** Called by the formula bar as you type in it. */
  formulaBarTextChanged(text: string) {
    if (!this.isActive) return;
    this.input.value = text;
    if (!this.insertingReference) {
      this.pointRange = null;
      this.pointCursor = null;
    }
    this.positionEditor();
    this.refreshDecorations();
  }

  private applyAutoComplete() {
    if (!this.lastEditWasInsertion || this.isFormula) return;
    this.lastEditWasInsertion = false;
    const current = this.input.value;
    if (this.input.selectionStart !== current.length || this.input.selectionEnd !== current.length) return;
    const completion = this.controller.autoCompletion(current, this.address);
    if (!completion) return;
    const suffix = completion.slice(current.length);
    if (!suffix) return;
    this.input.value = current + suffix;
    this.input.setSelectionRange(current.length, current.length + suffix.length);
    this.formulaBar?.showEditingText(this.input.value);
  }

  /** Colors references in the editor and draws matching boxes on the grid. */
  refreshDecorations() {
    const text = this.input.value;
    const { html, references } = highlightedFormulaHTML(text);
    this.backdrop.innerHTML = html;
    this.formulaBar?.syncHighlights(text);
    const highlights = references.map((r) => {
      const index = r.sheet !== undefined ? sheetIndexNamed(this.controller.workbook, r.sheet) : this.sheetIndex;
      return { sheet: index < 0 ? -1 : index, range: r.range, color: r.color };
    });
    this.host.setReferenceHighlights(highlights);
    this.updateHints();
  }

  updateHints() {
    if (!this.isActive) {
      this.hints.hide();
      return;
    }
    const field = this.activeField;
    const context = analyzeFormula(field.value, field.selectionStart ?? field.value.length);
    this.hints.update(context, field.getBoundingClientRect());
  }

  private acceptSuggestion(name: string, start: number, end: number) {
    const field = this.activeField;
    const replacement = name + "(";
    field.setRangeText(replacement, start, end, "end");
    field.focus();
    this.hints.hide();
    if (field === this.input) this.textChanged();
    else {
      this.formulaBarTextChanged(field.value);
      this.formulaBar?.showEditingText(field.value);
    }
  }

  // MARK: Pointing at references

  /** True when the caret sits where a reference could go (after an operator, "(" or ","). */
  get canInsertReference(): boolean {
    if (!this.isActive || !this.isFormula) return false;
    const field = this.activeField;
    const caret = field.selectionStart ?? 0;
    if (this.pointRange && (this.pointRange[0] + this.pointRange[1] === caret || (this.pointRange[0] === caret && this.pointRange[1] === (field.selectionEnd ?? caret) - caret))) return true;
    let i = Math.min(caret, field.value.length) - 1;
    while (i >= 0 && field.value[i] === " ") i--;
    return i >= 0 && "=(,;+-*/^&<>:".includes(field.value[i]);
  }

  insertReference(r: CellRange) {
    const field = this.activeField;
    let reference = isSingleCell(r) ? a1(r.start) : rangeA1(r);
    if (this.controller.activeSheetIndex !== this.sheetIndex) reference = quotedSheetName(this.controller.sheet.name) + "!" + reference;
    const caret = field.selectionStart ?? field.value.length;
    let target: [number, number] = [caret, (field.selectionEnd ?? caret) - caret];
    if (this.pointRange && (this.pointRange[0] + this.pointRange[1] === caret || this.pointRange[0] === caret)) target = this.pointRange;
    this.insertingReference = true;
    field.setRangeText(reference, target[0], target[0] + target[1], "end");
    this.pointRange = [target[0], reference.length];
    if (field === this.input) this.textChanged();
    else {
      this.formulaBarTextChanged(field.value);
      this.formulaBar?.showEditingText(field.value);
    }
    this.insertingReference = false;
    field.setSelectionRange(target[0] + reference.length, target[0] + reference.length);
    field.focus({ preventScroll: true });
  }

  /** Arrow keys in point mode move (or with Shift, extend) the pointed reference. */
  private movePointer(rows: number, columns: number, extend: boolean) {
    const cursor = this.pointCursor ?? this.address;
    const next = clampAddress({ row: cursor.row + rows, column: cursor.column + columns });
    if (!extend || !this.pointAnchor) this.pointAnchor = extend ? cursor : next;
    this.pointCursor = next;
    const r = extend ? range(this.pointAnchor ?? next, next) : range(next);
    if (!extend) this.pointAnchor = next;
    this.insertReference(r);
    this.host.scrollToCell(next);
  }

  toggleAbsoluteReference() {
    const field = this.activeField;
    if (!field.value.startsWith("=")) return;
    const caret = Math.max((field.selectionStart ?? 1) - 1, 0);
    const result = toggleAbsolute(field.value.slice(1), caret);
    if (!result) return;
    field.value = "=" + result.text;
    field.setSelectionRange(result.start + result.length + 1, result.start + result.length + 1);
    this.pointRange = null;
    if (field === this.input) this.textChanged();
    else {
      this.formulaBarTextChanged(field.value);
      this.formulaBar?.showEditingText(field.value);
    }
  }

  // MARK: Keys

  /** Key handling shared by the cell editor and the formula bar. Returns true when handled. */
  handleKey(event: KeyboardEvent, field: HTMLTextAreaElement): boolean {
    if (event.isComposing) return false;
    const ctrl = event.ctrlKey || event.metaKey;
    switch (event.key) {
      case "Enter":
        if (event.altKey) {
          field.setRangeText("\n", field.selectionStart ?? 0, field.selectionEnd ?? 0, "end");
          if (field === this.input) this.textChanged();
          else this.formulaBarTextChanged(field.value);
          return true;
        }
        if (ctrl) this.commit({ fillSelection: !this.controller.isSingleCellSelected });
        else this.commit({ reverseEnter: event.shiftKey, useEnterDirection: true });
        return true;
      case "Tab":
        if (this.hints.isShowingList && this.hints.selectedItem) {
          this.acceptSuggestion(this.hints.selectedItem.name, this.hints.replaceStart, this.hints.replaceEnd);
          return true;
        }
        this.commit({ move: [0, event.shiftKey ? -1 : 1] });
        return true;
      case "Escape":
        if (this.hints.isShowingList) {
          this.hints.hide();
          return true;
        }
        this.cancel();
        return true;
      case "F4":
        this.toggleAbsoluteReference();
        return true;
      case "ArrowUp":
      case "ArrowDown":
        if (this.hints.isShowingList && !event.shiftKey) {
          this.hints.moveSelection(event.key === "ArrowUp" ? -1 : 1);
          return true;
        }
        return this.arrow(event.key === "ArrowUp" ? [-1, 0] : [1, 0], event.shiftKey, field);
      case "ArrowLeft":
      case "ArrowRight":
        if (ctrl) return false;
        return this.arrow(event.key === "ArrowLeft" ? [0, -1] : [0, 1], event.shiftKey, field);
      default:
        return false;
    }
  }

  private arrow(delta: [number, number], extend: boolean, field: HTMLTextAreaElement): boolean {
    // Point mode: arrows pick a reference.
    if (this.isFormula && this.canInsertReference && (this.mode === "enter" || this.pointRange)) {
      this.movePointer(delta[0], delta[1], extend);
      return true;
    }
    // Enter mode: arrows finish the entry and move.
    if (this.mode === "enter" && !extend && field === this.input) {
      this.commit({ move: delta });
      return true;
    }
    return false;
  }
}
