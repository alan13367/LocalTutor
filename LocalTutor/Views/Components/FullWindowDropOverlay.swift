//
//  FullWindowDropOverlay.swift
//  LocalTutor
//

import SwiftUI

struct FullWindowDropOverlay: View {
    var isActive: Bool

    var body: some View {
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: 0)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Color.accentColor.opacity(0.06)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(
                                Color.accentColor.opacity(0.7),
                                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                            )
                            .padding(16)
                    )

                VStack(spacing: 14) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 56, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.bounce, value: isActive)
                    Text("Drop to add as sources")
                        .font(.title2.weight(.semibold))
                    Text("PDFs, Word, PowerPoint, Excel, text, and screenshots")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(28)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.thickMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 10)
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.18), value: isActive)
    }
}
