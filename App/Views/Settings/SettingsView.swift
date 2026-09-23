import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("checkInQuestionCap") private var questionCap = 8
    @AppStorage("speakQuestions") private var speakQuestions = true
    @State private var apiKeyDraft = ""
    @State private var hasStoredKey = KeychainStore().get(KeychainStore.apiKeyAccount) != nil
    @State private var keyMessage: String?

    var body: some View {
        Form {
            Section("Animals") {
                NavigationLink("Manage Animals") { ManageAnimalsView() }
            }
            Section("Oral check-in") {
                SecureField(hasStoredKey ? "API key saved (enter to replace)" : "Anthropic API key", text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    // Borderless: a Form row otherwise hands the whole row's taps to the first button.
                    Button("Save key") { saveKey() }
                        .buttonStyle(.borderless)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                    if hasStoredKey {
                        Button("Remove key", role: .destructive) { removeKey() }
                            .buttonStyle(.borderless)
                    }
                }
                if let keyMessage { Text(keyMessage).font(.footnote).foregroundStyle(.secondary) }
                Stepper("Max follow-up questions: \(questionCap)", value: $questionCap, in: 1...20)
                Toggle("Speak questions aloud", isOn: $speakQuestions)
            }
            Section("Tags") {
                SettingsPlaceholderRow(title: "Poop tags")
                SettingsPlaceholderRow(title: "Voice tags")
            }
            Section("Data") {
                SettingsPlaceholderRow(title: "Export")
                SettingsPlaceholderRow(title: "Import")
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                Text("All records and media stay on this phone. Only oral check-in transcripts are sent to Anthropic, using your own key.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func saveKey() {
        do {
            try KeychainStore().set(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines), account: KeychainStore.apiKeyAccount)
            apiKeyDraft = ""
            hasStoredKey = true
            keyMessage = "Key saved to the keychain."
        } catch {
            keyMessage = "Could not save key: \(error)"
        }
    }

    private func removeKey() {
        KeychainStore().delete(KeychainStore.apiKeyAccount)
        hasStoredKey = false
        keyMessage = "Key removed."
    }
}

/// Rows that later plans replace with real destinations.
struct SettingsPlaceholderRow: View {
    let title: String
    var body: some View {
        LabeledContent(title) { Text("Coming soon").foregroundStyle(.secondary) }
    }
}
