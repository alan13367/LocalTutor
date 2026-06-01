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

                Button {
                    viewModel.newSession()
                } label: {
                    Label("New session", systemImage: "square.and.pencil")
                }
                .disabled(viewModel.isGenerating)
                .help("Start a new study session")
                .keyboardShortcut("n", modifiers: .command)

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
            allowedContentTypes: viewModel.supportedSourceContentTypes,
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
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                if let status = viewModel.modelDownloadStatus {
                    ModelDownloadToast(status: status) {
                        viewModel.dismissModelDownloadStatus()
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 116)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.18), value: viewModel.modelDownloadStatus != nil)
        }
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

    @State private var renamingSessionID: UUID?
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            sidebarHeader

            List {
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

                Section("History") {
                    ForEach(viewModel.sessions) { session in
                        SessionRow(
                            session: session,
                            isCurrent: session.id == viewModel.currentSessionID,
                            isRunning: session.id == viewModel.runningSessionID
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectSession(session.id)
                        }
                        .contextMenu {
                            Button {
                                renamingSessionID = session.id
                                renameDraft = session.derivedTitle
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                viewModel.deleteSession(session.id)
                            } label: {
                                Label("Delete session", systemImage: "trash")
                            }
                            .disabled(session.id == viewModel.runningSessionID)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .alert("Rename Session", isPresented: renameAlertIsPresented) {
                TextField("Name", text: $renameDraft)
                Button("Save") {
                    if let id = renamingSessionID {
                        viewModel.renameSession(id, to: renameDraft)
                    }
                    renamingSessionID = nil
                }
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {
                    renamingSessionID = nil
                }
            } message: {
                Text("Choose a name for this study session.")
            }

            Divider()
            modelFooter
        }
    }

    private var sidebarHeader: some View {
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
                Text("LocalTutor")
                    .font(.headline)
                Text("\(viewModel.sessions.count) session\(viewModel.sessions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                viewModel.newSession()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(viewModel.isGenerating ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            .disabled(viewModel.isGenerating)
            .help("New session (⌘N)")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
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
                    if let selectedProfile = viewModel.selectedProfile {
                        Text(selectedProfile.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("\(selectedProfile.tierLabel) · \(SystemMemory.totalBytes().gibibytesDescription)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Choose a model")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("No model selected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

    private var renameAlertIsPresented: Binding<Bool> {
        Binding(
            get: { renamingSessionID != nil },
            set: { if !$0 { renamingSessionID = nil } }
        )
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: StudySession
    let isCurrent: Bool
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCurrent ? "bubble.left.fill" : "bubble.left")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.derivedTitle)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
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
