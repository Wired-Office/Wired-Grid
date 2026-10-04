import SwiftUI

/// The AutoFilter dropdown: sort, search and a checklist of values.
struct FilterPopoverView: View {
    let controller: WorkbookController
    let column: Int
    let dismiss: () -> Void

    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var values: [(text: String, count: Int)] = []
    @State private var conditionKind = 0
    @State private var conditionValue = ""

    private var filtered: [(text: String, count: Int)] {
        search.isEmpty ? values : values.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { sort(true) } label: { Label("Sort A → Z", systemImage: "arrow.up") }
                Button { sort(false) } label: { Label("Sort Z → A", systemImage: "arrow.down") }
            }
            .controlSize(.small)

            Divider()

            HStack {
                Picker("", selection: $conditionKind) {
                    Text("Values").tag(0)
                    Text("Greater than").tag(1)
                    Text("Less than").tag(2)
                    Text("Contains").tag(3)
                    Text("Top 10").tag(4)
                    Text("Above average").tag(5)
                }
                .labelsHidden()
                .frame(width: 140)
                if conditionKind >= 1 && conditionKind <= 3 {
                    TextField("Value", text: $conditionValue)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if conditionKind == 0 {
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
                List {
                    Toggle(isOn: Binding(
                        get: { filtered.allSatisfy { selected.contains($0.text) } },
                        set: { on in
                            for item in filtered { if on { selected.insert(item.text) } else { selected.remove(item.text) } }
                        }
                    )) {
                        Text("(Select All)").fontWeight(.medium)
                    }
                    ForEach(filtered, id: \.text) { item in
                        Toggle(isOn: Binding(
                            get: { selected.contains(item.text) },
                            set: { on in if on { selected.insert(item.text) } else { selected.remove(item.text) } }
                        )) {
                            HStack {
                                Text(item.text.isEmpty ? "(Blanks)" : item.text).lineLimit(1)
                                Spacer()
                                Text("\(item.count)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .frame(height: 220)
            }

            HStack {
                Button("Clear Filter") {
                    controller.setFilterCriterion(nil, column: column)
                    dismiss()
                }
                .disabled(controller.sheet.filter?.criteria[column] == nil)
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear(perform: load)
    }

    private func load() {
        values = controller.filterValues(column: column)
        switch controller.sheet.filter?.criteria[column] {
        case .values(let allowed)?:
            selected = allowed
        case .condition(let rule)?:
            selected = Set(values.map(\.text))
            switch rule {
            case .greaterThan(let v): conditionKind = 1; conditionValue = NumberFormat.general(v)
            case .lessThan(let v): conditionKind = 2; conditionValue = NumberFormat.general(v)
            case .textContains(let t): conditionKind = 3; conditionValue = t
            case .top: conditionKind = 4
            case .aboveAverage: conditionKind = 5
            default: break
            }
        case nil:
            selected = Set(values.map(\.text))
        }
    }

    private func sort(_ ascending: Bool) {
        guard let filter = controller.sheet.filter else { return }
        controller.sort(filter.range, keys: [SortKey(column: column, ascending: ascending)], hasHeader: true)
        dismiss()
    }

    private func apply() {
        let criterion: FilterCriterion?
        switch conditionKind {
        case 1: criterion = Double(conditionValue).map { .condition(.greaterThan($0)) }
        case 2: criterion = Double(conditionValue).map { .condition(.lessThan($0)) }
        case 3: criterion = conditionValue.isEmpty ? nil : .condition(.textContains(conditionValue))
        case 4: criterion = .condition(.top(10, percent: false))
        case 5: criterion = .condition(.aboveAverage)
        default: criterion = selected.count == values.count ? nil : .values(selected)
        }
        if case .condition(let rule)? = criterion, [4, 5].contains(conditionKind) {
            // Rules that need column statistics are resolved to the matching values now.
            let data = controller.sheet.filter?.dataRows.map { rows in rows.map { controller.value(at: CellAddress(row: $0, column: column)) } } ?? []
            let stats = ConditionalStats(values: data)
            var allowed = Set<String>()
            for row in controller.sheet.filter?.dataRows ?? 0...0 {
                let address = CellAddress(row: row, column: column)
                let v = controller.value(at: address)
                if ConditionalEvaluator.matches(rule, value: v, stats: stats) { allowed.insert(controller.displayText(at: address)) }
            }
            controller.setFilterCriterion(.values(allowed), column: column)
        } else {
            controller.setFilterCriterion(criterion, column: column)
        }
        dismiss()
    }
}
