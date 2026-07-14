# Codex Quota Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and install a native macOS menu-bar app that safely displays Codex quota windows, reset-credit count, and each reset credit's expiration time.

**Architecture:** A SwiftUI `MenuBarExtra` is driven by a main-actor `QuotaStore`. A read-only JSON-RPC client launches the bundled Codex App Server over stdio, maps `account/rateLimits/read` into domain models, caches the last successful snapshot, and schedules local expiration notifications. Swift Package Manager compiles the executable, and a deterministic script assembles and ad-hoc signs a standard `.app` bundle.

**Tech Stack:** Swift 5 language mode on Apple Swift 6.3.3, Swift Package Manager, SwiftUI, Foundation, AppKit, Combine, CryptoKit, ServiceManagement, UserNotifications, XCTest, shell packaging scripts.

## Global Constraints

- Support macOS 14 and newer on Apple Silicon.
- Build with Command Line Tools using `swift build`; do not require the full Xcode application.
- Use no third-party runtime or build dependencies.
- Keep the application menu-bar-only with `LSUIElement = true` and no Dock icon.
- Refresh on launch, every exactly 300 seconds, and on manual request; coalesce overlapping refreshes.
- Mark cached data stale after exactly 1,800 seconds without a successful refresh.
- Schedule one notification per available reset credit exactly 86,400 seconds before expiration.
- Permit only `initialize`, `initialized`, and `account/rateLimits/read` on the App Server connection.
- Never access browser cookies, ChatGPT credentials, Codex authentication files, or the Codex SQLite database directly.
- Never define, call, or serialize a reset-credit redemption method in the application target.
- Persist display data and SHA-256 notification keys only; never persist backend reset-credit IDs or account tokens.
- Package with bundle identifier `local.scott.CodexQuotaMenu` and ad-hoc signing for personal use.
- Use test-driven development for every behavior-bearing task and commit after each task passes.

---

## File Map

| Path | Responsibility |
|---|---|
| `Package.swift` | SwiftPM executable and XCTest target configuration |
| `Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift` | SwiftUI application entry and dependency composition |
| `Sources/CodexQuotaMenu/Domain/QuotaModels.swift` | Safe domain models and quota calculations |
| `Sources/CodexQuotaMenu/Protocol/AppServerWireModels.swift` | Decodable Codex App Server response types |
| `Sources/CodexQuotaMenu/Services/QuotaResponseMapper.swift` | Wire-to-domain mapping and credit-key hashing |
| `Sources/CodexQuotaMenu/Services/CodexExecutableLocator.swift` | Deterministic discovery of the bundled Codex executable |
| `Sources/CodexQuotaMenu/Services/JSONLineTransport.swift` | Testable line-transport boundary |
| `Sources/CodexQuotaMenu/Services/ProcessJSONLineTransport.swift` | `Process` and pipe-backed production transport |
| `Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift` | Initialization handshake, request whitelist, timeout, and one restart |
| `Sources/CodexQuotaMenu/Services/QuotaReader.swift` | Read-only service that fetches and maps one snapshot |
| `Sources/CodexQuotaMenu/Persistence/QuotaCache.swift` | Atomic Application Support cache |
| `Sources/CodexQuotaMenu/Notifications/ExpiryNotificationScheduler.swift` | Pure notification planning and UserNotifications adapter |
| `Sources/CodexQuotaMenu/System/LaunchAtLoginController.swift` | `SMAppService.mainApp` registration and preference |
| `Sources/CodexQuotaMenu/UI/QuotaStore.swift` | Refresh lifecycle, cache fallback, stale state, and UI state |
| `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift` | Quota window, reset-credit, error, and settings presentation |
| `Sources/CodexQuotaMenu/UI/MenuBarPresentation.swift` | Deterministic menu-bar title formatting |
| `Resources/Info.plist` | Standard app-bundle metadata and `LSUIElement` |
| `scripts/build-app.sh` | Release build, bundle assembly, and ad-hoc signing |
| `scripts/verify-app.sh` | Bundle metadata, signature, and read-only checks |
| `Tests/CodexQuotaMenuTests/**` | Unit, service, store, packaging, and gated live tests |
| `README.md` | Build, install, launch-at-login, privacy, and uninstall instructions |

---

### Task 1: SwiftPM Shell and Safe Domain Models

**Files:**
- Create: `.gitignore`
- Create: `Package.swift`
- Create: `Sources/CodexQuotaMenu/Domain/QuotaModels.swift`
- Create: `Sources/CodexQuotaMenu/UI/MenuBarPresentation.swift`
- Create: `Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift`
- Create: `Tests/CodexQuotaMenuTests/QuotaModelsTests.swift`

**Interfaces:**
- Consumes: No application code; only macOS system frameworks.
- Produces: `QuotaWindow`, `ResetCredit`, `QuotaSnapshot`, `QuotaDisplayState`, and `MenuBarPresentation.title(for:)` for all later tasks.

- [ ] **Step 1: Create the package manifest and failing domain tests**

Create `Package.swift`:

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexQuotaMenu",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexQuotaMenu", targets: ["CodexQuotaMenu"])
    ],
    targets: [
        .executableTarget(
            name: "CodexQuotaMenu",
            path: "Sources/CodexQuotaMenu"
        ),
        .testTarget(
            name: "CodexQuotaMenuTests",
            dependencies: ["CodexQuotaMenu"],
            path: "Tests/CodexQuotaMenuTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
```

Create `.gitignore`:

```gitignore
.build/
.swiftpm/
dist/
build/
*.xcuserstate
.DS_Store
```

Create `Tests/CodexQuotaMenuTests/QuotaModelsTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class QuotaModelsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_784_038_400)

    func testRemainingPercentIsClamped() {
        XCTAssertEqual(QuotaWindow(id: "a", label: "A", usedPercent: -2, durationMinutes: 300, resetsAt: nil).remainingPercent, 100)
        XCTAssertEqual(QuotaWindow(id: "b", label: "B", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil).remainingPercent, 47)
        XCTAssertEqual(QuotaWindow(id: "c", label: "C", usedPercent: 140, durationMinutes: nil, resetsAt: nil).remainingPercent, 0)
    }

    func testSnapshotUsesMostConstrainedWindow() {
        let snapshot = QuotaSnapshot(
            windows: [
                QuotaWindow(id: "five-hour", label: "5 小时额度", usedPercent: 9, durationMinutes: 300, resetsAt: nil),
                QuotaWindow(id: "weekly", label: "每周额度", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil)
            ],
            availableResetCount: 5,
            resetCredits: [],
            fetchedAt: now
        )
        XCTAssertEqual(snapshot.mostConstrainedRemainingPercent, 47)
    }

    func testMenuTitleCoversFreshStaleAndUnavailableStates() {
        let snapshot = QuotaSnapshot(
            windows: [QuotaWindow(id: "weekly", label: "每周额度", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil)],
            availableResetCount: 5,
            resetCredits: [],
            fetchedAt: now
        )
        XCTAssertEqual(MenuBarPresentation.title(for: .fresh(snapshot)), "47% · 5")
        XCTAssertEqual(MenuBarPresentation.title(for: .stale(snapshot, message: "offline")), "47% · 5 !")
        XCTAssertEqual(MenuBarPresentation.title(for: .loading), "— · —")
        XCTAssertEqual(MenuBarPresentation.title(for: .unavailable(message: "missing")), "不可用")
    }
}
```

- [ ] **Step 2: Run the tests and verify the package fails to compile**

Run:

```bash
swift test --filter QuotaModelsTests
```

Expected: compilation fails because `QuotaWindow`, `QuotaSnapshot`, `QuotaDisplayState`, and `MenuBarPresentation` do not exist.

- [ ] **Step 3: Implement the domain models and deterministic menu title**

Create `Sources/CodexQuotaMenu/Domain/QuotaModels.swift`:

```swift
import Foundation

struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let usedPercent: Int
    let durationMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Int {
        min(max(100 - usedPercent, 0), 100)
    }
}

enum ResetCreditStatus: String, Codable, Equatable, Sendable {
    case available
    case redeeming
    case redeemed
    case unknown
}

struct ResetCredit: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let status: ResetCreditStatus
    let grantedAt: Date
    let expiresAt: Date?
    let title: String?
    let detail: String?
}

struct QuotaSnapshot: Codable, Equatable, Sendable {
    let windows: [QuotaWindow]
    let availableResetCount: Int
    let resetCredits: [ResetCredit]?
    let fetchedAt: Date

    var mostConstrainedRemainingPercent: Int? {
        windows.map(\.remainingPercent).min()
    }

    func isStale(at date: Date, threshold: TimeInterval = 1_800) -> Bool {
        date.timeIntervalSince(fetchedAt) >= threshold
    }
}

enum QuotaDisplayState: Equatable, Sendable {
    case loading
    case fresh(QuotaSnapshot)
    case stale(QuotaSnapshot, message: String)
    case unavailable(message: String)

