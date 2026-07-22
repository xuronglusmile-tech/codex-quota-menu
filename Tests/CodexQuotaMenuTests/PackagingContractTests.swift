import Foundation
import Testing

@Suite
struct PackagingContractTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test
    func testMenuRendersIndependentMonthlyValueSectionWithoutRemovingControls() throws {
        let menuSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/UI/MenuBarContentView.swift"
            ),
            encoding: .utf8
        )
        let valueSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/UI/MonthlyUsageValueSection.swift"
            ),
            encoding: .utf8
        )

        #expect(menuSource.contains("MonthlyUsageValueSection(usage: monthlyUsage)"))
        #expect(menuSource.contains("本月使用数据暂不可用"))
        #expect(menuSource.contains("Sol API 假设场景暂不可用"))
        #expect(!menuSource.contains("本月 API 等价价值暂不可用"))
        #expect(valueSource.contains("Sol API 假设场景"))
        #expect(valueSource.contains("缓存较多情景"))
        #expect(valueSource.contains("输出较多情景"))
        #expect(valueSource.contains("固定构成：80/15/5 · 40/40/20"))
        #expect(valueSource.contains("GPT-5.6 Sol 标准 API 价格"))
        #expect(valueSource.contains("情景估算，并非实际账单或订阅价值"))
        #expect(valueSource.contains(#"Text("情景估算，并非实际账单或订阅价值")"#))
        #expect(!valueSource.contains("本月 API 等价价值"))
        #expect(!valueSource.contains("Plus $20"))
        #expect(!valueSource.contains("Pro $200"))
        #expect(!valueSource.contains("$250"))
        #expect(!valueSource.contains("statusText"))
        #expect(!valueSource.contains("plusFraction"))
        #expect(!valueSource.contains("proFraction"))
        #expect(menuSource.contains("可用重置次数"))
        #expect(menuSource.contains("登录时启动"))
        #expect(menuSource.contains("到期通知"))
        #expect(menuSource.contains("打开 ChatGPT"))
        #expect(menuSource.contains("退出"))
        #expect(menuSource.contains(".frame(width: 330)"))
    }

    @Test
    func testMenuBarUsesPercentageFirstQuotaPillAndNoGaugeSymbol() throws {
        let appSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift"
            ),
            encoding: .utf8
        )
        try #require(appSource.contains(
            "MenuBarQuotaLabel(presentation: store.menuPresentation)"
        ))
        #expect(!appSource.contains("gauge.with.dots.needle.50percent"))

        let labelSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/UI/MenuBarQuotaLabel.swift"
            ),
            encoding: .utf8
        )

        #expect(labelSource.contains("Text(presentation.text)"))
        #expect(labelSource.contains("MenuBarQuotaPill("))
        #expect(labelSource.contains("Color.green"))
        #expect(labelSource.contains("Color.yellow"))
        #expect(labelSource.contains("Color.red"))
        #expect(labelSource.contains("presentation.fillFraction"))
        #expect(labelSource.contains("presentation.accessibilityLabel"))
        #expect(!labelSource.contains("GeometryReader"))
        #expect(labelSource.contains("fillWidth * fillFraction"))

        let percentage = try #require(
            labelSource.range(of: "Text(presentation.text)")
        )
        let pill = try #require(
            labelSource.range(of: "MenuBarQuotaPill(")
        )
        #expect(percentage.lowerBound < pill.lowerBound)
    }

    @Test
    func testInfoPlistDeclaresCompleteMenuBarOnlyBundleContract() throws {
        let plist = root.appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let object = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        )

        #expect(Set(object.keys) == [
            "CFBundleDevelopmentRegion",
            "CFBundleDisplayName",
            "CFBundleExecutable",
            "CFBundleIdentifier",
            "CFBundleInfoDictionaryVersion",
            "CFBundleName",
            "CFBundlePackageType",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "LSMinimumSystemVersion",
            "LSUIElement",
            "NSHighResolutionCapable"
        ])
        #expect(object["CFBundleDevelopmentRegion"] as? String == "zh_CN")
        #expect(object["CFBundleDisplayName"] as? String == "Codex Quota Menu")
        #expect(object["CFBundleExecutable"] as? String == "CodexQuotaMenu")
        #expect(object["CFBundleIdentifier"] as? String == "local.scott.CodexQuotaMenu")
        #expect(object["CFBundleInfoDictionaryVersion"] as? String == "6.0")
        #expect(object["CFBundleName"] as? String == "Codex Quota Menu")
        #expect(object["CFBundlePackageType"] as? String == "APPL")
        #expect(object["CFBundleShortVersionString"] as? String == "0.1.0")
        #expect(object["CFBundleVersion"] as? String == "1")
        #expect(object["LSMinimumSystemVersion"] as? String == "14.0")
        #expect(object["LSUIElement"] as? Bool == true)
        #expect(object["NSHighResolutionCapable"] as? Bool == true)
    }

    @Test
    func testBuildScriptIsExecutableAndBuildsAReleaseBundleDeterministically() throws {
        let scriptURL = root.appendingPathComponent("scripts/build-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(try executablePermissions(of: scriptURL) == 0o755)
        #expect(script.contains(#"ROOT="$(cd "$(dirname "$0")/.." && pwd)""#))
        #expect(script.contains("CODEX_QUOTA_INTERFACE_COMPILER_VERSION:-6.3.2"))
        #expect(script.contains("--disable-sandbox"))
        #expect(script.contains("--cache-path"))
        #expect(script.contains("--config-path"))
        #expect(script.contains("--security-path"))
        #expect(script.contains("CLANG_MODULE_CACHE_PATH"))
        #expect(script.contains("SWIFTPM_MODULECACHE_OVERRIDE"))
        #expect(script.contains(#"APP="$ROOT/dist/Codex Quota Menu.app""#))
        #expect(script.contains(#"rm -rf "$APP""#))
        #expect(script.contains(#"cp "$BIN_DIR/CodexQuotaMenu" "$APP/Contents/MacOS/CodexQuotaMenu""#))
        #expect(script.contains(#"cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist""#))
        #expect(script.contains(#"codesign --force --sign - "$APP""#))
        #expect(!script.contains(#"codesign --force --sign - --identifier local.scott.CodexQuotaMenu "$BIN_DIR/CodexQuotaMenu""#))
        #expect(!script.contains("--deep"))

        let releaseBuild = try #require(script.range(of: "swift build -c release"))
        let showBinPath = try #require(script.range(of: "--show-bin-path"))
        let executableCopy = try #require(script.range(of: #"cp "$BIN_DIR/CodexQuotaMenu""#))
        let bundleSigning = try #require(script.range(of: #"codesign --force --sign - "$APP""#))
        #expect(releaseBuild.lowerBound < showBinPath.lowerBound)
        #expect(showBinPath.lowerBound < executableCopy.lowerBound)
        #expect(executableCopy.lowerBound < bundleSigning.lowerBound)
    }

    @Test
    func testVerifyScriptChecksBundleSignatureMetadataAndReadOnlyMethods() throws {
        let scriptURL = root.appendingPathComponent("scripts/verify-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        let auditScriptURL = root.appendingPathComponent("scripts/audit-outbound-methods.sh")
        let auditScript = try String(contentsOf: auditScriptURL, encoding: .utf8)

        #expect(try executablePermissions(of: scriptURL) == 0o755)
        #expect(try executablePermissions(of: auditScriptURL) == 0o755)
        for key in [
            "CFBundleDevelopmentRegion",
            "CFBundleDisplayName",
            "CFBundleExecutable",
            "CFBundleIdentifier",
            "CFBundleInfoDictionaryVersion",
            "CFBundleName",
            "CFBundlePackageType",
            "CFBundleShortVersionString",
            "CFBundleVersion",
            "LSMinimumSystemVersion",
            "LSUIElement",
            "NSHighResolutionCapable"
        ] {
            #expect(script.contains(key), "verify-app.sh must check \(key)")
        }
        #expect(script.contains("test -x"))
        #expect(script.contains("codesign --verify --strict"))
        #expect(script.contains("Signature=adhoc"))
        #expect(!script.contains("--deep"))
        #expect(script.contains(#"APP="${1:-$ROOT/dist/Codex Quota Menu.app}""#))
        #expect(script.contains(#""$ROOT/scripts/audit-outbound-methods.sh" "$ROOT/Sources""#))
        #expect(script.contains(#""$ROOT/scripts/test.sh" --filter CodexAppServerClientTests.testInitializesThenReadsAccountSnapshotUsingOnlyWhitelistedMethods"#))
        #expect(script.contains(#"cmp -s "$CURRENT_RELEASE_EXECUTABLE" "$EXECUTABLE""#))
        #expect(script.contains(#"REFERENCE_APP="$SUPPORT_DIR/verification-reference/Codex Quota Menu.app""#))
        #expect(script.contains(#"cp "$BIN_DIR/CodexQuotaMenu" "$REFERENCE_APP/Contents/MacOS/CodexQuotaMenu""#))
        #expect(script.contains(#"codesign --force --sign - "$REFERENCE_APP""#))

        let releaseBuild = try #require(script.range(of: "swift build -c release"))
        let byteComparison = try #require(script.range(of: #"cmp -s "$CURRENT_RELEASE_EXECUTABLE" "$EXECUTABLE""#))
        #expect(releaseBuild.lowerBound < byteComparison.lowerBound)

        #expect(auditScript.contains("AppServerMethod"))
        #expect(auditScript.contains("account/rateLimits/read"))
        #expect(auditScript.contains("account/usage/read"))
        #expect(auditScript.contains("consume|redeem|write"))
        #expect(auditScript.contains("find"))
        #expect(auditScript.contains("*.swift"))
        #expect(auditScript.contains("GLOBAL_SEND_REFERENCE_COUNT"))
        #expect(auditScript.contains("send call outside allowed client"))

        let clientSource = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift"
            ),
            encoding: .utf8
        )
        #expect(occurrenceCount(of: ".send(", in: clientSource) == 4)
        for method in ["initialize", "initialized", "rateLimitsRead", "usageRead"] {
            #expect(
                occurrenceCount(
                    of: "AppServerMethod.\(method).rawValue",
                    in: clientSource
                ) == 1,
                "each whitelisted method must appear in exactly one send payload"
            )
        }

        let enumBody = try #require(
            clientSource.range(
                of: "enum AppServerMethod: String, CaseIterable, Sendable {"
            )
        )
        let enumSuffix = clientSource[enumBody.upperBound...]
        let enumEnd = try #require(enumSuffix.range(of: "\n}"))
        let enumCases = enumSuffix[..<enumEnd.lowerBound]
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }
        #expect(enumCases == [
            "case initialize",
            "case initialized",
            "case rateLimitsRead = \"account/rateLimits/read\"",
            "case usageRead = \"account/usage/read\""
        ])
    }

    @Test
    func testGlobalOutboundAuditAcceptsClosedFixtureAndRejectsDynamicSendInAnotherSwiftFile() throws {
        let auditScriptURL = root.appendingPathComponent("scripts/audit-outbound-methods.sh")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureRoot = temporaryDirectory.appendingPathComponent("Sources", isDirectory: true)
        let clientDirectory = fixtureRoot.appendingPathComponent(
            "CodexQuotaMenu/Services",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: clientDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift"
            ),
            to: clientDirectory.appendingPathComponent("CodexAppServerClient.swift")
        )

        try run(executable: auditScriptURL.path, arguments: [fixtureRoot.path])

        let injectedSource = ##"""
        func injectedSend(transport: JSONLineTransport, runtimeMethod: String) async throws {
            try await transport.send(#"{"method":"\#(runtimeMethod)","params":{}}"#)
        }
        """##
        try Data(injectedSource.utf8).write(
            to: fixtureRoot.appendingPathComponent("InjectedDynamicSend.swift")
        )

        let rejected = try runCapturing(
            executable: auditScriptURL.path,
            arguments: [fixtureRoot.path]
        )
        #expect(rejected.status != 0)
        #expect(rejected.output.contains("send call outside allowed client"))
        #expect(rejected.output.contains("InjectedDynamicSend.swift"))
    }

    @Test
    func testGlobalOutboundAuditRejectsBoundSendReferenceInAnotherSwiftFile() throws {
        let auditScriptURL = root.appendingPathComponent("scripts/audit-outbound-methods.sh")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let fixtureRoot = temporaryDirectory.appendingPathComponent("Sources", isDirectory: true)
        let clientDirectory = fixtureRoot.appendingPathComponent(
            "CodexQuotaMenu/Services",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: clientDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/Services/CodexAppServerClient.swift"
            ),
            to: clientDirectory.appendingPathComponent("CodexAppServerClient.swift")
        )

        let injectedSource = """
        func injectedReference(
            transport: JSONLineTransport,
            dynamicPayload: String
        ) async throws {
            let emit: (String) async throws -> Void = transport.send
            try await emit(dynamicPayload)
        }
        """
        try Data(injectedSource.utf8).write(
            to: fixtureRoot.appendingPathComponent("InjectedSendReference.swift")
        )

        let rejected = try runCapturing(
            executable: auditScriptURL.path,
            arguments: [fixtureRoot.path]
        )
        #expect(rejected.status != 0)
        #expect(rejected.output.contains("send reference outside allowed client"))
        #expect(rejected.output.contains("InjectedSendReference.swift"))
    }

    @Test
    func testInstallScriptStagesVerifiesReplacesAndVerifiesWithoutSudo() throws {
        let scriptURL = root.appendingPathComponent("scripts/install-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(try executablePermissions(of: scriptURL) == 0o755)
        #expect(script.contains(#"SOURCE="$ROOT/dist/Codex Quota Menu.app""#))
        #expect(script.contains(#"TARGET="/Applications/Codex Quota Menu.app""#))
        #expect(script.contains("mktemp -d"))
        #expect(script.contains("trap cleanup EXIT"))
        #expect(script.contains("pgrep -x CodexQuotaMenu"))
        #expect(script.contains("Quit Codex Quota Menu and retry the install"))
        #expect(script.contains("xcrun --sdk macosx clang"))
        #expect(script.contains("-Werror"))
        #expect(script.contains("scripts/atomic-swap.c"))
        #expect(script.contains(#""$ROOT/scripts/verify-app.sh" "$STAGED""#))
        #expect(script.contains(#""$ROOT/scripts/verify-app.sh" "$TARGET""#))
        #expect(occurrenceCount(of: #""$SWAP_HELPER" "$STAGED" "$TARGET""#, in: script) == 2)
        #expect(script.contains(#"/bin/mv "$STAGED" "$TARGET""#))
        #expect(script.contains("Rollback failed; preserving recovery directory:"))
        #expect(script.contains("Previous app bundle remains at:"))
        #expect(script.contains("PRESERVE_STAGING"))
        #expect(script.contains(#"open -n "$TARGET""#))
        #expect(!script.contains(#"rm -rf "$TARGET""#))
        #expect(!script.contains("sudo"))

        let runningCheck = try #require(script.range(of: "pgrep -x CodexQuotaMenu"))
        let firstSwap = try #require(script.range(of: #""$SWAP_HELPER" "$STAGED" "$TARGET""#))
        let installedVerification = try #require(script.range(of: #""$ROOT/scripts/verify-app.sh" "$TARGET""#))
        let openNew = try #require(script.range(of: #"open -n "$TARGET""#))
        let completionOutput = try #require(script.range(of: #"echo "$TARGET""#))
        let commitState = try #require(script.range(of: #"STATE="committed""#))
        #expect(runningCheck.lowerBound < firstSwap.lowerBound)
        #expect(firstSwap.lowerBound < installedVerification.lowerBound)
        #expect(installedVerification.lowerBound < openNew.lowerBound)
        #expect(openNew.lowerBound < commitState.lowerBound)
        #expect(commitState.lowerBound < completionOutput.lowerBound)
    }

    @Test
    func testAtomicSwapHelperCompilesAndSwapsTwoDirectories() throws {
        let sourceURL = root.appendingPathComponent("scripts/atomic-swap.c")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        #expect(occurrenceCount(of: "renameatx_np", in: source) == 1)
        #expect(occurrenceCount(of: "RENAME_SWAP", in: source) == 1)

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        let helper = temporaryDirectory.appendingPathComponent("atomic-swap")
        try run(
            executable: "/usr/bin/xcrun",
            arguments: [
                "--sdk", "macosx", "clang",
                "-std=c11", "-Wall", "-Wextra", "-Werror",
                sourceURL.path, "-o", helper.path
            ]
        )

        let left = temporaryDirectory.appendingPathComponent("left", isDirectory: true)
        let right = temporaryDirectory.appendingPathComponent("right", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: false)
        try Data("left".utf8).write(to: left.appendingPathComponent("value"))
        try Data("right".utf8).write(to: right.appendingPathComponent("value"))

        try run(executable: helper.path, arguments: [left.path, right.path])

        #expect(try String(contentsOf: left.appendingPathComponent("value")) == "right")
        #expect(try String(contentsOf: right.appendingPathComponent("value")) == "left")
    }

    @Test
    func testTestWrapperEncapsulatesTheCompleteMixedCLTInvocation() throws {
        let scriptURL = root.appendingPathComponent("scripts/test.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(try executablePermissions(of: scriptURL) == 0o755)
        #expect(script.contains(#"ROOT="$(cd "$(dirname "$0")/.." && pwd)""#))
        #expect(script.contains("CODEX_QUOTA_INTERFACE_COMPILER_VERSION:-6.3.2"))
        #expect(script.contains("--disable-sandbox"))
        #expect(script.contains("--cache-path"))
        #expect(script.contains("--config-path"))
        #expect(script.contains("--security-path"))
        #expect(script.contains("--scratch-path"))
        #expect(script.contains("CLANG_MODULE_CACHE_PATH"))
        #expect(script.contains("SWIFTPM_MODULECACHE_OVERRIDE"))
        #expect(script.contains("-warnings-as-errors"))
        #expect(script.contains("CommandLineTools/Library/Developer/Frameworks"))
        #expect(script.contains("CommandLineTools/Library/Developer/usr/lib"))
        #expect(script.contains(#"swift test "${SWIFT_ARGS[@]}" "$@""#))
    }

    @Test
    func testApplicationDelegateGatesEveryTerminationPath() throws {
        let app = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/App/CodexQuotaMenuApp.swift"
            ),
            encoding: .utf8
        )
        let store = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/UI/QuotaStore.swift"
            ),
            encoding: .utf8
        )
        let menu = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/CodexQuotaMenu/UI/MenuBarContentView.swift"
            ),
            encoding: .utf8
        )

        #expect(app.contains("@NSApplicationDelegateAdaptor"))
        #expect(app.contains("applicationShouldTerminate"))
        #expect(app.contains("configureTermination"))
        #expect(!store.contains("NSApplication.willTerminateNotification"))
        #expect(menu.contains("NSApplication.shared.terminate(nil)"))
        #expect(!menu.contains("await store.stop()"))
    }

    @Test
    func testReadmeDocumentsBuildInstallPrivacyAndCompleteUninstall() throws {
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(readme.contains("./scripts/test.sh"))
        #expect(readme.contains("RUN_LIVE_CODEX_TESTS=1 ./scripts/test.sh --filter LiveCodexSmokeTests"))
        #expect(readme.contains("./scripts/build-app.sh"))
        #expect(readme.contains("./scripts/verify-app.sh"))
        #expect(readme.contains("./scripts/install-app.sh"))
        #expect(readme.contains("Quit Codex Quota Menu before installing or updating"))
        #expect(readme.contains("never redeems a reset credit"))
        #expect(readme.contains("does not read browser cookies"))
        #expect(readme.contains("ChatGPT credentials"))
        #expect(readme.contains("Codex authentication files"))
        #expect(readme.contains("Codex state database"))
        #expect(readme.contains("latest display snapshot"))
        #expect(readme.contains("SHA-256 notification identifiers"))
        #expect(readme.contains("standard UserDefaults domain"))
        #expect(readme.contains("local.scott.CodexQuotaMenu"))
        #expect(readme.contains("disable “到期通知”"))
        #expect(readme.contains("pending owned notification requests"))
        #expect(readme.contains("disable “登录时启动”"))
        #expect(readme.contains("/Applications/Codex Quota Menu.app"))
        #expect(readme.contains("~/Library/Application Support/Codex Quota Menu"))
        #expect(readme.contains("defaults delete local.scott.CodexQuotaMenu"))

        let disableNotifications = try #require(readme.range(of: "disable “到期通知”"))
        let disableLogin = try #require(readme.range(of: "disable “登录时启动”"))
        let quit = try #require(readme.range(of: "Quit the menu app", options: .backwards))
        let removeApp = try #require(readme.range(of: "move `/Applications/Codex Quota Menu.app`"))
        let removeCache = try #require(
            readme.range(of: "remove `~/Library/Application Support/Codex Quota Menu`")
        )
        let removeDefaults = try #require(
            readme.range(of: "defaults delete local.scott.CodexQuotaMenu")
        )
        #expect(disableNotifications.lowerBound < disableLogin.lowerBound)
        #expect(disableLogin.lowerBound < quit.lowerBound)
        #expect(quit.lowerBound < removeApp.lowerBound)
        #expect(removeApp.lowerBound < removeCache.lowerBound)
        #expect(removeCache.lowerBound < removeDefaults.lowerBound)
    }

    @Test
    func testLiveSmokeTestIsExplicitlyGatedAndCleanupSafe() throws {
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Tests/CodexQuotaMenuTests/LiveCodexSmokeTests.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("import Testing"))
        #expect(source.contains("RUN_LIVE_CODEX_TESTS"))
        #expect(source.contains(".enabled("))
        #expect(source.contains("if: ProcessInfo.processInfo.environment"))
        #expect(source.contains("catch"))
        #expect(source.components(separatedBy: "await reader.shutdown()").count - 1 == 2)
        #expect(source.contains("snapshot.windows.isEmpty"))
        #expect(source.contains("snapshot.availableResetCount >= 0"))
        #expect(source.contains("(0...100).contains"))
        #expect(source.contains("credit.id.count == 64"))
        #expect(source.contains("0123456789abcdef"))
    }

    private func executablePermissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func occurrenceCount(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func run(executable: String, arguments: [String]) throws {
        let result = try runCapturing(executable: executable, arguments: arguments)
        guard result.status == 0 else {
            throw PackagingProcessError.failed(
                command: ([executable] + arguments).joined(separator: " "),
                output: result.output
            )
        }
    }

    private func runCapturing(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }
}

private enum PackagingProcessError: Error {
    case failed(command: String, output: String)
}
