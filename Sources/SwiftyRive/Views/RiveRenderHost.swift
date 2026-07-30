import Foundation
import Observation
internal import RiveRuntime

/// The subset of `RiveUIView` behavior the render host drives, abstracted so
/// nudge and teardown logic is testable without a Metal device.
@MainActor
protocol RiveHostableView: AnyObject {
    /// Whether the view's display link and controller are paused.
    var isPaused: Bool { get set }
    /// Detaches the current Rive configuration from the view, synchronously
    /// releasing its controller and renderer.
    func detachRive()
}

extension RiveUIView: RiveHostableView {
    func detachRive() {
        rive = nil
    }
}

/// Builds and owns the runtime `Rive` object for a single ``RiveView``.
///
/// The host is the only place where render state is created and torn down:
/// configuration changes rebuild artboard → state machine → `Rive` in order,
/// and ``teardown()`` is the single deterministic release point. It also holds
/// a weak reference to the hosted platform view so bound instances can request
/// an advance-nudge (see ``requestAdvanceNudge()``).
@Observable
@MainActor
final class RiveRenderHost {
    struct Configuration {
        let document: RiveDocument
        let artboardName: String?
        let stateMachineName: String?
        let fit: RiveFit
        /// The explicit view model instance to bind, or `nil` for `.auto`.
        let boundViewModelInstance: RiveRuntime.ViewModelInstance?

        /// True when both configurations render the same artboard/state machine
        /// (i.e. a rebuild is unnecessary and only cheap properties may differ).
        func rendersSameScene(as other: Configuration) -> Bool {
            document === other.document
                && artboardName == other.artboardName
                && stateMachineName == other.stateMachineName
                && boundViewModelInstance == other.boundViewModelInstance
        }
    }

    /// The current runtime configuration, or `nil` while loading / after failure.
    private(set) var rive: RiveRuntime.Rive?

    /// The most recent build failure, if any.
    private(set) var error: (any Error)?

    /// True while an advance-nudge has temporarily unpaused the hosted view.
    /// ``RiveRepresentable`` skips pause syncing during a nudge so a SwiftUI
    /// update does not cut the nudge frame short.
    @ObservationIgnored
    private(set) var isNudging = false

    private var configuration: Configuration?

    @ObservationIgnored
    private weak var hostedView: (any RiveHostableView)?

    /// The pause state the surrounding SwiftUI environment wants, tracked so a
    /// nudge can restore it (and skip restoring when the user unpaused midway).
    @ObservationIgnored
    private var desiredIsPaused = false

    @ObservationIgnored
    private var nudgeTask: Task<Void, Never>?

    /// The in-flight rebuild, cancelled whenever a newer configuration arrives.
    @ObservationIgnored
    private var rebuildTask: Task<Void, Never>?

    /// Monotonic token for the latest requested rebuild; a stale build never
    /// commits over a newer one.
    @ObservationIgnored
    private var buildGeneration = 0

    /// True once a build has completed for the current configuration.
    /// Test/introspection hook that avoids exposing runtime types.
    var hasRive: Bool { rive != nil }

    /// The artboard name of the most recently applied configuration.
    /// Test/introspection hook.
    var appliedArtboardName: String? { configuration?.artboardName }

    /// Applies a configuration, rebuilding runtime objects only when needed.
    ///
    /// Fit-only changes are applied to the existing `Rive` object without a
    /// rebuild. Scene changes cancel any in-flight rebuild before starting a
    /// new one, so rapid successive switches cannot race: at most one rebuild
    /// can commit, and only the one matching the latest configuration.
    /// Intended to be called from `.task(id:)`; a call that is already
    /// cancelled on entry is a no-op, so superseded applies never clobber
    /// newer state.
    func apply(_ configuration: Configuration) async {
        guard Task.isCancelled == false else { return }

        if let current = self.configuration, rive != nil, current.rendersSameScene(as: configuration) {
            self.configuration = configuration
            if current.fit != configuration.fit {
                rive?.fit = configuration.fit.runtimeFit
            }
            return
        }

        self.configuration = configuration
        buildGeneration += 1
        let generation = buildGeneration

        rebuildTask?.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rebuild(configuration, generation: generation)
        }
        rebuildTask = task

        // Forward the caller's cancellation to the rebuild without letting a
        // later apply's cancel of `rebuildTask` cancel *this* caller.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Deterministically releases all runtime render state. Idempotent.
    ///
    /// Teardown order matters: cancel tasks, detach the view, then release
    /// `Rive` on the main actor (rive-ios #442/#418/#453).
    func teardown() {
        rebuildTask?.cancel()
        rebuildTask = nil
        nudgeTask?.cancel()
        nudgeTask = nil
        isNudging = false
        hostedView?.detachRive()
        configuration = nil
        rive = nil
        error = nil
    }

    // MARK: - Advance-nudge (workaround for rive-ios #383)

