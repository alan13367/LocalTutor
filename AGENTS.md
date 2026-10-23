# LocalTutor

Native macOS app for studying with local AI models. SwiftUI + MLX Swift. Premium feel, real tutor experience.

## Stack

- Swift 6.0 (strict concurrency), macOS 26.0+, App Sandbox
- SwiftUI with Liquid Glass (`NavigationSplitView` + `.inspector`, `@Observable` state)
- MLX Swift (v0.32.3) + mlx-swift-lm for on-device LLM inference, `MLXGuidedGeneration` for schema-constrained JSON
- mlx-swift-lm is vendored as a local package in `Vendor/mlx-swift-lm` (upstream `main` @ `bb0d5b04`, needed for EmbeddingGemma 2) with one local patch: Gemma 4 image/video prompts prefill in chunks that never split a vision block, with block-bidirectional masks that account for cached keys, and return logits only for the final positions (`Libraries/MLXVLM/Models/Gemma4.swift`). Upstream processed the whole prompt in one pass with logits for every position, which crashed on notebook-sized prompts with page images. Re-apply the patch when updating, or drop the vendored copy once upstream fixes it. It also carries one local addition, `Libraries/MLXLLM/Models/Flint.swift` (port of the unreleased mlx-lm Flint model, ml-explore/mlx-lm PR #1998), registered at runtime by `FlintRegistration.register()` from the runner because the vendored files are read-only; drop it once upstream ships Flint
- Apple FoundationModels (Apple Intelligence) for small helper tasks when available
- SPM via Xcode (no standalone Package.swift)

## Build & Test

- Open `LocalTutor.xcodeproj` in Xcode, scheme `LocalTutor`
- Build: Cmd+B | Test: Cmd+U
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) — not XCTest
- No linter/formatter configured

## Architecture

Notebook model: `Notebook` → sources, chats (`NotebookChat` → `StudyTurn`), Studio items (`StudioItem`), notes, flashcard review states. One JSON file per notebook (`NotebookPersistence`); legacy `study-sessions.json` is migrated once.

App state lives in `Views/State`: `AppModel` composes `NotebookStore`, `ModelManager`, `SourceLibrary`, `ChatController`, `StudioController` (all `@MainActor @Observable`). The center pane is a stage (`AppModel.stage`, `WorkspaceStage`): the chat, or a Studio item, note or flashcard review opened in place under a header tinted by the tool (`StudyResourceKind.tint`), with the chat composer still docked below (hidden for notes). Studio things never open as sheets; players inside the stage scope their keyboard shortcuts to their own focus (`onKeyPress`) so they don't steal typing from the composer. Streaming text goes into a per-response `LiveGeneration`, which reveals it smoothly (`RevealPacer`) and is committed to the notebook when finished. `MarkdownStreamRenderer` parses completed blocks once and re-parses only the in-progress tail, healed by `MarkdownStreamHealer` so unfinished markup never flashes.

Inference: `InferenceService` protocol, `LocalModelRunner` actor. Requests queue through `GenerationGate` (FIFO). Chat uses `ChatSession` continuation so follow-ups reuse the KV cache; Studio uses single-shot runs, and structured kinds (flashcards, quiz, mind map, audio) use guided JSON generation.

