# Declaring Schemas

Describe a Rive view model as a typed Swift schema and bind it two ways.

## Overview

Rive's data binding addresses view-model properties by string path. SwiftyRive
keeps those paths in exactly one place — a ``RiveSchema`` — and validates the
whole schema against the file when an instance is created. After validation
succeeds, every read and write is plain, synchronous, type-checked Swift.

## Declare the schema

Each property you use becomes a **stored** ``RiveKey`` (or ``RiveTriggerKey``
for triggers):

```swift
enum Mood: String, RiveEnum { case idle, happy, alarmed }

struct RobotSchema: RiveSchema {
    let energy = RiveKey<Double>("energy")        // number
    let isOn = RiveKey<Bool>("isOn")              // boolean
    let title = RiveKey<String>("card/title")     // string, nested view model
    let tint = RiveKey<RiveColor>("tint")         // color
    let mood = RiveKey<Mood>("mood")              // enum
    let celebrate = RiveTriggerKey("celebrate")   // trigger
}
```

The supported value types are `Double`, `Bool`, `String`, ``RiveColor``, and
any ``RiveEnum`` — matching Rive's number, boolean, string, color, and enum
property kinds. Nested view models use the runtime's forward-slash notation
(`"card/title"`).

Keys are discovered via `Mirror`, so they must be stored properties; a schema
whose keys are all computed fails loudly with
``RiveSchemaError/Issue/noKeysDiscovered(schema:)``.

By default the schema binds against an artboard's default view model — the
artboard passed to ``RiveDocument/makeInstance(of:artboard:)``, or the file's
default artboard when none is given. The binding is anchored to *that*
artboard's view model, so render the instance with the same artboard;
rendering a different artboard whose default view model differs leaves writes
without any visible effect (the render host logs an error when it detects
this). To target a specific view model regardless of artboard, override
``RiveSchema/viewModelName``:

```swift
struct RobotSchema: RiveSchema {
    static var viewModelName: String? { "Robot" }
    // keys...
}
```

## Enums

A ``RiveEnum``'s raw values must match the case names in the Rive editor
exactly:

```swift
enum Mood: String, RiveEnum {
    case idle = "Idle"
    case happy = "Happy"
    case alarmed = "Alarmed"
}
```

Validation compares both directions: a Swift case missing from the file is an
error; a file case missing from Swift is a logged warning (reading such a
value keeps the last known Swift case).

## Validate and create an instance

``RiveDocument/makeInstance(of:artboard:)`` validates first and then creates a live
binding:

```swift
let document = try await RiveDocument.load(.bundle("robot"))
let instance = try await document.makeInstance(of: RobotSchema.self)
```

Validation aggregates **all** problems into a single ``RiveSchemaError`` —
wrong view-model name, unknown paths, type mismatches, enum case drift — each
with the available alternatives spelled out, so one failed run tells you
everything that needs fixing. To check a schema without creating an instance,
use ``RiveDocument/validate(_:artboard:)``.

Not sure which paths exist in a file you did not author? Dump its
data-binding tree:

```swift
print(await document.dumpViewModels())
```

## Read, write, bind

``RiveInstance`` is `@Observable`. Reads are synchronous from a local mirror;
writes forward to the runtime and render even while playback is paused:

```swift
struct RobotControls: View {
    let instance: RiveInstance<RobotSchema>

    var body: some View {
        VStack {
            RiveView(instance)
                .frame(height: 240)

            // Direct read/write by key path:
            Text("Energy: \(instance[\.energy], format: .number)")

            // SwiftUI Binding for controls:
            Slider(value: instance.binding(for: \.energy), in: 0...1)
            TextField("Title", text: instance.binding(for: \.title))

            Button("Celebrate") { instance.fire(\.celebrate) }
        }
    }
}
```

Changes originating *inside* the animation flow back automatically — the
mirror updates and SwiftUI re-renders anything reading the instance.

## Observe triggers

Triggers fired by the animation (or by ``RiveInstance/fire(_:)``) can be
consumed as an `AsyncStream`:

```swift
.task {
    for await _ in instance.firings(of: \.celebrate) {
        // React to the trigger. Delivery is at-least-once: rapid successive
        // firings may batch into fewer elements.
    }
}
```

Every ``RiveInstance/firings(of:)`` call returns an independent stream, so any
number of consumers can observe the same trigger.
