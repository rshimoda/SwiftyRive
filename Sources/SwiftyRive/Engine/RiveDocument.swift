import Foundation
internal import RiveRuntime

/// A parsed `.riv` file.
///
/// Documents are cheap to hold: the heavy parsing happens once (via ``RiveEngine``)
/// and the resulting document can be shared by any number of views.
@MainActor
public final class RiveDocument {
    /// The source this document was loaded from.
    public let source: RiveSource

    /// The names of all artboards contained in the file.
    ///
    /// Empty if the runtime failed to enumerate artboards (the failure is logged).
    public let artboardNames: [String]

    /// The underlying runtime file. Internal so runtime types never leak into public API.
    let file: RiveRuntime.File

    /// Bytes retained for remote URL sources only, so the bounds shim never
    /// re-downloads. Dropped once the bounds catalog is built.
    private var retainedRemoteBytes: Data?

    /// Cached result of the legacy bounds parse. Built lazily on the first
    /// ``artboardSize(named:)`` call and never invalidated (authored bounds are
    /// immutable per file).
    private var boundsCatalog: LegacyArtboardBounds.Catalog?

    /// How many legacy parses this document has performed. Test hook; must
    /// never exceed 1.
    private(set) var legacyBoundsParseCount = 0

    init(source: RiveSource) async throws {
        let worker = try SharedRiveWorker.shared()

        let runtimeSource: RiveRuntime.Source
        switch source.storage {
        case .bundle(let name, let bundleURL):
            guard let bundle = Bundle(url: bundleURL) else {
                throw RiveLoadError.bundleUnavailable(bundleURL: bundleURL)
            }
            runtimeSource = .local(name, bundle)
        case .url(let url) where !url.isFileURL:
            // Download here (not inside the runtime) so the bytes stay
            // available for the bounds shim without a second download.
            let data = try await Self.download(url)
            retainedRemoteBytes = data
            runtimeSource = .data(data)
        case .url(let url):
            runtimeSource = .url(url)
        case .data(let data, _):
            runtimeSource = .data(data)
        }

        let file: RiveRuntime.File
        do {
            file = try await RiveRuntime.File(source: runtimeSource, worker: worker)
        } catch {
            if error is CancellationError {
                throw error
            }
            if case RiveRuntime.FileError.cancelled = error {
                throw CancellationError()
            }
            throw RiveLoadError(runtimeError: error, source: source)
        }

        var artboardNames: [String] = []
        do {
            artboardNames = try await file.getArtboardNames()
        } catch {
            Log.engine.error("Failed to read artboard names for \(source.debugName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        self.source = source
        self.file = file
        self.artboardNames = artboardNames

        prewarmBoundsCatalog()
    }

    /// Loads (or returns the cached) document for `source` via ``RiveEngine/shared``.
    public static func load(_ source: RiveSource) async throws -> RiveDocument {
        try await RiveEngine.shared.document(for: source)
    }

    // MARK: - Sizing

    /// The authored size of an artboard, in artboard points.
    ///
    /// This is the size the artboard was designed at in the Rive editor — the
    /// natural size used by ``SwiftUICore/View/riveNaturalSize()`` and
    /// ``RiveNativeView``'s intrinsic content size. It is independent of any
    /// ``RiveFit``: fit only decides how content is rendered *inside* whatever
    /// rect layout provides.
    ///
    /// The first call parses the file's bytes once through the legacy bounds
    /// shim; results for every artboard are cached on the document.
    ///
    /// - Parameter name: The artboard name, or `nil` for the file's default artboard.
    /// - Throws: ``RiveLoadError/artboardNotFound(name:available:)`` when no such
    ///   artboard exists, or a load error if the bytes cannot be re-read or parsed.
    public func artboardSize(named name: String? = nil) throws -> CGSize {
        let catalog = try loadBoundsCatalog()
        if let name {
            guard let size = catalog.sizesByName[name] else {
                throw RiveLoadError.artboardNotFound(name: name, available: artboardNames)
            }
            return size
        }
        guard let size = catalog.defaultArtboardSize else {
            throw RiveLoadError.artboardNotFound(name: "(default)", available: artboardNames)
        }
        return size
    }

    /// The authored aspect ratio (width / height) of an artboard.
    ///
    /// - Parameter name: The artboard name, or `nil` for the file's default artboard.
    /// - Throws: The same errors as ``artboardSize(named:)``, plus
    ///   ``RiveLoadError/parseFailed(description:)`` for a degenerate zero-height artboard.
    public func artboardAspectRatio(named name: String? = nil) throws -> CGFloat {
        let size = try artboardSize(named: name)
        guard size.height > 0 else {
            throw RiveLoadError.parseFailed(
                description: "artboard '\(name ?? "(default)")' has zero height, so it has no aspect ratio"
            )
        }
        return size.width / size.height
    }

    /// Builds the bounds catalog ahead of the first ``artboardSize(named:)``
    /// call, so sizing queries made during layout (`sizeThatFits`,
    /// `intrinsicContentSize`) usually hit the cache instead of paying for
    /// disk I/O plus a full legacy parse inside the layout pass.
    ///
    /// Fire-and-forget at utility priority. Everything funnels through the
    /// main-actor-synchronous ``loadBoundsCatalog()``, so the prewarm and the
    /// sync fallback can never both parse: whichever runs first builds the
    /// catalog and the other sees the cache (`legacyBoundsParseCount` stays
    /// at most 1).
    private func prewarmBoundsCatalog() {
        Task(priority: .utility) { @MainActor [weak self] in
            guard let self, self.boundsCatalog == nil else { return }
            _ = try? self.loadBoundsCatalog()
        }
    }

    /// Returns the cached bounds catalog, building it on first use (one legacy
    /// parse). On success the retained remote bytes are released.
    private func loadBoundsCatalog() throws -> LegacyArtboardBounds.Catalog {
        if let boundsCatalog {
            return boundsCatalog
        }
        let bytes = try sourceBytes()
        legacyBoundsParseCount += 1
        let catalog = try LegacyArtboardBounds.readCatalog(from: bytes)
        boundsCatalog = catalog
        retainedRemoteBytes = nil
        return catalog
    }

    /// Re-obtains the original `.riv` bytes for the bounds shim: from the
    /// source, from disk, or from the bytes retained at download time.
    private func sourceBytes() throws -> Data {
        switch source.storage {
        case .data(let data, _):
            return data
        case .bundle(let name, let bundleURL):
            guard let bundle = Bundle(url: bundleURL) else {
                throw RiveLoadError.bundleUnavailable(bundleURL: bundleURL)
            }
            guard let url = bundle.url(forResource: name, withExtension: "riv"),
                  let data = try? Data(contentsOf: url) else {
                throw RiveLoadError.fileNotFound(resource: name)
            }
            return data
        case .url(let url):
            if let retainedRemoteBytes {
                return retainedRemoteBytes
            }
            guard url.isFileURL else {
                // Unreachable in practice: init retains remote bytes until the
                // catalog is built, and the catalog makes this call moot.
                throw RiveLoadError.downloadFailed(url: url)
            }
            guard let data = try? Data(contentsOf: url) else {
                throw RiveLoadError.fileNotFound(resource: url.deletingPathExtension().lastPathComponent)
            }
            return data
        }
    }

    /// Downloads a remote `.riv` once, mapping failures onto ``RiveLoadError``.
    private static func download(_ url: URL) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw RiveLoadError.downloadFailed(url: url)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RiveLoadError.downloadFailed(url: url)
        }
        guard !data.isEmpty else {
            throw RiveLoadError.downloadFailed(url: url)
        }
        return data
    }

