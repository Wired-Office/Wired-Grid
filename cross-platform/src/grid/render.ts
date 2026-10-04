import {
  MAX_COLUMNS, cellKey, columnName, isSingleCell, isWholeColumns, isWholeRows, keyAddress, rangeContains, rangeRC, rangesIntersect, sameRange,
  type CellAddress, type CellRange,
} from "../model/address";
import { FormulaError, type CellValue } from "../model/values";
import { luminance, mixColors, tableBandColor } from "../model/color";
import {
  BORDER_WIDTHS, TABLE_HEADER_COLORS, getCell, mergeContaining, numberFormatOf, styleAt,
  type BorderLine, type CellBorders, type CellStyle, type Color, type IconSet, type Sheet,
} from "../model/workbook";
import { formatValue, general, GENERAL } from "../formula/numberFormat";
import type { WorkbookController } from "../engine/controller";
import type { ConditionalFormatter } from "../engine/conditional";
import { isMultipleSelection, isSingleSelection, primaryRange } from "../engine/selection";
import { settings } from "../settings";
import { fontStack, UI_FONT, type GridTheme } from "./theme";
import { insetRect, type GridGeometry, type Rect } from "./geometry";

/** Everything needed to draw one cell's contents. */
export interface CellAppearance {
  text: string;
  font: string;
  fontSize: number;
  color: string;
  fill?: string;
  horizontal: string;
  vertical: string;
  wrap: boolean;
  underline: boolean;
  doubleUnderline: boolean;
  strikethrough: boolean;
  indent: number;
  rotation: number;
  isNumber: boolean;
  isGeneral: boolean;
  fillSplit?: [string, string];
  dataBar?: [number, Color];
  icon?: [IconSet, number];
  cfBorder?: Color;
}

export interface Overlays {
  referenceHighlights: { sheet: number; range: CellRange; color: string }[];
  dragPreview: CellRange | null;
  marchingPhase: number;
  resizeGuide: { x: number; y: number; label: string; vertical: boolean } | null;
  editing: boolean;
  /** Printing: no selection, filter buttons or other screen-only decorations. */
  printing?: boolean;
}

const PADDING = 3;

export function cssFont(style: CellStyle, zoom: number, bold = false, italic = false): { font: string; size: number } {
  const size = (style.fontSize ?? settings().defaultFontSize) * zoom;
  const name = style.fontName ?? settings().defaultFontName;
  const weight = style.bold || bold ? 700 : 400;
  return { font: `${style.italic || italic ? "italic " : ""}${weight} ${size}px ${fontStack(name)}`, size };
}

/** Ascent and line height for a font, measured once. */
const metricsCache = new Map<string, { ascent: number; descent: number }>();
export function fontMetrics(ctx: CanvasRenderingContext2D, font: string, size: number) {
  let m = metricsCache.get(font);
  if (!m) {
    ctx.font = font;
    const measured = ctx.measureText("Mgjy");
    const ascent = measured.fontBoundingBoxAscent || measured.actualBoundingBoxAscent || size * 0.8;
    const descent = measured.fontBoundingBoxDescent || measured.actualBoundingBoxDescent || size * 0.22;
    m = { ascent, descent };
    if (metricsCache.size > 200) metricsCache.clear();
    metricsCache.set(font, m);
  }
  return m;
}

/** Splits text into lines that fit `width`, breaking at spaces (or inside long words). */
export function wrapLines(ctx: CanvasRenderingContext2D, text: string, width: number): string[] {
  const lines: string[] = [];
  for (const paragraph of text.split(/\r\n|\r|\n/)) {
    const words = paragraph.split(/(\s+)/);
    let line = "";
    for (const word of words) {
      if (!word) continue;
      const candidate = line + word;
      if (ctx.measureText(candidate).width <= width || !line) {
        if (ctx.measureText(candidate).width > width && !line.trim()) {
          // A single word wider than the cell breaks by character.
          let piece = "";
          for (const ch of word) {
            if (ctx.measureText(piece + ch).width > width && piece) {
              lines.push(piece);
              piece = ch;
            } else piece += ch;
          }
          line = piece;
        } else {
          line = candidate;
        }
      } else {
        lines.push(line.trimEnd());
        line = word.trimStart();
      }
    }
    lines.push(line.trimEnd());
  }
  return lines;
}

/** Draws the worksheet into a canvas context already scaled to CSS pixels. */
export class GridRenderer {
  pixel = 1;

  constructor(private controller: WorkbookController, private conditional: ConditionalFormatter) {}

  private snap(v: number) {
    return Math.round(v / this.pixel) * this.pixel;
  }

  draw(ctx: CanvasRenderingContext2D, g: GridGeometry, theme: GridTheme, overlays: Overlays, sheetOverride?: Sheet) {
    const sheet = sheetOverride ?? this.controller.sheet;
    ctx.fillStyle = theme.cellBackground;
    ctx.fillRect(0, 0, g.width, g.height);

    // Quadrants: scrolled body, frozen top, frozen left, frozen corner.
    const quadrants: [[number, number], [number, number], Rect][] = [[g.visibleRows, g.visibleColumns, g.bodyRect]];
    if (g.frozenRows > 0) quadrants.push([[0, g.frozenRows - 1], g.visibleColumns, { x: g.bodyX, y: g.headerHeight, width: g.bodyRect.width, height: g.frozenHeight }]);
    if (g.frozenColumns > 0) quadrants.push([g.visibleRows, [0, g.frozenColumns - 1], { x: g.headerWidth, y: g.bodyY, width: g.frozenWidth, height: g.bodyRect.height }]);
    if (g.frozenRows > 0 && g.frozenColumns > 0) quadrants.push([[0, g.frozenRows - 1], [0, g.frozenColumns - 1], { x: g.headerWidth, y: g.headerHeight, width: g.frozenWidth, height: g.frozenHeight }]);

    for (const [rows, columns, clip] of quadrants) {
      if (clip.width <= 0 || clip.height <= 0) continue;
      ctx.save();
      ctx.beginPath();
      ctx.rect(clip.x, clip.y, clip.width, clip.height);
      ctx.clip();
      this.drawCells(ctx, rows, columns, clip, g, sheet, theme, !!overlays.printing);
      if (!overlays.printing) this.drawOverlays(ctx, g, sheet, theme, overlays);
      ctx.restore();
    }

    if (sheet.showHeadings) this.drawHeaders(ctx, g, sheet, theme, !!overlays.printing);
    this.drawResizeGuide(ctx, g, theme, overlays);

    // Frozen pane dividers.
    ctx.fillStyle = theme.frozenDivider;
    if (g.frozenRows > 0) ctx.fillRect(g.headerWidth, g.bodyY - 1, g.width, 1.5);
    if (g.frozenColumns > 0) ctx.fillRect(g.bodyX - 1, g.headerHeight, 1.5, g.height);
  }

