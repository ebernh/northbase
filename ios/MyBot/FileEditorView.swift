//
//  FileEditorView.swift
//  Northbase
//

import SwiftUI

private enum OfflineStatus: Equatable {
    case none
    case offlineCached   // opened from disk cache while offline
    case savedLocally    // local edit not yet uploaded to Supabase
    case conflict        // remote updated_at changed since our local edit
}

private enum SaveState: Equatable {
    case idle, saving, saved, savedLocally
    case error(String)
}

private struct SavedFileRow: Decodable {
    let updatedAt: Date
    enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
}

struct FileEditorView: View {
    let path: String

    @EnvironmentObject private var store: FilesStore

    @State private var content = ""
    @State private var baselineContent = ""
    @State private var showInitialLoader = false
    @State private var backgroundError: String?
    @State private var fileExists = false
    @State private var saveState: SaveState = .idle
    @State private var offlineStatus: OfflineStatus = .none
    @State private var conflictError: String?
    @State private var debounceTask: Task<Void, Never>?

    private var navTitle: String {
        let filename = path.split(separator: "/").last.map(String.init) ?? path
        if let dot = filename.lastIndex(of: ".") {
            return String(filename[..<dot])
        }
        return filename
    }

    var body: some View {
        Group {
            if showInitialLoader {
                ProgressView()
            } else {
                VStack(spacing: 0) {
                    TextEditor(text: $content)
                        .font(.body)
                        .lineSpacing(7)
                        .scrollContentBackground(.hidden)
                        .textSelection(.enabled)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .onChange(of: content) { _, _ in scheduleAutosave() }
                        .overlay(alignment: .topLeading) {
                            if content.isEmpty {
                                Text("Start typing…")
                                    .font(.body)
                                    .foregroundStyle(Color(.placeholderText))
                                    .padding(.horizontal, 25)
                                    .padding(.top, 12)
                                    .allowsHitTesting(false)
                            }
                        }

                    if offlineStatus == .conflict {
                        conflictBanner
                    } else if let msg = statusBannerMessage {
                        HStack(spacing: 6) {
                            Image(systemName: statusBannerIcon)
                            Text(msg)
                            if offlineStatus == .savedLocally {
                                Spacer()
                                Button("Retry") {
                                    Task {
                                        if content != baselineContent { await save() }
                                        else { await trySyncPending() }
                                    }
                                }
                                .font(.caption.weight(.medium))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(statusBannerColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .transition(.opacity)
                    }
                }
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                saveIndicator
            }
        }
        .task { await openFile() }
        .onDisappear {
            debounceTask?.cancel()
            if content != baselineContent, saveState != .saving {
                print("NB save-on-exit: \(path)")
                Task { await save() }
            }
        }
    }

    // MARK: - Status banner helpers

    private var statusBannerMessage: String? {
        switch offlineStatus {
        case .offlineCached: return "Offline — showing cached version"
        case .savedLocally:  return "Saved locally — not synced"
        case .conflict:      return nil   // handled by conflictBanner
        case .none:          return backgroundError
        }
    }

    @ViewBuilder
    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Conflict")
                        .fontWeight(.semibold)
                    Text("Remote version changed while you were offline.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)

            VStack(spacing: 10) {
                Button {
                    debounceTask?.cancel()
                    Task { await keepMine() }
                } label: {
                    Text("Keep My Version").appPrimaryButton()
                }
                .tint(.orange)

                Button {
                    debounceTask?.cancel()
                    Task { await useRemote() }
                } label: {
                    Text("Use Remote Version").appSecondaryButton()
                }
            }

            if let err = conflictError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(Color(.secondarySystemBackground))
        .transition(.opacity)
    }

    private var statusBannerIcon: String {
        switch offlineStatus {
        case .offlineCached: return "wifi.slash"
        case .savedLocally:  return "exclamationmark.icloud"
        case .conflict:      return "exclamationmark.triangle.fill"
        case .none:          return "exclamationmark.circle.fill"
        }
    }

    private var statusBannerColor: Color {
        switch offlineStatus {
        case .offlineCached: return .secondary
        case .savedLocally:  return .orange
        case .conflict:      return .red
        case .none:          return .secondary
        }
    }

    // MARK: - Save indicator (toolbar)

    @ViewBuilder
    private var saveIndicator: some View {
        switch saveState {
        case .idle:
            EmptyView()
        case .saving:
            ProgressView().scaleEffect(0.8)
        case .saved:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Saved")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .savedLocally:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.orange)
                Text("Local")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    // MARK: - Open

    private func openFile() async {
        if let diskContent = store.readDiskContent(path: path) {
            content = diskContent
            baselineContent = diskContent
            fileExists = store.fileExistsInList(path: path)
            print("NB disk-hit: \(path)")

            if store.hasConflict(path: path) {
                withAnimation { offlineStatus = .conflict }
                print("NB conflict-persisted: \(path)")
            } else if store.isPendingSync(path: path) {
                withAnimation { offlineStatus = .savedLocally }
                await trySyncPending()
            } else if store.needsRefresh(path: path) {
                await backgroundRefresh()
            } else {
                print("NB metadata-match: \(path)")
            }
        } else {
            showInitialLoader = true
            print("NB no disk cache for \(path), fetching")
            do {
                let fetched = try await store.fetchContent(path: path)
                content = fetched
                baselineContent = fetched
                fileExists = store.fileExistsInList(path: path)
            } catch {
                backgroundError = error.localizedDescription
            }
            showInitialLoader = false
        }
    }

    private func backgroundRefresh() async {
        guard !store.isPendingSync(path: path) else { return }
        let snapBeforeFetch = content
        print("NB remote-refresh: \(path)")
        do {
            let serverContent = try await store.fetchContent(path: path)
            if content == snapBeforeFetch, serverContent != content {
                content = serverContent
                baselineContent = serverContent
            }
        } catch {
            withAnimation { offlineStatus = .offlineCached }
            print("NB offline-open: \(path)")
        }
    }

    // MARK: - Pending sync

    private func trySyncPending() async {
        guard store.isPendingSync(path: path) else { return }
        print("NB pending-sync-retry: \(path)")
        do {
            let remoteUpdatedAt = try await store.fetchRemoteUpdatedAt(path: path)
            let localUpdatedAt  = store.lastKnownRemoteUpdatedAt(path: path)
            if remoteUpdatedAt == nil || remoteUpdatedAt == localUpdatedAt {
                // Safe — no one else edited, or file is brand new
                await save()
            } else {
                store.setPendingConflict(path: path)
                withAnimation { offlineStatus = .conflict }
                print("NB conflict: \(path)")
            }
        } catch {
            // Still offline — keep savedLocally state
            withAnimation { offlineStatus = .savedLocally }
            print("NB offline-still: \(path)")
        }
    }

    // MARK: - Conflict resolution

    private func keepMine() async {
        saveState = .saving
        conflictError = nil
        do {
            try await store.forceSyncLocalVersion(path: path, content: content)
            baselineContent = content
            withAnimation(.easeInOut(duration: 0.2)) { saveState = .saved; offlineStatus = .none }
            try? await Task.sleep(for: .seconds(2))
            if saveState == .saved { withAnimation(.easeInOut(duration: 0.2)) { saveState = .idle } }
        } catch {
            saveState = .idle
            conflictError = error.localizedDescription
        }
    }

    private func useRemote() async {
        saveState = .saving
        conflictError = nil
        do {
            let remote = try await store.discardLocalAndFetchRemote(path: path)
            content = remote
            baselineContent = remote
            withAnimation(.easeInOut(duration: 0.2)) { saveState = .idle; offlineStatus = .none }
        } catch {
            saveState = .idle
            conflictError = error.localizedDescription
        }
    }

    // MARK: - Save

    private func scheduleAutosave() {
        guard content != baselineContent else { return }
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(0.8))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    @MainActor
    private func save() async {
        saveState = .saving
        backgroundError = nil
        do {
            if fileExists {
                let rows: [SavedFileRow] = try await supabase
                    .from("files")
                    .update(["content": content])
                    .eq("path", value: path)
                    .select("updated_at")
                    .execute()
                    .value
                if let saved = rows.first {
                    store.writeDiskContent(path: path, content: content, updatedAt: saved.updatedAt)
                    store.upsertMeta(path: path, updatedAt: saved.updatedAt)
                }
            } else {
                let rows: [SavedFileRow] = try await supabase
                    .from("files")
                    .insert(["path": path, "content": content])
                    .select("updated_at")
                    .execute()
                    .value
                fileExists = true
                if let saved = rows.first {
                    store.writeDiskContent(path: path, content: content, updatedAt: saved.updatedAt)
                    store.upsertMeta(path: path, updatedAt: saved.updatedAt)
                }
            }
            baselineContent = content
            withAnimation(.easeInOut(duration: 0.2)) { saveState = .saved; offlineStatus = .none }
            try? await Task.sleep(for: .seconds(2))
            if saveState == .saved { withAnimation(.easeInOut(duration: 0.2)) { saveState = .idle } }
        } catch {
            store.saveLocalPending(path: path, content: content)
            baselineContent = content
            withAnimation(.easeInOut(duration: 0.2)) {
                saveState = .savedLocally
                offlineStatus = .savedLocally
            }
            print("NB offline-save: \(path) (fallback)")
        }
    }
}