Model catalog: `Resources/ModelCatalog.json` (standard MLX quantizations only, never OptiQ). Entries can override `maxTokens`, `temperature`, `topP`, `topK` and set `quantizeKVCache: false`. Flint 40B-A2.5B (`flint40B_A2B`, community `mlx-community/flint-mixed-3-4bit`) needs that: its attention sinks have no quantized-attention path, it always reasons in `<think>` (its template has no switch), so it gets an 8K output allowance and Recursive's sampling (1.0 / 0.95 / 20). Its chat template uses a `\x00` escape that swift-jinja reads as `x00`; `ChatTemplateCompatibility` rewrites it to a real NUL in the downloaded template before loading. Gemma 4 entries list an MTP drafter (`drafterRepository`); the runner downloads it with the model and decodes with an unquantized KV cache. MTP is chosen per model (`SpeculativeDecodingPreference`, the Settings toggle follows the selected model) and is off by default where the catalog sets `speculativeDecodingByDefault: false`: on Gemma 4 26B-A4B verifying drafts wakes extra experts, so it decodes faster without it (≈85 vs 61–72 tok/s on an M4 Max). `ModelManager` applies the choice to the runner before each preload, and the context budget only reserves drafter weights and fp16 KV when MTP is on. Generation runs under an MLX wired-memory ticket sized to weights + KV (`LocalModelRunner.wiredBytes`) so weights stay resident under memory pressure. `ChatSession` has no MTP support, so the MTP chat path keeps its own token ledger + KV cache. A follow-up in the same chat appends only the new user turn (its tokens are the common suffix of two template renders that differ only in a probe answer), never a re-render of the past, so retrieval excerpts, page images and answer clean-up can't break reuse; it rebuilds from history when the chat, instructions or completed-turn count change, or the context is full. Downloads resume from `.partial` files via HTTP Range and are paused/cancelled through `ModelManager`. Context window is computed per Mac by `ContextBudget`: the model's native limit and KV cost come from its downloaded `config.json` (`ModelArchitecture`, catalog values before download), memory fit uses the GPU working set, and the Balanced preference also caps by prefill speed measured on this Mac (`PrefillSpeedStore`). No fixed per-tier caps.

Source pipeline: Extract → Index (chunk + headings) → Retrieve (heading match + BM25 + EmbeddingGemma 2 text embeddings) → Pack (token budget) → numbered excerpts `[n]` → Infer → clickable citations. Chat puts the whole notebook in the stable instructions prefix when it fits, otherwise retrieves per question. PDF pages without a text layer (scans, handwriting) are OCR'd with Vision at extraction and marked with `SourceExtractor.scannedPageNote`. Whole-notebook Studio items skip document page renders (standalone image sources still go in), distill the notebook section by section when it exceeds the model's synthesis budget (`SourceContextPlanner.synthesisBudget`, by memory tier: 8K / 12K / 24K tokens), and run free-text kinds with native thinking (`enable_thinking`, `StudyPromptBuilder.thinkingSystemInstruction`, which must not name `<think>` tags or Gemma 4 leaves its thought channel unclosed) plus a separate `StudioController.thinkingTokens` allowance; chat keeps thinking off. If a run ends with no visible text, `GenerationCollector` recovers the answer from the reasoning (`ReasoningOutputFilter.recoveredAnswer`). The response language comes from a sample of the original source text, not the distilled notes.

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
- Notebook summary evaluation: serve a folder of sources over HTTP (the sandboxed test host can't read arbitrary paths), e.g. `python3 -m http.server 8765 --bind 127.0.0.1`, then `TEST_RUNNER_LOCALTUTOR_EVAL_URL=http://127.0.0.1:8765/ TEST_RUNNER_LOCALTUTOR_EVAL_FILES=a.pdf,b.pdf xcodebuild test -only-testing:LocalTutorTests/NotebookSummaryEvaluation` runs the real Studio summary pipeline and prints `[eval]` lines with the output (`TEST_RUNNER_LOCALTUTOR_EVAL_REPEATS=n` repeats the final step to check thinking reliability)
- Speed numbers (tok/s) are only meaningful from optimized builds: run tests with `-configuration Release -derivedDataPath build/bench ENABLE_TESTABILITY=YES`. Debug decode is CPU-bound (≈3× slower) and makes MTP look like a win when it isn't
- Retrieval benchmark: `-only-testing:LocalTutorTests/RetrievalBenchmarkTests` prints `[benchmark]` hit@1 / recall@5 / MRR@10 lines; lexical always runs, dense + hybrid need `TEST_RUNNER_LOCALTUTOR_INTEGRATION=1` (downloads EmbeddingGemma 2)

## Status

Notebook workspace (sources · chat · Studio), onboarding, Settings window. Model Lab is a DEBUG-only window.