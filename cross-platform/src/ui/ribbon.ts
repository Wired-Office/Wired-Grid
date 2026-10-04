import { CHART_KIND_TITLES, TABLE_STYLES, numberFormatOf, type ChartKind, type Rule } from "../model/workbook";
import {
  BORDER_TITLES, NAMED_STYLE_TITLES, PASTE_TITLES, WorkbookController,
  type BorderPreset, type NamedCellStyle, type PasteMode,
} from "../engine/controller";
import { FORMATS as CODES } from "../formula/numberFormat";
import { FUNCTIONS, FUNCTION_CATEGORIES, type FunctionCategory } from "../formula";
import { settings } from "../settings";
import type { AppActions } from "./actions";
import { closePalette, showPalette } from "./colors";
import { icon } from "./icons";
import type { MenuEntry } from "./menubar";
import { showPopupMenu } from "./popup";

export const NUMBER_PRESETS: [string, string][] = [
  ["General", CODES.general], ["Number", CODES.number], ["Currency", CODES.currency], ["Accounting", CODES.accounting],
  ["Short Date", CODES.shortDate], ["Long Date", CODES.longDate], ["Time", CODES.time], ["Percentage", CODES.percent],
  ["Fraction", CODES.fraction], ["Scientific", CODES.scientific], ["Text", CODES.text],
];

const FONT_CANDIDATES = [
  "Helvetica Neue", "Arial", "Calibri", "Cambria", "Candara", "Consolas", "Courier New", "Georgia", "Helvetica", "Segoe UI",
  "Tahoma", "Times New Roman", "Trebuchet MS", "Verdana", "Menlo", "Liberation Sans", "Liberation Serif", "Liberation Mono",
  "DejaVu Sans", "DejaVu Serif", "DejaVu Sans Mono", "Noto Sans", "Noto Serif", "Ubuntu", "Cantarell", "Roboto",
];

const FONT_SIZES = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72];

/** Fonts installed on this computer (measured, since document.fonts.check is unreliable). */
function availableFonts(): string[] {
  const ctx = document.createElement("canvas").getContext("2d");
  if (!ctx) return FONT_CANDIDATES;
  const sample = "mmmmmmmmmmlli1WQ@#";
  const width = (font: string) => { ctx.font = `32px ${font}`; return ctx.measureText(sample).width; };
  const bases = ["monospace", "serif", "sans-serif"].map((b) => [b, width(b)] as const);
  const installed = FONT_CANDIDATES.filter((name) => bases.some(([base, w]) => width(`"${name}", ${base}`) !== w));
  const defaults = settings().defaultFontName;
  return [defaults, ...installed.filter((f) => f !== defaults)];
}

type Tab = "home" | "insert" | "pageLayout" | "formulas" | "data" | "review" | "view";
const TABS: [Tab, string][] = [["home", "Home"], ["insert", "Insert"], ["pageLayout", "Page Layout"], ["formulas", "Formulas"], ["data", "Data"], ["review", "Review"], ["view", "View"]];

interface ButtonOptions {
  isOn?: () => boolean;
  enabled?: () => boolean;
  menu?: () => MenuEntry[];
  title?: string;
}

/** The Excel-style ribbon: a row of tabs over the selected tab's commands. */
export class Ribbon {
  private tab: Tab = "home";
  private collapsed = false;
  private updaters: (() => void)[] = [];
  private body!: HTMLDivElement;
  private tabButtons = new Map<Tab, HTMLButtonElement>();
  private chartTab!: HTMLButtonElement;
  private fonts = availableFonts();
  private lastFill = "#FFEB9C";
  private lastText = "#C00000";

  constructor(private root: HTMLElement, private c: WorkbookController, private actions: AppActions) {
    this.build();
  }

  showTab(tab: Tab) {
    this.tab = tab;
    this.collapsed = false;
    this.render();
  }

  toggleCollapsed() {
    this.collapsed = !this.collapsed;
    this.render();
  }

  get tabs() {
    return TABS;
  }

  private build() {
    const strip = document.createElement("div");
    strip.className = "ribbon-tabs";
    for (const [id, title] of TABS) {
      const button = document.createElement("button");
      button.className = "ribbon-tab";
      button.textContent = title;
      button.addEventListener("mousedown", (e) => e.preventDefault());
      button.addEventListener("click", () => {
        if (this.tab === id && !this.collapsed) return;
        this.tab = id;
        this.collapsed = false;
        this.render();
      });
      button.addEventListener("dblclick", () => { this.tab = id; this.toggleCollapsed(); });
      this.tabButtons.set(id, button);
      strip.append(button);
    }
    this.chartTab = document.createElement("button");
    this.chartTab.className = "ribbon-tab contextual";
    this.chartTab.textContent = "Chart";
    this.chartTab.title = "Edit the selected chart";
    this.chartTab.hidden = true;
    this.chartTab.addEventListener("click", () => {
      const chart = this.c.sheet.charts.find((ch) => ch.id === this.c.selectedChartId);
      if (chart) this.actions.editChart(chart);
    });
    strip.append(this.chartTab);
    const collapse = document.createElement("button");
    collapse.className = "ribbon-collapse";
    collapse.title = "Collapse the Ribbon";
    collapse.textContent = "⌃";
    collapse.addEventListener("click", () => {
      this.toggleCollapsed();
      collapse.textContent = this.collapsed ? "⌄" : "⌃";
      collapse.title = this.collapsed ? "Show the Ribbon" : "Collapse the Ribbon";
    });
    strip.append(collapse);
    this.body = document.createElement("div");
    this.body.className = "ribbon-body";
    this.root.append(strip, this.body);
    this.render();
  }

