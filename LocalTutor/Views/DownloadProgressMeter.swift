//
//  DownloadProgressMeter.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import SwiftUI

struct DownloadProgressMeter: View {
    var fraction: Double?

    @State private var animateIndeterminate = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fillWidth = fillWidth(for: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.secondary.opacity(0.18))

                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: fillWidth)
                    .offset(x: indeterminateOffset(width: width, fillWidth: fillWidth))
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .accessibilityLabel("Download progress")
        .accessibilityValue(accessibilityValue)
        .onAppear {
            animateIndeterminate = fraction == nil
        }
        .onChange(of: fraction == nil) { _, isIndeterminate in
            animateIndeterminate = isIndeterminate
        }
        .animation(
            fraction == nil
                ? .linear(duration: 1.15).repeatForever(autoreverses: false)
                : .easeOut(duration: 0.18),
            value: animateIndeterminate
        )
        .animation(.easeOut(duration: 0.18), value: fraction)
    }

    private var clampedFraction: Double? {
        fraction.map { max(0, min(1, $0)) }
    }

    private var accessibilityValue: String {
        guard let clampedFraction else {
            return "In progress"
        }

        return "\(Int((clampedFraction * 100).rounded())) percent"
    }

    private func fillWidth(for width: CGFloat) -> CGFloat {
        if let clampedFraction {
            return max(2, width * CGFloat(clampedFraction))
        }

        return max(32, width * 0.28)
    }

    private func indeterminateOffset(width: CGFloat, fillWidth: CGFloat) -> CGFloat {
        guard fraction == nil else {
            return 0
        }

        return animateIndeterminate ? width : -fillWidth
    }
}

#Preview {
    VStack(spacing: 14) {
        DownloadProgressMeter(fraction: nil)
            .frame(width: 220)
        DownloadProgressMeter(fraction: 0.42)
            .frame(width: 220)
    }
    .padding()
}
