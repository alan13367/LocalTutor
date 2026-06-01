# LocalTutor

Native macOS app for studying with local AI models. SwiftUI + MLX Swift. Premium feel, real tutor experience.

## Stack

- Swift 6.0 (strict concurrency), macOS 26.5+, App Sandbox
- SwiftUI (`NavigationSplitView`, `@StateObject`/`@Published`)
- MLX Swift (v0.31.3) + mlx-swift-lm for on-device LLM inference
- SPM via Xcode (no standalone Package.swift)

## Build & Test

- Open `LocalTutor.xcodeproj` in Xcode, scheme `LocalTutor`
- Build: Cmd+B | Test: Cmd+U
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) — not XCTest
- No linter/formatter configured

## Architecture

MVVM. ViewModels are `@MainActor final class : ObservableObject`. Services use protocols (`InferenceService`) with actor implementations (`LocalModelRunner`).

Source pipeline: Extract → Index (chunk + headings) → Retrieve (heading match + BM25) → Pack (token budget) → Prompt → Infer.

## Structure

```
LocalTutor/
  Models/       Domain types (ModelProfile, StudySession, StudyTurn, etc.)
  Services/     Business logic (LocalModelRunner, SourceExtractor, SourceIndex, etc.)
  Views/        SwiftUI views + ViewModels
    Components/ Reusable UI components
  Support/      Constants, helpers, file paths
LocalTutorTests/  Swift Testing tests
```

## Conventions

- No comments unless asked
- `@MainActor` on ViewModels, `actor` for thread-safe services
- Streaming: token-by-token with coalesced UI flushes (~25fps)
- Persistence: JSON to Application Support, debounced saves (700ms)
- `#if DEBUG` for test-only APIs (e.g. `setRunningForTesting`)
- Xcode uses file system sync (no manual pbxproj file refs needed)

## Status

Early. Model Lab (debug) and Study Workspace (main app) exist.