export interface MenuItemSpec {
  label: string;
  shortcut?: string;
  action?: () => void;
  enabled?: boolean;
  checked?: boolean;
  submenu?: MenuEntry[];
}
export type MenuEntry = MenuItemSpec | "-";

export interface MenuSpec {
  label: string;
  /** Built each time the menu opens, so state (checked, enabled, recent files) is current. */
  items: () => MenuEntry[];
}

/** An in-window menu bar that looks and behaves the same on Windows and Linux. */
export function buildMenubar(root: HTMLElement, menus: MenuSpec[], onClose: () => void) {
  let open: HTMLElement | null = null;

  const close = () => {
    if (!open) return;
    open.classList.remove("open");
    open = null;
    onClose();
  };

  const renderItems = (container: HTMLElement, entries: MenuEntry[]) => {
    container.replaceChildren();
    for (const entry of entries) {
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
        const items = document.createElement("div");
        items.className = "menu-items";
        renderItems(items, entry.submenu);
        if (!entry.submenu.length) {
          const empty = document.createElement("div");
          empty.className = "menu-empty";
          empty.textContent = "None";
          items.append(empty);
        }
        wrapper.append(button, items);
        container.append(wrapper);
        continue;
      }
      button.addEventListener("click", () => {
        close();
        entry.action?.();
      });
      container.append(button);
    }
  };

  for (const spec of menus) {
    const menu = document.createElement("div");
    menu.className = "menu";
    const title = document.createElement("button");
    title.textContent = spec.label;
    title.setAttribute("aria-haspopup", "true");
    const items = document.createElement("div");
    items.className = "menu-items";
    items.setAttribute("role", "menu");
    menu.append(title, items);
    root.append(menu);

    const show = () => {
      if (open && open !== menu) open.classList.remove("open");
      renderItems(items, spec.items());
      menu.classList.add("open");
      open = menu;
    };
    // Keep focus in the editor so the selection stays visible.
    title.addEventListener("mousedown", (event) => event.preventDefault());
    items.addEventListener("mousedown", (event) => event.preventDefault());
    title.addEventListener("click", () => (open === menu ? close() : show()));
    title.addEventListener("mouseenter", () => { if (open && open !== menu) show(); });
  }

  document.addEventListener("mousedown", (event) => {
    if (open && !root.contains(event.target as Node)) close();
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && open) {
      event.preventDefault();
      close();
    }
  }, true);
}
