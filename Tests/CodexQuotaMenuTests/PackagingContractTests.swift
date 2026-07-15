import Foundation
import Testing

@Suite
struct PackagingContractTests {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

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
        #expect(!script.contains("--deep"))

        let releaseBuild = try #require(script.range(of: "swift build -c release"))
        let showBinPath = try #require(script.range(of: "--show-bin-path"))
        #expect(releaseBuild.lowerBound < showBinPath.lowerBound)
    }

    @Test
    func testVerifyScriptChecksBundleSignatureMetadataAndReadOnlyMethods() throws {
        let scriptURL = root.appendingPathComponent("scripts/verify-app.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        #expect(try executablePermissions(of: scriptURL) == 0o755)
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
        #expect(script.contains("AppServerMethod"))
        #expect(script.contains("account/rateLimits/read"))
        #expect(script.contains("consume|redeem|write"))
        #expect(script.contains(#"APP="${1:-$ROOT/dist/Codex Quota Menu.app}""#))
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
        #expect(script.contains(#""$ROOT/scripts/verify-app.sh" "$STAGED""#))
        #expect(script.contains(#""$ROOT/scripts/verify-app.sh" "$TARGET""#))
        #expect(script.contains(#"open "$TARGET""#))
        #expect(!script.contains("sudo"))
    }

    @Test
    func testReadmeDocumentsBuildInstallPrivacyAndCompleteUninstall() throws {
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        #expect(readme.contains("swift test"))
        #expect(readme.contains("./scripts/build-app.sh"))
        #expect(readme.contains("./scripts/verify-app.sh"))
        #expect(readme.contains("./scripts/install-app.sh"))
        #expect(readme.contains("never redeems a reset credit"))
        #expect(readme.contains("does not read browser cookies"))
        #expect(readme.contains("ChatGPT credentials"))
        #expect(readme.contains("Codex authentication files"))
        #expect(readme.contains("Codex state database"))
        #expect(readme.contains("SHA-256 notification identifiers"))
        #expect(readme.contains("disable “登录时启动”"))
        #expect(readme.contains("/Applications/Codex Quota Menu.app"))
        #expect(readme.contains("~/Library/Application Support/Codex Quota Menu"))
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
}
