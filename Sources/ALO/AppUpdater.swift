import AppKit
import CryptoKit
import Foundation
import Security
import ALOCore

@MainActor
final class AppUpdater {
    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let browserDownloadURL: URL
            let digest: String?
            let size: Int

            enum CodingKeys: String, CodingKey {
                case name, digest, size
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    enum UpdateError: LocalizedError {
        case invalidResponse, noCompatibleAsset, invalidDigest, invalidArchive
        case invalidSignature, notNewer, cannotInstallDevelopmentBuild, unsupportedArchitecture

        var errorDescription: String? {
            switch self {
            case .invalidResponse: return "GitHub returned an invalid update response."
            case .noCompatibleAsset: return "This release has no Apple Silicon app archive."
            case .invalidDigest: return "The download did not match GitHub's SHA-256 digest."
            case .invalidArchive: return "The downloaded update archive is invalid."
            case .invalidSignature: return "The update is not signed by ALO's expected Apple Developer team."
            case .notNewer: return "The downloaded app is not newer than this copy of ALO."
            case .cannotInstallDevelopmentBuild: return "Run a packaged ALO.app to install updates automatically."
            case .unsupportedArchitecture: return "Automatic updates are available only for the Apple Silicon release."
            }
        }
    }

    nonisolated static let repository = "theShyamsindhia/WERAI"
    nonisolated static let teamID = "R9QFK9NM3Y"
    nonisolated static let bundleID = "in.werai.audio"
    nonisolated static let developerIDRequirement = """
    anchor apple generic and identifier "in.werai.audio" \
    and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
    and certificate leaf[subject.OU] = "R9QFK9NM3Y"
    """
    nonisolated static var supportsAutomaticInstallation: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    var updateAvailableHandler: ((String) -> Void)?
    var updateAvailabilityHandler: ((String?) -> Void)?
    var messageHandler: ((String) -> Void)?
    private(set) var availableRelease: Release? {
        didSet {
            updateAvailabilityHandler?(availableRelease.flatMap { AppVersion($0.tagName)?.description })
        }
    }
    private var checkTimer: Timer?
    private var checkTask: Task<Void, Never>?
    private var lastPresentedVersion: String?
    private var lastAutomaticCheck: Date?

    var currentVersion: AppVersion {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(AppVersion.init) ?? AppVersion("0")!
    }

