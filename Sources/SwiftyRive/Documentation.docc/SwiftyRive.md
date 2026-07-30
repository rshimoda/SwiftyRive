# ``SwiftyRive``

A Swifty, SwiftUI-first wrapper over rive-ios's Concurrency runtime.

## Overview

SwiftyRive renders [Rive](https://rive.app) animations in SwiftUI with typed,
load-time-validated schemas instead of stringly-typed property paths, two-way
`@Observable` data binding, natural content sizing, clean fit/alignment, and a
shared document cache.

The essential flow:

```swift
// 1. Load (parsed once, cached by the shared engine).
let document = try await RiveDocument.load(.bundle("robot"))

// 2. Render.
RiveView(document, artboard: "Hero")
    .riveFit(.cover)
    .riveNaturalSize()
```

Add a ``RiveSchema`` and ``RiveDocument/makeInstance(of:artboard:)`` for typed two-way
binding between your SwiftUI state and the animation's view model.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:DeclaringSchemas>
- <doc:SizingAndFit>
- <doc:MigratingFromRiveViewModel>

### Loading documents

- ``RiveSource``
- ``RiveEngine``
- ``RiveDocument``
- ``RiveLoadError``

### Views

- ``RiveView``
- ``AsyncRiveView``
- ``AsyncRivePhase``
- ``RiveNativeView``

### Typed schemas

- ``RiveSchema``
- ``RiveKey``
- ``RiveTriggerKey``
- ``RiveEnum``
- ``RivePropertyValue``
- ``RiveColor``
- ``RiveSchemaError``

### Two-way binding

- ``RiveInstance``

### Fit and alignment

- ``RiveFit``
- ``RiveAlignment``
- ``RiveLayoutScale``

### Diagnostics

- ``RiveDocument/dumpViewModels()``