  // MARK: Appearance

  private tableStyle(a: CellAddress, sheet: Sheet): { fill?: Color; text?: Color; bold: boolean; line?: Color } | null {
    const table = sheet.tables.find((t) => rangeContains(t.range, a));
    if (!table) return null;
    const header = TABLE_HEADER_COLORS[table.style];
    if (table.showHeader && a.row === table.range.start.row) return { fill: header, text: "#FFFFFF", bold: true };
    if (table.showTotals && a.row === table.range.end.row) return { bold: true, line: header };
    const dataIndex = a.row - table.range.start.row - (table.showHeader ? 1 : 0);
    if (table.bandedRows && dataIndex % 2 === 0) return { fill: tableBandColor(header), bold: false };
    return { bold: false };
  }

  appearance(a: CellAddress, value: CellValue, sheet: Sheet, zoom: number, theme: GridTheme): CellAppearance {
    const c = this.controller;
    const style = styleAt(sheet, a.row, a.column);
    const look = this.conditional.look(a, c.activeSheetIndex, c.revision);
    const table = this.tableStyle(a, sheet);
    const cell = getCell(sheet, a.row, a.column);
    const formatted = c.showFormulas && cell?.formula !== undefined ? { text: "=" + cell.formula } as ReturnType<typeof formatValue> : formatValue(value, numberFormatOf(style));
    let color: string;
    if (look?.text) color = look.text;
    else if (formatted.color) color = formatted.color;
    else if (style.textColor) color = legible(style.textColor, style.fillColor ?? table?.fill, theme);
    else if (table?.text && !style.fillColor) color = table.text;
    else if (cell?.link) color = theme.linkText;
    else color = theme.cellText;
    let fill = style.fillColor ?? table?.fill;
    if (look?.fill) fill = look.fill;
    // Keep "automatic" text legible on dark fills, and in dark mode on light fills.
    const autoFill = style.fillColor ?? look?.fill ?? table?.fill;
    if (!style.textColor && !look?.text && !formatted.color && autoFill && (!table?.text || style.fillColor)) {
      color = luminance(autoFill) < 0.45 ? "#FFFFFF" : "#000000";
    }
    const { font, size } = cssFont(style, zoom, !!look?.bold || !!table?.bold, !!look?.italic);
    return {
      text: formatted.text,
      font, fontSize: size, color, fill,
      horizontal: style.horizontal ?? "general",
      vertical: style.vertical ?? "bottom",
      wrap: !!style.wrap,
      underline: !!style.underline || !!cell?.link,
      doubleUnderline: !!style.doubleUnderline,
      strikethrough: !!style.strikethrough,
      indent: (style.indent ?? 0) * 9 * zoom,
      rotation: style.rotation ?? 0,
      isNumber: typeof value === "number" && !c.showFormulas,
      isGeneral: numberFormatOf(style) === GENERAL,
      fillSplit: formatted.fillSplit,
      dataBar: look?.dataBar,
      icon: look?.icon,
      cfBorder: look?.border,
    };
  }

  private hasLook(sheet: Sheet) {
    return sheet.conditionalFormats.length > 0 || sheet.tables.length > 0;
  }

  // MARK: Cells

