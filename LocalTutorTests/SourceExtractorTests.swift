//
//  SourceExtractorTests.swift
//  LocalTutorTests
//

import AppKit
import CoreGraphics
import Foundation
import Testing
import ZIPFoundation
@testable import LocalTutor

struct SourceExtractorTests {
    @Test
    func extractionPreservesAttachmentOrderAndConcatenatesText() async throws {
        let directory = try temporaryDirectory()
        let first = directory.appendingPathComponent("z-first.txt")
        let second = directory.appendingPathComponent("a-second.txt")
        try "First source".write(to: first, atomically: true, encoding: .utf8)
        try "Second source".write(to: second, atomically: true, encoding: .utf8)

        let extracted = await SourceExtractor.extract(
            [StudySource(url: first), StudySource(url: second)],
            options: SourceExtractionOptions(imageLimit: 0, imageResize: nil, minEmbeddedImageDimension: 64)
        )

        #expect(extracted.map(\.source.displayName) == ["z-first.txt", "a-second.txt"])
        #expect(extracted[0].text == "First source")
        #expect(extracted[1].text == "Second source")
    }

    @Test
    func standaloneImagesRespectGlobalCapButSmallAttachmentsAreNotDecorative() async throws {
        let directory = try temporaryDirectory()
        let urls = try (1...3).map { index in
            let url = directory.appendingPathComponent("image\(index).png")
            try pngData(size: CGSize(width: 24, height: 24)).write(to: url)
            return url
        }

        let extracted = await SourceExtractor.extract(
            urls.map(StudySource.init(url:)),
            options: SourceExtractionOptions(imageLimit: 2, imageResize: CGSize(width: 1024, height: 1024), minEmbeddedImageDimension: 64)
        )

        #expect(extracted.reduce(0) { $0 + $1.includedImageCount } == 2)
        #expect(extracted.reduce(0) { $0 + $1.omittedImageCount } == 1)
    }

    @Test
    func scannedPDFRendersPageImageInsteadOfFailing() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("scan.pdf")
        try scannedPDFData().write(to: url)

        let extracted = await SourceExtractor.extract(
            [StudySource(url: url)],
            options: SourceExtractionOptions(imageLimit: 1, imageResize: CGSize(width: 1024, height: 1024), minEmbeddedImageDimension: 64)
        )

