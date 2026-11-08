import Foundation
import SwiftUI

struct AppUpdate: Equatable {
    let build: Int
    let tag: String
    let downloadURL: URL
    var installURL: URL {
        var components = URLComponents()
        components.scheme = "sidestore"
        components.host = "install"
        components.queryItems = [URLQueryItem(name: "url", value: downloadURL.absoluteString)]
        return components.url!
    }
}

enum AppUpdatePolicy {
    static let endpoint = URL(string: "https://api.github.com/repos/R347H4CK3R/GhostAI/releases/latest")!
    struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    struct Asset: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int
    }
    enum Failure: Error { case invalidRelease, invalidInstalledBuild, oversized, badResponse }
    static func candidate(_ data: Data, installedBuild: String) throws -> AppUpdate? {
        guard let current = Int(installedBuild), current > 0 else { throw Failure.invalidInstalledBuild }
        guard data.count <= 262_144 else { throw Failure.oversized }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let prefix = "ios-build-"
        guard !release.draft, !release.prerelease, release.tag_name.hasPrefix(prefix) else {
            throw Failure.invalidRelease
        }
        let suffix = String(release.tag_name.dropFirst(prefix.count))
        guard let build = Int(suffix), build > 0, String(build) == suffix else { throw Failure.invalidRelease }
        let expected = "https://github.com/R347H4CK3R/GhostAI/releases/download/\(release.tag_name)/AsterionVeyra-unsigned.ipa"
        let matching = release.assets.filter { $0.name == "AsterionVeyra-unsigned.ipa" }
        guard matching.count == 1, let asset = matching.first,
              asset.browser_download_url == expected, asset.size > 0,
              asset.size <= 536_870_912, let url = URL(string: expected) else { throw Failure.invalidRelease }
        return build > current ? AppUpdate(build: build, tag: release.tag_name, downloadURL: url) : nil
    }
}

private final class UpdateRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class AppUpdateController: ObservableObject {
    @Published private(set) var checking = false
    @Published private(set) var candidate: AppUpdate?
    @Published private(set) var status = "Check for a published iPhone update."
    func check() async {
        guard !checking else { return }
        checking = true
        candidate = nil
        status = "Checking for updates…"
        defer { checking = false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: UpdateRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: AppUpdatePolicy.endpoint)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("AsterionVeyra-UpdateCheck", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.url == AppUpdatePolicy.endpoint else {
                throw AppUpdatePolicy.Failure.badResponse
            }
            if http.statusCode == 404 {
                status = "No published update is available yet."
                return
            }
            guard http.statusCode == 200 else { throw AppUpdatePolicy.Failure.badResponse }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 262_144 else { throw AppUpdatePolicy.Failure.oversized }
                data.append(byte)
            }
            try Task.checkCancellation()
            let installed = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
            candidate = try AppUpdatePolicy.candidate(data, installedBuild: installed)
            status = candidate.map { "Build \($0.build) is available." } ?? "No newer published build is available."
        } catch {
            candidate = nil
            status = Task.isCancelled ? "Update check cancelled." :
                "Could not check for updates. Check your connection and try again."
        }
    }
}

struct AppUpdatesView: View {
    @StateObject private var controller = AppUpdateController()
    @State private var checkTask: Task<Void, Never>?
    @State private var confirmInstall = false
    @State private var openFailed = false
    @Environment(\.openURL) private var openURL
    private var installed: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (build \(info["CFBundleVersion"] as? String ?? "?"))"
    }
    var body: some View {
        List {
            Section("Installed version") { Text(installed) }
            Section("Updates") {
                Text(controller.status).accessibilityIdentifier("updates.status")
                Button(controller.checking ? "Checking…" : "Check for updates") {
                    checkTask = Task { await controller.check() }
                }.disabled(controller.checking).accessibilityIdentifier("updates.check")
                if let update = controller.candidate {
                    Button("Update to build \(update.build) with SideStore") { confirmInstall = true }
                        .accessibilityIdentifier("updates.install")
                }
            }
            Section("Install with SideStore") {
                Text("SideStore signs and installs the update after you approve it. Keep the existing app installed and use the same SideStore signing account to retain its data.")
                Text("Export important chats and notes from Memory before updating. Updates need internet; your existing app remains usable when an update check fails.")
                Text("Checking contacts GitHub for public release information. It does not send chats, memories, API keys or repository credentials.")
            }
        }
        .navigationTitle("App updates")
        .onDisappear { checkTask?.cancel() }
        .alert("Open SideStore to update?", isPresented: $confirmInstall) {
            Button("Open SideStore") {
                if let candidate = controller.candidate {
                    openURL(candidate.installURL) { accepted in openFailed = !accepted }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SideStore will download and sign the published IPA. Do not delete the current app. Opening SideStore does not confirm that installation succeeded.")
        }
        .alert("Could not open SideStore", isPresented: $openFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Make sure SideStore is installed. You can also download the published IPA from the GhostAI GitHub Releases page and import it into SideStore.")
        }
    }
}
