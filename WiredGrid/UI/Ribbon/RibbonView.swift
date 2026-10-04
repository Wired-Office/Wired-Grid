import AppKit
import SwiftUI

/// The Excel-style ribbon: a row of tabs over the selected tab's commands.
/// Double-click a tab (or use the chevron) to collapse it to just the tabs.
struct RibbonView: View {
    @ObservedObject var model: RibbonModel
    @ObservedObject var controller: WorkbookController

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            if !model.isCollapsed {
                ScrollView(.horizontal, showsIndicators: false) {
                    content
                        .padding(.horizontal, 10)
                        .frame(height: RibbonModel.contentHeight, alignment: .center)
                }
                .frame(height: RibbonModel.contentHeight)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: Theme.barBackground))
    }

    private var tabStrip: some View {
        HStack(spacing: 2) {
            ForEach(RibbonModel.Tab.allCases) { tab in
                RibbonTabButton(title: tab.title, isSelected: model.tab == tab && !model.isCollapsed) {
                    if model.tab == tab && !model.isCollapsed { return }
                    model.tab = tab
                    if model.isCollapsed { model.isCollapsed = false }
                } onDoubleClick: {
                    model.tab = tab
                    model.isCollapsed.toggle()
                }
            }
            if let chartID = controller.selectedChartID, let chart = controller.sheet.charts.first(where: { $0.id == chartID }) {
                Text("Chart")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accentColor)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentColor.opacity(0.12)))
                    .onTapGesture { controller.presenter?.presentChartEditor(chart) }
                    .help("Edit the selected chart")
            }
            Spacer(minLength: 8)
            Button {
                model.isCollapsed.toggle()
            } label: {
                Image(systemName: model.isCollapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(RibbonButtonStyle())
            .help(model.isCollapsed ? "Show the Ribbon" : "Collapse the Ribbon")
        }
        .padding(.horizontal, 12)
        .frame(height: RibbonModel.tabHeight)
    }

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .home: HomeTab(controller: controller)
        case .insert: InsertTab(controller: controller)
        case .pageLayout: PageLayoutTab(controller: controller)
        case .formulas: FormulasTab(controller: controller)
        case .data: DataTab(controller: controller)
        case .review: ReviewTab(controller: controller)
        case .view: ViewTab(controller: controller)
        }
    }
}

private struct RibbonTabButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    let onDoubleClick: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.78))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering && !isSelected ? Color.primary.opacity(0.07) : .clear)
            )
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(isSelected ? Theme.accentColor : .clear)
                    .frame(height: 3)
                    .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleClick)
            .onTapGesture(count: 1, perform: action)
            .onHover { hovering = $0 }
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

/// A small caption under a ribbon group.
struct RibbonCaption: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }
}

/// A group with its caption underneath, like Excel's.
struct CaptionedGroup<Content: View>: View {
    let title: String
    var showsDivider = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 3) {
                HStack(alignment: .center, spacing: 2) { content() }
                    .frame(maxHeight: .infinity)
                RibbonCaption(title: title)
            }
            .padding(.vertical, 4)
            if showsDivider {
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 1, height: 70)
                    .padding(.horizontal, 7)
            }
        }
    }
}
