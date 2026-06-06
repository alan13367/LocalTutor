//
//  SourceExtractor.swift
//  LocalTutor
//
//  Reads ordered text and visual blocks out of attached study sources.
//

import AppKit
import CoreGraphics
import CoreImage
import Foundation
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import ZIPFoundation

struct ExtractedSource: Sendable {
    var source: StudySource
    var blocks: [DocumentBlock] {
        didSet {
            cachedText = Self.combinedText(from: blocks)
        }
    }
    /// Nil on success, otherwise a short reason the contents could not be read.
    var failureReason: String?
    var warnings: [String] = []
    var omittedImageCount: Int = 0
    private var cachedText: String

    /// Plain-text representation of the document's contents, kept for the
    /// existing context-window budget logic.
    var text: String {
        cachedText
    }

    var hasContent: Bool {
        !cachedText.isEmpty
            || blocks.contains { $0.imageValue != nil }
    }

    var includedImageCount: Int {
        blocks.filter { $0.imageValue != nil }.count
    }

    var textOnlyCacheCopy: ExtractedSource {
        ExtractedSource(
            source: source,
            blocks: blocks.compactMap { block in
                guard case .text = block else { return nil }
                return block
            },
            failureReason: failureReason,
            warnings: warnings,
            omittedImageCount: 0
        )
    }

    init(
        source: StudySource,
        blocks: [DocumentBlock],
        failureReason: String? = nil,
        warnings: [String] = [],
        omittedImageCount: Int = 0
    ) {
        self.source = source
        self.blocks = blocks
        self.failureReason = failureReason
        self.warnings = warnings
        self.omittedImageCount = omittedImageCount
        self.cachedText = Self.combinedText(from: blocks)
    }