    // MARK: - Typed schemas

    /// Validates a schema against this file, aggregating **all** problems into
    /// a single ``RiveSchemaError``.
    ///
    /// Warning-level issues (file enum cases missing from Swift) are logged
    /// but do not throw.
    ///
    /// - Parameters:
    ///   - schema: The schema type to validate.
    ///   - artboard: The artboard whose default view model anchors a schema
    ///     with a `nil` ``RiveSchema/viewModelName``, or `nil` for the file's
    ///     default artboard. Ignored when the schema names its view model
    ///     explicitly (beyond checking that the artboard exists).
    public func validate<S: RiveSchema>(_ schema: S.Type, artboard: String? = nil) async throws {
        let keys = try S.discoverKeys()
        _ = try await SchemaValidator.validate(
            keys: keys,
            viewModelName: S.viewModelName,
            artboardName: artboard,
            in: self
        )
    }

    /// Validates `schema` and creates a live two-way binding over a fresh view
    /// model instance.
    ///
    /// The instance is created from the schema's ``RiveSchema/viewModelName``,
    /// using the view model's default values. When the name is `nil`, the
    /// instance binds to the **default view model of the given (or
    /// file-default) artboard** — so if you render it with a *different*
    /// artboard whose default view model differs, property writes will succeed
    /// but have no visible effect. Pass the same `artboard` here that you pass
    /// to ``RiveView`` (the render host logs an error when it detects such a
    /// mismatch).
    ///
    /// - Parameters:
    ///   - schema: The schema type to bind.
    ///   - artboard: The artboard whose default view model anchors a schema
    ///     with a `nil` ``RiveSchema/viewModelName``, or `nil` for the file's
    ///     default artboard. Ignored when the schema names its view model
    ///     explicitly (beyond checking that the artboard exists).
    /// - Throws: ``RiveLoadError/artboardNotFound(name:available:)`` when
    ///   `artboard` names no artboard in the file, ``RiveSchemaError`` when
    ///   validation fails, or ``RiveLoadError`` when runtime metadata cannot
    ///   be read.
    public func makeInstance<S: RiveSchema>(
        of schema: S.Type,
        artboard: String? = nil
    ) async throws -> RiveInstance<S> {
        let keys = try S.discoverKeys()
        _ = try await SchemaValidator.validate(
            keys: keys,
            viewModelName: S.viewModelName,
            artboardName: artboard,
            in: self
        )

        let source: RiveRuntime.ViewModelInstanceSource
        if let name = S.viewModelName {
            source = .viewModelDefault(from: .name(name))
        } else {
            let runtimeArtboard = try await createArtboard(named: artboard)
            source = .viewModelDefault(from: .artboardDefault(runtimeArtboard))
        }

        let viewModelInstance: RiveRuntime.ViewModelInstance
        do {
            viewModelInstance = try await file.createViewModelInstance(source)
        } catch {
            throw RiveLoadError.parseFailed(description: "Could not create a view model instance: \(error.localizedDescription)")
        }

        return try await RiveInstance(
            schema: S(),
            keys: keys,
            viewModelInstance: viewModelInstance,
            document: self
        )
    }

