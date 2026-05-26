#if canImport(UIKit)
@preconcurrency import Citadel
import Crypto
import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Security
import SwiftUI
import UIKit

struct ConnectionDraft {
    var label = ""
    var host = ""
    var port = "22"
    var user = ""
    var hermesProfile = ""
    var customHermesHomePath = ""
    var authKind: SSHCredentialKind = .password
    var password = ""
    var privateKey = ""
    var passphrase = ""

    init() {}

    init(connection: ConnectionProfile, credential: SSHCredentialRecord) {
        label = connection.label
        host = connection.sshHost
        port = connection.sshPort.map(String.init) ?? "22"
        user = connection.sshUser
        hermesProfile = connection.hermesProfile ?? ""
        customHermesHomePath = connection.customHermesHomePath ?? ""
        authKind = connection.authKind
        password = credential.password ?? ""
        privateKey = credential.privateKey ?? ""
        passphrase = credential.passphrase ?? ""
    }

    init(profileTemplateFrom connection: ConnectionProfile, credential: SSHCredentialRecord) {
        label = ""
        host = connection.sshHost
        port = connection.sshPort.map(String.init) ?? "22"
        user = connection.sshUser
        hermesProfile = ""
        customHermesHomePath = ""
        authKind = connection.authKind
        password = credential.password ?? ""
        privateKey = credential.privateKey ?? ""
        passphrase = credential.passphrase ?? ""
    }

    func makeProfile(existingID: UUID?) -> ConnectionProfile {
        ConnectionProfile(
            id: existingID ?? UUID(),
            label: label,
            sshAlias: "",
            sshHost: host,
            sshPort: Int(port),
            sshUser: user,
            hermesProfile: hermesProfile.nilIfBlank,
            customHermesHomePath: customHermesHomePath.nilIfBlank,
            authKind: authKind
        )
    }

    var credential: SSHCredentialRecord {
        SSHCredentialRecord(
            password: password.nilIfBlank,
            privateKey: privateKey.nilIfBlank,
            passphrase: passphrase.nilIfBlank
        )
    }

    var trimmedHermesProfile: String? {
        guard let value = hermesProfile.nilIfBlank else { return nil }
        guard value.caseInsensitiveCompare("default") != .orderedSame else { return nil }
        return value
    }

    var trimmedCustomHermesHomePath: String? {
        guard var value = customHermesHomePath.nilIfBlank else { return nil }
        if value == "~/" {
            return "~"
        }
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    var resolvedHermesProfileName: String {
        if let trimmedCustomHermesHomePath {
            return customHermesHomeDisplayName(trimmedCustomHermesHomePath)
        }
        return trimmedHermesProfile ?? "default"
    }

    private func customHermesHomeDisplayName(_ path: String) -> String {
        let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = normalized.split(separator: "/").last else { return "custom" }
        return String(last)
    }
}

struct ConnectionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: HermesPhoneStore
    @Binding var draft: ConnectionDraft
    let editingConnectionID: UUID?
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Host") {
                TextField("Host or IP", text: $draft.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("SSH Port", text: $draft.port)
                    .keyboardType(.numberPad)
                TextField("SSH User", text: $draft.user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Inserisci il Mac o server a cui ti colleghi via SSH. Terminale e Files funzionano già con questi dati.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Hermes Profile") {
                TextField("Display Name", text: $draft.label)
                TextField("Hermes Profile Name", text: $draft.hermesProfile)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Custom Hermes Home", text: $draft.customHermesHomePath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                profileScopeHelp
            }

            Section("Authentication") {
                Picker("Method", selection: $draft.authKind) {
                    ForEach(SSHCredentialKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                switch draft.authKind {
                case .password:
                    SecureField("Password", text: $draft.password)
                case .privateKey:
                    TextEditor(text: $draft.privateKey)
                        .frame(minHeight: 180)
                        .font(.body.monospaced())
                    SecureField("Passphrase (optional)", text: $draft.passphrase)
                }
            }

            Section {
                Button(isTesting ? "Testing…" : "Test Connection") {
                    Task {
                        isTesting = true
                        let message = await store.testConnection(
                            profile: draft.makeProfile(existingID: editingConnectionID),
                            credential: draft.credential
                        )
                        testResult = message
                        isTesting = false
                    }
                }
                .disabled(isTesting)

                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(editorTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let profile = draft.makeProfile(existingID: editingConnectionID)
                    store.saveConnection(
                        profile: profile,
                        credential: draft.credential,
                        makeActive: store.activeConnectionID == nil || editingConnectionID == store.activeConnectionID
                    )
                    dismiss()
                }
            }
        }
    }

    private var editorTitle: String {
        if editingConnectionID != nil {
            return "Edit Profile"
        }
        return draft.host.nilIfBlank == nil ? "New Host" : "New Profile"
    }

    @ViewBuilder
    private var profileScopeHelp: some View {
        if let customHermesHomePath = draft.trimmedCustomHermesHomePath {
            Text("Usa la home Hermes \(customHermesHomePath). Lascia vuoto Hermes Profile Name quando usi una home personalizzata.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if let hermesProfile = draft.trimmedHermesProfile {
            Text("Usa il profilo Hermes \(hermesProfile). Il suo file di configurazione è ~/.hermes/profiles/\(hermesProfile)/.env.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text("Usa il profilo default. Il suo file di configurazione è ~/.hermes/.env.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
