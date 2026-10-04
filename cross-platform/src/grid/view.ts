import {
  ALL_CELLS, MAX_COLUMNS, MAX_ROWS, cellKey, columnCount, isValidAddress, isWholeColumns, isWholeRows, offsetRange, range, rangeRC, rowCount,
  sameRange, wholeColumns, wholeRows, type CellAddress, type CellRange,
} from "../model/address";
import { FormulaError } from "../model/values";
import { DEFAULT_COLUMN_WIDTH, DEFAULT_ROW_HEIGHT, columnWidth, contentExtent, getCell, mergeContaining, rowHeight, type ChartObject } from "../model/workbook";
import { PASTE_TITLES, type PasteMode, type WorkbookController } from "../engine/controller";
import { ConditionalFormatter } from "../engine/conditional";
import { isMultipleSelection, primaryRange, selectedColumns, selectedRows, selectionContains } from "../engine/selection";
import { settings } from "../settings";
import { closePopupMenu, showPopupMenu } from "../ui/popup";
import type { MenuEntry } from "../ui/menubar";
import { showFilterPopover } from "../ui/filterPopover";
import { ChartLayer } from "./charts";
import { CellEditor } from "./editor";
import { GridGeometry, insetRect, rectContains, type Rect } from "./geometry";
import { fillHandleRect, filterButtonRect, GridRenderer, type Overlays } from "./render";
import { currentTheme, onThemeChange } from "./theme";

type Region =
  | { kind: "corner" }
  | { kind: "columnHeader"; column: number }
  | { kind: "columnBorder"; column: number }
  | { kind: "rowHeader"; row: number }
  | { kind: "rowBorder"; row: number }
  | { kind: "fillHandle" }
  | { kind: "selectionEdge" }
  | { kind: "filterButton"; column: number }
  | { kind: "cell"; address: CellAddress }
  | { kind: "none" };

type DragMode =
  | { kind: "none" }
  | { kind: "selecting" }
  | { kind: "columns"; anchor: number }
  | { kind: "rows"; anchor: number }
  | { kind: "resizeColumn"; column: number; startX: number; startWidth: number }
  | { kind: "resizeRow"; row: number; startY: number; startHeight: number }
  | { kind: "fill"; source: CellRange }
  | { kind: "move"; source: CellRange; grab: CellAddress }
  | { kind: "point"; anchor: CellAddress }
  /** A press on the fill handle or selection border that hasn't moved far enough to count as a drag. */
  | { kind: "pending"; fill: boolean; startX: number; startY: number; cell: CellAddress; source: CellRange; grab: CellAddress };

/** What the grid asks the window for (dialogs and system services). */
export interface GridCommands {
  formatCells(): void;
  customSort(): void;
  editNote(a: CellAddress): void;
  defineName(): void;
  promptColumnWidth(): void;
  promptRowHeight(): void;
  editChart(chart: ChartObject): void;
  openURL(url: string): void;
  copy(cut: boolean): void;
  paste(mode: PasteMode): void;
  insertLink(): void;
}

const DRAG_THRESHOLD = 4;

/**
 * Draws the worksheet on a canvas and handles its input. A scrolling element
 * with a large spacer provides native scrolling; the canvas stays put and
 * draws just the visible cells, so headers and frozen panes stay fixed and
 * the full 1,048,576 × 16,384 sheet costs nothing.
 */
export class GridView {
  readonly scroller: HTMLDivElement;
  private readonly content: HTMLDivElement;
  private readonly stage: HTMLDivElement;
  private readonly canvas: HTMLCanvasElement;
  readonly overlay: HTMLDivElement;
  readonly editor: CellEditor;
  readonly charts: ChartLayer;
  readonly measureContext: CanvasRenderingContext2D;
  private readonly renderer: GridRenderer;
  private readonly noteBubble: HTMLDivElement;

  private scrollX = 0;
  private scrollY = 0;
  private viewWidth = 0;
  private viewHeight = 0;
  /** How far the scrollable content currently reaches; grows as you scroll, like Excel. */
  private extentRows = 300;
  private extentColumns = 50;
  private frame = 0;
  private dragMode: DragMode = { kind: "none" };
  private lastPointer: { x: number; y: number } | null = null;
  private autoScrollTimer: number | null = null;
  private marchingTimer: number | null = null;
  private noteAddress: CellAddress | null = null;
  private overlays: Overlays = { referenceHighlights: [], dragPreview: null, marchingPhase: 0, resizeGuide: null, editing: false };

