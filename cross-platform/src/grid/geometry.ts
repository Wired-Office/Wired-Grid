import { MAX_COLUMNS, MAX_ROWS, type CellAddress, type CellRange } from "../model/address";
import { DEFAULT_COLUMN_WIDTH, DEFAULT_ROW_HEIGHT, type Sheet } from "../model/workbook";

/**
 * Positions along one axis (rows or columns) with custom and hidden sizes.
 * Offsets use a binary search over the few custom sizes, so the full
 * 1,048,576-row sheet costs nothing.
 */
export class AxisMetrics {
  readonly defaultSize: number;
  private keys: number[];
  private sizes: number[];
  /** prefix[i] = sum of (size - default) for keys[0..<i] */
  private prefix: number[];

  constructor(defaultSize: number, custom: Map<number, number>, hidden: Iterable<number>, zoom: number, readonly limit: number) {
    this.defaultSize = defaultSize * zoom;
    const merged = new Map<number, number>();
    for (const [index, size] of custom) if (index < limit) merged.set(index, size * zoom);
    for (const index of hidden) if (index < limit) merged.set(index, 0);
    this.keys = [...merged.keys()].sort((a, b) => a - b);
    this.sizes = this.keys.map((k) => merged.get(k)!);
    this.prefix = [0];
    let running = 0;
    for (const size of this.sizes) {
      running += size - this.defaultSize;
      this.prefix.push(running);
    }
  }

  /** Number of custom entries with index < i. */
  private customCount(i: number): number {
    let low = 0, high = this.keys.length;
    while (low < high) {
      const mid = (low + high) >> 1;
      if (this.keys[mid] < i) low = mid + 1;
      else high = mid;
    }
    return low;
  }

  size(i: number): number {
    const k = this.customCount(i);
    return k < this.keys.length && this.keys[k] === i ? this.sizes[k] : this.defaultSize;
  }

  /** Start of index `i`. */
  offset(i: number): number {
    return i * this.defaultSize + this.prefix[this.customCount(i)];
  }

  end(i: number): number {
    return this.offset(i) + this.size(i);
  }

  /** The index covering `position` (skipping zero-size entries forward). */
  index(position: number): number {
    if (position <= 0) return this.firstVisible(0);
    let low = 0, high = this.limit - 1;
    while (low < high) {
      const mid = Math.floor((low + high + 1) / 2);
      if (this.offset(mid) <= position) low = mid;
      else high = mid - 1;
    }
    return this.firstVisible(low);
  }

  firstVisible(i: number): number {
    let index = i;
    while (index < this.limit - 1 && this.size(index) === 0) index++;
    return index;
  }

  isHidden(i: number): boolean {
    return this.size(i) === 0;
  }
}

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

export const rectContains = (r: Rect, x: number, y: number) => x >= r.x && x <= r.x + r.width && y >= r.y && y <= r.y + r.height;
export const insetRect = (r: Rect, dx: number, dy: number): Rect => ({ x: r.x + dx, y: r.y + dy, width: r.width - 2 * dx, height: r.height - 2 * dy });

/** Maps between cells and view coordinates, including headers and frozen panes. */
export class GridGeometry {
  readonly rows: AxisMetrics;
  readonly columns: AxisMetrics;
  readonly headerWidth: number;
  readonly headerHeight: number;
  readonly frozenRows: number;
  readonly frozenColumns: number;
  readonly frozenWidth: number;
  readonly frozenHeight: number;
  readonly scrollX: number;
  readonly scrollY: number;

