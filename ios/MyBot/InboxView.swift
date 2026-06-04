//
//  FilesListView.swift
//  Northbase
//

import SwiftUI
import Supabase

// MARK: - Models

struct FileMeta: Identifiable, Decodable {
    let id: UUID
    let path: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, path
        case updatedAt = "updated_at"
    }
}

enum NavDestination: Hashable {
    case folder(String)   // prefix ending with "/", e.g. "tasks/"
    case file(String)     // full path, e.g. "tasks/today.md"
}

// MARK: - Cache

struct CachedMeta: Codable {
    var updatedAt: Date        // last remote updated_at we successfully synced
    var pendingSync: Bool      // local edits not yet uploaded to Supabase
    var hasConflict: Bool      // remote changed since our pending local edit
    var localEditedAt: Date?   // when local edit was made

    init(updatedAt: Date,
         pendingSync: Bool = false,
         hasConflict: Bool = false,
         localEditedAt: Date? = nil) {
        self.updatedAt = updatedAt
        self.pendingSync = pendingSync
        self.hasConflict = hasConflict
        self.localEditedAt = localEditedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt     = try c.decode(Date.self, forKey: .updatedAt)
        pendingSync   = try c.decodeIfPresent(Bool.self, forKey: .pendingSync) ?? false
        hasConflict   = try c.decodeIfPresent(Bool.self, forKey: .hasConflict) ?? false
        localEditedAt = try c.decodeIfPresent(Date.self, forKey: .localEditedAt)
    }

    enum CodingKeys: String, CodingKey {
        case updatedAt, pendingSync, hasConflict, localEditedAt
    }
}

struct FileContentRow: Decodable { let content: String }

struct FetchTimeoutError: LocalizedError {
    var errorDescription: String? { "Request timed out" }
}

let listTTL:       TimeInterval = 30
let fetchTimeoutSec: Double     = 8

// MARK: - Helpers

/// Returns the direct subfolders and direct files at `prefix`.
/// e.g. prefix="", files=["inbox.md","tasks/today.md","tasks/sub/x.md"]
/// → folders=["tasks"], files=["inbox.md"]
private func folderContents(prefix: String, in files: [FileMeta])
    -> (folders: [String], files: [FileMeta])
{
    var folders = Set<String>()
    var directFiles: [FileMeta] = []

    for file in files {
        guard file.path.hasPrefix(prefix) else { continue }
        let remainder = String(file.path.dropFirst(prefix.count))
        if let slash = remainder.firstIndex(of: "/") {
            let name = String(remainder[..<slash])
            if !name.isEmpty { folders.insert(name) }
        } else if !remainder.isEmpty {
            directFiles.append(file)
        }
    }
    return (folders: folders.sorted(), files: directFiles)
}

/// File name without extension: "ideas.md" → "ideas", "script.py" → "script"
private func displayName(for path: String) -> String {
    let filename: String
    if let idx = path.lastIndex(of: "/") {
        filename = String(path[path.index(after: idx)...])
    } else {
        filename = path
    }
    if let dot = filename.lastIndex(of: ".") {
        return String(filename[..<dot])
    }
    return filename
}

/// Conditionally applies .searchable — only root FolderView gets a search bar.
/// Subfolders must not have their own UISearchController or they flash during
/// NavigationStack push/pop transitions.
/// Total files whose path starts with `prefix`.
private func itemCount(prefix: String, in files: [FileMeta]) -> Int {
    files.filter { $0.path.hasPrefix(prefix) }.count
}

/// Trim, collapse "//", strip leading/trailing "/", auto-append ".md" if no extension.
/// Does NOT filter ".." — validation does that.
private func normalizePath(_ raw: String) -> String {
    var s = raw.trimmingCharacters(in: .whitespaces)
    while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !s.isEmpty {
        let parts = s.split(separator: "/", omittingEmptySubsequences: true)
        if let last = parts.last, !last.contains(".") { s += ".md" }
    }
    return s
}

