import SwiftUI

/// Insert Function: search or browse by category, with syntax and description.
struct InsertFunctionSheet: View {
    let initialCategory: FunctionCategory?
    let dismiss: () -> Void
    let onInsert: (String) -> Void

    @State private var search = ""
    @State private var category: FunctionCategory?
    @State private var selection: String?

    private var functions: [FunctionSpec] {
        let library = FunctionLibrary.shared
        var list = category.map { library.functions(in: $0) } ?? library.sortedNames.compactMap { library.function(named: $0) }
        if !search.isEmpty {
            let query = search.lowercased()
            list = list.filter { $0.name.lowercased().contains(query) || $0.summary.lowercased().contains(query) }
                .sorted { a, b in
                    let pa = a.name.lowercased().hasPrefix(query), pb = b.name.lowercased().hasPrefix(query)
                    return pa != pb ? pa : a.name < b.name
                }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Insert Function", systemImage: "function").font(.headline)
                Spacer()
                Text("\(FunctionLibrary.shared.functions.count) functions").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Search for a function", text: $search).textFieldStyle(.roundedBorder)
                Picker("", selection: $category) {
                    Text("All").tag(FunctionCategory?.none)
                    Divider()
                    ForEach(FunctionCategory.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            List(functions, id: \.name, selection: $selection) { spec in
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name).font(.system(.body, design: .monospaced)).fontWeight(.semibold)
                    Text(spec.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.vertical, 2)
                .tag(spec.name)
                .onTapGesture(count: 2) { insert(spec.name) }
                .onTapGesture { selection = spec.name }
            }
            .frame(height: 260)
            if let name = selection, let spec = FunctionLibrary.shared.function(named: name) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(spec.syntax).font(.system(.callout, design: .monospaced)).fontWeight(.medium).textSelection(.enabled)
                    Text(spec.summary).font(.callout).foregroundStyle(.secondary)
                    Text(spec.category.rawValue).font(.caption).foregroundStyle(Theme.accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Insert") { if let selection { insert(selection) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { category = initialCategory }
    }

    private func insert(_ name: String) {
        dismiss()
        onInsert(name)
    }
}

/// Help ▸ Function Reference: every function by category.
struct FunctionReferenceView: View {
    @State private var search = ""
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(FunctionCategory.allCases) { category in
                    let items = FunctionLibrary.shared.functions(in: category).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.summary.localizedCaseInsensitiveContains(search) }
                    if !items.isEmpty {
                        Section(category.rawValue) {
                            ForEach(items, id: \.name) { Text($0.name).font(.system(.body, design: .monospaced)).tag($0.name) }
                        }
                    }
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(220)
        } detail: {
            if let name = selection, let spec = FunctionLibrary.shared.function(named: name) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(spec.name).font(.system(size: 26, weight: .bold, design: .monospaced))
                    Text(spec.category.rawValue).foregroundStyle(Theme.accentColor)
                    Text(spec.syntax).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    Text(spec.summary).font(.title3)
                    if !spec.parameters.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Arguments").font(.headline)
                            ForEach(spec.parameters, id: \.self) { parameter in
                                Text("• " + parameter + (parameter.hasPrefix("[") ? "  (optional)" : "")).font(.system(.body, design: .monospaced))
                            }
                        }
                    }
                    Spacer()
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Choose a function").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}
