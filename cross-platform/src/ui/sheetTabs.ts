import type { WorkbookController } from "../engine/controller";
import type { AppActions } from "./actions";
import { showPalette } from "./colors";
import { showPopupMenu } from "./popup";

/** Sheet tabs: click to switch, double-click to rename, drag to reorder, right-click for more. */
export class SheetTabs {
  private strip: HTMLDivElement;
  private renaming: number | null = null;

  constructor(root: HTMLElement, private c: WorkbookController, private actions: AppActions) {
    root.innerHTML = `
      <div class="tab-nav">
        <button data-nav="prev" title="Previous Sheet (Ctrl+Page Up)" aria-label="Previous Sheet">‹</button>
        <button data-nav="next" title="Next Sheet (Ctrl+Page Down)" aria-label="Next Sheet">›</button>
      </div>
      <div class="tab-strip" role="tablist"></div>
      <button class="add-sheet" title="New Sheet (Shift+F11)" aria-label="New Sheet">+</button>`;
    this.strip = root.querySelector(".tab-strip")!;
    root.querySelector('[data-nav="prev"]')!.addEventListener("click", () => this.step(-1));
    root.querySelector('[data-nav="next"]')!.addEventListener("click", () => this.step(1));
    root.querySelector(".add-sheet")!.addEventListener("click", () => { c.addSheet(); actions.focusGrid(); });
    c.subscribe((kind) => { if (kind === "sheets" || kind === "load") this.render(); });
    document.addEventListener("wg-rename-sheet", () => this.startRename(c.activeSheetIndex));
    document.addEventListener("wg-tab-color", () => {
      const tab = this.strip.children[c.activeSheetIndex] as HTMLElement | undefined;
      if (tab) showPalette(tab, "No Color", (color) => c.setTabColor(color, c.activeSheetIndex));
    });
    this.render();
  }

  step(delta: number) {
    const count = this.c.workbook.sheets.length;
    const next = this.c.activeSheetIndex + delta;
    if (next >= 0 && next < count) this.c.activateSheet(next);
    this.actions.focusGrid();
  }

  render() {
    this.strip.replaceChildren();
    this.c.workbook.sheets.forEach((sheet, index) => {
      const tab = document.createElement("button");
      tab.className = "sheet-tab" + (index === this.c.activeSheetIndex ? " active" : "");
      tab.setAttribute("role", "tab");
      tab.setAttribute("aria-selected", String(index === this.c.activeSheetIndex));
      tab.draggable = true;
      if (this.renaming === index) {
        const input = document.createElement("input");
        input.value = sheet.name;
        input.maxLength = 31;
        const finish = (commit: boolean) => {
          if (this.renaming !== index) return;
          this.renaming = null;
          if (commit && input.value.trim() !== sheet.name) this.c.renameSheet(index, input.value);
          this.render();
          this.actions.focusGrid();
        };
        input.addEventListener("keydown", (e) => {
          e.stopPropagation();
          if (e.key === "Enter") finish(true);
          else if (e.key === "Escape") finish(false);
        });
        input.addEventListener("blur", () => finish(true));
        tab.append(input);
        setTimeout(() => { input.focus(); input.select(); }, 0);
      } else {
        tab.append(sheet.name);
      }
      if (sheet.tabColor) {
        const color = document.createElement("span");
        color.className = "tab-color";
        color.style.background = sheet.tabColor;
        tab.append(color);
      }
      tab.addEventListener("mousedown", (e) => { if (this.renaming !== index) e.preventDefault(); });
      tab.addEventListener("click", () => {
        if (this.renaming === index) return;
        this.c.activateSheet(index);
        this.actions.focusGrid();
      });
      tab.addEventListener("dblclick", () => this.startRename(index));
      tab.addEventListener("contextmenu", (e) => {
        e.preventDefault();
        this.c.activateSheet(index);
        const c = this.c;
        showPopupMenu({ x: e.clientX, y: e.clientY }, [
          { label: "Insert Sheet", action: () => c.addSheet(index) },
          { label: "Delete", enabled: c.workbook.sheets.length > 1, action: () => void c.deleteSheet(index) },
          { label: "Rename", action: () => this.startRename(index) },
          { label: "Duplicate", action: () => c.duplicateSheet(index) },
          "-",
          { label: "Move Left", enabled: index > 0, action: () => c.moveSheet(index, index - 1) },
          { label: "Move Right", enabled: index < c.workbook.sheets.length - 1, action: () => c.moveSheet(index, index + 1) },
          "-",
          { label: "Tab Color…", action: () => showPalette(tab, "No Color", (color) => c.setTabColor(color, index)) },
        ], () => this.actions.focusGrid());
      });
      tab.addEventListener("dragstart", (e) => {
        e.dataTransfer?.setData("application/x-wired-grid-sheet", String(index));
        if (e.dataTransfer) e.dataTransfer.effectAllowed = "move";
      });
      tab.addEventListener("dragover", (e) => {
        if (!e.dataTransfer?.types.includes("application/x-wired-grid-sheet")) return;
        e.preventDefault();
        tab.classList.add("drop-before");
      });
      tab.addEventListener("dragleave", () => tab.classList.remove("drop-before"));
      tab.addEventListener("drop", (e) => {
        tab.classList.remove("drop-before");
        const source = Number(e.dataTransfer?.getData("application/x-wired-grid-sheet"));
        if (Number.isNaN(source)) return;
        e.preventDefault();
        const destination = source < index ? index - 1 : index;
        this.c.moveSheet(source, destination);
      });
      this.strip.append(tab);
    });
    (this.strip.children[this.c.activeSheetIndex] as HTMLElement | undefined)?.scrollIntoView({ block: "nearest", inline: "nearest" });
  }

  startRename(index: number) {
    this.renaming = index;
    this.render();
  }
}