private func formatDate(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    } else if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 {
        return date.formatted(.dateTime.weekday(.wide))
    } else {
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

private func dateGroup(for date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date)     { return "Today" }
    if cal.isDateInYesterday(date) { return "Yesterday" }
    let days = cal.dateComponents([.day], from: date, to: .now).day ?? 0
    if days < 7                    { return "Previous 7 Days" }
    if days < 30                   { return "Previous 30 Days" }
    return "Earlier"
}

// MARK: - FilesStore

@MainActor
final class FilesStore: ObservableObject {
    @Published var files: [FileMeta] = []
    @Published var isLoading = false
    @Published var isInitialLoadComplete = false
    @Published var fetchError: String?

    private let userID: String
    private var diskIndex: [String: CachedMeta] = [:]
    private var listFetchedAt: Date?
    private var isFetching = false

    init() {
        self.userID = supabase.auth.currentUser?.id.uuidString ?? "unknown-user"
        loadDiskIndex()
        preloadFromDisk()
    }

    private func preloadFromDisk() {
        guard !diskIndex.isEmpty else { return }
        files = diskIndex.map { path, meta in
            FileMeta(id: UUID(), path: path, updatedAt: meta.updatedAt)
        }.sorted { $0.updatedAt > $1.updatedAt }
        print("NB: preloaded \(files.count) files from disk index (offline fallback)")
    }

    // MARK: List

    func fetch(force: Bool = false) async {
        guard !isFetching else {
            print("NB: list fetch skipped (in-flight)")
            return
        }
        if !force, let t = listFetchedAt, Date().timeIntervalSince(t) < listTTL {
            print("NB: list fetch skipped (fresh)")
            return
        }
        isFetching = true
        isLoading = true
        fetchError = nil
        do {
            files = try await supabase
                .from("files")
                .select("id, path, updated_at")
                .order("updated_at", ascending: false)
                .execute()
                .value
            listFetchedAt = Date()
            print("NB: list fetched (\(files.count) files)")
            pruneStaleCacheEntries(remotePaths: Set(files.map(\.path)))
        } catch {
            fetchError = error.localizedDescription
        }
        isLoading = false
        isFetching = false
        if !isInitialLoadComplete { isInitialLoadComplete = true }
    }

    @discardableResult
    func optimisticRemove(_ file: FileMeta) -> Int {
        let index = files.firstIndex(where: { $0.id == file.id }) ?? files.count
        files.removeAll { $0.id == file.id }
        return index
    }

    func restore(_ file: FileMeta, at index: Int) {
        files.insert(file, at: min(index, files.count))
    }

    @discardableResult
    func optimisticRemoveFolder(prefix: String) -> [FileMeta] {
        let safePrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        let removed = files.filter { $0.path.hasPrefix(safePrefix) }
        files.removeAll { $0.path.hasPrefix(safePrefix) }
        return removed
    }

    func restoreFiles(_ filesToRestore: [FileMeta]) {
        files.append(contentsOf: filesToRestore)
        files.sort { $0.updatedAt > $1.updatedAt }
    }

    func delete(_ file: FileMeta) async throws {
        try await supabase
            .from("files")
            .delete()
            .eq("id", value: file.id.uuidString)
            .execute()
        try? FileManager.default.removeItem(at: diskPath(for: file.path))
        diskIndex.removeValue(forKey: file.path)
        saveDiskIndex()
    }

    func deleteFolder(prefix: String) async throws {
        let safePrefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        try await supabase
            .from("files")
            .delete()
            .like("path", value: "\(safePrefix)%")
            .execute()
        let cacheKeys = diskIndex.keys.filter { $0.hasPrefix(safePrefix) }
        for key in cacheKeys {
            try? FileManager.default.removeItem(at: diskPath(for: key))
            diskIndex.removeValue(forKey: key)
        }
        saveDiskIndex()
    }

    func rename(_ file: FileMeta, to newPath: String) async throws {
        try await supabase
            .from("files")
            .update(["path": newPath])
            .eq("id", value: file.id.uuidString)
            .execute()
        if let idx = files.firstIndex(where: { $0.id == file.id }) {
            files[idx] = FileMeta(id: file.id, path: newPath, updatedAt: file.updatedAt)
        }
        try? FileManager.default.removeItem(at: diskPath(for: file.path))
        diskIndex.removeValue(forKey: file.path)
        saveDiskIndex()
    }