  private drawCells(ctx: CanvasRenderingContext2D, rows: [number, number], columns: [number, number], clip: Rect, g: GridGeometry, sheet: Sheet, theme: GridTheme, printing: boolean) {
    const c = this.controller;
    const px = this.pixel;
    const region = rangeRC(rows[0], columns[0], rows[1], columns[1]);
    const merges = sheet.merges.filter((m) => rangesIntersect(m, region));
    const mergeFor = (a: CellAddress) => merges.find((m) => rangeContains(m, a));
    const value = (row: number, column: number) => c.calculator.value(c.activeSheetIndex, row, column);

    // 1. Gridlines.
    if (sheet.showGridlines) {
      ctx.fillStyle = theme.gridline;
      const top = Math.max(g.y(rows[0]), clip.y), bottom = Math.min(g.y(rows[1]) + g.rows.size(rows[1]), clip.y + clip.height);
      const left = Math.max(g.x(columns[0]), clip.x), right = Math.min(g.x(columns[1]) + g.columns.size(columns[1]), clip.x + clip.width);
      for (let column = columns[0]; column <= columns[1]; column++) {
        if (g.columns.isHidden(column)) continue;
        ctx.fillRect(this.snap(g.x(column) + g.columns.size(column)) - px, top, px, bottom - top);
      }
      for (let row = rows[0]; row <= rows[1]; row++) {
        if (g.rows.isHidden(row)) continue;
        ctx.fillRect(left, this.snap(g.y(row) + g.rows.size(row)) - px, right - left, px);
      }
    }

    // 2. Fills (cells, tables, conditional formats) and merged areas.
    const items: { a: CellAddress; rect: Rect; value: CellValue; look: CellAppearance }[] = [];
    for (const merge of merges) {
      const anchor = merge.start;
      const rect = this.snapRect(g.rangeRect(merge));
      const v = value(anchor.row, anchor.column);
      const look = this.appearance(anchor, v, sheet, g.zoom, theme);
      if (look.fill) {
        ctx.fillStyle = look.fill;
        ctx.fillRect(rect.x - px, rect.y - px, rect.width + px, rect.height + px);
      } else {
        // Hide the interior gridlines, keeping the outer edges.
        ctx.fillStyle = theme.cellBackground;
        ctx.fillRect(rect.x, rect.y, rect.width - px, rect.height - px);
      }
      items.push({ a: anchor, rect, value: v, look });
    }
    const needsLook = this.hasLook(sheet);
    const textStart = Math.max(columns[0] - 6, 0);
    for (let row = rows[0]; row <= rows[1]; row++) {
      if (g.rows.isHidden(row)) continue;
      const rowStyled = sheet.rowStyles.has(row);
      for (let column = textStart; column <= columns[1]; column++) {
        if (g.columns.isHidden(column)) continue;
        const a = { row, column };
        const visible = column >= columns[0];
        if (mergeFor(a) || (!visible && mergeContaining(sheet, a))) continue;
        const cell = sheet.cells.get(cellKey(row, column));
        const v = value(row, column);
        if (!cell?.style && !rowStyled && !sheet.columnStyles.has(column) && v === null && !needsLook) continue;
        const rect = this.snapRect(g.cellRect(a));
        const look = this.appearance(a, v, sheet, g.zoom, theme);
        if (visible && look.fill) {
          ctx.fillStyle = look.fill;
          ctx.fillRect(rect.x - px, rect.y - px, rect.width + px, rect.height + px);
        }
        if (visible && look.dataBar) {
          const [fraction, color] = look.dataBar;
          const bar = { x: rect.x + 2, y: rect.y + 3 * g.zoom, width: Math.max((rect.width - 4) * fraction, 2), height: rect.height - 6 * g.zoom };
          const gradient = ctx.createLinearGradient(bar.x, 0, bar.x + bar.width, 0);
          gradient.addColorStop(0, withAlpha(color, 0.85));
          gradient.addColorStop(1, withAlpha(color, 0.25));
          ctx.fillStyle = gradient;
          ctx.fillRect(bar.x, bar.y, bar.width, bar.height);
          ctx.strokeStyle = color;
          ctx.lineWidth = 0.5;
          ctx.strokeRect(bar.x + 0.25, bar.y + 0.25, bar.width - 0.5, bar.height - 0.5);
        }
        items.push({ a, rect, value: v, look });
      }
    }

    // 3. Text, with overflow into empty neighbours.
    for (const { a, rect, value: v, look } of items) {
      if (!look.text && !look.icon) continue;
      let textClip = rect;
      const alignment = effectiveAlignment(look, v);
      const merged = !!mergeFor(a) || !!mergeContaining(sheet, a);
      if (!look.wrap && !look.isNumber && !merged && look.rotation === 0) {
        ctx.font = look.font;
        const firstLine = look.text.split(/\r|\n/)[0];
        const needed = ctx.measureText(firstLine).width + PADDING * 2 * g.zoom + look.indent;
        if (needed > rect.width) {
          const extra = needed - rect.width;
          const isFree = (column: number) => {
            const n = { row: a.row, column };
            return !sheet.cells.get(cellKey(a.row, column))?.formula && value(a.row, column) === null && !getCell(sheet, a.row, column)?.value && !mergeContaining(sheet, n);
          };
          if (alignment === "left" || alignment === "general" || alignment === "justify") {
            let right = rect.x + rect.width, column = a.column + 1;
            while (right < rect.x + rect.width + extra && column < MAX_COLUMNS && isFree(column)) { right += g.columns.size(column); column++; }
            textClip = { ...rect, width: right - rect.x };
          } else if (alignment === "right") {
            let left = rect.x, column = a.column - 1;
            while (left > rect.x - extra && column >= 0 && isFree(column)) { left -= g.columns.size(column); column--; }
            textClip = { ...rect, x: left, width: rect.x + rect.width - left };
          } else if (alignment === "center") {
            let left = rect.x, right = rect.x + rect.width, cl = a.column - 1, cr = a.column + 1;
            while (left > rect.x - extra / 2 && cl >= 0 && isFree(cl)) { left -= g.columns.size(cl); cl--; }
            while (right < rect.x + rect.width + extra / 2 && cr < MAX_COLUMNS && isFree(cr)) { right += g.columns.size(cr); cr++; }
            textClip = { ...rect, x: left, width: right - left };
          }
          // Overflowing text hides the gridlines it crosses.
          if (textClip.width > rect.width && sheet.showGridlines) {
            ctx.fillStyle = theme.cellBackground;
            for (let column = g.columnAt(textClip.x + 1); column < MAX_COLUMNS; column++) {
              const edge = this.snap(g.x(column) + g.columns.size(column));
              if (edge >= textClip.x + textClip.width - 1) break;
              if (!styleAt(sheet, a.row, column).fillColor && !styleAt(sheet, a.row, column + 1).fillColor) ctx.fillRect(edge - px, rect.y, px, rect.height - px);
            }
          }
        }
      }
      let drawRect = rect;
      if (textClip.width > rect.width) {
        if (alignment === "right") drawRect = { ...rect, x: textClip.x, width: textClip.width };
        else if (alignment === "center") drawRect = textClip;
        else drawRect = { ...rect, width: textClip.width };
      }
      this.drawText(ctx, look, v, drawRect, textClip, g.zoom);
    }

    // 4. Borders (explicit, table totals and conditional).
    for (const { a, rect, look } of items) {
      let borders: CellBorders = { ...(styleAt(sheet, a.row, a.column).borders ?? {}) };
      const merge = mergeContaining(sheet, a);
      if (merge && merge.start.row === a.row && merge.start.column === a.column) {
        // A merged cell uses the edges of its corner cells.
        borders.right = styleAt(sheet, merge.start.row, merge.end.column).borders?.right ?? borders.right;
        borders.bottom = styleAt(sheet, merge.end.row, merge.start.column).borders?.bottom ?? borders.bottom;
      }
      const tableLine = this.tableStyle(a, sheet)?.line;
      if (tableLine && !borders.top) borders.top = { style: "thin", color: tableLine };
      if (look.cfBorder) {
        const line: BorderLine = { style: "thin", color: look.cfBorder };
        borders = { top: line, left: line, bottom: line, right: line };
      }
      if (borders.top || borders.bottom || borders.left || borders.right) this.drawBorders(ctx, borders, rect, theme);
    }

    // 5. Note indicators, filter buttons, spill outline.
    for (const key of sheet.notes.keys()) {
      const a = keyAddress(key);
      if (!rangeContains(region, a)) continue;
      const r = g.rangeRect(mergeContaining(sheet, a) ?? { start: a, end: a });
      const size = 6 * g.zoom;
      ctx.beginPath();
      ctx.moveTo(r.x + r.width - size, r.y);
      ctx.lineTo(r.x + r.width, r.y);
      ctx.lineTo(r.x + r.width, r.y + size);
      ctx.closePath();
      ctx.fillStyle = "#d9261a";
      ctx.fill();
    }
    if (printing) return;
    const filter = sheet.filter;
    if (filter && filter.range.start.row >= rows[0] && filter.range.start.row <= rows[1]) {
      for (let column = filter.range.start.column; column <= filter.range.end.column; column++) {
        if (column < columns[0] || column > columns[1] || g.columns.isHidden(column)) continue;
        this.drawFilterButton(ctx, filterButtonRect(column, filter.range.start.row, g), filter.criteria.has(column), theme);
      }
    }
    const anchor = c.calculator.spillAnchor(c.activeSheetIndex, c.selection.active);
    const spill = anchor ? c.calculator.spillRange(c.activeSheetIndex, anchor) : undefined;
    if (spill) {
      const r = insetRect(g.rangeRect(spill), 0.5, 0.5);
      ctx.setLineDash([3, 2]);
      ctx.strokeStyle = "rgba(10,132,255,0.8)";
      ctx.lineWidth = 1;
      ctx.strokeRect(r.x, r.y, r.width, r.height);
      ctx.setLineDash([]);
    }
  }

