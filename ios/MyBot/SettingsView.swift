//
//  SettingsView.swift
//  Northbase
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var auth: AuthStore
    @AppStorage("colorSchemePreference") private var colorSchemeRaw = 0
    @State private var showDeleteConfirm = false

    private var userEmail: String {
        supabase.auth.currentUser?.email ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Email", value: userEmail)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $colorSchemeRaw) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button("Sign Out") {
                        Task { await auth.signOut() }
                    }
                }

                Section("Danger Zone") {
                    if let err = auth.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button("Delete Account", role: .destructive) {
                        auth.errorMessage = nil
                        showDeleteConfirm = true
                    }
                    .disabled(auth.isWorking)
                }
            }
            .navigationTitle("Settings")
            .alert("Delete Account?", isPresented: $showDeleteConfirm) {
                Button("Delete Account", role: .destructive) {
                    Task { await auth.deleteAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes your account and all notes. This cannot be undone.")
            }
        }
    }
}