    func renameFolder(from oldPrefix: String, to newPrefix: String) async throws {
        let safeOld = oldPrefix.hasSuffix("/") ? oldPrefix : oldPrefix + "/"
        let safeNew = newPrefix.hasSuffix("/") ? newPrefix : newPrefix + "/"
        let affected = files.filter { $0.path.hasPrefix(safeOld) }
        for file in affected {
            let newPath = safeNew + String(file.path.dropFirst(safeOld.count))
            try await supabase
                .from("files")
                .update(["path": newPath])
                .eq("id", value: file.id.uuidString)
                .execute()
            if let idx = files.firstIndex(where: { $0.id == file.id }) {
                files[idx] = FileMeta(id: file.id, path: newPath, updatedAt: file.updatedAt)
            }
            try? FileManager.default.removeItem(at: diskPath(for: file.path))
            diskIndex.removeValue(forKey: file.path)
        }
        saveDiskIndex()
    }

    // MARK: Disk cache

    private func diskCacheDir() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UserCaches")
            .appendingPathComponent(userID)
            .appendingPathComponent("CachedFiles")
    }

    private func diskIndexURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UserCaches")
            .appendingPathComponent(userID)
            .appendingPathComponent("fileIndex.json")
    }

    private func loadDiskIndex() {
        guard let data = try? Data(contentsOf: diskIndexURL()) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        diskIndex = (try? decoder.decode([String: CachedMeta].self, from: data)) ?? [:]
        print("NB: disk index loaded (\(diskIndex.count) entries)")
    }

    private func pruneStaleCacheEntries(remotePaths: Set<String>) {
        let staleKeys = diskIndex.keys.filter { !remotePaths.contains($0) }
        guard !staleKeys.isEmpty else { return }
        for key in staleKeys {
            try? FileManager.default.removeItem(at: diskPath(for: key))
            diskIndex.removeValue(forKey: key)
        }
        saveDiskIndex()
        print("NB: pruned \(staleKeys.count) stale cache entries")
    }

    private func saveDiskIndex() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(diskIndex) else { return }
        try? data.write(to: diskIndexURL())
    }

    func diskPath(for path: String) -> URL {
        diskCacheDir().appendingPathComponent(path)
    }

    func readDiskContent(path: String) -> String? {
        guard diskIndex[path] != nil else { return nil }
        return try? String(contentsOf: diskPath(for: path), encoding: .utf8)
    }

    func writeDiskContent(path: String, content: String, updatedAt: Date) {
        let fileURL = diskPath(for: path)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        diskIndex[path] = CachedMeta(updatedAt: updatedAt)
        saveDiskIndex()
        print("MYBOT disk-write: \(path)")
    }

    func needsRefresh(path: String) -> Bool {
        guard let cached = diskIndex[path] else { return true }
        guard let remote = files.first(where: { $0.path == path }) else { return false }
        return remote.updatedAt != cached.updatedAt
    }

    func fetchContent(path: String) async throws -> String {
        print("NB: fetching content for \(path)")
        let result = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let rows: [FileContentRow] = try await supabase
                    .from("files").select("content")
                    .eq("path", value: path).limit(1).execute().value
                return rows.first?.content ?? ""
            }
            group.addTask {
                try await Task.sleep(for: .seconds(fetchTimeoutSec))
                throw FetchTimeoutError()
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
        let updatedAt = files.first(where: { $0.path == path })?.updatedAt ?? Date()
        writeDiskContent(path: path, content: result, updatedAt: updatedAt)
        return result
    }

    func fileExistsInList(path: String) -> Bool { files.contains { $0.path == path } }

    func upsertMeta(path: String, updatedAt: Date) {
        if let idx = files.firstIndex(where: { $0.path == path }) {
            files[idx] = FileMeta(id: files[idx].id, path: path, updatedAt: updatedAt)
        } else {
            files.append(FileMeta(id: UUID(), path: path, updatedAt: updatedAt))
        }
        files.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: Offline / pending sync

    func saveLocalPending(path: String, content: String) {
        let fileURL = diskPath(for: path)
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        let existingUpdatedAt = diskIndex[path]?.updatedAt ?? Date(timeIntervalSince1970: 0)
        diskIndex[path] = CachedMeta(updatedAt: existingUpdatedAt,
                                     pendingSync: true,
                                     localEditedAt: Date())
        saveDiskIndex()
        print("NB offline-save: \(path) (pending sync)")
    }

    func setPendingConflict(path: String) {
        guard var meta = diskIndex[path] else { return }
        meta.hasConflict = true
        diskIndex[path] = meta
        saveDiskIndex()
        print("NB conflict: \(path)")
    }

    func isPendingSync(path: String) -> Bool { diskIndex[path]?.pendingSync ?? false }
    func hasConflict(path: String)   -> Bool { diskIndex[path]?.hasConflict ?? false }
    func lastKnownRemoteUpdatedAt(path: String) -> Date? { diskIndex[path]?.updatedAt }

    func fetchRemoteUpdatedAt(path: String) async throws -> Date? {
        struct UpdatedAtRow: Decodable {
            let updatedAt: Date
            enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
        }
        let rows: [UpdatedAtRow] = try await supabase
            .from("files")
            .select("updated_at")
            .eq("path", value: path)
            .limit(1)
            .execute()
            .value
        return rows.first?.updatedAt
    }

    func forceSyncLocalVersion(path: String, content: String) async throws {
        struct Row: Decodable {
            let updatedAt: Date
            enum CodingKeys: String, CodingKey { case updatedAt = "updated_at" }
        }
        let rows: [Row] = try await supabase
            .from("files")
            .update(["content": content])
            .eq("path", value: path)
            .select("updated_at")
            .execute()
            .value
        if let saved = rows.first {
            writeDiskContent(path: path, content: content, updatedAt: saved.updatedAt)
            upsertMeta(path: path, updatedAt: saved.updatedAt)
        }
        print("NB force-sync: \(path) (keep mine)")
    }

    func discardLocalAndFetchRemote(path: String) async throws -> String {
        let remote = try await fetchContent(path: path)
        print("NB discard-local: \(path) (use remote)")
        return remote
    }
}