  private snapRect(r: Rect): Rect {
    const x = this.snap(r.x), y = this.snap(r.y);
    return { x, y, width: this.snap(r.x + r.width) - x, height: this.snap(r.y + r.height) - y };
  }

  private drawText(ctx: CanvasRenderingContext2D, a: CellAppearance, value: CellValue, rect: Rect, clip: Rect, zoom: number) {
    const pad = PADDING * zoom;
    const inner = insetRect(rect, pad, 0);
    const alignment = effectiveAlignment(a, value);
    if (a.icon) {
      const size = Math.min(rect.height - 4 * zoom, 14 * zoom);
      drawIcon(ctx, a.icon[0], a.icon[1], { x: rect.x + pad, y: rect.y + rect.height / 2 - size / 2, width: size, height: size });
      inner.x += size + 3 * zoom;
      inner.width -= size + 3 * zoom;
    }
    if (a.indent > 0) {
      if (alignment === "right") inner.width -= a.indent;
      else { inner.x += a.indent; inner.width -= a.indent; }
    }
    if (inner.width <= 1 || !a.text) return;

    ctx.save();
    ctx.beginPath();
    const left = Math.max(clip.x, Math.min(rect.x, clip.x)), right = Math.max(clip.x + clip.width, rect.x + rect.width);
    ctx.rect(Math.max(clip.x, left), rect.y, Math.min(clip.x + clip.width, right) - Math.max(clip.x, left), rect.height);
    ctx.clip();
    ctx.font = a.font;
    ctx.fillStyle = a.color;
    ctx.textBaseline = "alphabetic";
    const { ascent, descent } = fontMetrics(ctx, a.font, a.fontSize);
    const lineHeight = ascent + descent;

    if (a.rotation !== 0) {
      const width = ctx.measureText(a.text).width;
      ctx.translate(rect.x + rect.width / 2, rect.y + rect.height / 2);
      ctx.rotate((-a.rotation * Math.PI) / 180);
      ctx.fillText(a.text, -width / 2, ascent - lineHeight / 2);
      ctx.restore();
      return;
    }

    if (a.wrap && !a.isNumber) {
      const lines = wrapLines(ctx, a.text, inner.width);
      const height = Math.min(lines.length * lineHeight, rect.height);
      let y = a.vertical === "top" ? rect.y + 2 * zoom : a.vertical === "middle" ? rect.y + rect.height / 2 - height / 2 : rect.y + rect.height - height - 2 * zoom;
      y = Math.max(y, rect.y);
      for (const line of lines) {
        const w = ctx.measureText(line).width;
        const x = alignment === "center" ? inner.x + inner.width / 2 - w / 2 : alignment === "right" ? inner.x + inner.width - w : inner.x;
        ctx.fillText(line, x, y + ascent);
        this.decorate(ctx, a, x, y + ascent, w);
        y += lineHeight;
        if (y > rect.y + rect.height) break;
      }
      ctx.restore();
      return;
    }

    // Multi-line text without wrap shows only the first line, like Excel.
    let text = a.text.split(/\r|\n/)[0];
    let width = ctx.measureText(text).width;
    // Numbers that don't fit become ### (or fewer General digits).
    if (a.isNumber && width > inner.width + 0.5 && typeof value === "number" && !a.fillSplit) {
      let shortened: string | null = null;
      if (a.isGeneral) {
        for (let length = text.length - 1; length >= 1; length--) {
          const candidate = general(value, length);
          if (ctx.measureText(candidate).width <= inner.width) { shortened = candidate; break; }
        }
      }
      text = shortened ?? "#".repeat(Math.max(1, Math.floor(inner.width / Math.max(ctx.measureText("#").width, 1))));
      width = ctx.measureText(text).width;
    }
    let y = a.vertical === "top" ? rect.y + 2 * zoom : a.vertical === "middle" ? rect.y + rect.height / 2 - lineHeight / 2 : rect.y + rect.height - lineHeight - 3 * zoom;
    y = Math.max(y, rect.y + 0.5);
    const baseline = y + ascent;

    // Accounting-style formats pin the currency symbol left and the number right.
    if (a.fillSplit && a.isNumber) {
      ctx.fillText(a.fillSplit[0], inner.x, baseline);
      const rightWidth = ctx.measureText(a.fillSplit[1]).width;
      ctx.fillText(a.fillSplit[1], inner.x + inner.width - rightWidth, baseline);
      ctx.restore();
      return;
    }
    let x: number;
    if (alignment === "right") x = inner.x + inner.width - width;
    else if (alignment === "center" || alignment === "centerAcross") x = inner.x + inner.width / 2 - width / 2;
    else if (alignment === "fill") {
      const unit = Math.max(width, 1);
      text = text.repeat(Math.max(1, Math.floor(inner.width / unit)));
      width = ctx.measureText(text).width;
      x = inner.x;
    } else x = inner.x;
    ctx.fillText(text, x, baseline);
    this.decorate(ctx, a, x, baseline, width);
    ctx.restore();
  }