  constructor(sheet: Sheet, readonly zoom: number, scrollX: number, scrollY: number, readonly width: number, readonly height: number) {
    this.rows = new AxisMetrics(DEFAULT_ROW_HEIGHT, sheet.rowHeights, [...sheet.hiddenRows, ...(sheet.filter?.hiddenRows ?? [])], zoom, MAX_ROWS);
    this.columns = new AxisMetrics(DEFAULT_COLUMN_WIDTH, sheet.columnWidths, sheet.hiddenColumns, zoom, MAX_COLUMNS);
    if (sheet.showHeadings) {
      const digits = Math.max(3, String(Math.floor(scrollY / Math.max(this.rows.defaultSize, 1)) + 200).length);
      this.headerWidth = Math.ceil(digits * 8 * Math.max(zoom, 0.8) + 14);
      this.headerHeight = Math.ceil(22 * Math.max(zoom, 0.8));
    } else {
      this.headerWidth = 0;
      this.headerHeight = 0;
    }
    this.frozenRows = sheet.frozenRows;
    this.frozenColumns = sheet.frozenColumns;
    this.frozenWidth = this.columns.offset(sheet.frozenColumns);
    this.frozenHeight = this.rows.offset(sheet.frozenRows);
    this.scrollX = Math.max(scrollX, 0);
    this.scrollY = Math.max(scrollY, 0);
  }

  /** Top-left of the scrolling cell area. */
  get bodyX() { return this.headerWidth + this.frozenWidth; }
  get bodyY() { return this.headerHeight + this.frozenHeight; }

  get bodyRect(): Rect {
    return { x: this.bodyX, y: this.bodyY, width: Math.max(this.width - this.bodyX, 0), height: Math.max(this.height - this.bodyY, 0) };
  }

  get cellAreaRect(): Rect {
    return { x: this.headerWidth, y: this.headerHeight, width: Math.max(this.width - this.headerWidth, 0), height: Math.max(this.height - this.headerHeight, 0) };
  }

  x(column: number): number {
    return this.headerWidth + this.columns.offset(column) - (column < this.frozenColumns ? 0 : this.scrollX);
  }

  y(row: number): number {
    return this.headerHeight + this.rows.offset(row) - (row < this.frozenRows ? 0 : this.scrollY);
  }

  cellRect(a: CellAddress): Rect {
    return { x: this.x(a.column), y: this.y(a.row), width: this.columns.size(a.column), height: this.rows.size(a.row) };
  }

  rangeRect(r: CellRange): Rect {
    const left = this.x(r.start.column), top = this.y(r.start.row);
    const right = this.x(r.end.column) + this.columns.size(r.end.column);
    const bottom = this.y(r.end.row) + this.rows.size(r.end.row);
    return { x: left, y: top, width: Math.max(right - left, 0), height: Math.max(bottom - top, 0) };
  }

  /** The column under an x position in the cell area (frozen or scrolled). */
  columnAt(px: number): number {
    const local = px - this.headerWidth;
    if (this.frozenColumns > 0 && local < this.frozenWidth) return this.columns.index(local);
    return Math.max(this.columns.index(local + this.scrollX), this.frozenColumns);
  }

  rowAt(py: number): number {
    const local = py - this.headerHeight;
    if (this.frozenRows > 0 && local < this.frozenHeight) return this.rows.index(local);
    return Math.max(this.rows.index(local + this.scrollY), this.frozenRows);
  }

  addressAt(px: number, py: number): CellAddress {
    return { row: this.rowAt(py), column: this.columnAt(px) };
  }

  /** Visible scrolled columns (excluding frozen ones), as [first, last]. */
  get visibleColumns(): [number, number] {
    const first = Math.max(this.columns.index(this.frozenWidth + this.scrollX), this.frozenColumns);
    const last = Math.max(this.columns.index(this.frozenWidth + this.scrollX + Math.max(this.width - this.bodyX, 1)), first);
    return [first, Math.max(first, Math.min(last + 1, MAX_COLUMNS - 1))];
  }

  get visibleRows(): [number, number] {
    const first = Math.max(this.rows.index(this.frozenHeight + this.scrollY), this.frozenRows);
    const last = Math.max(this.rows.index(this.frozenHeight + this.scrollY + Math.max(this.height - this.bodyY, 1)), first);
    return [first, Math.max(first, Math.min(last + 1, MAX_ROWS - 1))];
  }

  /** Total size of the scrolling content for `rowCount` × `columnCount` cells. */
  contentSize(rowCount: number, columnCount: number): { width: number; height: number } {
    return { width: this.headerWidth + this.columns.offset(columnCount), height: this.headerHeight + this.rows.offset(rowCount) };
  }
}
