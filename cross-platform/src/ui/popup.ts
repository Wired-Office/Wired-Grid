import type { MenuEntry } from "./menubar";

let current: { root: HTMLElement; close: () => void } | null = null;

export function closePopupMenu() {
  current?.close();
}

/** Shows a menu at a point (a context menu) or under an element. */
export function showPopupMenu(at: { x: number; y: number } | HTMLElement, entries: MenuEntry[], onClose?: () => void) {
  closePopupMenu();
  const root = document.createElement("div");
  root.className = "popup-menu menu-items";
  root.setAttribute("role", "menu");
  document.body.append(root);

  const close = () => {
    if (current?.root !== root) return;
    current = null;
    root.remove();
    document.removeEventListener("mousedown", outside, true);
    document.removeEventListener("keydown", keys, true);
    window.removeEventListener("blur", close);
    onClose?.();
  };
  const outside = (event: MouseEvent) => {
    if (!(event.target as Node).isConnected || !root.contains(event.target as Node)) close();
  };
  const keys = (event: KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      close();
    }
  };

  const render = (container: HTMLElement, items: MenuEntry[]) => {
    for (const entry of items) {
      if (entry === "-") {
        const separator = document.createElement("div");
        separator.className = "menu-separator";
        container.append(separator);
        continue;
      }
      const button = document.createElement("button");
      button.className = "menu-item";
      button.setAttribute("role", "menuitem");
      button.textContent = entry.label;
      if (entry.checked) button.classList.add("checked");
      if (entry.enabled === false) button.disabled = true;
      if (entry.shortcut) {
        const shortcut = document.createElement("span");
        shortcut.className = "shortcut";
        shortcut.textContent = entry.shortcut;
        button.append(shortcut);
      }
      if (entry.submenu) {
        const wrapper = document.createElement("div");
        wrapper.className = "submenu";
        const sub = document.createElement("div");
        sub.className = "menu-items";
        render(sub, entry.submenu);
        wrapper.append(button, sub);
        container.append(wrapper);
        continue;
      }
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", () => {
        close();
        entry.action?.();
      });
      container.append(button);
    }
  };
  render(root, entries);

  let x: number, y: number;
  if (at instanceof HTMLElement) {
    const rect = at.getBoundingClientRect();
    x = rect.left;
    y = rect.bottom + 2;
  } else {
    ({ x, y } = at);
  }
  const width = root.offsetWidth, height = root.offsetHeight;
  if (x + width > window.innerWidth - 4) x = Math.max(4, window.innerWidth - width - 4);
  if (y + height > window.innerHeight - 4) y = Math.max(4, (at instanceof HTMLElement ? at.getBoundingClientRect().top - height - 2 : y - height));
  root.style.left = `${x}px`;
  root.style.top = `${y}px`;

  current = { root, close };
  setTimeout(() => {
    document.addEventListener("mousedown", outside, true);
    window.addEventListener("blur", close);
  }, 0);
  document.addEventListener("keydown", keys, true);
}
