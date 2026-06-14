<p align="center">
  <img src="LocalTutor/Assets.xcassets/AppIcon.appiconset/LocalTutorIcon-256x256@2x.png" width="128" height="128" alt="LocalTutor app icon" />
</p>

<h1 align="center">LocalTutor</h1>

<p align="center">
  A native macOS study companion powered by on-device AI.<br />
  Drop your files, pick a model, and study — everything stays on your Mac.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026.5%2B-blue" alt="macOS 26.5+" />
  <img src="https://img.shields.io/badge/chip-Apple%20Silicon-orange" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License" />
</p>

---

## Screenshots

![LocalTutor study workspace — drop files, pick a starting point, and study with a local model](docs/screenshots/mainWindow.png)

---

## Why LocalTutor

Most AI study tools send your notes to someone else's server. LocalTutor doesn't — every model runs on your Mac through Apple's [MLX](https://github.com/ml-explore/mlx-swift) framework, so your lecture slides, textbook PDFs, and class notes never leave your device. No API keys, no subscriptions, no cloud.

It's designed to feel like sitting down with a real tutor: you bring your materials, ask questions, and get answers grounded in what you're actually studying.

---

## Features

### 📚 Study with your own materials

Drop or attach files and LocalTutor builds a searchable index of your content in seconds. Supported formats include:

| Category | Formats |
|----------|---------|
| Documents | PDF, Word (`.docx`), Pages, RTF, ePub |
| Spreadsheets | Excel (`.xlsx`), Numbers |
| Presentations | PowerPoint (`.pptx`), Keynote |
| Images | JPEG, PNG, TIFF, HEIC, WebP |
| Text | Markdown, plain text, CSV, JSON, XML, HTML |
| Web | Web archives (`.webarchive`) |

Vision-capable models can read diagrams, charts, and handwritten notes directly from images and PDF pages.

### 💬 Conversational tutoring

Ask questions in natural language and get streaming, markdown-rendered answers grounded in your sources. The tutor cites specific sections, pages, and headings so you can verify everything it says.

Three study modes adapt the tutor's behavior:

- **Focused Study** — deep-dive into a specific topic within your sources
- **Broad Overview** — survey across all attached materials for high-level understanding
- **Open Ended** — free conversation without source material

Quick-action chips let you refine any answer instantly: *Expand · Simplify · Example · Why? · Deeper · Summarize · Compare · Related Topics*.

### 🃏 Flashcards

Generate flashcard decks from your sources with a single click. Each card includes a difficulty rating (easy, medium, hard) and the built-in player lets you flip, navigate, and shuffle through your deck — no export needed.

### ✅ Quizzes

Generate multiple-choice quizzes grounded in your materials. The quiz player scores your answers in real time, shows explanations for each question, and gives you a final breakdown when you're done.

### 🔍 Smart retrieval

LocalTutor doesn't just dump your files into a prompt. A multi-stage retrieval pipeline finds the most relevant content for each question:

1. **Heading matching** — recognizes section numbers, chapter titles, and heading hierarchies
2. **Lexical search** — BM25 ranking via a persistent SQLite FTS5 index
3. **Semantic search** — on-device vector embeddings (Gemma Embedder 300M) for meaning-based retrieval
4. **Hybrid fusion** — combines lexical and semantic results with Reciprocal Rank Fusion
5. **Context packing** — fits the best content into the model's token budget with proportional allocation

All of this happens locally and automatically — you just ask your question.

### 🧠 Model library

Choose from models tiered to your Mac's memory:

| Tier | Models | Capabilities |
|------|--------|-------------|
| **8 GB** | Gemma 3 1B, Qwen 3 1.7B | Text tutoring, fast responses |
| **16 GB** | Gemma 3 4B, Qwen 3 4B, Phi-4 Mini | Multimodal vision, stronger reasoning |

Models are downloaded once from Hugging Face and cached locally. A memory preflight check prevents loading a model that won't fit, and runtime policies cap generation length and source budgets per model.

### ⚡ Performance

- Token-by-token streaming at ~25 fps for responsive answers
- Built-in benchmark suite measuring prefill speed, generation throughput, and time-to-first-token
- Automatic embedding model lifecycle — loads for indexing/queries, unloads after 20 seconds of idle to free memory
- Debounced session persistence so your study history is always saved

### 🔒 Privacy

- **Fully offline** — inference, indexing, and retrieval all happen on-device
- **App Sandbox** enabled — file access uses security-scoped bookmarks
- **No telemetry, no accounts, no cloud**

---

## Requirements

| | Minimum | Recommended |
|---|---------|-------------|
| **macOS** | 26.5 | Latest |
| **Chip** | Apple Silicon | Apple Silicon |
| **Memory** | 8 GB unified | 16 GB unified |
| **Xcode** | 16+ | Latest |

---

## Getting started

1. **Clone and open:**

   ```bash
   git clone https://github.com/alan13367/LocalTutor.git
   cd LocalTutor
   ```

2. Open `LocalTutor.xcodeproj` in Xcode.

3. Select the **LocalTutor** scheme and press **⌘R**.

4. Open **Settings** (**⌘,**) → download a tutor model. Smaller models (1B–1.7B) download in minutes and run on any Apple Silicon Mac.

5. Drag your study files into the workspace, type a question, and start studying. Try generating flashcards or a quiz from the toolbar.

---

## Project structure

```
LocalTutor/
├── Views/              SwiftUI — Study Workspace, Settings, artifact players
│   └── Components/     Flashcard player, quiz player, composer, refinement chips
├── Services/           Model runner, source extraction, indexing, retrieval, embedding
├── Models/             Model profiles, study sessions, artifacts, runtime policies
└── Support/            Constants, helpers, file paths

LocalTutorTests/        Unit tests (Swift Testing)
```

## Tech stack

- **SwiftUI** — native macOS interface with `NavigationSplitView`
- **[MLX Swift](https://github.com/ml-explore/mlx-swift)** + **[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)** — on-device LLM and embedding inference
- **[swift-huggingface](https://github.com/huggingface/swift-huggingface)** — model downloads from Hugging Face Hub
- **SQLite / FTS5** — persistent source indexing and full-text search
- **CryptoKit** — content fingerprinting for cache invalidation
- **Accelerate / vDSP** — fast vector similarity for semantic search

## License

[MIT](LICENSE) — Copyright (c) 2026 Alan Beltran Pozo
