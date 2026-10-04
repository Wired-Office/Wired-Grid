import { FUNCTIONS, functionCompletions, functionParameters, type FunctionSpec } from "../formula";
import { settings } from "../settings";

/** What the formula under the caret calls for: a list of function names or an argument hint. */
export type FormulaContext =
  | { kind: "suggestions"; prefix: string; start: number; end: number; items: FunctionSpec[] }
  | { kind: "signature"; spec: FunctionSpec; argument: number }
  | { kind: "none" };

const isNameChar = (ch: string) => /[\p{L}\p{N}._]/u.test(ch);

/** Analyzes formula text up to the caret. */
export function analyzeFormula(text: string, caret: number): FormulaContext {
  if (!text.startsWith("=")) return { kind: "none" };
  const end = Math.min(caret, text.length);

  // An identifier being typed right before the caret.
  let start = end;
  while (start > 1 && isNameChar(text[start - 1])) start--;
  if (start < end) {
    const prefix = text.slice(start, end);
    const before = start > 0 ? text[start - 1] : "";
    const afterIsParen = text[end] === "(";
    const insideString = (text.slice(0, start).match(/"/g)?.length ?? 0) % 2 === 1;
    if (/^\p{L}/u.test(prefix) && !afterIsParen && "=(,;+-*/^&<> :".includes(before) && !insideString) {
      const items = functionCompletions(prefix).slice(0, 12);
      if (items.length) return { kind: "suggestions", prefix, start, end, items };
    }
  }

  // The innermost function call around the caret.
  const stack: [string | null, number][] = [];
  let inString = false;
  for (let i = 1; i < end; i++) {
    const ch = text[i];
    if (ch === '"') inString = !inString;
    if (inString) continue;
    if (ch === "(") {
      let j = i;
      while (j > 1 && isNameChar(text[j - 1])) j--;
      stack.push([j < i ? text.slice(j, i).toUpperCase() : null, 0]);
    } else if (ch === ")") {
      stack.pop();
    } else if ((ch === "," || ch === ";") && stack.length) {
      stack[stack.length - 1][1]++;
    }
  }
  for (let k = stack.length - 1; k >= 0; k--) {
    const [name, argument] = stack[k];
    if (!name) continue;
    const spec = FUNCTIONS.get(name);
    if (spec) return { kind: "signature", spec, argument };
    break;
  }
  return { kind: "none" };
}

const escapeHTML = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

/** A small floating panel under the editor showing function suggestions or argument help. */
export class FunctionHints {
  readonly element: HTMLDivElement;
  items: FunctionSpec[] = [];
  selectedIndex = 0;
  replaceStart = 0;
  replaceEnd = 0;
  onAccept: ((spec: FunctionSpec, start: number, end: number) => void) | null = null;

  constructor(parent: HTMLElement) {
    this.element = document.createElement("div");
    this.element.className = "function-hints";
    this.element.hidden = true;
    this.element.addEventListener("mousedown", (event) => {
      event.preventDefault();
      const row = (event.target as HTMLElement).closest<HTMLElement>("[data-index]");
      if (row) {
        const item = this.items[Number(row.dataset.index)];
        if (item) this.onAccept?.(item, this.replaceStart, this.replaceEnd);
      }
    });
    parent.append(this.element);
  }

  get isShowingList() {
    return !this.element.hidden && this.items.length > 0;
  }

  get selectedItem(): FunctionSpec | null {
    return this.items[this.selectedIndex] ?? null;
  }

  update(context: FormulaContext, anchor: DOMRect) {
    if (!settings().functionHints || context.kind === "none") {
      this.hide();
      return;
    }
    if (context.kind === "suggestions") {
      if (this.items.map((i) => i.name).join() !== context.items.map((i) => i.name).join()) this.selectedIndex = 0;
      this.items = context.items;
      this.replaceStart = context.start;
      this.replaceEnd = context.end;
      this.renderList();
    } else {
      this.items = [];
      this.element.innerHTML = `<div class="signature">${signatureHTML(context.spec, context.argument)}</div><div class="summary">${escapeHTML(context.spec.summary)}</div>`;
    }
    this.element.hidden = false;
    const width = this.element.offsetWidth, height = this.element.offsetHeight;
    let left = anchor.left, top = anchor.bottom + 4;
    if (top + height > window.innerHeight - 4) top = anchor.top - height - 4;
    left = Math.min(left, window.innerWidth - width - 8);
    this.element.style.left = `${Math.max(4, left)}px`;
    this.element.style.top = `${Math.max(4, top)}px`;
  }

  private renderList() {
    const rows = this.items.map((item, i) =>
      `<div class="hint-row${i === this.selectedIndex ? " selected" : ""}" data-index="${i}"><span class="hint-name">${item.name}</span><span class="hint-summary">${escapeHTML(item.summary)}</span></div>`).join("");
    const footer = this.selectedItem ? `<div class="hint-footer">${escapeHTML(this.selectedItem.syntax)}</div>` : "";
    this.element.innerHTML = `<div class="hint-header">FUNCTIONS · Tab to insert</div>${rows}${footer}`;
  }

  moveSelection(delta: number) {
    if (!this.items.length) return;
    this.selectedIndex = (this.selectedIndex + delta + this.items.length) % this.items.length;
    this.renderList();
  }

  hide() {
    this.items = [];
    this.element.hidden = true;
  }
}

function signatureHTML(spec: FunctionSpec, argument: number): string {
  const parameters = functionParameters(spec);
  const parts = parameters.map((p, i) => {
    // Repeating parameters ("…") highlight for every later argument.
    const current = i === argument || (i === parameters.length - 1 && p.includes("…") && argument >= i);
    return current ? `<b>${escapeHTML(p)}</b>` : escapeHTML(p);
  });
  return `<span class="fn">${spec.name}(</span>${parts.join(", ")})`;
}
