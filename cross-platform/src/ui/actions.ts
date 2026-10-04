import type { CellAddress } from "../model/address";
import type { ChartObject, Rule } from "../model/workbook";
import type { PasteMode } from "../engine/controller";
import type { FunctionCategory } from "../formula";
import type { FormatID } from "../formats";

/** Window-level commands the ribbon, menus and grid share. */
export interface AppActions {
  newWorkbook(): void;
  newFromTemplate(): void;
  open(): void;
  save(): void;
  saveAs(): void;
  exportAs(format: FormatID | "pdf"): void;
  print(): void;
  importText(): void;
  pageSetup(): void;
  copy(cut: boolean): void;
  paste(mode: PasteMode): void;
  formatCells(tab?: "number" | "alignment" | "font" | "border" | "fill"): void;
  customSort(): void;
  conditionalFormat(rule?: Rule["type"]): void;
  manageRules(): void;
  nameManager(): void;
  defineName(): void;
  goTo(): void;
  goToSpecial(): void;
  find(replace: boolean): void;
  insertFunction(category?: FunctionCategory): void;
  insertLink(): void;
  editNote(a?: CellAddress): void;
  textToColumns(): void;
  columnWidth(): void;
  rowHeight(): void;
  editChart(chart: ChartObject): void;
  fillSeries(): void;
  statistics(): void;
  settings(): void;
  about(): void;
  checkForUpdates(): void;
  openURL(url: string): void;
  focusGrid(): void;
}
