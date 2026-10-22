//
//  AppInfo.swift
//  LocalTutor
//
//

import Foundation

enum AppInfo {
    static var version: String {
        let info = Bundle.main.infoDictionary
        let marketingVersion = info?["CFBundleShortVersionString"] as? String
        let buildNumber = info?["CFBundleVersion"] as? String

        switch (marketingVersion, buildNumber) {
        case let (marketingVersion?, buildNumber?):
            return "\(marketingVersion) (\(buildNumber))"
        case let (marketingVersion?, nil):
            return marketingVersion
        default:
            return "0"
        }
    }
}

enum SystemInfo {
    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    static var chipName: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Apple silicon" : name
    }
}

extension UInt64 {
    static let gibibyte: UInt64 = 1_073_741_824

    var gibibytesDescription: String {
        ByteCountFormatter.localTutorMemoryString(fromByteCount: Int64(self))
    }
}

extension Int {
    static let gibibyte = 1_073_741_824
}

extension Double {
    static let gibibyte = 1_073_741_824.0
}

extension BinaryInteger {
    var gibibytes: UInt64 {
        UInt64(self) * UInt64.gibibyte
    }
}

extension ByteCountFormatter {
    static func localTutorMemoryString(fromByteCount byteCount: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.includesUnit = true
        formatter.includesCount = true
        return formatter.string(fromByteCount: byteCount)
    }
}

extension DateFormatter {
    static func localTutorBenchmarkFilename(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

extension JSONEncoder {
    static var localTutorBenchmark: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var localTutorBenchmark: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
