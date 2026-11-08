import Foundation

/// This catalog is compiled into the app. It does not load or execute plugin code.
protocol IntegrationAdapter {
    static var descriptor: IntegrationDescriptor { get }
}

struct IntegrationVersion: Equatable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    var description: String { "\(major).\(minor).\(patch)" }
}

enum IntegrationAccess: String, Codable, Sendable { case read, send, write }
enum IntegrationConsent: String, Sendable {
    case userStartedRead, explicitUserAction, reviewEachRequest, reviewEachWrite
    var needsReview: Bool { self == .reviewEachRequest || self == .reviewEachWrite }
    var label: String {
        switch self {
        case .userStartedRead: return "User-selected read scope"
        case .explicitUserAction: return "Explicit user action"
        case .reviewEachRequest: return "Review every outgoing request"
        case .reviewEachWrite: return "Review the exact change and destination"
        }
    }
}

enum IntegrationDataScope: String, Codable, CaseIterable, Sendable {
    case question, projectNotes, selectedSource, recentConversation, cachedKnowledge
    case repositoryIdentity, repositoryPath, pinnedRevision, optionalReadCredential
    case explicitContext, modelIdentifier, hostedCredential
    case reviewedReplacement, proposalMetadata, writeCredential
    var label: String {
        switch self {
        case .question: return "Question"
        case .projectNotes: return "Selected project's notes"
        case .selectedSource: return "Selected source excerpt"
        case .recentConversation: return "Bounded conversation context"
        case .cachedKnowledge: return "Selected workspace offline knowledge excerpts"
        case .repositoryIdentity: return "Selected repository"
        case .repositoryPath: return "Requested file or directory path"
        case .pinnedRevision: return "Pinned commit and object IDs"
        case .optionalReadCredential: return "Read credential, if connected"
        case .explicitContext: return "Context explicitly entered in Hosted"
        case .modelIdentifier: return "Chosen model ID"
        case .hostedCredential: return "Session API credential"
        case .reviewedReplacement: return "Reviewed replacement source"
        case .proposalMetadata: return "Reviewed branch and draft PR details"
        case .writeCredential: return "Separate write credential"
        }
    }
}

/// No custom URL, wildcard host, redirect recipient, OAuth issuer or inherited connector.
enum IntegrationRecipient: String, Codable, Sendable {
    case onDevice, githubAPI, openAIResponses
    var requiresNetwork: Bool { self != .onDevice }
    var label: String {
        switch self {
        case .onDevice: return "This device only"
        case .githubAPI: return "GitHub · https://api.github.com:443"
        case .openAIResponses: return "OpenAI · https://api.openai.com:443/v1/responses"
        }
    }
}

enum IntegrationResourceKind: Equatable, Sendable { case project, repository, hostedRequest, proposal }

/// Values come from trusted app selection or an immutable review, never model permissions.
/// These identifiers are deliberately omitted from descriptions and diagnostics.
enum IntegrationResource: Equatable, Sendable {
    case project(String)
    case repository(name: String, commit: String, path: String)
    case hostedRequest(UUID)
    case proposal(name: String, commit: String, path: String, reviewID: UUID)

    fileprivate var kind: IntegrationResourceKind {
        switch self {
        case .project: return .project
        case .repository: return .repository
        case .hostedRequest: return .hostedRequest
        case .proposal: return .proposal
        }
    }
    fileprivate func validate(allowRoot: Bool) throws {
        switch self {
        case .project(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 200, !name.contains("*"), MemorySearch.canSave(name),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw IntegrationFailure.invalidResource
            }
        case .repository(let name, let commit, let path), .proposal(let name, let commit, let path, _):
            guard !name.contains("*"), !path.contains("*"),
                  (try? GitHubRoute.repository(name)) != nil, MemorySearch.canSave(name),
                  RepositoryToolPolicy.isObjectSHA(commit),
                  (try? RepositoryToolPolicy.validatePath(path, allowRoot: allowRoot)) != nil,
                  !RepositoryToolPolicy.isLikelyCredentialPath(path) else {
                throw IntegrationFailure.invalidResource
            }
        case .hostedRequest: break
        }
    }
}

struct IntegrationOperationDescriptor: Identifiable, Sendable {
    let id: String
    let name: String
    let access: IntegrationAccess
    let resourceKind: IntegrationResourceKind
    let recipient: IntegrationRecipient
    let dataScopes: Set<IntegrationDataScope>
    let consent: IntegrationConsent
    let modelCallable: Bool
    let allowsRootPath: Bool

    init(id: String, name: String, access: IntegrationAccess, resourceKind: IntegrationResourceKind,
         recipient: IntegrationRecipient, dataScopes: Set<IntegrationDataScope>, consent: IntegrationConsent,
         modelCallable: Bool = false, allowsRootPath: Bool = false) {
        self.id = id; self.name = name; self.access = access; self.resourceKind = resourceKind
        self.recipient = recipient; self.dataScopes = dataScopes; self.consent = consent
        self.modelCallable = modelCallable; self.allowsRootPath = allowsRootPath
    }
}

