# SwiftyRive

A Swifty, SwiftUI-first wrapper over [rive-ios](https://github.com/rive-app/rive-ios)'s new Concurrency runtime.

Rive's new Swift runtime (`Worker` / `File` / `Rive` / `ViewModelInstance`) is a solid, fully `async` foundation, but using it directly means stringly-typed property paths, manual view-model plumbing, no SwiftUI data binding, and no way to ask an artboard for its own size. SwiftyRive layers a small, strict Swift 6 API on top: typed schemas validated at load time, two-way `@Observable` binding, natural content sizing, clean fit/alignment, and a shared document cache. `RiveRuntime` is an `internal import` in every file, so no runtime type ever leaks into your code.

## SwiftyRive vs. raw rive-ios

| | raw rive-ios (Concurrency API) | SwiftyRive |
|---|---|---|
| Property access | Stringly-typed paths, checked at each call | Typed ``RiveKey`` schemas, **all** mismatches reported in one aggregated error at load time |
| SwiftUI data flow | Manual `setValue` / `valueStream` plumbing | Two-way binding: `instance[\.energy]`, `instance.binding(for: \.energy)`, `@Observable` |
| Content size | None: views can only be sized externally ([rive-ios #323](https://github.com/rive-app/rive-ios/issues/323), open since 2022) | `.riveNaturalSize()` sizes the view like `Image`; `document.artboardSize(named:)`; `RiveNativeView.intrinsicContentSize` |
| Fit / alignment | `Fit.none` naming collision, alignment easy to misapply | `RiveFit.actualSize`, alignment-carrying factories, SwiftUI-style `leading`/`trailing` naming |
| File caching | Manual | ``RiveEngine`` caches parsed documents, coalesces concurrent loads, supports preloading; switching artboards on a loaded document is hitch-free |
| Colors | 8-bit ARGB, color-space footguns | ``RiveColor`` in 0...1 sRGB `Double` space with `SwiftUI.Color` / platform-color conversions |
| Teardown | Known crash patterns on view churn | Deterministic teardown in one place |
| Paused writes / triggers | Writes invisible while paused ([#383](https://github.com/rive-app/rive-ios/issues/383)) | Automatic advance-nudge: writes and trigger fires render even while paused |

## Installation

Add the package in Xcode (**File ▸ Add Package Dependencies…**) using this repository's URL, or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/rshimoda/SwiftyRive.git", from: "0.1.0"),
]
```

Then `import SwiftyRive`.

Requirements:

- iOS 17+ / macOS 14+
- Swift 6.2 (the package builds in Swift 6 language mode with main-actor default isolation)
- [rive-ios](https://github.com/rive-app/rive-ios) ≥ 6.22.0 (resolved automatically)

## Quick Start

### Load and render

```swift
import SwiftUI
import SwiftyRive

struct Hero: View {
    @State private var document: RiveDocument?

    var body: some View {
        Group {
            if let document {
                RiveView(document, artboard: "Hero", stateMachine: "Idle")
                    .riveFit(.cover)
            }
        }
        .task {
            document = try? await RiveDocument.load(.bundle("hero"))
        }
    }
}
```

Or let the view handle loading, `AsyncImage`-style:

```swift
AsyncRiveView(source: .bundle("hero")) { phase in
    switch phase {
    case .loading: ProgressView()
    case .success(let rive): rive
    case .failure: Image(systemName: "exclamationmark.triangle")
    }
}
```

Sources can come from a bundle, a URL (local or remote), or in-memory bytes: `.bundle("hero")`, `.url(fileURL)`, `.data(bytes, identifier: "hero")`. Loads go through `RiveEngine.shared`, so equal sources are parsed once and cached.

### Typed schema + two-way binding

Declare the view-model properties you use as a schema:

```swift
enum Mood: String, RiveEnum { case idle, happy, alarmed }

struct RobotSchema: RiveSchema {
    let energy = RiveKey<Double>("energy")
    let tint = RiveKey<RiveColor>("tint")
    let mood = RiveKey<Mood>("mood")
    let title = RiveKey<String>("card/title")     // nested view-model path
    let celebrate = RiveTriggerKey("celebrate")
}
```

`makeInstance(of:artboard:)` validates the whole schema against the file first (wrong view-model name, missing property, type mismatch, enum case drift) and reports **every** problem in a single `RiveSchemaError`. After that, every key is proven valid, so reads and writes are plain synchronous Swift:

```swift
struct RobotView: View {
    let instance: RiveInstance<RobotSchema>   // from document.makeInstance(of: RobotSchema.self)

    var body: some View {
        VStack {
            RiveView(instance)
                .frame(height: 240)

            Slider(value: instance.binding(for: \.energy), in: 0...1)
            Button("Celebrate") { instance.fire(\.celebrate) }
        }
    }
}
```

Changes flow both ways: writing `instance[\.mood] = .happy` updates the animation, and changes originating inside the animation update `instance` (it is `@Observable`, so SwiftUI views track it automatically). Trigger firings can also be observed: `for await _ in instance.firings(of: \.celebrate) { ... }`.

## Sizing

The Concurrency runtime has no artboard-size API, so a raw Rive view can only be sized from the outside. SwiftyRive restores natural sizing:

```swift
VStack {
    Text("Above")
    RiveView(document, artboard: "Badge")
        .riveNaturalSize()     // participates in layout like Image
    Text("Below")
}
```

With `.riveNaturalSize()`, the view reports the artboard's authored size when nothing is proposed, derives the other axis from the aspect ratio when one axis is proposed, and defers to explicit proposals. Without it, `RiveView` is greedy and fills the proposed space (then `RiveFit` decides how content renders inside it).

You can also query sizes directly:

```swift
let size = try document.artboardSize(named: "Badge")     // authored CGSize
let ratio = try document.artboardAspectRatio(named: "Badge")
```

**Fit vs. natural size:** fit controls how content is *rendered inside* whatever rect layout provides; natural size controls the rect *itself*. They compose independently.

## Fit and alignment

```swift
RiveView(document)
    .riveFit(.contain)                              // default
    .riveFit(.cover(alignment: .topLeading))
    .riveFit(.actualSize)                           // rive's "none", renamed to say what it does
    .riveFit(.layout(scale: .automatic))            // Rive's responsive layout engine
    .rivePaused(isPaused)
    .riveFrameRate(30)
```

Available fits: `.contain`, `.cover`, `.fill`, `.fitWidth`, `.fitHeight`, `.scaleDown`, and `.actualSize`, each with an optional `RiveAlignment` (`.topLeading` through `.bottomTrailing`, SwiftUI naming). `.layout(scale:)` is the exception: the Rive layout engine positions content itself, so alignment does not apply.

## Dynamic access (no schema)

For tooling and inspection, when you do not know the file's shape up front, `makeDynamicInstance(artboard:viewModel:)` discovers every data-binding property at runtime (nested view models flattened into `"card/title"` paths) and exposes lenient, string-keyed access:

```swift
let instance = try await document.makeDynamicInstance()
for property in instance.properties {
    print(property.path, property.kind)   // "Number" number, "Nested/String" string, ...
}
instance[number: "Number"] = 42           // wrong path/kind → nil / logged no-op, never a crash
instance.fire("Trigger Red")
RiveView(instance)                        // renders just like a typed instance
```

Prefer typed schemas in application code: they prove every path at load time. The dynamic API trades that proof for discovery.

## Try it

The repository ships a tiny macOS demo app built on the dynamic API. It inspects any `.riv` file:

```sh
swift run RiveInspector            # then drag & drop any .riv file
swift run RiveInspector my.riv     # or pass a file directly
```

It auto-discovers the file's artboards and data-binding properties and renders live controls for them (sliders, toggles, color pickers, enum pickers, trigger buttons).

## How it works

SwiftyRive builds entirely on rive-ios's new Concurrency runtime, with one deliberate exception: the runtime exposes no artboard-size API, so `Sources/SwiftyRive/Internal/LegacyArtboardBounds.swift`, the **single** file touching legacy runtime types, lazily parses the same `.riv` bytes once through the legacy `RiveFile` API, reads every artboard's authored bounds in one pass, caches the result on the document, and releases the legacy objects. This shim will be deleted the moment rive-ios ships an artboard-size API in the Swift runtime ([#323](https://github.com/rive-app/rive-ios/issues/323)).

Everything else (loading, rendering, data binding, triggers) goes through the modern runtime. `RiveRuntime` is imported as `internal import` in every file, so the compiler guarantees no runtime type appears in SwiftyRive's public API.

Helpful extras:

- `document.dumpViewModels()` prints a file's full data-binding tree (view models, properties, enums). Handy when writing a schema for a file you did not author.
- Errors are `LocalizedError` with actionable messages that list the available artboards / properties / cases when a name does not match.

## Documentation

The package ships a DocC catalog: **Getting Started**, **Declaring Schemas**, **Sizing and Fit**, and **Migrating from RiveViewModel**. Build it in Xcode via **Product ▸ Build Documentation**.

## Roadmap

Planned for upcoming versions, roughly in order:

- **Full UIKit/AppKit parity** - artboard and state machine switching on a live `RiveNativeView`, plus frame rate control (currently these are SwiftUI-only).
- **List, image, and artboard properties** - typed and dynamic access to the remaining data binding property kinds.
- **`@RiveBindable` macro** - generate observable Swift properties straight from a schema, removing the subscript/`binding(for:)` layer at call sites.
- **visionOS support** - the runtime already ships slices for it; needs CI coverage and testing.
- **Legacy shim removal** - delete the artboard bounds shim as soon as rive-ios ships a size API in the Swift runtime ([#323](https://github.com/rive-app/rive-ios/issues/323)).

Ideas and requests are welcome in [Issues](https://github.com/rshimoda/SwiftyRive/issues).

## License

MIT. See [LICENSE](LICENSE).

Rive and the Rive runtime are products of [Rive Inc.](https://rive.app); rive-ios is MIT-licensed. This package is not affiliated with Rive.
