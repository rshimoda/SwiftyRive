import os

/// Package-wide loggers.
nonisolated enum Log {
    static let engine = Logger(subsystem: "com.swiftyrive", category: "Engine")
    static let view = Logger(subsystem: "com.swiftyrive", category: "View")
    static let schema = Logger(subsystem: "com.swiftyrive", category: "Schema")
    static let binding = Logger(subsystem: "com.swiftyrive", category: "Binding")
}