  private render() {
    for (const [id, button] of this.tabButtons) button.classList.toggle("selected", id === this.tab && !this.collapsed);
    this.body.classList.toggle("collapsed", this.collapsed);
    this.body.replaceChildren();
    this.updaters = [];
    const groups: HTMLElement[] = {
      home: () => this.home(), insert: () => this.insert(), pageLayout: () => this.pageLayout(), formulas: () => this.formulas(),
      data: () => this.data(), review: () => this.review(), view: () => this.view(),
    }[this.tab]();
    this.body.append(...groups);
    this.refresh();
  }

  /** Updates toggles and fields for the current selection. */
  refresh() {
    this.chartTab.hidden = !this.c.selectedChartId;
    for (const update of this.updaters) update();
  }

  // MARK: Builders

  private group(title: string, ...children: HTMLElement[]): HTMLElement {
    const group = document.createElement("div");
    group.className = "rb-group";
    const content = document.createElement("div");
    content.className = "rb-group-content";
    content.append(...children);
    const caption = document.createElement("div");
    caption.className = "rb-group-title";
    caption.textContent = title;
    group.append(content, caption);
    return group;
  }

  private stack(...rows: HTMLElement[][]): HTMLElement {
    const stack = document.createElement("div");
    stack.className = "rb-stack";
    for (const items of rows) {
      const row = document.createElement("div");
      row.className = "rb-row";
      row.append(...items);
      stack.append(row);
    }
    return stack;
  }

  private button(iconName: string | null, label: string | null, action: (() => void) | null, options: ButtonOptions & { large?: boolean; text?: string } = {}): HTMLButtonElement {
    const b = document.createElement("button");
    b.className = "rb" + (options.large ? " large" : "");
    b.type = "button";
    if (iconName) b.insertAdjacentHTML("beforeend", icon(iconName));
    if (options.text) {
      const t = document.createElement("span");
      t.className = "rb-text";
      t.textContent = options.text;
      b.append(t);
    }
    if (label) {
      const l = document.createElement("span");
      l.className = "label";
      l.textContent = label;
      b.append(l);
    }
    if (options.menu && !action) b.insertAdjacentHTML("beforeend", '<span class="caret">▾</span>');
    b.title = options.title ?? label ?? "";
    b.addEventListener("mousedown", (e) => e.preventDefault());
    b.addEventListener("click", () => {
      closePalette();
      if (action) action();
      else if (options.menu) showPopupMenu(b, options.menu(), () => this.actions.focusGrid());
      if (action) this.actions.focusGrid();
    });
    if (options.isOn || options.enabled) {
      this.updaters.push(() => {
        if (options.isOn) b.classList.toggle("on", options.isOn());
        if (options.enabled) b.disabled = !options.enabled();
      });
    }
    return b;
  }

  private large(iconName: string, label: string, action: (() => void) | null, options: ButtonOptions = {}) {
    if (action && options.menu) return this.split(this.button(iconName, label, action, { ...options, large: true, menu: undefined }), options.menu, true);
    return this.button(iconName, label, action, { ...options, large: true });
  }

  private small(iconName: string | null, label: string | null, action: (() => void) | null, options: ButtonOptions & { text?: string } = {}) {
    if (action && options.menu) return this.split(this.button(iconName, label, action, { ...options, menu: undefined }), options.menu, false);
    return this.button(iconName, label, action, options);
  }

  private split(main: HTMLButtonElement, menu: () => MenuEntry[], large: boolean): HTMLElement {
    const wrap = document.createElement("div");
    wrap.className = "rb-split";
    if (large) wrap.style.flexDirection = "column";
    const arrow = document.createElement("button");
    arrow.className = "rb";
    arrow.type = "button";
    arrow.innerHTML = '<span class="caret">▾</span>';
    if (large) Object.assign(arrow.style, { height: "14px", width: "100%", borderRadius: "0 0 5px 5px" });
    arrow.title = main.title;
    arrow.addEventListener("mousedown", (e) => e.preventDefault());
    arrow.addEventListener("click", () => showPopupMenu(arrow, menu(), () => this.actions.focusGrid()));
    if (large) main.style.height = "48px";
    wrap.append(main, arrow);
    return wrap;
  }

