import { type CellValue } from "../model/values";
import { CHART_PALETTES, numberFormatOf, styleAt, type ChartObject, type Workbook } from "../model/workbook";
import { formatNumber, formatValue, isDateFormat } from "../formula/numberFormat";
import type { Calculator } from "../formula/calculator";

/** The numbers behind a chart, read from its data range. */
export interface ChartSeries {
  name: string;
  values: (number | null)[];
  xValues: (number | null)[];
}

export interface ChartData {
  categories: string[];
  series: ChartSeries[];
}

export function readChartData(chart: ChartObject, sheetIndex: number, workbook: Workbook, calculator: Calculator): ChartData {
  const r = chart.dataRange;
  const sheet = workbook.sheets[sheetIndex];
  const value = (row: number, column: number): CellValue => calculator.value(sheetIndex, row, column);
  const text = (row: number, column: number) => formatValue(value(row, column), numberFormatOf(styleAt(sheet, row, column))).text;
  const span = (a: number, b: number) => Array.from({ length: b - a + 1 }, (_, i) => a + i);
  // Orient so series run down columns.
  const rows = chart.seriesInColumns ? span(r.start.row, r.end.row) : span(r.start.column, r.end.column);
  const columns = chart.seriesInColumns ? span(r.start.column, r.end.column) : span(r.start.row, r.end.row);
  if (!rows.length || !columns.length || rows.length * columns.length > 200_000) return { categories: [], series: [] };
  const v = (i: number, j: number) => (chart.seriesInColumns ? value(rows[i], columns[j]) : value(columns[j], rows[i]));
  const t = (i: number, j: number) => (chart.seriesInColumns ? text(rows[i], columns[j]) : text(columns[j], rows[i]));
  const isDateColumn = (j: number) => {
    const last = rows[rows.length - 1];
    const [row, column] = chart.seriesInColumns ? [last, columns[j]] : [columns[j], last];
    return isDateFormat(numberFormatOf(styleAt(sheet, row, column)));
  };
  // A header row: text over the value columns.
  const firstDataColumn = columns.length > 1 ? 1 : 0;
  let hasHeader = false;
  if (rows.length > 1) for (let j = firstDataColumn; j < columns.length; j++) if (typeof v(0, j) === "string") hasHeader = true;
  const dataStart = hasHeader ? 1 : 0;
  // A category column: text (or dates) in the first column.
  let labels = false;
  if (columns.length > 1) {
    for (let i = dataStart; i < rows.length; i++) if (typeof v(i, 0) === "string") labels = true;
    if (isDateColumn(0)) labels = true;
  }
  const scatter = chart.kind === "scatter";
  const seriesColumns = labels || (scatter && columns.length > 1) ? span(1, columns.length - 1) : span(0, columns.length - 1);
  const categories: string[] = [];
  for (let i = dataStart; i < rows.length; i++) categories.push(labels || (scatter && columns.length > 1) ? t(i, 0) : String(i - dataStart + 1));
  const series = seriesColumns.map((j, n): ChartSeries => {
    const name = hasHeader ? t(0, j) : `Series ${n + 1}`;
    const values: (number | null)[] = [];
    const xValues: (number | null)[] = [];
    for (let i = dataStart; i < rows.length; i++) {
      const x = v(i, j);
      values.push(typeof x === "number" ? x : null);
      if (scatter) {
        const xv = columns.length > 1 ? v(i, 0) : i - dataStart + 1;
        xValues.push(typeof xv === "number" ? xv : null);
      }
    }
    return { name: name || `Series ${n + 1}`, values, xValues };
  });
  return { categories, series };
}

interface Palette {
  background: string;
  text: string;
  secondaryText: string;
  grid: string;
  axis: string;
}

const palette = (dark: boolean): Palette => dark
  ? { background: "#292b2b", text: "#ebebeb", secondaryText: "#a6a6a6", grid: "rgba(255,255,255,0.1)", axis: "rgba(255,255,255,0.3)" }
  : { background: "#ffffff", text: "#262626", secondaryText: "#6b6b6b", grid: "rgba(0,0,0,0.08)", axis: "rgba(0,0,0,0.28)" };

