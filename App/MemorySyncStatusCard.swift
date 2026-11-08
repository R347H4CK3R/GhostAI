import SwiftUI

/// Observe the controller itself so progress and last-success changes update immediately.
struct MemorySyncStatusCard: View {
    @ObservedObject var controller: PrivateMemorySyncController
    @State private var showingDetails = false

    var body: some View {
        Button { showingDetails = true } label: {
            HStack(alignment: .top, spacing: 12) {
                LibraryItemIcon(symbol: controller.isConfigured ? "lock.icloud" : "icloud")
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.statusTitle).font(.headline).foregroundStyle(.primary)
                    Text(controller.statusDetail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = controller.lastSyncedAt {
                        Text("Last completed: \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if controller.pendingChanges {
                        Label("Changes waiting to upload", systemImage: "clock")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                if controller.isWorking { ProgressView().accessibilityLabel("Sync in progress") }
                else { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true) }
            }.padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Private sync: \(controller.statusTitle)")
        .accessibilityValue(controller.statusDetail + (controller.pendingChanges ? " Changes waiting to upload." : ""))
        .accessibilityIdentifier("memory.sync.open")
        .accessibilityHint("Review private sync status and setup")
        .sheet(isPresented: $showingDetails) { PrivateMemorySyncView(controller: controller) }
    }
}
