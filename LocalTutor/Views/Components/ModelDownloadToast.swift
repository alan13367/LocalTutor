//
//  ModelDownloadToast.swift
//  LocalTutor
//

import SwiftUI

struct ModelDownloadToast: View {
    let status: ModelDownloadStatus
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(iconBackground)
                    .frame(width: 34, height: 34)
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status.profileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if status.phase == .ready || status.phase == .failed {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Dismiss")
                    }
                }

                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if status.phase != .ready && status.phase != .failed {
                    HStack(spacing: 8) {
                        DownloadProgressMeter(fraction: status.fraction)
                        Text(progressLabel)
                            .font(.caption2.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 310)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var iconName: String {
        switch status.phase {
        case .checking, .loading:
            "cpu"
        case .downloading:
            "arrow.down.circle.fill"
        case .ready:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch status.phase {
        case .ready:
            .green
        case .failed:
            .orange
        default:
            .accentColor
        }
    }

    private var iconBackground: Color {
        iconColor.opacity(0.15)
    }

    private var progressLabel: String {
        guard let fraction = status.fraction else {
            return "..."
        }
        return DownloadProgressUpdate.percentText(for: fraction)
    }
}