  private decorate(ctx: CanvasRenderingContext2D, a: CellAppearance, x: number, baseline: number, width: number) {
    const thickness = Math.max(1, a.fontSize / 14);
    if (a.underline || a.doubleUnderline) {
      ctx.fillRect(x, baseline + thickness * 1.5, width, thickness);
      if (a.doubleUnderline) ctx.fillRect(x, baseline + thickness * 3.5, width, thickness);
    }
    if (a.strikethrough) ctx.fillRect(x, baseline - a.fontSize * 0.3, width, thickness);
  }

  private drawBorders(ctx: CanvasRenderingContext2D, borders: CellBorders, rect: Rect, theme: GridTheme) {
    const px = this.pixel;
    const inset = px / 2;
    const edge = (line: BorderLine | undefined, x1: number, y1: number, x2: number, y2: number, horizontal: boolean) => {
      if (!line) return;
      ctx.strokeStyle = line.color === "#000000" ? theme.cellText : line.color;
      const width = Math.max(BORDER_WIDTHS[line.style], px);
      ctx.setLineDash(line.style === "dashed" ? [4, 2] : line.style === "dotted" ? [1, 1.5] : []);
      if (line.style === "double") {
        ctx.lineWidth = 0.8;
        for (const shift of [-1.2, 1.2]) {
          ctx.beginPath();
          ctx.moveTo(x1 + (horizontal ? 0 : shift), y1 + (horizontal ? shift : 0));
          ctx.lineTo(x2 + (horizontal ? 0 : shift), y2 + (horizontal ? shift : 0));
          ctx.stroke();
        }
        return;
      }
      ctx.lineWidth = width;
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.stroke();
    };
    const right = rect.x + rect.width, bottom = rect.y + rect.height;
    edge(borders.top, rect.x - inset, rect.y - inset, right - inset, rect.y - inset, true);
    edge(borders.bottom, rect.x - inset, bottom - inset, right - inset, bottom - inset, true);
    edge(borders.left, rect.x - inset, rect.y - inset, rect.x - inset, bottom - inset, false);
    edge(borders.right, right - inset, rect.y - inset, right - inset, bottom - inset, false);
    ctx.setLineDash([]);
  }

  private drawFilterButton(ctx: CanvasRenderingContext2D, r: Rect, active: boolean, theme: GridTheme) {
    ctx.beginPath();
    ctx.roundRect?.(r.x, r.y, r.width, r.height, 3);
    if (!ctx.roundRect) ctx.rect(r.x, r.y, r.width, r.height);
    ctx.fillStyle = active ? withAlpha(theme.accent, 0.18) : theme.dark ? "#3a3c3b" : "#ffffff";
    ctx.fill();
    ctx.strokeStyle = active ? theme.accent : theme.headerLine;
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.strokeStyle = active ? theme.accent : theme.headerText;
    ctx.lineWidth = 1.5;
    const cx = r.x + r.width / 2, cy = r.y + r.height / 2, s = r.height * 0.18;
    ctx.beginPath();
    if (active) {
      // A funnel: three shrinking lines.
      for (let i = 0; i < 3; i++) {
        const w = s * (2.4 - i * 0.8);
        ctx.moveTo(cx - w, cy - s * 1.2 + i * s * 1.2);
        ctx.lineTo(cx + w, cy - s * 1.2 + i * s * 1.2);
      }
    } else {
      ctx.moveTo(cx - s * 1.6, cy - s * 0.6);
      ctx.lineTo(cx, cy + s * 0.9);
      ctx.lineTo(cx + s * 1.6, cy - s * 0.6);
    }
    ctx.stroke();
  }

  // MARK: Overlays