    var snapshot: QuotaSnapshot? {
        switch self {
        case .fresh(let snapshot), .stale(let snapshot, _): return snapshot
        case .loading, .unavailable: return nil
        }
    }
}
```

Create `Sources/CodexQuotaMenu/UI/MenuBarPresentation.swift`:

```swift
enum MenuBarPresentation {
    static func title(for state: QuotaDisplayState) -> String {
        switch state {
        case .loading:
            return "— · —"
        case .unavailable:
            return "不可用"
        case .fresh(let snapshot):
            return title(snapshot: snapshot, suffix: "")
        case .stale(let snapshot, _):
            return title(snapshot: snapshot, suffix: " !")
        }
    }

    private static func title(snapshot: QuotaSnapshot, suffix: String) -> String {
        let percent = snapshot.mostConstrainedRemainingPercent.map { "\($0)%" } ?? "—"
        return "\(percent) · \(snapshot.availableResetCount)\(suffix)"
    }
}
```

Create the smallest buildable app shell in `Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift`:

```swift
import SwiftUI

@main
struct CodexQuotaMenuApp: App {
    var body: some Scene {
        MenuBarExtra("Codex Quota") {
            Text("正在准备额度读取…")
                .padding()
        } label: {
            Label("— · —", systemImage: "gauge.with.dots.needle.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 4: Run unit tests and compile the executable**

Run:

```bash
swift test --filter QuotaModelsTests
swift build
```

Expected: all three tests pass and the `CodexQuotaMenu` executable builds successfully.

- [ ] **Step 5: Commit the package shell and domain contract**

```bash
git add .gitignore Package.swift Sources Tests
git commit -m "feat: add quota domain and SwiftPM app shell"
```

---

### Task 2: Decode and Map the App Server Rate-Limit Response

**Files:**
- Create: `Sources/CodexQuotaMenu/Protocol/AppServerWireModels.swift`
- Create: `Sources/CodexQuotaMenu/Services/QuotaResponseMapper.swift`
- Create: `Tests/CodexQuotaMenuTests/QuotaResponseMapperTests.swift`

**Interfaces:**
- Consumes: `QuotaWindow`, `ResetCredit`, and `QuotaSnapshot` from Task 1.
- Produces: `RateLimitsReadResponse` and `QuotaResponseMapper.map(_:fetchedAt:) throws -> QuotaSnapshot` for the live reader in Task 4.

- [ ] **Step 1: Write failing decoder and mapping tests using a realistic response**

Create `Tests/CodexQuotaMenuTests/QuotaResponseMapperTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class QuotaResponseMapperTests: XCTestCase {
    func testMapsWindowsCountAndCreditExpirationWithoutPersistingBackendID() throws {
        let data = Data(Self.responseJSON.utf8)
        let response = try JSONDecoder().decode(RateLimitsReadResponse.self, from: data)
        let fetchedAt = Date(timeIntervalSince1970: 1_784_038_400)
        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.windows.map(\.label), ["每周额度"])
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 47)
        XCTAssertEqual(snapshot.availableResetCount, 5)
        XCTAssertEqual(snapshot.resetCredits?.count, 1)
        XCTAssertEqual(snapshot.resetCredits?.first?.expiresAt, Date(timeIntervalSince1970: 1_784_335_339))
        XCTAssertNotEqual(snapshot.resetCredits?.first?.id, "backend-secret-id")
        XCTAssertEqual(snapshot.resetCredits?.first?.id.count, 64)
    }

    func testNullCreditDetailsKeepsAvailableCount() throws {
        let data = Data(Self.responseJSON.replacingOccurrences(
            of: #""credits":[{"id":"backend-secret-id","resetType":"codexRateLimits","status":"available","grantedAt":1781743339,"expiresAt":1784335339,"title":"Full reset","description":"Granted"}]"#,
            with: #""credits":null"#
        ).utf8)
        let response = try JSONDecoder().decode(RateLimitsReadResponse.self, from: data)
        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        XCTAssertEqual(snapshot.availableResetCount, 5)
        XCTAssertNil(snapshot.resetCredits)
    }

    func testMapsPrimaryAndSecondaryWindowsWithoutDuplicatingLegacyBucket() throws {
        let response = RateLimitsReadResponse(
            rateLimits: WireRateLimitSnapshot(
                limitId: "legacy",
                limitName: nil,
                primary: WireRateLimitWindow(usedPercent: 99, windowDurationMins: 300, resetsAt: nil),
                secondary: nil
            ),
            rateLimitsByLimitId: [
                "codex": WireRateLimitSnapshot(
                    limitId: "codex",
                    limitName: nil,
                    primary: WireRateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
                    secondary: WireRateLimitWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: nil)
                )
            ],
            rateLimitResetCredits: WireResetCreditsSummary(availableCount: 0, credits: [])
        )
        let snapshot = try QuotaResponseMapper.map(response, fetchedAt: .distantPast)
        XCTAssertEqual(snapshot.windows.map(\.label), ["5 小时额度", "每周额度"])
        XCTAssertEqual(snapshot.mostConstrainedRemainingPercent, 60)
    }

    private static let responseJSON = #"""
    {
      "rateLimits": {
        "limitId": "codex",
        "primary": {"usedPercent": 53, "windowDurationMins": 10080, "resetsAt": 1784503858},
        "secondary": null
      },
      "rateLimitsByLimitId": {
        "codex": {
          "limitId": "codex",
          "primary": {"usedPercent": 53, "windowDurationMins": 10080, "resetsAt": 1784503858},
          "secondary": null,
          "unknownFutureField": true
        }
      },
      "rateLimitResetCredits": {
        "availableCount": 5,
        "credits":[{"id":"backend-secret-id","resetType":"codexRateLimits","status":"available","grantedAt":1781743339,"expiresAt":1784335339,"title":"Full reset","description":"Granted"}]
      }
    }
    """#
}
```

- [ ] **Step 2: Run the mapper tests and verify missing types fail compilation**

Run:

```bash
swift test --filter QuotaResponseMapperTests
```

Expected: compilation fails because the wire models and mapper do not exist.

- [ ] **Step 3: Implement wire models that tolerate optional and unknown fields**

Create `Sources/CodexQuotaMenu/Protocol/AppServerWireModels.swift`:

```swift
import Foundation

struct RateLimitsReadResponse: Decodable, Sendable {
    let rateLimits: WireRateLimitSnapshot
    let rateLimitsByLimitId: [String: WireRateLimitSnapshot]?
    let rateLimitResetCredits: WireResetCreditsSummary?
}

struct WireRateLimitSnapshot: Decodable, Sendable {
    let limitId: String?
    let limitName: String?
    let primary: WireRateLimitWindow?
    let secondary: WireRateLimitWindow?
}

struct WireRateLimitWindow: Decodable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int?
    let resetsAt: Int64?
}

struct WireResetCreditsSummary: Decodable, Sendable {
    let availableCount: Int
    let credits: [WireResetCredit]?
}

struct WireResetCredit: Decodable, Sendable {
    let id: String
    let status: String
    let grantedAt: Int64
    let expiresAt: Int64?
    let title: String?
    let description: String?
}
```

- [ ] **Step 4: Implement safe mapping, labels, sorting, and SHA-256 identity keys**

Create `Sources/CodexQuotaMenu/Services/QuotaResponseMapper.swift`:

```swift
import CryptoKit
import Foundation

enum QuotaMappingError: LocalizedError {
    case noQuotaWindows

    var errorDescription: String? { "Codex 返回的数据中没有可识别的额度窗口。" }
}

enum QuotaResponseMapper {
    static func map(_ response: RateLimitsReadResponse, fetchedAt: Date) throws -> QuotaSnapshot {
        let buckets: [WireRateLimitSnapshot]
        if let keyed = response.rateLimitsByLimitId, !keyed.isEmpty {
            buckets = keyed.keys.sorted().compactMap { keyed[$0] }
        } else {
            buckets = [response.rateLimits]
        }

        let windows = buckets.flatMap { bucket in
            [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { entry in
                let (slot, optionalWindow) = entry
                guard let window = optionalWindow else { return nil }
                return QuotaWindow(
                    id: "\(bucket.limitId ?? "codex")-\(slot)",
                    label: label(for: window.windowDurationMins, fallback: bucket.limitName),
                    usedPercent: window.usedPercent,
                    durationMinutes: window.windowDurationMins,
                    resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }
        guard !windows.isEmpty else { throw QuotaMappingError.noQuotaWindows }

        let details = response.rateLimitResetCredits?.credits?.compactMap { wire -> ResetCredit? in
            let status = ResetCreditStatus(rawValue: wire.status) ?? .unknown
            guard status == .available else { return nil }
            let expiration = wire.expiresAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return ResetCredit(
                id: stableKey(backendID: wire.id, expiresAt: expiration),
                status: status,
                grantedAt: Date(timeIntervalSince1970: TimeInterval(wire.grantedAt)),
                expiresAt: expiration,
                title: wire.title,
                detail: wire.description
            )
        }.sorted { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs.id < rhs.id
            }
        }

        return QuotaSnapshot(
            windows: windows,
            availableResetCount: max(response.rateLimitResetCredits?.availableCount ?? 0, 0),
            resetCredits: response.rateLimitResetCredits?.credits == nil ? nil : details,
            fetchedAt: fetchedAt
        )
    }

    private static func label(for minutes: Int?, fallback: String?) -> String {
        switch minutes {
        case 300: return "5 小时额度"
        case 10_080: return "每周额度"
        default:
            if let fallback, !fallback.isEmpty { return fallback }
            return "Codex 额度"
        }
    }

    private static func stableKey(backendID: String, expiresAt: Date?) -> String {
        let seconds = expiresAt.map { String(Int64($0.timeIntervalSince1970)) } ?? "never"
        let digest = SHA256.hash(data: Data("\(backendID)\u{0}\(seconds)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 5: Run the focused and full test suites**

Run:

```bash
swift test --filter QuotaResponseMapperTests
swift test
```

Expected: mapper tests and all existing tests pass.

- [ ] **Step 6: Commit response decoding and mapping**

```bash
git add Sources/CodexQuotaMenu/Protocol Sources/CodexQuotaMenu/Services/QuotaResponseMapper.swift Tests/CodexQuotaMenuTests/QuotaResponseMapperTests.swift
git commit -m "feat: decode Codex quota responses"
```

---

### Task 3: Codex Executable Discovery and Process Line Transport

**Files:**
- Create: `Sources/CodexQuotaMenu/Services/CodexExecutableLocator.swift`
- Create: `Sources/CodexQuotaMenu/Services/JSONLineTransport.swift`
- Create: `Sources/CodexQuotaMenu/Services/ProcessJSONLineTransport.swift`
- Create: `Tests/CodexQuotaMenuTests/CodexExecutableLocatorTests.swift`
- Create: `Tests/CodexQuotaMenuTests/ProcessJSONLineTransportTests.swift`

**Interfaces:**
- Consumes: Foundation `Process`, `Pipe`, and `FileHandle`.
- Produces: `CodexExecutableLocating.locate() throws -> URL`, `JSONLineTransport`, and `ProcessJSONLineTransport(executableURL:arguments:)` for Task 4.

- [ ] **Step 1: Write failing locator and `/bin/cat` transport tests**

Create `Tests/CodexQuotaMenuTests/CodexExecutableLocatorTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class CodexExecutableLocatorTests: XCTestCase {
    func testReturnsFirstExecutableCandidate() throws {
        let locator = CodexExecutableLocator(
            candidates: [URL(fileURLWithPath: "/missing"), URL(fileURLWithPath: "/bin/cat")],
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0.path) }
        )
        XCTAssertEqual(try locator.locate().path, "/bin/cat")
    }

    func testThrowsActionableErrorWhenNothingExists() {
        let locator = CodexExecutableLocator(candidates: [URL(fileURLWithPath: "/missing")], isExecutable: { _ in false })
        XCTAssertThrowsError(try locator.locate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("ChatGPT"))
        }
    }
}
```

Create `Tests/CodexQuotaMenuTests/ProcessJSONLineTransportTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class ProcessJSONLineTransportTests: XCTestCase {
    func testRoundTripsOneLineThroughCat() async throws {
        let transport = ProcessJSONLineTransport(executableURL: URL(fileURLWithPath: "/bin/cat"), arguments: [])
        try await transport.start()
        try await transport.send("hello")
        XCTAssertEqual(try await transport.receive(), "hello")
        await transport.stop()
    }
}
```

- [ ] **Step 2: Run the tests and confirm missing transport types fail compilation**

Run:

```bash
swift test --filter CodexExecutableLocatorTests
swift test --filter ProcessJSONLineTransportTests
```

Expected: compilation fails because locator and transport types do not exist.

- [ ] **Step 3: Implement deterministic executable discovery**

Create `Sources/CodexQuotaMenu/Services/CodexExecutableLocator.swift`:

```swift
import Foundation

protocol CodexExecutableLocating: Sendable {
    func locate() throws -> URL
}

struct CodexExecutableNotFound: LocalizedError {
    var errorDescription: String? {
        "找不到 Codex。请确认 ChatGPT 已安装在 /Applications 并完成登录。"
    }
}

struct CodexExecutableLocator: CodexExecutableLocating {
    let candidates: [URL]
    private let isExecutable: @Sendable (URL) -> Bool