  private select(className: string, options: [string, string][], current: () => string, onChange: (value: string) => void, title: string, editable = false): HTMLElement {
    if (editable) {
      const input = document.createElement("input");
      input.className = "rb-select " + className;
      input.title = title;
      const list = document.createElement("datalist");
      list.id = `list-${className}`;
      for (const [value] of options) list.append(new Option(value, value));
      input.setAttribute("list", list.id);
      input.addEventListener("change", () => { onChange(input.value); this.actions.focusGrid(); });
      input.addEventListener("keydown", (e) => { if (e.key === "Enter") { onChange(input.value); this.actions.focusGrid(); } else if (e.key === "Escape") this.actions.focusGrid(); });
      this.updaters.push(() => { if (document.activeElement !== input) input.value = current(); });
      const wrap = document.createElement("span");
      wrap.append(input, list);
      return wrap;
    }
    const select = document.createElement("select");
    select.className = "rb-select " + className;
    select.title = title;
    for (const [label, value] of options) select.append(new Option(label, value));
    select.addEventListener("change", () => { onChange(select.value); this.actions.focusGrid(); });
    this.updaters.push(() => {
      if (document.activeElement === select) return;
      const value = current();
      if (![...select.options].some((o) => o.value === value)) {
        select.querySelector("option[data-custom]")?.remove();
        const option = new Option("Custom", value);
        option.dataset.custom = "1";
        select.append(option);
      }
      select.value = value;
    });
    return select;
  }

  private colorButton(iconName: string, title: string, kind: "fill" | "text"): HTMLElement {
    const swatchColor = () => (kind === "fill" ? this.lastFill : this.lastText);
    const apply = (color: string | undefined) => {
      if (kind === "fill") {
        if (color) this.lastFill = color;
        this.c.setFillColor(color);
      } else {
        if (color) this.lastText = color;
        this.c.setTextColor(color);
      }
      this.actions.focusGrid();
      update();
    };
    const main = this.button(iconName, null, () => apply(swatchColor()), { title });
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    main.append(swatch);
    const update = () => { swatch.style.background = swatchColor(); };
    update();
    const wrap = document.createElement("div");
    wrap.className = "rb-split";
    const arrow = document.createElement("button");
    arrow.className = "rb";
    arrow.type = "button";
    arrow.title = title;
    arrow.innerHTML = '<span class="caret">▾</span>';
    arrow.addEventListener("mousedown", (e) => e.preventDefault());
    arrow.addEventListener("click", () => showPalette(arrow, kind === "fill" ? "No Fill" : "Automatic", apply));
    wrap.append(main, arrow);
    return wrap;
  }

  // MARK: Menus

  private pasteMenu(): MenuEntry[] {
    const modes: PasteMode[] = ["all", "formulas", "values", "formats", "transpose", "valuesAndNumberFormats", "noBorders", "columnWidths", "link"];
    return modes.map((mode) => ({ label: PASTE_TITLES[mode], action: () => this.actions.paste(mode) }));
  }

  private bordersMenu(): MenuEntry[] {
    const presets: (BorderPreset | "-")[] = ["bottom", "top", "left", "right", "-", "none", "all", "outside", "thickOutside", "-",
      "doubleBottom", "thickBottom", "topAndBottom", "topAndDoubleBottom", "-", "insideHorizontal", "insideVertical"];
    return [
      ...presets.map((p): MenuEntry => (p === "-" ? "-" : { label: BORDER_TITLES[p], action: () => this.c.applyBorders(p) })),
      "-",
      { label: "More Borders…", action: () => this.actions.formatCells("border") },
    ];
  }

  private orientationMenu(): MenuEntry[] {
    const current = this.c.activeStyle.rotation ?? 0;
    return ([["Horizontal", 0], ["Angle Counterclockwise", 45], ["Angle Clockwise", -45], ["Rotate Text Up", 90], ["Rotate Text Down", -90]] as const)
      .map(([label, degrees]) => ({ label, checked: current === degrees, action: () => this.c.setRotation(degrees) }));
  }

  private mergeMenu(): MenuEntry[] {
    return [
      { label: "Merge & Center", action: () => void this.c.merge("mergeAndCenter") },
      { label: "Merge Across", action: () => void this.c.merge("mergeAcross") },
      { label: "Merge Cells", action: () => void this.c.merge("merge") },
      { label: "Unmerge Cells", action: () => void this.c.merge("unmerge") },
    ];
  }

  private currencyMenu(): MenuEntry[] {
    return ([["$ English (US)", CODES.accounting], ["€ Euro", '_-* #,##0.00 €_-;-* #,##0.00 €_-;_-* "-"?? €_-;_-@_-'], ["£ English (UK)", '_-£* #,##0.00_-;-£* #,##0.00_-;_-£* "-"??_-;_-@_-'],
      ["¥ Japanese", '_-¥* #,##0_-;-¥* #,##0_-;_-¥* "-"_-;_-@_-'], ["CHF Swiss", '_-"CHF" * #,##0.00_-;-"CHF" * #,##0.00_-;_-"CHF" * "-"??_-;_-@_-']] as const)
      .map(([label, code]) => ({ label, action: () => this.c.setNumberFormat(code) }));
  }

