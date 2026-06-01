//
//  DocumentBlocks.swift
//  LocalTutor
//

import CoreGraphics
import CoreImage
import Foundation

struct DocumentImage: Sendable {
    var image: CIImage
    var sourceName: String
    var locator: String?
    var caption: String?
    var isStandalone: Bool
    var originalSize: CGSize

    var displayCaption: String {
        var parts: [String] = []
        parts.append(isStandalone ? "Attached image" : "Document image")
        parts.append(sourceName)
        if let locator, !locator.isEmpty {
            parts.append(locator)
        }
        if let caption, !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(caption)
        }
        return parts.joined(separator: " - ")
    }
}

enum DocumentBlock: Sendable {
    case text(String)
    case image(DocumentImage)

    var textValue: String? {
        if case .text(let text) = self {
            return text
        }
        return nil
    }

    var imageValue: DocumentImage? {
        if case .image(let image) = self {
            return image
        }
        return nil
    }
}

struct SourceExtractionOptions: Sendable, Equatable {
    var imageLimit: Int
    var imageResize: CGSize?
    var minEmbeddedImageDimension: CGFloat

    var allowsImages: Bool {
        imageLimit > 0
    }

    static func defaults(for defaults: ModelRuntimeDefaults) -> SourceExtractionOptions {
        SourceExtractionOptions(
            imageLimit: defaults.documentImageLimit,
            imageResize: defaults.imageResize,
            minEmbeddedImageDimension: defaults.minEmbeddedImageDimension
        )
    }
}