    func start() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdates(userInitiated: false) }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.checkForUpdates(userInitiated: false)
        }
    }

    func checkForUpdates(userInitiated: Bool) {
        if !userInitiated, let lastAutomaticCheck,
           Date().timeIntervalSince(lastAutomaticCheck) < 5 * 60 { return }
        if !userInitiated { lastAutomaticCheck = Date() }
        checkTask?.cancel()
        checkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await Self.fetchLatestRelease()
                guard !Task.isCancelled else { return }
                handleFetchedRelease(release, userInitiated: userInitiated)
            } catch is CancellationError {
            } catch {
                if userInitiated { messageHandler?("Could not check for updates: \(error.localizedDescription)") }
            }
        }
    }

    func handleFetchedRelease(_ release: Release, userInitiated: Bool) {
        guard let version = AppVersion(release.tagName), version > currentVersion else {
            availableRelease = nil
            if userInitiated { messageHandler?("ALO \(currentVersion) is up to date.") }
            return
        }
        // Availability remains visible even when the once-per-version alert
        // has already been dismissed with Later.
        availableRelease = release
        if userInitiated || lastPresentedVersion != version.description {
            lastPresentedVersion = version.description
            updateAvailableHandler?(version.description)
        }
    }

    func observePeerVersion(_ rawVersion: String) {
        guard let peerVersion = AppVersion(rawVersion), peerVersion > currentVersion else { return }
        checkForUpdates(userInitiated: false)
    }

    func installAvailableUpdate() {
        guard Self.supportsAutomaticInstallation else {
            messageHandler?(UpdateError.unsupportedArchitecture.localizedDescription)
            return
        }
        guard let release = availableRelease else {
            checkForUpdates(userInitiated: true)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let app = try await Self.downloadAndValidate(release, currentVersion: currentVersion)
                try Self.launchInstaller(for: app)
                NSApp.terminate(nil)
            } catch {
                messageHandler?("Could not install the update: \(error.localizedDescription)")
            }
        }
    }

    func openReleasePage() {
        let fallback = URL(string: "https://github.com/\(Self.repository)/releases/latest")!
        NSWorkspace.shared.open(availableRelease?.htmlURL ?? fallback)
    }

    nonisolated static func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ALO-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 2_000_000 else {
            throw UpdateError.invalidResponse
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    nonisolated static func downloadAndValidate(_ release: Release, currentVersion: AppVersion) async throws -> URL {
        guard supportsAutomaticInstallation else { throw UpdateError.unsupportedArchitecture }
        guard let releaseVersion = AppVersion(release.tagName), releaseVersion > currentVersion else {
            throw UpdateError.notNewer
        }
        guard let asset = release.assets.first(where: { $0.name == "ALO-macos-arm64.zip" }) else {
            throw UpdateError.noCompatibleAsset
        }
        guard asset.size > 0, asset.size <= 250_000_000 else { throw UpdateError.invalidArchive }
        let (downloaded, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.invalidResponse
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alo-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let archive = root.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: downloaded, to: archive)
        let actualSize = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard actualSize == asset.size else { throw UpdateError.invalidArchive }
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError.invalidDigest
        }
        let actual = SHA256.hash(data: try Data(contentsOf: archive))
            .map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(String(digest.dropFirst("sha256:".count))) == .orderedSame else {
            throw UpdateError.invalidDigest
        }
        let entries = try output("/usr/bin/zipinfo", ["-1", archive.path])
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let metadata = try output("/usr/bin/zipinfo", ["-l", archive.path])
        guard archiveEntriesAreSafe(entries),
              archiveMetadataIsSafe(metadata, expectedEntryCount: entries.count)
        else { throw UpdateError.invalidArchive }
        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
        let app = extracted.appendingPathComponent("ALO.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path),
              try extractedTreeIsSafe(extracted),
              let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID,
              let rawVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = AppVersion(rawVersion), version == releaseVersion, version > currentVersion
        else { throw UpdateError.invalidArchive }
        try validateSignature(app)
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=2", app.path])
        return app
    }

    nonisolated static func archiveEntriesAreSafe(_ entries: [String]) -> Bool {
        guard !entries.isEmpty, entries.count <= 10_000 else { return false }
        return entries.allSatisfy { entry in
            guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.contains("\\") else { return false }
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.contains(".."), !components.contains(".") else { return false }
            return entry == "ALO.app" || entry.hasPrefix("ALO.app/")
                || entry == "__MACOSX" || entry.hasPrefix("__MACOSX/")
        }
    }

    nonisolated static func archiveMetadataIsSafe(
        _ listing: String,
        expectedEntryCount: Int
    ) -> Bool {
        guard expectedEntryCount > 0, expectedEntryCount <= 10_000 else { return false }
        var entryCount = 0
        var totalBytes = 0
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(
                maxSplits: 9,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard let mode = fields.first, mode.count == 10 else { continue }
            let permissionCharacters = Set("rwxstST-@+")
            guard mode.dropFirst().allSatisfy(permissionCharacters.contains) else { continue }
            guard mode.first == "-" || mode.first == "d", fields.count == 10,
                  let uncompressedBytes = Int(fields[3]), uncompressedBytes >= 0
            else { return false }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(uncompressedBytes)
            guard !overflow, newTotal <= 500_000_000 else { return false }
            totalBytes = newTotal
            entryCount += 1
        }
        return entryCount == expectedEntryCount
    }

    nonisolated static func extractedTreeIsSafe(_ root: URL) throws -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return false }
        var totalBytes = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true { return false }
            if values.isRegularFile == true {
                totalBytes += values.fileSize ?? 0
                if totalBytes > 500_000_000 { return false }
            }
        }
        return true
    }

    nonisolated static func validateSignature(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.invalidSignature
        }
        var requirement: SecRequirement?
        let validationFlags = SecCSFlags(rawValue:
            kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        )
        guard SecRequirementCreateWithString(developerIDRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, validationFlags, requirement) == errSecSuccess
        else { throw UpdateError.invalidSignature }
    }

    nonisolated static func launchInstaller(for sourceApp: URL) throws {
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { throw UpdateError.cannotInstallDevelopmentBuild }
        let root = sourceApp.deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent("install-update.sh")
        let staged = target.deletingLastPathComponent().appendingPathComponent(".ALO-update-\(UUID().uuidString).app")
        let backup = target.deletingLastPathComponent().appendingPathComponent(".ALO-previous-\(UUID().uuidString).app")
        let log = root.appendingPathComponent("install.log")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/sh
        set -eu
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/ditto \(shellQuote(sourceApp.path)) \(shellQuote(staged.path))
        if [ -e \(shellQuote(target.path)) ]; then /bin/mv \(shellQuote(target.path)) \(shellQuote(backup.path)); fi
        if /bin/mv \(shellQuote(staged.path)) \(shellQuote(target.path)); then
          if /usr/bin/open \(shellQuote(target.path)); then
            /bin/rm -rf \(shellQuote(backup.path)) \(shellQuote(root.path))
          else
            /bin/rm -rf \(shellQuote(target.path))
            if [ -e \(shellQuote(backup.path)) ]; then /bin/mv \(shellQuote(backup.path)) \(shellQuote(target.path)); fi
            exit 1
          fi
        else
          if [ -e \(shellQuote(backup.path)) ]; then /bin/mv \(shellQuote(backup.path)) \(shellQuote(target.path)); fi
          exit 1
        fi
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        if FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = [helper.path]
            process.standardOutput = output
            process.standardError = output
            try process.run()
        } else {
            // Never execute a user-writable helper or install a previously validated
            // user-writable bundle as root. Copy into a root-owned directory and
            // revalidate that immutable copy before arranging the post-exit swap.
            let secureRoot = URL(
                fileURLWithPath: "/private/var/tmp/alo-update-\(UUID().uuidString)",
                isDirectory: true
            )
            let secureApp = secureRoot.appendingPathComponent("ALO.app", isDirectory: true)
            let secureLog = URL(fileURLWithPath: secureRoot.path + ".log")
            let postExit = """
            set -eu
            while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
            if [ -e \(shellQuote(target.path)) ]; then /bin/mv \(shellQuote(target.path)) \(shellQuote(backup.path)); fi
            if /bin/mv \(shellQuote(secureApp.path)) \(shellQuote(target.path)); then
              if /usr/bin/open \(shellQuote(target.path)); then
                /bin/rm -rf \(shellQuote(backup.path)) \(shellQuote(secureRoot.path)) \(shellQuote(root.path))
              else
                /bin/rm -rf \(shellQuote(target.path))
                if [ -e \(shellQuote(backup.path)) ]; then /bin/mv \(shellQuote(backup.path)) \(shellQuote(target.path)); fi
                exit 1
              fi
            else
              if [ -e \(shellQuote(backup.path)) ]; then /bin/mv \(shellQuote(backup.path)) \(shellQuote(target.path)); fi
              exit 1
            fi
            """
            let command = """
            set -eu
            umask 077
            /bin/mkdir \(shellQuote(secureRoot.path))
            trap '/bin/rm -rf \(secureRoot.path)' EXIT HUP INT TERM
            /usr/bin/ditto \(shellQuote(sourceApp.path)) \(shellQuote(secureApp.path))
            /usr/sbin/chown -R root:wheel \(shellQuote(secureRoot.path))
            /bin/chmod -R go-w \(shellQuote(secureRoot.path))
            /usr/bin/codesign --verify --deep --strict -R \(shellQuote("=" + developerIDRequirement)) \(shellQuote(secureApp.path))
            /usr/sbin/spctl --assess --type execute --verbose=2 \(shellQuote(secureApp.path))
            /usr/bin/nohup /bin/sh -c \(shellQuote(postExit)) >\(shellQuote(secureLog.path)) 2>&1 &
            trap - EXIT
            """
            let appleScript = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"
            try run("/usr/bin/osascript", ["-e", appleScript])
        }
    }

    private nonisolated static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let diagnostics = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: diagnostics, encoding: .utf8) ?? ""
            throw NSError(domain: "ALOUpdater", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private nonisolated static func output(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let combined = Pipe()
        process.standardOutput = combined
        process.standardError = combined
        try process.run()
        let data = combined.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ALOUpdater", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private nonisolated static func appleScriptEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
