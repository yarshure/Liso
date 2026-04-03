import Foundation
import Testing
@testable import Lisao

@Test func loggerWritesToConfiguredFile() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let fileURL = directory.appendingPathComponent("module.log")

    let logger = Logger(
        category: "UnitTest",
        fileURL: fileURL,
        writesToConsole: false,
        dateProvider: { Date(timeIntervalSince1970: 1_234_567_890) }
    )

    logger.info("hello logger", file: "Tests/LisaoTests/LisaoTests.swift", function: "loggerWritesToConfiguredFile()", line: 12)

    let contents = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(contents.contains("[INFO]"))
    #expect(contents.contains("[UnitTest]"))
    #expect(contents.contains("hello logger"))
}

@Test func debugFlagMatchesBuildConfiguration() {
    #if DEBUG
    #expect(Logger.isDebugLoggingEnabled())
    #else
    #expect(!Logger.isDebugLoggingEnabled())
    #endif
}
