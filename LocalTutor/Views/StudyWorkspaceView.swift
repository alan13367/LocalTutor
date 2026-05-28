//
//  StudyWorkspaceView.swift
//  LocalTutor
//
//

import SwiftUI
import UniformTypeIdentifiers

struct StudyWorkspaceView: View {
    @StateObject private var viewModel = StudyWorkspaceViewModel()
    @State private var isImportingSources = false
    @State private var isDropTargeted = false
    @State private var isShowingSettings = false

    var body: some View {
        NavigationSplitView {
            StudySidebar(
                viewModel: viewModel,
                onAttach: { isImportingSources = true },
                onOpenSettings: { isShowingSettings = true }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detailSurface
        }
        .navigationTitle("LocalTutor")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isImportingSources = true
                } label: {
                    Label("Add sources", systemImage: "paperclip")
                }
                .help("Attach files")

                Button(role: .destructive) {
                    viewModel.clearTranscript()
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                }
                .disabled(viewModel.turns.isEmpty || viewModel.isRunning)
                .help("Start a fresh session")

                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                }
                .help("Settings and models")
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .fileImporter(
            isPresented: $isImportingSources,
            allowedContentTypes: StudySource.supportedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                viewModel.importURLs(urls)
            case .failure(let error):
                viewModel.globalError = error.localizedDescription
            }
        }
    }

    private var detailSurface: some View {
        ZStack(alignment: .bottom) {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if let error = viewModel.globalError {
                    GlobalErrorBanner(message: error) {
                        viewModel.globalError = nil
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                StudyTranscriptView(viewModel: viewModel, onAttach: { isImportingSources = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                StudyComposer(viewModel: viewModel, onAttach: { isImportingSources = true })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 18)
                    .padding(.top, 6)
                    .frame(maxWidth: 920)
                    .frame(maxWidth: .infinity)
            }
        }
        .overlay(FullWindowDropOverlay(isActive: isDropTargeted))
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isDropTargeted,
            perform: viewModel.importFromDropProviders
        )
        .animation(.easeOut(duration: 0.2), value: viewModel.turns.count)
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .windowBackgroundColor).opacity(0.85)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Sidebar

private struct StudySidebar: View {
    @ObservedObject var viewModel: StudyWorkspaceViewModel
    var onAttach: () -> Void
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.16))
                                .frame(width: 30, height: 30)
                            Image(systemName: "graduationcap.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Study Session")
                                .font(.headline)
                            Text(viewModel.activeProfile.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section("Sources") {
                    if viewModel.sources.isEmpty {
                        Button(action: onAttach) {
                            Label("Add files", systemImage: "plus")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ForEach(viewModel.sources) { source in
                            HStack(spacing: 8) {
                                Image(systemName: source.kind.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(source.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button {
                                    viewModel.removeSource(source)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Button(role: .destructive) {
                            viewModel.clearSources()
                        } label: {
                            Label("Clear all", systemImage: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                if !viewModel.turns.isEmpty {
                    Section("This session") {
                        ForEach(viewModel.turns) { turn in
                            HStack(spacing: 8) {
                                Image(systemName: turn.user.resourceKind.systemImage)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(turn.user.displayPrompt)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            modelFooter
        }
    }

    private var modelFooter: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.accentColor.opacity(0.16))
                        .frame(width: 34, height: 34)
                    Image(systemName: "cpu")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.activeProfile.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(viewModel.activeProfile.tierLabel) · \(SystemMemory.totalBytes().gibibytesDescription)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open settings and choose a model")
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

// MARK: - Global error banner

private struct GlobalErrorBanner: View {
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.7)
        )
    }
}

#Preview {
    StudyWorkspaceView()
        .frame(width: 1180, height: 760)
}