    init(
        candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ],
        isExecutable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isExecutableFile(atPath: $0.path) }
    ) {
        self.candidates = candidates
        self.isExecutable = isExecutable
    }

    func locate() throws -> URL {
        guard let match = candidates.first(where: isExecutable) else { throw CodexExecutableNotFound() }
        return match
    }
}
```

- [ ] **Step 4: Implement the transport interface and pipe-backed actor**

Create `Sources/CodexQuotaMenu/Services/JSONLineTransport.swift`:

```swift
protocol JSONLineTransport: AnyObject, Sendable {
    func start() async throws
    func send(_ line: String) async throws
    func receive() async throws -> String
    func stop() async
}

enum JSONLineTransportError: Error, Equatable {
    case notStarted
    case closed
    case invalidUTF8
}
```

Create `Sources/CodexQuotaMenu/Services/ProcessJSONLineTransport.swift` with a single actor that owns the process, pipes, buffered bytes, and an `AsyncThrowingStream<String, Error>`. Its public methods must use these exact signatures:

```swift
import Foundation

actor ProcessJSONLineTransport: JSONLineTransport {
    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var iterator: AsyncThrowingStream<String, Error>.Iterator?

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func start() async throws {
        guard process == nil else { return }
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let stream = AsyncThrowingStream<String, Error> { continuation in
            var buffer = Data()
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    continuation.finish()
                    return
                }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    guard let line = String(data: lineData, encoding: .utf8) else {
                        continuation.finish(throwing: JSONLineTransportError.invalidUTF8)
                        return
                    }
                    continuation.yield(line)
                }
            }
            process.terminationHandler = { _ in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                continuation.finish()
            }
        }

        try process.run()
        self.process = process
        self.input = inputPipe.fileHandleForWriting
        self.iterator = stream.makeAsyncIterator()
    }

    func send(_ line: String) async throws {
        guard let input else { throw JSONLineTransportError.notStarted }
        try input.write(contentsOf: Data((line + "\n").utf8))
    }

    func receive() async throws -> String {
        guard var iterator else { throw JSONLineTransportError.notStarted }
        guard let line = try await iterator.next() else { throw JSONLineTransportError.closed }
        self.iterator = iterator
        return line
    }

    func stop() async {
        input?.closeFile()
        process?.terminate()
        process = nil
        input = nil
        iterator = nil
    }
}
```

- [ ] **Step 5: Run focused tests, then all tests**

Run:

```bash
swift test --filter CodexExecutableLocatorTests
swift test --filter ProcessJSONLineTransportTests
swift test
```

Expected: locator tests, the `/bin/cat` round-trip, and all earlier tests pass with no child process left running.

- [ ] **Step 6: Commit executable discovery and transport**

```bash
git add Sources/CodexQuotaMenu/Services Tests/CodexQuotaMenuTests/CodexExecutableLocatorTests.swift Tests/CodexQuotaMenuTests/ProcessJSONLineTransportTests.swift
git commit -m "feat: add Codex process transport"
```

---

### Task 4: Read-Only JSON-RPC Client and Live Quota Reader

**Files:**
- Create: `Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift`
- Create: `Sources/CodexQuotaMenu/Services/QuotaReader.swift`
- Create: `Tests/CodexQuotaMenuTests/CodexAppServerClientTests.swift`
- Create: `Tests/CodexQuotaMenuTests/QuotaReaderTests.swift`

**Interfaces:**
- Consumes: `JSONLineTransport`, `CodexExecutableLocating`, `RateLimitsReadResponse`, and `QuotaResponseMapper` from Tasks 2–3.
- Produces: `RateLimitsReading.readRateLimits() async throws -> RateLimitsReadResponse` and `QuotaReading.read() async throws -> QuotaSnapshot` for `QuotaStore` in Task 7.

- [ ] **Step 1: Write a failing test that captures the exact outbound method set**

Create `Tests/CodexQuotaMenuTests/CodexAppServerClientTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class CodexAppServerClientTests: XCTestCase {
    func testInitializesThenReadsRateLimitsUsingOnlyWhitelistedMethods() async throws {
        let transport = FakeJSONLineTransport(lines: [
            #"{"id":0,"result":{"userAgent":"test"}}"#,
            #"{"method":"account/rateLimits/updated","params":{}}"#,
            #"{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":53,"windowDurationMins":10080,"resetsAt":1784503858},"secondary":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":5,"credits":[]}}}"#
        ])
        let client = CodexAppServerClient(makeTransport: { transport }, timeoutSeconds: 1)

        let result = try await client.readRateLimits()
        XCTAssertEqual(result.rateLimitResetCredits?.availableCount, 5)

        let sent = await transport.sentLines
        let methods = try sent.map { line -> String in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(object["method"] as? String)
        }
        XCTAssertEqual(methods, ["initialize", "initialized", "account/rateLimits/read"])
        XCTAssertEqual(Set(AppServerMethod.allCases.map(\.rawValue)), Set(methods))
    }
}