    /// Creates a runtime artboard by name (or the file's default for `nil`),
    /// mapping failures onto ``RiveLoadError/artboardNotFound(name:available:)``.
    ///
    /// The name is pre-checked against ``artboardNames`` (when the runtime
    /// enumerated them) so the common typo case fails without a runtime round
    /// trip and with the available names in the error.
    func createArtboard(named name: String?) async throws -> RiveRuntime.Artboard {
        if let name, !artboardNames.isEmpty, !artboardNames.contains(name) {
            throw RiveLoadError.artboardNotFound(name: name, available: artboardNames)
        }
        do {
            return try await file.createArtboard(name)
        } catch {
            if error is CancellationError {
                throw error
            }
            throw RiveLoadError.artboardNotFound(
                name: name ?? "(default)",
                available: artboardNames
            )
        }
    }
}

extension RiveLoadError {
    /// Maps a runtime loading error onto the package's public error type.
    init(runtimeError: any Error, source: RiveSource) {
        guard let fileError = runtimeError as? RiveRuntime.FileError else {
            self = .parseFailed(description: runtimeError.localizedDescription)
            return
        }
        switch fileError {
        case .missingFile(let name):
            self = .fileNotFound(resource: name)
        case .missingData(let urlString):
            // The runtime reports the failing URL as a string. Prefer the URL
            // the source already carries; fall back to parsing the runtime's
            // string, then to a file URL of that string so the case always
            // carries *something* pointing at the failing location.
            let url: URL
            if case .url(let sourceURL) = source.storage {
                url = sourceURL
            } else {
                url = URL(string: urlString) ?? URL(fileURLWithPath: urlString)
            }
            self = .downloadFailed(url: url)
        default:
            self = .parseFailed(description: fileError.localizedDescription)
        }
    }
}
