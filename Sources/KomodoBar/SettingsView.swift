import KomodoBarCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            ConnectionSettingsView()
                .tabItem { Label("Connection", systemImage: "network") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 560)
    }
}

private struct ConnectionSettingsView: View {
    @State private var address = CredentialStore.address
    @State private var apiKey = CredentialStore.apiKey
    @State private var apiSecret = CredentialStore.apiSecret
    @State private var pollInterval = KomodoStore.shared.pollInterval
    @State private var stackFilter = KomodoStore.shared.stackFilter

    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    private var credentials: KomodoCredentials? {
        KomodoCredentials(urlString: self.address, apiKey: self.apiKey, apiSecret: self.apiSecret)
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: self.$address, prompt: Text("https://komodo.example.com"))
                    .textContentType(.URL)
                TextField("API Key", text: self.$apiKey, prompt: Text("the key from Settings → Users → Api Keys"))
                SecureField("API Secret", text: self.$apiSecret, prompt: Text("shown once when the key is created"))
            } header: {
                Text("Komodo Connection")
            } footer: {
                Text(
                    "Komodo Core listens on port 9120 (HTTP) unless behind a reverse proxy. The secret is stored in your Keychain.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Picker("Refresh every", selection: self.$pollInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
            }

            Section {
                Picker("Show stacks", selection: self.$stackFilter) {
                    ForEach(StackFilter.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: self.stackFilter) { _, newValue in
                    KomodoStore.shared.stackFilter = newValue
                }
            } header: {
                Text("Display")
            } footer: {
                Text(
                    "Down stacks are often intentionally off — hide them to cut menu clutter. Pending updates are always shown.",
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let testResult {
                Label(testResult, systemImage: self.testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(self.testOK ? .green : .red)
                    .font(.callout)
            }

            HStack {
                Button("Test Connection") { Task { await self.testConnection() } }
                    .disabled(self.credentials == nil || self.testing)
                if self.testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Save") { self.save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(self.credentials == nil)
            }
        }
        .formStyle(.grouped)
    }

    private func testConnection() async {
        guard let credentials else { return }
        self.testing = true
        self.testResult = nil
        defer { testing = false }
        let client = KomodoClient(credentials: credentials)
        do {
            let version = try await client.ping()
            let summary = try await client.serversSummary()
            self.testOK = true
            self.testResult = "Connected to Komodo v\(version) — \(summary.total) server(s)."
        } catch let error as KomodoError {
            testOK = false
            testResult = error.errorDescription ?? error.message
        } catch {
            self.testOK = false
            self.testResult = error.localizedDescription
        }
    }

    private func save() {
        CredentialStore.save(address: self.address, apiKey: self.apiKey, apiSecret: self.apiSecret)
        KomodoStore.shared.pollInterval = self.pollInterval
        KomodoStore.shared.reloadCredentials()
        KomodoStore.shared.refreshNow()
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lizard.fill").font(.largeTitle)
            Text("KomodoBar").font(.title2).bold()
            Text("A menu-bar control plane for Komodo.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("© 2026 Danny Feates. MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
