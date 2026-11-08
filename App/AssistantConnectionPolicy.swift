import Foundation
import Network

/// A path is a routing hint, not proof that any remote service is reachable.
enum AssistantNetworkPath: Equatable, Sendable { case unknown, available, unavailable }

enum AssistantConnectionState: Equatable, Sendable {
    case setupRequired, ready, checking, online, offline, serviceUnavailable
    case authenticationRequired, accessDenied, rateLimited, failed

    var usesSavedOnlyFallback: Bool { self == .offline || self == .serviceUnavailable }
    var label: String {
        switch self {
        case .setupRequired: return "Select a repository in Projects for live GitHub access"
        case .ready: return "Live GitHub ready · checked when you ask"
        case .checking: return "Checking selected GitHub repository…"
        case .online: return "Online · selected GitHub repository reached"
        case .offline: return "Offline fallback · connection unavailable"
        case .serviceUnavailable: return "GitHub service unavailable · saved-context fallback"
        case .authenticationRequired: return "GitHub session ended · reconnect in Projects"
        case .accessDenied: return "GitHub access denied · check repository permissions"
        case .rateLimited: return "GitHub rate limit reached · try later"
        case .failed: return "Live GitHub read failed · not an offline connection diagnosis"
        }
    }
    var shortLabel: String {
        switch self {
        case .setupRequired: return "GitHub not selected"
        case .ready: return "Live GitHub ready"
        case .checking: return "Checking GitHub"
        case .online: return "GitHub online"
        case .offline: return "Offline fallback"
        case .serviceUnavailable: return "GitHub unavailable"
        case .authenticationRequired: return "Reconnect GitHub"
        case .accessDenied: return "GitHub access denied"
        case .rateLimited: return "GitHub rate limited"
        case .failed: return "GitHub read failed"
        }
    }
    var symbol: String {
        switch self {
        case .online: return "network"
        case .offline, .serviceUnavailable: return "wifi.slash"
        case .setupRequired, .authenticationRequired: return "link.badge.plus"
        case .accessDenied, .rateLimited, .failed: return "exclamationmark.triangle"
        case .checking, .ready: return "network"
        }
    }
    func responseSource(usedLiveReference: Bool) -> String {
        if usesSavedOnlyFallback && usedLiveReference {
            return "Apple on device · Partial live reference; connection/service interrupted"
        }
        return responseSource
    }
    var responseSource: String {
        switch self {
        case .online: return "Apple on device · Live GitHub reference"
        case .offline: return "Apple on device · Saved context; connection unavailable"
        case .serviceUnavailable: return "Apple on device · Saved context; GitHub service unavailable"
        case .setupRequired, .ready, .checking: return "Apple on device · No live source used"
        default: return "Apple on device · Live access incomplete"
        }
    }
}

enum AssistantConnectionPolicy {
    static func initial(path: AssistantNetworkPath, hasRepository: Bool) -> AssistantConnectionState {
        if path == .unavailable { return .offline }
        return hasRepository ? .ready : .setupRequired
    }
    static func failure(_ error: Error) -> AssistantConnectionState {
        guard let failure = error as? GitHubAccessError else { return .failed }
        switch failure {
        case .unavailable: return .offline
        case .serviceUnavailable: return .serviceUnavailable
        case .expired: return .authenticationRequired
        case .accessDenied: return .accessDenied
        case .rateLimited: return .rateLimited
        default: return .failed
        }
    }
    static func isUnavailable(_ error: URLError) -> Bool {
        // Security, cancellation, malformed payload and provider rejection are not no-service states.
        [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
         .dnsLookupFailed, .timedOut].contains(error.code)
    }
    static func scopeInstruction(repository: String?, state: AssistantConnectionState) -> String {
        if state.usesSavedOnlyFallback {
            return "Live connection/service unavailable for this question. Use saved context only, label it potentially stale, and do not claim current online access."
        }
        guard repository != nil else {
            return "No live repository has been selected. This is a setup/scope limitation, not evidence of no internet. For GitHub work, ask the user to connect/select a repository in Projects. Do not ask them to copy a repository list into offline memory."
        }
        return "Prefer the selected live GitHub tools for current repository evidence. They are read-only and scoped to this one pinned commit, not every repository. Saved references are secondary and may be stale."
    }
}

protocol AssistantNetworkMonitoring: AnyObject {
    func start(_ receive: @escaping @Sendable (AssistantNetworkPath) -> Void)
    func cancel()
}

final class AssistantNetworkMonitor: AssistantNetworkMonitoring {
    private let monitor = NWPathMonitor()
    func start(_ receive: @escaping @Sendable (AssistantNetworkPath) -> Void) {
        monitor.pathUpdateHandler = { path in
            switch path.status {
            case .satisfied: receive(.available)
            case .unsatisfied: receive(.unavailable)
            default: receive(.unknown)
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.asterionveyra.connection-path"))
    }
    func cancel() { monitor.cancel() }
    deinit { monitor.cancel() }
}
