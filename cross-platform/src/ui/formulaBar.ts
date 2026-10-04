import type { WorkbookController } from "../engine/controller";
import { highlightedFormulaHTML, type CellEditor, type FormulaBarLink } from "../grid/editor";
import { settings, updateSettings } from "../settings";
import type { AppActions } from "./actions";

/** The name box, the ✕ / ✓ / fx buttons and the formula field. */
export class FormulaBar implements FormulaBarLink {
  private nameBox: HTMLInputElement;
  private field: HTMLTextAreaElement;
  private backdrop: HTMLDivElement;
  private cancelButton: HTMLButtonElement;
  private enterButton: HTMLButtonElement;
  private expanded = false;
  private focused = false;

  constructor(private root: HTMLElement, private c: WorkbookController, private editor: CellEditor, actions: AppActions) {
    root.innerHTML = `
      <input class="name-box" aria-label="Name Box" title="Name Box: type a reference or a name to go there, or a new name for the selection" spellcheck="false">
      <div class="fx-buttons">
        <button class="cancel" title="Cancel (Esc)" aria-label="Cancel">✕</button>
        <button class="enter" title="Enter" aria-label="Enter">✓</button>
        <button class="fx" title="Insert Function (Shift+F3)" aria-label="Insert Function">fx</button>
      </div>
      <div class="formula-field-wrap">
        <div class="formula-backdrop" aria-hidden="true"></div>
        <textarea class="formula-field" aria-label="Formula Bar" spellcheck="false" rows="1"></textarea>
      </div>
      <button class="expand-button" title="Expand Formula Bar" aria-label="Expand Formula Bar">⌄</button>`;
    this.nameBox = root.querySelector(".name-box")!;
    this.field = root.querySelector(".formula-field")!;
    this.backdrop = root.querySelector(".formula-backdrop")!;
    this.cancelButton = root.querySelector(".cancel")!;
    this.enterButton = root.querySelector(".enter")!;
    editor.formulaBar = this;

    this.nameBox.addEventListener("focus", () => this.nameBox.select());
    this.nameBox.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        const text = this.nameBox.value.trim();
        if (text && !c.goTo(text)) {
          // A new name for the selection.
          if (/^[\p{L}_\\][\p{L}\p{N}_.]*$/u.test(text)) c.nameSelection(text);
          else c.presenter.alert(`“${text}” isn't a valid reference or name.`);
        }
        actions.focusGrid();
        this.refresh();
      } else if (event.key === "Escape") {
        this.refresh();
        actions.focusGrid();
      }
    });
    this.nameBox.addEventListener("blur", () => this.refresh());

    for (const b of [this.cancelButton, this.enterButton]) b.addEventListener("mousedown", (e) => e.preventDefault());
    this.cancelButton.addEventListener("click", () => c.cancelEditing());
    this.enterButton.addEventListener("click", () => this.editor.commit({}));
    root.querySelector(".fx")!.addEventListener("click", () => actions.insertFunction());
    root.querySelector(".expand-button")!.addEventListener("click", () => {
      this.expanded = !this.expanded;
      root.classList.toggle("formula-bar-expanded", this.expanded);
      (root.querySelector(".expand-button") as HTMLElement).textContent = this.expanded ? "⌃" : "⌄";
    });

    this.field.addEventListener("focus", () => {
      this.focused = true;
      if (!c.isEditing) {
        const caret = this.field.selectionStart;
        this.editor.begin({ mode: "edit", focusFormulaBar: true });
        this.field.setSelectionRange(caret ?? this.field.value.length, caret ?? this.field.value.length);
      }
    });
    this.field.addEventListener("blur", () => { this.focused = false; });
    this.field.addEventListener("input", () => {
      this.editor.formulaBarTextChanged(this.field.value);
      this.syncHighlights(this.field.value);
    });
    this.field.addEventListener("scroll", () => { this.backdrop.scrollTop = this.field.scrollTop; });
    this.field.addEventListener("keydown", (event) => {
      if (!c.isEditing) return;
      // Enter commits in place (no move), like Excel's formula bar.
      if (event.key === "Enter" && !event.altKey && !event.ctrlKey && !event.metaKey) {
        event.preventDefault();
        this.editor.commit({ reverseEnter: event.shiftKey, useEnterDirection: true });
        return;
      }
      if (this.editor.handleKey(event, this.field)) event.preventDefault();
    });
    for (const type of ["click", "keyup", "select"]) this.field.addEventListener(type, () => this.editor.updateHints());

    c.subscribe((kind) => {
      if (kind === "selection" || kind === "content" || kind === "sheets" || kind === "load") this.refresh();
      if (kind === "editing") this.updateButtons();
    });
    this.applyVisibility();
    this.refresh();
  }

  applyVisibility() {
    this.root.hidden = !settings().showFormulaBar;
  }

  toggleVisibility() {
    updateSettings({ showFormulaBar: !settings().showFormulaBar });
    this.applyVisibility();
  }

  refresh() {
    if (document.activeElement !== this.nameBox) this.nameBox.value = this.c.nameBoxText;
    if (!this.c.isEditing) {
      const text = this.c.inputText(this.c.selection.active);
      this.field.value = text;
      this.syncHighlights(text);
    }
    this.updateButtons();
  }

  private updateButtons() {
    this.cancelButton.disabled = !this.c.isEditing;
    this.enterButton.disabled = !this.c.isEditing;
  }

  // MARK: FormulaBarLink

  showEditingText(text: string) {
    if (this.field.value !== text) this.field.value = text;
    this.syncHighlights(text);
  }

  endEditing() {
    this.focused = false;
    this.refresh();
  }

  focusField() {
    this.field.focus();
  }

  activeField(): HTMLTextAreaElement | null {
    return this.focused && this.c.isEditing ? this.field : null;
  }

  syncHighlights(text: string) {
    this.backdrop.innerHTML = highlightedFormulaHTML(text).html;
    this.backdrop.scrollTop = this.field.scrollTop;
  }

  insertText(text: string) {
    const field = this.editor.activeField;
    field.setRangeText(text, field.selectionStart ?? field.value.length, field.selectionEnd ?? field.value.length, "end");
    field.dispatchEvent(new Event("input"));
    field.focus();
  }
}
