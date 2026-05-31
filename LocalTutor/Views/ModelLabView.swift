//
//  ModelLabView.swift
//  LocalTutor
//
//

import SwiftUI
import UniformTypeIdentifiers

struct ModelLabView: View {
    @StateObject private var viewModel = ModelLabViewModel()
    @State private var isImportingImage = false
    @State private var isExportingBenchmark = false
    @State private var exportDocument = BenchmarkExportDocument(data: Data())

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    promptEditor
                    imagePicker
                    actionBar
                    outputPanel
                    metricsPanel
                }
                .padding(24)
                .frame(maxWidth: 1120, alignment: .leading)
            }
            .background(.background)
        }
        .fileImporter(isPresented: $isImportingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                viewModel.setImageURL(url)
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExportingBenchmark,
            document: exportDocument,
            contentType: .json,
            defaultFilename: viewModel.exportFilename
        ) { result in
            if case .failure(let error) = result {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }

    private var sidebar: some View {
        List(selection: $viewModel.selectedProfileID) {
            Section("Profiles") {
                ForEach(viewModel.profiles) { profile in
                    ProfileRow(profile: profile)
                        .tag(profile.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Model Lab")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.selectedProfile.name)
                        .font(.title2.weight(.semibold))
                    Text(viewModel.selectedProfile.subtitle)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(viewModel.selectedProfile.modelIdentifier)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Label(viewModel.selectedProfile.tierLabel, systemImage: "memorychip")
                Label(viewModel.selectedProfile.kind.rawValue.capitalized, systemImage: "eye")
                Label("Needs \(viewModel.selectedProfile.minimumSystemMemoryDescription) Mac", systemImage: "gauge.with.dots.needle.33percent")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            StatusStrip(preflight: viewModel.currentPreflight)
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt")
                .font(.headline)

            TextEditor(text: $viewModel.prompt)
                .font(.body.monospaced())
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator.opacity(0.45))
                }
        }
    }

    private var imagePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional Image")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    isImportingImage = true
                } label: {
                    Label("Choose Image", systemImage: "photo")
                }

                if let selectedImageURL = viewModel.selectedImageURL {
                    Text(selectedImageURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)

                    Button {
                        viewModel.setImageURL(nil)
                    } label: {
                        Label("Remove", systemImage: "xmark.circle")
                    }
                    .labelStyle(.iconOnly)
                    .help("Remove image")
                } else {
                    Text("Text-only prompts use the same Gemma 4 VLM path.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    viewModel.runSelectedProfile()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!viewModel.canRun)

                Button {
                    viewModel.cancelRun()
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .disabled(!viewModel.isRunning)

                Divider()
                    .frame(height: 18)

                Button {
                    viewModel.unloadModel()
                } label: {
                    Label("Unload", systemImage: "eject")
                }

                Button {
                    viewModel.clearCache()
                } label: {
                    Label("Clear Cache", systemImage: "trash")
                }

                Button {
                    if let record = viewModel.latestRecord {
                        exportDocument = BenchmarkExportDocument(record: record)
                        isExportingBenchmark = true
                    }
                } label: {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(viewModel.latestRecord == nil)
            }

            HStack(spacing: 10) {
                if viewModel.isDownloading {
                    DownloadProgressMeter(fraction: viewModel.downloadProgress)
                        .frame(width: 180)
                } else if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(viewModel.statusMessage)
                    .foregroundStyle(.secondary)

                if let latestRecordURL = viewModel.latestRecordURL {
                    Text(latestRecordURL.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
    }

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output")
                .font(.headline)

            ScrollView {
                Text(viewModel.output.isEmpty ? "Run a profile to stream output here." : viewModel.output)
                    .font(.body)
                    .foregroundStyle(viewModel.output.isEmpty ? .tertiary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 240)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.45))
            }
        }
    }

    private var metricsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metrics")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                if let record = viewModel.latestRecord {
                    MetricRow("Status", record.status.rawValue)
                    MetricRow("Download", record.timing.downloadSeconds.formattedSeconds)
                    MetricRow("Load", record.timing.loadSeconds.formattedSeconds)
                    MetricRow("First Token", record.timing.firstTokenSeconds?.formattedSeconds ?? "n/a")
                    MetricRow("Wall", record.timing.wallSeconds.formattedSeconds)
                    MetricRow("Prompt Tokens", record.tokenMetrics.promptTokens?.formatted() ?? "n/a")
                    MetricRow("Generated Tokens", record.tokenMetrics.generatedTokens?.formatted() ?? "n/a")
                    MetricRow("Tokens/sec", record.tokenMetrics.tokensPerSecond?.formatted(.number.precision(.fractionLength(2))) ?? "n/a")
                    MetricRow("Peak Footprint", record.processPeakPhysicalFootprintBytes?.gibibytesDescription ?? "n/a")
                    MetricRow("MLX Peak", record.mlxMemoryAfter?.peakBytes.gibibytesDescription ?? "n/a")
                } else {
                    MetricRow("Status", "No run yet")
                    MetricRow("System RAM", SystemMemory.totalBytes().gibibytesDescription)
                    MetricRow("Available", SystemMemory.availableBytes().gibibytesDescription)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator.opacity(0.45))
            }
        }
    }
}

private struct ProfileRow: View {
    var profile: ModelProfile

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                Text(profile.tierLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "memorychip")
        }
    }
}

private struct StatusStrip: View {
    var preflight: MemoryPreflightResult

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: preflight.canRun ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(preflight.canRun ? .green : .orange)
            Text(preflight.message)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MetricRow: View {
    var title: String
    var value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private extension Double {
    var formattedSeconds: String {
        formatted(.number.precision(.fractionLength(2))) + "s"
    }
}

#Preview {
    ModelLabView()
}