  constructor(parent: HTMLElement, private controller: WorkbookController, private commands: GridCommands) {
    this.scroller = document.createElement("div");
    this.scroller.className = "grid-scroller";
    this.content = document.createElement("div");
    this.content.className = "grid-content";
    this.stage = document.createElement("div");
    this.stage.className = "grid-stage";
    this.canvas = document.createElement("canvas");
    this.canvas.className = "grid-canvas";
    this.canvas.setAttribute("role", "grid");
    this.canvas.setAttribute("aria-label", "Worksheet");
    this.overlay = document.createElement("div");
    this.overlay.className = "grid-overlay";
    this.stage.append(this.canvas, this.overlay);
    this.content.append(this.stage);
    this.scroller.append(this.content);
    parent.append(this.scroller);
    this.noteBubble = document.createElement("div");
    this.noteBubble.className = "note-bubble";
    this.noteBubble.hidden = true;
    document.body.append(this.noteBubble);

    this.measureContext = document.createElement("canvas").getContext("2d")!;
    this.renderer = new GridRenderer(controller, new ConditionalFormatter(controller.calculator));
    this.charts = new ChartLayer(this.overlay, controller, () => this.geometry(), (chart) => commands.editChart(chart));
    this.editor = new CellEditor(controller, {
      geometry: () => this.geometry(),
      overlay: this.overlay,
      measureContext: this.measureContext,
      setReferenceHighlights: (h) => { this.overlays.referenceHighlights = h; this.redraw(); },
      scrollToCell: (a) => this.scrollToCell(a),
      redraw: () => this.redraw(),
    });
    controller.beginEditingHandler = (text, selection) => this.beginEditing({ initial: text, mode: "edit", selection });

    this.scroller.addEventListener("scroll", () => this.scrolled(), { passive: true });
    this.scroller.addEventListener("wheel", (event) => this.wheel(event), { passive: false });
    this.canvas.addEventListener("mousedown", (event) => this.mouseDown(event));
    this.canvas.addEventListener("mousemove", (event) => { if (this.dragMode.kind === "none") this.hover(event); });
    this.canvas.addEventListener("mouseleave", () => this.hideNote());
    this.canvas.addEventListener("contextmenu", (event) => this.contextMenu(event));
    this.canvas.addEventListener("dblclick", (event) => event.preventDefault());
    this.editor.input.addEventListener("keydown", (event) => this.keyDown(event));
    this.editor.input.addEventListener("copy", (event) => this.clipboardEvent(event, "copy"));
    this.editor.input.addEventListener("cut", (event) => this.clipboardEvent(event, "cut"));
    this.editor.input.addEventListener("paste", (event) => this.clipboardEvent(event, "paste"));
    new ResizeObserver(() => this.layout()).observe(this.scroller);
    onThemeChange(() => { this.redraw(); this.charts.refresh(); });

    controller.subscribe((kind) => {
      switch (kind) {
        case "content":
          this.redraw();
          this.charts.sync();
          break;
        case "selection":
          this.redraw();
          if (this.controller.selectedChartId && !this.controller.isEditing) this.controller.selectChart(null);
          this.editor.parkInput();
          break;
        case "geometry":
        case "load":
        case "sheets":
          this.geometryChanged(kind !== "geometry");
          break;
        case "scroll":
          this.scrollToCell(this.controller.selection.active);
          break;
        case "marquee":
          this.updateMarchingAnts();
          break;
        case "chart":
          this.charts.sync();
          if (this.controller.selectedChartId) this.overlay.querySelector<HTMLElement>(".chart-view.selected")?.focus({ preventScroll: true });
          break;
        case "editing":
          this.overlays.editing = this.controller.isEditing;
          this.redraw();
          break;
      }
    });
    this.layout();
  }

  // MARK: Geometry and layout

  geometry(): GridGeometry {
    const sheet = this.controller.sheet;
    return new GridGeometry(sheet, sheet.zoom, this.scrollX, this.scrollY, this.viewWidth, this.viewHeight);
  }

  private layout() {
    this.viewWidth = this.scroller.clientWidth;
    this.viewHeight = this.scroller.clientHeight;
    const dpr = window.devicePixelRatio || 1;
    this.canvas.width = Math.max(1, Math.round(this.viewWidth * dpr));
    this.canvas.height = Math.max(1, Math.round(this.viewHeight * dpr));
    for (const el of [this.canvas, this.stage]) Object.assign(el.style, { width: `${this.viewWidth}px`, height: `${this.viewHeight}px` });
    this.updateContentSize();
    this.drawNow();
    this.charts.layout();
    this.editor.positionEditor();
  }

  private updateContentSize() {
    const g = this.geometry();
    const size = g.contentSize(this.extentRows, this.extentColumns);
    this.content.style.width = `${Math.max(size.width, this.viewWidth + 1)}px`;
    this.content.style.height = `${Math.max(size.height, this.viewHeight + 1)}px`;
  }

  private geometryChanged(resetScroll: boolean) {
    const used = contentExtent(this.controller.sheet);
    const active = this.controller.selection.active;
    this.extentRows = Math.max(300, used.row + 100, active.row + 50);
    this.extentColumns = Math.max(50, used.column + 20, active.column + 10);
    this.updateContentSize();
    if (resetScroll) {
      this.scroller.scrollTo(0, 0);
      this.scrollX = 0;
      this.scrollY = 0;
      this.scrollToCell(active);
    }
    this.charts.sync();
    this.redraw();
    this.editor.positionEditor();
  }

  private scrolled() {
    this.scrollX = Math.max(this.scroller.scrollLeft, 0);
    this.scrollY = Math.max(this.scroller.scrollTop, 0);
    // Grow the scrollable area as you approach its end, like Excel.
    let grew = false;
    if (this.scrollY + this.viewHeight > this.content.offsetHeight - this.viewHeight && this.extentRows < MAX_ROWS) {
      this.extentRows = Math.min(this.extentRows + Math.max(200, Math.floor(this.extentRows / 4)), MAX_ROWS);
      grew = true;
    }
    if (this.scrollX + this.viewWidth > this.content.offsetWidth - this.viewWidth && this.extentColumns < MAX_COLUMNS) {
      this.extentColumns = Math.min(this.extentColumns + 20, MAX_COLUMNS);
      grew = true;
    }
    if (grew) this.updateContentSize();
    this.drawNow();
    this.charts.layout();
    this.editor.positionEditor();
    this.hideNote();
  }