  private conditionalMenu(): MenuEntry[] {
    const a = this.actions;
    const highlight = (type: Rule["type"]) => () => a.conditionalFormat(type);
    const quick = (rule: Rule) => () => this.c.addConditionalFormat(rule);
    return [
      { label: "Highlight Cells Rules", submenu: [
        { label: "Greater Than…", action: highlight("greaterThan") },
        { label: "Less Than…", action: highlight("lessThan") },
        { label: "Between…", action: highlight("between") },
        { label: "Equal To…", action: highlight("equalTo") },
        { label: "Text that Contains…", action: highlight("textContains") },
        { label: "Duplicate Values", action: quick({ type: "duplicates" }) },
        { label: "Blank Cells", action: quick({ type: "blanks" }) },
      ] },
      { label: "Top/Bottom Rules", submenu: [
        { label: "Top 10 Items", action: quick({ type: "top", count: 10, percent: false }) },
        { label: "Top 10%", action: quick({ type: "top", count: 10, percent: true }) },
        { label: "Bottom 10 Items", action: quick({ type: "bottom", count: 10, percent: false }) },
        { label: "Bottom 10%", action: quick({ type: "bottom", count: 10, percent: true }) },
        { label: "Above Average", action: quick({ type: "aboveAverage" }) },
        { label: "Below Average", action: quick({ type: "belowAverage" }) },
      ] },
      "-",
      { label: "Data Bars", submenu: ([["Green", "#63BE7B"], ["Blue", "#638EC6"], ["Orange", "#FFB628"], ["Red", "#F8696B"], ["Purple", "#8E5BD6"]] as const)
        .map(([label, color]) => ({ label, action: quick({ type: "dataBar", color }) })) },
      { label: "Color Scales", submenu: [
        { label: "Green – Yellow – Red", action: quick({ type: "colorScale", colors: ["#63BE7B", "#FFEB84", "#F8696B"] }) },
        { label: "Red – Yellow – Green", action: quick({ type: "colorScale", colors: ["#F8696B", "#FFEB84", "#63BE7B"] }) },
        { label: "White – Green", action: quick({ type: "colorScale", colors: ["#FFFFFF", "#63BE7B"] }) },
        { label: "White – Blue", action: quick({ type: "colorScale", colors: ["#FFFFFF", "#5A8AC6"] }) },
      ] },
      { label: "Icon Sets", submenu: ([["3 Arrows", "arrows"], ["3 Traffic Lights", "trafficLights"], ["3 Flags", "flags"], ["3 Stars", "stars"]] as const)
        .map(([label, set]) => ({ label, action: quick({ type: "iconSet", set }) })) },
      "-",
      { label: "New Rule…", action: () => a.conditionalFormat() },
      { label: "Clear Rules from Selected Cells", action: () => this.c.clearConditionalFormats(true) },
      { label: "Clear Rules from Entire Sheet", action: () => this.c.clearConditionalFormats(false) },
      { label: "Manage Rules…", action: () => a.manageRules() },
    ];
  }

  private tableMenu(): MenuEntry[] {
    return TABLE_STYLES.map((style) => ({ label: style[0].toUpperCase() + style.slice(1), action: () => this.c.formatAsTable(style) }));
  }

  private cellStylesMenu(): MenuEntry[] {
    return (Object.keys(NAMED_STYLE_TITLES) as NamedCellStyle[]).map((s) => ({ label: NAMED_STYLE_TITLES[s], action: () => this.c.applyNamedStyle(s) }));
  }

  private insertMenu(): MenuEntry[] {
    const c = this.c;
    return [
      { label: "Insert Cells (Shift Down)", action: () => c.insertCells(true) },
      { label: "Insert Cells (Shift Right)", action: () => c.insertCells(false) },
      { label: "Insert Sheet Rows", action: () => c.insertSheetRows() },
      { label: "Insert Sheet Columns", action: () => c.insertSheetColumns() },
      { label: "Insert Sheet", action: () => c.addSheet() },
    ];
  }

  private deleteMenu(): MenuEntry[] {
    const c = this.c;
    return [
      { label: "Delete Cells (Shift Up)", action: () => c.deleteCells(true) },
      { label: "Delete Cells (Shift Left)", action: () => c.deleteCells(false) },
      { label: "Delete Sheet Rows", action: () => c.deleteSheetRows() },
      { label: "Delete Sheet Columns", action: () => c.deleteSheetColumns() },
      { label: "Delete Sheet", enabled: c.workbook.sheets.length > 1, action: () => void c.deleteSheet(c.activeSheetIndex) },
    ];
  }

