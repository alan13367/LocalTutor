//
//  SourceChip.swift
//  LocalTutor
//

import AppKit
import SwiftUI

struct SourceChip: View {
    let source: StudySource
    var onRemove: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            thumbnail
            VStack(alignment: .leading, spacing: 0) {
                Text(source.displayName)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.kind.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 1 : 0.55)
                .help("Remove")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if source.isImage, let image = NSImage(contentsOf: source.url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 26, height: 26)
                Image(systemName: source.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
    }
}
