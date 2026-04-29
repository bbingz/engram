// macos/Engram/Components/SharedPickers.swift
// Shared views extracted from SessionListView — used by TimelineView, FavoritesView, etc.
import SwiftUI

struct MultiSelectPicker: View {
    let emptyLabel: LocalizedStringKey
    let icon: String
    let items: [String]
    @Binding var selected: Set<String>
    var colorForItem: ((String) -> Color)? = nil
    var labelForItem: ((String) -> String)? = nil
    @State private var showPopover = false

    var isFiltered: Bool { !selected.isEmpty }

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(isFiltered ? Color.accentColor : Color.secondary)
                buttonText
                    .lineLimit(1)
                    .foregroundStyle(isFiltered ? Color.accentColor : Color.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(isFiltered
                ? Color.accentColor.opacity(0.12)
                : Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            pickerPopover
        }
    }

    @ViewBuilder
    private var buttonText: some View {
        switch selected.count {
        case 0:  Text(emptyLabel)
        case 1:
            let item = selected.first!
            Text(verbatim: labelForItem?(item) ?? item)
        default: Text("\(selected.count) selected")
        }
    }

    private var pickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isFiltered {
                Button {
                    selected = []
                } label: {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Clear Filter")
                    }
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
            }
            if items.isEmpty {
                Text("No items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(items, id: \.self) { item in
                            let isSelected = selected.contains(item)
                            Button {
                                if isSelected { selected.remove(item) } else { selected.insert(item) }
                            } label: {
                                HStack(spacing: 8) {
                                    if let colorFn = colorForItem {
                                        Circle()
                                            .fill(colorFn(item))
                                            .frame(width: 8, height: 8)
                                    }
                                    Text(verbatim: labelForItem?(item) ?? item)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(Color.accentColor)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(isSelected
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 200)
    }
}

struct SessionRow: View {
    let session: Session

    private var sourceColor: Color { SourceDisplay.color(for: session.source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text(verbatim: session.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if session.sizeCategory != .normal {
                    HStack(spacing: 2) {
                        if session.sizeCategory == .huge {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                        }
                        Text(session.formattedSize)
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .foregroundStyle(session.sizeCategory == .huge ? .red : .orange)
                }
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(sourceColor)
                    .frame(width: 7, height: 7)
                Text(verbatim: session.project ?? "\u{2014}")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if session.isSubAgent {
                    Text("agent")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }
                Spacer(minLength: 4)
                Text(verbatim: SourceDisplay.label(for: session.source))
                    .font(.caption)
                    .foregroundStyle(sourceColor)
                Text(verbatim: session.displayDate)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 4) {
                Text(session.msgCountLabel)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }
}

struct GroupHeader: View {
    let title: String
    let count: Int
    let icon: String
    let lastUpdated: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(verbatim: title)
                .fontWeight(.medium)
            Spacer()
            Text("\(count)")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            Text(lastUpdated)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
