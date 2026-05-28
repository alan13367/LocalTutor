//
//  MLXMemorySnapshotRecord+MLX.swift
//  LocalTutor
//
//  Created by Codex on 28/05/2026.
//

import Foundation
import MLX

extension MLXMemorySnapshotRecord {
    init(snapshot: Memory.Snapshot) {
        activeBytes = UInt64(max(0, snapshot.activeMemory))
        cacheBytes = UInt64(max(0, snapshot.cacheMemory))
        peakBytes = UInt64(max(0, snapshot.peakMemory))
    }
}
