import AppKit

/// The running build's version, read from the bundle Info.plist that
/// `make-app.sh` bakes from `./VERSION`. A non-bundle run (e.g. `--check` from
/// `.build`) has no Info.plist, so it reports "dev" and skips update checks.
enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// The repo checkout PitStop was built from (baked in by make-app.sh) —
    /// enables the rebuild-from-source update. nil for relocated/downloaded
    /// installs, which fall back to opening the release page.
    static var sourcePath: String? {
        (Bundle.main.object(forInfoDictionaryKey: "PitStopSourcePath") as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "v1.2.3" / "1.2.3-beta" → [1, 2, 3] (pre-release suffix dropped).
    static func components(_ s: String) -> [Int] {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        let core = trimmed.split(separator: "-").first.map(String.init) ?? trimmed
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// True when `remote` is a strictly higher version than `local`.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = components(remote), l = components(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

/// Checks GitHub Releases for a newer build and, for source installs, can pull
/// + rebuild + relaunch in place. No code signing / notarization involved — it
/// re-runs the same `make-app.sh` the user installed with.
enum Updater {
    static let repoSlug = "Livin21/pitstop"

    struct UpdateInfo: Equatable {
        var version: String   // display form, "v" stripped (e.g. "0.3.0")
        var url: URL          // the release page
        var canRebuild: Bool  // a usable source checkout is recorded
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Return info when GitHub's latest release is newer than this build; nil
    /// when up to date, no release exists yet (404), the build is unversioned,
    /// or the network is unreachable. Best-effort and silent on failure.
    static func checkForUpdate() async -> UpdateInfo? {
        let local = AppVersion.current
        guard local != "dev" else { return nil }
        guard let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("PitStop", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              AppVersion.isNewer(tag, than: local) else {
            return nil
        }
        let page = (root["html_url"] as? String).flatMap(URL.init)
            ?? URL(string: "https://github.com/\(repoSlug)/releases/latest")!
        let display = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return UpdateInfo(version: display, url: page, canRebuild: sourceRepoValid())
    }

    /// The baked source path is a real git checkout with the installer script.
    static func sourceRepoValid() -> Bool {
        guard let path = AppVersion.sourcePath else { return false }
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "/.git")
            && fm.fileExists(atPath: path + "/scripts/make-app.sh")
    }

    /// Pull the latest source and re-run make-app.sh (off the main actor — the
    /// build takes seconds). Throws with the failing step's output.
    static func rebuildFromSource() async throws {
        guard let path = AppVersion.sourcePath else {
            throw Failure(message: "No source checkout is recorded for this install.")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try run("/usr/bin/git", ["-C", path, "pull", "--ff-only"])
                    try run("/bin/zsh", [path + "/scripts/make-app.sh"])
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Relaunch the freshly-installed app: a detached helper waits for this
    /// process to exit, then reopens it (so there's never two instances).
    static func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done; "
            + "open \"/Applications/PitStop.app\""]
        try? helper.run()
        NSApp.terminate(nil)
    }

    static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        // GUI-launched apps inherit a bare PATH; make-app.sh needs swift/codesign.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        // Drain both pipes concurrently: a sequential read-to-end deadlocks
        // when the child fills the other pipe's buffer (e.g. swift build
        // warnings on stderr) and blocks in write() before closing stdout.
        var out = Data(), err = Data()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            out = outPipe.fileHandleForReading.readDataToEndOfFile(); drained.leave()
        }
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            err = errPipe.fileHandleForReading.readDataToEndOfFile(); drained.leave()
        }
        p.waitUntilExit()
        drained.wait()
        guard p.terminationStatus == 0 else {
            let combined = ((String(data: err, encoding: .utf8) ?? "")
                + (String(data: out, encoding: .utf8) ?? ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(combined.suffix(300))
            throw Failure(message: "\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(tail)")
        }
    }
}
