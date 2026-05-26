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
        authKind = connection.authKind
        password = credential.password ?? ""
        privateKey = credential.privateKey ?? ""
        passphrase = credential.passphrase ?? ""
    }

    func makeProfile(existingID: UUID?) -> ConnectionProfile {
        ConnectionProfile(
            id: existingID ?? UUID(),
            label: label.nilIfBlank ?? host.nilIfBlank ?? "Hermes Host",
            sshAlias: "",
            sshHost: host,
            sshPort: Int(port),
            sshUser: user,
            hermesProfile: nil,
            customHermesHomePath: nil,
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
                TextField("Display Name", text: $draft.label)
                TextField("Host or IP", text: $draft.host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("SSH Port", text: $draft.port)
                    .keyboardType(.numberPad)
                TextField("SSH User", text: $draft.user)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("Add the SSH host once. Hermes profiles on this host are discovered automatically after connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    let editsActiveHost = editingConnectionID.map { editedID in
                        store.activeHostConnections.contains { $0.id == editedID }
                    } ?? false
                    store.saveConnection(
                        profile: profile,
                        credential: draft.credential,
                        makeActive: store.activeConnectionID == nil || editingConnectionID == store.activeConnectionID || editsActiveHost
                    )
                    dismiss()
                }
            }
        }
    }

    private var editorTitle: String {
        if editingConnectionID != nil {
            return "Edit Host"
        }
        return "New Host"
    }

}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
