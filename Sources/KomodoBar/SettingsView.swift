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
        KomodoCredentials(urlString: address, apiKey: apiKey, apiSecret: apiSecret)
    }

    var body: some View {
        Form {
            Section {
                TextField("Server URL", text: $address, prompt: Text("https://komodo.example.com"))
                    .textContentType(.URL)
                TextField("API Key", text: $apiKey, prompt: Text("the key from Settings → Users → Api Keys"))
                SecureField("API Secret", text: $apiSecret, prompt: Text("shown once when the key is created"))
            } header: {
                Text("Komodo Connection")
            } footer: {
                Text("Komodo Core listens on port 9120 (HTTP) unless behind a reverse proxy. The secret is stored in your Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Refresh every", selection: $pollInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
            }

            Section {
                Picker("Show stacks", selection: $stackFilter) {
                    ForEach(StackFilter.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: stackFilter) { _, newValue in
                    KomodoStore.shared.stackFilter = newValue
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Down stacks are often intentionally off — hide them to cut menu clutter. Pending updates are always shown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let testResult {
                Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(testOK ? .green : .red)
                    .font(.callout)
            }

            HStack {
                Button("Test Connection") { Task { await testConnection() } }
                    .disabled(credentials == nil || testing)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(credentials == nil)
            }
        }
        .formStyle(.grouped)
    }

    private func testConnection() async {
        guard let credentials else { return }
        testing = true
        testResult = nil
        defer { testing = false }
        let client = KomodoClient(credentials: credentials)
        do {
            let version = try await client.ping()
            let summary = try await client.serversSummary()
            testOK = true
            testResult = "Connected to Komodo v\(version) — \(summary.total) server(s)."
        } catch let error as KomodoError {
            testOK = false
            testResult = error.errorDescription ?? error.message
        } catch {
            testOK = false
            testResult = error.localizedDescription
        }
    }

    private func save() {
        CredentialStore.save(address: address, apiKey: apiKey, apiSecret: apiSecret)
        KomodoStore.shared.pollInterval = pollInterval
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
