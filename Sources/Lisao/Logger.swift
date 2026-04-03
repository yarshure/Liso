import Foundation

public final class Logger: @unchecked Sendable {
    public enum Level: String, CaseIterable, Sendable {
        case trace = "TRACE"
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
    }

    public struct Configuration: Sendable {
        public var category: String
        public var fileURL: URL?
        public var writesToConsole: Bool
        public var dateProvider: @Sendable () -> Date

        public init(
            category: String = "Default",
            fileURL: URL? = nil,
            writesToConsole: Bool = true,
            dateProvider: @escaping @Sendable () -> Date = Date.init
        ) {
            self.category = category
            self.fileURL = fileURL
            self.writesToConsole = writesToConsole
            self.dateProvider = dateProvider
        }
    }

    private struct State {
        var category: String
        var fileURL: URL?
        var writesToConsole: Bool
    }

    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let dateProvider: @Sendable () -> Date
    private var state: State

    public init(
        category: String = "Default",
        fileURL: URL? = nil,
        writesToConsole: Bool = true,
        fileManager: FileManager = .default,
        dateProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.queue = DispatchQueue(label: "Lisao.Logger.\(category)")
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.state = State(category: category, fileURL: fileURL, writesToConsole: writesToConsole)
    }

    public convenience init(configuration: Configuration, fileManager: FileManager = .default) {
        self.init(
            category: configuration.category,
            fileURL: configuration.fileURL,
            writesToConsole: configuration.writesToConsole,
            fileManager: fileManager,
            dateProvider: configuration.dateProvider
        )
    }

    public func updateFileURL(_ fileURL: URL?) {
        queue.sync {
            state.fileURL = fileURL
        }
    }

    public func updateCategory(_ category: String) {
        queue.sync {
            state.category = category
        }
    }

    public func updateConsoleOutput(enabled: Bool) {
        queue.sync {
            state.writesToConsole = enabled
        }
    }

    public func trace(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(.trace, message(), file: file, function: function, line: line)
    }

    public func info(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(.info, message(), file: file, function: function, line: line)
    }

    public func warning(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        log(.warning, message(), file: file, function: function, line: line)
    }

    public func debug(
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        #if DEBUG
        log(.debug, message(), file: file, function: function, line: line)
        #endif
    }

    public func log(
        _ level: Level,
        _ message: @autoclosure () -> String,
        file: String = #fileID,
        function: String = #function,
        line: Int = #line
    ) {
        #if !DEBUG
        if level == .debug {
            return
        }
        #endif

        let message = message()
        let now = dateProvider()

        queue.sync {
            let rendered = Self.render(
                date: now,
                level: level,
                category: state.category,
                message: message,
                file: file,
                function: function,
                line: line
            )

            if state.writesToConsole {
                print(rendered)
            }

            if let fileURL = state.fileURL {
                append(rendered + "\n", to: fileURL)
            }
        }
    }

    public static func isDebugLoggingEnabled() -> Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func render(
        date: Date,
        level: Level,
        category: String,
        message: String,
        file: String,
        function: String,
        line: Int
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: date)
        let source = "\(file):\(line) \(function)"
        return "\(timestamp) [\(level.rawValue)] [\(category)] \(message) (\(source))"
    }

    private func append(_ text: String, to fileURL: URL) {
        do {
            let directory = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            if !fileManager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }

            guard let data = text.data(using: .utf8) else {
                return
            }

            if let handle = FileHandle(forWritingAtPath: fileURL.path) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            if state.writesToConsole {
                print("Logger file write failed: \(error.localizedDescription)")
            }
        }
    }
}
