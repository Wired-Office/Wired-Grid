import { isSingleCell, isWholeColumns, isWholeRows, range, rangeContains, type CellAddress, type CellRange } from "../model/address";

/** The selected cells on one sheet: one or more ranges plus the active cell. */
export interface Selection {
  /** The cell that receives typing. */
  active: CellAddress;
  /** Where Shift-extension starts from. */
  anchor: CellAddress;
  /** Every selected range; the last is the current one and contains `active`. */
  ranges: CellRange[];
}

export const selectionAt = (a: CellAddress): Selection => ({ active: a, anchor: a, ranges: [range(a)] });
export const selectionOf = (r: CellRange, active: CellAddress = r.start): Selection => ({ active, anchor: r.start, ranges: [r] });

export const primaryRange = (s: Selection) => s.ranges[s.ranges.length - 1] ?? range(s.active);
export const isSingleSelection = (s: Selection) => s.ranges.length === 1 && isSingleCell(primaryRange(s));
export const isMultipleSelection = (s: Selection) => s.ranges.length > 1;
export const selectionContains = (s: Selection, a: CellAddress) => s.ranges.some((r) => rangeContains(r, a));

export function selectedColumns(s: Selection): Set<number> {
  const set = new Set<number>();
  for (const r of s.ranges) if (isWholeColumns(r)) for (let c = r.start.column; c <= r.end.column; c++) set.add(c);
  return set;
}

export function selectedRows(s: Selection): Set<number> {
  const set = new Set<number>();
  for (const r of s.ranges) if (isWholeRows(r)) for (let row = r.start.row; row <= r.end.row && set.size < 2_000_000; row++) set.add(row);
  return set;
}

export function sameSelection(a: Selection, b: Selection): boolean {
  if (a.ranges.length !== b.ranges.length) return false;
  const same = (p: CellAddress, q: CellAddress) => p.row === q.row && p.column === q.column;
  return same(a.active, b.active) && same(a.anchor, b.anchor) && a.ranges.every((r, i) => same(r.start, b.ranges[i].start) && same(r.end, b.ranges[i].end));
}
