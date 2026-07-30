# Getting Started

Load a `.riv` file and put an animation on screen.

## Add the package

Add SwiftyRive to your target's dependencies and `import SwiftyRive`. The
package requires iOS 17+ / macOS 14+ and pulls in rive-ios (≥ 6.22.0)
automatically.

## Describe where the file lives

A ``RiveSource`` names the bytes of a `.riv` file. It is also the cache key —
equal sources are parsed once, process-wide:

```swift
let bundled = RiveSource.bundle("robot")                    // robot.riv in Bundle.main
let remote = RiveSource.url(URL(string: "https://example.com/robot.riv")!)
let inMemory = RiveSource.data(bytes, identifier: "robot")
```

## The simplest path: AsyncRiveView

``AsyncRiveView`` loads a source and hands you the current ``RivePhase``,
`AsyncImage`-style:

```swift
AsyncRiveView(source: .bundle("robot")) { phase in
    switch phase {
    case .loading:
        ProgressView()
    case .success(let rive):
        rive
    case .failure(let error):
        Text(error.localizedDescription)
    }
}
```

## Loading yourself: RiveDocument + RiveView

When you want to hold the document (to share it, query sizes, or create typed
instances), load it explicitly and pass it to ``RiveView``:

```swift
struct Robot: View {
    @State private var document: RiveDocument?

    var body: some View {
        Group {
            if let document {
                RiveView(document, artboard: "Hero", stateMachine: "Idle")
                    .riveFit(.contain)
            } else {
                ProgressView()
            }
        }
        .task {
            document = try? await RiveDocument.load(.bundle("robot"))
        }
    }
}
```

Both `artboard` and `stateMachine` default to `nil` — the file's default
artboard and its default state machine. Changing either value rebuilds the
render pipeline; the parsed document stays cached, so switching is hitch-free.

## Controlling playback

Playback and rendering options flow through the environment, so they can be
set on a single view or a whole hierarchy:

```swift
RiveView(document)
    .rivePaused(isPaused)      // pause / resume
    .riveFrameRate(30)         // cap the frame rate (nil restores the display default)
```

## Preloading

Warm the cache before views appear:

```swift
let failures = await RiveEngine.shared.preloadDocuments(for: [
    .bundle("robot"),
    .bundle("confetti"),
])
```

The result maps each failing source to its error; an empty dictionary means
everything loaded.

## Next steps

- <doc:DeclaringSchemas> — typed, validated two-way binding.
- <doc:SizingAndFit> — natural content size and fit modes.