    private static func combinedText(from blocks: [DocumentBlock]) -> String {
        blocks.compactMap(\.textValue)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

enum SourceExtractor {
    static func extract(
        _ sources: [StudySource],
        options: SourceExtractionOptions = .defaults(for: .vision)
    ) async -> [ExtractedSource] {
        var remainingImageSlots = max(0, options.imageLimit)
        var results: [ExtractedSource] = []

        for source in sources {
            let sourceOptions = SourceExtractionOptions(
                imageLimit: remainingImageSlots,
                imageResize: options.imageResize,
                minEmbeddedImageDimension: options.minEmbeddedImageDimension
            )

            let extracted: ExtractedSource
            if shouldUseCache(for: source),
               let cached = await SourceExtractionCache.shared.cached(for: source) {
                extracted = cached
            } else {
                extracted = await extractOne(source, options: sourceOptions)
                if shouldUseCache(for: source), extracted.includedImageCount == 0 {
                    await SourceExtractionCache.shared.store(extracted.textOnlyCacheCopy, for: source)
                }
            }

            remainingImageSlots = max(0, remainingImageSlots - extracted.includedImageCount)
            results.append(extracted)
        }

        return results
    }

    private static func shouldUseCache(for source: StudySource) -> Bool {
        switch source.kind {
        case .text:
            return true
        case .document:
            return !["docx", "pages"].contains(source.fileExtension)
        default:
            return false
        }
    }

    private static func imagesDisabledWarning(for source: StudySource) -> String {
        "\(source.displayName) contains images or scanned pages that were skipped because the selected model is text-only. Switch to a vision model to include them."
    }

    private static func imageOnlyFailure(for source: StudySource) -> String {
        "No readable text was found. This source appears to rely on images or scanned pages; switch to a vision model to study it."
    }

    private static func extractOne(
        _ source: StudySource,
        options: SourceExtractionOptions
    ) async -> ExtractedSource {
        let url = source.accessibleURL
        let granted = url.startAccessingSecurityScopedResource()
        defer {
            if granted { url.stopAccessingSecurityScopedResource() }
        }

        do {
            return try await readBlocks(at: url, source: source, options: options)
        } catch let error as SourceExtractorError {
            return ExtractedSource(source: source, blocks: [], failureReason: error.description)
        } catch {
            return ExtractedSource(source: source, blocks: [], failureReason: error.localizedDescription)
        }
    }

    private static func readBlocks(
        at url: URL,
        source: StudySource,
        options: SourceExtractionOptions
    ) async throws -> ExtractedSource {
        switch source.kind {
        case .pdf:
            guard let document = PDFDocument(url: url) else {
                throw SourceExtractorError.unreadable("Could not open the PDF.")
            }
            return extractPDF(document, source: source, options: options)

        case .image:
            return try readStandaloneImage(url, source: source, options: options)

        case .text:
            let text = try readPlainText(url)
            return textSource(source, text: text)

        case .document:
            switch source.fileExtension {
            case "docx":
                return try readDocx(url, source: source, options: options)
            case "pages":
                if let preview = try await readIWorkPreview(url, source: source, options: options) {
                    return preview
                }
                return try await readPreviewFallback(url, source: source, options: options, warning: "Pages preview extraction was limited to the available thumbnail.")
            default:
                let text = try readAttributed(url, fileExtension: source.fileExtension)
                var extracted = textSource(source, text: text)
                if options.allowsImages,
                   source.fileExtension == "rtfd",
                   let preview = try? await readPreviewImage(url, source: source, locator: nil, options: options) {
                    var included = extracted.includedImageCount
                    var omitted = 0
                    appendImage(
                        preview,
                        sourceName: source.displayName,
                        locator: nil,
                        caption: "RTFD preview",
                        isStandalone: false,
                        originalSize: preview.extent.size,
                        options: options,
                        includedCount: &included,
                        omittedCount: &omitted,
                        blocks: &extracted.blocks
                    )
                    extracted.omittedImageCount += omitted
                }
                return extracted
            }

        case .presentation:
            switch source.fileExtension {
            case "pptx":
                return try readPptx(url, source: source, options: options)
            case "key":
                if let preview = try await readIWorkPreview(url, source: source, options: options) {
                    return preview
                }
                return try await readPreviewFallback(url, source: source, options: options, warning: "Keynote preview extraction was limited to the available thumbnail.")
            default:
                return try await readPreviewFallback(url, source: source, options: options, warning: "Legacy slide deck extraction is limited to the available system preview.")
            }

        case .spreadsheet:
            switch source.fileExtension {
            case "csv":
                let text = try readPlainText(url)
                return textSource(source, text: text)
            case "xlsx":
                return try readXlsx(url, source: source, options: options)
            case "numbers":
                if let preview = try await readIWorkPreview(url, source: source, options: options) {
                    return preview
                }
                return try await readPreviewFallback(url, source: source, options: options, warning: "Numbers preview extraction was limited to the available thumbnail.")
            default:
                return try await readPreviewFallback(url, source: source, options: options, warning: "Legacy spreadsheet extraction is limited to the available system preview.")
            }

        case .other:
            if let text = try? readPlainText(url) {
                return textSource(source, text: text)
            }
            return try await readPreviewFallback(url, source: source, options: options, warning: "This file type is limited to the available system preview.")
        }
    }

    private static func textSource(_ source: StudySource, text: String) -> ExtractedSource {
        let cleaned = clean(text)
        let blocks = cleaned.isEmpty ? [] : [DocumentBlock.text(cleaned)]
        return ExtractedSource(source: source, blocks: blocks, failureReason: nil)
    }

    // MARK: - PDF

    private static func extractPDF(
        _ document: PDFDocument,
        source: StudySource,
        options: SourceExtractionOptions
    ) -> ExtractedSource {
        var blocks: [DocumentBlock] = []
        var omitted = 0
        var included = 0

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let locator = "page \(index + 1)"
            let text = clean(page.string ?? "")
            if !text.isEmpty {
                blocks.append(.text("=== \(source.displayName) \(locator) ===\n\(text)"))
            }

            let shouldRender = text.isEmpty || pageLikelyContainsImage(page)
            guard shouldRender else { continue }
            guard included < options.imageLimit else {
                omitted += 1
                continue
            }

            if let rendered = renderPDFPage(page, maxSize: options.imageResize) {
                appendImage(
                    rendered,
                    sourceName: source.displayName,
                    locator: locator,
                    caption: text.isEmpty ? "Scanned or image-only page" : "Page render with visual material",
                    isStandalone: false,
                    originalSize: rendered.extent.size,
                    options: options,
                    includedCount: &included,
                    omittedCount: &omitted,
                    blocks: &blocks
                )
            }
        }

        if blocks.isEmpty {
            let failure = !options.allowsImages && omitted > 0
                ? imageOnlyFailure(for: source)
                : "No readable text or page preview could be extracted from this PDF."
            return ExtractedSource(
                source: source,
                blocks: [],
                failureReason: failure,
                warnings: !options.allowsImages && omitted > 0 ? [imagesDisabledWarning(for: source)] : [],
                omittedImageCount: omitted
            )
        }

        return ExtractedSource(
            source: source,
            blocks: blocks,
            failureReason: nil,
            warnings: !options.allowsImages && omitted > 0 ? [imagesDisabledWarning(for: source)] : [],
            omittedImageCount: omitted
        )
    }

    private static func pageLikelyContainsImage(_ page: PDFPage) -> Bool {
        guard let pageRef = page.pageRef,
              let dictionary = pageRef.dictionary else {
            return false
        }
        return pdfDictionaryContainsImage(dictionary)
    }

    private static func pdfDictionaryContainsImage(_ dictionary: CGPDFDictionaryRef) -> Bool {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources),
              let resources else {
            return false
        }

        var xObjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xObjects),
              let xObjects else {
            return false
        }

