import { rangeRC, union, type CellRange } from "./model/address";
import { columnWidth, rowHeight, usedRange, type Sheet } from "./model/workbook";
import type { WorkbookController } from "./engine/controller";
import { ConditionalFormatter } from "./engine/conditional";
import { drawChart, readChartData, CHART_FONT } from "./charts/render";
import { GridGeometry } from "./grid/geometry";
import { GridRenderer } from "./grid/render";
import { currentTheme } from "./grid/theme";
import { formatNumber } from "./formula/numberFormat";
import { serialFromDate } from "./formula/dateSerial";

/** CSS pixels per point. */
const PX = 96 / 72;

/** Letter in the US and Canada, A4 elsewhere (in points). */
function paperSize(): [number, number] {
  return /^en-(US|CA)$/i.test(navigator.language) ? [612, 792] : [595.28, 841.89];
}

/** The cells to print: the print area, or everything used (including charts beyond the data). */
export function printRange(c: WorkbookController, sheet: Sheet): CellRange {
  let area = sheet.pageSetup.printArea ?? (usedRange(sheet) ? rangeRC(0, 0, usedRange(sheet)!.end.row, usedRange(sheet)!.end.column) : rangeRC(0, 0, 0, 0));
  if (!sheet.pageSetup.printArea) {
    for (const chart of sheet.charts) {
      const right = chart.frame.x + chart.frame.width, bottom = chart.frame.y + chart.frame.height;
      let column = area.end.column, row = area.end.row;
      while (c.columnOffset(column + 1) < right && column < area.end.column + 200) column++;
      while (c.rowOffset(row + 1) < bottom && row < area.end.row + 2000) row++;
      area = union(area, rangeRC(row, column, row, column));
    }
  }
  return area;
}

/** Splits [first, last] into runs whose sizes fit `limit`, breaking only between rows/columns. */
function paginate(first: number, last: number, size: (i: number) => number, limit: number): [number, number][] {
  const pages: [number, number][] = [];
  let start = first, used = 0;
  for (let i = first; i <= last; i++) {
    const s = size(i);
    if (used + s > limit && i > start) {
      pages.push([start, i - 1]);
      start = i;
      used = 0;
    }
    used += s;
  }
  pages.push([start, last]);
  return pages;
}

function headerText(template: string, page: number, pages: number, sheetName: string): string {
  const today = formatNumber(Math.floor(serialFromDate(new Date())), "m/d/yyyy").text;
  return template.replace(/&P/g, String(page)).replace(/&N/g, String(pages)).replace(/&D/g, today).replace(/&A/g, sheetName);
}

/**
 * Renders the active sheet into page images in #print-root and opens the
 * system print dialog (which also saves PDFs). Pages break between rows and
 * columns, like the Mac app.
 */
