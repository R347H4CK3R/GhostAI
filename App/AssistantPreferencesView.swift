import SwiftUI

struct AssistantPreferencesView: View {
    @ObservedObject private var preferences: AssistantPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var avatar: AssistantAvatar
    @State private var startScreen: AssistantStartScreen
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    init(preferences: AssistantPreferences) {
        self.preferences = preferences
        _name = State(initialValue: preferences.value.name)
        _avatar = State(initialValue: preferences.value.avatar)
        _startScreen = State(initialValue: preferences.value.startScreen)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: avatar.symbol)
                            .font(.system(size: 30)).foregroundStyle(.cyan)
                            .frame(width: 64, height: 64)
                            .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(name.isEmpty ? "Your assistant" : name).font(.title3.weight(.semibold))
                            Text("Local assistant profile").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                    TextField("Assistant name", text: $name)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .focused($nameFocused).accessibilityIdentifier("assistantPreferences.name")
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("assistantPreferences.error")
                    }
                } footer: {
                    Text("This changes the name shown in this app. Your model, permissions, saved conversations and connections stay the same.")
                }
                Section("Avatar") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                        ForEach(AssistantAvatar.allCases) { option in
                            Button {
                                nameFocused = false
                                avatar = option
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: option.symbol).font(.title2).frame(height: 28)
                                    Text(option.title).font(.caption)
                                }.frame(maxWidth: .infinity).padding(.vertical, 10)
                                    .foregroundStyle(avatar == option ? Color.cyan : Color.secondary)
                                    .background(avatar == option ? Color.cyan.opacity(0.12) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                                .accessibilityLabel(option.title + " avatar")
                                .accessibilityValue(avatar == option ? "Selected" : "Not selected")
                                .accessibilityIdentifier("assistantPreferences.avatar." + option.rawValue)
                        }
                    }
                }
                Section {
                    Picker("Start screen", selection: $startScreen) {
                        ForEach(AssistantStartScreen.allCases) { screen in
                            Text(screen.title).tag(screen).accessibilityIdentifier("assistantPreferences.startScreen." + screen.rawValue)
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("assistantPreferences.startScreen")
                } footer: {
                    Text("Used when you next launch the app. Siri voice requests still open Assistant controls without starting the microphone.")
                }
                if let warning = preferences.loadWarning {
                    Section("Saved settings") { Text(warning).font(.footnote).foregroundStyle(.orange) }
                }
                Section {
                    Text("These preferences stay on this device. They are not included in chats, memory backups or private memory sync.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Name & avatar").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.accessibilityIdentifier("assistantPreferences.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        nameFocused = false
                        do {
                            try preferences.save(name: name, avatar: avatar, startScreen: startScreen)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("assistantPreferences.save")
                }
            }
        }
    }
}
