import Foundation
import UIKit

struct MountedFolder: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let path: String
    let bookmarkData: Data
    let createdAt: Date
    var isAccessible: Bool
}

final class BookmarkManager: ObservableObject {
    static let shared = BookmarkManager()

    private let storageKey = "com.yangjiii.3105.mounted_folders.v1"
    private let lock = NSLock()
    private var activeSecurityScopedURLs: [String: URL] = [:]

    @Published private(set) var mountedFolders: [MountedFolder] = []

    private init() {
        loadPersistedFolders()
        activateAllBookmarks()
    }

    deinit {
        stopAllAccess()
    }

    // MARK: - Persistence

    private func loadPersistedFolders() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([MountedFolder].self, from: data) else {
            mountedFolders = []
            return
        }
        mountedFolders = decoded
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(mountedFolders) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Save Bookmark

    @discardableResult
    func saveBookmark(for url: URL, customName: String? = nil) throws -> MountedFolder {
        lock.lock()
        defer { lock.unlock() }

        _ = url.startAccessingSecurityScopedResource()

        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        let canonicalPath = canonicalURL.path

        let bookmarkData = try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: [.isDirectoryKey, .nameKey],
            relativeTo: nil
        )

        let displayName = customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? customName!
            : url.lastPathComponent

        // Replace existing entry if matching path
        if let index = mountedFolders.firstIndex(where: {
            $0.path.caseInsensitiveCompare(canonicalPath) == .orderedSame
        }) {
            let updated = MountedFolder(
                id: mountedFolders[index].id,
                name: displayName,
                path: canonicalPath,
                bookmarkData: bookmarkData,
                createdAt: mountedFolders[index].createdAt,
                isAccessible: true
            )
            mountedFolders[index] = updated
            activeSecurityScopedURLs[canonicalPath] = url
            persistFolders()
            return updated
        }

        let newFolder = MountedFolder(
            id: UUID(),
            name: displayName,
            path: canonicalPath,
            bookmarkData: bookmarkData,
            createdAt: Date(),
            isAccessible: true
        )
        mountedFolders.append(newFolder)
        activeSecurityScopedURLs[canonicalPath] = url
        persistFolders()
        return newFolder
    }

    func removeBookmark(id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        guard let index = mountedFolders.firstIndex(where: { $0.id == id }) else { return }
        let folder = mountedFolders[index]
        if let activeURL = activeSecurityScopedURLs.removeValue(forKey: folder.path) {
            activeURL.stopAccessingSecurityScopedResource()
        }
        mountedFolders.remove(at: index)
        persistFolders()
    }

    // MARK: - Security Scope Activation

    func activateAllBookmarks() {
        lock.lock()
        defer { lock.unlock() }

        for (index, folder) in mountedFolders.enumerated() {
            var isStale = false
            guard let resolvedURL = try? URL(
                resolvingBookmarkData: folder.bookmarkData,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                mountedFolders[index].isAccessible = false
                continue
            }

            let started = resolvedURL.startAccessingSecurityScopedResource()
            if started {
                let canonicalPath = resolvedURL.resolvingSymlinksInPath().standardizedFileURL.path
                activeSecurityScopedURLs[canonicalPath] = resolvedURL
                activeSecurityScopedURLs[folder.path] = resolvedURL
                mountedFolders[index].isAccessible = true
            } else {
                mountedFolders[index].isAccessible = false
            }

            if isStale {
                if let refreshedData = try? resolvedURL.bookmarkData(
                    options: [.minimalBookmark],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    mountedFolders[index] = MountedFolder(
                        id: folder.id,
                        name: folder.name,
                        path: folder.path,
                        bookmarkData: refreshedData,
                        createdAt: folder.createdAt,
                        isAccessible: started
                    )
                }
            }
        }
        persistFolders()
    }

    func stopAllAccess() {
        lock.lock()
        defer { lock.unlock() }

        for (_, url) in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    // MARK: - Scoped Execution

    func resolveActiveURL(for path: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        let normalized = (path as NSString).standardizingPath
        if let direct = activeSecurityScopedURLs[normalized] {
            return direct
        }

        // Check if path is a child of any active mount
        for (mountPath, mountURL) in activeSecurityScopedURLs {
            let cleanMount = mountPath.hasSuffix("/") ? mountPath : mountPath + "/"
            let cleanTarget = normalized.hasSuffix("/") ? normalized : normalized + "/"
            if cleanTarget.hasPrefix(cleanMount) {
                let relative = String(normalized.dropFirst(cleanMount.count))
                return mountURL.appendingPathComponent(relative)
            }
        }
        return nil
    }

    func isUnderActiveScope(path: String) -> Bool {
        resolveActiveURL(for: path) != nil
    }

    func withSecurityScope<T>(for path: String, block: (URL) throws -> T) rethrows -> T {
        if let scopedURL = resolveActiveURL(for: path) {
            let started = scopedURL.startAccessingSecurityScopedResource()
            defer { if started { scopedURL.stopAccessingSecurityScopedResource() } }
            return try block(scopedURL)
        } else {
            let directURL = URL(fileURLWithPath: path)
            let started = directURL.startAccessingSecurityScopedResource()
            defer { if started { directURL.stopAccessingSecurityScopedResource() } }
            return try block(directURL)
        }
    }
}
