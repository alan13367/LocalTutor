//
//  MemoryPreflight.swift
//  LocalTutor
//
//

import Foundation
import Darwin

struct MemoryPreflightResult: Equatable, Sendable {
    var canRun: Bool
    var systemMemoryBytes: UInt64
    var requiredBytes: UInt64
    var message: String
}

enum MemoryPreflight {
    static func evaluate(profile: ModelProfile, systemMemoryBytes: UInt64 = SystemMemory.totalBytes()) -> MemoryPreflightResult {
        let policy = ModelRuntimePolicyProvider.policy(for: profile, systemMemoryBytes: systemMemoryBytes)
        return evaluate(policy: policy)
    }

    static func evaluate(policy: ModelRuntimePolicy) -> MemoryPreflightResult {
        let requiredBytes = policy.minimumSystemMemoryBytes
        let canRun = policy.systemMemoryBytes >= requiredBytes
        let systemMemory = ByteCountFormatter.localTutorMemoryString(fromByteCount: Int64(policy.systemMemoryBytes))
        let required = ByteCountFormatter.localTutorMemoryString(fromByteCount: Int64(requiredBytes))
        let message = canRun
            ? "System memory \(systemMemory) meets \(required) requirement."
            : "Not enough system memory for \(policy.profileName). This Mac has \(systemMemory), requires \(required)."

        return MemoryPreflightResult(
            canRun: canRun,
            systemMemoryBytes: policy.systemMemoryBytes,
            requiredBytes: requiredBytes,
            message: message
        )
    }
}

enum SystemMemory {
    static func totalBytes() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    static func availableBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return ProcessInfo.processInfo.physicalMemory
        }

        var hostPageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &hostPageSize)
        let pageSize = UInt64(hostPageSize)
        let free = UInt64(stats.free_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        return free + inactive + speculative
    }
}
