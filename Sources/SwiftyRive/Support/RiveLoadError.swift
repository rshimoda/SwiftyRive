import Foundation

/// Errors thrown while loading and configuring Rive content.
public nonisolated enum RiveLoadError: Error {
    /// The `.riv` resource could not be found.
    case fileNotFound(resource: String)
    /// The bundle a ``RiveSource/bundle(_:in:)`` source referred to no longer exists on disk.
    case bundleUnavailable(bundleURL: URL)
    /// A remote `.riv` file could not be downloaded.
    case downloadFailed(url: URL)
    /// The file bytes could not be parsed as Rive content.
    case parseFailed(description: String)
    /// Rendering infrastructure (a Metal device) is unavailable on this machine.
    case renderingUnavailable
    /// The requested artboard does not exist in the file.
    case artboardNotFound(name: String, available: [String])
    /// The requested state machine does not exist on the artboard.
    case stateMachineNotFound(name: String, artboard: String?)
    /// A view-model property's initial value could not be read.
    case propertyReadFailed(path: String, description: String)
}

extension RiveLoadError: LocalizedError {
    /// A human-readable description including the failing name and, where
    /// useful, the available alternatives.
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let resource):
            return "Rive file '\(resource).riv' was not found. Check that the resource name is spelled correctly and that the file is included in the bundle's resources."
        case .bundleUnavailable(let bundleURL):
            return "The bundle at \(bundleURL.path) is unavailable. Recreate the RiveSource with a bundle that exists at load time."
        case .downloadFailed(let url):
            return "Could not download the Rive file from \(url.absoluteString). Check the URL and network connectivity."
        case .parseFailed(let description):
            return "The data could not be parsed as a Rive file (\(description)). Re-export the file from the Rive editor and make sure the bytes are an unmodified .riv file."
        case .renderingUnavailable:
            return "Rive rendering is unavailable because no Metal device could be created on this machine."
        case .artboardNotFound(let name, let available):
            if available.isEmpty {
                return "Artboard '\(name)' was not found in the file."
            }
            return "Artboard '\(name)' was not found in the file. Available artboards: \(available.joined(separator: ", "))."
        case .stateMachineNotFound(let name, let artboard):
            let location = artboard.map { "artboard '\($0)'" } ?? "the default artboard"
            return "State machine '\(name)' was not found on \(location). Check the state machine name in the Rive editor."
        case .propertyReadFailed(let path, let description):
            return "Could not read the initial value of property '\(path)' (\(description))."
        }
    }
}