        #expect(extracted.first?.failureReason == nil)
        #expect(extracted.first?.includedImageCount == 1)
    }

    @Test
    func scannedPDFRespectsImageLimitAcrossPages() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("multi-page-scan.pdf")
        try scannedPDFData(pageCount: 3).write(to: url)

        let extracted = await SourceExtractor.extract(
            [StudySource(url: url)],
            options: SourceExtractionOptions(imageLimit: 1, imageResize: CGSize(width: 1024, height: 1024), minEmbeddedImageDimension: 64)
        )

        #expect(extracted.first?.includedImageCount == 1)
        #expect(extracted.first?.omittedImageCount == 2)
    }

    @Test
    func docxExtractsTextAndInlineImage() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("notes.docx")
        try makeArchive(at: url, entries: [
            "word/document.xml": """
            <w:document xmlns:w="word" xmlns:r="rels" xmlns:a="drawing">
              <w:body><w:p><w:r><w:t>Hello figure</w:t></w:r><w:r><w:drawing><a:blip r:embed="rId1"/></w:drawing></w:r></w:p></w:body>
            </w:document>
            """.data(using: .utf8)!,
            "word/_rels/document.xml.rels": """
            <Relationships><Relationship Id="rId1" Target="media/image1.png"/></Relationships>
            """.data(using: .utf8)!,
            "word/media/image1.png": pngData(size: CGSize(width: 128, height: 96))
        ])

        let extracted = await SourceExtractor.extract(
            [StudySource(url: url)],
            options: SourceExtractionOptions(imageLimit: 1, imageResize: CGSize(width: 1024, height: 1024), minEmbeddedImageDimension: 64)
        )

        #expect(extracted.first?.text.contains("Hello figure") == true)
        #expect(extracted.first?.includedImageCount == 1)
    }

    @Test
    func pptxExtractsSlidesInPresentationOrder() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("deck.pptx")
        try makeArchive(at: url, entries: [
            "ppt/presentation.xml": """
            <p:presentation xmlns:p="presentation" xmlns:r="rels"><p:sldIdLst><p:sldId r:id="rId2"/><p:sldId r:id="rId1"/></p:sldIdLst></p:presentation>
            """.data(using: .utf8)!,
            "ppt/_rels/presentation.xml.rels": """
            <Relationships><Relationship Id="rId1" Target="slides/slide1.xml"/><Relationship Id="rId2" Target="slides/slide2.xml"/></Relationships>
            """.data(using: .utf8)!,
            "ppt/slides/slide1.xml": """
            <p:sld xmlns:p="presentation" xmlns:a="drawing"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Slide One</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
            """.data(using: .utf8)!,
            "ppt/slides/slide2.xml": """
            <p:sld xmlns:p="presentation" xmlns:a="drawing"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>Slide Two</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
            """.data(using: .utf8)!
        ])

        let extracted = await SourceExtractor.extract(
            [StudySource(url: url)],
            options: SourceExtractionOptions(imageLimit: 0, imageResize: nil, minEmbeddedImageDimension: 64)
        )

        let text = extracted.first?.text ?? ""
        let slideTwo = try #require(text.range(of: "Slide Two")?.lowerBound)
        let slideOne = try #require(text.range(of: "Slide One")?.lowerBound)
        #expect(slideTwo < slideOne)
    }

    @Test
    func xlsxExtractsSharedStringCells() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("sheet.xlsx")
        try makeArchive(at: url, entries: [
            "xl/workbook.xml": """
            <workbook xmlns:r="rels"><sheets><sheet name="Week 1" r:id="rId1"/></sheets></workbook>
            """.data(using: .utf8)!,
            "xl/_rels/workbook.xml.rels": """
            <Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>
            """.data(using: .utf8)!,
            "xl/sharedStrings.xml": """
            <sst><si><t>Photosynthesis</t></si></sst>
            """.data(using: .utf8)!,
            "xl/worksheets/sheet1.xml": """
            <worksheet><sheetData><row><c r="A1" t="s"><v>0</v></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>
            """.data(using: .utf8)!
        ])

        let extracted = await SourceExtractor.extract(
            [StudySource(url: url)],
            options: SourceExtractionOptions(imageLimit: 0, imageResize: nil, minEmbeddedImageDimension: 64)
        )

        #expect(extracted.first?.text.contains("A1: Photosynthesis") == true)
        #expect(extracted.first?.text.contains("B1: 42") == true)
    }

    @Test
    func iWorkPreviewPDFRoutesThroughPDFExtraction() async throws {
        let directory = try temporaryDirectory()
        let package = directory.appendingPathComponent("essay.pages", isDirectory: true)
        let quickLook = package.appendingPathComponent("QuickLook", isDirectory: true)
        try FileManager.default.createDirectory(at: quickLook, withIntermediateDirectories: true)
        try scannedPDFData().write(to: quickLook.appendingPathComponent("Preview.pdf"))

        let extracted = await SourceExtractor.extract(
            [StudySource(url: package)],
            options: SourceExtractionOptions(imageLimit: 1, imageResize: CGSize(width: 1024, height: 1024), minEmbeddedImageDimension: 64)
        )

        #expect(extracted.first?.failureReason == nil)
        #expect(extracted.first?.includedImageCount == 1)
    }

    @Test
    func promptContentReportsOmittedFigures() async throws {
        let directory = try temporaryDirectory()
        let urls = try (1...3).map { index in
            let url = directory.appendingPathComponent("figure\(index).png")
            try pngData(size: CGSize(width: 128, height: 128)).write(to: url)
            return url
        }
        let sources = urls.map(StudySource.init(url:))
        let user = StudyTurnUser(focus: "", resourceKind: .summary, sources: sources, isRefinement: false)
        let extracted = await SourceExtractor.extract(
            sources,
            options: SourceExtractionOptions(imageLimit: 2, imageResize: CGSize(width: 1024, height: 1024), minEmbeddedImageDimension: 64)
        )

        let content = StudyPromptBuilder.content(for: user, history: [], extracted: extracted)

        #expect(content.includedImageCount == 2)
        #expect(content.omittedImageCount == 1)
        #expect(content.benchmarkText.contains("1 additional figure/page was omitted"))
    }

    @Test
    func askPromptUsesQuestionFramingInsteadOfCreationFraming() throws {
        let directory = try temporaryDirectory()
        let sourceURL = directory.appendingPathComponent("authors.txt")
        try "The authors are Ada Lovelace and Grace Hopper.".write(to: sourceURL, atomically: true, encoding: .utf8)
        let source = StudySource(url: sourceURL)
        let user = StudyTurnUser(
            focus: "Who are the authors?",
            resourceKind: .ask,
            sources: [source],
            isRefinement: false
        )
        let extracted = [
            ExtractedSource(
                source: source,
                blocks: [.text("The authors are Ada Lovelace and Grace Hopper.")]
            )
        ]

        let content = StudyPromptBuilder.content(for: user, history: [], extracted: extracted)

        #expect(content.benchmarkText.contains("Task:"))
        #expect(content.benchmarkText.contains("Student question:"))
        #expect(content.benchmarkText.contains("Answer the student's question directly"))
        #expect(!content.benchmarkText.contains("Resource to create:"))
    }

    @Test
    func sourceIndexFindsHeadingAfterFormerCharacterCap() throws {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/attention.pdf"))
        let filler = String(repeating: "Introduction filler text.\n", count: 700)
        let extracted = ExtractedSource(
            source: source,
            blocks: [
                .text("""
                === attention.pdf page 1 ===
                \(filler)
                """),
                .text("""
                === attention.pdf page 6 ===
                5 Training
                This section describes training data, batching, optimizer settings, and regularization.
                """)
            ]
        )

        let index = SourceIndexBuilder.build(from: extracted)

        #expect(index.chunks.contains { $0.headingPath.contains("5 Training") })
        #expect(index.chunks.contains { $0.text.contains("optimizer settings") })
    }

    @Test
    func sourceRetrieverSelectsTrainingSectionByHeading() throws {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/attention.pdf"))
        let extracted = ExtractedSource(
            source: source,
            blocks: [
                .text("""
                === attention.pdf page 4 ===
                4 Model Architecture
                Encoder and decoder stacks use attention layers.
                """),
                .text("""
                === attention.pdf page 6 ===
                5 Training
                The model uses WMT data, batches of sentence pairs, Adam, warmup, and label smoothing.
                """),
                .text("""
                === attention.pdf page 8 ===
                6 Results
                The model reaches strong BLEU scores.
                """)
            ]
        )
        let index = SourceIndexBuilder.build(from: extracted)

        let result = SourceRetriever.retrieve(
            query: "Can you summarize the Training Section of the paper?",
            indexes: [index]
        )

        #expect(result.matchedHeading == "5 Training")
        #expect(result.chunks.contains { $0.text.contains("label smoothing") })
        #expect(!result.chunks.contains { $0.text.contains("Encoder and decoder") })
    }

    @Test
    func sourceRetrieverSelectsExactMarkdownPhaseNumber() throws {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/roadmap.md"))
        let extracted = ExtractedSource(
            source: source,
            blocks: [
                .text("""
                # GRUB-Compatible Rust Unix-Like OS Roadmap

                ## Phase 8: Virtual Memory and Paging

                ### Tasks

                Implement page tables, virtual address mapping, kernel space mappings, and page faults.

                ### Deliverable

                The kernel can map and unmap pages safely.

                ## Phase 20: Shell

                ### Deliverable

                The OS boots into a shell.
                """)
            ]
        )
        let index = SourceIndexBuilder.build(from: extracted)

        let result = SourceRetriever.retrieve(
            query: "Can you explain phase 8 deeper?",
            indexes: [index]
        )

        #expect(result.matchedHeading == "## Phase 8: Virtual Memory and Paging")
        #expect(result.chunks.contains { $0.text.contains("page tables") })
        #expect(!result.chunks.contains { $0.text.contains("boots into a shell") })
    }

    @Test
    func sourceRetrieverFallsBackToBM25ForWeakHeadingOverlap() throws {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/attention.pdf"))
        let extracted = ExtractedSource(
            source: source,
            blocks: [
                .text("""
                === attention.pdf page 4 ===
                4 Model Architecture
                Encoder and decoder stacks use attention layers.
                """),
                .text("""
                === attention.pdf page 8 ===
                6 Results
                The model perform score is strong and reaches high BLEU.
                """)
            ]
        )
        let index = SourceIndexBuilder.build(from: extracted)

        let result = SourceRetriever.retrieve(
            query: "How does the model perform?",
            indexes: [index]
        )

        #expect(result.matchedHeading == nil)
        #expect(result.chunks.first?.text.contains("BLEU") == true)
    }

    @Test
    func sourceIndexPreservesNestedHeadingPath() throws {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/attention.pdf"))
        let extracted = ExtractedSource(
            source: source,
            blocks: [
                .text("""
                5 Training
                5.1 Training Data and Batching
                Sentence pairs are batched by approximate sequence length.
                """)
            ]
        )

        let index = SourceIndexBuilder.build(from: extracted)
        let nested = try #require(index.chunks.first { $0.text.contains("Sentence pairs") })

        #expect(nested.headingPath == ["5 Training", "5.1 Training Data and Batching"])
    }

    @Test
    func sourceIndexDetectsMarkdownHeadings() throws {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/roadmap.md"))
        let extracted = ExtractedSource(
            source: source,
            blocks: [
                .text("""
                # GRUB-Compatible Rust Unix-Like OS Roadmap

                ## Phase 1 - Project Setup

                Create the cargo project and linker script.

                ### Deliverable

                A kernel binary that can be packaged into an ISO.
                """)
            ]
        )

        let index = SourceIndexBuilder.build(from: extracted)
        let deliverable = try #require(index.chunks.first { $0.text.contains("kernel binary") })

        #expect(deliverable.headingPath.contains("# GRUB-Compatible Rust Unix-Like OS Roadmap"))
        #expect(deliverable.headingPath.contains("## Phase 1 - Project Setup"))
        #expect(deliverable.headingPath.contains("### Deliverable"))
    }

    @Test
    func sourceIndexFallsBackToPlainChunksWithoutHeadings() throws {
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/notes.txt"))
        let extracted = ExtractedSource(
            source: source,
            blocks: [.text(String(repeating: "Plain study note without numbered headings. ", count: 200))]
        )

        let index = SourceIndexBuilder.build(from: extracted)

        #expect(!index.chunks.isEmpty)
        #expect(index.chunks.allSatisfy { $0.headingPath.isEmpty })
    }

    @Test
    func promptPackerRespectsTokenBudget() throws {
        let sourceID = UUID()
        let chunks = (1...3).map { index in
            SourceChunk(
                id: "c\(index)",
                sourceID: sourceID,
                sourceName: "notes.txt",
                locator: nil,
                headingPath: [],
                ordinal: index,
                text: String(repeating: "word ", count: 160),
                estimatedTokenCount: 200
            )
        }

        let packed = PromptPacker.pack(chunks, budget: 250)

        #expect(packed.chunks.count == 1)
        #expect(packed.omitted == 2)
    }

    @Test
    func promptPackerPreservesCoverageForModestOverflow() throws {
        let sourceID = UUID()
        let chunks = (1...4).map { index in
            SourceChunk(
                id: "c\(index)",
                sourceID: sourceID,
                sourceName: "roadmap.md",
                locator: nil,
                headingPath: ["# Roadmap", "## Phase \(index)"],
                ordinal: index,
                text: String(repeating: "Rust kernel milestone with GRUB, paging, syscalls, and scheduling. ", count: 75),
                estimatedTokenCount: 1_200
            )
        }

        let packed = PromptPacker.packForCoverage(chunks, budget: 4_200)

        #expect(PromptPacker.canPreserveCoverage(chunks, budget: 4_200))
        #expect(packed.chunks.count == chunks.count)
        #expect(packed.compactedChunkCount == chunks.count)
        #expect(PromptPacker.fits(packed.chunks, budget: 4_200))
        #expect(packed.chunks.allSatisfy { $0.text.contains("Rust kernel milestone") })
    }

    @Test
    func promptPackerOverviewSamplesAcrossSources() throws {
        let firstID = UUID()
        let secondID = UUID()
        let first = (1...6).map { index in
            SourceChunk(id: "a\(index)", sourceID: firstID, sourceName: "first.pdf", locator: "page \(index)", headingPath: [], ordinal: index, text: String(repeating: "First source page \(index). ", count: 80), estimatedTokenCount: 220)
        }
        let second = (1...6).map { index in
            SourceChunk(id: "b\(index)", sourceID: secondID, sourceName: "second.pdf", locator: "page \(index)", headingPath: [], ordinal: index, text: String(repeating: "Second source page \(index). ", count: 80), estimatedTokenCount: 220)
        }

        let packed = PromptPacker.packForOverview(first + second, budget: 600)

        #expect(packed.chunks.count == 4)
        #expect(packed.omitted == 8)
        #expect(packed.chunks.contains { $0.sourceName == "first.pdf" && $0.ordinal == 1 })
        #expect(packed.chunks.contains { $0.sourceName == "first.pdf" && $0.ordinal == 6 })
        #expect(packed.chunks.contains { $0.sourceName == "second.pdf" && $0.ordinal == 1 })
        #expect(packed.chunks.contains { $0.sourceName == "second.pdf" && $0.ordinal == 6 })
        #expect(PromptPacker.fits(packed.chunks, budget: 600))
    }

    @Test
    func modestWholeDocumentOverflowAvoidsIntermediateModelCalls() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("roadmap.md")
        let section = String(
            repeating: "Rust kernel milestone with GRUB, paging, syscalls, scheduling, files, and user mode. ",
            count: 60
        )
        try """
        # Roadmap

        ## Phase 1
        \(section)

        ## Phase 2
        \(section)

        ## Phase 3
        \(section)

        ## Phase 4
        \(section)
        """.write(to: url, atomically: true, encoding: .utf8)

        let counter = IntermediateCallCounter()
        let source = StudySource(url: url)
        let user = StudyTurnUser(focus: "", resourceKind: .summary, sources: [source], isRefinement: false)

        let content = try await SourceContextPlanner.content(
            for: user,
            history: [],
            profile: .gemma4E4B,
            generateIntermediate: { _, _, _ in
                await counter.increment()
                return "intermediate"
            },
            status: { _ in }
        )

        #expect(await counter.value == 0)
        #expect(content.benchmarkText.contains("Full source coverage selected with compacted excerpts."))
    }

    @Test
    func largeUnheadedWholeDocumentUsesFastOverviewInsteadOfManyIntermediateCalls() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("long-notes.txt")
        let lines = (1...180).map { index in
            "Plain study source line \(index) with concepts, examples, dates, and definitions for a broad summary."
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

        let counter = IntermediateCallCounter()
        let source = StudySource(url: url)
        let user = StudyTurnUser(focus: "", resourceKind: .summary, sources: [source], isRefinement: false)

        let content = try await SourceContextPlanner.content(
            for: user,
            history: [],
            profile: .gemma4E4B,
            generateIntermediate: { _, _, _ in
                await counter.increment()
                return "intermediate"
            },
            status: { _ in }
        )

        #expect(await counter.value == 0)
        #expect(content.benchmarkText.contains("Fast source overview selected."))
        #expect(content.benchmarkText.contains("fast overview"))
    }

    @Test
    func wholeDocumentGroupingUsesSectionsBeforeSynthesis() throws {
        let sourceID = UUID()
        let chunks = [
            SourceChunk(id: "1", sourceID: sourceID, sourceName: "paper.pdf", locator: "page 1", headingPath: ["1 Intro"], ordinal: 1, text: "Intro", estimatedTokenCount: 10),
            SourceChunk(id: "2", sourceID: sourceID, sourceName: "paper.pdf", locator: "page 2", headingPath: ["1 Intro"], ordinal: 2, text: "More intro", estimatedTokenCount: 10),
            SourceChunk(id: "3", sourceID: sourceID, sourceName: "paper.pdf", locator: "page 6", headingPath: ["5 Training"], ordinal: 3, text: "Training", estimatedTokenCount: 10)
        ]

        let groups = SourceContextPlanner.sectionGroups(for: chunks, budget: 100)

        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].first?.headingPath == ["5 Training"])
    }

    @Test
    func wholeDocumentGroupingBatchesUnheadedChunksByBudget() throws {
        let sourceID = UUID()
        let chunks = (1...5).map { index in
            SourceChunk(id: "\(index)", sourceID: sourceID, sourceName: "paper.pdf", locator: "page \(index)", headingPath: [], ordinal: index, text: "Page \(index)", estimatedTokenCount: 100)
        }

        let groups = SourceContextPlanner.sectionGroups(for: chunks, budget: 250)

        #expect(groups.map(\.count) == [2, 2, 1])
    }

    @Test
    func budgetGroupingCombinesDifferentSectionsForRecursiveCondensing() throws {
        let sourceID = UUID()
        let chunks = [
            SourceChunk(id: "1", sourceID: sourceID, sourceName: "paper.pdf", locator: "page 1", headingPath: ["1 Intro"], ordinal: 1, text: "Intro", estimatedTokenCount: 100),
            SourceChunk(id: "2", sourceID: sourceID, sourceName: "paper.pdf", locator: "page 2", headingPath: ["2 Background"], ordinal: 2, text: "Background", estimatedTokenCount: 100),
            SourceChunk(id: "3", sourceID: sourceID, sourceName: "paper.pdf", locator: "page 6", headingPath: ["5 Training"], ordinal: 3, text: "Training", estimatedTokenCount: 100)
        ]

        let groups = SourceContextPlanner.budgetGroups(for: chunks, budget: 250)

        #expect(groups.count == 2)
        #expect(groups[0].count == 2)
        #expect(groups[1].first?.headingPath == ["5 Training"])
    }

    @Test
    func interactivePromptsKeepStrictJSONFormatWithPlannedContext() throws {
        let context = SourcePromptContext(
            title: "Retrieved relevant source excerpts.",
            blocks: [
                .text("""
                === notes.txt ===
                Photosynthesis converts light into chemical energy.
                """)
            ],
            warnings: [],
            includedImageCount: 0,
            omittedImageCount: 0,
            imageFilenames: [],
            omittedTextChunkCount: 0
        )
        let source = StudySource(url: URL(fileURLWithPath: "/tmp/notes.txt"))
        let user = StudyTurnUser(focus: "", resourceKind: .quiz, sources: [source], isRefinement: false)

        let content = StudyPromptBuilder.content(for: user, history: [], sourceContext: context)

        #expect(content.benchmarkText.contains("Return ONLY a single JSON object"))
        #expect(content.benchmarkText.contains("\"questions\""))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalTutorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pngData(size: CGSize) throws -> Data {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(NSColor.systemTeal.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard let cgImage = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private func scannedPDFData(pageCount: Int = 1) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for _ in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor)
            context.fill(mediaBox)
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 40, y: 160, width: 220, height: 80))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func makeArchive(at url: URL, entries: [String: Data]) throws {
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        for (path, data) in entries {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count)
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return data.subdata(in: start..<end)
            }
        }
    }
}

private actor IntermediateCallCounter {
    var value = 0

    func increment() {
        value += 1
    }
}
