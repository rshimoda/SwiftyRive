# Sizing and Fit

Understand the two independent questions: how big is the view, and how does
content render inside it?

## Overview

Rive layout involves two separate decisions that are easy to conflate:

- **Sizing** — what rect does layout give the view? (``SwiftUICore/View/riveNaturalSize()``,
  `frame`, the surrounding layout)
- **Fit** — how is the artboard scaled and positioned *inside* that rect?
  (``RiveFit``, via ``SwiftUICore/View/riveFit(_:)``)

Fit never changes the view's layout size; sizing never changes how content is
scaled within the rect. They compose independently.

## Natural size

By default a ``RiveView`` is greedy: it fills whatever space is proposed, like
`Color` does. Apply ``SwiftUICore/View/riveNaturalSize()`` to make it
participate in layout like `Image` instead:

```swift
VStack(spacing: 12) {
    Text("Above")
    RiveView(document, artboard: "Badge")
        .riveNaturalSize()
    Text("Below")
}
```

With the modifier applied:

- neither axis proposed → the artboard's authored size,
- one axis proposed → the other derived from the artboard's aspect ratio,
- both axes proposed → the proposal wins.

The natural size is always the size the artboard was **authored** at in the
Rive editor. If it cannot be determined, the view falls back to greedy sizing.

You can also query sizes directly from a document:

```swift
let size = try document.artboardSize(named: "Badge")          // CGSize
let ratio = try document.artboardAspectRatio(named: "Badge")  // width / height
```

> Note: The Concurrency runtime has no artboard-size API (rive-ios #323), so
> the first size query lazily re-parses the file's bytes once through the
> legacy runtime, reads every artboard's bounds in one pass, and caches the
> result on the document. The shim disappears when rive-ios ships a size API.

In UIKit/AppKit hierarchies, ``RiveNativeView`` reports the authored size as
its `intrinsicContentSize`.

## Fit

``RiveFit`` decides how the artboard renders inside the rect. Set it through
the environment:

```swift
RiveView(document)
    .riveFit(.cover)
```

| Fit | Behavior |
| --- | --- |
| ``RiveFit/contain`` | Fits entirely within the bounds, preserving aspect ratio (default). |
| ``RiveFit/cover`` | Covers the bounds, preserving aspect ratio; may crop. |
| ``RiveFit/fill`` | Stretches to the exact bounds, ignoring aspect ratio. |
| ``RiveFit/fitWidth`` | Matches the bounds width. |
| ``RiveFit/fitHeight`` | Matches the bounds height. |
| ``RiveFit/scaleDown`` | Scales down only; never scales up. |
| ``RiveFit/actualSize`` | Renders at the authored size, unscaled (the runtime's "none"). |
| ``RiveFit/layout(scale:)`` | Rive's responsive layout engine reflows content to the rect. |

Every fit except `layout` takes an optional ``RiveAlignment``:

```swift
.riveFit(.cover(alignment: .topLeading))
```

Alignment uses SwiftUI naming (`leading`/`trailing`); the runtime has no
right-to-left awareness, so leading always maps to left. In `layout` mode the
layout engine positions content itself and alignment does not apply.

## Choosing a combination

- Fixed slot in your UI, animation should fill it edge-to-edge: explicit
  `frame` + `.riveFit(.cover)`.
- Badge/illustration that should occupy its authored size in a stack:
  `.riveNaturalSize()` (fit rarely matters — the rect already matches the
  artboard's aspect ratio).
- Responsive artboard authored with Rive's layout engine:
  `.riveFit(.layout())`, sized by your UI.