// MARK: - FilesListView (root)

struct FilesListView: View {
    @StateObject private var store = FilesStore()

    var body: some View {
        NavigationStack {
            FolderView(prefix: "")
                .navigationDestination(for: NavDestination.self) { dest in
                    switch dest {
                    case .folder(let p):  FolderView(prefix: p)
                    case .file(let path): FileEditorView(path: path)
                    }
                }
        }
        .environmentObject(store)
        .task { await store.fetch(force: true) }
    }
}

// MARK: - FolderView

struct FolderView: View {
    let prefix: String

    @EnvironmentObject private var store: FilesStore
    @EnvironmentObject private var auth: AuthStore

    @State private var searchText = ""
    @State private var showSettingsSheet = false
    @FocusState private var searchFocused: Bool
    @Namespace private var bottomBarNamespace
    @State private var showNewFileSheet = false
    @State private var pendingNewFilePath: String?
    @State private var pendingNavigation: NavDestination?

    @State private var showNewFolderSheet = false
    @State private var pendingNewFolderName: String?

    @State private var showRenameAlert = false
    @State private var renamingFile: FileMeta?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var fileToDelete: FileMeta?
    @State private var showDeleteConfirm = false
    @State private var fileDeleteError: String?
    @State private var fileDeleteRestoreIndex: Int = 0
    @State private var folderToDelete: String?
    @State private var showFolderDeleteConfirm = false
    @State private var folderDeleteRemovedFiles: [FileMeta] = []
    @State private var renamingFolder: String?
    @State private var showFolderRenameAlert = false
    @State private var folderRenameText = ""
    @State private var folderRenameError: String?

    // MARK: Computed

    private var folderTitle: String {
        if prefix.isEmpty { return "Files" }
        let stripped = prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        return stripped.split(separator: "/").last.map(String.init) ?? "Folder"
    }

    private var contents: (folders: [String], files: [FileMeta]) {
        folderContents(prefix: prefix, in: store.files)
    }

