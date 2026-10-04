import type { WorkbookController } from "../engine/controller";
import { ConditionalStats, ruleMatches } from "../engine/conditional";
import { general } from "../formula/numberFormat";
import type { FilterCriterion, Rule } from "../model/workbook";

let open: HTMLElement | null = null;

export function closeFilterPopover() {
  open?.remove();
  open = null;
}

const escapeHTML = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** The AutoFilter dropdown: sort, search and a checklist of values (or a condition). */
export function showFilterPopover(controller: WorkbookController, column: number, anchor: DOMRect, onClose: () => void) {
  closeFilterPopover();
  const filter = controller.sheet.filter;
  if (!filter) return;
  const values = controller.filterValues(column);
  const existing = filter.criteria.get(column);
  let selected = new Set(existing?.type === "values" ? existing.values : values.map((v) => v.text));
  let kind = 0;
  let conditionValue = "";
  if (existing?.type === "condition") {
    const rule = existing.rule;
    if (rule.type === "greaterThan") { kind = 1; conditionValue = general(rule.value); }
    else if (rule.type === "lessThan") { kind = 2; conditionValue = general(rule.value); }
    else if (rule.type === "textContains") { kind = 3; conditionValue = rule.text; }
    else if (rule.type === "top") kind = 4;
    else if (rule.type === "aboveAverage") kind = 5;
  }

  const root = document.createElement("div");
  root.className = "popover filter-popover";
  root.innerHTML = `
    <div class="row">
      <button data-sort="asc">↑ Sort A → Z</button>
      <button data-sort="desc">↓ Sort Z → A</button>
    </div>
    <hr>
    <div class="row">
      <select class="kind">
        <option value="0">Values</option><option value="1">Greater than</option><option value="2">Less than</option>
        <option value="3">Contains</option><option value="4">Top 10</option><option value="5">Above average</option>
      </select>
      <input class="condition" type="text" placeholder="Value">
    </div>
    <div class="values-area">
      <input class="search" type="search" placeholder="Search">
      <div class="checklist" role="list"></div>
    </div>
    <div class="row buttons">
      <button class="clear">Clear Filter</button>
      <span class="spacer"></span>
      <button class="cancel">Cancel</button>
      <button class="primary apply">Apply</button>
    </div>`;
  document.body.append(root);
  open = root;

  const q = <T extends HTMLElement>(s: string) => root.querySelector<T>(s)!;
  const kindSelect = q<HTMLSelectElement>(".kind");
  const condition = q<HTMLInputElement>(".condition");
  const search = q<HTMLInputElement>(".search");
  const list = q<HTMLDivElement>(".checklist");
  kindSelect.value = String(kind);
  condition.value = conditionValue;
  q<HTMLButtonElement>(".clear").disabled = !existing;

  const filtered = () => (search.value ? values.filter((v) => v.text.toLowerCase().includes(search.value.toLowerCase())) : values);
  const renderList = () => {
    const items = filtered();
    const allOn = items.every((i) => selected.has(i.text));
    list.innerHTML = `<label class="check all"><input type="checkbox" data-all ${allOn ? "checked" : ""}> <b>(Select All)</b></label>` +
      items.map((item, i) => `<label class="check"><input type="checkbox" data-index="${i}" ${selected.has(item.text) ? "checked" : ""}> <span class="text">${escapeHTML(item.text || "(Blanks)")}</span><span class="count">${item.count}</span></label>`).join("");
  };
  const syncKind = () => {
    const k = Number(kindSelect.value);
    condition.hidden = !(k >= 1 && k <= 3);
    q<HTMLDivElement>(".values-area").hidden = k !== 0;
  };
  list.addEventListener("change", (event) => {
    const input = event.target as HTMLInputElement;
    const items = filtered();
    if (input.dataset.all !== undefined) {
      for (const item of items) input.checked ? selected.add(item.text) : selected.delete(item.text);
    } else {
      const item = items[Number(input.dataset.index)];
      if (item) input.checked ? selected.add(item.text) : selected.delete(item.text);
    }
    renderList();
  });
  search.addEventListener("input", renderList);
  kindSelect.addEventListener("change", syncKind);

  const dismiss = () => {
    closeFilterPopover();
    document.removeEventListener("mousedown", outside, true);
    document.removeEventListener("keydown", keys, true);
    onClose();
  };
  const outside = (event: MouseEvent) => { if (!root.contains(event.target as Node)) dismiss(); };
  const keys = (event: KeyboardEvent) => {
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); dismiss(); }
    else if (event.key === "Enter" && event.target !== search) { event.preventDefault(); apply(); }
  };
  const sort = (ascending: boolean) => {
    controller.sort(filter.range, [{ column, ascending }], true);
    dismiss();
  };
  const apply = () => {
    const k = Number(kindSelect.value);
    const number = Number(condition.value);
    let criterion: FilterCriterion | undefined;
    let rule: Rule | null = null;
    if (k === 1 && condition.value.trim() && !Number.isNaN(number)) criterion = { type: "condition", rule: { type: "greaterThan", value: number } };
    else if (k === 2 && condition.value.trim() && !Number.isNaN(number)) criterion = { type: "condition", rule: { type: "lessThan", value: number } };
    else if (k === 3) criterion = condition.value ? { type: "condition", rule: { type: "textContains", text: condition.value } } : undefined;
    else if (k === 4) rule = { type: "top", count: 10, percent: false };
    else if (k === 5) rule = { type: "aboveAverage" };
    else if (k === 0) criterion = selected.size === values.length ? undefined : { type: "values", values: [...selected] };
    if (rule) {
      // Rules that need column statistics are resolved to the matching values now.
      const current = controller.sheet.filter!;
      const rows: number[] = [];
      for (let row = current.range.start.row + 1; row <= current.range.end.row; row++) rows.push(row);
      const stats = new ConditionalStats(rows.map((row) => controller.value({ row, column })));
      const allowed = new Set<string>();
      for (const row of rows) {
        const a = { row, column };
        if (ruleMatches(rule, controller.value(a), stats)) allowed.add(controller.displayText(a));
      }
      criterion = { type: "values", values: [...allowed] };
    }
    controller.setFilterCriterion(criterion, column);
    dismiss();
  };
  root.addEventListener("click", (event) => {
    const target = event.target as HTMLElement;
    if (target.dataset.sort) sort(target.dataset.sort === "asc");
    else if (target.classList.contains("clear")) { controller.setFilterCriterion(undefined, column); dismiss(); }
    else if (target.classList.contains("cancel")) dismiss();
    else if (target.classList.contains("apply")) apply();
  });

  renderList();
  syncKind();
  const width = root.offsetWidth, height = root.offsetHeight;
  let left = anchor.right - width, top = anchor.bottom + 4;
  if (top + height > window.innerHeight - 8) top = Math.max(8, anchor.top - height - 4);
  left = Math.min(Math.max(8, left), window.innerWidth - width - 8);
  Object.assign(root.style, { left: `${left}px`, top: `${top}px` });
  setTimeout(() => document.addEventListener("mousedown", outside, true), 0);
  document.addEventListener("keydown", keys, true);
  (kindSelect.value === "0" ? search : condition).focus();
}