  private drawOverlays(ctx: CanvasRenderingContext2D, g: GridGeometry, sheet: Sheet, theme: GridTheme, overlays: Overlays) {
    const c = this.controller;
    const selection = c.selection;

    // Formula reference boxes.
    for (const h of overlays.referenceHighlights) {
      if (h.sheet !== c.activeSheetIndex) continue;
      const r = insetRect(this.clampedRect(h.range, g), 0.5, 0.5);
      ctx.fillStyle = withAlpha(h.color, 0.1);
      ctx.fillRect(r.x, r.y, r.width, r.height);
      ctx.strokeStyle = h.color;
      ctx.lineWidth = 1.5;
      ctx.strokeRect(r.x, r.y, r.width, r.height);
      ctx.fillStyle = h.color;
      for (const [x, y] of [[r.x, r.y], [r.x + r.width, r.y], [r.x, r.y + r.height], [r.x + r.width, r.y + r.height]]) ctx.fillRect(x - 2, y - 2, 4, 4);
    }

    // Selection fill: every range, leaving the active cell clear.
    if (!(overlays.editing && isSingleSelection(selection))) {
      ctx.beginPath();
      for (const r of selection.ranges) {
        if (!isSingleCell(r) || isMultipleSelection(selection)) {
          const rect = this.clampedRect(r, g);
          ctx.rect(rect.x, rect.y, rect.width, rect.height);
        }
      }
      if (!isSingleSelection(selection)) {
        const active = g.rangeRect(mergeContaining(sheet, selection.active) ?? { start: selection.active, end: selection.active });
        ctx.rect(active.x, active.y, active.width, active.height);
      }
      ctx.fillStyle = theme.selectionFill;
      ctx.fill("evenodd");
    }

    // Outline of the current range, and the fill handle.
    const primary = this.clampedRect(primaryRange(selection), g);
    ctx.strokeStyle = theme.selection;
    ctx.lineWidth = 2;
    ctx.strokeRect(primary.x - 0.5, primary.y - 0.5, primary.width + 1, primary.height + 1);
    if (isMultipleSelection(selection) || !isSingleSelection(selection)) {
      const active = insetRect(g.rangeRect(mergeContaining(sheet, selection.active) ?? { start: selection.active, end: selection.active }), 0.5, 0.5);
      ctx.lineWidth = 1;
      ctx.strokeStyle = withAlpha(theme.selection, 0.7);
      ctx.strokeRect(active.x, active.y, active.width, active.height);
    }
    const p = primaryRange(selection);
    if (!overlays.editing && !isMultipleSelection(selection) && !isWholeColumns(p) && !isWholeRows(p)) {
      const handle = fillHandleRect(g, p);
      ctx.fillStyle = theme.cellBackground;
      ctx.fillRect(handle.x - 1, handle.y - 1, handle.width + 2, handle.height + 2);
      ctx.fillStyle = theme.selection;
      ctx.fillRect(handle.x, handle.y, handle.width, handle.height);
    }

    // Copy marquee.
    const marquee = c.clipboardMarquee;
    if (marquee && marquee.sheetId === sheet.id) {
      const r = insetRect(g.rangeRect(marquee.range), 0.5, 0.5);
      ctx.lineWidth = 2;
      ctx.strokeStyle = theme.cellBackground;
      ctx.strokeRect(r.x, r.y, r.width, r.height);
      ctx.setLineDash([4, 4]);
      ctx.lineDashOffset = -overlays.marchingPhase;
      ctx.strokeStyle = theme.selection;
      ctx.strokeRect(r.x, r.y, r.width, r.height);
      ctx.setLineDash([]);
      ctx.lineDashOffset = 0;
    }

    if (overlays.dragPreview) {
      const r = insetRect(g.rangeRect(overlays.dragPreview), 0.5, 0.5);
      ctx.lineWidth = 1.5;
      ctx.setLineDash([3, 3]);
      ctx.strokeStyle = theme.headerText;
      ctx.strokeRect(r.x, r.y, r.width, r.height);
      ctx.setLineDash([]);
    }
  }

  /** Whole-row/column ranges extend just past the visible area rather than to row 1,048,576. */
  clampedRect(r: CellRange, g: GridGeometry): Rect {
    let bounded = r;
    if (isWholeColumns(r) || isWholeRows(r)) {
      const lastRow = Math.min(r.end.row, g.visibleRows[1] + 1);
      const lastColumn = Math.min(r.end.column, g.visibleColumns[1] + 1);
      bounded = rangeRC(r.start.row, r.start.column, Math.max(lastRow, r.start.row), Math.max(lastColumn, r.start.column));
    }
    const rect = g.rangeRect(bounded);
    if (isWholeColumns(r)) { rect.height = Math.max(rect.height + Math.max(rect.y - g.headerHeight, 0), g.height); rect.y = Math.min(rect.y, g.headerHeight); }
    if (isWholeRows(r)) { rect.width = Math.max(rect.width + Math.max(rect.x - g.headerWidth, 0), g.width); rect.x = Math.min(rect.x, g.headerWidth); }
    return rect;
  }

  // MARK: Headers

