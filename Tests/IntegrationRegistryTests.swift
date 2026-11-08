import XCTest
@testable import AsterionVeyra

/// These exercise policy only. No test contacts a provider or invokes an adapter.
final class IntegrationRegistryTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let online = IntegrationRuntimeSnapshot(network: .online, localModelAvailable: true,
        memoryAvailable: true, hostedSessionConfigured: true, proposalSessionConfigured: true)

    private func read(path: String = "README.md", repository: String = "owner/repo",
                      commit: String? = nil) -> IntegrationInvocation {
        IntegrationInvocation(integrationID: "github.read", operationID: "read_text",
            resource: .repository(name: repository, commit: commit ?? self.commit, path: path),
            recipient: .githubAPI, dataScopes: [.repositoryIdentity, .repositoryPath, .pinnedRevision, .optionalReadCredential])
    }

    func testDuplicateIntegrationIDsAreRejectedRatherThanOverwritten() throws {
        let descriptor = GitHubReadIntegration.descriptor
        XCTAssertThrowsError(try IntegrationRegistry(descriptors: [descriptor, descriptor])) {
            XCTAssertEqual($0 as? IntegrationFailure, .duplicateIntegration)
        }
    }

    func testDuplicateOperationIDsAreRejected() {
        let operation = GitHubReadIntegration.descriptor.operations[0]
        let descriptor = IntegrationDescriptor(id: "test.duplicate", version: .init(major: 1, minor: 0, patch: 0),
            name: "Test", summary: "Test", symbol: "puzzlepiece", setup: "Test", dataDisclosure: "Test",
            operations: [operation, operation])
        XCTAssertThrowsError(try IntegrationRegistry(descriptors: [descriptor])) {
            XCTAssertEqual($0 as? IntegrationFailure, .duplicateOperation)
        }
    }

    func testUnknownIntegrationAndOperationAreDenied() throws {
        let registry = try IntegrationRegistry.bundled()
        for (plugin, tool) in [("remote.mcp", "read_text"), ("github.read", "run_shell")] {
            let request = IntegrationInvocation(integrationID: plugin, operationID: tool,
                resource: .project("General"), recipient: .onDevice, dataScopes: [.projectNotes])
            XCTAssertThrowsError(try registry.approve(request, initiatedBy: .user, runtime: online)) {
                XCTAssertEqual($0 as? IntegrationFailure, plugin == "remote.mcp" ? .unknownIntegration : .unknownOperation)
            }
        }
    }

    func testNoImplicitGrantEvenForReadOnlyOperation() throws {
        let registry = try IntegrationRegistry.bundled()
        XCTAssertThrowsError(try registry.validate(read(), grant: nil, initiatedBy: .model, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .missingGrant)
        }
    }

    func testUserGrantPermitsOnlyTheExactSelectedRead() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = read()
        let grant = try registry.approve(request, initiatedBy: .user, runtime: online)
        XCTAssertNoThrow(try registry.validate(request, grant: grant, initiatedBy: .model, runtime: online))
        for changed in [read(path: "Secrets.md"), read(repository: "other/repo"), read(commit: String(repeating: "b", count: 40))] {
            XCTAssertThrowsError(try registry.validate(changed, grant: grant, initiatedBy: .model, runtime: online)) {
                XCTAssertEqual($0 as? IntegrationFailure, .scopeMismatch)
            }
        }
    }

    func testModelCannotCreateOrWidenGrants() throws {
        let registry = try IntegrationRegistry.bundled()
        XCTAssertThrowsError(try registry.approve(read(), initiatedBy: .model, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .modelPermissionChange)
        }
        let grant = try registry.approve(read(), initiatedBy: .user, runtime: online)
        let widened = IntegrationInvocation(integrationID: "github.read", operationID: "read_text",
            resource: read().resource, recipient: .githubAPI,
            dataScopes: read().dataScopes.union([.projectNotes]))
        XCTAssertThrowsError(try registry.validate(widened, grant: grant, initiatedBy: .model, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .dataScopeMismatch)
        }
    }

    func testNarrowerDataDeclarationsCannotHideActualAdapterRequirements() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = IntegrationInvocation(integrationID: "github.read", operationID: "read_text",
            resource: read().resource, recipient: .githubAPI, dataScopes: [.repositoryIdentity])
        XCTAssertThrowsError(try registry.approve(request, initiatedBy: .user, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .dataScopeMismatch)
        }
    }

    func testRecipientCannotBeSubstituted() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = IntegrationInvocation(integrationID: "github.read", operationID: "read_text",
            resource: read().resource, recipient: .openAIResponses, dataScopes: read().dataScopes)
        XCTAssertThrowsError(try registry.approve(request, initiatedBy: .user, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .recipientMismatch)
        }
    }

    func testGrantsCannotCrossRegistryInstances() throws {
        let first = try IntegrationRegistry.bundled()
        let second = try IntegrationRegistry.bundled()
        let grant = try first.approve(read(), initiatedBy: .user, runtime: online)
        XCTAssertThrowsError(try second.validate(read(), grant: grant, initiatedBy: .user, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .scopeMismatch)
        }
    }

    func testOfflineAndUnknownNetworkDenyNetworkOperationsAfterGrant() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = read()
        let grant = try registry.approve(request, initiatedBy: .user, runtime: online)
        for (network, failure) in [(IntegrationNetworkStatus.offline, IntegrationFailure.offline), (.unknown, .networkUnverified)] {
            XCTAssertThrowsError(try registry.validate(request, grant: grant, initiatedBy: .user,
                runtime: .init(network: network))) { XCTAssertEqual($0 as? IntegrationFailure, failure) }
        }
    }

    func testOfflineMemorySearchRemainsUsable() throws {
        let registry = try IntegrationRegistry.bundled()
        let runtime = IntegrationRuntimeSnapshot(network: .offline, memoryAvailable: true)
        let request = IntegrationInvocation(integrationID: "local.memory", operationID: "search_notes",
            resource: .project("General"), recipient: .onDevice, dataScopes: [.projectNotes])
        let grant = try registry.approve(request, initiatedBy: .user, runtime: runtime)
        XCTAssertNoThrow(try registry.validate(request, grant: grant, initiatedBy: .model, runtime: runtime))
        let changed = IntegrationInvocation(integrationID: "local.memory", operationID: "search_notes",
            resource: .project("Other"), recipient: .onDevice, dataScopes: [.projectNotes])
        XCTAssertThrowsError(try registry.validate(changed, grant: grant, initiatedBy: .model, runtime: runtime))
    }

    func testCachedKnowledgeMetadataAllowsExplicitOfflineReadGrant() throws {
        // Policy declarations only: this neither searches storage nor loads an executable plugin.
        let registry = try IntegrationRegistry.bundled()
        let runtime = IntegrationRuntimeSnapshot(network: .offline, memoryAvailable: true)
        let operation = try XCTUnwrap(OfflineMemoryIntegration.descriptor.operations.first { $0.id == "search_cached_knowledge" })
        XCTAssertEqual(operation.access, .read)
        XCTAssertEqual(operation.recipient, .onDevice)
        XCTAssertEqual(operation.dataScopes, [.cachedKnowledge])
        XCTAssertTrue(operation.modelCallable)
        XCTAssertFalse(OfflineMemoryIntegration.descriptor.requiresNetwork)
        let request = IntegrationInvocation(integrationID: "local.memory", operationID: operation.id,
            resource: .project("General"), recipient: .onDevice, dataScopes: [.cachedKnowledge])
        let grant = try registry.approve(request, initiatedBy: .user, runtime: runtime)
        XCTAssertNoThrow(try registry.validate(request, grant: grant, initiatedBy: .model, runtime: runtime))
    }

    func testCachedKnowledgeCannotReuseNoteGrantOrCrossProjectAndAccountScope() throws {
        let registry = try IntegrationRegistry.bundled()
        let runtime = IntegrationRuntimeSnapshot(network: .offline, memoryAvailable: true)
        let project = "GitHub account 1: owner/private"
        let notes = IntegrationInvocation(integrationID: "local.memory", operationID: "search_notes",
            resource: .project(project), recipient: .onDevice, dataScopes: [.projectNotes])
        let cached = IntegrationInvocation(integrationID: "local.memory", operationID: "search_cached_knowledge",
            resource: .project(project), recipient: .onDevice, dataScopes: [.cachedKnowledge])
        let notesGrant = try registry.approve(notes, initiatedBy: .user, runtime: runtime)
        XCTAssertThrowsError(try registry.validate(cached, grant: notesGrant, initiatedBy: .model, runtime: runtime)) {
            XCTAssertEqual($0 as? IntegrationFailure, .scopeMismatch)
        }
        let cachedGrant = try registry.approve(cached, initiatedBy: .user, runtime: runtime)
        XCTAssertThrowsError(try registry.validate(notes, grant: cachedGrant, initiatedBy: .model, runtime: runtime)) {
            XCTAssertEqual($0 as? IntegrationFailure, .scopeMismatch)
        }
        for changedProject in ["General", "GitHub account 2: owner/private", "GitHub account 1: other/project"] {
            let changed = IntegrationInvocation(integrationID: "local.memory", operationID: "search_cached_knowledge",
                resource: .project(changedProject), recipient: .onDevice, dataScopes: [.cachedKnowledge])
            XCTAssertThrowsError(try registry.validate(changed, grant: cachedGrant, initiatedBy: .model, runtime: runtime)) {
                XCTAssertEqual($0 as? IntegrationFailure, .scopeMismatch)
            }
        }
    }

    func testCachedKnowledgeHasNoImplicitModelGrantOrScopeSubstitution() throws {
        let registry = try IntegrationRegistry.bundled()
        let runtime = IntegrationRuntimeSnapshot(network: .offline, memoryAvailable: true)
        let request = IntegrationInvocation(integrationID: "local.memory", operationID: "search_cached_knowledge",
            resource: .project("General"), recipient: .onDevice, dataScopes: [.cachedKnowledge])
        XCTAssertThrowsError(try registry.validate(request, grant: nil, initiatedBy: .model, runtime: runtime)) {
            XCTAssertEqual($0 as? IntegrationFailure, .missingGrant)
        }
        XCTAssertThrowsError(try registry.approve(request, initiatedBy: .model, runtime: runtime)) {
            XCTAssertEqual($0 as? IntegrationFailure, .modelPermissionChange)
        }
        let disguised = IntegrationInvocation(integrationID: "local.memory", operationID: "search_cached_knowledge",
            resource: .project("General"), recipient: .onDevice, dataScopes: [.projectNotes])
        XCTAssertThrowsError(try registry.approve(disguised, initiatedBy: .user, runtime: runtime)) {
            XCTAssertEqual($0 as? IntegrationFailure, .dataScopeMismatch)
        }
    }

    func testInvalidAndWildcardRepositoryResourcesAreDenied() throws {
        let registry = try IntegrationRegistry.bundled()
        for request in [read(path: "../private"), read(path: "*"), read(repository: "owner/*"), read(commit: "main"), read(path: ""), read(path: ".env"), read(path: "keys/id_rsa")] {
            XCTAssertThrowsError(try registry.approve(request, initiatedBy: .user, runtime: online)) {
                XCTAssertEqual($0 as? IntegrationFailure, .invalidResource)
            }
        }
    }

    func testDirectoryRootNeedsItsOwnOperationGrant() throws {
        let registry = try IntegrationRegistry.bundled()
        let listing = IntegrationInvocation(integrationID: "github.read", operationID: "list_tree",
            resource: .repository(name: "owner/repo", commit: commit, path: ""),
            recipient: .githubAPI, dataScopes: read().dataScopes)
        let grant = try registry.approve(listing, initiatedBy: .user, runtime: online)
        XCTAssertNoThrow(try registry.validate(listing, grant: grant, initiatedBy: .model, runtime: online))
        XCTAssertThrowsError(try registry.validate(read(), grant: grant, initiatedBy: .model, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .scopeMismatch)
        }
    }

    func testSavingLocalNotesHasNoDefaultWriteGrantAndIsNeverModelCallable() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = IntegrationInvocation(integrationID: "local.memory", operationID: "save_note",
            resource: .project("General"), recipient: .onDevice, dataScopes: [.projectNotes])
        XCTAssertThrowsError(try registry.validate(request, grant: nil, initiatedBy: .user, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .missingGrant)
        }
        let grant = try registry.approve(request, initiatedBy: .user, runtime: online)
        XCTAssertThrowsError(try registry.validate(request, grant: grant, initiatedBy: .model, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .modelOperationDenied)
        }
    }

    func testDescriptorCannotAdvertiseModelCallableWrite() {
        let operation = IntegrationOperationDescriptor(id: "write", name: "Write", access: .write,
            resourceKind: .project, recipient: .onDevice, dataScopes: [.projectNotes],
            consent: .explicitUserAction, modelCallable: true)
        let descriptor = IntegrationDescriptor(id: "test.write", version: .init(major: 1, minor: 0, patch: 0),
            name: "Test", summary: "Test", symbol: "puzzlepiece", setup: "Test", dataDisclosure: "Test",
            operations: [operation])
        XCTAssertThrowsError(try IntegrationRegistry(descriptors: [descriptor])) {
            XCTAssertEqual($0 as? IntegrationFailure, .invalidDescriptor)
        }
    }

    func testDefaultRuntimeDoesNotClaimModelOrPaidSessionAvailable() throws {
        let registry = try IntegrationRegistry.bundled()
        XCTAssertEqual(try registry.availability(of: "apple.local-model", runtime: .init()), .configured)
        XCTAssertEqual(try registry.availability(of: "github.read", runtime: .init()), .configured)
        XCTAssertEqual(try registry.availability(of: "openai.hosted", runtime: .init()), .setupRequired)
        XCTAssertEqual(try registry.availability(of: "github.proposals", runtime: .init()), .setupRequired)
        XCTAssertEqual(try registry.availability(of: "openai.hosted", runtime: .init(network: .offline)), .offlineUnavailable)
    }

    func testUnavailableLocalModelDoesNotOfferFakeOfflineAnswers() throws {
        let registry = try IntegrationRegistry.bundled()
        XCTAssertEqual(try registry.availability(of: "apple.local-model",
            runtime: .init(network: .offline, localModelAvailable: false)), .deviceUnavailable)
    }

    func testWriteGrantRequiresReviewAndCannotBeUsedByModel() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = IntegrationInvocation(integrationID: "github.proposals", operationID: "publish_draft",
            resource: .proposal(name: "owner/repo", commit: commit, path: "README.md", reviewID: UUID()),
            recipient: .githubAPI,
            dataScopes: [.repositoryIdentity, .repositoryPath, .pinnedRevision, .reviewedReplacement, .proposalMetadata, .writeCredential])
        XCTAssertThrowsError(try registry.approve(request, initiatedBy: .user, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .reviewRequired)
        }
        let grant = try registry.approve(request, initiatedBy: .user, runtime: online, reviewedRequest: request)
        XCTAssertThrowsError(try registry.validate(request, grant: grant, initiatedBy: .model, runtime: online)) {
            XCTAssertEqual($0 as? IntegrationFailure, .modelOperationDenied)
        }
        XCTAssertNoThrow(try registry.validate(request, grant: grant, initiatedBy: .user, runtime: online))
    }

    func testHostedGrantIsBoundToExactReviewIDAndDeniedWhileSessionIsUnconfigured() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = IntegrationInvocation(integrationID: "openai.hosted", operationID: "answer",
            resource: .hostedRequest(UUID()), recipient: .openAIResponses,
            dataScopes: [.question, .explicitContext, .modelIdentifier, .hostedCredential])
        XCTAssertThrowsError(try registry.approve(request, initiatedBy: .user, runtime: online))
        let grant = try registry.approve(request, initiatedBy: .user, runtime: online, reviewedRequest: request)
        let changed = IntegrationInvocation(integrationID: request.integrationID, operationID: request.operationID,
            resource: .hostedRequest(UUID()), recipient: request.recipient, dataScopes: request.dataScopes)
        XCTAssertThrowsError(try registry.validate(changed, grant: grant, initiatedBy: .user, runtime: online))
        XCTAssertThrowsError(try registry.validate(request, grant: grant, initiatedBy: .user,
            runtime: .init(network: .online))) {
            XCTAssertEqual($0 as? IntegrationFailure, .setupRequired)
        }
    }

    func testMetadataDoesNotExposeResourceOrCredentialContents() throws {
        let registry = try IntegrationRegistry.bundled()
        let request = read(path: "PrivateDesign.md", repository: "private-owner/private-repo")
        let grant = try registry.approve(request, initiatedBy: .user, runtime: online)
        let metadata = registry.redactedMetadata(runtime: online)
        let output = String(describing: request) + String(reflecting: request)
            + String(describing: grant) + String(reflecting: grant)
            + String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)
        for secret in ["PrivateDesign.md", "private-owner", "private-repo", commit] {
            XCTAssertFalse(output.contains(secret))
        }
        XCTAssertEqual(metadata.count, 5)
        XCTAssertTrue(metadata.allSatisfy { !$0.integrationID.isEmpty && !$0.version.isEmpty })
    }
}
