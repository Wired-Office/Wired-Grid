import type { WorkbookController } from "../engine/controller";
import { general } from "../formula/numberFormat";
import { settings } from "../settings";

const ZOOM_STEPS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];

/** Mode, selection summary (sum, average, count) and zoom. */
export class StatusBar {
  private mode: HTMLSpanElement;
  private summary: HTMLSpanElement;
  private slider: HTMLInputElement;
  private zoomValue: HTMLButtonElement;
  private pending = false;

  constructor(private root: HTMLElement, private c: WorkbookController) {
    root.innerHTML = `
      <span class="mode">Ready</span>
      <span class="message"></span>
      <span class="spacer"></span>
      <span class="summary"></span>
      <button class="zoom-out" aria-label="Zoom out">−</button>
      <input class="zoom-slider" type="range" min="10" max="400" step="5" value="100" aria-label="Zoom">
      <button class="zoom-in" aria-label="Zoom in">+</button>
      <button class="zoom-value" title="Actual size">100%</button>`;
    this.mode = root.querySelector(".mode")!;
    this.summary = root.querySelector(".summary")!;
    this.slider = root.querySelector(".zoom-slider")!;
    this.zoomValue = root.querySelector(".zoom-value")!;
    this.slider.addEventListener("input", () => c.setZoom(Number(this.slider.value) / 100));
    root.querySelector(".zoom-in")!.addEventListener("click", () => c.setZoom(ZOOM_STEPS.find((z) => z > c.sheet.zoom + 0.001) ?? 4));
    root.querySelector(".zoom-out")!.addEventListener("click", () => c.setZoom([...ZOOM_STEPS].reverse().find((z) => z < c.sheet.zoom - 0.001) ?? 0.1));
    this.zoomValue.addEventListener("click", () => c.setZoom(1));
    c.subscribe((kind) => { if (kind !== "scroll" && kind !== "marquee") this.schedule(); });
    this.applyVisibility();
    this.schedule();
  }

  applyVisibility() {
    this.root.hidden = !settings().showStatusBar;
  }

  private schedule() {
    if (this.pending) return;
    this.pending = true;
    requestAnimationFrame(() => {
      this.pending = false;
      this.update();
    });
  }

  private update() {
    const c = this.c;
    this.mode.textContent = c.isEditing ? "Edit" : c.formatPainter ? "Paint" : c.clipboardMarquee ? (c.clipboardMarquee.isCut ? "Move" : "Copy") : "Ready";
    (this.root.querySelector(".message") as HTMLElement).textContent = c.statusMessage ?? (c.clipboardMarquee ? "Select a destination and choose Paste" : "");
    const s = c.selectionSummary();
    const fmt = (n: number) => general(Math.round(n * 1e10) / 1e10, 12);
    const parts: string[] = [];
    if (s.count > 1 || (s.count === 1 && !c.isSingleCellSelected)) {
      if (s.numericalCount > 0) {
        parts.push(`Average: <b>${fmt(s.average!)}</b>`);
        parts.push(`Count: <b>${s.count}</b>`);
        parts.push(`Sum: <b>${fmt(s.sum!)}</b>`);
      } else {
        parts.push(`Count: <b>${s.count}</b>`);
      }
    }
    this.summary.innerHTML = parts.join("&nbsp;&nbsp;&nbsp;");
    const zoom = Math.round(c.sheet.zoom * 100);
    if (document.activeElement !== this.slider) this.slider.value = String(zoom);
    this.zoomValue.textContent = `${zoom}%`;
  }
}
