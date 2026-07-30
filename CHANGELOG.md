# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

Initial release: a Swift 6, SwiftUI-first wrapper over rive-ios's Concurrency runtime.

### Added

- **Loading and caching** — `RiveSource` (bundle / URL / in-memory data), `RiveEngine` actor with a shared document cache, in-flight load coalescing, `preloadDocuments(for:)`, and explicit eviction. `RiveDocument.load(_:)` as the one-line entry point.
- **SwiftUI views** — `RiveView` for loaded documents and bound instances; `AsyncRiveView` with `AsyncImage`-style `AsyncRivePhase` handling (reappearing with an unchanged source keeps the rendered view instead of flashing the placeholder). Changing `artboard` / `stateMachine` values rebuilds the render pipeline hitch-free while the parsed document stays cached. Disappearing without removal (tab switch, navigation push) only pauses playback, so state machines resume where they left off; deterministic teardown happens when the view is actually removed from the hierarchy.
- **Typed schemas** — `RiveSchema` with `RiveKey<Value>` / `RiveTriggerKey` typed property paths (nested `"card/title"` paths supported), `RiveEnum` for file enums, and load-time validation that aggregates **all** mismatches (missing view model, missing property, type mismatch, enum case drift) into one `RiveSchemaError`. `validate(_:artboard:)` and `makeInstance(of:artboard:)` take an optional artboard name so a schema with a `nil` `viewModelName` can anchor to a specific artboard's default view model (default: the file's default artboard); the render host logs an error when a bound instance's view model is not the rendered artboard's default.
- **Two-way binding** — `RiveInstance<Schema>`: `@Observable` with per-key invalidation (a view reading one property does not re-render on changes to another), synchronous subscript reads/writes, SwiftUI `Binding` support via `binding(for:)`, trigger firing via `fire(_:)` and observation via `firings(of:)` `AsyncStream`s. Writes made while playback is paused still render (advance-nudge, workaround for rive-ios #383).
- **Sizing** — `document.artboardSize(named:)` / `artboardAspectRatio(named:)`, the `.riveNaturalSize()` modifier (Image-like layout participation), and `RiveNativeView` (UIKit/AppKit escape hatch) with a real `intrinsicContentSize` — a local fix for the missing size API in the runtime (rive-ios #323), implemented via a single, cached legacy-API bounds shim prewarmed off the layout path — and deterministic render-state teardown on deallocation (`isolated deinit`, mitigation for rive-ios #442/#418/#453).
- **Fit and alignment** — `RiveFit` (`contain`, `cover`, `fill`, `fitWidth`, `fitHeight`, `scaleDown`, `actualSize`, `layout(scale:)`) with per-fit `RiveAlignment` and SwiftUI-style `leading`/`trailing` naming; environment modifiers `.riveFit(_:)`, `.rivePaused(_:)`, `.riveFrameRate(_:)` (optional frames per second; `nil` restores the display default).
- **Colors** — `RiveColor` in 0–1 sRGB `Double` space with conversions from `SwiftUI.Color`, `UIColor`, and `NSColor`.
- **Diagnostics** — `document.dumpViewModels()` renders a file's full data-binding tree; all errors are `LocalizedError` with actionable messages listing available names; `os.Logger`-based logging throughout.
- **Documentation** — DocC catalog with Getting Started, Declaring Schemas, Sizing and Fit, and Migrating from RiveViewModel articles.
- **Dynamic access** — `RiveDynamicInstance` with runtime property discovery (`document.makeDynamicInstance(artboard:viewModel:)`, `document.dynamicProperties(artboard:viewModel:)`): nested view models flattened into `RiveDynamicProperty` paths, lenient string-keyed subscripts (`instance[number: path]`, `bool:`, `string:`, `color:`, `enumValue:`) and `fire(_:)` that return `nil` / no-op with a log instead of trapping, plus `RiveView` and `RiveNativeView` initializers for dynamic instances. Complements typed schemas for tooling and inspection.
- **RiveInspector demo** — minimal macOS demo app (`swift run RiveInspector [file.riv]`, `Examples/RiveInspector`): drag & drop a `.riv` file, auto-discovered artboard/fit/pause and data-binding controls via the dynamic API.

### Notes

- Requires iOS 17+ / macOS 14+, Swift 6.2, rive-ios ≥ 6.22.0.
- The package uses `internal import RiveRuntime` everywhere: no rive-ios type appears in the public API.
