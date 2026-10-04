import { a1, columnName, isSingleCell, rangeA1, parseRange, type CellAddress } from "../model/address";
import {
  CHART_KINDS, CHART_KIND_TITLES, HIGHLIGHT_PRESETS, normalizeStyle, numberFormatOf,
  type BorderLineStyle, type CellStyle, type ChartObject, type ChartPalette, type ConditionalFormat,
  type HighlightFormat, type PageSetup, type Rule,
} from "../model/workbook";
import { WorkbookController, applyNamedStyleTo, type BorderPreset, type SpecialTarget } from "../engine/controller";
import { ruleSummary, ConditionalFormatter } from "../engine/conditional";
import { primaryRange } from "../engine/selection";
import { FUNCTIONS, FUNCTION_CATEGORIES, POPULAR_FUNCTIONS, type FunctionCategory } from "../formula";
import { adjustingDecimals, formatValue } from "../formula/numberFormat";
import { GridGeometry } from "../grid/geometry";
import { GridRenderer } from "../grid/render";
import { currentTheme } from "../grid/theme";
import { openURL, basename } from "../platform";
import { settings, updateSettings, type EnterDirection } from "../settings";
import type { WorkbookTemplate } from "../templates";
import { APP_VERSION, platformName } from "../version";
import { NUMBER_PRESETS } from "./ribbon";
import { THEME_GRID } from "./colors";

interface DialogButton {
  label: string;
  value: string;
  primary?: boolean;
  /** Placed on the left, away from the main actions. */
  left?: boolean;
}

const dialog = () => document.getElementById("dialog") as HTMLDialogElement;
let queue: Promise<unknown> = Promise.resolve();

/** Shows a modal dialog; resolves with the clicked button's value, or null when dismissed. */
export function showDialog(title: string, body: HTMLElement | string, buttons: DialogButton[], options: { onOpen?: (root: HTMLElement) => void; width?: "wide" | "xwide" } = {}): Promise<string | null> {
  const run = () => new Promise<string | null>((resolve) => {
    const el = dialog();
    el.replaceChildren();
    el.className = options.width ?? "";
    const content = document.createElement("form");
    content.method = "dialog";
    const main = document.createElement("div");
    main.className = "dialog-body";
    const heading = document.createElement("h2");
    heading.textContent = title;
    main.append(heading);
    if (typeof body === "string") {
      const p = document.createElement("p");
      p.textContent = body;
      main.append(p);
    } else {
      main.append(body);
    }
    const actions = document.createElement("div");
    actions.className = "dialog-actions";
    for (const b of buttons) {
      const button = document.createElement("button");
      button.textContent = b.label;
      button.value = b.value;
      if (b.primary) button.className = "primary";
      if (b.left) button.classList.add("left");
      actions.append(button);
    }
    content.append(main, actions);
    el.append(content);
    el.onclose = () => resolve(el.returnValue && el.returnValue !== "cancel" ? el.returnValue : null);
    el.returnValue = "";
    // Enter submits with the primary button.
    content.addEventListener("submit", (event) => {
      const submitter = (event as SubmitEvent).submitter as HTMLButtonElement | null;
      if (!submitter) {
        event.preventDefault();
        el.close(buttons.find((b) => b.primary)?.value ?? "");
      }
    });
    el.showModal();
    options.onOpen?.(main);
  });
  const next = queue.then(run, run);
  queue = next.catch(() => undefined);
  return next;
}

export const html = (markup: string) => {
  const div = document.createElement("div");
  div.innerHTML = markup;
  return div;
};

export const escape = (text: string) => text.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

const OK_CANCEL = (ok = "OK"): DialogButton[] => [{ label: "Cancel", value: "cancel" }, { label: ok, value: "ok", primary: true }];
const q = <T extends HTMLElement>(root: HTMLElement, selector: string) => root.querySelector<T>(selector)!;
const focusFirst = (selector: string) => (root: HTMLElement) => {
  const el = root.querySelector<HTMLInputElement>(selector);
  el?.focus();
  el?.select?.();
};

export async function alertDialog(message: string, info?: string) {
  const body = html(info ? `<p>${escape(info)}</p>` : "");
  await showDialog(message, body, [{ label: "OK", value: "ok", primary: true }]);
}

export async function confirmDialog(message: string, info: string, ok: string): Promise<boolean> {
  const body = html(info ? `<p>${escape(info)}</p>` : "");
  return (await showDialog(message, body, OK_CANCEL(ok))) === "ok";
}

export async function promptNumber(title: string, label: string, value: number): Promise<number | null> {
  const body = html(`<div class="field"><label for="p-num">${escape(label)}</label><input id="p-num" type="number" step="any" value="${Math.round(value * 100) / 100}"></div>`);
  if ((await showDialog(title, body, OK_CANCEL(), { onOpen: focusFirst("#p-num") })) !== "ok") return null;
  const n = Number(q<HTMLInputElement>(body, "#p-num").value);
  return Number.isFinite(n) ? n : null;
}

export async function promptText(title: string, label: string, value = "", placeholder = ""): Promise<string | null> {
  const body = html(`<div class="field"><label for="p-text">${escape(label)}</label><input id="p-text" type="text" value="${escape(value)}" placeholder="${escape(placeholder)}" spellcheck="false"></div>`);
  if ((await showDialog(title, body, OK_CANCEL(), { onOpen: focusFirst("#p-text") })) !== "ok") return null;
  return q<HTMLInputElement>(body, "#p-text").value;
}

// MARK: Format Cells

type FormatTab = "number" | "alignment" | "font" | "border" | "fill";

const swatchGrid = (name: string, current: string | undefined, clearLabel: string) => {
  const colors = THEME_GRID.flat();
  return `<div class="swatches" data-name="${name}">
    <button type="button" data-color="" class="no-color ${current ? "" : "selected"}">${clearLabel}</button>
    ${colors.map((c) => `<button type="button" data-color="${c}" title="${c}" style="background:${c}" class="${current === c ? "selected" : ""}"></button>`).join("")}
  </div>`;
};