struct IntegrationDescriptor: Identifiable, Sendable {
    let id: String
    let version: IntegrationVersion
    let name: String
    let summary: String
    let symbol: String
    let setup: String
    let dataDisclosure: String
    let operations: [IntegrationOperationDescriptor]
    var requiresNetwork: Bool { operations.contains { $0.recipient.requiresNetwork } }
}

enum IntegrationNetworkStatus: Equatable, Sendable { case unknown, online, offline }

/// Supplied by app-owned state. Creating or inspecting a snapshot never probes a network,
/// opens a Keychain item, signs in, or checks a third-party account.
struct IntegrationRuntimeSnapshot: Sendable {
    let network: IntegrationNetworkStatus
    let localModelAvailable: Bool?
    let memoryAvailable: Bool?
    let hostedSessionConfigured: Bool
    let proposalSessionConfigured: Bool
    init(network: IntegrationNetworkStatus = .unknown, localModelAvailable: Bool? = nil,
         memoryAvailable: Bool? = nil, hostedSessionConfigured: Bool = false,
         proposalSessionConfigured: Bool = false) {
        self.network = network; self.localModelAvailable = localModelAvailable
        self.memoryAvailable = memoryAvailable; self.hostedSessionConfigured = hostedSessionConfigured
        self.proposalSessionConfigured = proposalSessionConfigured
    }
}

enum IntegrationAvailability: String, Codable, Sendable {
    case available, configured, setupRequired, offlineUnavailable, deviceUnavailable
    var label: String {
        switch self {
        case .available: return "Available in current app state"
        case .configured: return "Bundled · availability not verified"
        case .setupRequired: return "Setup required in its screen"
        case .offlineUnavailable: return "Unavailable offline"
        case .deviceUnavailable: return "Unavailable on this device"
        }
    }
}

enum IntegrationInitiator: Equatable { case user, model }

struct IntegrationInvocation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let integrationID: String
    let operationID: String
    let resource: IntegrationResource
    let recipient: IntegrationRecipient
    let dataScopes: Set<IntegrationDataScope>
    var description: String { "IntegrationInvocation(scope redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["scope": "redacted"]) }
}

/// Immutable, memory-only policy grant. It is not a credential, executable capability or
/// replacement for a provider's live authorization and single-use review checks.
struct IntegrationGrant: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    fileprivate let registryID: UUID
    fileprivate let invocation: IntegrationInvocation
    fileprivate init(registryID: UUID, invocation: IntegrationInvocation) {
        self.registryID = registryID; self.invocation = invocation
    }
    var description: String { "IntegrationGrant(scope redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["scope": "redacted"]) }
}

struct IntegrationRedactedMetadata: Codable, Equatable {
    let integrationID: String
    let version: String
    let operationCount: Int
    let availability: IntegrationAvailability
    // No resource identifiers, endpoint arguments, payloads, account IDs or credentials.
}

enum IntegrationFailure: Error, Equatable, LocalizedError {
    case invalidDescriptor, duplicateIntegration, duplicateOperation, unknownIntegration, unknownOperation
    case missingGrant, modelPermissionChange, modelOperationDenied, scopeMismatch, invalidResource
    case recipientMismatch, dataScopeMismatch, reviewRequired, offline, networkUnverified, setupRequired, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidDescriptor, .duplicateIntegration, .duplicateOperation: return "The bundled integration catalog is invalid. No adapter was executed."
        case .unknownIntegration, .unknownOperation: return "This operation is not registered in this app."
        case .missingGrant: return "Select and approve the exact operation before using it."
        case .modelPermissionChange: return "A model cannot create or expand integration permissions."
        case .modelOperationDenied: return "This operation requires the user-operated review screen."
        case .scopeMismatch: return "The request does not match the original approved scope."
        case .invalidResource: return "Select a valid exact project, pinned repository path or review. Wildcards are not allowed."
        case .recipientMismatch: return "The recipient does not match the bundled adapter."
        case .dataScopeMismatch: return "The declared data does not match the adapter's requirements."
        case .reviewRequired: return "Review this exact request and destination before approving."
        case .offline: return "This integration needs a network connection. Saved local memory remains separate."
        case .networkUnverified: return "Network availability has not been verified. No operation was executed."
        case .setupRequired: return "Finish setup in the integration's own screen first."
        case .unavailable: return "The integration is not currently available."
        }
    }
}

/// Policy validation only: no executor, network client, storage mutation, credential input,
/// downloaded manifest, model tool registration or default grants exist here.
struct IntegrationRegistry {
    let descriptors: [IntegrationDescriptor]
    private let registryID = UUID()

    init(descriptors: [IntegrationDescriptor]) throws {
        var ids = Set<String>()
        for descriptor in descriptors {
            guard ids.insert(descriptor.id).inserted else { throw IntegrationFailure.duplicateIntegration }
            guard Self.validID(descriptor.id), descriptor.version.major >= 0,
                  descriptor.version.minor >= 0, descriptor.version.patch >= 0,
                  !descriptor.operations.isEmpty else { throw IntegrationFailure.invalidDescriptor }
            var operationIDs = Set<String>()
            for operation in descriptor.operations {
                guard operationIDs.insert(operation.id).inserted else { throw IntegrationFailure.duplicateOperation }
                guard Self.validID(operation.id), !operation.dataScopes.isEmpty,
                      !(operation.modelCallable && operation.access != .read),
                      !(operation.access != .read && operation.consent == .userStartedRead),
                      !(operation.recipient.requiresNetwork && operation.access != .read && !operation.consent.needsReview) else {
                    throw IntegrationFailure.invalidDescriptor
                }
            }
        }
        self.descriptors = descriptors
    }