export const CHART_FONT = '-apple-system, "Segoe UI", system-ui, Ubuntu, "Noto Sans", sans-serif';

/** "Nice" axis bounds and step (1, 2, 2.5 or 5 × 10ⁿ). */
export function niceScale(low: number, high: number, ticks = 5): { min: number; max: number; step: number } {
  let lo = low, hi = high;
  if (lo === hi) {
    lo -= lo === 0 ? 1 : Math.abs(lo) * 0.5;
    hi += hi === 0 ? 1 : Math.abs(hi) * 0.5;
  }
  const rawStep = (hi - lo) / Math.max(ticks, 1);
  const magnitude = Math.pow(10, Math.floor(Math.log10(rawStep)));
  const residual = rawStep / magnitude;
  const nice = residual <= 1 ? 1 : residual <= 2 ? 2 : residual <= 2.5 ? 2.5 : residual <= 5 ? 5 : 10;
  const step = nice * magnitude;
  return { min: Math.floor(lo / step) * step, max: Math.ceil(hi / step) * step, step };
}

const trim = (v: number) => {
  const s = v.toFixed(1);
  return s.endsWith(".0") ? s.slice(0, -2) : s;
};

export function axisLabel(value: number, step: number): string {
  const magnitude = Math.abs(value);
  if (magnitude >= 1e9) return trim(value / 1e9) + "B";
  if (magnitude >= 1e6) return trim(value / 1e6) + "M";
  if (magnitude >= 10_000) return trim(value / 1000) + "K";
  const decimals = step < 1 ? Math.min(Math.ceil(-Math.log10(step)), 6) : 0;
  return formatNumber(value, decimals > 0 ? "#,##0." + "0".repeat(decimals) : "#,##0").text;
}

const isRadial = (chart: ChartObject) => chart.kind === "pie" || chart.kind === "doughnut";

function roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  const radius = Math.max(0, Math.min(r, w / 2, h / 2));
  ctx.beginPath();
  ctx.moveTo(x + radius, y);
  ctx.arcTo(x + w, y, x + w, y + h, radius);
  ctx.arcTo(x + w, y + h, x, y + h, radius);
  ctx.arcTo(x, y + h, x, y, radius);
  ctx.arcTo(x, y, x + w, y, radius);
  ctx.closePath();
}