export async function printSheet(c: WorkbookController): Promise<void> {
  c.commitEditingIfNeeded();
  const original = c.sheet;
  const setup = original.pageSetup;
  const [paperW, paperH] = setup.orientation === "landscape" ? [paperSize()[1], paperSize()[0]] : paperSize();
  const margin = setup.margin;
  const headerSpace = 18;
  const contentW = paperW - margin * 2;
  const contentH = paperH - margin * 2 - headerSpace * 2;
  const area = printRange(c, original);

  // Draw the sheet as it prints: no frozen panes, gridlines and headings as chosen for printing.
  const sheet: Sheet = { ...original, frozenRows: 0, frozenColumns: 0, showGridlines: setup.printGridlines, showHeadings: setup.printHeadings, zoom: 1 };
  const probe = new GridGeometry(sheet, 1, 0, 0, 1000, 1000);
  const headingW = probe.headerWidth, headingH = probe.headerHeight;
  let totalW = 0, totalH = 0;
  for (let col = area.start.column; col <= area.end.column; col++) totalW += columnWidth(sheet, col);
  for (let row = area.start.row; row <= area.end.row; row++) totalH += rowHeight(sheet, row);

  let scale = 1;
  if (setup.scaling === "fitWidth") scale = Math.min(1, contentW / (totalW + headingW));
  if (setup.scaling === "fitPage") scale = Math.min(1, contentW / (totalW + headingW), contentH / (totalH + headingH));
  const columnPages = paginate(area.start.column, area.end.column, (i) => columnWidth(sheet, i), contentW / scale - headingW);
  const rowPages = paginate(area.start.row, area.end.row, (i) => rowHeight(sheet, i), contentH / scale - headingH);

  const renderer = new GridRenderer(c, new ConditionalFormatter(c.calculator));
  const theme = { ...currentTheme(), dark: false, cellBackground: "#ffffff", cellText: "#000000", gridline: "#c8c8c8", headerBackground: "#f2f2f2", headerText: "#555555", headerLine: "#bbbbbb", linkText: "#0d66bf" };
  const density = 2;
  const root = document.getElementById("print-root")!;
  root.replaceChildren();
  const total = columnPages.length * rowPages.length;
  let page = 0;
  for (const [r1, r2] of rowPages) {
    for (const [c1, c2] of columnPages) {
      page++;
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(paperW * PX * density);
      canvas.height = Math.round(paperH * PX * density);
      const ctx = canvas.getContext("2d")!;
      ctx.scale(PX * density, PX * density);
      ctx.fillStyle = "#ffffff";
      ctx.fillRect(0, 0, paperW, paperH);
      // Header and footer.
      ctx.fillStyle = "#444444";
      ctx.font = `9px ${CHART_FONT}`;
      ctx.textBaseline = "middle";
      for (const [template, y] of [[setup.header, margin / 2 + 4], [setup.footer, paperH - margin / 2 - 4]] as const) {
        if (!template) continue;
        const text = headerText(template, page, total, original.name);
        ctx.fillText(text, paperW / 2 - ctx.measureText(text).width / 2, y);
      }
      ctx.textBaseline = "alphabetic";
      // The cells of this page.
      let pageW = 0, pageH = 0;
      for (let col = c1; col <= c2; col++) pageW += columnWidth(sheet, col);
      for (let row = r1; row <= r2; row++) pageH += rowHeight(sheet, row);
      const width = pageW + headingW, height = pageH + headingH;
      const left = margin + (setup.centerHorizontally ? (contentW - width * scale) / 2 : 0);
      const top = margin + headerSpace;
      ctx.save();
      ctx.translate(left, top);
      ctx.scale(scale, scale);
      ctx.beginPath();
      ctx.rect(0, 0, width, height);
      ctx.clip();
      const scrollX = probe.columns.offset(c1), scrollY = probe.rows.offset(r1);
      const g = new GridGeometry(sheet, 1, scrollX, scrollY, width + 1, height + 1);
      renderer.pixel = 1 / (PX * density * scale);
      renderer.draw(ctx, g, theme, { referenceHighlights: [], dragPreview: null, marchingPhase: 0, resizeGuide: null, editing: false, printing: true }, sheet);
      // Charts on this page.
      for (const chart of sheet.charts) {
        const x = headingW + chart.frame.x - scrollX, y = headingH + chart.frame.y - scrollY;
        if (x > width || y > height || x + chart.frame.width < 0 || y + chart.frame.height < 0) continue;
        drawChart(ctx, chart, readChartData(chart, c.activeSheetIndex, c.workbook, c.calculator), { x, y, width: chart.frame.width, height: chart.frame.height }, false);
        ctx.strokeStyle = "#d0d0d0";
        ctx.lineWidth = 0.5;
        ctx.strokeRect(x, y, chart.frame.width, chart.frame.height);
      }
      ctx.restore();
      const img = document.createElement("img");
      img.src = canvas.toDataURL("image/png");
      img.style.width = `${paperW}pt`;
      img.style.height = `${paperH}pt`;
      img.style.display = "block";
      const wrapper = document.createElement("div");
      wrapper.className = "print-page";
      wrapper.append(img);
      root.append(wrapper);
    }
  }

  let style = document.getElementById("page-style");
  if (!style) {
    style = document.createElement("style");
    style.id = "page-style";
    document.head.append(style);
  }
  style.textContent = `@page { size: ${paperW}pt ${paperH}pt; margin: 0; }`;
  await Promise.all([...root.querySelectorAll("img")].map((img) => (img.complete ? Promise.resolve() : new Promise((r) => { img.onload = r; img.onerror = r; }))));
  const cleanup = () => {
    root.replaceChildren();
    window.removeEventListener("afterprint", cleanup);
  };
  window.addEventListener("afterprint", cleanup);
  window.print();
}