  scrollBy(dx: number, dy: number) {
    const maxY = this.content.offsetHeight - this.viewHeight;
    const maxX = this.content.offsetWidth - this.viewWidth;
    if (this.scroller.scrollTop + dy > maxY - 10) { this.extentRows = Math.min(this.extentRows + 500, MAX_ROWS); this.updateContentSize(); }
    if (this.scroller.scrollLeft + dx > maxX - 10) { this.extentColumns = Math.min(this.extentColumns + 20, MAX_COLUMNS); this.updateContentSize(); }
    this.scroller.scrollBy(dx, dy);
  }

  /** Scrolls just enough to show a cell. */
  scrollToCell(a: CellAddress) {
    if (a.row + 50 > this.extentRows) { this.extentRows = Math.min(a.row + 200, MAX_ROWS); this.updateContentSize(); }
    if (a.column + 10 > this.extentColumns) { this.extentColumns = Math.min(a.column + 20, MAX_COLUMNS); this.updateContentSize(); }
    const g = this.geometry();
    const body = g.bodyRect;
    let x = this.scroller.scrollLeft, y = this.scroller.scrollTop;
    if (a.column >= g.frozenColumns) {
      const left = g.columns.offset(a.column) - g.frozenWidth, right = g.columns.end(a.column) - g.frozenWidth;
      if (left < x) x = left;
      else if (right > x + body.width) x = Math.min(right - body.width, left);
    }
    if (a.row >= g.frozenRows) {
      const top = g.rows.offset(a.row) - g.frozenHeight, bottom = g.rows.end(a.row) - g.frozenHeight;
      if (top < y) y = top;
      else if (bottom > y + body.height) y = Math.min(bottom - body.height, top);
    }
    x = Math.max(x, 0);
    y = Math.max(y, 0);
    if (Math.abs(x - this.scroller.scrollLeft) > 0.5 || Math.abs(y - this.scroller.scrollTop) > 0.5) {
      this.scroller.scrollTo(x, y);
      this.scrolled();
    }
  }

  // MARK: Drawing

