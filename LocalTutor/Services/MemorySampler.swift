//
//  MemorySampler.swift
//  LocalTutor
//
//

import Foundation
import Darwin

actor MemorySampler {
    private var samplingTask: Task<Void, Never>?
    private var peakBytes: UInt64 = 0

    func start() {
        stop()
        peakBytes = ProcessFootprint.currentPhysicalFootprintBytes()
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                let footprint = ProcessFootprint.currentPhysicalFootprintBytes()
                await self?.record(footprint)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stopAndReturnPeak() -> UInt64 {
        stop()
        return peakBytes
    }

    private func stop() {
        samplingTask?.cancel()
        samplingTask = nil
    }

    private func record(_ bytes: UInt64) {
        peakBytes = max(peakBytes, bytes)
    }
}

enum ProcessFootprint {
    static func currentPhysicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return 0
        }

        return UInt64(info.phys_footprint)
    }
}
