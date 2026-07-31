# Contributing to Parla

Thanks for your interest! Parla is a native SwiftUI, 100%-on-device transcription app for macOS and
iOS/iPadOS. This guide covers how to build, test, and send changes.

## Build & run

See the [README](README.md#build--run) for full prerequisites. In short:

```bash
# macOS (no Apple account needed — ad-hoc signed)
./build_app.sh && open Parla.app

# iOS (needs Xcode signing + your own bundle IDs — see the README)
cd apps/ios && brew install xcodegen && xcodegen generate && open Parla-iOS.xcodeproj
```

> **Run the macOS app as the built `.app`**, not via `swift run` or an IDE Run button — a windowed
> SwiftUI app needs a real bundle to show its window.

## Tests

```bash
swift test          # macOS pure-logic suite (320+ tests) — run this before every PR
```

The iOS test target runs from Xcode (⌘U). Some decode/transcription tests need a local voice fixture
that is **never committed** (voice stays out of git) — those `XCTSkip` when it's absent; that's expected,
not a failure.

**Every change must keep `swift test` green.** If you touch shared code in `Sources/ParlaCore`, also build
the macOS app (`./build_app.sh`) and, if iOS is affected, the iOS target — the macOS app must not regress.

## Project layout

```
Sources/ParlaCore/   cross-platform library — engine, view-model, on-device AI, audio-decode seams
Sources/Parla/       macOS app (thin SwiftUI shell + menu bar + macOS-only integrations)
apps/ios/            iOS · iPadOS app (XcodeGen project) + Share & Widgets extensions
Localization/        en / ru / uk .lproj (shared by both apps)
Vendor/ffmpeg/       bundled LGPL ffmpeg + build recipe
```

The architecture is described in the [README](README.md#architecture): one cross-platform `ParlaCore`
library, thin native apps, platform differences behind injected seams (`AppModel.mac()` / `AppModel.iOS()`).

## Commit & PR conventions

- **Atomic commits**, Conventional-Commits style: `type(scope): summary` (e.g. `fix(ios): …`,
  `feat(core): …`, `docs: …`). One logical change per commit; tests in the same commit as the code they cover.
- **Green before you commit:** `swift test` (+ the relevant build) must pass.
- Match the surrounding code — comment density, naming, and idiom. No large unrelated reformatting.
- Open a PR against `main` with a clear description of *what* and *why*. Small, focused PRs review fastest.

## Load-bearing invariants (please don't regress these)

These are subtle and easy to break — a reviewer will look for them:

- **Every new `TranscriptItem` field must be `Optional`.** Swift's synthesized `Decodable` throws
  `keyNotFound` on old JSON for a non-optional new field, and history-load's `?? []` then **wipes the
  archive**. A legacy-JSON decode test pins this — extend it when you add a field.
- **WhisperKit special tokens** are stripped at the source *and* again on display/export
  (`stripWhisperTokens` / `Segment.cleanText`). Keep both.
- **Long audio (>~10 min)** goes through the chunked pipeline; chunk cuts land exactly on chunk boundaries
  so the stitched timeline stays drift-free.
- **The on-device AI / TTS / Live-Activity / widget paths are best-effort** — a failure there must **never**
  touch the transcript (the text is the product).
- **`NLContextualEmbedding` vectors** are comparable only within one script and are anisotropic — mean-center
  before cosine, and bump the `extractive-vN` provenance tag when the insight pipeline changes.
- **Localization:** every user-facing string key must exist in all three of `en` / `ru` / `uk`
  (a key-parity test enforces it).

## Reporting bugs / requesting features

Use the issue templates. For anything security-related, see [SECURITY.md](SECURITY.md).

## License

Parla's source is offered publicly under the [PolyForm Noncommercial License 1.0.0](LICENSE) (from v1.1.0 onward;
the v1.0.0 release remains under the MIT License), while the maintainer distributes official builds under separate
commercial terms. To keep that possible, contributions are accepted under a permissive inbound grant:

> By submitting a contribution (e.g. a pull request), you certify that you wrote it or otherwise have the right to
> submit it, and you grant the project maintainer, Oleksandr Uskov, a perpetual, worldwide, non-exclusive,
> royalty-free, irrevocable license to use, reproduce, modify, distribute, sublicense, and relicense your
> contribution as part of Parla — including under the PolyForm Noncommercial License 1.0.0 and under separate
> commercial terms for official distribution.

Contributions are certified under the [Developer Certificate of Origin](https://developercertificate.org/); please
sign off your commits with `git commit -s`.
