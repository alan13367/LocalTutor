//
//  MindMapView.swift
//  LocalTutor
//

import SwiftUI

struct MindMapView: View {
    let root: MindMapNode
    var onAsk: (String) -> Void

    @State private var collapsed: Set<String> = []

    private static let columnWidth: CGFloat = 250
    private static let nodeWidth: CGFloat = 200
    private static let rowHeight: CGFloat = 46
    private static let padding: CGFloat = 32

    var body: some View {
        let layout = MindMapLayout(root: root, collapsed: collapsed)
        let size = CGSize(
            width: CGFloat(layout.depth + 1) * Self.columnWidth + Self.padding * 2,
            height: max(CGFloat(layout.rows) * Self.rowHeight + Self.padding * 2, 320)
        )
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for edge in layout.edges {
                        let start = point(for: edge.from, layout: layout, trailing: true)
                        let end = point(for: edge.to, layout: layout, trailing: false)
                        var path = Path()
                        path.move(to: start)
                        let midX = (start.x + end.x) / 2
                        path.addCurve(to: end, control1: CGPoint(x: midX, y: start.y), control2: CGPoint(x: midX, y: end.y))
                        context.stroke(path, with: .color(.accentColor.opacity(0.45)), lineWidth: 1.5)
                    }
                }
                .frame(width: size.width, height: size.height)

                ForEach(layout.placed, id: \.node.id) { placed in
                    MindMapNodeView(
                        node: placed.node,
                        level: placed.level,
                        isCollapsed: collapsed.contains(placed.node.id),
                        onToggle: { toggle(placed.node) },
                        onAsk: { onAsk(placed.node.title) }
                    )
                    .frame(width: Self.nodeWidth)
                    .position(center(for: placed))
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .background(.background.secondary)
        .overlay(alignment: .bottomTrailing) {
            Text("Click a branch to fold it · Right-click to ask about a topic")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(8)
                .glassEffect(.regular, in: .capsule)
                .padding(12)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mind map of \(root.title)")
        .onAppear {
            if MindMapLayout(root: root, collapsed: []).rows > 14 {
                collapsed = Set(root.children.filter { !$0.children.isEmpty }.map(\.id))
            }
        }
    }

    private func toggle(_ node: MindMapNode) {
        guard !node.children.isEmpty else { return }
        withAnimation(.snappy(duration: 0.25)) {
            if collapsed.contains(node.id) {
                collapsed.remove(node.id)
            } else {
                collapsed.insert(node.id)
            }
        }
    }

    private func center(for placed: MindMapLayout.Placed) -> CGPoint {
        CGPoint(
            x: Self.padding + CGFloat(placed.level) * Self.columnWidth + Self.nodeWidth / 2,
            y: Self.padding + placed.row * Self.rowHeight + Self.rowHeight / 2
        )
    }

    private func point(for id: String, layout: MindMapLayout, trailing: Bool) -> CGPoint {
        guard let placed = layout.placed.first(where: { $0.node.id == id }) else { return .zero }
        let center = center(for: placed)
        return CGPoint(x: center.x + (trailing ? Self.nodeWidth / 2 : -Self.nodeWidth / 2), y: center.y)
    }
}

struct MindMapLayout {
    struct Placed {
        var node: MindMapNode
        var level: Int
        var row: CGFloat
    }

    struct Edge {
        var from: String
        var to: String
    }

    private(set) var placed: [Placed] = []
    private(set) var edges: [Edge] = []
    private(set) var rows = 0
    private(set) var depth = 0

    init(root: MindMapNode, collapsed: Set<String>) {
        _ = place(root, level: 0, collapsed: collapsed)
    }

    private mutating func place(_ node: MindMapNode, level: Int, collapsed: Set<String>) -> CGFloat {
        depth = max(depth, level)
        let children = collapsed.contains(node.id) ? [] : node.children
        let row: CGFloat
        if children.isEmpty {
            row = CGFloat(rows)
            rows += 1
        } else {
            let childRows = children.map { place($0, level: level + 1, collapsed: collapsed) }
            row = ((childRows.first ?? 0) + (childRows.last ?? 0)) / 2
            for child in children {
                edges.append(Edge(from: node.id, to: child.id))
            }
        }
        placed.append(Placed(node: node, level: level, row: row))
        return row
    }
}

private struct MindMapNodeView: View {
    let node: MindMapNode
    let level: Int
    let isCollapsed: Bool
    var onToggle: () -> Void
    var onAsk: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Text(node.title)
                    .font(level == 0 ? .headline : (level == 1 ? .callout.weight(.semibold) : .callout))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !node.children.isEmpty {
                    Text(isCollapsed ? "\(node.children.count)" : "")
                        .font(.caption2.weight(.bold))
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.left")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(glass, in: .rect(cornerRadius: 10))
        .contextMenu {
            Button("Ask About \"\(node.title)\"", systemImage: "questionmark.bubble", action: onAsk)
        }
        .accessibilityLabel(node.title)
        .accessibilityHint(node.children.isEmpty ? "Right-click to ask about this topic" : (isCollapsed ? "Expand" : "Collapse"))
    }

    private var glass: Glass {
        switch level {
        case 0: .regular.tint(Color.accentColor.opacity(0.35)).interactive()
        case 1: .regular.tint(Color.accentColor.opacity(0.15)).interactive()
        default: .regular.interactive()
        }
    }
}
