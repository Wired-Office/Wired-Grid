import { CHART_KINDS, CHART_KIND_TITLES, type ChartObject } from "../model/workbook";
import type { WorkbookController } from "../engine/controller";
import { showPopupMenu } from "../ui/popup";
import { drawChart, readChartData } from "../charts/render";
import { currentTheme } from "./theme";
import type { GridGeometry } from "./geometry";

const HANDLE = 8;
const PAD = 4;

/** Hosts the charts floating over the scrolling cell area. */
export class ChartLayer {
  readonly element: HTMLDivElement;
  private views = new Map<string, { root: HTMLDivElement; canvas: HTMLCanvasElement; chart: ChartObject }>();

  constructor(parent: HTMLElement, private controller: WorkbookController, private geometry: () => GridGeometry, private onEdit: (chart: ChartObject) => void) {
    this.element = document.createElement("div");
    this.element.className = "chart-layer";
    parent.append(this.element);
  }

  sync() {
    const charts = this.controller.sheet.charts;
    const ids = new Set(charts.map((c) => c.id));
    for (const [id, view] of this.views) {
      if (!ids.has(id)) {
        view.root.remove();
        this.views.delete(id);
      }
    }
    for (const chart of charts) {
      let view = this.views.get(chart.id);
      if (!view) view = this.create(chart);
      view.chart = chart;
      view.root.classList.toggle("selected", this.controller.selectedChartId === chart.id);
      this.element.append(view.root); // Keeps z-order matching the model.
    }
    this.layout();
  }

  layout() {
    const g = this.geometry();
    const body = g.bodyRect;
    Object.assign(this.element.style, { left: `${body.x}px`, top: `${body.y}px`, width: `${body.width}px`, height: `${body.height}px` });
    for (const view of this.views.values()) this.layoutChart(view, g);
  }

  private layoutChart(view: { root: HTMLDivElement; canvas: HTMLCanvasElement; chart: ChartObject }, g: GridGeometry) {
    const zoom = g.zoom;
    const f = view.chart.frame;
    // Content coordinates → this layer (which starts at the frozen boundary).
    const x = f.x * zoom - g.scrollX - g.frozenWidth;
    const y = f.y * zoom - g.scrollY - g.frozenHeight;
    const width = f.width * zoom, height = f.height * zoom;
    Object.assign(view.root.style, { left: `${x - PAD}px`, top: `${y - PAD}px`, width: `${width + PAD * 2}px`, height: `${height + PAD * 2}px` });
    const visible = x + width > -50 && y + height > -50 && x < g.width && y < g.height;
    if (visible) this.paint(view, width, height);
  }

  /** Redraws chart contents (data may have changed). */
  refresh() {
    const g = this.geometry();
    for (const view of this.views.values()) this.paint(view, view.chart.frame.width * g.zoom, view.chart.frame.height * g.zoom);
  }