  private formatMenu(): MenuEntry[] {
    const c = this.c;
    return [
      { label: "Row Height…", action: () => this.actions.rowHeight() },
      { label: "AutoFit Row Height", action: () => c.autoFitRows(c.selectedRowIndices) },
      { label: "Column Width…", action: () => this.actions.columnWidth() },
      { label: "AutoFit Column Width", action: () => c.autoFitColumns(c.selectedColumnIndices) },
      "-",
      { label: "Hide & Unhide", submenu: [
        { label: "Hide Rows", action: () => c.hideRows() },
        { label: "Hide Columns", action: () => c.hideColumns() },
        { label: "Unhide Rows", action: () => c.unhideRows() },
        { label: "Unhide Columns", action: () => c.unhideColumns() },
      ] },
      "-",
      { label: "Rename Sheet", action: () => document.dispatchEvent(new CustomEvent("wg-rename-sheet")) },
      { label: "Tab Color", action: () => document.dispatchEvent(new CustomEvent("wg-tab-color")) },
      "-",
      { label: "Format Cells…", shortcut: "Ctrl+1", action: () => this.actions.formatCells() },
    ];
  }

  private autoSumMenu(): MenuEntry[] {
    return [["Sum", "SUM"], ["Average", "AVERAGE"], ["Count Numbers", "COUNT"], ["Max", "MAX"], ["Min", "MIN"]]
      .map(([label, fn]) => ({ label, action: () => this.c.autoSum(fn) }));
  }

  private functionMenu(categories: FunctionCategory[]): MenuEntry[] {
    const insert = (name: string) => () => {
      const c = this.c;
      if (c.isEditing) document.dispatchEvent(new CustomEvent("wg-insert-function", { detail: name }));
      else c.beginEditingHandler?.(`=${name}()`, [name.length + 2, 0]);
    };
    const specs = [...FUNCTIONS.values()].filter((f) => categories.includes(f.category)).sort((a, b) => (a.name < b.name ? -1 : 1));
    if (categories.length === 1) return specs.map((f) => ({ label: f.name, action: insert(f.name) }));
    return categories.map((cat) => ({ label: cat, submenu: specs.filter((f) => f.category === cat).map((f) => ({ label: f.name, action: insert(f.name) })) }));
  }

  private findMenu(): MenuEntry[] {
    const a = this.actions;
    return [
      { label: "Find…", shortcut: "Ctrl+F", action: () => a.find(false) },
      { label: "Replace…", shortcut: "Ctrl+H", action: () => a.find(true) },
      { label: "Go To…", shortcut: "Ctrl+G", action: () => a.goTo() },
      { label: "Go To Special…", action: () => a.goToSpecial() },
      "-",
      { label: "Formulas", action: () => this.c.selectSpecial("formulas") },
      { label: "Notes", action: () => this.c.selectSpecial("notes") },
      { label: "Conditional Formatting", action: () => this.c.selectSpecial("conditionalFormats") },
      { label: "Constants", action: () => this.c.selectSpecial("constants") },
    ];
  }

  private sortFilterMenu(): MenuEntry[] {
    const c = this.c;
    return [
      { label: "Sort A to Z", action: () => c.quickSort(true) },
      { label: "Sort Z to A", action: () => c.quickSort(false) },
      { label: "Custom Sort…", action: () => this.actions.customSort() },
      "-",
      { label: "Filter", checked: !!c.sheet.filter, shortcut: "Ctrl+Shift+L", action: () => c.toggleFilter() },
      { label: "Clear", enabled: !!c.sheet.filter?.criteria.size, action: () => c.clearFilters() },
      { label: "Reapply", enabled: !!c.sheet.filter, action: () => c.reapplyFilter() },
    ];
  }

  private chartMenu(kinds: ChartKind[]): MenuEntry[] {
    return kinds.map((kind) => ({ label: CHART_KIND_TITLES[kind], action: () => this.c.insertChart(kind) }));
  }

  // MARK: Tabs

