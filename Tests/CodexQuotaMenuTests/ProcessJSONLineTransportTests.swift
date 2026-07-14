import Darwin
import Foundation
import Testing
@testable import CodexQuotaMenu

@Suite
struct ProcessJSONLineTransportTests {
    @Test
    func testRoundTripsOneLineThroughCat() async throws {
        let transport = ProcessJSONLineTransport(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )

        try await transport.start()
        try await transport.send("hello")
        #expect(try await transport.receive() == "hello")
        await transport.stop()
    }

    @Test
    func testStopReapsProcessAndCatChild() async throws {
        let transport = ProcessJSONLineTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "cat & child=$!; echo \"$$ $child\"; wait \"$child\"; sleep 1"
            ]
        )

        try await transport.start()
        let components = try await transport.receive().split(separator: " ")
        #expect(components.count == 2)
        let shellPID = try #require(components.first.flatMap { pid_t($0) })
        let catPID = try #require(components.last.flatMap { pid_t($0) })

        await transport.stop()

        #expect(!Self.processExists(shellPID))
        #expect(!Self.processExists(catPID))
    }

    private static func processExists(_ processID: pid_t) -> Bool {
        kill(processID, 0) == 0 || errno == EPERM
    }
}