    static func bundled() throws -> Self {
        try Self(descriptors: [AppleLocalModelIntegration.descriptor, OfflineMemoryIntegration.descriptor,
            GitHubReadIntegration.descriptor, OpenAIHostedIntegration.descriptor, GitHubProposalIntegration.descriptor])
    }

    func availability(of id: String, runtime: IntegrationRuntimeSnapshot) throws -> IntegrationAvailability {
        guard let descriptor = descriptors.first(where: { $0.id == id }) else { throw IntegrationFailure.unknownIntegration }
        if descriptor.requiresNetwork && runtime.network == .offline { return .offlineUnavailable }
        switch id {
        case "apple.local-model": return localAvailability(runtime.localModelAvailable)
        case "local.memory": return localAvailability(runtime.memoryAvailable)
        case "github.read": return runtime.network == .online ? .available : .configured
        case "openai.hosted":
            guard runtime.hostedSessionConfigured else { return .setupRequired }
            return runtime.network == .online ? .available : .configured
        case "github.proposals":
            guard runtime.proposalSessionConfigured else { return .setupRequired }
            return runtime.network == .online ? .available : .configured
        default: return .setupRequired // New adapters must explicitly define their runtime checks.
        }
    }

    /// Call only from trusted UI code after real user selection. `initiatedBy` is not an
    /// authentication mechanism and must never be accepted as a model/server argument.
    func approve(_ request: IntegrationInvocation, initiatedBy: IntegrationInitiator,
                 runtime: IntegrationRuntimeSnapshot, reviewedRequest: IntegrationInvocation? = nil) throws -> IntegrationGrant {
        guard initiatedBy == .user else { throw IntegrationFailure.modelPermissionChange }
        let operation = try validateDeclaration(request, runtime: runtime)
        if operation.consent.needsReview && reviewedRequest != request { throw IntegrationFailure.reviewRequired }
        return IntegrationGrant(registryID: registryID, invocation: request)
    }

    /// A successful result describes policy compatibility only. Adapter-specific session,
    /// expiry, budgets, exact-payload review and single-use consent remain mandatory.
    func validate(_ request: IntegrationInvocation, grant: IntegrationGrant?, initiatedBy: IntegrationInitiator,
                  runtime: IntegrationRuntimeSnapshot) throws {
        let operation = try validateDeclaration(request, runtime: runtime)
        guard let grant else { throw IntegrationFailure.missingGrant }
        guard grant.registryID == registryID, grant.invocation == request else { throw IntegrationFailure.scopeMismatch }
        if initiatedBy == .model && !operation.modelCallable { throw IntegrationFailure.modelOperationDenied }
    }

    func redactedMetadata(runtime: IntegrationRuntimeSnapshot) -> [IntegrationRedactedMetadata] {
        descriptors.map { descriptor in
            IntegrationRedactedMetadata(integrationID: descriptor.id, version: descriptor.version.description,
                operationCount: descriptor.operations.count,
                availability: (try? availability(of: descriptor.id, runtime: runtime)) ?? .deviceUnavailable)
        }
    }

    private func validateDeclaration(_ request: IntegrationInvocation, runtime: IntegrationRuntimeSnapshot) throws -> IntegrationOperationDescriptor {
        guard let descriptor = descriptors.first(where: { $0.id == request.integrationID }) else { throw IntegrationFailure.unknownIntegration }
        guard let operation = descriptor.operations.first(where: { $0.id == request.operationID }) else { throw IntegrationFailure.unknownOperation }
        guard request.recipient == operation.recipient else { throw IntegrationFailure.recipientMismatch }
        guard request.dataScopes == operation.dataScopes else { throw IntegrationFailure.dataScopeMismatch }
        guard request.resource.kind == operation.resourceKind else { throw IntegrationFailure.invalidResource }
        try request.resource.validate(allowRoot: operation.allowsRootPath)
        if operation.recipient.requiresNetwork {
            if runtime.network == .offline { throw IntegrationFailure.offline }
            if runtime.network == .unknown { throw IntegrationFailure.networkUnverified }
        }
        switch try availability(of: descriptor.id, runtime: runtime) {
        case .available: break
        case .setupRequired: throw IntegrationFailure.setupRequired
        case .offlineUnavailable: throw IntegrationFailure.offline
        case .configured, .deviceUnavailable: throw IntegrationFailure.unavailable
        }
        return operation
    }

    private func localAvailability(_ value: Bool?) -> IntegrationAvailability {
        guard let value else { return .configured }
        return value ? .available : .deviceUnavailable
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 80 && value.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0)
        }
    }
}