function withAlpha(hex: string, alpha: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`;
}

/** Draws a chart into `rect` (CSS pixels). */
export function drawChart(ctx: CanvasRenderingContext2D, chart: ChartObject, data: ChartData, rect: { x: number; y: number; width: number; height: number }, dark: boolean, scale = 1) {
  const p = palette(dark);
  const font = (size: number, weight = 400) => `${weight} ${size * scale}px ${CHART_FONT}`;
  ctx.save();
  ctx.fillStyle = p.background;
  ctx.fillRect(rect.x, rect.y, rect.width, rect.height);
  ctx.textBaseline = "top";
  const colors = CHART_PALETTES[chart.palette];
  const plot = { x: rect.x + 14 * scale, y: rect.y + 12 * scale, width: rect.width - 28 * scale, height: rect.height - 24 * scale };

  if (chart.title) {
    ctx.font = font(15, 600);
    ctx.fillStyle = p.text;
    const w = ctx.measureText(chart.title).width;
    ctx.fillText(chart.title, rect.x + rect.width / 2 - w / 2, plot.y);
    const h = 15 * scale * 1.2;
    plot.y += h + 8 * scale;
    plot.height -= h + 8 * scale;
  }

  if (!data.series.length || !data.series.some((s) => s.values.some((v) => v !== null))) {
    ctx.font = font(12);
    ctx.fillStyle = p.secondaryText;
    const message = "No numeric data to chart";
    const w = ctx.measureText(message).width;
    ctx.fillText(message, rect.x + rect.width / 2 - w / 2, rect.y + rect.height / 2 - 7 * scale);
    ctx.restore();
    return;
  }

  // Legend at the bottom.
  const items: [string, string][] = isRadial(chart)
    ? data.categories.map((c, i) => [c, colors[i % colors.length]])
    : data.series.map((s, i) => [s.name, colors[i % colors.length]]);
  if (chart.showLegend && (items.length > 1 || isRadial(chart))) {
    const height = drawLegend(ctx, items, plot.width, plot.x, 0, p, scale, true);
    drawLegend(ctx, items, plot.width, plot.x, plot.y + plot.height - height, p, scale, false);
    plot.height -= height + 6 * scale;
  }

  ctx.beginPath();
  ctx.rect(rect.x, rect.y, rect.width, rect.height);
  ctx.clip();
  if (isRadial(chart)) drawPie(ctx, chart, data, plot, colors, p, scale);
  else drawCartesian(ctx, chart, data, plot, colors, p, scale);
  ctx.restore();
}

function drawLegend(ctx: CanvasRenderingContext2D, items: [string, string][], width: number, x0: number, y0: number, p: Palette, scale: number, measureOnly: boolean): number {
  ctx.font = `400 ${11 * scale}px ${CHART_FONT}`;
  const lineHeight = 16 * scale;
  const lines: [string, string, number][][] = [[]];
  let lineWidth = 0;
  for (const [name, color] of items.slice(0, 24)) {
    const w = Math.min(ctx.measureText(name).width, 160 * scale) + 22 * scale;
    if (lineWidth + w > width && lines[lines.length - 1].length) {
      lines.push([]);
      lineWidth = 0;
    }
    lines[lines.length - 1].push([name, color, w]);
    lineWidth += w;
  }
  const height = lines.length * lineHeight;
  if (measureOnly) return height;
  lines.forEach((line, i) => {
    const total = line.reduce((a, l) => a + l[2], 0);
    let x = x0 + (width - total) / 2;
    const y = y0 + i * lineHeight;
    for (const [name, color, w] of line) {
      ctx.fillStyle = color;
      roundRect(ctx, x, y + 4 * scale, 9 * scale, 9 * scale, 2 * scale);
      ctx.fill();
      ctx.fillStyle = p.secondaryText;
      ctx.save();
      ctx.beginPath();
      ctx.rect(x + 13 * scale, y, w - 18 * scale, lineHeight);
      ctx.clip();
      ctx.fillText(name, x + 13 * scale, y + 2 * scale);
      ctx.restore();
      x += w;
    }
  });
  return height;
}

function drawCartesian(ctx: CanvasRenderingContext2D, chart: ChartObject, data: ChartData, area: { x: number; y: number; width: number; height: number }, colors: string[], p: Palette, scale: number) {
  const horizontal = chart.kind === "bar";
  const stacked = chart.kind === "stackedColumn";
  const count = data.categories.length;
  if (!count) return;

  // Value range.
  let low = 0, high = 0;
  if (stacked) {
    for (let i = 0; i < count; i++) {
      let positives = 0, negatives = 0;
      for (const s of data.series) {
        const v = s.values[i];
        if (v === null || v === undefined) continue;
        if (v > 0) positives += v;
        else negatives += v;
      }
      high = Math.max(high, positives);
      low = Math.min(low, negatives);
    }
  } else {
    const all = data.series.flatMap((s) => s.values.filter((v): v is number => v !== null));
    const lineLike = chart.kind === "line" || chart.kind === "scatter";
    const min = all.length ? Math.min(...all) : 0, max = all.length ? Math.max(...all) : 0;
    low = Math.min(min, lineLike ? min : 0);
    high = Math.max(max, lineLike ? max : 0);
    if (!(lineLike && low > 0 && high - low < high * 0.5) && low > 0) low = 0;
  }
  const y = niceScale(low, high);

  // X range for scatter.
  let x = { min: 0, max: count, step: 1 };
  if (chart.kind === "scatter") {
    const xs = data.series.flatMap((s) => s.xValues.filter((v): v is number => v !== null));
    x = niceScale(xs.length ? Math.min(...xs) : 0, xs.length ? Math.max(...xs) : 1);
  }

  ctx.font = `400 ${10 * scale}px ${CHART_FONT}`;
  const valueLabels: string[] = [];
  for (let tick = y.min; tick <= y.max + y.step / 2; tick += y.step) valueLabels.push(axisLabel(tick, y.step));
  const valueLabelWidth = Math.max(0, ...valueLabels.map((l) => ctx.measureText(l).width)) + 6 * scale;
  const categoryLabelHeight = 16 * scale;
  let plot = { ...area };
  if (chart.yAxisTitle) { plot.x += 16 * scale; plot.width -= 16 * scale; }
  if (chart.xAxisTitle) plot.height -= 16 * scale;
  if (horizontal) {
    const categoryWidth = Math.min(Math.max(0, ...data.categories.map((c) => ctx.measureText(c).width)) + 8 * scale, area.width * 0.35);
    plot = { x: plot.x + categoryWidth, y: plot.y, width: plot.width - categoryWidth - 8 * scale, height: plot.height - categoryLabelHeight };
  } else {
    plot = { x: plot.x + valueLabelWidth, y: plot.y + 4 * scale, width: plot.width - valueLabelWidth - 6 * scale, height: plot.height - categoryLabelHeight - 4 * scale };
  }
  if (plot.width <= 20 || plot.height <= 20) return;
  const maxY = plot.y + plot.height;

  const position = (v: number) => {
    const t = (v - y.min) / (y.max - y.min);
    return horizontal ? plot.x + t * plot.width : maxY - t * plot.height;
  };

  // Gridlines and value labels.
  let index = 0;
  for (let tick = y.min; tick <= y.max + y.step / 2; tick += y.step, index++) {
    const pos = position(tick);
    const zero = Math.abs(tick) < y.step / 1000;
    if (chart.showGridlines || zero) {
      ctx.fillStyle = zero ? p.axis : p.grid;
      if (horizontal) ctx.fillRect(pos, plot.y, 1, plot.height);
      else ctx.fillRect(plot.x, pos, plot.width, 1);
    }
    const label = valueLabels[index] ?? axisLabel(tick, y.step);
    const w = ctx.measureText(label).width;
    ctx.fillStyle = p.secondaryText;
    if (horizontal) ctx.fillText(label, pos - w / 2, maxY + 3 * scale);
    else ctx.fillText(label, plot.x - w - 5 * scale, pos - 6 * scale);
  }

  // Axis titles.
  ctx.font = `500 ${11 * scale}px ${CHART_FONT}`;
  ctx.fillStyle = p.secondaryText;
  if (chart.xAxisTitle) {
    const w = ctx.measureText(chart.xAxisTitle).width;
    ctx.fillText(chart.xAxisTitle, plot.x + plot.width / 2 - w / 2, area.y + area.height - 13 * scale);
  }
  if (chart.yAxisTitle) {
    const w = ctx.measureText(chart.yAxisTitle).width;
    ctx.save();
    ctx.translate(area.x + 7 * scale, plot.y + plot.height / 2);
    ctx.rotate(-Math.PI / 2);
    ctx.fillText(chart.yAxisTitle, -w / 2, -7 * scale);
    ctx.restore();
  }

  // Category labels (thinned to fit).
  ctx.font = `400 ${10 * scale}px ${CHART_FONT}`;
  const band = (horizontal ? plot.height : plot.width) / count;
  if (chart.kind !== "scatter") {
    const widest = Math.max(0, ...data.categories.map((c) => ctx.measureText(c).width));
    const stride = horizontal ? Math.max(1, Math.ceil((14 * scale) / Math.max(band, 1))) : Math.max(1, Math.ceil((widest + 6 * scale) / Math.max(band, 1)));
    ctx.fillStyle = p.secondaryText;
    data.categories.forEach((category, i) => {
      if (i % stride !== 0) return;
      const w = ctx.measureText(category).width;
      if (horizontal) {
        const cy = plot.y + band * (i + 0.5);
        const room = plot.x - area.x - 6 * scale;
        ctx.save();
        ctx.beginPath();
        ctx.rect(area.x, cy - 8 * scale, room, 16 * scale);
        ctx.clip();
        ctx.fillText(category, area.x + Math.max(room - w, 0), cy - 6 * scale);
        ctx.restore();
      } else {
        const cx = plot.x + band * (i + 0.5);
        ctx.fillText(category, cx - Math.min(w, band * stride) / 2, maxY + 3 * scale);
      }
    });
  } else {
    for (let xv = x.min; xv <= x.max + x.step / 2; xv += x.step) {
      const px = plot.x + ((xv - x.min) / (x.max - x.min)) * plot.width;
      if (chart.showGridlines) {
        ctx.fillStyle = p.grid;
        ctx.fillRect(px, plot.y, 1, plot.height);
      }
      const label = axisLabel(xv, x.step);
      ctx.fillStyle = p.secondaryText;
      ctx.fillText(label, px - ctx.measureText(label).width / 2, maxY + 3 * scale);
    }
  }
  ctx.fillStyle = p.axis;
  if (horizontal) ctx.fillRect(position(Math.max(y.min, 0)), plot.y, 1, plot.height);
  else ctx.fillRect(plot.x, maxY, plot.width, 1);

  const dataLabelFont = `500 ${9.5 * scale}px ${CHART_FONT}`;
  const seriesCount = data.series.length;
  if (chart.kind === "column" || chart.kind === "bar" || chart.kind === "stackedColumn") {
    const groupWidth = band * 0.72;
    const barWidth = stacked ? groupWidth : groupWidth / Math.max(seriesCount, 1);
    for (let i = 0; i < count; i++) {
      let positiveBase = 0, negativeBase = 0;
      data.series.forEach((series, s) => {
        const value = series.values[i];
        if (value === null || value === undefined) return;
        let from = 0, to = value;
        if (stacked) {
          if (value >= 0) { from = positiveBase; to = positiveBase + value; positiveBase = to; }
          else { from = negativeBase; to = negativeBase + value; negativeBase = to; }
        }
        const a = position(from), b = position(to);
        const offset = band * i + (band - groupWidth) / 2 + (stacked ? 0 : barWidth * s);
        const r = horizontal
          ? { x: Math.min(a, b), y: plot.y + offset, width: Math.abs(b - a), height: barWidth * 0.92 }
          : { x: plot.x + offset, y: Math.min(a, b), width: barWidth * 0.92, height: Math.abs(b - a) };
        const radius = stacked ? 0 : Math.min(3 * scale, (horizontal ? r.height : r.width) / 4);
        ctx.fillStyle = colors[s % colors.length];
        roundRect(ctx, r.x, r.y, r.width, r.height, radius);
        ctx.fill();
        if (chart.showDataLabels) {
          ctx.font = dataLabelFont;
          ctx.fillStyle = p.text;
          const label = axisLabel(value, y.step / 10);
          const w = ctx.measureText(label).width;
          if (horizontal) ctx.fillText(label, r.x + r.width + 3, r.y + r.height / 2 - 6 * scale);
          else ctx.fillText(label, r.x + r.width / 2 - w / 2, value >= 0 ? r.y - 13 * scale : r.y + r.height + 1);
        }
      });
    }
  } else if (chart.kind === "line" || chart.kind === "area") {
    for (let s = data.series.length - 1; s >= 0; s--) {
      const series = data.series[s];
      const color = colors[s % colors.length];
      const points = Array.from({ length: count }, (_, i) => {
        const v = series.values[i];
        return v === null || v === undefined ? null : { x: plot.x + band * (i + 0.5), y: position(v) };
      });
      const valid = points.filter((pt): pt is { x: number; y: number } => !!pt);
      if (!valid.length) continue;
      if (chart.kind === "area") {
        const base = position(Math.max(y.min, 0));
        ctx.beginPath();
        ctx.moveTo(valid[0].x, base);
        for (const pt of valid) ctx.lineTo(pt.x, pt.y);
        ctx.lineTo(valid[valid.length - 1].x, base);
        ctx.closePath();
        ctx.fillStyle = withAlpha(color, 0.35);
        ctx.fill();
      }
      ctx.beginPath();
      let started = false;
      for (const pt of points) {
        if (!pt) { started = false; continue; }
        if (started) ctx.lineTo(pt.x, pt.y);
        else { ctx.moveTo(pt.x, pt.y); started = true; }
      }
      ctx.lineWidth = 2.2 * scale;
      ctx.lineJoin = "round";
      ctx.lineCap = "round";
      ctx.strokeStyle = color;
      ctx.stroke();
      if (chart.kind === "line" && count <= 40) {
        for (const pt of valid) {
          ctx.beginPath();
          ctx.arc(pt.x, pt.y, 3 * scale, 0, Math.PI * 2);
          ctx.fillStyle = p.background;
          ctx.fill();
          ctx.lineWidth = 1.8 * scale;
          ctx.strokeStyle = color;
          ctx.stroke();
        }
      }
      if (chart.showDataLabels) {
        ctx.font = dataLabelFont;
        ctx.fillStyle = p.text;
        points.forEach((pt, i) => {
          const v = series.values[i];
          if (!pt || v === null || v === undefined) return;
          const label = axisLabel(v, y.step / 10);
          ctx.fillText(label, pt.x - ctx.measureText(label).width / 2, pt.y - 16 * scale);
        });
      }
    }
  } else if (chart.kind === "scatter") {
    data.series.forEach((series, s) => {
      ctx.fillStyle = withAlpha(colors[s % colors.length], 0.85);
      series.values.forEach((value, i) => {
        const xv = series.xValues[i];
        if (value === null || xv === null || xv === undefined) return;
        const px = plot.x + ((xv - x.min) / (x.max - x.min)) * plot.width;
        ctx.beginPath();
        ctx.arc(px, position(value), 3.5 * scale, 0, Math.PI * 2);
        ctx.fill();
      });
    });
  }
}

function drawPie(ctx: CanvasRenderingContext2D, chart: ChartObject, data: ChartData, area: { x: number; y: number; width: number; height: number }, colors: string[], p: Palette, scale: number) {
  const series = data.series[0];
  if (!series) return;
  const values = series.values.map((v) => Math.max(v ?? 0, 0));
  const total = values.reduce((a, b) => a + b, 0);
  if (total <= 0) return;
  const radius = Math.min(area.width, area.height) / 2 - 6 * scale;
  if (radius <= 4) return;
  const cx = area.x + area.width / 2, cy = area.y + area.height / 2;
  let angle = -Math.PI / 2;
  ctx.font = `600 ${10.5 * scale}px ${CHART_FONT}`;
  values.forEach((value, i) => {
    if (value <= 0) return;
    const sweep = (value / total) * 2 * Math.PI;
    ctx.beginPath();
    ctx.moveTo(cx, cy);
    ctx.arc(cx, cy, radius, angle, angle + sweep);
    ctx.closePath();
    ctx.fillStyle = colors[i % colors.length];
    ctx.fill();
    ctx.strokeStyle = p.background;
    ctx.lineWidth = 1.5 * scale;
    ctx.stroke();
    if (chart.showDataLabels || sweep > 0.35) {
      const mid = angle + sweep / 2;
      const labelRadius = chart.kind === "doughnut" ? radius * 0.78 : radius * 0.64;
      const label = chart.showDataLabels ? axisLabel(value, 0.1) : formatNumber(value / total, "0%").text;
      ctx.fillStyle = "#ffffff";
      const w = ctx.measureText(label).width;
      ctx.fillText(label, cx + Math.cos(mid) * labelRadius - w / 2, cy + Math.sin(mid) * labelRadius - 6 * scale);
    }
    angle += sweep;
  });
  if (chart.kind === "doughnut") {
    ctx.beginPath();
    ctx.arc(cx, cy, radius * 0.55, 0, Math.PI * 2);
    ctx.fillStyle = p.background;
    ctx.fill();
    ctx.font = `700 ${16 * scale}px ${CHART_FONT}`;
    ctx.fillStyle = p.text;
    const text = axisLabel(total, 1);
    ctx.fillText(text, cx - ctx.measureText(text).width / 2, cy - 9 * scale);
  }
}