  redraw() {
    if (this.frame) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.drawNow();
    });
  }

  private drawNow() {
    if (this.frame) {
      cancelAnimationFrame(this.frame);
      this.frame = 0;
    }
    const ctx = this.canvas.getContext("2d");
    if (!ctx || !this.viewWidth || !this.viewHeight) return;
    const dpr = window.devicePixelRatio || 1;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    this.renderer.pixel = 1 / dpr;
    this.renderer.draw(ctx, this.geometry(), currentTheme(), this.overlays);
  }

  private updateMarchingAnts() {
    const active = !!this.controller.clipboardMarquee;
    if (active && this.marchingTimer === null) {
      this.marchingTimer = window.setInterval(() => {
        this.overlays.marchingPhase = (this.overlays.marchingPhase + 1) % 8;
        this.redraw();
      }, 80);
    } else if (!active && this.marchingTimer !== null) {
      clearInterval(this.marchingTimer);
      this.marchingTimer = null;
    }
    this.redraw();
  }

  // MARK: Editing

  beginEditing(options: { initial?: string; mode: "enter" | "edit"; selection?: [number, number]; caret?: number; focusFormulaBar?: boolean }) {
    if (this.controller.isEditing) return;
    this.scrollToCell(this.controller.selection.active);
    this.editor.begin(options);
  }

  focus() {
    this.editor.focus();
  }

  // MARK: Hit testing

  private point(event: MouseEvent) {
    const rect = this.canvas.getBoundingClientRect();
    return { x: event.clientX - rect.left, y: event.clientY - rect.top };
  }

  private region(x: number, y: number): Region {
    const c = this.controller;
    const g = this.geometry();
    if (x < g.headerWidth && y < g.headerHeight) return { kind: "corner" };
    if (y < g.headerHeight) {
      const column = g.columnAt(x);
      const edge = g.x(column) + g.columns.size(column);
      if (Math.abs(x - edge) <= 4) return { kind: "columnBorder", column };
      if (Math.abs(x - g.x(column)) <= 3 && column > 0) {
        // The border on the left belongs to the previous visible column.
        let previous = column - 1;
        while (previous > 0 && g.columns.isHidden(previous)) previous--;
        return { kind: "columnBorder", column: previous };
      }
      return { kind: "columnHeader", column };
    }
    if (x < g.headerWidth) {
      const row = g.rowAt(y);
      const edge = g.y(row) + g.rows.size(row);
      if (Math.abs(y - edge) <= 3) return { kind: "rowBorder", row };
      if (Math.abs(y - g.y(row)) <= 2 && row > 0) {
        let previous = row - 1;
        while (previous > 0 && g.rows.isHidden(previous)) previous--;
        return { kind: "rowBorder", row: previous };
      }
      return { kind: "rowHeader", row };
    }
    const primary = primaryRange(c.selection);
    const whole = isWholeColumns(primary) || isWholeRows(primary);
    if (!c.isEditing && !isMultipleSelection(c.selection) && !whole && rectContains(insetRect(fillHandleRect(g, primary), -2, -2), x, y)) return { kind: "fillHandle" };
    const filter = c.sheet.filter;
    if (filter && g.rowAt(y) === filter.range.start.row) {
      const column = g.columnAt(x);
      if (column >= filter.range.start.column && column <= filter.range.end.column && rectContains(filterButtonRect(column, filter.range.start.row, g), x, y)) return { kind: "filterButton", column };
    }
    if (!c.isEditing && !isMultipleSelection(c.selection) && !whole) {
      const rect = this.renderer.clampedRect(primary, g);
      if (rectContains(insetRect(rect, -2, -2), x, y) && !rectContains(insetRect(rect, 2, 2), x, y)) return { kind: "selectionEdge" };
    }
    return { kind: "cell", address: g.addressAt(x, y) };
  }

  private cursor(region: Region, event?: MouseEvent): string {
    switch (region.kind) {
      case "columnBorder": return "col-resize";
      case "rowBorder": return "row-resize";
      case "fillHandle": return "crosshair";
      case "selectionEdge": return "move";
      case "columnHeader": return "s-resize";
      case "rowHeader": return "e-resize";
      case "cell": {
        const link = getCell(this.controller.sheet, region.address.row, region.address.column)?.link;
        return link && (event?.ctrlKey || event?.metaKey) ? "pointer" : "cell";
      }
      default: return "default";
    }
  }

  // MARK: Mouse

  private mouseDown(event: MouseEvent) {
    if (event.button !== 0) return;
    closePopupMenu();
    const c = this.controller;
    const { x, y } = this.point(event);
    const region = this.region(x, y);
    const shift = event.shiftKey, ctrl = event.ctrlKey || event.metaKey;
    event.preventDefault();

    // Pointing at cells while typing a formula inserts references.
    if (c.isEditing && this.editor.canInsertReference && region.kind === "cell") {
      this.editor.insertReference(range(region.address));
      this.startDrag({ kind: "point", anchor: region.address }, x, y);
      return;
    }
    if (c.isEditing && region.kind === "cell" && region.address.row === this.editor.address.row && region.address.column === this.editor.address.column) {
      this.editor.focus();
      return;
    }
    if (c.isEditing && !c.commitEditingIfNeeded()) return;
    this.focus();
    c.selectChart(null);

    switch (region.kind) {
      case "corner":
        c.selectRange(ALL_CELLS, c.selection.active, false);
        return;
      case "columnHeader": {
        if (shift && isWholeColumns(primaryRange(c.selection))) {
          const anchor = c.selection.anchor.column;
          c.selectColumns(Math.min(anchor, region.column), Math.max(anchor, region.column));
          c.setSelection({ ...c.selection, anchor: { row: 0, column: anchor } }, false);
          this.startDrag({ kind: "columns", anchor }, x, y);
        } else {
          c.selectColumns(region.column, region.column, ctrl);
          this.startDrag({ kind: "columns", anchor: region.column }, x, y);
        }
        return;
      }
      case "rowHeader": {
        if (shift && isWholeRows(primaryRange(c.selection))) {
          const anchor = c.selection.anchor.row;
          c.selectRows(Math.min(anchor, region.row), Math.max(anchor, region.row));
          c.setSelection({ ...c.selection, anchor: { row: anchor, column: 0 } }, false);
          this.startDrag({ kind: "rows", anchor }, x, y);
        } else {
          c.selectRows(region.row, region.row, ctrl);
          this.startDrag({ kind: "rows", anchor: region.row }, x, y);
        }
        return;
      }
      case "columnBorder": {
        if (event.detail >= 2) {
          const columns = selectedColumns(c.selection).has(region.column) ? [...selectedColumns(c.selection)].sort((a, b) => a - b) : [region.column];
          c.autoFitColumns(columns);
          return;
        }
        const g = this.geometry();
        this.startDrag({ kind: "resizeColumn", column: region.column, startX: x, startWidth: g.columns.size(region.column) / g.zoom }, x, y);
        this.updateResizeGuide(x, y);
        return;
      }
      case "rowBorder": {
        if (event.detail >= 2) {
          const rows = selectedRows(c.selection).has(region.row) ? [...selectedRows(c.selection)].sort((a, b) => a - b) : [region.row];
          c.autoFitRows(rows);
          return;
        }
        const g = this.geometry();
        this.startDrag({ kind: "resizeRow", row: region.row, startY: y, startHeight: g.rows.size(region.row) / g.zoom }, x, y);
        this.updateResizeGuide(x, y);
        return;
      }
      case "fillHandle":
      case "selectionEdge": {
        const a = this.geometry().addressAt(x, y);
        this.startDrag({ kind: "pending", fill: region.kind === "fillHandle", startX: x, startY: y, cell: a, source: primaryRange(c.selection), grab: a }, x, y);
        return;
      }
      case "filterButton": {
        const rect = filterButtonRect(region.column, c.sheet.filter!.range.start.row, this.geometry());
        const bounds = this.canvas.getBoundingClientRect();
        showFilterPopover(c, region.column, new DOMRect(bounds.left + rect.x, bounds.top + rect.y, rect.width, rect.height), () => this.focus());
        return;
      }
      case "cell": {
        const link = getCell(c.sheet, region.address.row, region.address.column)?.link;
        if (ctrl && link && !shift) {
          const url = c.followLink(region.address);
          if (url) this.commands.openURL(url);
          return;
        }
        if (event.detail >= 2) {
          c.select(region.address, { scroll: false });
          this.beginEditing({ mode: "edit", caret: this.caretForClick(region.address, x) });
          return;
        }
        c.select(region.address, { extend: shift, add: ctrl && !shift, scroll: false });
        this.startDrag({ kind: "selecting" }, x, y);
        return;
      }
      default:
        return;
    }
  }

  /** Where in the cell's text a double-click lands, for placing the caret. */
  private caretForClick(a: CellAddress, x: number): number | undefined {
    const text = this.controller.inputText(a);
    if (!text) return undefined;
    const g = this.geometry();
    const rect = g.cellRect(a);
    const ctx = this.measureContext;
    ctx.font = `${12 * g.zoom}px sans-serif`;
    const local = x - rect.x - 3;
    for (let i = 0; i <= text.length; i++) if (ctx.measureText(text.slice(0, i)).width >= local) return i;
    return text.length;
  }

  private startDrag(mode: DragMode, x: number, y: number) {
    this.dragMode = mode;
    this.lastPointer = { x, y };
    const move = (event: MouseEvent) => {
      const p = this.point(event);
      this.lastPointer = p;
      this.handleDrag(p.x, p.y, event);
      this.updateAutoScroll();
    };
    const up = (event: MouseEvent) => {
      document.removeEventListener("mousemove", move);
      document.removeEventListener("mouseup", up);
      this.stopAutoScroll();
      this.mouseUp(event);
    };
    document.addEventListener("mousemove", move);
    document.addEventListener("mouseup", up);
  }

  private handleDrag(x: number, y: number, event?: MouseEvent) {
    const c = this.controller;
    const g = this.geometry();
    const a = g.addressAt(Math.max(x, g.headerWidth + 1), Math.max(y, g.headerHeight + 1));
    if (this.dragMode.kind === "pending") {
      const d = this.dragMode;
      if (Math.hypot(x - d.startX, y - d.startY) < DRAG_THRESHOLD) return;
      this.dragMode = d.fill ? { kind: "fill", source: d.source } : { kind: "move", source: d.source, grab: d.grab };
    }
    const mode = this.dragMode;
    switch (mode.kind) {
      case "selecting":
        c.select(a, { extend: true, scroll: false });
        break;
      case "columns": {
        const ranges = [...c.selection.ranges];
        ranges[ranges.length - 1] = wholeColumns(Math.min(mode.anchor, a.column), Math.max(mode.anchor, a.column));
        c.setSelection({ ...c.selection, ranges }, false);
        break;
      }
      case "rows": {
        const ranges = [...c.selection.ranges];
        ranges[ranges.length - 1] = wholeRows(Math.min(mode.anchor, a.row), Math.max(mode.anchor, a.row));
        c.setSelection({ ...c.selection, ranges }, false);
        break;
      }
      case "resizeColumn":
      case "resizeRow":
        this.updateResizeGuide(x, y);
        break;
      case "fill": {
        // Extend along whichever axis the pointer moved farther.
        const source = mode.source;
        const rect = g.rangeRect(source);
        const right = rect.x + rect.width, bottom = rect.y + rect.height;
        const dx = x > right ? x - right : x < rect.x ? rect.x - x : 0;
        const dy = y > bottom ? y - bottom : y < rect.y ? rect.y - y : 0;
        let target = source;
        if (dy >= dx) {
          if (a.row > source.end.row) target = rangeRC(source.start.row, source.start.column, a.row, source.end.column);
          else if (a.row < source.start.row) target = rangeRC(a.row, source.start.column, source.end.row, source.end.column);
          else if (a.row < source.end.row && y < bottom && y > rect.y) target = rangeRC(source.start.row, source.start.column, a.row, source.end.column);
        } else {
          if (a.column > source.end.column) target = rangeRC(source.start.row, source.start.column, source.end.row, a.column);
          else if (a.column < source.start.column) target = rangeRC(source.start.row, a.column, source.end.row, source.end.column);
        }
        this.overlays.dragPreview = sameRange(target, source) ? null : target;
        this.redraw();
        break;
      }
      case "move": {
        const moved = offsetRange(mode.source, a.row - mode.grab.row, a.column - mode.grab.column);
        if (isValidAddress(moved.start) && isValidAddress(moved.end)) this.overlays.dragPreview = moved;
        this.canvas.style.cursor = event?.ctrlKey ? "copy" : "grabbing";
        this.redraw();
        break;
      }
      case "point":
        this.editor.insertReference(range(mode.anchor, a));
        break;
      default:
        break;
    }
  }

  private updateResizeGuide(x: number, y: number) {
    const mode = this.dragMode;
    const g = this.geometry();
    if (mode.kind === "resizeColumn") {
      const width = Math.max(0, mode.startWidth + (x - mode.startX) / g.zoom);
      this.overlays.resizeGuide = { x, y, vertical: true, label: `Width: ${Math.round(width)} px` };
    } else if (mode.kind === "resizeRow") {
      const height = Math.max(0, mode.startHeight + (y - mode.startY) / g.zoom);
      this.overlays.resizeGuide = { x, y, vertical: false, label: `Height: ${Math.round(height)} px` };
    }
    this.redraw();
  }

  private mouseUp(event: MouseEvent) {
    const c = this.controller;
    const { x, y } = this.point(event);
    const mode = this.dragMode;
    const g = this.geometry();
    switch (mode.kind) {
      case "resizeColumn": {
        const width = Math.max(0, mode.startWidth + (x - mode.startX) / g.zoom);
        const set = selectedColumns(c.selection);
        c.setColumnWidth(width, set.has(mode.column) ? [...set].sort((a, b) => a - b) : [mode.column]);
        break;
      }
      case "resizeRow": {
        const height = Math.max(0, mode.startHeight + (y - mode.startY) / g.zoom);
        const set = selectedRows(c.selection);
        c.setRowHeight(height, set.has(mode.row) ? [...set].sort((a, b) => a - b) : [mode.row]);
        break;
      }
      case "fill":
        if (this.overlays.dragPreview) c.autoFill(mode.source, this.overlays.dragPreview, event.ctrlKey || event.metaKey);
        break;
      case "move":
        if (this.overlays.dragPreview && !sameRange(this.overlays.dragPreview, mode.source)) {
          void c.moveCells(mode.source, this.overlays.dragPreview.start, event.ctrlKey || event.metaKey);
        }
        break;
      case "pending":
        // It was a click after all: select the cell under the pointer.
        c.select(mode.cell, { extend: event.shiftKey, scroll: false });
        break;
      case "selecting":
        if (c.formatPainter) c.applyFormatPainter();
        break;
      default:
        break;
    }
    this.dragMode = { kind: "none" };
    this.overlays.dragPreview = null;
    this.overlays.resizeGuide = null;
    this.canvas.style.cursor = this.cursor(this.region(x, y), event);
    this.redraw();
    if (c.isEditing) this.editor.activeField.focus({ preventScroll: true });
  }

  private updateAutoScroll() {
    const p = this.lastPointer;
    const g = this.geometry();
    const outside = !p || !rectContains(g.cellAreaRect, p.x, p.y);
    if (!outside || this.dragMode.kind === "resizeColumn" || this.dragMode.kind === "resizeRow") {
      this.stopAutoScroll();
      return;
    }
    if (this.autoScrollTimer === null) this.autoScrollTimer = window.setInterval(() => this.autoScrollStep(), 40);
  }

  private autoScrollStep() {
    const p = this.lastPointer;
    if (!p) return;
    const g = this.geometry();
    const body = g.bodyRect;
    let dx = 0, dy = 0;
    if (p.x > body.x + body.width) dx = Math.min(p.x - body.x - body.width, 120);
    if (p.x < body.x && g.scrollX > 0) dx = -Math.min(body.x - p.x, 120);
    if (p.y > body.y + body.height) dy = Math.min(p.y - body.y - body.height, 120);
    if (p.y < body.y && g.scrollY > 0) dy = -Math.min(body.y - p.y, 120);
    if (!dx && !dy) return;
    this.scrollBy(dx * 0.5, dy * 0.5);
    this.handleDrag(p.x, p.y);
  }

  private stopAutoScroll() {
    if (this.autoScrollTimer !== null) clearInterval(this.autoScrollTimer);
    this.autoScrollTimer = null;
  }

  private wheel(event: WheelEvent) {
    if (event.ctrlKey || event.metaKey) {
      event.preventDefault();
      const delta = -event.deltaY * (event.deltaMode === 0 ? 0.005 : 0.05);
      this.controller.setZoom(this.controller.sheet.zoom * (1 + Math.max(-0.5, Math.min(delta, 0.5))));
    }
  }

  // MARK: Hover, notes and tooltips

  private hover(event: MouseEvent) {
    const { x, y } = this.point(event);
    const region = this.region(x, y);
    this.canvas.style.cursor = this.cursor(region, event);
    const c = this.controller;
    if (region.kind !== "cell" || c.isEditing) {
      this.hideNote();
      this.canvas.title = "";
      return;
    }
    const anchor = mergeContaining(c.sheet, region.address)?.start ?? region.address;
    const note = c.sheet.notes.get(cellKey(anchor.row, anchor.column));
    if (note) {
      if (!this.noteAddress || this.noteAddress.row !== anchor.row || this.noteAddress.column !== anchor.column) this.showNote(note, anchor);
    } else {
      this.hideNote();
    }
    const link = getCell(c.sheet, anchor.row, anchor.column)?.link;
    const value = c.value(anchor);
    this.canvas.title = link ? `${link}\nCtrl+click to follow the link.` : value instanceof FormulaError ? value.explanation : "";
  }

  private showNote(text: string, a: CellAddress) {
    this.noteAddress = a;
    const g = this.geometry();
    const cell = g.rangeRect(mergeContaining(this.controller.sheet, a) ?? range(a));
    const author = settings().authorName;
    this.noteBubble.textContent = "";
    if (author) {
      const b = document.createElement("b");
      b.textContent = author + ":";
      this.noteBubble.append(b, document.createElement("br"));
    }
    this.noteBubble.append(text);
    this.noteBubble.hidden = false;
    const bounds = this.canvas.getBoundingClientRect();
    let left = bounds.left + cell.x + cell.width + 8;
    if (left + this.noteBubble.offsetWidth > bounds.right) left = bounds.left + cell.x - this.noteBubble.offsetWidth - 8;
    Object.assign(this.noteBubble.style, { left: `${left}px`, top: `${bounds.top + cell.y}px` });
  }

  private hideNote() {
    this.noteBubble.hidden = true;
    this.noteAddress = null;
  }

  // MARK: Keyboard

  private keyDown(event: KeyboardEvent) {
    const c = this.controller;
    if (c.isEditing) {
      if (this.editor.handleKey(event, this.editor.input)) event.preventDefault();
      return;
    }
    if (event.isComposing) return;
    const shift = event.shiftKey, ctrl = event.ctrlKey || event.metaKey, alt = event.altKey;
    const handled = () => event.preventDefault();
    if (ctrl && !alt && !shift && ["c", "x", "v"].includes(event.key.toLowerCase())) {
      // Browsers only run Copy/Cut on a non-empty selection, so select a placeholder;
      // the clipboard events below then put the cells on the clipboard.
      const input = this.editor.input;
      input.value = " ";
      input.select();
      setTimeout(() => { if (!c.isEditing) input.value = ""; }, 0);
      return;
    }
    switch (event.key) {
      case "ArrowLeft": case "ArrowRight": case "ArrowUp": case "ArrowDown": {
        const [dr, dc] = { ArrowLeft: [0, -1], ArrowRight: [0, 1], ArrowUp: [-1, 0], ArrowDown: [1, 0] }[event.key] as [number, number];
        if (ctrl) c.jumpSelection(dr, dc, shift);
        else c.moveSelection(dr, dc, shift);
        return handled();
      }
      case "Enter":
        if (alt) return;
        c.moveAfterEnter(shift);
        return handled();
      case "Tab":
        if (ctrl) return;
        c.advanceWithinSelection(!shift, false);
        return handled();
      case "Delete":
        if (ctrl || alt) return;
        c.clearContents();
        return handled();
      case "Backspace":
        if (ctrl || alt) return;
        // Like Excel on Windows: clears the cell and starts typing in it.
        this.beginEditing({ initial: "", mode: "enter" });
        return handled();
      case "Escape":
        if (c.clipboardMarquee) { c.clearMarquee(); c.clipboard = c.clipboard && { ...c.clipboard, isCut: false }; return handled(); }
        if (c.formatPainter) { c.cancelFormatPainter(); return handled(); }
        if (c.selectedChartId) { c.selectChart(null); return handled(); }
        return;
      case "Home":
        if (ctrl) c.select({ row: c.sheet.frozenRows, column: c.sheet.frozenColumns }, { extend: shift });
        else c.select({ row: c.selection.active.row, column: 0 }, { extend: shift });
        return handled();
      case "End":
        if (ctrl) c.select(contentExtent(c.sheet), { extend: shift });
        return handled();
      case "PageUp": case "PageDown": {
        const g = this.geometry();
        const up = event.key === "PageUp";
        if (alt) {
          const [first, last] = g.visibleColumns;
          const columns = Math.max(last - first - 1, 1);
          c.moveSelection(0, up ? -columns : columns, shift);
        } else if (ctrl) {
          return; // Next/previous sheet, handled by the window.
        } else {
          const [first, last] = g.visibleRows;
          const rows = Math.max(last - first - 1, 1);
          c.moveSelection(up ? -rows : rows, 0, shift);
          this.scrollBy(0, (up ? -1 : 1) * rows * g.rows.defaultSize);
        }
        return handled();
      }
      case "F2":
        this.beginEditing({ mode: "edit" });
        return handled();
      case " ":
        if (ctrl && !shift) {
          const r = primaryRange(c.selection);
          c.selectColumns(r.start.column, r.end.column);
          return handled();
        }
        if (shift && !ctrl) {
          const r = primaryRange(c.selection);
          c.selectRows(r.start.row, r.end.row);
          return handled();
        }
        return;
      case "ContextMenu": {
        const g = this.geometry();
        const r = g.cellRect(c.selection.active);
        const bounds = this.canvas.getBoundingClientRect();
        this.showContextMenu("cell", bounds.left + r.x + r.width / 2, bounds.top + r.y + r.height);
        return handled();
      }
      default:
        // Typed characters arrive through the input event and start an entry.
        return;
    }
  }

  private clipboardEvent(event: ClipboardEvent, kind: "copy" | "cut" | "paste") {
    const c = this.controller;
    if (c.isEditing) return;
    event.preventDefault();
    this.editor.input.value = "";
    if (kind === "paste") {
      const text = event.clipboardData?.getData("text/plain") ?? "";
      c.paste("all", text);
      return;
    }
    const payload = c.copySelection(kind === "cut");
    if (payload && event.clipboardData) {
      event.clipboardData.setData("text/plain", payload.text);
      event.clipboardData.setData("text/html", payload.html);
    }
  }

  // MARK: Context menus

  private contextMenu(event: MouseEvent) {
    event.preventDefault();
    const c = this.controller;
    if (c.isEditing && !c.commitEditingIfNeeded()) return;
    this.focus();
    const { x, y } = this.point(event);
    const region = this.region(x, y);
    if (region.kind === "cell") {
      if (!selectionContains(c.selection, region.address)) c.select(region.address, { scroll: false });
      this.showContextMenu("cell", event.clientX, event.clientY);
    } else if (region.kind === "columnHeader") {
      if (!selectedColumns(c.selection).has(region.column)) c.selectColumns(region.column, region.column);
      this.showContextMenu("column", event.clientX, event.clientY);
    } else if (region.kind === "rowHeader") {
      if (!selectedRows(c.selection).has(region.row)) c.selectRows(region.row, region.row);
      this.showContextMenu("row", event.clientX, event.clientY);
    } else {
      this.showContextMenu("cell", event.clientX, event.clientY);
    }
  }

  showContextMenu(kind: "cell" | "column" | "row", x: number, y: number) {
    const c = this.controller;
    const k = this.commands;
    const r = () => primaryRange(c.selection);
    const pasteModes: PasteMode[] = ["formulas", "values", "formats", "transpose", "valuesAndNumberFormats", "noBorders", "columnWidths", "link"];
    const entries: MenuEntry[] = [
      { label: "Cut", shortcut: "Ctrl+X", action: () => k.copy(true) },
      { label: "Copy", shortcut: "Ctrl+C", action: () => k.copy(false) },
      { label: "Paste", shortcut: "Ctrl+V", action: () => k.paste("all") },
      { label: "Paste Special", submenu: pasteModes.map((mode) => ({ label: PASTE_TITLES[mode], action: () => k.paste(mode) })) },
      "-",
    ];
    if (kind === "column") {
      entries.push(
        { label: "Insert Columns", action: () => c.insertSheetColumns() },
        { label: "Delete Columns", action: () => c.deleteSheetColumns() },
        { label: "Clear Contents", action: () => c.clearContents() },
        "-",
        { label: "Column Width…", action: () => k.promptColumnWidth() },
        { label: "AutoFit Column Width", action: () => c.autoFitColumns(c.selectedColumnIndices) },
        { label: "Hide", action: () => c.hideColumns() },
        { label: "Unhide", action: () => c.unhideColumns() },
      );
    } else if (kind === "row") {
      entries.push(
        { label: "Insert Rows", action: () => c.insertSheetRows() },
        { label: "Delete Rows", action: () => c.deleteSheetRows() },
        { label: "Clear Contents", action: () => c.clearContents() },
        "-",
        { label: "Row Height…", action: () => k.promptRowHeight() },
        { label: "AutoFit Row Height", action: () => c.autoFitRows(c.selectedRowIndices) },
        { label: "Hide", action: () => c.hideRows() },
        { label: "Unhide", action: () => c.unhideRows() },
      );
    } else {
      const a = c.selection.active;
      entries.push(
        { label: "Insert", submenu: [
          { label: "Shift Cells Right", action: () => c.insertCells(false) },
          { label: "Shift Cells Down", action: () => c.insertCells(true) },
          { label: "Entire Row", action: () => c.insertRows(r().start.row, rowCount(r())) },
          { label: "Entire Column", action: () => c.insertColumns(r().start.column, columnCount(r())) },
        ] },
        { label: "Delete", submenu: [
          { label: "Shift Cells Left", action: () => c.deleteCells(false) },
          { label: "Shift Cells Up", action: () => c.deleteCells(true) },
          { label: "Entire Row", action: () => c.deleteRows(r().start.row, rowCount(r())) },
          { label: "Entire Column", action: () => c.deleteColumns(r().start.column, columnCount(r())) },
        ] },
        { label: "Clear Contents", action: () => c.clearContents() },
        "-",
        { label: "Sort", submenu: [
          { label: "Sort A to Z", action: () => c.quickSort(true) },
          { label: "Sort Z to A", action: () => c.quickSort(false) },
          { label: "Custom Sort…", action: () => k.customSort() },
        ] },
        { label: c.sheet.filter ? "Remove Filter" : "Filter", action: () => c.toggleFilter() },
        "-",
      );
      if (c.note(a) !== undefined) {
        entries.push({ label: "Edit Note", action: () => k.editNote(a) }, { label: "Delete Note", action: () => c.setNote(null, a) });
      } else {
        entries.push({ label: "New Note", action: () => k.editNote(a) });
      }
      const link = getCell(c.sheet, a.row, a.column)?.link;
      if (link) {
        entries.push(
          { label: "Open Hyperlink", action: () => { const url = c.followLink(a); if (url) k.openURL(url); } },
          { label: "Edit Hyperlink…", action: () => k.insertLink() },
          { label: "Remove Hyperlink", action: () => c.clearHyperlinks() },
        );
      } else {
        entries.push({ label: "Hyperlink…", action: () => k.insertLink() });
      }
      entries.push({ label: "Format Cells…", shortcut: "Ctrl+1", action: () => k.formatCells() }, { label: "Define Name…", action: () => k.defineName() });
    }
    showPopupMenu({ x, y }, entries, () => this.focus());
  }

  /** Current width/height for the prompts (first selected column/row). */
  currentColumnWidth(): number {
    const columns = this.controller.selectedColumnIndices;
    return columns.length ? columnWidth(this.controller.sheet, columns[0]) || DEFAULT_COLUMN_WIDTH : DEFAULT_COLUMN_WIDTH;
  }

  currentRowHeight(): number {
    const rows = this.controller.selectedRowIndices;
    return rows.length ? rowHeight(this.controller.sheet, rows[0]) || DEFAULT_ROW_HEIGHT : DEFAULT_ROW_HEIGHT;
  }

  /** The screen rectangle of a cell (for anchoring popovers). */
  cellScreenRect(a: CellAddress): Rect {
    const r = this.geometry().cellRect(a);
    const bounds = this.canvas.getBoundingClientRect();
    return { x: bounds.left + r.x, y: bounds.top + r.y, width: r.width, height: r.height };
  }
}