private actor FakeJSONLineTransport: JSONLineTransport {
    private var lines: [String]
    private(set) var sentLines: [String] = []

    init(lines: [String]) { self.lines = lines }
    func start() async throws {}
    func send(_ line: String) async throws { sentLines.append(line) }
    func receive() async throws -> String {
        guard !lines.isEmpty else { throw JSONLineTransportError.closed }
        return lines.removeFirst()
    }
    func stop() async {}
}
```

Create `Tests/CodexQuotaMenuTests/QuotaReaderTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class QuotaReaderTests: XCTestCase {
    func testReaderUsesInjectedTimeForFetchedAt() async throws {
        let fixed = Date(timeIntervalSince1970: 1_784_038_400)
        let reader = LiveQuotaReader(client: StubRateLimitsReader(response: Self.response), now: { fixed })
        let snapshot = try await reader.read()
        XCTAssertEqual(snapshot.fetchedAt, fixed)
        XCTAssertEqual(snapshot.availableResetCount, 2)
    }

    private static let response = RateLimitsReadResponse(
        rateLimits: WireRateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: WireRateLimitWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: nil),
            secondary: nil
        ),
        rateLimitsByLimitId: nil,
        rateLimitResetCredits: WireResetCreditsSummary(availableCount: 2, credits: [])
    )
}

private struct StubRateLimitsReader: RateLimitsReading {
    let response: RateLimitsReadResponse
    func readRateLimits() async throws -> RateLimitsReadResponse { response }
}
```

The wire structs' synthesized internal memberwise initializers are available to the test target through `@testable import`; no production-only factory is added.

- [ ] **Step 2: Run the client and reader tests and verify they fail to compile**

Run:

```bash
swift test --filter CodexAppServerClientTests
swift test --filter QuotaReaderTests
```

Expected: compilation fails because `CodexAppServerClient`, `AppServerMethod`, `RateLimitsReading`, and `LiveQuotaReader` do not exist.

- [ ] **Step 3: Implement the method whitelist and sequential JSON-RPC client**

Create `Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift`:

```swift
import Foundation

enum AppServerMethod: String, CaseIterable, Sendable {
    case initialize
    case initialized
    case rateLimitsRead = "account/rateLimits/read"
}

protocol RateLimitsReading: Sendable {
    func readRateLimits() async throws -> RateLimitsReadResponse
}

enum AppServerClientError: LocalizedError {
    case timeout
    case malformedResponse
    case server(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "读取 Codex 额度超时。"
        case .malformedResponse: return "Codex 返回了无法识别的数据。"
        case .server(_, let message): return message
        }
    }
}

private struct MessageHeader: Decodable { let id: Int?; let method: String? }
private struct RPCError: Decodable { let code: Int; let message: String }
private struct RPCResponse<Result: Decodable>: Decodable {
    let id: Int
    let result: Result?
    let error: RPCError?
}
private struct IgnoredResult: Decodable {}

