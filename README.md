# Wired Grid

A spreadsheet with a familiar Excel workflow for **macOS, Windows and Linux**. The companion to [Wired Paper](https://github.com/Wired-Office/Wired-Paper).

- **macOS:** a native app written in Swift, with AppKit for the grid and SwiftUI for the surrounding interface. No third-party dependencies.
- **Windows and Linux:** a desktop app built with [Tauri](https://tauri.app) (Rust plus a web-based grid) in [`cross-platform/`](cross-platform/).

Both read and write the same **`.grid`** files, so workbooks move freely between computers.

## Download

Get the latest version from [Releases](https://github.com/Wired-Office/Wired-Grid/releases/latest):

| Platform | File |
| --- | --- |
| macOS 14+ (Apple silicon and Intel) | `Wired-Grid-<version>.dmg` |
| Windows 10/11 (x64) | `Wired-Grid-<version>-windows-x64-setup.exe` |
| Linux (x86_64), any distribution | `Wired-Grid-<version>-linux-x86_64.AppImage` |
| Debian, Ubuntu, Mint… | `Wired-Grid-<version>-linux-amd64.deb` |

The builds aren't signed by Apple or Microsoft yet, so on first launch macOS asks you to confirm (right-click ▸ Open), and Windows SmartScreen asks you to confirm (More info ▸ Run anyway). For the AppImage, make the file executable (`chmod +x`) and run it.

## Building the Mac app

Open `WiredGrid.xcodeproj` in Xcode (26 or later) and run the **WiredGrid** scheme. It requires macOS 14 or later.

From the command line:

```bash
xcodebuild -project WiredGrid.xcodeproj -scheme WiredGrid build
xcodebuild -project WiredGrid.xcodeproj -scheme WiredGrid test
```

The project uses file-system-synchronized groups, so new source files placed under `WiredGrid/` are picked up automatically. Regenerate the app icon with `swift Scripts/generate-icon.swift`.

## Building the Windows and Linux app

Needs Node.js 20+ and Rust (stable). On Linux, also install the WebKitGTK development packages ([Tauri prerequisites](https://tauri.app/start/prerequisites/)).

```bash
cd cross-platform
npm install
npm test            # formula engine and file format tests
npm run tauri dev   # run the desktop app
npm run dev         # or just the spreadsheet, in a browser at http://localhost:1420
npm run tauri build # installers in src-tauri/target/release/bundle
```

Release installers are built by GitHub Actions ([`windows-linux.yml`](.github/workflows/windows-linux.yml)): create the release, then run the workflow with the release tag and it attaches the `.exe`, `.AppImage` and `.deb`. Build the Mac `.dmg` with `Scripts/make-dmg.sh`.

### What the Windows and Linux app does

It is a TypeScript port of the Mac app's engine and interface, so it behaves the same way: the same ribbon (Home, Insert, Page Layout, Formulas, Data, Review, View), the formula engine with 300+ functions and dynamic arrays, colored references and function hints while editing, the fill handle, Paste Special, number formats, cell styles, Format as Table, conditional formatting (including color scales, data bars and icon sets), sort, AutoFilter, Find & Replace, defined names, notes, links, charts, frozen panes, zoom, templates with live previews, printing and PDF (through the system's print-to-PDF printer), and update notifications when a new release is out. It opens and saves `.grid`, Excel `.xlsx`, CSV and TSV. Shortcuts use Ctrl where the Mac uses ⌘.

## Features

- **A real grid.** 1,048,576 rows × 16,384 columns, drawn on demand. Custom row heights and column widths (drag or double-click a header border to AutoFit), hidden rows and columns, freeze panes, zoom (pinch, ⌘-scroll or the status bar slider), gridlines and headings toggles, light and dark mode.
- **Formulas.** Over 300 Excel functions across math, statistics, logic, text, dates, lookup and finance — including `XLOOKUP`, `FILTER`, `SORT`, `UNIQUE`, `SEQUENCE`, `LET`, `IFS`, `SUMIFS`, `TEXTJOIN`, `PMT` and `IRR`. Dynamic arrays spill into neighboring cells (with `#SPILL!` when blocked), array arithmetic, cross-sheet references, defined names, circular-reference detection and Excel's error values.
- **Formula editing.** In-cell editor mirrored in the formula bar; click or arrow-key cells to insert references while typing, with each reference colored in the text and outlined on the grid. F4 / ⌘T cycles `$A$1`→`A$1`→`$A1`→`A1`. Function suggestions and argument hints appear as you type; Insert Function browses them all.
- **Data entry like Excel.** Typing `12%`, `$1,200`, `3/15/2026`, `9:30 PM` or `1 1/2` stores a number and picks the format. AutoComplete from the column, ⌘Return fills the selection, Option-Return adds a line break.
- **Editing.** Multi-range selection, the fill handle (number and date series, weekdays, months, "Item 1…", formulas with shifted references), drag to move cells (Option to copy), cut/copy/paste with formula adjustment, Paste Special (values, formats, transposed, formulas, links, column widths), insert/delete rows, columns and cells with every formula in the workbook updated, full undo.
- **Formatting.** Fonts, sizes, bold/italic/underline/strikethrough, text and fill colors, borders, alignment, wrap, indent, rotation, merge & center, Format Painter, cell styles and Format as Table. Number formats understand Excel format codes: sections, colors, conditions, thousands scaling, fractions, scientific, text and date/time tokens, and Accounting's pinned currency symbol.
- **Conditional formatting.** Highlight rules, top/bottom, above/below average, duplicates, formula rules, color scales, data bars and icon sets.
- **Data tools.** Sort (multi-level), AutoFilter with value checklists and conditions, Remove Duplicates, Text to Columns, Find & Replace across the workbook, Go To (Special), status bar sum/average/count.
- **Charts.** Column, stacked column, bar, line, area, pie, doughnut and scatter, drawn live from their data with nice axes, legends and palettes. Drag to move, drag handles to resize, double-click to edit.
- **Sheets.** Add, rename (double-click the tab), duplicate, reorder by dragging, delete and color tabs; formulas follow renames.
- **Files.** `.grid` (native), Excel `.xlsx` (values, formulas with cached results, styles, widths, heights, merges, frozen panes, filters, conditional formats, names), CSV and TSV. PDF export and printing with page breaks on row/column boundaries.
- **Templates.** Monthly Budget, Invoice, Loan Calculator, Gradebook, Project Tracker and Sales Dashboard, with live previews in the chooser.

## Architecture

```
WiredGrid/
  Model/        CellAddress/CellRange, CellValue, CellStyle, Sheet, Workbook, conditional formats, charts, tables
  Formula/      Lexer, parser (Excel precedence), Calculator (recalculation, spills, cycles), function library,
                number formats, input parsing, date serials, reference rewriting
  Engine/       WorkbookController (the model + selection + every command, all undoable), AutoFill,
                clipboard, sorting/filtering, conditional formatting evaluation
  Grid/         GridView (drawing + input), geometry, cell renderer, editing session, function hints,
                filter popover, container (scrolling, notes, context menus)
  Charts/       Chart renderer (Core Graphics) and the floating chart views
  Persistence/  .grid, .xlsx (reader and writer), CSV/TSV, ZIP
  Window/       Window controller, workbook view controller (layout, menu actions, dialogs)
  UI/           Ribbon, formula bar, sheet tabs, status bar, dialogs, theme
  Print/        Paginated sheet rendering for printing and PDF
  Templates/    Template library and chooser
WiredGridTests/ Formula engine, number formats, input parsing, editing commands and file round-trips
cross-platform/
  src/          The same layers in TypeScript (model, formula, engine, formats, charts, grid on <canvas>, ui)
  src-tauri/    The Rust shell: file access, the workbook passed on the command line, installers
  tests/        Formula engine, .grid compatibility with the Mac app, xlsx/CSV round-trips
```

### Key decisions

- **The grid draws itself.** `GridView` sits over an `NSScrollView` that only provides native scrolling and scrollbars. The view reads the scroll offset and draws just the visible cells, so headers and frozen panes stay fixed and sheet size costs nothing. Row and column positions use a binary search over the few custom sizes.
- **One model, value-typed.** `Workbook` is a struct; every edit goes through `WorkbookController.change(_:_:)`, which snapshots the workbook for undo, applies the change, recalculates and notifies views.
- **Full recalculation, done carefully.** After each change the calculator evaluates every formula in row-major order (so top-down chains resolve iteratively) on a thread with a large stack (so long bottom-up chains can't overflow). A second pass settles dynamic-array spills whose shape changed.
- **Formulas stay text.** Formulas are stored as Excel-compatible text and rewritten token-by-token when rows move, sheets are renamed or cells are copied, so `.xlsx` files carry them directly.

## Known limitations

- No pivot tables, macros, data validation, sparklines or R1C1 references.
- Charts aren't exported to `.xlsx` (they're kept in `.grid` files).
- Point-and-click references to other sheets while editing aren't supported yet; type `Sheet2!A1` instead.
- On Windows and Linux, PDF export goes through the print dialog (choose a print-to-PDF printer).