    /// Registers the platform view currently hosting this configuration and
    /// the pause state the SwiftUI environment wants. Called by
    /// ``RiveRepresentable`` on make/update; idempotent.
    func adoptHostedView(_ view: any RiveHostableView, desiredIsPaused: Bool) {
        hostedView = view
        self.desiredIsPaused = desiredIsPaused
    }

    /// Makes a pending data-binding write or trigger visible on a paused view
    /// by unpausing it for one frame and re-pausing (rive-ios #383).
    ///
    /// Nudges within a burst coalesce: each write extends the restore
    /// deadline, and exactly one restore runs per burst.
    func requestAdvanceNudge() {
        guard let view = hostedView, desiredIsPaused else { return }

        if isNudging == false {
            // Not mid-nudge: if the view is already running, the write renders
            // on the next display-link tick and no nudge is needed.
            guard view.isPaused else { return }
            isNudging = true
            view.isPaused = false
        }

        nudgeTask?.cancel()
        nudgeTask = Task { @MainActor [weak self, weak view] in
            // One display-link frame at the lowest plausible frame rate.
            try? await Task.sleep(for: .milliseconds(50))
            guard Task.isCancelled == false, let self else { return }
            self.isNudging = false
            self.nudgeTask = nil
            if let view, self.desiredIsPaused {
                view.isPaused = true
            }
        }
    }

    /// Logs when a bound instance's view model is not the rendered artboard's
    /// default (writes would silently change nothing on screen).
    /// Fire-and-forget: must not delay or fail the rebuild.
    private func warnOnViewModelMismatch(
        instance: RiveRuntime.ViewModelInstance,
        artboard: RiveRuntime.Artboard,
        document: RiveDocument,
        artboardName: String?
    ) {
        Task { @MainActor in
            guard let boundName = try? await instance.viewModelName(),
                  let defaultName = try? await document.file.getDefaultViewModelInfo(for: artboard).viewModelName,
                  boundName != defaultName else { return }
            Log.view.error("Bound view model '\(boundName, privacy: .public)' is not the default view model '\(defaultName, privacy: .public)' of artboard '\(artboardName ?? "(default)", privacy: .public)'. If the artboard does not use this view model, property writes will have no visible effect — create the instance with makeInstance(of:artboard:) for the artboard you render.")
        }
    }

    private func rebuild(_ configuration: Configuration, generation: Int) async {
        Log.view.debug("Rebuilding Rive (artboard: \(configuration.artboardName ?? "default", privacy: .public), stateMachine: \(configuration.stateMachineName ?? "default", privacy: .public))")
        do {
            let document = configuration.document

            if let name = configuration.artboardName,
               !document.artboardNames.isEmpty,
               !document.artboardNames.contains(name) {
                throw RiveLoadError.artboardNotFound(name: name, available: document.artboardNames)
            }

            let artboard: RiveRuntime.Artboard
            do {
                artboard = try await document.file.createArtboard(configuration.artboardName)
            } catch {
                try Task.checkCancellation()
                throw RiveLoadError.artboardNotFound(
                    name: configuration.artboardName ?? "(default)",
                    available: document.artboardNames
                )
            }

            let stateMachine: RiveRuntime.StateMachine
            do {
                stateMachine = try await artboard.createStateMachine(configuration.stateMachineName)
            } catch {
                try Task.checkCancellation()
                throw RiveLoadError.stateMachineNotFound(
                    name: configuration.stateMachineName ?? "(default)",
                    artboard: configuration.artboardName
                )
            }

            let dataBind: RiveRuntime.DataBind
            if let instance = configuration.boundViewModelInstance {
                dataBind = .instance(instance)
                warnOnViewModelMismatch(
                    instance: instance,
                    artboard: artboard,
                    document: document,
                    artboardName: configuration.artboardName
                )
            } else {
                dataBind = .auto
            }

            try Task.checkCancellation()
            let rive = try await RiveRuntime.Rive(
                file: document.file,
                artboard: artboard,
                stateMachine: stateMachine,
                dataBind: dataBind,
                fit: configuration.fit.runtimeFit
            )

            // The generation token catches stale builds, including rapid
            // A/B/A flips where configurations are equal.
            try Task.checkCancellation()
            guard generation == buildGeneration else { return }

            // A fit-only change may have raced in while this scene was
            // building; honor the latest requested fit.
            if let currentFit = self.configuration?.fit, currentFit != configuration.fit {
                rive.fit = currentFit.runtimeFit
            }

            // Replace the previous `Rive` only after the new one is fully
            // built, so switching never shows a blank frame.
            self.rive = rive
            self.error = nil
        } catch is CancellationError {
            // Superseded or view disappeared; keep whatever state we had.
        } catch {
            Log.view.error("Failed to build Rive: \(error.localizedDescription, privacy: .public)")
            // A stale build's failure must not clobber a newer configuration.
            guard generation == buildGeneration else { return }
            rive = nil
            self.error = error
        }
    }
}
