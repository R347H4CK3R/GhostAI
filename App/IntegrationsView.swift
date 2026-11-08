import SwiftUI

/// Navigation only. These closures must open the existing review/selection screens,
/// not execute requests, create credentials or grant access as a side effect.
struct IntegrationNavigation {
    var openAssistant: (() -> Void)?
    var openMemory: (() -> Void)?
    var openProjects: (() -> Void)?
    var openHosted: (() -> Void)?
    var openProposals: (() -> Void)?

    init(openAssistant: (() -> Void)? = nil, openMemory: (() -> Void)? = nil,
         openProjects: (() -> Void)? = nil, openHosted: (() -> Void)? = nil,
         openProposals: (() -> Void)? = nil) {
        self.openAssistant = openAssistant; self.openMemory = openMemory
        self.openProjects = openProjects; self.openHosted = openHosted; self.openProposals = openProposals
    }

    fileprivate func action(for id: String) -> (() -> Void)? {
        switch id {
        case "apple.local-model": return openAssistant
        case "local.memory": return openMemory
        case "github.read": return openProjects
        case "openai.hosted": return openHosted
        case "github.proposals": return openProposals ?? openProjects
        default: return nil
        }
    }
    fileprivate func label(for id: String) -> String {
        switch id {
        case "apple.local-model": return "Open Assistant"
        case "local.memory": return "Open Memory"
        case "github.read": return "Open Projects"
        case "openai.hosted": return "Open Hosted"
        case "github.proposals": return openProposals == nil ? "Select a project for a proposal" : "Open proposal review"
        default: return "Open integration"
        }
    }
}

/// Standalone, read-only catalog. Showing this view does not initialize any adapter,
/// load a credential, infer an account connection, or make a network request.
struct IntegrationsView: View {
    let runtime: IntegrationRuntimeSnapshot
    let navigation: IntegrationNavigation
    private let registry: IntegrationRegistry?

    init(runtime: IntegrationRuntimeSnapshot = .init(), navigation: IntegrationNavigation = .init()) {
        self.runtime = runtime; self.navigation = navigation
        registry = try? IntegrationRegistry.bundled()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Your tools. Clear boundaries.", systemImage: "puzzlepiece.extension")
                            .font(.headline)
                        Text("These integrations are built into this app. Browsing this list does not connect an account or send data.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("dot and ChatGPT plugins, accounts and permissions are not inherited.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }

                if let registry {
                    Section("Bundled integrations") {
                        ForEach(registry.descriptors) { descriptor in
                            integrationRow(descriptor, registry: registry)
                        }
                    }
                } else {
                    Section("Catalog unavailable") {
                        Text("The bundled catalog could not be validated. No adapter was started. The individual feature screens remain separate.")
                    }
                }

                Section("Network and setup") {
                    Label(networkLabel, systemImage: runtime.network == .offline ? "wifi.slash" : "network")
                    Text("Availability is based only on app-supplied state, not a live service test. It does not prove account access, billing, model access or a working connection. Provider errors remain visible in each feature's screen.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("No account creation, OAuth enrollment, credential provisioning or API request happens here. Read access never becomes write access.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Future adapters") {
                    Text("Remote MCP servers and third-party OAuth connectors are not implemented or connected.")
                    Text("New integrations must be reviewed and compiled into an app update. A future MCP adapter must declare exact tools, recipients and data scopes, validate untrusted tool results, and use separate user-approved setup. Downloaded code and arbitrary shell execution are not supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Integrations")
            .accessibilityIdentifier("integrationsScreen")
        }
    }

    private var networkLabel: String {
        switch runtime.network {
        case .unknown: return "Network availability not checked"
        case .online: return "App reports a network connection"
        case .offline: return "Offline: use saved local features"
        }
    }

    private func integrationRow(_ descriptor: IntegrationDescriptor, registry: IntegrationRegistry) -> some View {
        let availability = (try? registry.availability(of: descriptor.id, runtime: runtime)) ?? .deviceUnavailable
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text(descriptor.summary).font(.subheadline)
                detail("Data and recipients", descriptor.dataDisclosure)
                detail("Setup", descriptor.setup)
                ForEach(descriptor.operations) { operation in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(operation.name).font(.subheadline.weight(.semibold))
                        Text(operation.recipient.label).font(.caption).textSelection(.enabled)
                        Text(operation.access.rawValue.capitalized + " · " + operation.consent.label).font(.caption)
                        Text(operation.modelCallable ? "Model may request only an already granted read scope." : "User-operated feature; not callable by a model.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Declared data: " + operation.dataScopes.sorted { $0.rawValue < $1.rawValue }
                            .map(\.label).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let action = navigation.action(for: descriptor.id) {
                    Button(navigation.label(for: descriptor.id), action: action)
                        .accessibilityIdentifier("integrationOpen." + descriptor.id)
                }
                Text("Adapter " + descriptor.id + " · v" + descriptor.version.description)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }.padding(.vertical, 8)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: descriptor.symbol).foregroundStyle(.cyan).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(descriptor.name).font(.headline)
                    Text(availability.label).font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 4)
        }
        .accessibilityIdentifier("integration." + descriptor.id)
    }

    private func detail(_ heading: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.subheadline.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
