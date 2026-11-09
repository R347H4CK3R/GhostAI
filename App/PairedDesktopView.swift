import SwiftUI

struct PairedDesktopView: View {
    @EnvironmentObject private var model: PairedDesktopClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var screenID = UUID()
    @State private var screenVisible = false
    @State private var descriptor = ""
    @State private var deviceName = "My iPhone"
    @State private var verifiedDisplay = false
    @State private var directlyInstalled = false
    @State private var reviewedPreviewToken: UUID?
    @State private var previewError: String?
    @State private var project = ""
    @State private var goal = ""
    @State private var limits = PairedDesktopLimits.defaults
    @State private var forgetConfirmation = false
    @State private var archiveConfirmation: PairedDesktopSubmission?

    init(initialGoal: String = "") {
        _goal = State(initialValue: initialGoal)
    }

    var body: some View {
        List {
            Section("Foreground desktop jobs · Development") {
                Text("Use an explicitly configured desktop on the same private network. Keep its host running and laptop awake. Connections run only while a paired desktop screen is visible and active.")
                Text("Native TLS, device and interoperability checks are required before relying on this feature. No always-on iPhone execution, Internet access from anywhere or automatic memory sync is provided.").font(.caption).foregroundStyle(.secondary)
            }
            if model.storageUnavailable {
                Section("Pairing storage unavailable") {
                    Text("A device passcode is required. Unlock and retry. Weaker or unreadable records are not upgraded or replaced. The passcode-bound identity, counter and outbox are excluded from backups; removing the passcode may destroy them. Revoke the old device on the desktop before explicitly pairing again.")
                    Button("Retry reading local storage") { model.reloadStorage() }.disabled(model.busy)
                }
            } else if let record = model.record { paired(record) }
            else if let invitation = model.invitation, let token = model.previewToken { review(invitation, token: token) }
            else { setup }
            if model.busy { ProgressView("Secure desktop request in progress") }
            if let message = model.message { Section("Status") { Text(message).font(.footnote).textSelection(.enabled) } }
            if let previewError { Section("Descriptor not accepted") { Text(previewError).font(.footnote) } }
            if model.record != nil || model.storageUnavailable {
                Section("Remove access") {
                    Text("Revoke this device on the desktop first. That is authoritative for future requests and effects. Forgetting here deletes only this phone’s key, job references and retained submissions, not desktop jobs or data.").font(.caption)
                    Button("Forget local pairing", role: .destructive) { forgetConfirmation = true }.disabled(model.busy)
                }
            }
        }
        .navigationTitle("Paired desktop").accessibilityIdentifier("pairedDesktop.screen")
        .task {
            screenVisible = true; model.setScreen(id: screenID, visible: true, foreground: scenePhase == .active)
            if model.record != nil { await model.refresh() }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await model.pollIfDue()
            }
        }
        .onDisappear { screenVisible = false; model.setScreen(id: screenID, visible: false, foreground: false) }
        .onChange(of: model.previewToken) { _, _ in
            reviewedPreviewToken = nil; verifiedDisplay = false; directlyInstalled = false
        }
        .onChange(of: scenePhase) { _, phase in
            model.setScreen(id: screenID, visible: screenVisible, foreground: phase == .active)
            if screenVisible && phase == .active { Task { await model.refresh() } }
        }
        .alert("Archive this unresolved submission?", isPresented: Binding(get: { archiveConfirmation != nil }, set: { if !$0 { archiveConfirmation = nil } }), presenting: archiveConfirmation) { submission in
            Button("Retain in archive and allow a new task") {
                model.archiveSubmission(submission.submissionID, confirmedMayAlreadyBeAccepted: true); goal = ""; project = ""
            }
            Button("Keep current outbox", role: .cancel) {}
        } message: { submission in
            Text("Submission \(submission.submissionID) may already be accepted or completed. Check the desktop before starting another task to avoid duplicate work. Archiving does not cancel it or prove failure. Original bytes and ID remain in bounded history for an explicit same-ID retry.")
        }
        .alert("Forget this phone’s pairing?", isPresented: $forgetConfirmation) {
            Button("Forget local pairing", role: .destructive) {
                model.forget(); descriptor = ""; goal = ""; project = ""; verifiedDisplay = false; directlyInstalled = false
            }
            Button("Keep pairing", role: .cancel) {}
        } message: {
            Text("Revoke the device on the desktop too. Forgetting cannot remotely revoke access, cancel jobs or erase desktop data. An unresolved submission may already be running; losing its local identity prevents reconciliation. Check the desktop before resubmitting under a new pairing.")
        }
    }
    private var setup: some View {
        Section("Not configured") {
            Text("Run the documented foreground setup on your desktop and show a short-lived invitation locally. Paste only from that owner-controlled display. A message or link alone does not establish desktop identity.").font(.footnote)
            TextEditor(text: $descriptor).frame(minHeight: 130).autocorrectionDisabled().textInputAutocapitalization(.never)
                .accessibilityLabel("Owner-displayed invitation JSON").accessibilityIdentifier("pairedDesktop.descriptor")
            Button("Review desktop invitation") {
                do { try model.preview(Data(descriptor.utf8)); descriptor = ""; previewError = nil; verifiedDisplay = false; directlyInstalled = false }
                catch { previewError = "The invitation is malformed, expired or uses an unsupported endpoint. Only canonical private IPv4 HTTPS addresses with an explicit port are accepted. Get a fresh descriptor locally." }
            }.disabled(descriptor.isEmpty || descriptor.utf8.count > 4096 || model.busy)
                .accessibilityIdentifier("pairedDesktop.review")
            Text("Reviewing creates no credentials and sends nothing. The descriptor contains a temporary secret; do not publish or share it.").font(.caption)
        }
    }
    @ViewBuilder private func review(_ invitation: PairedExecutionInvitation, token: UUID) -> some View {
        Section("Verify locally before connecting") {
            LabeledContent("Desktop origin", value: invitation.origin)
            Text("Leaf certificate SHA-256").font(.caption)
            Text(invitation.tlsLeafSHA256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text("Host ID: \(invitation.hostID)").font(.caption).textSelection(.enabled)
            Text("Compare the exact origin and fingerprint with the desktop display. A certificate change stops requests rather than being accepted automatically.").font(.caption)
            TextField("Device name shown on desktop", text: $deviceName).autocorrectionDisabled()
            Toggle("I verified the owner-controlled desktop display", isOn: consentBinding(token: token, directInstallation: false))
            Toggle("I am using a directly installed app, not a host container", isOn: consentBinding(token: token, directInstallation: true))
        }
        Section("Approve persistent device identity") {
            Text("Continue requires a device passcode and creates a P-256 signing key. Key, counter and pending submissions are stored together in this device’s non-synchronizing, passcode-bound Keychain, usable only while unlocked and excluded from backups. Passcode removal may destroy the whole record. This app will not change device settings.")
            Text("Your chosen device name and pairing proof go only to this desktop after certificate checks. This descriptor does not contain project grants: compare the safety code and review exact workspaces, local model and read-only grants on the desktop before approving there.")
            Text("Later submitted goals and desktop file reads are visible to that desktop and its selected local model. Results return here. No phone notes, chats or GitHub credentials are shared. Revoke the identity on the desktop to stop future access; deleting the local key does not revoke access or erase copied data.").font(.caption)
            Button("Create device-only key and request pairing") {
                guard let reviewed = reviewedPreviewToken, reviewed == token, model.previewToken == token,
                      verifiedDisplay, directlyInstalled else { return }
                let name = deviceName
                Task { await model.confirmPairing(expectedPreviewToken: reviewed, deviceName: name) }
            }
                .disabled(reviewedPreviewToken != token || model.previewToken != token || !verifiedDisplay || !directlyInstalled || deviceName.isEmpty || model.busy)
                .accessibilityIdentifier("pairedDesktop.confirmPairing")
            Button("Cancel review", role: .cancel) { model.dismissPreview() }.disabled(model.busy)
        }
    }
    /// The binding itself binds consent to the displayed token, not merely an
    /// asynchronous onChange reset. This closes the cross-window rendering race.
    private func consentBinding(token: UUID, directInstallation: Bool) -> Binding<Bool> {
        Binding(get: {
            guard reviewedPreviewToken == token, model.previewToken == token else { return false }
            return directInstallation ? directlyInstalled : verifiedDisplay
        }, set: { approved in
            guard model.previewToken == token else {
                reviewedPreviewToken = nil; verifiedDisplay = false; directlyInstalled = false; return
            }
            if reviewedPreviewToken != token {
                reviewedPreviewToken = token; verifiedDisplay = false; directlyInstalled = false
            }
            if directInstallation { directlyInstalled = approved } else { verifiedDisplay = approved }
        })
    }
    @ViewBuilder private func paired(_ record: PairedDesktopRecord) -> some View {
        Section("Saved desktop identity") {
            LabeledContent("Origin", value: record.origin)
            Text(record.pin).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            if let id = record.deviceID { Text("Device ID: \(id)").font(.caption).textSelection(.enabled) }
        }
        switch record.phase {
        case .beginning:
            Section("Pairing request unresolved") {
                Text("The desktop may already have received this request. Retry the same saved key and bytes; no replacement identity is created automatically.")
                Button("Retry saved pairing request") { Task { await model.retryEnrollment() } }.disabled(!model.canRequest)
            }
        case .pending:
            Section("Approve on desktop") {
                Text(record.safetyCode).font(.system(.title2, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("pairedDesktop.safetyCode")
                Text("Both displays must match. Review exact project grants on the desktop, then approve there. This phone cannot approve itself. Approval checks occur no faster than every five seconds while a screen is active and stop when the invitation expires.")
                Button("Check approval") { Task { await model.refresh() } }.disabled(!model.canRequest)
            }
        case .rePairRequired:
            Section("Re-pair required") { Text("Enrollment expired or the desktop rejected this identity, sequence or authorization. Inspect outstanding jobs and revoke this identity on the desktop, then explicitly forget and pair again. Do not reset the counter.") }
        case .active:
            Section("Desktop-approved read-only grants") {
                if record.grants.isEmpty { Text("No current projects are granted. Check local desktop authorization.") }
                ForEach(record.grants) { grant in
                    VStack(alignment: .leading) { Text(grant.label); Text("\(grant.projectID) · revision \(grant.permissionRevision) · jobs.read_only").font(.caption).textSelection(.enabled) }
                }
                Button("Refresh desktop authorization") { Task { await model.refresh() } }.disabled(!model.canRequest)
            }
            if record.outbox == nil { composer(record) }
        }
        if let outbox = record.outbox {
            Section("Submission awaiting reconciliation") {
                Text("This may already be accepted. Retry its exact saved bytes and ID, or explicitly archive after checking the desktop. A new job stays blocked until you confirm archiving.")
                Text(outbox.submissionID).font(.caption).textSelection(.enabled)
                Button("Retry the same saved submission") { Task { await model.retrySubmission() } }.disabled(!model.canRequest || record.phase != .active)
                Button("Review archive and new-task warning") { archiveConfirmation = outbox }.disabled(!model.canRequest || record.phase != .active)
            }
        }
        if !record.archivedSubmissions.isEmpty {
            Section("Retained submissions · \(record.archivedSubmissions.count)/\(PairedDesktopRecord.maximumArchivedSubmissions)") {
                Text("Original bytes and IDs remain retained. Entries are not cancellations or proof of failure, and are never silently evicted.").font(.caption)
                ForEach(record.archivedSubmissions) { entry in
                    VStack(alignment: .leading) {
                        Text(entry.submissionID).font(.caption).textSelection(.enabled)
                        Text("Project: \(entry.projectID)").font(.caption)
                        if let job = record.jobs.first(where: { $0.submissionID == entry.submissionID }) { Text("Reconciled as job \(job.jobID)").font(.caption) }
                        else { Button("Restore original submission without sending") { model.restoreArchivedSubmission(entry.submissionID) }.disabled(!model.canRequest || record.phase != .active || record.outbox != nil || record.jobs.count >= 20) }
                    }
                }
            }
        }
        if !record.jobs.isEmpty {
            Section("Accepted jobs · \(record.jobs.count)/20 saved") {
                ForEach(record.jobs.reversed()) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.status.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline)
                        Text(job.jobID).font(.caption).textSelection(.enabled)
                        if let details = model.jobDetails[job.jobID], !details.isEmpty { Text(details).font(.footnote).textSelection(.enabled) }
                        HStack {
                            Button("Check status") { Task { await model.refreshJob(job.jobID) } }
                            if !job.isTerminal { Button(job.cancellationBody == nil ? "Request cancellation" : "Retry cancellation") { Task { await model.cancelJob(job.jobID) } } }
                        }.buttonStyle(.bordered).disabled(!model.canRequest || record.phase != .active)
                    }
                }
                Text("Jobs continue after this screen closes only while the desktop host runs. Cancellation is cooperative and cannot undo earlier reads. Model summaries are not verified proof. History is bounded and never silently evicted.").font(.caption)
            }
        }
    }
    private func composer(_ record: PairedDesktopRecord) -> some View {
        Section("Review a read-only job") {
            Picker("Project", selection: $project) { Text("Choose a granted project").tag(""); ForEach(record.grants) { Text($0.label).tag($0.projectID) } }
            TextField("Goal sent to this desktop and local model", text: $goal, axis: .vertical).lineLimit(3...8)
            Stepper("Iterations: \(limits.maxIterations)", value: $limits.maxIterations, in: 1...8)
            Stepper("Tool calls: \(limits.maxToolCalls)", value: $limits.maxToolCalls, in: 1...32)
            Stepper("Seconds: \(limits.maxSeconds)", value: $limits.maxSeconds, in: 1...120)
            Stepper("I/O bytes: \(limits.maxIOBytes)", value: $limits.maxIOBytes, in: 1...1_048_576, step: 1024)
            Stepper("Output bytes: \(limits.maxOutputBytes)", value: $limits.maxOutputBytes, in: 1...262_144, step: 1024)
            Text("Only this goal, project and budgets are sent. The host may list/read its locally granted files, validate JSON and calculate hashes. No remote writes, shell commands or downloads. Stricter desktop limits can reject a request and are never raised by this phone.").font(.caption)
            Button("Send reviewed read-only job") {
                let selected = project; let reviewedGoal = goal; let reviewedLimits = limits
                Task { await model.submit(projectID: selected, goal: reviewedGoal, limits: reviewedLimits) }
            }.disabled(!model.canSubmit || !record.grants.contains(where: { $0.projectID == project }) || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || goal.utf8.count > 8192)
                .accessibilityIdentifier("pairedDesktop.submit")
        }
    }
}