export async function formatCellsDialog(c: WorkbookController, initialTab: FormatTab = "number"): Promise<void> {
  const original = c.activeStyle;
  let style: CellStyle = { ...original };
  let tab: FormatTab = initialTab;
  let borderPreset: BorderPreset | null = null;
  const sample = c.value(c.selection.active);
  const sampleNumber = typeof sample === "number" ? sample : 1234.5678;

  const body = html(`
    <div class="segmented">${(["number", "alignment", "font", "border", "fill"] as FormatTab[]).map((t) => `<button type="button" data-tab="${t}">${t[0].toUpperCase() + t.slice(1)}</button>`).join("")}</div>
    <div class="tab-content"></div>`);
  const content = q<HTMLDivElement>(body, ".tab-content");

  const renderTab = () => {
    body.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach((b) => b.classList.toggle("selected", b.dataset.tab === tab));
    const code = numberFormatOf(style);
    switch (tab) {
      case "number":
        content.innerHTML = `
          <div class="field"><label>Category</label><select id="fc-preset">${NUMBER_PRESETS.map(([label, value]) => `<option value="${escape(value)}" ${value === code ? "selected" : ""}>${label}</option>`).join("")}<option value="__custom" ${NUMBER_PRESETS.some(([, v]) => v === code) ? "" : "selected"}>Custom</option></select></div>
          <div class="field"><label for="fc-code">Format code</label><input id="fc-code" type="text" value="${escape(code)}" spellcheck="false"></div>
          <div class="field"><label>Decimal places</label><div class="field-row"><button type="button" id="fc-less">−</button><button type="button" id="fc-more">+</button><label class="check"><input id="fc-thousands" type="checkbox" ${code.includes("#,##") ? "checked" : ""}> Use 1000 separator (,)</label></div></div>
          <div class="section-title">Sample</div>
          <div class="preview-box" id="fc-sample"></div>
          <p class="note">Codes like <code>#,##0.00</code> · <code>0%</code> · <code>$#,##0;[Red]-$#,##0</code> · <code>yyyy-mm-dd</code> · <code>h:mm AM/PM</code></p>`;
        {
          const codeInput = q<HTMLInputElement>(content, "#fc-code");
          const update = () => {
            style.numberFormat = codeInput.value || "General";
            const formatted = formatValue(typeof sample === "string" || sample === null ? sampleNumber : sample, style.numberFormat);
            const el = q<HTMLDivElement>(content, "#fc-sample");
            el.textContent = formatted.text || " ";
            el.style.color = formatted.color ?? "";
          };
          q<HTMLSelectElement>(content, "#fc-preset").addEventListener("change", (e) => {
            const v = (e.target as HTMLSelectElement).value;
            if (v !== "__custom") codeInput.value = v;
            update();
          });
          codeInput.addEventListener("input", update);
          const adjust = (delta: number) => {
            codeInput.value = adjustCode(codeInput.value, delta, sampleNumber);
            update();
          };
          q(content, "#fc-less").addEventListener("click", () => adjust(-1));
          q(content, "#fc-more").addEventListener("click", () => adjust(1));
          q<HTMLInputElement>(content, "#fc-thousands").addEventListener("change", (e) => {
            const on = (e.target as HTMLInputElement).checked;
            let v = codeInput.value === "General" ? "0" : codeInput.value;
            v = on ? v.replace(/(^|[^#,])0(?!,)/, "$1#,##0") : v.replace(/#,##0/g, "0");
            codeInput.value = v;
            update();
          });
          update();
        }
        break;
      case "alignment":
        content.innerHTML = `
          <div class="field"><label>Horizontal</label><select id="fc-h">${[["general", "General"], ["left", "Left"], ["center", "Center"], ["right", "Right"], ["fill", "Fill"], ["justify", "Justify"], ["centerAcross", "Center Across Selection"]].map(([v, l]) => `<option value="${v}" ${(style.horizontal ?? "general") === v ? "selected" : ""}>${l}</option>`).join("")}</select></div>
          <div class="field"><label>Vertical</label><select id="fc-v">${[["top", "Top"], ["middle", "Center"], ["bottom", "Bottom"]].map(([v, l]) => `<option value="${v}" ${(style.vertical ?? "bottom") === v ? "selected" : ""}>${l}</option>`).join("")}</select></div>
          <div class="field"><label for="fc-indent">Indent</label><input id="fc-indent" type="number" min="0" max="15" value="${style.indent ?? 0}"></div>
          <div class="field"><label>Orientation</label><select id="fc-rot">${[[0, "Horizontal"], [45, "45° up"], [-45, "45° down"], [90, "90° up"], [-90, "90° down"]].map(([v, l]) => `<option value="${v}" ${(style.rotation ?? 0) === v ? "selected" : ""}>${l}</option>`).join("")}</select></div>
          <label class="toggle"><input id="fc-wrap" type="checkbox" ${style.wrap ? "checked" : ""}> Wrap text</label>
          <label class="toggle"><input id="fc-shrink" type="checkbox" ${style.shrinkToFit ? "checked" : ""}> Shrink to fit</label>
          <label class="toggle"><input id="fc-merge" type="checkbox" ${c.selectionIsMerged ? "checked" : ""}> Merge cells</label>`;
        content.addEventListener("change", () => {
          style.horizontal = q<HTMLSelectElement>(content, "#fc-h")?.value as CellStyle["horizontal"];
          style.vertical = q<HTMLSelectElement>(content, "#fc-v")?.value as CellStyle["vertical"];
          style.indent = Math.max(0, Math.min(15, Number(q<HTMLInputElement>(content, "#fc-indent")?.value) || 0));
          style.rotation = Number(q<HTMLSelectElement>(content, "#fc-rot")?.value) || 0;
          style.wrap = q<HTMLInputElement>(content, "#fc-wrap")?.checked;
          style.shrinkToFit = q<HTMLInputElement>(content, "#fc-shrink")?.checked;
        }, { once: false });
        break;
      case "font":
        content.innerHTML = `
          <div class="field"><label for="fc-font">Font</label><input id="fc-font" type="text" value="${escape(style.fontName ?? settings().defaultFontName)}" spellcheck="false"></div>
          <div class="field"><label for="fc-size">Size</label><input id="fc-size" type="number" min="1" max="409" value="${style.fontSize ?? settings().defaultFontSize}"></div>
          <div class="columns-2"><div>
            <label class="toggle"><input id="fc-bold" type="checkbox" ${style.bold ? "checked" : ""}> Bold</label>
            <label class="toggle"><input id="fc-italic" type="checkbox" ${style.italic ? "checked" : ""}> Italic</label>
            <label class="toggle"><input id="fc-strike" type="checkbox" ${style.strikethrough ? "checked" : ""}> Strikethrough</label>
          </div><div>
            <label class="toggle"><input id="fc-under" type="checkbox" ${style.underline ? "checked" : ""}> Underline</label>
            <label class="toggle"><input id="fc-dunder" type="checkbox" ${style.doubleUnderline ? "checked" : ""}> Double underline</label>
          </div></div>
          <div class="section-title">Color</div>
          ${swatchGrid("text", style.textColor, "Automatic")}`;
        content.addEventListener("change", () => {
          const font = q<HTMLInputElement>(content, "#fc-font")?.value.trim();
          if (font !== undefined) style.fontName = font && font !== settings().defaultFontName ? font : undefined;
          const size = Number(q<HTMLInputElement>(content, "#fc-size")?.value);
          if (size > 0) style.fontSize = size === settings().defaultFontSize ? undefined : Math.min(size, 409);
          style.bold = q<HTMLInputElement>(content, "#fc-bold")?.checked;
          style.italic = q<HTMLInputElement>(content, "#fc-italic")?.checked;
          style.strikethrough = q<HTMLInputElement>(content, "#fc-strike")?.checked;
          style.underline = q<HTMLInputElement>(content, "#fc-under")?.checked;
          style.doubleUnderline = q<HTMLInputElement>(content, "#fc-dunder")?.checked;
        });
        break;
      case "border":
        content.innerHTML = `
          <div class="field"><label>Line style</label><select id="fc-line">${(["thin", "medium", "thick", "dashed", "dotted", "double", "hair"] as BorderLineStyle[]).map((s) => `<option value="${s}">${s[0].toUpperCase() + s.slice(1)}</option>`).join("")}</select></div>
          <div class="field"><label>Line color</label><input id="fc-line-color" type="color" value="#000000"></div>
          <div class="section-title">Presets</div>
          <div class="border-grid">${([["none", "None"], ["outside", "Outline"], ["all", "All"], ["insideHorizontal", "Inside Horizontal"], ["insideVertical", "Inside Vertical"], ["top", "Top"], ["bottom", "Bottom"], ["left", "Left"], ["right", "Right"], ["thickOutside", "Thick Outline"], ["doubleBottom", "Double Bottom"], ["topAndBottom", "Top and Bottom"]] as [BorderPreset, string][]).map(([p, l]) => `<button type="button" data-preset="${p}">${l}</button>`).join("")}</div>
          <p class="note" id="fc-border-note">The chosen preset is applied to the selection when you click OK.</p>`;
        content.querySelectorAll<HTMLButtonElement>("[data-preset]").forEach((b) => b.addEventListener("click", () => {
          borderPreset = b.dataset.preset as BorderPreset;
          content.querySelectorAll("[data-preset]").forEach((x) => (x as HTMLElement).style.borderColor = "");
          b.style.borderColor = "var(--accent)";
          q(content, "#fc-border-note").textContent = `${b.textContent} will be applied when you click OK.`;
        }));
        break;
      case "fill":
        content.innerHTML = `<div class="section-title">Background color</div>${swatchGrid("fill", style.fillColor, "No Fill")}
          <div class="section-title">Cell styles</div>
          <div class="border-grid">${(["good", "bad", "neutral", "title", "heading1", "heading2", "total", "input", "output", "calculation", "note", "accent"] as const).map((s) => `<button type="button" data-named="${s}">${s[0].toUpperCase() + s.slice(1).replace(/(\d)/, " $1")}</button>`).join("")}</div>`;
        content.querySelectorAll<HTMLButtonElement>("[data-named]").forEach((b) => b.addEventListener("click", () => {
          style = applyNamedStyleTo(b.dataset.named as never, style);
          renderTab();
        }));
        break;
    }
    content.querySelectorAll<HTMLElement>(".swatches").forEach((grid) => grid.addEventListener("click", (e) => {
      const button = (e.target as HTMLElement).closest<HTMLButtonElement>("button[data-color]");
      if (!button) return;
      grid.querySelectorAll("button").forEach((b) => b.classList.remove("selected"));
      button.classList.add("selected");
      const color = button.dataset.color || undefined;
      if (grid.dataset.name === "fill") style.fillColor = color;
      else style.textColor = color;
    }));
  };
  body.querySelectorAll<HTMLButtonElement>("[data-tab]").forEach((b) => b.addEventListener("click", () => {
    tab = b.dataset.tab as FormatTab;
    renderTab();
  }));
  renderTab();

  if ((await showDialog("Format Cells", body, OK_CANCEL(), { width: "wide" })) !== "ok") return;
  const merged = q<HTMLInputElement>(body, "#fc-merge");
  const changes = diffStyle(original, normalizeStyle(style));
  if (Object.keys(changes).length) c.applyStyle("Format Cells", (s) => ({ ...s, ...changes }), true);
  if (borderPreset) {
    const lineStyle = (body.querySelector<HTMLSelectElement>("#fc-line")?.value ?? "thin") as BorderLineStyle;
    const color = (body.querySelector<HTMLInputElement>("#fc-line-color")?.value ?? "#000000").toUpperCase();
    c.applyBorders(borderPreset, { style: lineStyle, color });
  }
  if (merged && merged.checked !== c.selectionIsMerged) await c.merge(merged.checked ? "merge" : "unmerge");
}

/** The fields the dialog changed, so other cells in the selection keep their own formatting. */
function diffStyle(before: CellStyle, after: CellStyle): Partial<CellStyle> {
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]) as Set<keyof CellStyle>;
  const changes: Record<string, unknown> = {};
  for (const key of keys) {
    if (JSON.stringify(before[key]) !== JSON.stringify(after[key])) changes[key] = after[key];
  }
  return changes as Partial<CellStyle>;
}

const adjustCode = (code: string, delta: number, sample: number) => adjustingDecimals(code, delta, sample);

// MARK: Sort

export async function sortDialog(c: WorkbookController): Promise<void> {
  const r = c.dataRangeForCommand;
  const header = c.looksLikeHeader(r);
  const columns: { index: number; label: (hasHeader: boolean) => string }[] = [];
  for (let col = r.start.column; col <= r.end.column; col++) {
    columns.push({ index: col, label: (h) => (h ? `${formatValue(c.value({ row: r.start.row, column: col }), "General").text || "Column " + columnName(col)}` : `Column ${columnName(col)}`) });
  }
  const body = html(`
    <p class="note">Sorting ${escape(rangeA1(r))}.</p>
    <label class="toggle"><input id="s-header" type="checkbox" ${header ? "checked" : ""}> My data has headers</label>
    <div id="s-levels"></div>
    <button type="button" id="s-add">Add Level</button>`);
  const levels = q<HTMLDivElement>(body, "#s-levels");
  const keys: { column: number; ascending: boolean }[] = [{ column: c.selection.active.column >= r.start.column && c.selection.active.column <= r.end.column ? c.selection.active.column : r.start.column, ascending: true }];
  const render = () => {
    const h = q<HTMLInputElement>(body, "#s-header").checked;
    levels.innerHTML = keys.map((k, i) => `
      <div class="field"><label>${i === 0 ? "Sort by" : "Then by"}</label><div class="field-row">
        <select data-i="${i}" data-kind="column">${columns.map((col) => `<option value="${col.index}" ${col.index === k.column ? "selected" : ""}>${escape(col.label(h))}</option>`).join("")}</select>
        <select data-i="${i}" data-kind="order"><option value="1" ${k.ascending ? "selected" : ""}>A → Z</option><option value="0" ${k.ascending ? "" : "selected"}>Z → A</option></select>
        ${i > 0 ? `<button type="button" data-remove="${i}">−</button>` : ""}
      </div></div>`).join("");
  };
  levels.addEventListener("change", (e) => {
    const el = e.target as HTMLSelectElement;
    const i = Number(el.dataset.i);
    if (el.dataset.kind === "column") keys[i].column = Number(el.value);
    else keys[i].ascending = el.value === "1";
  });
  levels.addEventListener("click", (e) => {
    const remove = (e.target as HTMLElement).dataset.remove;
    if (remove !== undefined) { keys.splice(Number(remove), 1); render(); }
  });
  q(body, "#s-add").addEventListener("click", () => { if (keys.length < 6) keys.push({ column: r.start.column, ascending: true }); render(); });
  q(body, "#s-header").addEventListener("change", render);
  render();
  if ((await showDialog("Sort", body, OK_CANCEL("Sort"))) !== "ok") return;
  c.sort(r, keys, q<HTMLInputElement>(body, "#s-header").checked);
}

// MARK: Conditional formatting

const RULE_KINDS: [Rule["type"], string][] = [
  ["greaterThan", "Cell value greater than"], ["lessThan", "Cell value less than"], ["between", "Cell value between"],
  ["equalTo", "Cell value equal to"], ["notEqualTo", "Cell value not equal to"], ["textContains", "Text that contains"],
  ["beginsWith", "Text that begins with"], ["endsWith", "Text that ends with"], ["blanks", "Blank cells"], ["noBlanks", "Cells that aren't blank"],
  ["duplicates", "Duplicate values"], ["uniques", "Unique values"], ["top", "Top N"], ["bottom", "Bottom N"],
  ["aboveAverage", "Above average"], ["belowAverage", "Below average"], ["formula", "Use a formula"],
  ["colorScale", "Color scale"], ["dataBar", "Data bar"], ["iconSet", "Icon set"],
];

export async function conditionalFormatDialog(c: WorkbookController, initial?: Rule["type"], existing?: ConditionalFormat): Promise<void> {
  const rule = existing?.rule;
  const kind = existing?.rule.type ?? initial ?? "greaterThan";
  const presetIndex = existing ? HIGHLIGHT_PRESETS.findIndex(([, f]) => JSON.stringify(f) === JSON.stringify(existing.format)) : 0;
  const v = (key: string): string => {
    if (!rule) return "";
    const r = rule as unknown as Record<string, unknown>;
    if (key === "formula" && r.formula) return "=" + String(r.formula);
    return r[key] === undefined ? "" : String(r[key]);
  };
  const body = html(`
    <div class="field"><label for="cf-range">Applies to</label><input id="cf-range" type="text" value="${escape(rangeA1(existing?.range ?? c.boundedToContent(primaryRange(c.selection))))}"></div>
    <div class="field"><label for="cf-kind">Rule</label><select id="cf-kind">${RULE_KINDS.map(([k, l]) => `<option value="${k}" ${k === kind ? "selected" : ""}>${l}</option>`).join("")}</select></div>
    <div class="field" id="cf-a-row"><label for="cf-a" id="cf-a-label">Value</label><input id="cf-a" type="text" value="${escape(v("value") || v("low") || v("text") || v("count") || v("formula"))}"></div>
    <div class="field" id="cf-b-row"><label for="cf-b">And</label><input id="cf-b" type="text" value="${escape(v("high"))}"></div>
    <label class="toggle" id="cf-percent-row"><input id="cf-percent" type="checkbox" ${rule?.type === "top" || rule?.type === "bottom" ? (rule.percent ? "checked" : "") : ""}> Percent</label>
    <div class="field" id="cf-format-row"><label for="cf-format">Format with</label><select id="cf-format">${HIGHLIGHT_PRESETS.map(([l], i) => `<option value="${i}" ${i === Math.max(presetIndex, 0) ? "selected" : ""}>${l}</option>`).join("")}</select></div>
    <div class="field" id="cf-scale-row"><label for="cf-scale">Colors</label><select id="cf-scale">
      <option value="#63BE7B,#FFEB84,#F8696B">Green – Yellow – Red</option><option value="#F8696B,#FFEB84,#63BE7B">Red – Yellow – Green</option>
      <option value="#FFFFFF,#63BE7B">White – Green</option><option value="#FFFFFF,#5A8AC6">White – Blue</option></select></div>
    <div class="field" id="cf-bar-row"><label for="cf-bar">Bar color</label><input id="cf-bar" type="color" value="${rule?.type === "dataBar" ? rule.color : "#63BE7B"}"></div>
    <div class="field" id="cf-icons-row"><label for="cf-icons">Icons</label><select id="cf-icons"><option value="arrows">3 Arrows</option><option value="trafficLights">3 Traffic Lights</option><option value="flags">3 Flags</option><option value="stars">3 Stars</option></select></div>`);
  const kindSelect = q<HTMLSelectElement>(body, "#cf-kind");
  if (rule?.type === "iconSet") q<HTMLSelectElement>(body, "#cf-icons").value = rule.set;
  const sync = () => {
    const k = kindSelect.value as Rule["type"];
    const needsA = ["greaterThan", "lessThan", "between", "equalTo", "notEqualTo", "textContains", "beginsWith", "endsWith", "top", "bottom", "formula"].includes(k);
    q(body, "#cf-a-row").hidden = !needsA;
    q(body, "#cf-a-label").textContent = k === "formula" ? "Formula" : k === "top" || k === "bottom" ? "Count" : k === "between" ? "Between" : "Value";
    q(body, "#cf-b-row").hidden = k !== "between";
    q(body, "#cf-percent-row").hidden = !(k === "top" || k === "bottom");
    q(body, "#cf-format-row").hidden = ["colorScale", "dataBar", "iconSet"].includes(k);
    q(body, "#cf-scale-row").hidden = k !== "colorScale";
    q(body, "#cf-bar-row").hidden = k !== "dataBar";
    q(body, "#cf-icons-row").hidden = k !== "iconSet";
  };
  kindSelect.addEventListener("change", sync);
  sync();
  if ((await showDialog(existing ? "Edit Formatting Rule" : "New Formatting Rule", body, OK_CANCEL(), { onOpen: focusFirst("#cf-a") })) !== "ok") return;
  const r = parseRange(q<HTMLInputElement>(body, "#cf-range").value.trim());
  if (!r) {
    await alertDialog("The range isn't valid.");
    return;
  }
  const k = kindSelect.value as Rule["type"];
  const a = q<HTMLInputElement>(body, "#cf-a").value.trim(), b = q<HTMLInputElement>(body, "#cf-b").value.trim();
  const num = (s: string) => (s !== "" && Number.isFinite(Number(s)) ? Number(s) : null);
  let built: Rule | null = null;
  switch (k) {
    case "greaterThan": case "lessThan": built = num(a) !== null ? { type: k, value: num(a)! } : null; break;
    case "between": built = num(a) !== null && num(b) !== null ? { type: k, low: num(a)!, high: num(b)! } : null; break;
    case "equalTo": case "notEqualTo": case "textContains": case "beginsWith": case "endsWith": built = { type: k, text: a }; break;
    case "top": case "bottom": built = { type: k, count: Math.max(1, Math.trunc(num(a) ?? 10)), percent: q<HTMLInputElement>(body, "#cf-percent").checked }; break;
    case "formula": {
      try {
        built = { type: k, formula: WorkbookController.normalizeFormula(a.replace(/^=/, "")) };
      } catch {
        built = null;
      }
      break;
    }
    case "colorScale": built = { type: k, colors: q<HTMLSelectElement>(body, "#cf-scale").value.split(",") }; break;
    case "dataBar": built = { type: k, color: q<HTMLInputElement>(body, "#cf-bar").value.toUpperCase() }; break;
    case "iconSet": built = { type: k, set: q<HTMLSelectElement>(body, "#cf-icons").value as "arrows" }; break;
    default: built = { type: k } as Rule;
  }
  if (!built) {
    await alertDialog("Enter a valid value for the rule.");
    return;
  }
  const format: HighlightFormat = HIGHLIGHT_PRESETS[Number(q<HTMLSelectElement>(body, "#cf-format").value)]?.[1] ?? HIGHLIGHT_PRESETS[0][1];
  if (existing) c.updateConditionalFormat({ ...existing, range: r, rule: built, format });
  else c.addConditionalFormat(built, format, r);
}

export async function manageRulesDialog(c: WorkbookController): Promise<void> {
  let selected = 0;
  const body = html(`<div class="list-box" id="mr-list"></div>
    <div class="field-row" style="margin-top:10px"><button type="button" id="mr-new">New Rule…</button><button type="button" id="mr-edit">Edit…</button><button type="button" id="mr-delete">Delete</button></div>`);
  const list = q<HTMLDivElement>(body, "#mr-list");
  const render = () => {
    const rules = c.sheet.conditionalFormats;
    list.innerHTML = rules.length ? rules.map((cf, i) => `<div class="item ${i === selected ? "selected" : ""}" data-i="${i}"><span class="grow">${escape(ruleSummary(cf.rule))}</span><span class="muted">${escape(rangeA1(cf.range))}</span></div>`).join("") : '<div class="empty">No rules on this sheet.</div>';
  };
  list.addEventListener("click", (e) => {
    const item = (e.target as HTMLElement).closest<HTMLElement>("[data-i]");
    if (item) { selected = Number(item.dataset.i); render(); }
  });
  const reopen = async (action: () => Promise<void>) => {
    dialog().close("cancel");
    await action();
    await manageRulesDialog(c);
  };
  q(body, "#mr-new").addEventListener("click", () => reopen(() => conditionalFormatDialog(c)));
  q(body, "#mr-edit").addEventListener("click", () => {
    const cf = c.sheet.conditionalFormats[selected];
    if (cf) reopen(() => conditionalFormatDialog(c, undefined, cf));
  });
  q(body, "#mr-delete").addEventListener("click", () => {
    const cf = c.sheet.conditionalFormats[selected];
    if (cf) { c.deleteConditionalFormat(cf.id); selected = Math.max(0, selected - 1); render(); }
  });
  render();
  await showDialog("Conditional Formatting Rules", body, [{ label: "Done", value: "ok", primary: true }], { width: "wide" });
}

// MARK: Names

export async function defineNameDialog(c: WorkbookController, existing?: { name: string; formula: string; comment: string }): Promise<boolean> {
  const reference = existing?.formula ?? `${quoted(c.sheet.name)}!${absolute(c)}`;
  const body = html(`
    <div class="field"><label for="n-name">Name</label><input id="n-name" type="text" value="${escape(existing?.name ?? "")}" spellcheck="false"></div>
    <div class="field"><label for="n-ref">Refers to</label><input id="n-ref" type="text" value="${escape("=" + reference)}" spellcheck="false"></div>
    <div class="field"><label for="n-comment">Comment</label><input id="n-comment" type="text" value="${escape(existing?.comment ?? "")}"></div>`);
  if ((await showDialog(existing ? "Edit Name" : "New Name", body, OK_CANCEL(), { onOpen: focusFirst("#n-name") })) !== "ok") return false;
  return c.defineName(q<HTMLInputElement>(body, "#n-name").value.trim(), q<HTMLInputElement>(body, "#n-ref").value, q<HTMLInputElement>(body, "#n-comment").value, existing?.name);
}

const quoted = (name: string) => (/^[\p{L}_][\p{L}\p{N}_.]*$/u.test(name) && !parseRange(name) ? name : "'" + name.replace(/'/g, "''") + "'");
function absolute(c: WorkbookController): string {
  const r = primaryRange(c.selection);
  const abs = (a: CellAddress) => "$" + columnName(a.column) + "$" + String(a.row + 1);
  return isSingleCell(r) ? abs(r.start) : abs(r.start) + ":" + abs(r.end);
}

export async function nameManagerDialog(c: WorkbookController): Promise<void> {
  let selected = 0;
  const body = html(`<div class="list-box" id="nm-list"></div>
    <div class="field-row" style="margin-top:10px"><button type="button" id="nm-new">New…</button><button type="button" id="nm-edit">Edit…</button><button type="button" id="nm-delete">Delete</button><button type="button" id="nm-go">Go To</button></div>`);
  const list = q<HTMLDivElement>(body, "#nm-list");
  const render = () => {
    const names = c.workbook.names;
    list.innerHTML = names.length ? names.map((n, i) => {
      const value = c.calculator.evaluate(n.formula, c.activeSheetIndex, c.selection.active);
      return `<div class="item ${i === selected ? "selected" : ""}" data-i="${i}"><b>${escape(n.name)}</b><span class="grow muted">=${escape(n.formula)}</span><span class="muted">${escape(formatValue(value, "General").text)}</span></div>`;
    }).join("") : '<div class="empty">No names defined. Select cells and choose New… to name them.</div>';
  };
  list.addEventListener("click", (e) => {
    const item = (e.target as HTMLElement).closest<HTMLElement>("[data-i]");
    if (item) { selected = Number(item.dataset.i); render(); }
  });
  const reopen = async (action: () => Promise<unknown>) => {
    dialog().close("cancel");
    await action();
    await nameManagerDialog(c);
  };
  q(body, "#nm-new").addEventListener("click", () => reopen(() => defineNameDialog(c)));
  q(body, "#nm-edit").addEventListener("click", () => { const n = c.workbook.names[selected]; if (n) reopen(() => defineNameDialog(c, n)); });
  q(body, "#nm-delete").addEventListener("click", () => { const n = c.workbook.names[selected]; if (n) { c.deleteName(n.name); selected = 0; render(); } });
  q(body, "#nm-go").addEventListener("click", () => { const n = c.workbook.names[selected]; if (n && c.goTo(n.name)) dialog().close("ok"); });
  render();
  await showDialog("Name Manager", body, [{ label: "Done", value: "ok", primary: true }], { width: "wide" });
}

// MARK: Go To

export async function goToDialog(c: WorkbookController): Promise<void> {
  const body = html(`
    ${c.workbook.names.length ? `<div class="list-box" id="g-names" style="max-height:140px;margin-bottom:10px">${c.workbook.names.map((n) => `<div class="item" data-name="${escape(n.name)}"><b>${escape(n.name)}</b><span class="grow muted">${escape(n.formula)}</span></div>`).join("")}</div>` : ""}
    <div class="field"><label for="g-ref">Reference</label><input id="g-ref" type="text" placeholder="B12, Sheet2!A1:C9 or a name" spellcheck="false"></div>`);
  body.querySelector("#g-names")?.addEventListener("click", (e) => {
    const item = (e.target as HTMLElement).closest<HTMLElement>("[data-name]");
    if (item) q<HTMLInputElement>(body, "#g-ref").value = item.dataset.name!;
  });
  const result = await showDialog("Go To", body, [{ label: "Special…", value: "special", left: true }, ...OK_CANCEL("Go")], { onOpen: focusFirst("#g-ref") });
  if (result === "special") return goToSpecialDialog(c);
  if (result !== "ok") return;
  const text = q<HTMLInputElement>(body, "#g-ref").value;
  if (!c.goTo(text)) await alertDialog(`“${text}” isn't a valid reference or name.`);
}

export async function goToSpecialDialog(c: WorkbookController): Promise<void> {
  const options: [SpecialTarget, string][] = [["formulas", "Formulas"], ["constants", "Constants"], ["blanks", "Blanks"], ["notes", "Notes"], ["errors", "Errors"], ["conditionalFormats", "Conditional formats"]];
  const body = html(options.map(([v, l], i) => `<label class="toggle"><input type="radio" name="gs" value="${v}" ${i === 0 ? "checked" : ""}> ${l}</label>`).join(""));
  if ((await showDialog("Go To Special", body, OK_CANCEL())) !== "ok") return;
  const value = body.querySelector<HTMLInputElement>('input[name="gs"]:checked')?.value as SpecialTarget;
  if (value) c.selectSpecial(value);
}

// MARK: Insert function

export async function insertFunctionDialog(initial?: FunctionCategory): Promise<string | null> {
  let category: string = initial ?? "Most Used";
  let selected = "";
  const body = html(`
    <input id="f-search" type="search" placeholder="Search functions" spellcheck="false" style="margin-bottom:10px">
    <div class="function-browser"><div class="list-box" id="f-cats"></div><div class="list-box" id="f-list"></div></div>
    <div class="function-detail" id="f-detail"></div>`);
  const cats = q<HTMLDivElement>(body, "#f-cats"), list = q<HTMLDivElement>(body, "#f-list"), detail = q<HTMLDivElement>(body, "#f-detail");
  const search = q<HTMLInputElement>(body, "#f-search");
  const categories = ["Most Used", "All", ...FUNCTION_CATEGORIES];
  const items = () => {
    const term = search.value.trim().toUpperCase();
    let specs = [...FUNCTIONS.values()];
    if (term) specs = specs.filter((f) => f.name.includes(term) || f.summary.toUpperCase().includes(term));
    else if (category === "Most Used") specs = POPULAR_FUNCTIONS.map((n) => FUNCTIONS.get(n)!).filter(Boolean);
    else if (category !== "All") specs = specs.filter((f) => f.category === category);
    return category === "Most Used" && !term ? specs : specs.sort((a, b) => (a.name < b.name ? -1 : 1));
  };
  const render = () => {
    cats.innerHTML = categories.map((cat) => `<div class="item ${cat === category && !search.value ? "selected" : ""}" data-cat="${escape(cat)}">${escape(cat)}</div>`).join("");
    const specs = items();
    if (!specs.some((s) => s.name === selected)) selected = specs[0]?.name ?? "";
    list.innerHTML = specs.map((s) => `<div class="item ${s.name === selected ? "selected" : ""}" data-name="${s.name}"><b>${s.name}</b></div>`).join("") || '<div class="empty">No functions match.</div>';
    const spec = FUNCTIONS.get(selected);
    detail.innerHTML = spec ? `<div class="syntax">${escape(spec.syntax)}</div><div class="note">${escape(spec.summary)}</div>` : "";
    list.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
  };
  cats.addEventListener("click", (e) => {
    const item = (e.target as HTMLElement).closest<HTMLElement>("[data-cat]");
    if (item) { category = item.dataset.cat!; search.value = ""; render(); }
  });
  list.addEventListener("click", (e) => {
    const item = (e.target as HTMLElement).closest<HTMLElement>("[data-name]");
    if (item) { selected = item.dataset.name!; render(); }
  });
  list.addEventListener("dblclick", () => dialog().close("ok"));
  search.addEventListener("input", render);
  render();
  const result = await showDialog("Insert Function", body, OK_CANCEL("Insert"), { width: "wide", onOpen: () => search.focus() });
  return result === "ok" && selected ? selected : null;
}

// MARK: Links and notes

export async function linkDialog(currentURL: string, currentText: string): Promise<{ url: string; text?: string } | "remove" | null> {
  const body = html(`
    <div class="field"><label for="l-url">Address</label><input id="l-url" type="text" placeholder="https://example.com, name@example.com or #Sheet2!A1" value="${escape(currentURL)}" spellcheck="false"></div>
    <div class="field"><label for="l-text">Text to display</label><input id="l-text" type="text" value="${escape(currentText)}"></div>`);
  const buttons: DialogButton[] = OK_CANCEL(currentURL ? "Update" : "Insert");
  if (currentURL) buttons.unshift({ label: "Remove Link", value: "remove", left: true });
  const result = await showDialog(currentURL ? "Edit Hyperlink" : "Insert Hyperlink", body, buttons, { onOpen: focusFirst("#l-url") });
  if (result === "remove") return "remove";
  if (result !== "ok") return null;
  let url = q<HTMLInputElement>(body, "#l-url").value.trim();
  if (!url) return null;
  if (!url.startsWith("#") && !/^[a-z][a-z0-9+.-]*:/i.test(url)) url = url.includes("@") && !url.includes("/") ? `mailto:${url}` : `https://${url}`;
  return { url, text: q<HTMLInputElement>(body, "#l-text").value.trim() || undefined };
}

export async function noteDialog(title: string, text: string): Promise<string | null | "delete"> {
  const body = html(`<textarea id="note-text" rows="6" spellcheck="true">${escape(text)}</textarea>`);
  const buttons = OK_CANCEL("Save");
  if (text) buttons.unshift({ label: "Delete Note", value: "delete", left: true });
  const result = await showDialog(title, body, buttons, { onOpen: () => q<HTMLTextAreaElement>(body, "#note-text").focus() });
  if (result === "delete") return "delete";
  return result === "ok" ? q<HTMLTextAreaElement>(body, "#note-text").value : null;
}

// MARK: Data tools

export async function textToColumnsDialog(): Promise<string | null> {
  const body = html(`
    <p class="note">Splits the text in the selected column into several columns.</p>
    ${[["\t", "Tab"], [",", "Comma"], [";", "Semicolon"], [" ", "Space"]].map(([v, l], i) => `<label class="toggle"><input type="radio" name="d" value="${escape(v)}" ${i === 1 ? "checked" : ""}> ${l}</label>`).join("")}
    <label class="toggle"><input type="radio" name="d" value="__other"> Other: <input id="d-other" type="text" maxlength="5" style="width:80px;height:24px"></label>`);
  if ((await showDialog("Text to Columns", body, OK_CANCEL("Split"))) !== "ok") return null;
  const value = body.querySelector<HTMLInputElement>('input[name="d"]:checked')?.value ?? ",";
  return value === "__other" ? q<HTMLInputElement>(body, "#d-other").value || null : value;
}

export async function fillSeriesDialog(): Promise<{ step: number; vertical: boolean } | null> {
  const body = html(`
    <label class="toggle"><input type="radio" name="dir" value="columns" checked> Down columns</label>
    <label class="toggle"><input type="radio" name="dir" value="rows"> Across rows</label>
    <div class="field"><label for="fs-step">Step value</label><input id="fs-step" type="number" step="any" value="1"></div>`);
  if ((await showDialog("Series", body, OK_CANCEL(), { onOpen: focusFirst("#fs-step") })) !== "ok") return null;
  const step = Number(q<HTMLInputElement>(body, "#fs-step").value);
  return { step: Number.isFinite(step) ? step : 1, vertical: body.querySelector<HTMLInputElement>('input[name="dir"]:checked')?.value !== "rows" };
}

// MARK: Page setup

export async function pageSetupDialog(setup: PageSetup): Promise<PageSetup | null> {
  const metric = !/^en-(US|CA)$/i.test(navigator.language);
  const unit = metric ? { name: "cm", per: 72 / 2.54, step: 0.1 } : { name: "in", per: 72, step: 0.05 };
  const body = html(`
    <div class="field"><label>Orientation</label><select id="ps-orientation"><option value="portrait">Portrait</option><option value="landscape">Landscape</option></select></div>
    <div class="field"><label>Scaling</label><select id="ps-scaling"><option value="actual">Actual size</option><option value="fitWidth">Fit all columns on one page</option><option value="fitPage">Fit sheet on one page</option></select></div>
    <div class="field"><label for="ps-margin">Margins (${unit.name})</label><input id="ps-margin" type="number" min="0" step="${unit.step}" value="${(setup.margin / unit.per).toFixed(2).replace(/\.?0+$/, "")}"></div>
    <label class="toggle"><input id="ps-grid" type="checkbox" ${setup.printGridlines ? "checked" : ""}> Print gridlines</label>
    <label class="toggle"><input id="ps-head" type="checkbox" ${setup.printHeadings ? "checked" : ""}> Print row and column headings</label>
    <label class="toggle"><input id="ps-center" type="checkbox" ${setup.centerHorizontally ? "checked" : ""}> Center horizontally on the page</label>
    <div class="field"><label for="ps-header">Header</label><input id="ps-header" type="text" value="${escape(setup.header)}"></div>
    <div class="field"><label for="ps-footer">Footer</label><input id="ps-footer" type="text" value="${escape(setup.footer)}"></div>
    <p class="note">In headers and footers, &amp;P is the page number, &amp;N the page count, &amp;D the date and &amp;A the sheet name.</p>`);
  q<HTMLSelectElement>(body, "#ps-orientation").value = setup.orientation;
  q<HTMLSelectElement>(body, "#ps-scaling").value = setup.scaling;
  if ((await showDialog("Page Setup", body, OK_CANCEL())) !== "ok") return null;
  const margin = Math.max(0, (Number(q<HTMLInputElement>(body, "#ps-margin").value) || 0) * unit.per);
  return {
    ...setup,
    orientation: q<HTMLSelectElement>(body, "#ps-orientation").value as PageSetup["orientation"],
    scaling: q<HTMLSelectElement>(body, "#ps-scaling").value as PageSetup["scaling"],
    margin: Math.min(margin, 144),
    printGridlines: q<HTMLInputElement>(body, "#ps-grid").checked,
    printHeadings: q<HTMLInputElement>(body, "#ps-head").checked,
    centerHorizontally: q<HTMLInputElement>(body, "#ps-center").checked,
    header: q<HTMLInputElement>(body, "#ps-header").value,
    footer: q<HTMLInputElement>(body, "#ps-footer").value,
  };
}

// MARK: Charts

export async function chartEditorDialog(c: WorkbookController, chart: ChartObject): Promise<void> {
  const palettes: ChartPalette[] = ["grid", "ocean", "sunset", "mono", "vivid"];
  const body = html(`
    <div class="field"><label>Type</label><select id="ch-kind">${CHART_KINDS.map((k) => `<option value="${k}" ${k === chart.kind ? "selected" : ""}>${CHART_KIND_TITLES[k]}</option>`).join("")}</select></div>
    <div class="field"><label for="ch-title">Title</label><input id="ch-title" type="text" value="${escape(chart.title)}"></div>
    <div class="field"><label for="ch-range">Data range</label><input id="ch-range" type="text" value="${escape(rangeA1(chart.dataRange))}"></div>
    <div class="field"><label>Series in</label><select id="ch-series"><option value="columns">Columns</option><option value="rows">Rows</option></select></div>
    <div class="field"><label>Colors</label><select id="ch-palette">${palettes.map((p) => `<option value="${p}" ${p === chart.palette ? "selected" : ""}>${p[0].toUpperCase() + p.slice(1)}</option>`).join("")}</select></div>
    <div class="field"><label for="ch-x">Horizontal axis title</label><input id="ch-x" type="text" value="${escape(chart.xAxisTitle)}"></div>
    <div class="field"><label for="ch-y">Vertical axis title</label><input id="ch-y" type="text" value="${escape(chart.yAxisTitle)}"></div>
    <label class="toggle"><input id="ch-legend" type="checkbox" ${chart.showLegend ? "checked" : ""}> Show legend</label>
    <label class="toggle"><input id="ch-labels" type="checkbox" ${chart.showDataLabels ? "checked" : ""}> Show data labels</label>
    <label class="toggle"><input id="ch-grid" type="checkbox" ${chart.showGridlines ? "checked" : ""}> Show gridlines</label>`);
  q<HTMLSelectElement>(body, "#ch-series").value = chart.seriesInColumns ? "columns" : "rows";
  const result = await showDialog("Edit Chart", body, [{ label: "Delete Chart", value: "delete", left: true }, ...OK_CANCEL()], { onOpen: focusFirst("#ch-title") });
  if (result === "delete") { c.deleteChart(chart.id); return; }
  if (result !== "ok") return;
  const r = parseRange(q<HTMLInputElement>(body, "#ch-range").value.trim()) ?? chart.dataRange;
  c.updateChart({
    ...chart,
    kind: q<HTMLSelectElement>(body, "#ch-kind").value as ChartObject["kind"],
    title: q<HTMLInputElement>(body, "#ch-title").value,
    dataRange: r,
    seriesInColumns: q<HTMLSelectElement>(body, "#ch-series").value === "columns",
    palette: q<HTMLSelectElement>(body, "#ch-palette").value as ChartPalette,
    xAxisTitle: q<HTMLInputElement>(body, "#ch-x").value,
    yAxisTitle: q<HTMLInputElement>(body, "#ch-y").value,
    showLegend: q<HTMLInputElement>(body, "#ch-legend").checked,
    showDataLabels: q<HTMLInputElement>(body, "#ch-labels").checked,
    showGridlines: q<HTMLInputElement>(body, "#ch-grid").checked,
  });
}

// MARK: Templates

/** Draws a template's first sheet, like a thumbnail. */
function drawTemplatePreview(canvas: HTMLCanvasElement, template: WorkbookTemplate) {
  const dpr = window.devicePixelRatio || 1;
  const width = canvas.clientWidth || 200, height = canvas.clientHeight || 118;
  canvas.width = width * dpr;
  canvas.height = height * dpr;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const controller = new WorkbookController(template.build());
  controller.selection = { active: { row: 1_000_000, column: 0 }, anchor: { row: 1_000_000, column: 0 }, ranges: [] };
  const sheet = controller.sheet;
  const renderer = new GridRenderer(controller, new ConditionalFormatter(controller.calculator));
  renderer.pixel = 1 / dpr;
  const g = new GridGeometry({ ...sheet, showHeadings: false, frozenRows: 0, frozenColumns: 0 }, 0.42, 0, 0, width, height);
  const theme = { ...currentTheme(), dark: false, cellBackground: "#ffffff", cellText: "#000000", gridline: "#e3e5e4" };
  renderer.draw(ctx, g, theme, { referenceHighlights: [], dragPreview: null, marchingPhase: 0, resizeGuide: null, editing: true });
}

export async function templateChooser(templates: WorkbookTemplate[], recent: string[], openRecent: (path: string) => void, openOther: () => void): Promise<WorkbookTemplate | null> {
  let chosen: WorkbookTemplate | null = null;
  const body = html(`
    <div class="template-grid">${templates.map((t, i) => `<button type="button" class="template-card" data-i="${i}"><canvas></canvas><div class="meta"><b>${escape(t.name)}</b><span>${escape(t.subtitle)}</span></div></button>`).join("")}</div>
    ${recent.length ? `<div class="section-title">Recent</div><div class="recent-list">${recent.slice(0, 6).map((p) => `<button type="button" data-path="${escape(p)}">${escape(basename(p))}<span>${escape(p)}</span></button>`).join("")}</div>` : ""}`);
  body.addEventListener("click", (e) => {
    const card = (e.target as HTMLElement).closest<HTMLElement>("[data-i]");
    if (card) {
      chosen = templates[Number(card.dataset.i)];
      dialog().close("ok");
      return;
    }
    const recentButton = (e.target as HTMLElement).closest<HTMLElement>("[data-path]");
    if (recentButton) {
      dialog().close("cancel");
      openRecent(recentButton.dataset.path!);
    }
  });
  const result = await showDialog("New Workbook", body, [{ label: "Open…", value: "open", left: true }, { label: "Cancel", value: "cancel" }], {
    width: "xwide",
    onOpen: (root) => {
      requestAnimationFrame(() => root.querySelectorAll<HTMLElement>(".template-card").forEach((card) => {
        try {
          drawTemplatePreview(card.querySelector("canvas")!, templates[Number(card.dataset.i)]);
        } catch {
          // A preview is decoration only.
        }
      }));
      root.querySelector<HTMLElement>(".template-card")?.focus();
    },
  });
  if (result === "open") openOther();
  return chosen;
}

// MARK: Statistics

export async function statisticsDialog(c: WorkbookController): Promise<void> {
  const sheet = c.sheet;
  let formulas = 0, numbers = 0, text = 0;
  for (const cell of sheet.cells.values()) {
    if (cell.formula !== undefined) formulas++;
    else if (typeof cell.value === "number") numbers++;
    else if (typeof cell.value === "string") text++;
  }
  const rows: [string, string][] = [
    ["Sheets", String(c.workbook.sheets.length)], ["Cells with data (this sheet)", String(sheet.cells.size)], ["Formulas", String(formulas)],
    ["Numbers", String(numbers)], ["Text", String(text)], ["Notes", String(sheet.notes.size)], ["Charts", String(sheet.charts.length)],
    ["Conditional formats", String(sheet.conditionalFormats.length)], ["Defined names", String(c.workbook.names.length)],
    ["Last cell", sheet.cells.size ? a1({ row: Math.max(...[...sheet.cells.keys()].map((k) => Math.floor(k / 16384))), column: Math.max(...[...sheet.cells.keys()].map((k) => k % 16384)) }) : "A1"],
  ];
  const body = html(`<div class="list-box">${rows.map(([l, v]) => `<div class="item"><span class="grow">${l}</span><b>${v}</b></div>`).join("")}</div>`);
  await showDialog("Workbook Statistics", body, [{ label: "OK", value: "ok", primary: true }]);
}

// MARK: Settings

export async function settingsDialog(checkNow: () => void): Promise<void> {
  const s = settings();
  const directions: [EnterDirection, string][] = [["down", "Down"], ["right", "Right"], ["up", "Up"], ["left", "Left"], ["none", "Don't Move"]];
  const body = html(`
    <div class="section-title">General</div>
    <label class="toggle"><input id="s-chooser" type="checkbox" ${s.showTemplateChooserOnLaunch ? "checked" : ""}> Show the template chooser when Wired Grid opens</label>
    <div class="field"><label for="s-sheets">Sheets in a new workbook</label><input id="s-sheets" type="number" min="1" max="16" value="${s.defaultSheetCount}"></div>
    <div class="field"><label for="s-author">Author name</label><input id="s-author" type="text" value="${escape(s.authorName)}"></div>
    <div class="section-title">Editing</div>
    <div class="field"><label for="s-enter">After pressing Enter, move</label><select id="s-enter">${directions.map(([v, l]) => `<option value="${v}" ${v === s.enterDirection ? "selected" : ""}>${l}</option>`).join("")}</select></div>
    <label class="toggle"><input id="s-auto" type="checkbox" ${s.autoComplete ? "checked" : ""}> AutoComplete cell values from the same column</label>
    <label class="toggle"><input id="s-hints" type="checkbox" ${s.functionHints ? "checked" : ""}> Show function suggestions and argument hints</label>
    <div class="section-title">New Workbooks</div>
    <div class="field"><label for="s-font">Default font</label><input id="s-font" type="text" value="${escape(s.defaultFontName)}"></div>
    <div class="field"><label for="s-size">Default size</label><input id="s-size" type="number" min="8" max="24" value="${s.defaultFontSize}"></div>
    <div class="section-title">View</div>
    <label class="toggle"><input id="s-fbar" type="checkbox" ${s.showFormulaBar ? "checked" : ""}> Show formula bar</label>
    <label class="toggle"><input id="s-sbar" type="checkbox" ${s.showStatusBar ? "checked" : ""}> Show status bar</label>
    <div class="section-title">Updates</div>
    <label class="toggle"><input id="s-updates" type="checkbox" ${s.checkForUpdates ? "checked" : ""}> Check for new versions automatically</label>
    <p class="note">Wired Grid ${APP_VERSION} for ${platformName()} · <a href="#" id="s-check">Check now</a></p>`);
  q(body, "#s-check").addEventListener("click", (e) => { e.preventDefault(); checkNow(); });
  // Closing the dialog either way keeps the changes, like a preferences window.
  await showDialog("Settings", body, [{ label: "Done", value: "ok", primary: true }]);
  const checked = (id: string) => q<HTMLInputElement>(body, id).checked;
  updateSettings({
    showTemplateChooserOnLaunch: checked("#s-chooser"),
    defaultSheetCount: Math.max(1, Math.min(16, Number(q<HTMLInputElement>(body, "#s-sheets").value) || 1)),
    authorName: q<HTMLInputElement>(body, "#s-author").value.trim(),
    enterDirection: q<HTMLSelectElement>(body, "#s-enter").value as EnterDirection,
    autoComplete: checked("#s-auto"),
    functionHints: checked("#s-hints"),
    defaultFontName: q<HTMLInputElement>(body, "#s-font").value.trim() || "Helvetica Neue",
    defaultFontSize: Math.max(8, Math.min(24, Number(q<HTMLInputElement>(body, "#s-size").value) || 12)),
    showFormulaBar: checked("#s-fbar"),
    showStatusBar: checked("#s-sbar"),
    checkForUpdates: checked("#s-updates"),
  });
}

// MARK: About and updates

export async function aboutDialog(): Promise<void> {
  const body = html(`
    <p>Version ${APP_VERSION} for ${platformName()}</p>
    <p>A spreadsheet with a familiar Excel workflow: over 300 functions, dynamic arrays, charts, conditional formatting and filters. Workbooks are saved as <b>.grid</b> files that open in Wired Grid on Mac, Windows and Linux, and it reads and writes Excel <b>.xlsx</b> files too.</p>
    <p class="note"><a href="#" id="about-site">github.com/Wired-Office/Wired-Grid</a></p>`);
  q(body, "#about-site").addEventListener("click", (e) => { e.preventDefault(); openURL("https://github.com/Wired-Office/Wired-Grid"); });
  await showDialog("Wired Grid", body, [{ label: "OK", value: "ok", primary: true }]);
}

/** Release notes as plain text: Markdown markers and the generator footer removed. */
export function plainNotes(body: string): string {
  return body
    .replace(/\r\n/g, "\n")
    .split("\n")
    .filter((line) => !line.includes("Generated with [Claude Code]"))
    .map((line) => line.replace(/^[#>]+\s*/, "").replace(/^[-*]\s+/, "• ").replace(/\*\*(.+?)\*\*/g, "$1").replace(/`([^`]+)`/g, "$1").replace(/\[([^\]]+)\]\([^)]+\)/g, "$1"))
    .join("\n")
    .trim();
}

export async function updateDialog(version: string, notes: string): Promise<"download" | "later" | "skip"> {
  const body = html(`<p>You have version ${APP_VERSION}. Download the new version and run the installer to update.</p><div class="notes"></div>`);
  q(body, ".notes").textContent = plainNotes(notes);
  const result = await showDialog(`Wired Grid ${version} is available`, body, [
    { label: "Skip This Version", value: "skip", left: true },
    { label: "Remind Me Later", value: "later" },
    { label: "Download", value: "download", primary: true },
  ]);
  return (result as "download" | "skip") ?? "later";
}