        var found = false
        CGPDFDictionaryApplyBlock(xObjects, { _, object, _ in
            var objectDictionary: CGPDFDictionaryRef?
            if CGPDFObjectGetValue(object, .dictionary, &objectDictionary),
               let objectDictionary {
                var subtype: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(objectDictionary, "Subtype", &subtype),
                   let subtype,
                   String(cString: subtype) == "Image" {
                    found = true
                    return false
                }
            }
            return true
        }, nil)
        return found
    }

    private static func renderPDFPage(_ page: PDFPage, maxSize: CGSize?) -> CIImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let target = maxSize ?? CGSize(width: 1024, height: 1024)
        let scale = min(target.width / bounds.width, target.height / bounds.height, 1)
        let width = max(1, Int((bounds.width * scale).rounded()))
        let height = max(1, Int((bounds.height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    // MARK: - Images

    private static func readStandaloneImage(
        _ url: URL,
        source: StudySource,
        options: SourceExtractionOptions
    ) throws -> ExtractedSource {
        guard options.allowsImages else {
            return ExtractedSource(
                source: source,
                blocks: [],
                failureReason: nil,
                warnings: ["\(source.displayName) was skipped because the selected model is text-only. Switch to a vision model to study images."],
                omittedImageCount: 1
            )
        }

        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw SourceExtractorError.unreadable("Could not load the image.")
        }

        var blocks: [DocumentBlock] = []
        var included = 0
        var omitted = 0
        appendImage(
            image,
            sourceName: source.displayName,
            locator: nil,
            caption: nil,
            isStandalone: true,
            originalSize: image.extent.size,
            options: options,
            includedCount: &included,
            omittedCount: &omitted,
            blocks: &blocks
        )

        return ExtractedSource(source: source, blocks: blocks, failureReason: nil, omittedImageCount: omitted)
    }

    private static func imageFromData(_ data: Data) -> CIImage? {
        CIImage(data: data, options: [.applyOrientationProperty: true])
    }

    private static func appendImage(
        _ image: CIImage,
        sourceName: String,
        locator: String?,
        caption: String?,
        isStandalone: Bool,
        originalSize: CGSize,
        options: SourceExtractionOptions,
        includedCount: inout Int,
        omittedCount: inout Int,
        blocks: inout [DocumentBlock]
    ) {
        let size = originalSize
        if !isStandalone,
           min(size.width, size.height) < options.minEmbeddedImageDimension {
            return
        }

        guard includedCount < options.imageLimit else {
            omittedCount += 1
            return
        }

        let resized = resize(image, toFit: options.imageResize)
        let documentImage = DocumentImage(
            image: resized,
            sourceName: sourceName,
            locator: locator,
            caption: caption,
            isStandalone: isStandalone,
            originalSize: originalSize
        )
        blocks.append(.image(documentImage))
        includedCount += 1
    }

    private static func resize(_ image: CIImage, toFit maxSize: CGSize?) -> CIImage {
        guard let maxSize,
              image.extent.width > 0,
              image.extent.height > 0 else {
            return image
        }
        let scale = min(maxSize.width / image.extent.width, maxSize.height / image.extent.height, 1)
        guard scale < 1 else { return image }
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    // MARK: - Plain and attributed text

    private static func readPlainText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw SourceExtractorError.unreadable("Could not decode the text file.")
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw SourceExtractorError.unreadable("Could not decode the text file.")
    }

    private static func readAttributed(_ url: URL, fileExtension: String) throws -> String {
        let ext = fileExtension.lowercased()
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]

        switch ext {
        case "docx":
            options[.documentType] = NSAttributedString.DocumentType.officeOpenXML
        case "doc":
            options[.documentType] = NSAttributedString.DocumentType.docFormat
        case "rtf":
            options[.documentType] = NSAttributedString.DocumentType.rtf
        case "rtfd":
            options[.documentType] = NSAttributedString.DocumentType.rtfd
        default:
            break
        }

        do {
            let data = try Data(contentsOf: url)
            let attributed = try NSAttributedString(data: data, options: options, documentAttributes: nil)
            return attributed.string
        } catch {
            throw SourceExtractorError.unreadable(error.localizedDescription)
        }
    }

    // MARK: - Office Open XML

    private static func readDocx(
        _ url: URL,
        source: StudySource,
        options: SourceExtractionOptions
    ) throws -> ExtractedSource {
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        let relationships = try relationships(in: archive, path: "word/_rels/document.xml.rels")
        let documentXML = try archiveData(in: archive, path: "word/document.xml")
        let refs = parseTextAndImageRefs(documentXML)

        var blocks: [DocumentBlock] = []
        var included = 0
        var omitted = 0

        for ref in refs {
            switch ref {
            case .text(let text):
                let cleaned = clean(text)
                if !cleaned.isEmpty {
                    blocks.append(.text(cleaned))
                }
            case .imageRef(let id):
                guard options.allowsImages else {
                    omitted += 1
                    continue
                }
                guard let target = relationships[id],
                      let imageData = try? archiveData(in: archive, path: normalizedArchivePath(base: "word", target: target)),
                      let image = imageFromData(imageData) else {
                    continue
                }
                appendImage(
                    image,
                    sourceName: source.displayName,
                    locator: "document body",
                    caption: "Embedded Word image",
                    isStandalone: false,
                    originalSize: image.extent.size,
                    options: options,
                    includedCount: &included,
                    omittedCount: &omitted,
                    blocks: &blocks
                )
            }
        }

        if blocks.isEmpty, let attributed = try? readAttributed(url, fileExtension: source.fileExtension) {
            let fallback = textSource(source, text: attributed)
            if fallback.hasContent {
                return fallback
            }
        }

        if blocks.isEmpty, !options.allowsImages, omitted > 0 {
            return ExtractedSource(
                source: source,
                blocks: [],
                failureReason: imageOnlyFailure(for: source),
                warnings: [imagesDisabledWarning(for: source)],
                omittedImageCount: omitted
            )
        }

        return ExtractedSource(
            source: source,
            blocks: blocks,
            failureReason: nil,
            warnings: !options.allowsImages && omitted > 0 ? [imagesDisabledWarning(for: source)] : [],
            omittedImageCount: omitted
        )
    }

    private static func readPptx(
        _ url: URL,
        source: StudySource,
        options: SourceExtractionOptions
    ) throws -> ExtractedSource {
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        let presentationXML = try archiveData(in: archive, path: "ppt/presentation.xml")
        let presentationRelationships = try relationships(in: archive, path: "ppt/_rels/presentation.xml.rels")
        let slideIDs = parsePresentationSlideIDs(presentationXML)

        var blocks: [DocumentBlock] = []
        var included = 0
        var omitted = 0

        for (index, id) in slideIDs.enumerated() {
            guard let slideTarget = presentationRelationships[id] else { continue }
            let slidePath = normalizedArchivePath(base: "ppt", target: slideTarget)
            guard let slideXML = try? archiveData(in: archive, path: slidePath) else { continue }

            let locator = "slide \(index + 1)"
            let refs = parseTextAndImageRefs(slideXML)
            let text = clean(refs.compactMap { ref in
                if case .text(let text) = ref { return text }
                return nil
            }.joined(separator: "\n"))
            if !text.isEmpty {
                blocks.append(.text("=== \(source.displayName) \(locator) ===\n\(text)"))
            }

            let slideRelsPath = relationshipsPath(for: slidePath)
            let slideRelationships = (try? relationships(in: archive, path: slideRelsPath)) ?? [:]
            if !options.allowsImages {
                omitted += refs.filter {
                    if case .imageRef = $0 { return true }
                    return false
                }.count
                continue
            }

            let images = refs.compactMap { ref -> CIImage? in
                guard case .imageRef(let id) = ref,
                      let target = slideRelationships[id],
                      let data = try? archiveData(in: archive, path: normalizedArchivePath(base: parentFolder(of: slidePath), target: target)) else {
                    return nil
                }
                return imageFromData(data)
            }

            if included < options.imageLimit,
               let synthetic = renderSyntheticPage(title: "\(source.displayName) \(locator)", body: text, images: images) {
                appendImage(
                    synthetic,
                    sourceName: source.displayName,
                    locator: locator,
                    caption: "Simplified slide render",
                    isStandalone: false,
                    originalSize: synthetic.extent.size,
                    options: options,
                    includedCount: &included,
                    omittedCount: &omitted,
                    blocks: &blocks
                )
            } else if included < options.imageLimit {
                for image in images {
                    appendImage(
                        image,
                        sourceName: source.displayName,
                        locator: locator,
                        caption: "Embedded slide image",
                        isStandalone: false,
                        originalSize: image.extent.size,
                        options: options,
                        includedCount: &included,
                        omittedCount: &omitted,
                        blocks: &blocks
                    )
                }
            }
        }

        if blocks.isEmpty {
            if !options.allowsImages, omitted > 0 {
                return ExtractedSource(
                    source: source,
                    blocks: [],
                    failureReason: imageOnlyFailure(for: source),
                    warnings: [imagesDisabledWarning(for: source)],
                    omittedImageCount: omitted
                )
            }
            throw SourceExtractorError.unreadable("No readable slide contents were found.")
        }
        return ExtractedSource(
            source: source,
            blocks: blocks,
            failureReason: nil,
            warnings: !options.allowsImages && omitted > 0 ? [imagesDisabledWarning(for: source)] : [],
            omittedImageCount: omitted
        )
    }

    private static func readXlsx(
        _ url: URL,
        source: StudySource,
        options: SourceExtractionOptions
    ) throws -> ExtractedSource {
        let archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        let workbookXML = try archiveData(in: archive, path: "xl/workbook.xml")
        let workbookRelationships = try relationships(in: archive, path: "xl/_rels/workbook.xml.rels")
        let sharedStrings = (try? archiveData(in: archive, path: "xl/sharedStrings.xml"))
            .map(parseSharedStrings) ?? []
        let sheets = parseWorkbookSheets(workbookXML)

        var blocks: [DocumentBlock] = []
        var included = 0
        var omitted = 0

        for sheet in sheets {
            guard let target = workbookRelationships[sheet.relationshipID] else { continue }
            let sheetPath = normalizedArchivePath(base: "xl", target: target)
            guard let sheetXML = try? archiveData(in: archive, path: sheetPath) else { continue }

            let rows = parseWorksheetRows(sheetXML, sharedStrings: sharedStrings)
            let sheetText = rows.joined(separator: "\n")
            if !sheetText.isEmpty {
                blocks.append(.text("=== \(source.displayName) \(sheet.name) ===\n\(sheetText)"))
            }

            if !options.allowsImages {
                omitted += parseTextAndImageRefs(sheetXML).filter {
                    if case .imageRef = $0 { return true }
                    return false
                }.count
                continue
            }

            let drawingImages = worksheetDrawingImages(archive: archive, sheetPath: sheetPath, sheetXML: sheetXML)
            if included < options.imageLimit,
               let synthetic = renderSyntheticPage(title: "\(source.displayName) \(sheet.name)", body: sheetText, images: drawingImages) {
                appendImage(
                    synthetic,
                    sourceName: source.displayName,
                    locator: sheet.name,
                    caption: "Simplified sheet render",
                    isStandalone: false,
                    originalSize: synthetic.extent.size,
                    options: options,
                    includedCount: &included,
                    omittedCount: &omitted,
                    blocks: &blocks
                )
            } else if included < options.imageLimit {
                for image in drawingImages {
                    appendImage(
                        image,
                        sourceName: source.displayName,
                        locator: sheet.name,
                        caption: "Embedded sheet image",
                        isStandalone: false,
                        originalSize: image.extent.size,
                        options: options,
                        includedCount: &included,
                        omittedCount: &omitted,
                        blocks: &blocks
                    )
                }
            }
        }

        if blocks.isEmpty {
            if !options.allowsImages, omitted > 0 {
                return ExtractedSource(
                    source: source,
                    blocks: [],
                    failureReason: imageOnlyFailure(for: source),
                    warnings: [imagesDisabledWarning(for: source)],
                    omittedImageCount: omitted
                )
            }
            throw SourceExtractorError.unreadable("No readable spreadsheet contents were found.")
        }
        return ExtractedSource(
            source: source,
            blocks: blocks,
            failureReason: nil,
            warnings: !options.allowsImages && omitted > 0 ? [imagesDisabledWarning(for: source)] : [],
            omittedImageCount: omitted
        )
    }

    // MARK: - iWork and preview fallbacks

    private static func readIWorkPreview(
        _ url: URL,
        source: StudySource,
        options: SourceExtractionOptions
    ) async throws -> ExtractedSource? {
        if url.hasDirectoryPath {
            let quickLook = url.appendingPathComponent("QuickLook")
            let previewPDF = quickLook.appendingPathComponent("Preview.pdf")
            if let document = PDFDocument(url: previewPDF) {
                return extractPDF(document, source: source, options: options)
            }
            guard options.allowsImages else { return nil }
            for name in ["Thumbnail.jpg", "Thumbnail.png"] {
                let thumbnailURL = quickLook.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: thumbnailURL.path),
                   let image = CIImage(contentsOf: thumbnailURL, options: [.applyOrientationProperty: true]) {
                    return previewSource(source: source, image: image, options: options, warning: "Only the document preview thumbnail was available.")
                }
            }
            return nil
        }

        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read, pathEncoding: nil)
        } catch {
            return nil
        }
        if let data = try? archiveData(in: archive, path: "QuickLook/Preview.pdf"),
           let document = PDFDocument(data: data) {
            return extractPDF(document, source: source, options: options)
        }
        guard options.allowsImages else { return nil }
        for path in ["QuickLook/Thumbnail.jpg", "QuickLook/Thumbnail.png"] {
            if let data = try? archiveData(in: archive, path: path),
               let image = imageFromData(data) {
                return previewSource(source: source, image: image, options: options, warning: "Only the document preview thumbnail was available.")
            }
        }
        return nil
    }

    private static func readPreviewFallback(
        _ url: URL,
        source: StudySource,
        options: SourceExtractionOptions,
        warning: String
    ) async throws -> ExtractedSource {
        guard options.allowsImages else {
            return ExtractedSource(
                source: source,
                blocks: [],
                failureReason: imageOnlyFailure(for: source),
                warnings: [imagesDisabledWarning(for: source)],
                omittedImageCount: 1
            )
        }

        if let image = try await readPreviewImage(url, source: source, locator: nil, options: options) {
            return previewSource(source: source, image: image, options: options, warning: warning)
        }
        throw SourceExtractorError.unsupported(warning)
    }

    private static func previewSource(
        source: StudySource,
        image: CIImage,
        options: SourceExtractionOptions,
        warning: String
    ) -> ExtractedSource {
        var blocks: [DocumentBlock] = []
        var included = 0
        var omitted = 0
        appendImage(
            image,
            sourceName: source.displayName,
            locator: nil,
            caption: "System preview",
            isStandalone: false,
            originalSize: image.extent.size,
            options: options,
            includedCount: &included,
            omittedCount: &omitted,
            blocks: &blocks
        )
        return ExtractedSource(source: source, blocks: blocks, failureReason: nil, warnings: [warning], omittedImageCount: omitted)
    }

    private static func readPreviewImage(
        _ url: URL,
        source: StudySource,
        locator: String?,
        options: SourceExtractionOptions
    ) async throws -> CIImage? {
        let size = options.imageResize ?? CGSize(width: 1024, height: 1024)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        let previewData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, error in
                if let data = representation?.nsImage.tiffRepresentation {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: SourceExtractorError.unreadable("No system preview was available."))
                }
            }
        }

        return imageFromData(previewData)
    }

    // MARK: - Archive helpers

    private static func archiveData(in archive: Archive, path: String) throws -> Data {
        let cleanPath = path.replacingOccurrences(of: "\\", with: "/")
        guard let entry = archive[cleanPath] else {
            throw SourceExtractorError.unreadable("Missing \(cleanPath).")
        }
        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    private static func relationships(in archive: Archive, path: String) throws -> [String: String] {
        guard let data = try? archiveData(in: archive, path: path) else { return [:] }
        return parseRelationships(data)
    }

    private static func normalizedArchivePath(base: String, target: String) -> String {
        if target.hasPrefix("/") {
            return String(target.dropFirst())
        }
        let combined = base.split(separator: "/").map(String.init) + target.split(separator: "/").map(String.init)
        var parts: [String] = []
        for part in combined {
            switch part {
            case "", ".":
                continue
            case "..":
                _ = parts.popLast()
            default:
                parts.append(part)
            }
        }
        return parts.joined(separator: "/")
    }

    private static func relationshipsPath(for partPath: String) -> String {
        let folder = parentFolder(of: partPath)
        let filename = URL(fileURLWithPath: partPath).lastPathComponent
        return "\(folder)/_rels/\(filename).rels"
    }

    private static func parentFolder(of path: String) -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.joined(separator: "/")
    }

    // MARK: - XML helpers

    private static func parseRelationships(_ data: Data) -> [String: String] {
        let delegate = RelationshipXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.relationships
    }

    private static func parseTextAndImageRefs(_ data: Data) -> [OfficeContentRef] {
        let delegate = TextAndImageXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.refs
    }

    private static func parsePresentationSlideIDs(_ data: Data) -> [String] {
        let delegate = PresentationXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.slideRelationshipIDs
    }

    private static func parseSharedStrings(_ data: Data) -> [String] {
        let delegate = SharedStringsXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.values
    }

    private static func parseWorkbookSheets(_ data: Data) -> [WorkbookSheet] {
        let delegate = WorkbookXMLParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.sheets
    }

    private static func parseWorksheetRows(_ data: Data, sharedStrings: [String]) -> [String] {
        let delegate = WorksheetXMLParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.rows
    }

    private static func worksheetDrawingImages(archive: Archive, sheetPath: String, sheetXML: Data) -> [CIImage] {
        let drawingRefs = parseTextAndImageRefs(sheetXML).compactMap { ref -> String? in
            if case .imageRef(let id) = ref { return id }
            return nil
        }
        guard !drawingRefs.isEmpty,
              let sheetRelationships = try? relationships(in: archive, path: relationshipsPath(for: sheetPath)) else {
            return []
        }

        return drawingRefs.flatMap { drawingID -> [CIImage] in
            guard let drawingTarget = sheetRelationships[drawingID],
                  let drawingXML = try? archiveData(in: archive, path: normalizedArchivePath(base: parentFolder(of: sheetPath), target: drawingTarget)) else {
                return []
            }
            let drawingPath = normalizedArchivePath(base: parentFolder(of: sheetPath), target: drawingTarget)
            let drawingRelationships = (try? relationships(in: archive, path: relationshipsPath(for: drawingPath))) ?? [:]
            return parseTextAndImageRefs(drawingXML).compactMap { ref -> CIImage? in
                guard case .imageRef(let imageID) = ref,
                      let imageTarget = drawingRelationships[imageID],
                      let data = try? archiveData(in: archive, path: normalizedArchivePath(base: parentFolder(of: drawingPath), target: imageTarget)) else {
                    return nil
                }
                return imageFromData(data)
            }
        }
    }

    // MARK: - Synthetic rendering

    private static func renderSyntheticPage(title: String, body: String, images: [CIImage]) -> CIImage? {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else {
            return nil
        }

        let size = CGSize(width: 1024, height: 768)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor.black
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]

        (title as NSString).draw(
            in: CGRect(x: 36, y: 704, width: 952, height: 36),
            withAttributes: titleAttributes
        )

        let clippedBody = body.split(separator: "\n").prefix(22).joined(separator: "\n")
        (clippedBody as NSString).draw(
            in: CGRect(x: 36, y: images.isEmpty ? 72 : 360, width: 952, height: images.isEmpty ? 600 : 320),
            withAttributes: bodyAttributes
        )

        let thumbs = images.prefix(4)
        for (offset, ciImage) in thumbs.enumerated() {
            guard let cgImage = syntheticImageContext.createCGImage(ciImage, from: ciImage.extent) else { continue }
            let nsImage = NSImage(cgImage: cgImage, size: ciImage.extent.size)
            let row = offset / 2
            let col = offset % 2
            let rect = CGRect(x: 36 + col * 494, y: 48 + row * 150, width: 458, height: 132)
            nsImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        guard let tiff = image.tiffRepresentation else { return nil }
        return CIImage(data: tiff)
    }

    private static let syntheticImageContext = CIContext()

    private static func clean(_ text: String) -> String {
        var stripped = text.replacingOccurrences(of: "\r\n", with: "\n")
        stripped = stripped.replacingOccurrences(of: "\r", with: "\n")
        let collapsed = stripped.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Cache

/// Caches extracted text so refinements, regenerations, and follow-up turns in a
/// session don't re-parse the same plain text/RTF/legacy Word files. Visual
/// blocks are deliberately not cached so CIImage-backed memory does not build up.
actor SourceExtractionCache {
    static let shared = SourceExtractionCache()
    private static let entryLimit = 20

    private struct Entry {
        var modified: Date?
        var extracted: ExtractedSource
        var lastAccessed: Date
    }

    private var store: [String: Entry] = [:]

    func cached(for source: StudySource) -> ExtractedSource? {
        let key = key(for: source)
        guard var entry = store[key] else { return nil }
        if entry.modified != currentModificationDate(for: source) {
            store[key] = nil
            return nil
        }
        entry.lastAccessed = Date()
        store[key] = entry
        return entry.extracted
    }

    func store(_ extracted: ExtractedSource, for source: StudySource) {
        store[key(for: source)] = Entry(
            modified: currentModificationDate(for: source),
            extracted: extracted.textOnlyCacheCopy,
            lastAccessed: Date()
        )
        evictIfNeeded()
    }

    private func key(for source: StudySource) -> String {
        source.accessibleURL.absoluteString
    }

    private func currentModificationDate(for source: StudySource) -> Date? {
        let url = source.accessibleURL
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // O(n log n) sort is fine here — entryLimit is 20.
    private func evictIfNeeded() {
        guard store.count > Self.entryLimit else { return }
        let overflow = store.count - Self.entryLimit
        let keys = store
            .sorted { $0.value.lastAccessed < $1.value.lastAccessed }
            .prefix(overflow)
            .map(\.key)
        for key in keys {
            store[key] = nil
        }
    }
}

enum SourceExtractorError: Error, CustomStringConvertible {
    case unreadable(String)
    case unsupported(String)

    var description: String {
        switch self {
        case .unreadable(let message), .unsupported(let message):
            return message
        }
    }
}

private enum OfficeContentRef {
    case text(String)
    case imageRef(String)
}

private struct WorkbookSheet {
    var name: String
    var relationshipID: String
}

private final class RelationshipXMLParser: NSObject, XMLParserDelegate {
    var relationships: [String: String] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship",
              let id = attributeDict["Id"],
              let target = attributeDict["Target"] else {
            return
        }
        relationships[id] = target
    }
}

private final class TextAndImageXMLParser: NSObject, XMLParserDelegate {
    private(set) var refs: [OfficeContentRef] = []
    private var collectingText = false
    private var buffer = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        switch name {
        case "t":
            collectingText = true
        case "tab":
            buffer += "\t"
        case "br":
            buffer += "\n"
        case "blip":
            flush()
            if let id = attributeDict["r:embed"] ?? attributeDict["embed"] {
                refs.append(.imageRef(id))
            }
        case "drawing":
            if let id = attributeDict["r:id"] ?? attributeDict["id"] {
                refs.append(.imageRef(id))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingText {
            buffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        switch name {
        case "t":
            collectingText = false
        case "p", "tr":
            buffer += "\n"
        case "tc":
            buffer += "\t"
        default:
            break
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) {
        flush()
    }

    private func flush() {
        let cleaned = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            refs.append(.text(cleaned))
        }
        buffer = ""
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private final class PresentationXMLParser: NSObject, XMLParserDelegate {
    var slideRelationshipIDs: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName) == "sldId",
              let id = attributeDict["r:id"] ?? attributeDict["id"] else {
            return
        }
        slideRelationshipIDs.append(id)
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private final class SharedStringsXMLParser: NSObject, XMLParserDelegate {
    var values: [String] = []
    private var inText = false
    private var current = ""

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if localName(elementName) == "t" {
            inText = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText {
            current += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        if name == "t" {
            inText = false
        } else if name == "si" {
            values.append(current)
            current = ""
        }
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private final class WorkbookXMLParser: NSObject, XMLParserDelegate {
    var sheets: [WorkbookSheet] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName) == "sheet",
              let name = attributeDict["name"],
              let id = attributeDict["r:id"] ?? attributeDict["id"] else {
            return
        }
        sheets.append(WorkbookSheet(name: name, relationshipID: id))
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}

private final class WorksheetXMLParser: NSObject, XMLParserDelegate {
    private let sharedStrings: [String]
    private var currentCellRef: String?
    private var currentCellType: String?
    private var collectingValue = false
    private var valueBuffer = ""
    private var currentRowValues: [String] = []
    var rows: [String] = []

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = localName(elementName)
        switch name {
        case "c":
            currentCellRef = attributeDict["r"]
            currentCellType = attributeDict["t"]
            valueBuffer = ""
        case "v", "t":
            collectingValue = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingValue {
            valueBuffer += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = localName(elementName)
        switch name {
        case "v", "t":
            collectingValue = false
        case "c":
            let resolved = resolve(valueBuffer.trimmingCharacters(in: .whitespacesAndNewlines), type: currentCellType)
            if !resolved.isEmpty {
                let label = currentCellRef ?? "Cell"
                currentRowValues.append("\(label): \(resolved)")
            }
            currentCellRef = nil
            currentCellType = nil
            valueBuffer = ""
        case "row":
            if !currentRowValues.isEmpty {
                rows.append(currentRowValues.joined(separator: " | "))
                currentRowValues = []
            }
        default:
            break
        }
    }

    private func resolve(_ raw: String, type: String?) -> String {
        if type == "s", let index = Int(raw), sharedStrings.indices.contains(index) {
            return sharedStrings[index]
        }
        return raw
    }

    private func localName(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }
}
