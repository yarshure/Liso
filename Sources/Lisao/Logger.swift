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
        var fileHandle: FileHandle?
        var bufferedData: Data
    }

    private let queue: DispatchQueue
    private let fileManager: FileManager
    private let dateProvider: @Sendable () -> Date
    private let formatter: ISO8601DateFormatter
    private let flushThreshold = 32 * 1024
    private let flushInterval: DispatchTimeInterval = .milliseconds(100)
    private let flushTimer: DispatchSourceTimer
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
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.flushTimer = DispatchSource.makeTimerSource(queue: queue)
        self.state = State(
            category: category,
            fileURL: fileURL,
            writesToConsole: writesToConsole,
            fileHandle: nil,
            bufferedData: Data()
        )

        flushTimer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        flushTimer.setEventHandler { [weak self] in
            self?.flushBufferedData()
        }
        flushTimer.resume()
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
        queue.async {
            if self.state.fileURL == fileURL { return }
            self.flushBufferedData()
            self.closeFileHandle()
            self.state.fileURL = fileURL
            _ = self.openFileHandleIfNeeded()
        }
    }

    public func updateCategory(_ category: String) {
        queue.async {
            self.state.category = category
        }
    }

    public func updateConsoleOutput(enabled: Bool) {
        queue.async {
            self.state.writesToConsole = enabled
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

        queue.async {
            let rendered = self.render(
                date: now,
                level: level,
                category: self.state.category,
                message: message,
                file: file,
                function: function,
                line: line
            )

            if self.state.writesToConsole {
                print(rendered)
            }

            if let fileURL = self.state.fileURL {
                self.append(rendered + "\n", to: fileURL)
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

    private func render(
        date: Date,
        level: Level,
        category: String,
        message: String,
        file: String,
        function: String,
        line: Int
    ) -> String {
        let timestamp = formatter.string(from: date)
        let source = "\(file):\(line) \(function)"
        return "\(timestamp) [\(level.rawValue)] [\(category)] \(message) (\(source))"
    }

    private func append(_ text: String, to fileURL: URL) {
        guard let data = text.data(using: .utf8) else { return }
        state.bufferedData.append(data)

        if state.fileHandle == nil {
            _ = openFileHandleIfNeeded()
        }

        if state.bufferedData.count >= flushThreshold {
            flushBufferedData()
        }
    }

    private func openFileHandleIfNeeded() -> Bool {
        guard state.fileHandle == nil, let fileURL = state.fileURL else {
            return state.fileHandle != nil
        }

        do {
            let directory = fileURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: directory.path) {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            if !fileManager.fileExists(atPath: fileURL.path) {
                try Data().write(to: fileURL)
            }

            guard let handle = FileHandle(forWritingAtPath: fileURL.path) else {
                return false
            }

            handle.seekToEndOfFile()
            state.fileHandle = handle
            return true
        } catch {
            reportFileWriteFailure(error)
            return false
        }
    }

    private func flushBufferedData() {
        guard !state.bufferedData.isEmpty else { return }
        guard openFileHandleIfNeeded(), let handle = state.fileHandle else { return }

        handle.write(state.bufferedData)
        state.bufferedData.removeAll(keepingCapacity: true)
    }

    private func closeFileHandle() {
        guard let handle = state.fileHandle else { return }
        handle.closeFile()
        state.fileHandle = nil
    }

    private func reportFileWriteFailure(_ error: Error) {
        if state.writesToConsole {
            print("Logger file write failed: \(error.localizedDescription)")
        }
    }

    deinit {
        flushTimer.setEventHandler {}
        flushTimer.cancel()
        queue.sync {
            self.flushBufferedData()
            self.closeFileHandle()
        }
    }
}
