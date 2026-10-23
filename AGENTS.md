# LocalTutor

Native macOS app for studying with local AI models. SwiftUI + MLX Swift. Premium feel, real tutor experience.

## Stack

- Swift 6.0 (strict concurrency), macOS 26.0+, App Sandbox
- SwiftUI with Liquid Glass (`NavigationSplitView` + `.inspector`, `@Observable` state)
- MLX Swift (v0.32.3) + mlx-swift-lm (pinned to a `main` revision for EmbeddingGemma 2 support; move back to a tagged release once one includes it) for on-device LLM inference, `MLXGuidedGeneration` for schema-constrained JSON
- Apple FoundationModels (Apple Intelligence) for small helper tasks when available
- SPM via Xcode (no standalone Package.swift)

## Build & Test

- Open `LocalTutor.xcodeproj` in Xcode, scheme `LocalTutor`
- Build: Cmd+B | Test: Cmd+U
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) — not XCTest
- No linter/formatter configured

## Architecture

Notebook model: `Notebook` → sources, chats (`NotebookChat` → `StudyTurn`), Studio items (`StudioItem`), notes, flashcard review states. One JSON file per notebook (`NotebookPersistence`); legacy `study-sessions.json` is migrated once.

App state lives in `Views/State`: `AppModel` composes `NotebookStore`, `ModelManager`, `SourceLibrary`, `ChatController`, `StudioController` (all `@MainActor @Observable`). Streaming text goes into a per-response `LiveGeneration`, which reveals it smoothly (`RevealPacer`) and is committed to the notebook when finished. `MarkdownStreamRenderer` parses completed blocks once and re-parses only the in-progress tail, healed by `MarkdownStreamHealer` so unfinished markup never flashes.

Inference: `InferenceService` protocol, `LocalModelRunner` actor. Requests queue through `GenerationGate` (FIFO). Chat uses `ChatSession` continuation so follow-ups reuse the KV cache; Studio uses single-shot runs, and structured kinds (flashcards, quiz, mind map, audio) use guided JSON generation.

Model catalog: `Resources/ModelCatalog.json` (standard MLX quantizations only, never OptiQ). Gemma 4 entries list an MTP drafter (`drafterRepository`); the runner downloads it with the model and decodes with an unquantized KV cache. `ChatSession` has no MTP support, so the MTP chat path keeps its own token ledger + KV cache and only appends the new prompt suffix (falls back to a full prefill when the prefix doesn't match). Downloads resume from `.partial` files via HTTP Range and are paused/cancelled through `ModelManager`. Context window is computed per Mac by `ContextBudget`: the model's native limit and KV cost come from its downloaded `config.json` (`ModelArchitecture`, catalog values before download), memory fit uses the GPU working set, and the Balanced preference also caps by prefill speed measured on this Mac (`PrefillSpeedStore`). No fixed per-tier caps.

Source pipeline: Extract → Index (chunk + headings) → Retrieve (heading match + BM25 + EmbeddingGemma 2 text embeddings) → Pack (token budget) → numbered excerpts `[n]` → Infer → clickable citations. Chat puts the whole notebook in the stable instructions prefix when it fits, otherwise retrieves per question.

## Structure

```
LocalTutor/
  Models/       Domain types (ModelProfile, StudySession, StudyTurn, etc.)
  Services/     Business logic (LocalModelRunner, SourceExtractor, SourceIndex, etc.)
  Resources/    ModelCatalog.json, SampleNotebook.md, Localizable.xcstrings
  Views/        SwiftUI screens (workspace, sources, chat, studio, settings, onboarding)
    State/      @Observable app state and controllers
    Components/ Reusable UI (markdown, flashcards, quiz, mind map, audio overview)
  Support/      Constants, helpers, file paths
scripts/        release.sh (archive → notarize → staple)
LocalTutorTests/  Swift Testing tests
```

## Conventions

- No comments unless asked
- `@MainActor @Observable` for app state, `actor` for thread-safe services
- Streaming: paced character reveal at ~60fps with incremental markdown rendering
- Persistence: JSON to Application Support, debounced saves (700ms)
- `#if DEBUG` for debug-only surfaces (e.g. the Model Lab window)
- The app folder uses file system sync; test files in `LocalTutorTests/` still need pbxproj entries
- Real-model checks: `TEST_RUNNER_LOCALTUTOR_INTEGRATION=1 xcodebuild test -only-testing:LocalTutorTests/ModelIntegrationTests` (downloads a model; `TEST_RUNNER_LOCALTUTOR_INTEGRATION_MODEL=<catalog id>` to pick one)
- Retrieval benchmark: `-only-testing:LocalTutorTests/RetrievalBenchmarkTests` prints `[benchmark]` hit@1 / recall@5 / MRR@10 lines; lexical always runs, dense + hybrid need `TEST_RUNNER_LOCALTUTOR_INTEGRATION=1` (downloads EmbeddingGemma 2)

## Status

Notebook workspace (sources · chat · Studio), onboarding, Settings window. Model Lab is a DEBUG-only window.