actor CodexAppServerClient: RateLimitsReading {
    private let makeTransport: @Sendable () -> any JSONLineTransport
    private let timeoutSeconds: TimeInterval
    private var transport: (any JSONLineTransport)?

    init(
        makeTransport: @escaping @Sendable () -> any JSONLineTransport,
        timeoutSeconds: TimeInterval = 10
    ) {
        self.makeTransport = makeTransport
        self.timeoutSeconds = timeoutSeconds
    }

    func readRateLimits() async throws -> RateLimitsReadResponse {
        do {
            return try await readOnce()
        } catch {
            await reset()
            do {
                return try await readOnce()
            } catch {
                await reset()
                throw error
            }
        }
    }

    private func readOnce() async throws -> RateLimitsReadResponse {
        let transport = try await initializedTransport()
        try await transport.send(#"{"method":"account/rateLimits/read","id":1,"params":null}"#)
        return try await waitForResponse(id: 1, result: RateLimitsReadResponse.self, transport: transport)
    }

    private func initializedTransport() async throws -> any JSONLineTransport {
        if let transport { return transport }
        let candidate = makeTransport()
        do {
            try await candidate.start()
            try await candidate.send(#"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"codex_quota_menu","title":"Codex Quota Menu","version":"0.1.0"}}}"#)
            _ = try await waitForResponse(id: 0, result: IgnoredResult.self, transport: candidate)
            try await candidate.send(#"{"method":"initialized","params":{}}"#)
            transport = candidate
            return candidate
        } catch {
            await candidate.stop()
            throw error
        }
    }

    private func waitForResponse<Result: Decodable>(
        id: Int,
        result: Result.Type,
        transport: any JSONLineTransport
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            group.addTask {
                while true {
                    let line = try await transport.receive()
                    let data = Data(line.utf8)
                    let header = try JSONDecoder().decode(MessageHeader.self, from: data)
                    guard header.id == id else { continue }
                    let response = try JSONDecoder().decode(RPCResponse<Result>.self, from: data)
                    if let error = response.error { throw AppServerClientError.server(code: error.code, message: error.message) }
                    guard let result = response.result else { throw AppServerClientError.malformedResponse }
                    return result
                }
            }
            group.addTask { [timeoutSeconds] in
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw AppServerClientError.timeout
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func reset() async {
        await transport?.stop()
        transport = nil
    }

    func stop() async { await reset() }
}
```

This actor serializes reads, ignores notifications with no matching ID, restarts the transport once after a failed read, and never accepts arbitrary method strings.

- [ ] **Step 4: Implement the live reader and production composition helper**

Create `Sources/CodexQuotaMenu/Services/QuotaReader.swift`:

```swift
import Foundation

protocol QuotaReading: Sendable {
    func read() async throws -> QuotaSnapshot
}

struct LiveQuotaReader: QuotaReading {
    let client: any RateLimitsReading
    let now: @Sendable () -> Date

    init(client: any RateLimitsReading, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    func read() async throws -> QuotaSnapshot {
        try QuotaResponseMapper.map(await client.readRateLimits(), fetchedAt: now())
    }
}
```

- [ ] **Step 5: Add and pass the one-restart test**

Add this test and helper types to `CodexAppServerClientTests.swift`:

```swift
extension CodexAppServerClientTests {
func testRestartsTransportExactlyOnce() async throws {
    let successful = FakeJSONLineTransport(lines: [
        #"{"id":0,"result":{"userAgent":"test"}}"#,
        #"{"id":1,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":53,"windowDurationMins":10080,"resetsAt":1784503858},"secondary":null},"rateLimitsByLimitId":null,"rateLimitResetCredits":{"availableCount":5,"credits":[]}}}"#
    ])
    let queue = TransportQueue([AlwaysClosedTransport(), successful])
    let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)
    let result = try await client.readRateLimits()
    XCTAssertEqual(result.rateLimitResetCredits?.availableCount, 5)
    XCTAssertEqual(queue.makeCount, 2)
}

func testTimeoutIsReturnedAfterOneRetry() async {
    let queue = TransportQueue([HangingTransport(), HangingTransport()])
    let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 0.01)
    do {
        _ = try await client.readRateLimits()
        XCTFail("Expected timeout")
    } catch AppServerClientError.timeout {
        XCTAssertEqual(queue.makeCount, 2)
    } catch {
        XCTFail("Unexpected error: \(error)")
    }
}

func testMalformedJSONFailsAfterOneRetry() async {
    let queue = TransportQueue([
        FakeJSONLineTransport(lines: ["not-json"]),
        FakeJSONLineTransport(lines: ["still-not-json"])
    ])
    let client = CodexAppServerClient(makeTransport: { queue.next() }, timeoutSeconds: 1)
    await XCTAssertThrowsErrorAsync { _ = try await client.readRateLimits() }
    XCTAssertEqual(queue.makeCount, 2)
}

private actor AlwaysClosedTransport: JSONLineTransport {
    func start() async throws {}
    func send(_ line: String) async throws {}
    func receive() async throws -> String { throw JSONLineTransportError.closed }
    func stop() async {}
}

private actor HangingTransport: JSONLineTransport {
    func start() async throws {}
    func send(_ line: String) async throws {}
    func receive() async throws -> String {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        throw JSONLineTransportError.closed
    }
    func stop() async {}
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}

private final class TransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var transports: [any JSONLineTransport]
    private(set) var makeCount = 0
    init(_ transports: [any JSONLineTransport]) { self.transports = transports }
    func next() -> any JSONLineTransport {
        lock.lock()
        defer { lock.unlock() }
        makeCount += 1
        return transports.removeFirst()
    }
}
```

Run:

```bash
swift test --filter CodexAppServerClientTests
swift test --filter QuotaReaderTests
swift test
```

Expected: whitelist, notification-skipping, fixed-time mapping, and exactly-one-restart tests pass.

- [ ] **Step 6: Commit the read-only client**

```bash
git add Sources/CodexQuotaMenu/Services Tests/CodexQuotaMenuTests/CodexAppServerClientTests.swift Tests/CodexQuotaMenuTests/QuotaReaderTests.swift Sources/CodexQuotaMenu/Protocol/AppServerWireModels.swift
git commit -m "feat: read quotas through Codex app server"
```

---

### Task 5: Atomic Cache and Freshness Semantics

**Files:**
- Create: `Sources/CodexQuotaMenu/Persistence/QuotaCache.swift`
- Create: `Tests/CodexQuotaMenuTests/QuotaCacheTests.swift`

**Interfaces:**
- Consumes: Codable `QuotaSnapshot` from Task 1; credit IDs are already SHA-256 keys from Task 2.
- Produces: `QuotaCaching.load() async -> QuotaSnapshot?` and `QuotaCaching.save(_:) async throws` for Task 7.

- [ ] **Step 1: Write failing cache round-trip, stale-boundary, and corruption tests**

Create `Tests/CodexQuotaMenuTests/QuotaCacheTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class QuotaCacheTests: XCTestCase {
    func testRoundTripAndStaleBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("quota-cache.json")
        let cache = FileQuotaCache(fileURL: url)
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = QuotaSnapshot(
            windows: [QuotaWindow(id: "weekly", label: "每周额度", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil)],
            availableResetCount: 5,
            resetCredits: [],
            fetchedAt: fetchedAt
        )

        try await cache.save(snapshot)
        XCTAssertEqual(await cache.load(), snapshot)
        XCTAssertFalse(snapshot.isStale(at: fetchedAt.addingTimeInterval(1_799)))
        XCTAssertTrue(snapshot.isStale(at: fetchedAt.addingTimeInterval(1_800)))
    }

    func testCorruptCacheIsIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("quota-cache.json")
        try Data("not-json".utf8).write(to: url)
        XCTAssertNil(await FileQuotaCache(fileURL: url).load())
    }
}
```

- [ ] **Step 2: Run cache tests and verify the missing cache types fail compilation**

Run:

```bash
swift test --filter QuotaCacheTests
```

Expected: compilation fails because `FileQuotaCache` does not exist.

- [ ] **Step 3: Implement atomic Application Support caching**

Create `Sources/CodexQuotaMenu/Persistence/QuotaCache.swift`:

```swift
import Foundation

protocol QuotaCaching: Sendable {
    func load() async -> QuotaSnapshot?
    func save(_ snapshot: QuotaSnapshot) async throws
}

actor FileQuotaCache: QuotaCaching {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL = FileQuotaCache.defaultURL()) {
        self.fileURL = fileURL
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func load() async -> QuotaSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(QuotaSnapshot.self, from: data)
    }

    func save(_ snapshot: QuotaSnapshot) async throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Quota Menu", isDirectory: true)
            .appendingPathComponent("quota-cache.json")
    }
}
```

- [ ] **Step 4: Pass cache tests and inspect the on-disk contract**

Run:

```bash
swift test --filter QuotaCacheTests
swift test
```

Expected: round-trip, exact 1,800-second stale boundary, corruption fallback, and all existing tests pass.

- [ ] **Step 5: Commit persistence**

```bash
git add Sources/CodexQuotaMenu/Persistence Tests/CodexQuotaMenuTests/QuotaCacheTests.swift
git commit -m "feat: cache the latest quota snapshot"
```

---

### Task 6: Expiration Notification Planning and Delivery

**Files:**
- Create: `Sources/CodexQuotaMenu/Notifications/ExpiryNotificationScheduler.swift`
- Create: `Tests/CodexQuotaMenuTests/ExpiryNotificationSchedulerTests.swift`

**Interfaces:**
- Consumes: `QuotaSnapshot` and SHA-256 `ResetCredit.id` from Tasks 1–2.
- Produces: `ExpiryNotificationReconciling.reconcile(snapshot:now:) async`, preference control, and `permissionState() async` for Task 7.

- [ ] **Step 1: Write failing pure planner tests for future, immediate, and skipped notifications**

Create `Tests/CodexQuotaMenuTests/ExpiryNotificationSchedulerTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class ExpiryNotificationSchedulerTests: XCTestCase {
    func testPlansExactlyTwentyFourHoursBeforeExpiration() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credit = ResetCredit(id: String(repeating: "a", count: 64), status: .available, grantedAt: now, expiresAt: now.addingTimeInterval(172_800), title: nil, detail: nil)
        let plans = ExpiryNotificationPlanner.plans(for: snapshot(credit), now: now)
        XCTAssertEqual(plans.map(\.fireAt), [now.addingTimeInterval(86_400)])
    }

    func testInsideWindowPlansImmediateSingleNotification() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credit = ResetCredit(id: String(repeating: "b", count: 64), status: .available, grantedAt: now, expiresAt: now.addingTimeInterval(3_600), title: nil, detail: nil)
        XCTAssertEqual(ExpiryNotificationPlanner.plans(for: snapshot(credit), now: now).map(\.fireAt), [now.addingTimeInterval(1)])
    }

    func testSkipsExpiredUnknownAndNonExpiringCredits() {
        let now = Date(timeIntervalSince1970: 1_000)
        let credits = [
            ResetCredit(id: "expired", status: .available, grantedAt: now, expiresAt: now.addingTimeInterval(-1), title: nil, detail: nil),
            ResetCredit(id: "unknown", status: .unknown, grantedAt: now, expiresAt: now.addingTimeInterval(100), title: nil, detail: nil),
            ResetCredit(id: "never", status: .available, grantedAt: now, expiresAt: nil, title: nil, detail: nil)
        ]
        XCTAssertTrue(ExpiryNotificationPlanner.plans(for: snapshot(credits), now: now).isEmpty)
    }

    private func snapshot(_ credit: ResetCredit) -> QuotaSnapshot { snapshot([credit]) }
    private func snapshot(_ credits: [ResetCredit]) -> QuotaSnapshot {
        QuotaSnapshot(windows: [QuotaWindow(id: "w", label: "额度", usedPercent: 1, durationMinutes: nil, resetsAt: nil)], availableResetCount: credits.count, resetCredits: credits, fetchedAt: .distantPast)
    }
}
```

- [ ] **Step 2: Run notification tests and verify the planner is missing**

Run:

```bash
swift test --filter ExpiryNotificationSchedulerTests
```

Expected: compilation fails because planner and scheduler types do not exist.

- [ ] **Step 3: Implement the pure plan and UserNotifications adapter**

Create `Sources/CodexQuotaMenu/Notifications/ExpiryNotificationScheduler.swift`:

```swift
import Foundation
import UserNotifications

struct ExpiryNotificationPlan: Equatable, Sendable {
    let identifier: String
    let fireAt: Date
    let expiresAt: Date
}

enum ExpiryNotificationPlanner {
    static func plans(for snapshot: QuotaSnapshot, now: Date) -> [ExpiryNotificationPlan] {
        (snapshot.resetCredits ?? []).compactMap { credit in
            guard credit.status == .available, let expiresAt = credit.expiresAt, expiresAt > now else { return nil }
            let preferred = expiresAt.addingTimeInterval(-86_400)
            return ExpiryNotificationPlan(
                identifier: "codex-reset-\(credit.id)",
                fireAt: max(preferred, now.addingTimeInterval(1)),
                expiresAt: expiresAt
            )
        }
    }
}

protocol ExpiryNotificationReconciling: Sendable {
    func requestAuthorization() async
    func reconcile(snapshot: QuotaSnapshot, now: Date) async
    func setEnabled(_ enabled: Bool) async
    func isEnabled() async -> Bool
    func permissionState() async -> NotificationPermissionState
}

enum NotificationPermissionState: Equatable, Sendable { case unknown, authorized, denied }

struct NotificationLedger {
    let defaults: UserDefaults
    let key = "notifiedResetCreditKeys"