  private drawHeaders(ctx: CanvasRenderingContext2D, g: GridGeometry, sheet: Sheet, theme: GridTheme, printing: boolean) {
    const selection = printing ? { active: { row: 0, column: 0 }, anchor: { row: 0, column: 0 }, ranges: [] } : this.controller.selection;
    const px = this.pixel;
    const selectedColumns = new Set<number>(), fullColumns = new Set<number>();
    const selectedRows = new Set<number>(), fullRows = new Set<number>();
    for (const r of selection.ranges) {
      const lastColumn = Math.min(r.end.column, g.visibleColumns[1] + 1);
      const lastRow = Math.min(r.end.row, g.visibleRows[1] + 1);
      for (let column = r.start.column; column <= lastColumn; column++) {
        selectedColumns.add(column);
        if (isWholeColumns(r)) fullColumns.add(column);
      }
      for (let row = Math.max(r.start.row, 0); row <= lastRow; row++) {
        if (row < g.visibleRows[0] - 1 && row >= g.frozenRows) { row = g.visibleRows[0] - 1; continue; }
        selectedRows.add(row);
        if (isWholeRows(r)) fullRows.add(row);
      }
    }
    const size = 11 * Math.max(Math.min(g.zoom, 1.6), 0.8);
    const font = `400 ${size}px ${UI_FONT}`, bold = `600 ${size}px ${UI_FONT}`;
    ctx.textBaseline = "middle";

    // Column headers.
    ctx.fillStyle = theme.headerBackground;
    ctx.fillRect(g.headerWidth, 0, g.width - g.headerWidth, g.headerHeight);
    const columnGroups: [[number, number], Rect][] = [[g.visibleColumns, { x: g.bodyX, y: 0, width: g.width - g.bodyX, height: g.headerHeight }]];
    if (g.frozenColumns > 0) columnGroups.push([[0, g.frozenColumns - 1], { x: g.headerWidth, y: 0, width: g.frozenWidth, height: g.headerHeight }]);
    for (const [[first, last], clip] of columnGroups) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(clip.x, clip.y, clip.width, clip.height);
      ctx.clip();
      for (let column = first; column <= last; column++) {
        if (g.columns.isHidden(column)) continue;
        const r = { x: this.snap(g.x(column)), y: 0, width: this.snap(g.x(column) + g.columns.size(column)) - this.snap(g.x(column)), height: g.headerHeight };
        const full = fullColumns.has(column), partial = selectedColumns.has(column);
        if (full || partial) {
          ctx.fillStyle = full ? theme.headerFullySelected : theme.headerSelected;
          ctx.fillRect(r.x, r.y, r.width, r.height);
        }
        const label = columnName(column);
        ctx.font = partial ? bold : font;
        const w = ctx.measureText(label).width;
        if (r.width > w + 2) {
          ctx.fillStyle = full ? "#ffffff" : partial ? theme.accent : theme.headerText;
          ctx.fillText(label, r.x + r.width / 2 - w / 2, r.height / 2 + 0.5);
        }
        ctx.fillStyle = theme.headerLine;
        ctx.fillRect(r.x + r.width - px, 3, px, r.height - 6);
        if (partial && !full) {
          ctx.fillStyle = theme.accent;
          ctx.fillRect(r.x, r.height - 2, r.width, 2);
        }
        // Hidden neighbours are marked by a double line.
        if (column + 1 < MAX_COLUMNS && g.columns.isHidden(column + 1)) {
          ctx.fillStyle = theme.headerText;
          ctx.fillRect(r.x + r.width - 2, 4, px, r.height - 8);
        }
      }
      ctx.restore();
    }
    ctx.fillStyle = theme.headerLine;
    ctx.fillRect(0, g.headerHeight - px, g.width, px);

    // Row headers.
    ctx.fillStyle = theme.headerBackground;
    ctx.fillRect(0, g.headerHeight, g.headerWidth, g.height - g.headerHeight);
    const rowGroups: [[number, number], Rect][] = [[g.visibleRows, { x: 0, y: g.bodyY, width: g.headerWidth, height: g.height - g.bodyY }]];
    if (g.frozenRows > 0) rowGroups.push([[0, g.frozenRows - 1], { x: 0, y: g.headerHeight, width: g.headerWidth, height: g.frozenHeight }]);
    const filter = sheet.filter;
    const filtered = (row: number) => !!filter && filter.criteria.size > 0 && row > filter.range.start.row && row <= filter.range.end.row;
    for (const [[first, last], clip] of rowGroups) {
      ctx.save();
      ctx.beginPath();
      ctx.rect(clip.x, clip.y, clip.width, clip.height);
      ctx.clip();
      for (let row = first; row <= last; row++) {
        if (g.rows.isHidden(row)) continue;
        const top = this.snap(g.y(row));
        const r = { x: 0, y: top, width: g.headerWidth, height: this.snap(g.y(row) + g.rows.size(row)) - top };
        const full = fullRows.has(row), partial = selectedRows.has(row);
        if (full || partial) {
          ctx.fillStyle = full ? theme.headerFullySelected : theme.headerSelected;
          ctx.fillRect(r.x, r.y, r.width, r.height);
        }
        const label = String(row + 1);
        ctx.font = partial ? bold : font;
        const w = ctx.measureText(label).width;
        if (r.height > size * 0.8) {
          ctx.fillStyle = full ? "#ffffff" : partial ? theme.accent : filtered(row) ? "#0a84ff" : theme.headerText;
          ctx.fillText(label, r.width - w - 6, r.y + r.height / 2 + 0.5);
        }
        ctx.fillStyle = theme.headerLine;
        ctx.fillRect(3, r.y + r.height - px, r.width - 6, px);
        if (partial && !full) {
          ctx.fillStyle = theme.accent;
          ctx.fillRect(r.width - 2, r.y, 2, r.height);
        }
        if (row + 1 < 1_048_576 && g.rows.isHidden(row + 1)) {
          ctx.fillStyle = theme.headerText;
          ctx.fillRect(4, r.y + r.height - 2, r.width - 8, px);
        }
      }
      ctx.restore();
    }
    ctx.fillStyle = theme.headerLine;
    ctx.fillRect(g.headerWidth - px, 0, px, g.height);

    // Corner (select all).
    ctx.fillStyle = theme.headerBackground;
    ctx.fillRect(0, 0, g.headerWidth - px, g.headerHeight - px);
    const right = g.headerWidth - px, bottom = g.headerHeight - px;
    ctx.beginPath();
    ctx.moveTo(right - 4, bottom - 12);
    ctx.lineTo(right - 4, bottom - 4);
    ctx.lineTo(right - 12, bottom - 4);
    ctx.closePath();
    const all = selection.ranges.length === 1 && isWholeColumns(selection.ranges[0]) && isWholeRows(selection.ranges[0]);
    ctx.fillStyle = all ? theme.accent : theme.headerLine;
    ctx.fill();
    ctx.textBaseline = "alphabetic";
  }

  private drawResizeGuide(ctx: CanvasRenderingContext2D, g: GridGeometry, theme: GridTheme, overlays: Overlays) {
    const guide = overlays.resizeGuide;
    if (!guide) return;
    ctx.fillStyle = theme.headerText;
    if (guide.vertical) ctx.fillRect(guide.x, 0, 1, g.height);
    else ctx.fillRect(0, guide.y, g.width, 1);
    ctx.font = `500 11px ${UI_FONT}`;
    const w = ctx.measureText(guide.label).width;
    const box = { x: guide.x + 10, y: guide.y + 12, width: w + 12, height: 20 };
    ctx.fillStyle = theme.dark ? "#2f3130" : "#ffffff";
    ctx.strokeStyle = theme.headerLine;
    ctx.beginPath();
    ctx.rect(box.x, box.y, box.width, box.height);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = theme.cellText;
    ctx.textBaseline = "middle";
    ctx.fillText(guide.label, box.x + 6, box.y + box.height / 2);
    ctx.textBaseline = "alphabetic";
  }
}