  private home(): HTMLElement[] {
    const c = this.c, a = this.actions;
    const style = () => c.activeStyle;
    const fontNames = this.fonts.map((f): [string, string] => [f, f]);
    return [
      this.group("Clipboard",
        this.large("paste", "Paste", () => a.paste("all"), { menu: () => this.pasteMenu(), title: "Paste (Ctrl+V)" }),
        this.stack(
          [this.small("cut", "Cut", () => a.copy(true), { title: "Cut (Ctrl+X)" })],
          [this.small("copy", "Copy", () => a.copy(false), { title: "Copy (Ctrl+C)" })],
          [this.small("painter", "Format", () => (c.formatPainter ? c.cancelFormatPainter() : c.captureFormatPainter(false)), {
            title: "Format Painter: click once to paint one range", isOn: () => !!c.formatPainter,
          })],
        ),
      ),
      this.group("Font",
        this.stack(
          [
            this.select("rb-font", fontNames, () => style().fontName ?? settings().defaultFontName, (v) => v && c.setFontName(v), "Font", true),
            this.select("rb-size", FONT_SIZES.map((s): [string, string] => [String(s), String(s)]), () => String(style().fontSize ?? settings().defaultFontSize), (v) => {
              const n = Number(v);
              if (n > 0) c.setFontSize(n);
            }, "Font Size", true),
            this.small("grow", null, () => c.growFont(true), { title: "Increase Font Size" }),
            this.small("shrink", null, () => c.growFont(false), { title: "Decrease Font Size" }),
          ],
          [
            this.small("bold", null, () => c.toggleBold(), { title: "Bold (Ctrl+B)", isOn: () => !!style().bold }),
            this.small("italic", null, () => c.toggleItalic(), { title: "Italic (Ctrl+I)", isOn: () => !!style().italic }),
            this.small("underline", null, () => c.toggleUnderline(), { title: "Underline (Ctrl+U)", isOn: () => !!style().underline || !!style().doubleUnderline,
              menu: () => [{ label: "Underline", action: () => c.toggleUnderline() }, { label: "Double Underline", action: () => c.toggleDoubleUnderline() }] }),
            this.small("strike", null, () => c.toggleStrikethrough(), { title: "Strikethrough (Ctrl+5)", isOn: () => !!style().strikethrough }),
            this.small("borders", null, () => c.applyBorders("bottom"), { title: "Borders", menu: () => this.bordersMenu() }),
            this.colorButton("fill", "Fill Color", "fill"),
            this.colorButton("fontColor", "Font Color", "text"),
          ],
        ),
      ),
      this.group("Alignment",
        this.stack(
          [
            this.small("alignTop", null, () => c.setVerticalAlignment("top"), { title: "Top Align", isOn: () => style().vertical === "top" }),
            this.small("alignMiddle", null, () => c.setVerticalAlignment("middle"), { title: "Middle Align", isOn: () => style().vertical === "middle" }),
            this.small("alignBottom", null, () => c.setVerticalAlignment("bottom"), { title: "Bottom Align", isOn: () => (style().vertical ?? "bottom") === "bottom" }),
            this.small("orientation", null, null, { title: "Orientation", menu: () => this.orientationMenu() }),
            this.small("wrap", "Wrap Text", () => c.toggleWrap(), { isOn: () => !!style().wrap }),
          ],
          [
            this.small("left", null, () => c.setHorizontalAlignment("left"), { title: "Align Left", isOn: () => style().horizontal === "left" }),
            this.small("center", null, () => c.setHorizontalAlignment("center"), { title: "Center", isOn: () => style().horizontal === "center" }),
            this.small("right", null, () => c.setHorizontalAlignment("right"), { title: "Align Right", isOn: () => style().horizontal === "right" }),
            this.small("indentLess", null, () => c.changeIndent(-1), { title: "Decrease Indent" }),
            this.small("indentMore", null, () => c.changeIndent(1), { title: "Increase Indent" }),
            this.small("merge", "Merge & Center", () => void c.merge("mergeAndCenter"), { isOn: () => c.selectionIsMerged, menu: () => this.mergeMenu() }),
          ],
        ),
      ),
      this.group("Number",
        this.stack(
          [this.select("rb-format", NUMBER_PRESETS, () => numberFormatOf(style()), (v) => c.setNumberFormat(v), "Number Format")],
          [
            this.small("currency", null, () => c.setNumberFormat(CODES.accounting), { title: "Accounting Number Format", menu: () => this.currencyMenu() }),
            this.small("percent", null, () => c.setNumberFormat("0%"), { title: "Percent Style (Ctrl+Shift+%)" }),
            this.small(null, null, () => c.setNumberFormat("#,##0.00"), { title: "Comma Style", text: "," }),
            this.small("decimalMore", null, () => c.adjustDecimals(1), { title: "Increase Decimal" }),
            this.small("decimalLess", null, () => c.adjustDecimals(-1), { title: "Decrease Decimal" }),
          ],
        ),
      ),
      this.group("Styles",
        this.large("conditional", "Conditional Formatting", null, { menu: () => this.conditionalMenu() }),
        this.large("table", "Format as Table", null, { menu: () => this.tableMenu() }),
        this.large("styles", "Cell Styles", null, { menu: () => this.cellStylesMenu() }),
      ),
      this.group("Cells",
        this.large("insertCells", "Insert", () => c.insertForSelection(), { menu: () => this.insertMenu() }),
        this.large("deleteCells", "Delete", () => c.deleteForSelection(), { menu: () => this.deleteMenu() }),
        this.large("format", "Format", null, { menu: () => this.formatMenu() }),
      ),
      this.group("Editing",
        this.stack(
          [this.small("sum", "AutoSum", () => c.autoSum(), { menu: () => this.autoSumMenu(), title: "AutoSum (Alt+=)" })],
          [this.small("fillDown", "Fill", null, { menu: () => [
            { label: "Down", shortcut: "Ctrl+D", action: () => c.fill(true) },
            { label: "Right", shortcut: "Ctrl+R", action: () => c.fill(false) },
            { label: "Series…", action: () => a.fillSeries() },
          ] })],
          [this.small("eraser", "Clear", null, { menu: () => [
            { label: "Clear All", action: () => c.clearAll() },
            { label: "Clear Formats", action: () => c.clearFormats() },
            { label: "Clear Contents", action: () => c.clearContents() },
            { label: "Clear Notes", action: () => c.clearNotes() },
            { label: "Clear Hyperlinks", action: () => c.clearHyperlinks() },
          ] })],
        ),
        this.large("sortFilter", "Sort & Filter", null, { menu: () => this.sortFilterMenu() }),
        this.large("find", "Find & Select", null, { menu: () => this.findMenu() }),
      ),
    ];
  }

