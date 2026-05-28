//
//  StudyWorkspaceView.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct StudyWorkspaceView: View {
    @StateObject private var viewModel = StudyWorkspaceViewModel()
    @State private var isImportingSources = false
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    sourceIntake
                    resourcePicker
                    studyGoal
                    outputArea
                }
                .padding(28)
                .frame(maxWidth: 1160, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("LocalTutor")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isImportingSources = true
                } label: {
                    Label("Add Sources", systemImage: "plus")
                }

                Button {
                    viewModel.generate()
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canGenerate)

                Button {
                    viewModel.cancel()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .disabled(!viewModel.isRunning)
            }
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
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private var sidebar: some View {
        List {
            Section("Session") {
                Label("Workspace", systemImage: "square.grid.2x2")
                Label(viewModel.sourceSummary, systemImage: "tray.full")
            }

            Section("Sources") {
                if viewModel.sources.isEmpty {
                    Text("No sources")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.sources.prefix(8)) { source in
                        Label {
                            Text(source.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: source.kind.systemImage)
                        }
                    }

                    if viewModel.sources.count > 8 {
                        Text("+ \(viewModel.sources.count - 8) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Model") {
                VStack(alignment: .leading, spacing: 6) {
                    Label(viewModel.activeProfile.name, systemImage: "memorychip")
                    Text(viewModel.activeProfile.studyTierLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(SystemMemory.totalBytes().gibibytesDescription)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Button {
                    viewModel.unloadModel()
                } label: {
                    Label("Unload", systemImage: "eject")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("LocalTutor")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Study Session")
                        .font(.largeTitle.weight(.semibold))
                    Text("Local model: \(viewModel.activeProfile.name)")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ModelReadinessPill(preflight: viewModel.preflight)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var sourceIntake: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Sources", detail: viewModel.sourceSummary)

            StudyDropZone(isTargeted: isDropTargeted) {
                isImportingSources = true
            }
            .onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $isDropTargeted,
                perform: viewModel.importFromDropProviders
            )

            if !viewModel.sources.isEmpty {
                VStack(spacing: 0) {
                    ForEach(viewModel.sources) { source in
                        SourceRow(source: source) {
                            viewModel.removeSource(source)
                        }

                        if source.id != viewModel.sources.last?.id {
                            Divider()
                        }
                    }
                }
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.45))
                }

                Button {
                    viewModel.clearSources()
                } label: {
                    Label("Clear Sources", systemImage: "trash")
                }
                .controlSize(.small)
            }
        }
    }

    private var resourcePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Create", detail: viewModel.selectedResource.title)

            Picker("Create", selection: $viewModel.selectedResource) {
                ForEach(StudyResourceKind.allCases) { resource in
                    Label(resource.title, systemImage: resource.systemImage)
                        .tag(resource)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var studyGoal: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Focus", detail: "What should LocalTutor help with?")

            TextEditor(text: $viewModel.studyGoal)
                .font(.body)
                .frame(minHeight: 112)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.45))
                }
        }
    }

    private var outputArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionHeader(title: "Tutor Output", detail: viewModel.statusMessage)

                Spacer()

                if viewModel.isDownloading {
                    DownloadProgressMeter(fraction: viewModel.downloadProgress)
                        .frame(width: 180)
                } else if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                Text(viewModel.output.isEmpty ? "Generated study material appears here." : viewModel.output)
                    .foregroundStyle(viewModel.output.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
                    .padding(14)
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.45))
            }
        }
    }
}

private struct SectionHeader: View {
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ModelReadinessPill: View {
    var preflight: MemoryPreflightResult

    var body: some View {
        Label(preflight.canRun ? "Ready" : "Model unavailable", systemImage: preflight.canRun ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(preflight.canRun ? .green : .orange)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(.thinMaterial, in: Capsule())
            .help(preflight.message)
    }
}

private struct StudyDropZone: View {
    var isTargeted: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.title2)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Drop study files here")
                        .font(.headline)
                    Text("PDF, Word, PowerPoint, Excel, text, and screenshots")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(isTargeted ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, dash: [6, 5]))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SourceRow: View {
    var source: StudySource
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(source.kind.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: remove) {
                Label("Remove", systemImage: "xmark.circle.fill")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
    }
}

private extension InferenceProfile {
    var studyTierLabel: String {
        switch tier {
        case .eightGB:
            "8GB baseline"
        case .sixteenGB:
            "16GB tier"
        }
    }
}

#Preview {
    StudyWorkspaceView()
}