    func identifiers() -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    func replace(with identifiers: Set<String>) {
        defaults.set(identifiers.sorted(), forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

actor ExpiryNotificationScheduler: ExpiryNotificationReconciling {
    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults
    private let ledger: NotificationLedger
    private let enabledKey = "expiryNotificationsEnabled"

    init(center: UNUserNotificationCenter = .current(), defaults: UserDefaults = .standard) {
        self.center = center
        self.defaults = defaults
        self.ledger = NotificationLedger(defaults: defaults)
    }

    func isEnabled() async -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    func setEnabled(_ enabled: Bool) async {
        defaults.set(enabled, forKey: enabledKey)
        guard !enabled else {
            await requestAuthorization()
            return
        }
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix("codex-reset-") })
        ledger.clear()
    }

    func requestAuthorization() async {
        guard await isEnabled() else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func permissionState() async -> NotificationPermissionState {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    func reconcile(snapshot: QuotaSnapshot, now: Date) async {
        guard await isEnabled() else { return }
        let plans = ExpiryNotificationPlanner.plans(for: snapshot, now: now)
        let desired = Set(plans.map(\.identifier))
        let pending = await center.pendingNotificationRequests()
        let obsolete = pending.map(\.identifier).filter { $0.hasPrefix("codex-reset-") && !desired.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        var notified = ledger.identifiers().intersection(desired)

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        for plan in plans where !pending.contains(where: { $0.identifier == plan.identifier }) && !notified.contains(plan.identifier) {
            let content = UNMutableNotificationContent()
            content.title = "Codex 重置额度即将到期"
            content.body = "一份重置额度将在 \(formatter.string(from: plan.expiresAt)) 到期。"
            content.sound = .default
            let interval = max(plan.fireAt.timeIntervalSince(now), 1)
            let request = UNNotificationRequest(identifier: plan.identifier, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
            do {
                try await center.add(request)
                notified.insert(plan.identifier)
            } catch {
                continue
            }
        }
        ledger.replace(with: notified)
    }
}
```

- [ ] **Step 4: Add duplicate-prevention and setting-default assertions, then run all tests**

Add two assertions to `ExpiryNotificationSchedulerTests`:

```swift
func testPlannerProducesStableIdentifierForPersistentDeduplication() {
    let now = Date(timeIntervalSince1970: 1_000)
    let creditID = String(repeating: "c", count: 64)
    let credit = ResetCredit(id: creditID, status: .available, grantedAt: now, expiresAt: now.addingTimeInterval(172_800), title: nil, detail: nil)
    let snapshot = QuotaSnapshot(windows: [QuotaWindow(id: "w", label: "额度", usedPercent: 1, durationMinutes: nil, resetsAt: nil)], availableResetCount: 1, resetCredits: [credit], fetchedAt: now)
    let expectedIdentifiers = ["codex-reset-\(creditID)"]
    XCTAssertEqual(ExpiryNotificationPlanner.plans(for: snapshot, now: now).map(\.identifier), expectedIdentifiers)
    XCTAssertEqual(ExpiryNotificationPlanner.plans(for: snapshot, now: now).map(\.identifier), expectedIdentifiers)
}

func testNotificationPreferenceDefaultsToEnabled() async {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let scheduler = ExpiryNotificationScheduler(center: .current(), defaults: defaults)
    XCTAssertTrue(await scheduler.isEnabled())
}

func testNotificationLedgerPersistsScheduledIdentifierAcrossInstances() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    NotificationLedger(defaults: defaults).replace(with: ["codex-reset-abc"])
    XCTAssertEqual(NotificationLedger(defaults: defaults).identifiers(), ["codex-reset-abc"])
}
```

Run:

```bash
swift test --filter ExpiryNotificationSchedulerTests
swift test
```

Expected: timing, skip, stable-ID tests and all previous tests pass.

- [ ] **Step 5: Commit notification planning**

```bash
git add Sources/CodexQuotaMenu/Notifications Tests/CodexQuotaMenuTests/ExpiryNotificationSchedulerTests.swift
git commit -m "feat: schedule reset credit expiry alerts"
```

---

### Task 7: Refresh Store, Stale Fallback, and Complete Menu UI

**Files:**
- Create: `Sources/CodexQuotaMenu/UI/QuotaStore.swift`
- Create: `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift`
- Modify: `Sources/CodexQuotaMenu/Services/QuotaReader.swift`
- Modify: `Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift`
- Create: `Tests/CodexQuotaMenuTests/QuotaStoreTests.swift`

**Interfaces:**
- Consumes: `QuotaReading`, `QuotaCaching`, `ExpiryNotificationReconciling`, `QuotaDisplayState`, and `MenuBarPresentation`.
- Produces: `QuotaStore.start()`, `QuotaStore.refresh() async`, `QuotaStore.stop() async`, observable UI properties, and a working read-only menu popover.

- [ ] **Step 1: Write failing store tests for cache-first loading, coalescing, and stale fallback**

Create `Tests/CodexQuotaMenuTests/QuotaStoreTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class QuotaStoreTests: XCTestCase {
    func testRefreshIntervalIsExactlyFiveMinutes() {
        XCTAssertEqual(QuotaStore.refreshIntervalSeconds, 300)
    }

    func testLoadsCacheThenRefreshesAndReconcilesNotifications() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let cached = Self.snapshot(fetchedAt: now.addingTimeInterval(-60), count: 2)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let cache = MemoryQuotaCache(snapshot: cached)
        let notifications = RecordingNotifications()
        let store = QuotaStore(reader: StubQuotaReader(result: .success(live)), cache: cache, notifications: notifications, now: { now })

        await store.loadCache()
        XCTAssertEqual(store.state, .fresh(cached))
        await store.refresh()
        XCTAssertEqual(store.state, .fresh(live))
        XCTAssertEqual(await notifications.snapshots, [live])
    }

    func testConcurrentRefreshesCoalesceToOneRead() async {
        let now = Date(timeIntervalSince1970: 2_000)
        let reader = CountingQuotaReader(snapshot: Self.snapshot(fetchedAt: now, count: 5))
        let store = QuotaStore(reader: reader, cache: MemoryQuotaCache(snapshot: nil), notifications: RecordingNotifications(), now: { now })
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        XCTAssertEqual(await reader.readCount, 1)
    }

    func testFailureMarksOldCacheStaleButRetainsValues() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let old = Self.snapshot(fetchedAt: now.addingTimeInterval(-1_800), count: 5)
        let store = QuotaStore(reader: StubQuotaReader(result: .failure(TestError.failed)), cache: MemoryQuotaCache(snapshot: old), notifications: RecordingNotifications(), now: { now })
        await store.loadCache()
        await store.refresh()
        guard case .stale(let snapshot, _) = store.state else { return XCTFail("Expected stale state") }
        XCTAssertEqual(snapshot.availableResetCount, 5)
    }

    func testNotificationSettingCanBeDisabledWithoutChangingQuotaState() async {
        let now = Date(timeIntervalSince1970: 5_000)
        let live = Self.snapshot(fetchedAt: now, count: 5)
        let notifications = RecordingNotifications()
        let store = QuotaStore(reader: StubQuotaReader(result: .success(live)), cache: MemoryQuotaCache(snapshot: live), notifications: notifications, now: { now })
        await store.loadCache()
        await store.setNotificationsEnabled(false)
        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertEqual(store.state, .fresh(live))
    }

    private static func snapshot(fetchedAt: Date, count: Int) -> QuotaSnapshot {
        QuotaSnapshot(windows: [QuotaWindow(id: "weekly", label: "每周额度", usedPercent: 53, durationMinutes: 10_080, resetsAt: nil)], availableResetCount: count, resetCredits: [], fetchedAt: fetchedAt)
    }
}

private enum TestError: Error { case failed }

private actor StubQuotaReader: QuotaReading {
    let result: Result<QuotaSnapshot, Error>
    init(result: Result<QuotaSnapshot, Error>) { self.result = result }
    func read() async throws -> QuotaSnapshot { try result.get() }
    func shutdown() async {}
}

private actor CountingQuotaReader: QuotaReading {
    let snapshot: QuotaSnapshot
    private(set) var readCount = 0
    init(snapshot: QuotaSnapshot) { self.snapshot = snapshot }
    func read() async throws -> QuotaSnapshot {
        readCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        return snapshot
    }
    func shutdown() async {}
}

private actor MemoryQuotaCache: QuotaCaching {
    var snapshot: QuotaSnapshot?
    init(snapshot: QuotaSnapshot?) { self.snapshot = snapshot }
    func load() async -> QuotaSnapshot? { snapshot }
    func save(_ snapshot: QuotaSnapshot) async throws { self.snapshot = snapshot }
}

private actor RecordingNotifications: ExpiryNotificationReconciling {
    private(set) var snapshots: [QuotaSnapshot] = []
    private var enabled = true
    func requestAuthorization() async {}
    func reconcile(snapshot: QuotaSnapshot, now: Date) async { snapshots.append(snapshot) }
    func setEnabled(_ enabled: Bool) async { self.enabled = enabled }
    func isEnabled() async -> Bool { enabled }
    func permissionState() async -> NotificationPermissionState { .authorized }
}
```

- [ ] **Step 2: Run store tests and verify `QuotaStore` is missing**

Run:

```bash
swift test --filter QuotaStoreTests
```

Expected: compilation fails because `QuotaStore` and the `shutdown()` reader contract do not exist.

- [ ] **Step 3: Extend the reader lifecycle and add a production reader**

Update `QuotaReading` in `QuotaReader.swift`:

```swift
protocol QuotaReading: Sendable {
    func read() async throws -> QuotaSnapshot
    func shutdown() async
}

extension LiveQuotaReader {
    func shutdown() async {}
}

actor ProductionQuotaReader: QuotaReading {
    private let locator: any CodexExecutableLocating
    private var client: CodexAppServerClient?

    init(locator: any CodexExecutableLocating = CodexExecutableLocator()) {
        self.locator = locator
    }

    func read() async throws -> QuotaSnapshot {
        if client == nil {
            let executable = try locator.locate()
            client = CodexAppServerClient(makeTransport: {
                ProcessJSONLineTransport(executableURL: executable, arguments: ["app-server", "--stdio"])
            })
        }
        return try await LiveQuotaReader(client: client!, now: Date.init).read()
    }

    func shutdown() async {
        await client?.stop()
        client = nil
    }
}
```

- [ ] **Step 4: Implement `QuotaStore` with exact refresh and stale rules**

Create `Sources/CodexQuotaMenu/UI/QuotaStore.swift`:

```swift
import AppKit
import Combine
import Foundation

@MainActor
final class QuotaStore: ObservableObject {
    static let refreshIntervalSeconds: TimeInterval = 300
    @Published private(set) var state: QuotaDisplayState = .loading
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var notificationsEnabled = true
    @Published private(set) var notificationPermission: NotificationPermissionState = .unknown

    private let reader: any QuotaReading
    private let cache: any QuotaCaching
    private let notifications: any ExpiryNotificationReconciling
    private let now: @Sendable () -> Date
    private var refreshTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private var terminationTask: Task<Void, Never>?

    init(
        reader: any QuotaReading,
        cache: any QuotaCaching,
        notifications: any ExpiryNotificationReconciling,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.reader = reader
        self.cache = cache
        self.notifications = notifications
        self.now = now
    }

    var menuTitle: String { MenuBarPresentation.title(for: state) }

    func setNotificationsEnabled(_ enabled: Bool) async {
        await notifications.setEnabled(enabled)
        notificationsEnabled = await notifications.isEnabled()
        notificationPermission = await notifications.permissionState()
        if notificationsEnabled, let snapshot = state.snapshot {
            await notifications.reconcile(snapshot: snapshot, now: now())
        }
    }

    func loadCache() async {
        guard let snapshot = await cache.load() else { return }
        state = snapshot.isStale(at: now()) ? .stale(snapshot, message: "缓存数据可能已过期") : .fresh(snapshot)
    }

    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer { self.isRefreshing = false }
            do {
                let snapshot = try await self.reader.read()
                try await self.cache.save(snapshot)
                await self.notifications.reconcile(snapshot: snapshot, now: self.now())
                self.state = .fresh(snapshot)
                self.lastErrorMessage = nil
            } catch {
                self.lastErrorMessage = error.localizedDescription
                if let snapshot = self.state.snapshot {
                    self.state = snapshot.isStale(at: self.now())
                        ? .stale(snapshot, message: error.localizedDescription)
                        : .fresh(snapshot)
                } else {
                    self.state = .unavailable(message: error.localizedDescription)
                }
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func start() {
        guard loopTask == nil else { return }
        terminationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification) {
                await self?.stop()
                break
            }
        }
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadCache()
            self.notificationsEnabled = await self.notifications.isEnabled()
            await self.notifications.requestAuthorization()
            self.notificationPermission = await self.notifications.permissionState()
            while !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(Self.refreshIntervalSeconds * 1_000_000_000))
            }
        }
    }

    func stop() async {
        loopTask?.cancel()
        loopTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        refreshTask?.cancel()
        await reader.shutdown()
    }
}
```

- [ ] **Step 5: Implement the complete read-only popover**

Create `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift` with this structure and exact user-visible states:

```swift
import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Codex 额度").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("刷新额度")
            }

            if let snapshot = store.state.snapshot {
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(window.label); Spacer(); Text("\(window.remainingPercent)%").bold() }
                        ProgressView(value: Double(window.remainingPercent), total: 100)
                        if let resetsAt = window.resetsAt {
                            Text("重置：\(resetsAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                HStack { Text("可用重置次数"); Spacer(); Text("\(snapshot.availableResetCount)").font(.title2).bold() }
                if let credits = snapshot.resetCredits {
                    ForEach(credits) { credit in
                        HStack {
                            Text(credit.title ?? "Full reset")
                            Spacer()
                            Text(credit.expiresAt?.formatted(date: .abbreviated, time: .shortened) ?? "不过期")
                                .foregroundStyle(isUrgent(credit) ? .orange : .secondary)
                        }.font(.caption)
                    }
                } else {
                    Text("到期详情暂不可用").font(.caption).foregroundStyle(.secondary)
                }

                Text("最后更新：\(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(store.lastErrorMessage ?? "正在读取额度…").foregroundStyle(.secondary)
                Button("重新检测") { Task { await store.refresh() } }
            }

            if case .stale(_, let message) = store.state {
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            } else if let message = store.lastErrorMessage {
                Text(message).foregroundStyle(.secondary).font(.caption)
            }

            Divider()
            HStack {
                Button("打开 ChatGPT") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/ChatGPT.app")) }
                Spacer()
                Button("退出") { Task { await store.stop(); NSApplication.shared.terminate(nil) } }
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private func isUrgent(_ credit: ResetCredit) -> Bool {
        guard let expiration = credit.expiresAt else { return false }
        return expiration.timeIntervalSinceNow <= 86_400
    }
}
```

Replace `CodexQuotaMenuApp.swift` with:

```swift
import SwiftUI

@main
@MainActor
struct CodexQuotaMenuApp: App {
    @StateObject private var store: QuotaStore

    init() {
        let store = QuotaStore(
            reader: ProductionQuotaReader(),
            cache: FileQuotaCache(),
            notifications: ExpiryNotificationScheduler()
        )
        _store = StateObject(wrappedValue: store)
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
        } label: {
            Label(store.menuTitle, systemImage: "gauge.with.dots.needle.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 6: Run store tests and build the full UI target**

Run:

```bash
swift test --filter QuotaStoreTests
swift test
swift build
```

Expected: cache-first, coalescing, stale fallback, all prior tests, and the complete SwiftUI executable build pass.

- [ ] **Step 7: Commit refresh orchestration and UI**

```bash
git add Sources/CodexQuotaMenu Tests/CodexQuotaMenuTests/QuotaStoreTests.swift
git commit -m "feat: add quota menu state and UI"
```

---

### Task 8: Launch-at-Login Setting and Permission Status

**Files:**
- Create: `Sources/CodexQuotaMenu/System/LaunchAtLoginController.swift`
- Modify: `Sources/CodexQuotaMenu/UI/MenuBarContentView.swift`
- Modify: `Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift`
- Create: `Tests/CodexQuotaMenuTests/LaunchAtLoginControllerTests.swift`

**Interfaces:**
- Consumes: SwiftUI app and menu content from Task 7.
- Produces: `LaunchAtLoginController.ensureDefaultEnabled()` and `setEnabled(_:)`, backed by `SMAppService.mainApp` and an explicit settings toggle.

- [ ] **Step 1: Write failing tests for first-run default and user override**

Create `Tests/CodexQuotaMenuTests/LaunchAtLoginControllerTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testFirstRunRegistersByDefaultOnlyOnce() {
        let service = FakeLoginItemService()
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = LaunchAtLoginController(service: service, defaults: defaults)
        controller.ensureDefaultEnabled()
        controller.ensureDefaultEnabled()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertTrue(controller.isEnabled)
    }

    func testUserCanDisableLaunchAtLogin() {
        let service = FakeLoginItemService(initial: .enabled)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let controller = LaunchAtLoginController(service: service, defaults: defaults)
        controller.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)
        XCTAssertFalse(controller.isEnabled)
    }
}

private final class FakeLoginItemService: LoginItemServicing {
    var state: LoginItemState
    var registerCount = 0
    var unregisterCount = 0
    init(initial: LoginItemState = .disabled) { state = initial }
    func register() throws { registerCount += 1; state = .enabled }
    func unregister() throws { unregisterCount += 1; state = .disabled }
}
```

- [ ] **Step 2: Run the tests and verify login-item types are missing**

Run:

```bash
swift test --filter LaunchAtLoginControllerTests
```

Expected: compilation fails because the controller and service boundary do not exist.

- [ ] **Step 3: Implement the ServiceManagement adapter and observable controller**

Create `Sources/CodexQuotaMenu/System/LaunchAtLoginController.swift`:

```swift
import Combine
import Foundation
import ServiceManagement

enum LoginItemState: Equatable { case enabled, disabled, requiresApproval, unavailable }

protocol LoginItemServicing: AnyObject {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

final class MainAppLoginItemService: LoginItemServicing {
    private let service = SMAppService.mainApp
    var state: LoginItemState {
        switch service.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled: Bool
    @Published private(set) var message: String?
    private let service: any LoginItemServicing
    private let defaults: UserDefaults
    private let configuredKey = "launchAtLoginConfigured"

    init(service: any LoginItemServicing = MainAppLoginItemService(), defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.isEnabled = service.state == .enabled
    }

    func ensureDefaultEnabled() {
        guard !defaults.bool(forKey: configuredKey) else { return }
        setEnabled(true)
        defaults.set(true, forKey: configuredKey)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            enabled ? try service.register() : try service.unregister()
            isEnabled = service.state == .enabled
            message = service.state == .requiresApproval ? "请在系统设置 → 通用 → 登录项中批准。" : nil
            defaults.set(true, forKey: configuredKey)
        } catch {
            isEnabled = service.state == .enabled
            message = error.localizedDescription
        }
    }
}
```

- [ ] **Step 4: Add the setting to the app and popover**

Replace `CodexQuotaMenuApp` with the following final dependency composition:

```swift
import SwiftUI

@main
@MainActor
struct CodexQuotaMenuApp: App {
    @StateObject private var store: QuotaStore
    @StateObject private var launchAtLogin: LaunchAtLoginController

    init() {
        let store = QuotaStore(
            reader: ProductionQuotaReader(),
            cache: FileQuotaCache(),
            notifications: ExpiryNotificationScheduler()
        )
        let launchAtLogin = LaunchAtLoginController()
        _store = StateObject(wrappedValue: store)
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
        launchAtLogin.ensureDefaultEnabled()
        store.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store, launchAtLogin: launchAtLogin)
        } label: {
            Label(store.menuTitle, systemImage: "gauge.with.dots.needle.50percent")
        }
        .menuBarExtraStyle(.window)
    }
}
```

Update the start of `MenuBarContentView` to include both observable objects:

```swift
struct MenuBarContentView: View {
    @ObservedObject var store: QuotaStore
    @ObservedObject var launchAtLogin: LaunchAtLoginController
```

Then add these exact settings rows above the final divider:

```swift
Toggle("登录时启动", isOn: Binding(
    get: { launchAtLogin.isEnabled },
    set: { launchAtLogin.setEnabled($0) }
))
Toggle("到期通知", isOn: Binding(
    get: { store.notificationsEnabled },
    set: { enabled in Task { await store.setNotificationsEnabled(enabled) } }
))
if store.notificationsEnabled && store.notificationPermission == .denied {
    Text("通知权限未启用；额度显示不受影响。")
        .font(.caption)
        .foregroundStyle(.orange)
}
if let message = launchAtLogin.message {
    Text(message).font(.caption).foregroundStyle(.orange)
}
```

The view initializer becomes `MenuBarContentView(store: QuotaStore, launchAtLogin: LaunchAtLoginController)`.

- [ ] **Step 5: Run tests and build**

Run:

```bash
swift test --filter LaunchAtLoginControllerTests
swift test
swift build
```

Expected: first-run registration, user disable, all existing tests, and app compilation pass.

- [ ] **Step 6: Commit launch-at-login support**

```bash
git add Sources/CodexQuotaMenu Tests/CodexQuotaMenuTests/LaunchAtLoginControllerTests.swift
git commit -m "feat: add launch at login setting"
```

---

### Task 9: Package, Verify, Install, and Run Against the Real Account

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`
- Create: `scripts/verify-app.sh`
- Create: `scripts/install-app.sh`
- Create: `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`
- Create: `Tests/CodexQuotaMenuTests/LiveCodexSmokeTests.swift`
- Create: `README.md`

**Interfaces:**
- Consumes: the complete SwiftPM executable and all app services from Tasks 1–8.
- Produces: `dist/Codex Quota Menu.app`, a verified ad-hoc signature, installation in `/Applications`, real quota display, launch-at-login registration, and documented removal steps.

- [ ] **Step 1: Write failing bundle-contract and gated live tests**

Create `Tests/CodexQuotaMenuTests/PackagingContractTests.swift`:

```swift
import XCTest

final class PackagingContractTests: XCTestCase {
    func testInfoPlistDeclaresMenuBarOnlyBundle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = root.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let object = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(object["CFBundleIdentifier"] as? String, "local.scott.CodexQuotaMenu")
        XCTAssertEqual(object["CFBundleExecutable"] as? String, "CodexQuotaMenu")
        XCTAssertEqual(object["LSUIElement"] as? Bool, true)
        XCTAssertEqual(object["LSMinimumSystemVersion"] as? String, "14.0")
    }
}
```

Create `Tests/CodexQuotaMenuTests/LiveCodexSmokeTests.swift`:

```swift
import XCTest
@testable import CodexQuotaMenu

final class LiveCodexSmokeTests: XCTestCase {
    func testRealReadReturnsAValidSnapshot() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_CODEX_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_LIVE_CODEX_TESTS=1 for the local account smoke test")
        }
        let reader = ProductionQuotaReader()
        let snapshot = try await reader.read()
        XCTAssertFalse(snapshot.windows.isEmpty)
        XCTAssertGreaterThanOrEqual(snapshot.availableResetCount, 0)
        XCTAssertTrue(snapshot.windows.allSatisfy { (0...100).contains($0.remainingPercent) })
        await reader.shutdown()
    }
}
```

- [ ] **Step 2: Run tests and confirm the missing plist fails the packaging test**

Run:

```bash
swift test --filter PackagingContractTests
```

Expected: test fails because `Resources/Info.plist` does not exist.

- [ ] **Step 3: Add the complete bundle metadata**

Create `Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>Codex Quota Menu</string>
  <key>CFBundleExecutable</key><string>CodexQuotaMenu</string>
  <key>CFBundleIdentifier</key><string>local.scott.CodexQuotaMenu</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Codex Quota Menu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

- [ ] **Step 4: Add deterministic build, verification, and installation scripts**

Create `scripts/build-app.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/Codex Quota Menu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CodexQuotaMenu" "$APP/Contents/MacOS/CodexQuotaMenu"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "$APP"
```

Create `scripts/verify-app.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Codex Quota Menu.app"
test -x "$APP/Contents/MacOS/CodexQuotaMenu"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "local.scott.CodexQuotaMenu"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP/Contents/Info.plist")" = "true"
codesign --verify --deep --strict "$APP"
if rg -n 'rateLimitResetCredit/consume' "$ROOT/Sources"; then
  echo "Read-only violation found" >&2
  exit 1
fi
echo "Verified: $APP"
```

Create `scripts/install-app.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/dist/Codex Quota Menu.app"
TARGET="/Applications/Codex Quota Menu.app"
test -d "$SOURCE"
ditto "$SOURCE" "$TARGET"
open "$TARGET"
echo "$TARGET"
```

Make the scripts executable with `chmod +x scripts/*.sh`.

- [ ] **Step 5: Add exact build, install, privacy, and uninstall documentation**

Create `README.md` with these commands and explanations:

````markdown
# Codex Quota Menu

Native read-only macOS menu-bar display for Codex quota windows and reset-credit expiration times.

## Build and test

```bash
swift test
./scripts/build-app.sh
./scripts/verify-app.sh
```

## Install

```bash
./scripts/install-app.sh
```

The app uses the Codex executable bundled in `/Applications/ChatGPT.app`, reuses its existing login, refreshes every five minutes, and never redeems a reset credit.

## Privacy

The app does not read browser cookies, ChatGPT credentials, Codex authentication files, or the Codex state database. It stores only the latest display snapshot and SHA-256 notification identifiers under `~/Library/Application Support/Codex Quota Menu`.

## Uninstall

Quit the menu app, disable “登录时启动”, move `/Applications/Codex Quota Menu.app` to Trash, and remove `~/Library/Application Support/Codex Quota Menu` if the cached display data is no longer wanted.
````

- [ ] **Step 6: Run all automated and live verification gates**

The live test must run with approval to use the real `~/.codex` state and account network connection; the normal unit suite remains sandboxed.

Run:

```bash
swift test
RUN_LIVE_CODEX_TESTS=1 swift test --filter LiveCodexSmokeTests
./scripts/build-app.sh
./scripts/verify-app.sh
```

Expected:

- All unit and packaging tests pass.
- The live test returns at least one quota window and a nonnegative reset count.
- `dist/Codex Quota Menu.app` exists, contains an executable, declares `LSUIElement=true`, passes ad-hoc signature verification, and contains no redemption method string in `Sources`.

- [ ] **Step 7: Install and verify the real macOS runtime**

Run `./scripts/install-app.sh` with permission to write `/Applications` and open a GUI app.

Expected manual checks:

1. The Dock has no Codex Quota Menu icon.
2. The menu bar shows the most constrained remaining percentage and the same `availableCount` returned by the live read.
3. The popover shows every returned quota window and reset-credit expiration in the current system time zone.
4. Manual refresh changes “最后更新”.
5. Denying notification permission does not break quota display.
6. Allowing notification permission creates pending requests only for available credits with expiration times.
7. “登录时启动” is enabled; after a fresh logout/login, the menu item returns automatically.
8. Quitting the app leaves no `codex app-server --stdio` child process belonging to Codex Quota Menu.

- [ ] **Step 8: Commit packaging, documentation, and live acceptance support**

```bash
git add Resources scripts Tests/CodexQuotaMenuTests README.md
git commit -m "build: package and verify Codex quota menu"
```

- [ ] **Step 9: Record final verification evidence**

Run:

```bash
git status --short
git log --oneline --decorate -10
```

Expected: the worktree is clean and the task commits appear in order, ending with `build: package and verify Codex quota menu`.

---