  private insert(): HTMLElement[] {
    const c = this.c, a = this.actions;
    return [
      this.group("Tables", this.large("table", "Table", () => c.formatAsTable("green"), { title: "Format the data around the selection as a table" })),
      this.group("Charts",
        this.large("chartColumn", "Column", () => c.insertChart("column"), { menu: () => this.chartMenu(["column", "stackedColumn"]) }),
        this.large("chartBar", "Bar", () => c.insertChart("bar")),
        this.large("chartLine", "Line", () => c.insertChart("line")),
        this.large("chartArea", "Area", () => c.insertChart("area")),
        this.large("chartPie", "Pie", () => c.insertChart("pie"), { menu: () => this.chartMenu(["pie", "doughnut"]) }),
        this.large("chartScatter", "Scatter", () => c.insertChart("scatter")),
      ),
      this.group("Links & Notes",
        this.large("link", "Link", () => a.insertLink(), { title: "Insert a hyperlink (Ctrl+K)" }),
        this.large("note", "Note", () => a.editNote(), { title: "Add a note to the cell (Shift+F2)" }),
      ),
      this.group("Text",
        this.stack(
          [this.small("calendar", "Date", () => c.insertCurrentDate(), { title: "Insert today's date (Ctrl+;)" })],
          [this.small("clock", "Time", () => c.insertCurrentTime(), { title: "Insert the current time (Ctrl+Shift+;)" })],
        ),
        this.large("function", "Function", () => a.insertFunction()),
      ),
    ];
  }

  private pageLayout(): HTMLElement[] {
    const c = this.c, a = this.actions;
    const setup = () => c.sheet.pageSetup;
    const update = (change: Partial<ReturnType<typeof setup>>) => c.updatePageSetup({ ...setup(), ...change });
    return [
      this.group("Page Setup",
        this.large("margins", "Margins", null, { menu: () => ([["Normal", 54], ["Wide", 72], ["Narrow", 36], ["None", 18]] as const)
          .map(([label, margin]) => ({ label, checked: setup().margin === margin, action: () => update({ margin }) })) }),
        this.large(setup().orientation === "portrait" ? "portrait" : "landscape", "Orientation", null, { menu: () => [
          { label: "Portrait", checked: setup().orientation === "portrait", action: () => update({ orientation: "portrait" }) },
          { label: "Landscape", checked: setup().orientation === "landscape", action: () => update({ orientation: "landscape" }) },
        ] }),
        this.large("printArea", "Print Area", null, { menu: () => [
          { label: "Set Print Area", action: () => c.setPrintArea() },
          { label: "Clear Print Area", enabled: !!setup().printArea, action: () => c.clearPrintArea() },
        ] }),
        this.large("pageSetup", "Page Setup", () => a.pageSetup()),
      ),
      this.group("Scale to Fit",
        this.stack(
          [this.small("actualSize", "Actual Size", () => update({ scaling: "actual" }), { isOn: () => setup().scaling === "actual" })],
          [this.small("fit", "Fit All Columns on One Page", () => update({ scaling: "fitWidth" }), { isOn: () => setup().scaling === "fitWidth" })],
          [this.small("zoomSelection", "Fit Sheet on One Page", () => update({ scaling: "fitPage" }), { isOn: () => setup().scaling === "fitPage" })],
        ),
      ),
      this.group("Sheet Options",
        this.stack(
          [this.small("gridlines", "View Gridlines", () => c.toggleGridlines(), { isOn: () => c.sheet.showGridlines })],
          [this.small("gridlines", "Print Gridlines", () => update({ printGridlines: !setup().printGridlines }), { isOn: () => setup().printGridlines })],
          [this.small("headings", "Print Headings", () => update({ printHeadings: !setup().printHeadings }), { isOn: () => setup().printHeadings })],
        ),
        this.large("print", "Print", () => a.print()),
      ),
    ];
  }