  private paint(view: { canvas: HTMLCanvasElement; chart: ChartObject }, width: number, height: number) {
    const dpr = window.devicePixelRatio || 1;
    const canvas = view.canvas;
    const w = Math.max(1, Math.round(width * dpr)), h = Math.max(1, Math.round(height * dpr));
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w;
      canvas.height = h;
    }
    Object.assign(canvas.style, { width: `${width}px`, height: `${height}px` });
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const c = this.controller;
    const data = readChartData(view.chart, c.activeSheetIndex, c.workbook, c.calculator);
    drawChart(ctx, view.chart, data, { x: 0, y: 0, width, height }, currentTheme().dark, this.geometry().zoom);
  }

  private create(chart: ChartObject) {
    const root = document.createElement("div");
    root.className = "chart-view";
    root.tabIndex = -1;
    const canvas = document.createElement("canvas");
    canvas.className = "chart-canvas";
    root.append(canvas);
    for (let i = 0; i < 8; i++) {
      const handle = document.createElement("div");
      handle.className = `chart-handle h${i}`;
      handle.dataset.handle = String(i);
      root.append(handle);
    }
    const view = { root, canvas, chart };
    this.views.set(chart.id, view);

    root.addEventListener("mousedown", (event) => {
      if (event.button !== 0) return;
      const c = this.controller;
      if (c.isEditing && !c.commitEditingIfNeeded()) return;
      event.preventDefault();
      event.stopPropagation();
      c.selectChart(view.chart.id);
      root.focus({ preventScroll: true });
      if (event.detail >= 2) {
        this.onEdit(view.chart);
        return;
      }
      const handle = (event.target as HTMLElement).dataset.handle;
      const start = { x: event.clientX, y: event.clientY };
      const original = { ...view.chart.frame };
      const zoom = this.geometry().zoom;
      let moved = false;
      const move = (e: MouseEvent) => {
        const dx = (e.clientX - start.x) / zoom, dy = (e.clientY - start.y) / zoom;
        if (Math.abs(dx) + Math.abs(dy) > 1) moved = true;
        const f = { ...original };
        if (handle === undefined) {
          f.x = Math.max(original.x + dx, 0);
          f.y = Math.max(original.y + dy, 0);
        } else {
          const h = Number(handle), min = 120;
          if ([0, 6, 7].includes(h)) { f.x = Math.min(original.x + dx, original.x + original.width - min); f.width = original.x + original.width - f.x; }
          if ([2, 3, 4].includes(h)) f.width = Math.max(original.width + dx, min);
          if ([0, 1, 2].includes(h)) { f.y = Math.min(original.y + dy, original.y + original.height - min); f.height = original.y + original.height - f.y; }
          if ([4, 5, 6].includes(h)) f.height = Math.max(original.height + dy, min);
        }
        view.chart = { ...view.chart, frame: f };
        this.layoutChart(view, this.geometry());
      };
      const up = () => {
        document.removeEventListener("mousemove", move);
        document.removeEventListener("mouseup", up);
        root.classList.remove("dragging");
        if (moved) c.updateChart(view.chart, handle === undefined ? "Move Chart" : "Resize Chart");
      };
      root.classList.add("dragging");
      document.addEventListener("mousemove", move);
      document.addEventListener("mouseup", up);
    });
    root.addEventListener("keydown", (event) => {
      if (event.key === "Delete" || event.key === "Backspace") {
        event.preventDefault();
        this.controller.deleteChart(view.chart.id);
      } else if (event.key === "Escape") {
        this.controller.selectChart(null);
      }
    });
    root.addEventListener("contextmenu", (event) => {
      event.preventDefault();
      event.stopPropagation();
      const c = this.controller;
      c.selectChart(view.chart.id);
      const chart = view.chart;
      showPopupMenu({ x: event.clientX, y: event.clientY }, [
        { label: "Edit Chart…", action: () => this.onEdit(chart) },
        { label: "Change Chart Type", submenu: CHART_KINDS.map((kind) => ({ label: CHART_KIND_TITLES[kind], checked: kind === chart.kind, action: () => c.updateChart({ ...chart, kind }, "Change Chart Type") })) },
        { label: chart.showLegend ? "Hide Legend" : "Show Legend", action: () => c.updateChart({ ...chart, showLegend: !chart.showLegend }) },
        { label: chart.showDataLabels ? "Hide Data Labels" : "Show Data Labels", action: () => c.updateChart({ ...chart, showDataLabels: !chart.showDataLabels }) },
        { label: "Bring to Front", action: () => c.bringChartToFront(chart.id) },
        "-",
        { label: "Copy as Image", action: () => this.copyImage(chart) },
        { label: "Delete Chart", action: () => c.deleteChart(chart.id) },
      ]);
    });
    return view;
  }

  /** Renders a chart at 2× and puts it on the clipboard as a PNG. */
  async copyImage(chart: ChartObject) {
    const canvas = document.createElement("canvas");
    canvas.width = chart.frame.width * 2;
    canvas.height = chart.frame.height * 2;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.scale(2, 2);
    const c = this.controller;
    drawChart(ctx, chart, readChartData(chart, c.activeSheetIndex, c.workbook, c.calculator), { x: 0, y: 0, width: chart.frame.width, height: chart.frame.height }, false);
    const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, "image/png"));
    if (!blob) return;
    try {
      await navigator.clipboard.write([new ClipboardItem({ "image/png": blob })]);
      c.flash("Chart copied as an image");
    } catch {
      c.flash("The chart couldn't be copied");
    }
  }
}

export const CHART_HANDLE_SIZE = HANDLE;