    private var searchResults: [FileMeta] {
        let scope = prefix.isEmpty
            ? store.files
            : store.files.filter { $0.path.hasPrefix(prefix) }
        return scope.filter { file in
            file.path
                .dropFirst(prefix.count)
                .localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedFiles: [(group: String, files: [FileMeta])] {
        let order = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Earlier"]
        let grouped = Dictionary(grouping: contents.files) { dateGroup(for: $0.updatedAt) }
        return order.compactMap { key in
            guard let files = grouped[key], !files.isEmpty else { return nil }
            return (group: key, files: files)
        }
    }

    private var isSearchActive: Bool { searchFocused || !searchText.isEmpty }

    @ViewBuilder
    private var bottomBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                    TextField("Search", text: $searchText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($searchFocused)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("searchPill", in: bottomBarNamespace)

                if isSearchActive {
                    Button {
                        searchText = ""
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("actionButton", in: bottomBarNamespace)
                } else {
                    Button { showNewFileSheet = true } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("actionButton", in: bottomBarNamespace)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .animation(.easeInOut(duration: 0.2), value: isSearchActive)
    }

    // MARK: Body

    var body: some View {
        Group {
            if !store.isInitialLoadComplete {
                ProgressView()
            } else if let err = store.fetchError, store.files.isEmpty {
                errorView(err)
            } else {
                folderList
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .navigationTitle(folderTitle)
        .navigationBarTitleDisplayMode(prefix.isEmpty ? .large : .inline)
        .onAppear {
            searchText = ""
            Task { await store.fetch() }
        }
        .onDisappear { searchText = "" }
        .toolbar {
            if prefix.isEmpty, store.fetchError != nil, !store.files.isEmpty {
                ToolbarItem(placement: .navigationBarLeading) {
                    Label("Offline", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if prefix.isEmpty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            Button { showNewFolderSheet = true } label: {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 15, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                            }
                            .glassEffect(.regular.interactive(), in: .capsule)
                            Button { showSettingsSheet = true } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 15, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                            }
                            .glassEffect(.regular.interactive(), in: .capsule)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showNewFolderSheet = true } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            SettingsView(auth: auth)
        }
        .sheet(isPresented: $showNewFileSheet, onDismiss: {
            if let p = pendingNewFilePath {
                pendingNavigation = .file(p)
                pendingNewFilePath = nil
            }
        }) {
            NewFileSheet(existingPaths: store.files.map(\.path), initialPrefix: prefix) { path in
                pendingNewFilePath = path
            }
        }
        .sheet(isPresented: $showNewFolderSheet, onDismiss: {
            if let name = pendingNewFolderName {
                pendingNavigation = .folder(prefix + name + "/")
                pendingNewFolderName = nil
            }
        }) {
            NewFolderSheet(existingFiles: store.files, prefix: prefix) { name in
                pendingNewFolderName = name
            }
        }
        .navigationDestination(item: $pendingNavigation) { dest in
            switch dest {
            case .folder(let p): FolderView(prefix: p)
            case .file(let path): FileEditorView(path: path)
            }
        }
        .alert("Rename", isPresented: $showRenameAlert) {
            TextField("New path", text: $renameText).autocorrectionDisabled()
            Button("Rename") { Task { await commitRename() } }
            Button("Cancel", role: .cancel) { renamingFile = nil; renameError = nil }
        } message: {
            if let e = renameError { Text(e) }
        }
        .alert(
            "Delete \"\(fileToDelete.map { displayName(for: $0.path) } ?? "")\"?",
            isPresented: $showDeleteConfirm
        ) {
            Button("Delete", role: .destructive) { Task { await commitDelete() } }
            Button("Cancel", role: .cancel) {
                if let f = fileToDelete { store.restore(f, at: fileDeleteRestoreIndex) }
            }
        }
        .alert("Couldn't Delete File", isPresented: Binding(
            get: { fileDeleteError != nil },
            set: { if !$0 { fileDeleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let e = fileDeleteError { Text(e) }
        }
        .alert("Delete Folder?", isPresented: $showFolderDeleteConfirm) {
            Button("Delete", role: .destructive) { Task { await commitFolderDelete() } }
            Button("Cancel", role: .cancel) {
                store.restoreFiles(folderDeleteRemovedFiles)
            }
        } message: {
            Text("This will permanently delete this folder and all files inside it. This cannot be undone.")
        }
        .alert("Rename Folder", isPresented: $showFolderRenameAlert) {
            TextField("Folder name", text: $folderRenameText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Rename") { Task { await commitFolderRename() } }
            Button("Cancel", role: .cancel) { renamingFolder = nil; folderRenameError = nil }
        } message: {
            if let e = folderRenameError { Text(e) }
        }
    }

    // MARK: Folder list (normal browsing)

    private var folderList: some View {
        Group {
            if contents.folders.isEmpty && contents.files.isEmpty && searchText.isEmpty {
                ContentUnavailableView {
                    Label("No Notes", systemImage: "doc.text")
                } description: {
                    Text("Tap the compose button to create your first note.")
                }
            } else {
                List {
                    if !searchText.isEmpty {
                        Section("Results") {
                            ForEach(searchResults) { file in
                                fileRow(file, subtitleOverride: file.path)
                            }
                        }
                    } else {
                        if !contents.folders.isEmpty {
                            Section("Folders") {
                                ForEach(contents.folders, id: \.self) { folder in
                                    folderRow(folder)
                                }
                            }
                        }
                        if prefix.isEmpty {
                            ForEach(groupedFiles, id: \.group) { bucket in
                                Section(bucket.group) {
                                    ForEach(bucket.files) { file in
                                        fileRow(file)
                                    }
                                }
                            }
                        } else if !contents.files.isEmpty {
                            Section("In this folder") {
                                ForEach(contents.files) { file in
                                    fileRow(file)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable { await store.fetch(force: true) }
                .overlay {
                    if !searchText.isEmpty && searchResults.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
            }
        }
    }

    // MARK: Rows

    private func folderRow(_ folder: String) -> some View {
        let subPrefix = prefix + folder + "/"
        let count = itemCount(prefix: subPrefix, in: store.files)
        return NavigationLink(value: NavDestination.folder(subPrefix)) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                Text(folder)
                    .font(.body).fontWeight(.medium).lineLimit(1)
                Spacer()
                Text("\(count) \(count == 1 ? "file" : "files")")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 10)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                folderDeleteRemovedFiles = store.optimisticRemoveFolder(prefix: subPrefix)
                folderToDelete = subPrefix
                showFolderDeleteConfirm = true
            } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button {
                renamingFolder = subPrefix
                folderRenameText = folder
                folderRenameError = nil
                showFolderRenameAlert = true
            } label: { Label("Rename", systemImage: "pencil") }
            .tint(.orange)
        }
    }

    private func fileRow(_ file: FileMeta, subtitleOverride: String? = nil) -> some View {
        NavigationLink(value: NavDestination.file(file.path)) {
            HStack(alignment: .firstTextBaseline) {
                Text(displayName(for: file.path))
                    .font(.body).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 16)
                Text(subtitleOverride ?? formatDate(file.updatedAt))
                    .font(.caption).foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
            .padding(.vertical, 10)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                fileDeleteRestoreIndex = store.optimisticRemove(file)
                fileToDelete = file
                showDeleteConfirm = true
            } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            Button {
                renamingFile = file
                renameText = file.path.hasSuffix(".md") ? String(file.path.dropLast(3)) : file.path
                renameError = nil
                showRenameAlert = true
            } label: { Label("Rename", systemImage: "pencil") }
            .tint(.orange)
        }
    }

    // MARK: Error view

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await store.fetch(force: true) } }
                .buttonStyle(.bordered)
        }
        .padding(40)
    }

    // MARK: Actions

    private func commitDelete() async {
        guard let file = fileToDelete else { return }
        fileToDelete = nil
        do {
            try await store.delete(file)
        } catch {
            store.restore(file, at: fileDeleteRestoreIndex)
            fileDeleteError = error.localizedDescription
        }
    }

    private func commitFolderDelete() async {
        guard let folder = folderToDelete else { return }
        folderToDelete = nil
        do {
            try await store.deleteFolder(prefix: folder)
        } catch {
            store.restoreFiles(folderDeleteRemovedFiles)
        }
    }

    private func commitFolderRename() async {
        guard let oldPrefix = renamingFolder else { return }
        let name = folderRenameText.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { folderRenameError = "Enter a folder name"; return }
        guard !name.contains("/"), name != "..", name != "." else {
            folderRenameError = "Invalid folder name"; return
        }
        let newPrefix = prefix + name + "/"
        guard newPrefix != oldPrefix else { renamingFolder = nil; return }
        guard !store.files.contains(where: { $0.path.hasPrefix(newPrefix) }) else {
            folderRenameError = "A folder with that name already exists"; return
        }
        do {
            try await store.renameFolder(from: oldPrefix, to: newPrefix)
            renamingFolder = nil
        } catch {
            folderRenameError = error.localizedDescription
        }
    }

    private func commitRename() async {
        guard let file = renamingFile else { return }
        let newPath = normalizePath(renameText)
        guard !newPath.isEmpty else { renameError = "Name can't be empty"; return }
        guard !store.files.contains(where: { $0.path == newPath && $0.id != file.id }) else {
            renameError = "A file with that name already exists"; return
        }
        do {
            try await store.rename(file, to: newPath)
            renamingFile = nil
        } catch {
            renameError = error.localizedDescription
        }
    }
}

// MARK: - NewFileSheet

struct NewFileSheet: View {
    let existingPaths: [String]
    let initialPrefix: String
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input: String
    @State private var validationError: String?

    init(existingPaths: [String], initialPrefix: String, onCreate: @escaping (String) -> Void) {
        self.existingPaths = existingPaths
        self.initialPrefix = initialPrefix
        self.onCreate = onCreate
        _input = State(initialValue: initialPrefix)
    }

    private var normalized: String { normalizePath(input) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .padding(.bottom, 4)
                    Text("New File")
                        .font(.headline)
                    Text("Type a name" + (initialPrefix.isEmpty ? "" : " in \(initialPrefix)") + ", or a path like tasks/today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 28)
                .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 6) {
                    TextField(
                        initialPrefix.isEmpty ? "notes or tasks/today" : initialPrefix + "…",
                        text: $input
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onSubmit { validate() }

                    if let e = validationError {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(e)
                        }
                        .font(.caption).foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.18), value: validationError)

                Spacer()

                VStack(spacing: 10) {
                    Button { validate() } label: {
                        Text("Create").appPrimaryButton()
                    }
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
            .navigationBarHidden(true)
        }
        .presentationDetents([.height(360)])
        .presentationCornerRadius(20)
    }

    private func validate() {
        let path = normalized
        if path.isEmpty { validationError = "Enter a file name"; return }
        let parts = path.split(separator: "/")
        if parts.contains("..") || parts.contains(".") { validationError = "Invalid path"; return }
        if existingPaths.contains(path) { validationError = "A file with that name already exists"; return }
        dismiss()
        onCreate(path)
    }
}

// MARK: - NewFolderSheet

struct NewFolderSheet: View {
    let existingFiles: [FileMeta]
    let prefix: String
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                        .padding(.bottom, 4)
                    Text("New Folder")
                        .font(.headline)
                    Text("Create a folder" + (prefix.isEmpty ? "" : " in \(prefix)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
                .padding(.top, 28)
                .padding(.bottom, 24)

                VStack(alignment: .leading, spacing: 6) {
                    TextField("Folder name", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onSubmit { validate() }

                    if let e = validationError {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(e)
                        }
                        .font(.caption).foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.horizontal, 24)
                .animation(.easeInOut(duration: 0.18), value: validationError)

                Spacer()

                VStack(spacing: 10) {
                    Button { validate() } label: {
                        Text("Create").appPrimaryButton()
                    }
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity)
            .navigationBarHidden(true)
        }
        .presentationDetents([.height(360)])
        .presentationCornerRadius(20)
    }

    private func validate() {
        let name = input.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { validationError = "Enter a folder name"; return }
        if name.contains("/") || name == ".." || name == "." {
            validationError = "Invalid folder name"; return
        }
        let newPrefix = prefix + name + "/"
        if existingFiles.contains(where: { $0.path.hasPrefix(newPrefix) }) {
            validationError = "A folder with that name already exists"; return
        }
        dismiss()
        onCreate(name)
    }
}
