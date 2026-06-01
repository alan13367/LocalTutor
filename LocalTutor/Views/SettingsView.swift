//
//  SettingsView.swift
//  LocalTutor
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: StudyWorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    private var systemMemory: UInt64 {
        SystemMemory.totalBytes()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    machineCard
                    modelsSection
                    aboutSection
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 700)
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                if let status = viewModel.modelDownloadStatus {
                    ModelDownloadToast(status: status) {
                        viewModel.dismissModelDownloadStatus()
                    }
                    .padding(20)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: viewModel.modelDownloadStatus != nil)
        }
        .onAppear {
            viewModel.refreshModelCacheInfo()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: 38, height: 38)
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Text("Choose your local tutor model")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var machineCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: 44, height: 44)
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("This Mac")
                    .font(.headline)
                Text("\(systemMemory.gibibytesDescription) unified memory · \(SystemInfo.architecture)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            tierBadge
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var tierBadge: some View {
        let tier = systemMemory >= 16.gibibytes ? "16 GB tier" : "8 GB tier"
        return Text(tier)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
            .foregroundStyle(Color.accentColor)
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Models")
                    .font(.title3.weight(.semibold))
                Spacer()
                Label("Text / Vision · MLX format", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
            Text("LocalTutor ships Apple Silicon MLX models gated to your Mac's memory tier. Vision models can inspect images and figures; text-only models focus on readable source text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                ForEach(ModelProfile.studyCatalog) { profile in
                    ModelOptionRow(
                        profile: profile,
                        isSelected: profile.id == viewModel.selectedProfile?.id,
                        canRun: MemoryPreflight.evaluate(profile: profile, systemMemoryBytes: systemMemory).canRun,
                        cacheInfo: viewModel.cacheInfo(for: profile),
                        isRemovingDownload: viewModel.isRemovingCachedModel(profile),
                        canRemoveDownload: viewModel.canRemoveCachedModel(profile)
                    ) {
                        viewModel.setActiveProfile(profile)
                    } onRemoveDownload: {
                        viewModel.removeCachedModel(profile)
                    }
                }
            }
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About")
                .font(.title3.weight(.semibold))
            HStack {
                Label("LocalTutor", systemImage: "graduationcap.fill")
                    .foregroundStyle(.primary)
                Spacer()
                Text(AppInfo.version)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
    }
}

private struct ModelOptionRow: View {
    let profile: ModelProfile
    let isSelected: Bool
    let canRun: Bool
    let cacheInfo: ModelCacheInfo
    let isRemovingDownload: Bool
    let canRemoveDownload: Bool
    var onSelect: () -> Void
    var onRemoveDownload: () -> Void

    @State private var isShowingRemoveConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: {
                guard canRun else { return }
                onSelect()
            }) {
                HStack(alignment: .top, spacing: 14) {
                    radio
                    content
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canRun)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(canRun ? 1.0 : 0.55)

            cacheAction
        }
        .padding(16)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 1.4 : 0.5
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .help(canRun ? profile.summary : "Requires \(profile.minimumSystemMemoryDescription) of unified memory.")
        .confirmationDialog(
            "Remove \(profile.name)?",
            isPresented: $isShowingRemoveConfirmation
        ) {
            Button("Remove Download", role: .destructive) {
                onRemoveDownload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(cacheInfo.sizeDescription). The model will download again the next time you use it.")
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
    }

    private var radio: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.45), lineWidth: 1.5)
                .frame(width: 20, height: 20)
            if isSelected {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
            }
        }
        .padding(.top, 2)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.headline)
                if profile.isRecommended {
                    Text("Recommended")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(.green)
                }
                if !canRun {
                    Text("Needs \(profile.minimumSystemMemoryDescription)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.18)))
                        .foregroundStyle(.orange)
                }
                if cacheInfo.isCached {
                    Text("Downloaded · \(cacheInfo.sizeDescription)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(profile.tierLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(profile.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 14) {
                metaItem(icon: "building.2", text: profile.publisher)
                metaItem(icon: "cpu", text: profile.parameterScale)
                if profile.supportsVision {
                    metaItem(icon: "eye", text: "Vision")
                } else {
                    metaItem(icon: "text.alignleft", text: "Text-only")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !profile.strengths.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(profile.strengths, id: \.self) { strength in
                        Text(strength)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                }
            }
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text)
        }
    }

    @ViewBuilder
    private var cacheAction: some View {
        if isRemovingDownload {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
                .help("Removing downloaded files")
        } else if cacheInfo.isCached {
            Button {
                isShowingRemoveConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(canRemoveDownload ? .secondary : .tertiary)
            .disabled(!canRemoveDownload)
            .help(canRemoveDownload ? "Remove downloaded model files" : "Stop the current response before removing model files")
        }
    }
}