export function effectiveAlignment(a: CellAppearance, value: CellValue): string {
  if (a.horizontal !== "general") return a.horizontal;
  if (typeof value === "number") return a.rotation === 0 ? "right" : "left";
  if (typeof value === "boolean" || value instanceof FormulaError) return "center";
  return "left";
}

export function filterButtonRect(column: number, headerRow: number, g: GridGeometry): Rect {
  const cell = g.cellRect({ row: headerRow, column });
  const size = Math.min(cell.height - 4, 17 * g.zoom);
  return { x: cell.x + cell.width - size - 3, y: cell.y + cell.height / 2 - size / 2, width: size, height: size };
}

export function fillHandleRect(g: GridGeometry, r: CellRange): Rect {
  const rect = g.rangeRect(r);
  return { x: rect.x + rect.width - 3.5, y: rect.y + rect.height - 3.5, width: 6, height: 6 };
}

/** Very dark explicit text on the dark sheet is lightened so it stays readable. */
function legible(color: Color, fill: Color | undefined, theme: GridTheme): string {
  if (fill || !theme.dark || luminance(color) >= 0.3) return color;
  return mixColors(color, "#FFFFFF", 0.6);
}

export function withAlpha(color: string, alpha: number): string {
  if (!color.startsWith("#")) return color;
  const n = parseInt(color.slice(1, 7), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
}

export function drawIcon(ctx: CanvasRenderingContext2D, set: IconSet, level: number, rect: Rect) {
  const colors = ["#d93833", "#f2b81a", "#33a64d"];
  const color = colors[Math.max(0, Math.min(2, level))];
  ctx.save();
  const r = insetRect(rect, 1.5, 1.5);
  const midX = r.x + r.width / 2, midY = r.y + r.height / 2, maxX = r.x + r.width, maxY = r.y + r.height;
  switch (set) {
    case "trafficLights":
      ctx.beginPath();
      ctx.arc(midX, midY, rect.width / 2 - 1, 0, Math.PI * 2);
      ctx.fillStyle = color;
      ctx.fill();
      ctx.strokeStyle = "rgba(0,0,0,0.2)";
      ctx.stroke();
      break;
    case "arrows": {
      ctx.beginPath();
      const s = r.width * 0.18;
      if (level === 2) { // up
        ctx.moveTo(midX, r.y); ctx.lineTo(maxX, midY); ctx.lineTo(midX + s, midY); ctx.lineTo(midX + s, maxY);
        ctx.lineTo(midX - s, maxY); ctx.lineTo(midX - s, midY); ctx.lineTo(r.x, midY);
      } else if (level === 0) { // down
        ctx.moveTo(midX, maxY); ctx.lineTo(maxX, midY); ctx.lineTo(midX + s, midY); ctx.lineTo(midX + s, r.y);
        ctx.lineTo(midX - s, r.y); ctx.lineTo(midX - s, midY); ctx.lineTo(r.x, midY);
      } else { // right
        const t = r.height * 0.18;
        ctx.moveTo(maxX, midY); ctx.lineTo(midX, r.y); ctx.lineTo(midX, midY - t); ctx.lineTo(r.x, midY - t);
        ctx.lineTo(r.x, midY + t); ctx.lineTo(midX, midY + t); ctx.lineTo(midX, maxY);
      }
      ctx.closePath();
      ctx.fillStyle = color;
      ctx.fill();
      break;
    }
    case "flags": {
      const f = insetRect(rect, 2, 1.5);
      ctx.fillStyle = "#555555";
      ctx.fillRect(f.x, f.y, 1.2, f.height);
      ctx.beginPath();
      ctx.moveTo(f.x + 1.2, f.y);
      ctx.lineTo(f.x + f.width, f.y + f.height * 0.28);
      ctx.lineTo(f.x + 1.2, f.y + f.height * 0.56);
      ctx.closePath();
      ctx.fillStyle = color;
      ctx.fill();
      break;
    }
    case "stars": {
      const s = insetRect(rect, 1, 1);
      ctx.beginPath();
      for (let i = 0; i < 10; i++) {
        const angle = (i * Math.PI) / 5 - Math.PI / 2;
        const radius = i % 2 === 0 ? s.width / 2 : s.width / 4.5;
        const x = s.x + s.width / 2 + Math.cos(angle) * radius, y = s.y + s.height / 2 + Math.sin(angle) * radius;
        if (i === 0) ctx.moveTo(x, y);
        else ctx.lineTo(x, y);
      }
      ctx.closePath();
      const gold = "#fabf1a";
      if (level === 2) {
        ctx.fillStyle = gold;
        ctx.fill();
      } else if (level === 1) {
        ctx.save();
        ctx.clip();
        ctx.fillStyle = gold;
        ctx.fillRect(s.x, s.y, s.width / 2, s.height);
        ctx.restore();
      }
      ctx.strokeStyle = gold;
      ctx.lineWidth = 0.8;
      ctx.stroke();
      break;
    }
  }
  ctx.restore();
}

export { sameRange };