  private formulas(): HTMLElement[] {
    const c = this.c, a = this.actions;
    const cat = (category: FunctionCategory) => () => this.functionMenu([category]);
    return [
      this.group("Function Library",
        this.large("function", "Insert Function", () => a.insertFunction()),
        this.large("sum", "AutoSum", () => c.autoSum(), { menu: () => this.autoSumMenu() }),
        this.large("currency", "Financial", null, { menu: cat("Financial") }),
        this.large("check", "Logical", null, { menu: cat("Logical") }),
        this.large("format", "Text", null, { menu: cat("Text") }),
        this.large("calendar", "Date & Time", null, { menu: cat("Date & Time") }),
        this.large("find", "Lookup", null, { menu: cat("Lookup & Reference") }),
        this.large("function", "Math & Trig", null, { menu: cat("Math & Trig") }),
        this.large("more", "More", null, { menu: () => this.functionMenu(FUNCTION_CATEGORIES.filter((x) => x === "Statistical" || x === "Information")) }),
      ),
      this.group("Defined Names",
        this.large("names", "Name Manager", () => a.nameManager()),
        this.stack(
          [this.small("plus", "Define Name", () => a.defineName())],
          [this.small("format", "Use in Formula", null, { menu: () => {
            const names = c.workbook.names;
            if (!names.length) return [{ label: "No names defined", enabled: false }];
            return names.map((n) => ({ label: n.name, action: () => {
              if (c.isEditing) document.dispatchEvent(new CustomEvent("wg-insert-text", { detail: n.name }));
              else c.beginEditingHandler?.(`=${n.name}`);
            } }));
          } })],
        ),
      ),
      this.group("Calculation",
        this.large("eye", "Show Formulas", () => c.toggleShowFormulas(), { isOn: () => c.showFormulas, title: "Show Formulas (Ctrl+`)" }),
        this.large("refresh", "Calculate Now", () => c.recalculate(), { title: "Calculate Now (F9)" }),
      ),
    ];
  }

  private data(): HTMLElement[] {
    const c = this.c, a = this.actions;
    return [
      this.group("Get Data", this.large("csv", "From Text/CSV", () => a.importText())),
      this.group("Sort & Filter",
        this.stack(
          [this.small("sortAsc", "A → Z", () => c.quickSort(true))],
          [this.small("sortDesc", "Z → A", () => c.quickSort(false))],
        ),
        this.large("sort", "Sort", () => a.customSort()),
        this.large("filter", "Filter", () => c.toggleFilter(), { isOn: () => !!c.sheet.filter }),
        this.stack(
          [this.small("eraser", "Clear", () => c.clearFilters(), { enabled: () => !!c.sheet.filter?.criteria.size })],
          [this.small("refresh", "Reapply", () => c.reapplyFilter(), { enabled: () => !!c.sheet.filter })],
        ),
      ),
      this.group("Data Tools",
        this.large("textColumns", "Text to Columns", () => a.textToColumns()),
        this.large("dedupe", "Remove Duplicates", () => c.removeDuplicates()),
      ),
    ];
  }

  private review(): HTMLElement[] {
    const c = this.c, a = this.actions;
    const jump = (forward: boolean) => () => {
      const keys = [...c.sheet.notes.keys()].sort((x, y) => x - y);
      if (!keys.length) return;
      const current = c.selection.active.row * 16384 + c.selection.active.column;
      const next = forward ? keys.find((k) => k > current) ?? keys[0] : [...keys].reverse().find((k) => k < current) ?? keys[keys.length - 1];
      c.select({ row: Math.floor(next / 16384), column: next % 16384 });
    };
    return [
      this.group("Notes",
        this.large("note", "Note", () => a.editNote(), { title: "New or edit note (Shift+F2)" }),
        this.large("trash", "Delete Note", () => c.setNote(null, c.selection.active), { enabled: () => c.note(c.selection.active) !== undefined }),
        this.stack(
          [this.small("prev", "Previous", jump(false), { enabled: () => c.sheet.notes.size > 0 })],
          [this.small("next", "Next", jump(true), { enabled: () => c.sheet.notes.size > 0 })],
        ),
      ),
      this.group("Proofing", this.large("stats", "Workbook Statistics", () => a.statistics())),
    ];
  }

  private view(): HTMLElement[] {
    const c = this.c;
    return [
      this.group("Show",
        this.stack(
          [this.small("gridlines", "Gridlines", () => c.toggleGridlines(), { isOn: () => c.sheet.showGridlines })],
          [this.small("headings", "Headings", () => c.toggleHeadings(), { isOn: () => c.sheet.showHeadings })],
          [this.small("formulas", "Formula Bar", () => document.dispatchEvent(new CustomEvent("wg-toggle-formula-bar")), { isOn: () => settings().showFormulaBar })],
        ),
      ),
      this.group("Zoom",
        this.large("zoomIn", "Zoom In", () => c.setZoom(c.sheet.zoom * 1.25)),
        this.large("zoomOut", "Zoom Out", () => c.setZoom(c.sheet.zoom / 1.25)),
        this.large("actualSize", "100%", () => c.setZoom(1)),
        this.large("zoomSelection", "Zoom to Selection", () => document.dispatchEvent(new CustomEvent("wg-zoom-selection"))),
      ),
      this.group("Window",
        this.large("freeze", "Freeze Panes", () => c.freezePanes(), { isOn: () => c.hasFrozenPanes, menu: () => [
          { label: c.hasFrozenPanes ? "Unfreeze Panes" : "Freeze Panes", action: () => c.freezePanes() },
          { label: "Freeze Top Row", action: () => c.freezeTopRow() },
          { label: "Freeze First Column", action: () => c.freezeFirstColumn() },
        ] }),
      ),
    ];
  }
}

