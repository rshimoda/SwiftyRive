import Foundation
import Observation
import SwiftUI
internal import RiveRuntime

/// A live, observable two-way binding between a ``RiveSchema`` and a view
/// model instance in a loaded file.
///
/// Create instances with ``RiveDocument/makeInstance(of:artboard:)`` (which validates
/// the schema first, so every key path is proven to exist with the right type)
/// and render them with ``RiveView/init(_:artboard:stateMachine:)-(RiveInstance<S>,_,_)``.
///
/// Reads are synchronous from a local mirror seeded with the file's initial
/// values; writes update the mirror, forward to the runtime, and nudge the
/// attached view so the change renders even while playback is paused
/// (workaround for rive-ios #383). Changes originating inside the animation
/// flow back through per-key value streams, so SwiftUI observation sees both
/// directions.
@MainActor
@Observable
public final class RiveInstance<Schema: RiveSchema> {
    /// The schema this instance is bound through.
    public let schema: Schema

    /// The document the instance was created from (held strongly — the
    /// runtime requires the file to outlive the view model instance).
    let document: RiveDocument

    /// The bound runtime instance (held strongly for the runtime's sake).
    let viewModelInstance: RiveRuntime.ViewModelInstance

    /// Local mirror of every value key, keyed by property path.
    private var mirror: [String: PropertyBox] = [:]

    /// One stream-consumption task per value key. Cancelled on deinit.
    @ObservationIgnored
    private var observationTasks: [Task<Void, Never>] = []

    /// One fan-out per observed trigger path: the runtime supports only one
    /// effective trigger subscription per (instance, path).
    @ObservationIgnored
    private var triggerFanouts: [String: TriggerFanout] = [:]

    /// Upstream tasks of the fan-outs, cancelled on deinit. Kept here because
    /// `deinit` is nonisolated and may only touch its own stored properties.
    @ObservationIgnored
    private var triggerTransportTasks: [Task<Void, Never>] = []

    /// Render host of the view currently displaying this instance, used to
    /// nudge a paused view into rendering fresh writes.
    @ObservationIgnored
    weak var renderHost: RiveRenderHost?

    /// Creates an instance over `viewModelInstance`, seeding the mirror with
    /// the current value of every discovered key.
    init(
        schema: Schema,
        keys: [DiscoveredKey],
        viewModelInstance: RiveRuntime.ViewModelInstance,
        document: RiveDocument
    ) async throws {
        self.schema = schema
        self.document = document
        self.viewModelInstance = viewModelInstance

        var seeded: [String: PropertyBox] = [:]
        for key in keys where key.declaration.kind != .trigger {
            seeded[key.path] = try await PropertyTransport.readValue(
                of: key.declaration.kind,
                at: key.path,
                from: viewModelInstance
            )
        }
        mirror = seeded

        observationTasks = keys.compactMap { key in
            PropertyTransport.observeValues(
                of: key.declaration.kind,
                at: key.path,
                from: viewModelInstance
            ) { [weak self] box in
                self?.applyRemoteChange(box, at: key.path)
            }
        }
    }

    deinit {
        for task in observationTasks {
            task.cancel()
        }
        for task in triggerTransportTasks {
            task.cancel()
        }
    }

    // MARK: - Values

    /// Reads and writes the value for a schema key.
    ///
    /// Reads are synchronous from the local mirror. Writes short-circuit when
    /// the value is unchanged; otherwise they update the mirror, forward to
    /// the runtime, and request an advance-nudge from the attached view.
    public subscript<V: RivePropertyValue>(key: KeyPath<Schema, RiveKey<V>>) -> V {
        get {
            let path = schema[keyPath: key].path
            guard let box = mirror[path], let value = box.value(as: V.self) else {
                preconditionFailure(
                    "No mirrored value for '\(path)'. Schema keys must be stored properties so they are discovered and validated by makeInstance(of:artboard:)."
                )
            }
            return value
        }
        set {
            let path = schema[keyPath: key].path
            guard let box = PropertyBox(newValue) else {
                preconditionFailure(
                    "Unsupported value type \(V.self) for '\(path)'. Supported types: Double, Bool, String, RiveColor, and RiveEnum conformances."
                )
            }
            guard mirror[path] != box else { return }
            mirror[path] = box
            PropertyTransport.write(box, at: path, to: viewModelInstance)
            renderHost?.requestAdvanceNudge()
        }
    }

    /// A SwiftUI `Binding` for a schema key, for direct use with controls.
    public func binding<V: RivePropertyValue>(for key: KeyPath<Schema, RiveKey<V>>) -> Binding<V> {
        Binding(
            get: { self[key] },
            set: { self[key] = $0 }
        )
    }

    // MARK: - Triggers

    /// Fires a trigger and nudges the attached view so any resulting state
    /// transition renders even while paused.
    public func fire(_ key: KeyPath<Schema, RiveTriggerKey>) {
        let path = schema[keyPath: key].path
        viewModelInstance.fire(trigger: TriggerProperty(path: path))
        renderHost?.requestAdvanceNudge()
    }

    /// A stream of firings of a trigger (including firings originating inside
    /// the animation).
    ///
    /// Every call returns an independent stream; it ends when its consumer
    /// stops iterating or, at the latest, when this instance deallocates.
    /// Delivery is at-least-once, not an exact firing count: the runtime may
    /// batch rapid successive firings into fewer emissions (rive-ios #446).
    public func firings(of key: KeyPath<Schema, RiveTriggerKey>) -> AsyncStream<Void> {
        let path = schema[keyPath: key].path
        let fanout = ensureTriggerFanout(for: path)
        let id = UUID()
        return AsyncStream { continuation in
            fanout.continuations[id] = continuation
            continuation.onTermination = { [weak fanout] _ in
                Task { @MainActor in
                    fanout?.continuations[id] = nil
                }
            }
        }
    }

    // MARK: - Private

    /// Applies a runtime-originated change to the mirror.
    /// The equality guard breaks write/stream echo loops.
    private func applyRemoteChange(_ box: PropertyBox, at path: String) {
        guard mirror[path] != box else { return }
        mirror[path] = box
    }

    /// Returns the fan-out for `path`, creating it on first use. Fan-outs live
    /// for the instance's lifetime; tearing subscriptions down on demand would
    /// race the runtime's asynchronous unsubscribe.
    private func ensureTriggerFanout(for path: String) -> TriggerFanout {
        if let existing = triggerFanouts[path] {
            return existing
        }
        let fanout = TriggerFanout()
        triggerFanouts[path] = fanout

        let upstream = viewModelInstance.stream(of: TriggerProperty(path: path))
        // Captures the fan-out strongly (not `self`) so `finishAll()` can
        // still terminate subscriber streams after the instance deinits.
        let task = Task { @MainActor in
            do {
                for try await _ in upstream {
                    for continuation in fanout.continuations.values {
                        continuation.yield(())
                    }
                }
            } catch is CancellationError {
                // Instance deinited (or the runtime instance went away).
            } catch {
                Log.binding.error("Trigger stream for '\(path, privacy: .public)' failed: \(error.localizedDescription, privacy: .public)")
            }
            fanout.finishAll()
        }
        triggerTransportTasks.append(task)
        return fanout
    }
}

/// Subscriber registry for one trigger path: continuations of every live
/// ``RiveInstance/firings(of:)`` stream for that path.
@MainActor
private final class TriggerFanout {
    var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    /// Finishes every subscriber stream and empties the registry.
    func finishAll() {
        let all = continuations.values
        continuations.removeAll()
        for continuation in all {
            continuation.finish()
        }
    }
}
