# Migrating from RiveViewModel

Map legacy rive-ios `RiveViewModel` patterns onto SwiftyRive.

## Overview

rive-ios's `RiveViewModel` is in maintenance mode; the recommended path is the
new Concurrency runtime, which SwiftyRive wraps. This article maps the common
legacy patterns onto their SwiftyRive equivalents.

## Creating and showing a view

Legacy:

```swift
let viewModel = RiveViewModel(fileName: "robot", stateMachineName: "Idle")
viewModel.view()   // SwiftUI
```

SwiftyRive:

```swift
let document = try await RiveDocument.load(.bundle("robot"))
RiveView(document, stateMachine: "Idle")
```

Or skip the explicit load with ``AsyncRiveView``:

```swift
AsyncRiveView(source: .bundle("robot"), stateMachine: "Idle") { phase in
    if case .success(let rive) = phase { rive } else { ProgressView() }
}
```

Loading is explicit and `async throws` — no silently-broken view when the file
name is wrong. Errors are ``RiveLoadError`` values with actionable messages.

## Inputs and data binding

Legacy state-machine inputs and view-model access were stringly typed at every
call site:

```swift
viewModel.setInput("energy", value: 0.5)
viewModel.triggerInput("celebrate")
```

SwiftyRive replaces per-call strings with a ``RiveSchema`` declared once and
validated at load time:

```swift
struct RobotSchema: RiveSchema {
    let energy = RiveKey<Double>("energy")
    let celebrate = RiveTriggerKey("celebrate")
}

let instance = try await document.makeInstance(of: RobotSchema.self)

instance[\.energy] = 0.5          // typed write
instance.fire(\.celebrate)        // trigger
```

> Important: SwiftyRive binds through Rive **data binding** (view models), the
> editor's successor to state-machine inputs. If your `.riv` still uses bare
> inputs, rewire them to a view model in the Rive editor as part of migrating.

Two-way SwiftUI flow, which required manual `RiveStateMachineDelegate`
plumbing before, is built in — ``RiveInstance`` is `@Observable` and vends
`Binding`s:

```swift
Slider(value: instance.binding(for: \.energy), in: 0...1)
```

Render the bound instance with ``RiveView/init(_:artboard:stateMachine:)-(RiveInstance<S>,_,_)``:

```swift
RiveView(instance)
```

## Fit and alignment

Legacy:

```swift
viewModel.fit = .fitCover
viewModel.alignment = .topLeft
```

SwiftyRive uses environment modifiers with SwiftUI naming, and the alignment
travels with the fit:

```swift
RiveView(document)
    .riveFit(.cover(alignment: .topLeading))
```

`Fit.noFit` / `.none` is called ``RiveFit/actualSize``; the runtime's layout
mode is ``RiveFit/layout(scale:)``.

## Playback

| Legacy | SwiftyRive |
| --- | --- |
| `viewModel.pause()` / `play()` | `.rivePaused(isPaused)` (value-driven) |
| `RiveView` preferred FPS setup | `.riveFrameRate(30)` |
| `viewModel.reset()` | Change the `artboard`/`stateMachine` value passed to ``RiveView`` — the pipeline rebuilds, the parsed file stays cached |

## Sizing

The legacy stack offered no content size either — views were sized externally.
SwiftyRive adds:

- ``SwiftUICore/View/riveNaturalSize()`` — Image-like layout participation,
- ``RiveDocument/artboardSize(named:)`` — the authored `CGSize`,
- ``RiveNativeView`` with a real `intrinsicContentSize` for UIKit/AppKit.

See <doc:SizingAndFit>.

## What has no direct equivalent

- **State-machine input APIs** (`setInput`, `triggerInput` on bare inputs):
  use data binding (view models) instead — see the note above.
- **`RiveModel` / manual `RiveFile` management**: replaced by ``RiveSource``,
  ``RiveEngine`` caching, and ``RiveDocument``.
- **Delegate callbacks** (`RivePlayerDelegate`, `RiveStateMachineDelegate`):
  observe values through the instance's observable state and
  ``RiveInstance/firings(of:)`` streams.
