import CryptoKit
import Foundation
import ImageIO
import os
import Security
import SMBClient
import UIKit

// MARK: - Models

/// One SMB server the user added. The password never lives here: it is stored
/// in the Keychain under `id` and only materialized into a connection config
/// at the moment a session is opened.
struct SMBServer: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var domain: String
    var addedAt: Date

    var displayAddress: String {
        let hostPart = (host.contains(":") && !host.hasPrefix("[")) ? "[\(host)]" : host
        return port == 445 ? hostPart : "\(hostPart):\(port)"
    }
}

/// A folder inside an SMB share treated as one album. `path` is relative to
/// the share root, "" for the root itself, otherwise starting with "/".
struct SMBFolderAlbum: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var serverID: UUID
    var share: String
    var path: String
    var name: String
    var addedAt: Date

    var displayPath: String {
        path.isEmpty ? share : "\(share)\(path)"
    }
}

enum SMBServerLibrary {
    static let storageKey = "PhotoVault.smbServers.v1"

    // Image loads ask for the server record on every cache miss; decoding the
    // JSON each time was measurable on large grids. The only writers are in
    // this process and go through `save`, which refreshes the snapshot.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedServers: [SMBServer]?

    static func load() -> [SMBServer] {
        lock.lock()
        if let cachedServers {
            lock.unlock()
            return cachedServers
        }
        lock.unlock()

        let decoded: [SMBServer]
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let servers = try? JSONDecoder().decode([SMBServer].self, from: data) {
            decoded = servers
        } else {
            decoded = []
        }

        lock.lock()
        let value = cachedServers ?? decoded
        cachedServers = value
        lock.unlock()
        return value
    }

    static func save(_ servers: [SMBServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        lock.lock()
        cachedServers = servers
        lock.unlock()
        SMBConfiguration.invalidateAll()
    }

    static func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }
}

enum SMBFolderLibrary {
    static let storageKey = "PhotoVault.smbFolders.v1"

    // Same reason as `SMBServerLibrary`: every image request resolves its
    // album record, and re-decoding the stored JSON per request is pure
    // overhead. All writers share this process and refresh the snapshot.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedFolders: [SMBFolderAlbum]?

    static func load() -> [SMBFolderAlbum] {
        lock.lock()
        if let cachedFolders {
            lock.unlock()
            return cachedFolders
        }
        lock.unlock()

        let decoded: [SMBFolderAlbum]
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let folders = try? JSONDecoder().decode([SMBFolderAlbum].self, from: data) {
            decoded = folders
        } else {
            decoded = []
        }

        lock.lock()
        let value = cachedFolders ?? decoded
        cachedFolders = value
        lock.unlock()
        return value
    }

    static func save(_ folders: [SMBFolderAlbum]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        lock.lock()
        cachedFolders = folders
        lock.unlock()
    }

    /// A physical folder maps to exactly one album entry: re-adding the same
    /// server/share/path refreshes the existing row instead of appending a
    /// duplicate.
    @discardableResult
    static func add(server: SMBServer, share: String, path: String, name: String) -> (folders: [SMBFolderAlbum], album: SMBFolderAlbum, isNew: Bool) {
        var folders = load()
        if let index = folders.firstIndex(where: {
            $0.serverID == server.id && $0.share == share && $0.path == path
        }) {
            folders[index].name = name
            save(folders)
            return (folders, folders[index], false)
        }
        let album = SMBFolderAlbum(
            id: UUID(),
            serverID: server.id,
            share: share,
            path: path,
            name: name,
            addedAt: .now
        )
        folders.append(album)
        save(folders)
        return (folders, album, true)
    }

    @discardableResult
    static func remove(albumID: UUID) -> [SMBFolderAlbum] {
        var folders = load()
        guard let index = folders.firstIndex(where: { $0.id == albumID }) else { return folders }
        let removed = folders.remove(at: index)
        save(folders)
        SMBOriginalCache.purge(albumID: removed.id)
        LANFolderThumbnailDiskCache.purge(folderID: removed.id)
        LANFolderSessionCache.remove(id: removed.id)
        // The pooled connection belongs to the whole share: other albums on
        // it keep using it, so deleting one album must not force a re-login.
        return folders
    }

    /// Removing a server removes the server record, every album that pointed
    /// at it and its Keychain credential. Files on the server are never
    /// touched.
    @discardableResult
    static func remove(serverID: UUID) -> [SMBFolderAlbum] {
        var folders = load()
        let removed = folders.filter { $0.serverID == serverID }
        folders.removeAll { $0.serverID == serverID }
        save(folders)
        for album in removed {
            SMBOriginalCache.purge(albumID: album.id)
            LANFolderThumbnailDiskCache.purge(folderID: album.id)
            LANFolderSessionCache.remove(id: album.id)
        }
        SMBConnectionPool.shared.discardAll(serverID: serverID)
        SMBCredentialStore.delete(for: serverID)
        // The server row must disappear together with its albums; otherwise
        // it stays listed with no password and every attempt asks to log in.
        SMBServerLibrary.remove(id: serverID)
        return folders
    }
}

#if DEBUG
/// UI tests launch this app with the previous run's SMB servers, albums and
/// Keychain entries still in place; the first album row then belongs to an
/// endpoint whose password may no longer be valid. `--pv-reset-smb` clears
/// that state before any view reads the libraries.
enum SMBTestState {
    static func resetIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--pv-reset-smb") else { return }
        for server in SMBServerLibrary.load() {
            SMBCredentialStore.delete(for: server.id)
        }
        SMBFolderLibrary.save([])
        SMBServerLibrary.save([])
    }
}
#endif

// MARK: - Credentials

enum SMBCredentialStore {
    private static let service = "com.misswell.PhotoVault.smb"

    private static func baseQuery(_ serverID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
        ]
    }

    @discardableResult
    static func save(password: String, for serverID: UUID) -> Bool {
        let query = baseQuery(serverID)
        let data = Data(password.utf8)
        // `kSecAttrAccessible` is fixed at creation and makes SecItemUpdate
        // fail with errSecParam, so update and add carry different payloads.
        // Update first: deleting before adding would leave the account
        // password-less if the add failed (locked device, keychain error).
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            SMBConfiguration.invalidate(serverID: serverID)
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
        if added {
            SMBConfiguration.invalidate(serverID: serverID)
        }
        return added
    }

    static func password(for serverID: UUID) -> String? {
        var query = baseQuery(serverID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        return password
    }

    static func delete(for serverID: UUID) {
        SecItemDelete(baseQuery(serverID) as CFDictionary)
        SMBConfiguration.invalidate(serverID: serverID)
    }
}

// MARK: - Connection configuration

struct SMBConnectionConfig: Sendable, Equatable {
    let host: String
    let port: Int
    let username: String
    let password: String
    let domain: String

    var loginUsername: String? {
        username.isEmpty ? nil : username
    }

    var loginPassword: String? {
        password.isEmpty ? nil : password
    }

    var loginDomain: String? {
        domain.isEmpty ? nil : domain
    }
}

enum SMBConfiguration {
    private struct Entry {
        let server: SMBServer
        let config: SMBConnectionConfig?
    }

    // Keychain reads are serialized by the system and were happening once per
    // image request (server list decode + SecItemCopyMatching). Keep the
    // resolved config — including the negative result — until a server or
    // credential mutation invalidates it.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [UUID: Entry] = [:]

    static func config(for server: SMBServer) -> SMBConnectionConfig? {
        lock.lock()
        if let entry = entries[server.id], entry.server == server {
            lock.unlock()
            return entry.config
        }
        lock.unlock()

        let config = SMBCredentialStore.password(for: server.id).map { password in
            SMBConnectionConfig(
                host: server.host,
                port: server.port,
                username: server.username,
                password: password,
                domain: server.domain
            )
        }

        lock.lock()
        entries[server.id] = Entry(server: server, config: config)
        lock.unlock()
        return config
    }

    static func config(forFolder folder: SMBFolderAlbum) -> (server: SMBServer, config: SMBConnectionConfig)? {
        guard let server = SMBServerLibrary.load().first(where: { $0.id == folder.serverID }),
              let config = config(for: server)
        else { return nil }
        return (server, config)
    }

    static func invalidate(serverID: UUID) {
        lock.lock()
        entries.removeValue(forKey: serverID)
        lock.unlock()
    }

    static func invalidateAll() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}

// MARK: - Errors

enum SMBError: LocalizedError, Equatable {
    case missingCredentials
    case timedOut
    case noShares
    case notConnected

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "没有保存这台服务器的密码，请重新输入后连接。"
        case .timedOut:
            return "连接 SMB 服务器超时，请检查网络、地址和端口后重试。"
        case .noShares:
            return "登录成功，但这台服务器没有可用的共享文件夹。"
        case .notConnected:
            return "SMB 连接已断开，请重试。"
        }
    }

    /// Maps SMB2 status codes to wording a user can act on. Everything else
    /// keeps the library's own description, which is still more useful than
    /// a generic "connection failed".
    static func describe(_ error: Error) -> String {
        if let smbError = error as? SMBError {
            return smbError.errorDescription ?? "SMB 连接失败。"
        }
        if let response = error as? ErrorResponse,
           let code = ErrorCode(rawValue: response.header.status) {
            switch code {
            case .logonFailure:
                return "用户名或密码不正确。"
            case .accessDenied:
                return "服务器拒绝访问：当前账户没有这个共享的读取权限。"
            case .badNetworkName, .networkNameDeleted:
                return "找不到这个共享文件夹，可能已被重命名或删除。"
            case .objectNameNotFound, .objectPathNotFound:
                return "服务器上找不到这个文件夹。"
            case .notSupported:
                return "服务器不支持当前连接方式（需要 SMB 2.0 或更新版本）。"
            case .ioTimeout:
                return "服务器响应超时，请检查网络连接。"
            case .connectionRefused:
                return "服务器拒绝连接，请确认地址、端口和 SMB 服务已开启。"
            default:
                break
            }
            return "SMB 服务器返回错误：\(response.description)"
        }
        let text = error.localizedDescription
        if text.isEmpty {
            return "SMB 连接失败，请稍后重试。"
        }
        return "SMB 连接失败：\(text)"
    }
}

// MARK: - Timeout

/// Races an operation against a timeout without waiting for the loser. SMB
/// reads block inside Network.framework and do not honor cooperative
/// cancellation, so a task-group race would keep the caller suspended until
/// the dead connection eventually failed.
///
/// `onWorkerExit` runs when the operation's worker really finishes — including
/// long after the caller already timed out. Callers that own a non-thread-safe
/// resource use it to keep the resource reserved until the abandoned call has
/// actually returned.
enum SMBTimeout {
    private final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var worker: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var cancelled = false

        /// Installs the continuation before any task starts. Resumes it with
        /// `CancellationError` when cancellation won the race first.
        func install(_ continuation: CheckedContinuation<T, Error>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func attach(worker: Task<Void, Never>, timeoutTask: Task<Void, Never>) {
            lock.lock()
            // The operation may already have finished before attach; then the
            // timeout timer must be cancelled instead of being kept around.
            let finished = cancelled || continuation == nil
            if !finished {
                self.worker = worker
                self.timeoutTask = timeoutTask
            }
            lock.unlock()
            if finished {
                worker.cancel()
                timeoutTask.cancel()
            }
        }

        func resume(_ result: Result<T, Error>) -> Bool {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            let worker = self.worker
            self.worker = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            lock.unlock()
            worker?.cancel()
            timeoutTask?.cancel()
            guard let continuation else { return false }
            continuation.resume(with: result)
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let continuation = self.continuation
            self.continuation = nil
            let worker = self.worker
            self.worker = nil
            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil
            lock.unlock()
            worker?.cancel()
            timeoutTask?.cancel()
            continuation?.resume(throwing: CancellationError())
        }
    }

    static func run<T: Sendable>(
        seconds: Double,
        onWorkerExit: (@Sendable () -> Void)? = nil,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let box = Box<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.install(continuation)
                let worker = Task {
                    let result: Result<T, Error>
                    do {
                        try Task.checkCancellation()
                        result = .success(try await body())
                    } catch {
                        result = .failure(error)
                    }
                    onWorkerExit?()
                    box.resume(result)
                }
                let timeout = Task {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    // A finished worker cancels this task, so a late wake-up
                    // must not report a timeout for an operation that won.
                    guard !Task.isCancelled else { return }
                    box.resume(.failure(SMBError.timedOut))
                }
                box.attach(worker: worker, timeoutTask: timeout)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Serial gate for one share. `SMBClient` is not thread-safe and a timed-out
/// call keeps running inside Network.framework: the gate must stay held until
/// that call really returns, or the next request would use the same client
/// concurrently with the abandoned one.
private final class SMBSerialGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Check and enqueue under one lock acquisition: a separate check
            // followed by an append could race a release and wait forever.
            let acquired = lock.withLock {
                if !busy {
                    busy = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty {
                busy = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

// MARK: - Virtual URLs

/// SMB files are exposed to the folder album UI as URLs so the existing grid,
/// viewer, filmstrip and slideshow can consume them unchanged. The scheme is
/// never handed to a system API without first being materialized to a local
/// file (see `SMBFileMaterializer`).
struct SMBVirtualURL: Hashable, Sendable {
    static let scheme = "photovault-smb"

    let albumID: UUID
    let path: String
    let modified: Date?
    let size: UInt64

    var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = albumID.uuidString
        components.path = "/" + path
        components.queryItems = [
            URLQueryItem(name: "mtime", value: String(Int(modified?.timeIntervalSince1970 ?? 0))),
            URLQueryItem(name: "size", value: String(size)),
        ]
        return components.url
    }

    var cacheKey: String {
        "\(albumID.uuidString)|\(path)|\(Int(modified?.timeIntervalSince1970 ?? 0))|\(size)"
    }

    init(albumID: UUID, path: String, modified: Date?, size: UInt64) {
        self.albumID = albumID
        self.path = path
        self.modified = modified
        self.size = size
    }

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              let albumID = UUID(uuidString: host)
        else { return nil }

        let rawPath = components.path
        self.albumID = albumID
        self.path = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        let items = components.queryItems ?? []
        let epoch = items.first(where: { $0.name == "mtime" })?.value.flatMap(TimeInterval.init) ?? 0
        self.modified = epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
        self.size = items.first(where: { $0.name == "size" })?.value.flatMap(UInt64.init) ?? 0
    }
}

// MARK: - Remote browsing

struct SMBRemoteFile: Sendable, Hashable, Identifiable {
    let path: String
    let name: String
    let size: UInt64
    let modified: Date?
    let isDirectory: Bool

    var id: String { path }
}

struct SMBShareInfo: Identifiable, Sendable, Hashable {
    let name: String
    let comment: String

    var id: String { name }
}

enum SMBPath {
    static func child(_ parent: String, _ name: String) -> String {
        let base = parent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return base.isEmpty ? name : "\(base)/\(name)"
    }

    static func displayName(for path: String, fallback: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let last = trimmed.split(separator: "/").last else { return fallback }
        return String(last)
    }
}

// MARK: - Connection

/// Owns one logged-in SMB session per (server, share). `SMBClient` is a
/// single-connection, non-thread-safe object, so every operation runs through
/// this actor's serial gate. Failures invalidate the session and retry once
/// on a fresh connection; timeouts never retry.
actor SMBShareConnection {
    private final class ClientBox: @unchecked Sendable {
        let client: SMBClient
        init(_ client: SMBClient) { self.client = client }
    }

    private let serverID: UUID
    private let share: String
    private let gate = SMBSerialGate()
    private var config: SMBConnectionConfig?
    private var clientBox: ClientBox?

    init(serverID: UUID, share: String) {
        self.serverID = serverID
        self.share = share
    }

    /// Serialized with operations: disconnecting a client that a worker is
    /// still using is exactly the race this gate exists to prevent.
    func update(config: SMBConnectionConfig) async {
        guard self.config != config else { return }
        await gate.acquire()
        defer { gate.release() }
        guard self.config != config else { return }
        self.config = config
        disconnect()
    }

    private func disconnect() {
        clientBox?.client.session.disconnect()
        clientBox = nil
    }

    private func connect() async throws -> ClientBox {
        if let clientBox { return clientBox }
        guard let config else { throw SMBError.missingCredentials }
        let share = self.share
        let box = ClientBox(SMBClient(host: config.host, port: config.port))
        do {
            try await SMBTimeout.run(seconds: 20) {
                try await box.client.login(
                    username: config.loginUsername,
                    password: config.loginPassword,
                    domain: config.loginDomain
                )
                try await box.client.connectShare(share)
            }
        } catch {
            // A timed-out login may still be running inside Network.framework;
            // disconnecting its session from here would race that call.
            if !(error is CancellationError), (error as? SMBError) != .timedOut {
                box.client.session.disconnect()
            }
            throw error
        }
        clientBox = box
        return box
    }

    private func attempt<T: Sendable>(
        timeout: Double,
        _ operation: @escaping @Sendable (SMBClient) async throws -> T
    ) async throws -> T {
        // One operation at a time per share, no matter how many cells request
        // images at once. The gate is released by `onWorkerExit`, not by this
        // caller: after a timeout the request is already answered, but the
        // client is still in use until the abandoned call returns.
        let gate = self.gate
        await gate.acquire()
        guard !Task.isCancelled else {
            gate.release()
            throw CancellationError()
        }
        return try await SMBTimeout.run(
            seconds: timeout,
            onWorkerExit: { gate.release() }
        ) {
            let box = try await self.connect()
            do {
                return try await operation(box.client)
            } catch {
                await self.invalidate(box)
                throw error
            }
        }
    }

    private func invalidate(_ box: ClientBox) {
        guard clientBox === box else { return }
        disconnect()
    }

    private func run<T: Sendable>(
        timeout: Double,
        _ operation: @escaping @Sendable (SMBClient) async throws -> T
    ) async throws -> T {
        do {
            return try await attempt(timeout: timeout, operation)
        } catch {
            if Task.isCancelled || error is CancellationError { throw error }
            if error as? SMBError == .timedOut { throw error }
            // Missing credentials cannot be healed by reconnecting.
            if error as? SMBError == .missingCredentials { throw error }
            return try await attempt(timeout: timeout, operation)
        }
    }

    func listDirectory(at path: String) async throws -> [SMBRemoteFile] {
        try await run(timeout: 45) { client in
            let files = try await client.listDirectory(path: path)
            return files.map { file in
                SMBRemoteFile(
                    path: SMBPath.child(path, file.name),
                    name: file.name,
                    size: file.size,
                    modified: file.lastWriteTime,
                    isDirectory: file.isDirectory
                )
            }
        }
    }

    func download(path: String, to destination: URL) async throws {
        try await run(timeout: 300) { client in
            try await client.download(path: path, localPath: destination, overwrite: true)
        }
    }

    func close() async {
        await gate.acquire()
        disconnect()
        gate.release()
    }
}

// MARK: - Pool

final class SMBConnectionPool: @unchecked Sendable {
    static let shared = SMBConnectionPool()

    private let lock = NSLock()
    private var connections: [String: SMBShareConnection] = [:]

    private func key(serverID: UUID, share: String) -> String {
        "\(serverID.uuidString)|\(share.lowercased())"
    }

    func connection(serverID: UUID, share: String) -> SMBShareConnection {
        lock.lock()
        defer { lock.unlock() }
        let key = key(serverID: serverID, share: share)
        if let existing = connections[key] { return existing }
        let connection = SMBShareConnection(serverID: serverID, share: share)
        connections[key] = connection
        return connection
    }

    func discard(serverID: UUID, share: String) {
        lock.lock()
        let connection = connections.removeValue(forKey: key(serverID: serverID, share: share))
        lock.unlock()
        Task { await connection?.close() }
    }

    func discardAll(serverID: UUID) {
        lock.lock()
        let prefix = "\(serverID.uuidString)|"
        let discarded = connections.filter { $0.key.hasPrefix(prefix) }.map(\.value)
        connections = connections.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
        for connection in discarded {
            Task { await connection.close() }
        }
    }
}

// MARK: - Browse helpers

enum SMBShareBrowser {
    /// Login-only pass used by the add-album flow. Directory browsing after
    /// this point goes through the pooled per-share connection.
    static func listShares(config: SMBConnectionConfig) async throws -> [SMBShareInfo] {
        final class Box: @unchecked Sendable {
            let client: SMBClient
            init(_ client: SMBClient) { self.client = client }
        }
        let box = Box(SMBClient(host: config.host, port: config.port))
        do {
            // Directory-style shares only: IPC$/print queues have no photos
            // and admin shares are hidden behind a trailing `$`.
            let visible = try await SMBTimeout.run(seconds: 30) { () -> [SMBShareInfo] in
                try await box.client.login(
                    username: config.loginUsername,
                    password: config.loginPassword,
                    domain: config.loginDomain
                )
                defer { box.client.session.disconnect() }
                let shares = try await box.client.listShares()
                return shares
                    .filter { ($0.type.rawValue & 0x0FFFFFFF) == 0 && !$0.name.hasSuffix("$") }
                    .map { SMBShareInfo(name: $0.name, comment: $0.comment) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            guard !visible.isEmpty else { throw SMBError.noShares }
            return visible
        } catch {
            // The timeout path cannot stop the login/list call inside
            // Network.framework; disconnecting now would race the worker.
            if !(error is CancellationError), (error as? SMBError) != .timedOut {
                box.client.session.disconnect()
            }
            throw error
        }
    }
}

enum SMBFolderEnumerator {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp",
        "bmp", "tif", "tiff", "dng",
    ]

    /// Recursively lists image files under the album folder, newest first.
    /// The traversal is bounded by directory count and timeout so a share
    /// with an accidental network-mount loop cannot spin forever.
    static func enumerate(folder: SMBFolderAlbum) async throws -> [URL] {
        guard let resolved = SMBConfiguration.config(forFolder: folder) else {
            throw SMBError.missingCredentials
        }
        let connection = SMBConnectionPool.shared.connection(
            serverID: folder.serverID,
            share: folder.share
        )
        await connection.update(config: resolved.config)

        var pending = [folder.path]
        var visited = Set<String>()
        var results: [SMBRemoteFile] = []
        var directoryCount = 0

        while let directory = pending.popLast() {
            // The caller races enumeration against a timeout; stop walking a
            // huge tree as soon as that timeout has been declared.
            try Task.checkCancellation()
            guard visited.insert(directory).inserted else { continue }
            directoryCount += 1
            if directoryCount > 5_000 { break }
            let entries = try await connection.listDirectory(at: directory)
            for entry in entries {
                if entry.name == "." || entry.name == ".." || entry.name.isEmpty { continue }
                if entry.isDirectory {
                    if !entry.name.hasPrefix(".") {
                        pending.append(entry.path)
                    }
                    continue
                }
                let ext = (entry.name as NSString).pathExtension.lowercased()
                guard imageExtensions.contains(ext) else { continue }
                results.append(entry)
            }
        }

        return results
            .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            .compactMap { file in
                SMBVirtualURL(
                    albumID: folder.id,
                    path: file.path,
                    modified: file.modified,
                    size: file.size
                ).url
            }
    }
}

// MARK: - Original-file cache

/// Downloaded originals back the thumbnail, the viewer and sharing. Keeping
/// them on disk means scrolling back, opening a photo twice or sharing never
/// pays for the same SMB transfer again.
enum SMBOriginalCache {
    private static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let lock = NSLock()
    /// Estimated bytes in the tree. -1 until the first sweep measures a cache
    /// left behind by an earlier process.
    nonisolated(unsafe) private static var approximateBytes: Int64 = -1
    nonisolated(unsafe) private static var sweepInFlight = false
    nonisolated(unsafe) private static var didInitialSweep = false

    private static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoVault", isDirectory: true)
            .appendingPathComponent("smb-files", isDirectory: true)
    }

    /// Path only: cache lookups run for every image request and must not pay
    /// a `createDirectory` syscall, nor recreate a purged album directory.
    private static func directory(for albumID: UUID) -> URL {
        root.appendingPathComponent(albumID.uuidString, isDirectory: true)
    }

    private static func fileName(for remote: SMBVirtualURL) -> String {
        let digest = Insecure.MD5.hash(data: Data(remote.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let ext = (remote.path as NSString).pathExtension.lowercased()
        let safeExt = LANFolderImageLoader.imageExtensions.contains(ext) ? ext : "img"
        let mtime = Int(remote.modified?.timeIntervalSince1970 ?? 0)
        return "\(digest)-\(mtime)-\(remote.size).\(safeExt)"
    }

    private static func cacheFile(for remote: SMBVirtualURL) -> URL {
        directory(for: remote.albumID)
            .appendingPathComponent(fileName(for: remote))
    }

    static func cachedFile(for remote: SMBVirtualURL) -> URL? {
        let file = cacheFile(for: remote)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    static func store(tempURL: URL, for remote: SMBVirtualURL) throws -> URL {
        let directory = directory(for: remote.albumID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName(for: remote))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? Int64(remote.size)
        trackStore(size: size)
        return destination
    }

    /// Deleting a cache directory can span thousands of files, so it runs off
    /// the main thread — this is called from album/server deletion UI.
    static func purge(albumID: UUID) {
        let directory = root.appendingPathComponent(albumID.uuidString, isDirectory: true)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func purgeAll() {
        try? FileManager.default.removeItem(at: root)
        lock.lock()
        approximateBytes = 0
        lock.unlock()
    }

    private static func trackStore(size: Int64) {
        lock.lock()
        let initial = !didInitialSweep
        didInitialSweep = true
        approximateBytes = max(0, approximateBytes) + max(0, size)
        let shouldSweep = !sweepInFlight && (initial || approximateBytes > maxBytes)
        if shouldSweep { sweepInFlight = true }
        lock.unlock()
        guard shouldSweep else { return }

        // One sweep at a time: the budget is checked against a measured tree,
        // so overlapping sweeps would fight over the same oldest files.
        Task.detached(priority: .utility) {
            let total = sweep()
            lock.withLock {
                approximateBytes = total
                sweepInFlight = false
            }
        }
    }

    /// Synchronous on purpose: `FileManager.enumerator` cannot be iterated
    /// from an async context under Swift 6.
    private static func sweep() -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var files: [(url: URL, size: Int64, date: Date)] = []
        var staleTemporaries: [URL] = []
        var total: Int64 = 0
        // Transfers have a 300 s timeout; anything older than an hour was
        // left behind by a killed process, not by a live download.
        let temporaryCutoff = Date().addingTimeInterval(-3600)
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  let size = values.fileSize
            else { continue }
            let date = values.contentModificationDate ?? .distantPast
            if fileURL.lastPathComponent.hasPrefix(".download-") {
                if date < temporaryCutoff { staleTemporaries.append(fileURL) }
                continue
            }
            files.append((fileURL, Int64(size), date))
            total += Int64(size)
        }
        for url in staleTemporaries {
            try? FileManager.default.removeItem(at: url)
        }
        guard total > maxBytes else { return total }
        for file in files.sorted(by: { $0.date < $1.date }) {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
            if total <= maxBytes { break }
        }
        return max(0, total)
    }
}

actor SMBTransferLimiter {
    static let shared = SMBTransferLimiter()

    private var available = 3
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

actor SMBTransferCoordinator {
    static let shared = SMBTransferCoordinator()

    private struct Download {
        let id: UInt64
        let task: Task<URL?, Never>
    }

    private var downloads: [String: Download] = [:]
    private var nextID: UInt64 = 0

    func localFile(
        for remote: SMBVirtualURL,
        album: SMBFolderAlbum,
        config: SMBConnectionConfig
    ) async -> URL? {
        if let cached = SMBOriginalCache.cachedFile(for: remote) {
            return cached
        }
        let key = remote.cacheKey
        if let existing = downloads[key] {
            let result = await existing.task.value
            // Only the matching job may clear the slot; a newer request may
            // have started after this waiter resumed.
            if downloads[key]?.id == existing.id {
                downloads[key] = nil
            }
            return result
        }
        nextID &+= 1
        let id = nextID
        let task = Task.detached(priority: .userInitiated) { () -> URL? in
            await SMBTransferLimiter.shared.acquire()
            var result: URL?
            var temporary: URL?
            do {
                let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("PhotoVault", isDirectory: true)
                    .appendingPathComponent("smb-files", isDirectory: true)
                    .appendingPathComponent(album.id.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let downloadURL = directory
                    .appendingPathComponent(".download-\(UUID().uuidString)")
                temporary = downloadURL
                let connection = SMBConnectionPool.shared.connection(
                    serverID: album.serverID,
                    share: album.share
                )
                await connection.update(config: config)
                try await connection.download(path: remote.path, to: downloadURL)
                result = try SMBOriginalCache.store(tempURL: downloadURL, for: remote)
                temporary = nil
            } catch {
                if let temporary {
                    try? FileManager.default.removeItem(at: temporary)
                }
                LANFolderDiagnostics.log("SMB download failed for \(album.name)/\(remote.path): \(error.localizedDescription)")
            }
            await SMBTransferLimiter.shared.release()
            return result
        }
        downloads[key] = Download(id: id, task: task)
        let result = await task.value
        if downloads[key]?.id == id {
            downloads[key] = nil
        }
        return result
    }
}

// MARK: - Decoding

enum SMBImageDecoder {
    static func downsample(fileURL: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}

enum SMBImageMemoryCache {
    // NSCache is thread-safe; the reference itself is immutable.
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        cache.countLimit = 64
        return cache
    }()

    static func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func store(_ image: UIImage, forKey key: String) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }

    /// Decoded SMB originals have no PhotoKit cache behind them; release them
    /// on backgrounding and on the settings' cache-clear action.
    static func removeAll() {
        cache.removeAllObjects()
    }
}

actor SMBImagePipeline {
    static let shared = SMBImagePipeline()

    private struct Decode {
        let id: UInt64
        let task: Task<UIImage?, Never>
    }

    private var decodes: [String: Decode] = [:]
    private var nextID: UInt64 = 0

    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        guard let remote = SMBVirtualURL(url: url) else { return nil }
        let key = "\(remote.cacheKey)#\(Int(maxPixelSize))"
        if let cached = SMBImageMemoryCache.image(forKey: key) {
            return cached
        }
        if let existing = decodes[key] {
            let image = await existing.task.value
            if decodes[key]?.id == existing.id {
                decodes[key] = nil
            }
            return image
        }
        guard let album = SMBFolderLibrary.load().first(where: { $0.id == remote.albumID }),
              let resolved = SMBConfiguration.config(forFolder: album)
        else { return nil }
        nextID &+= 1
        let id = nextID
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let file = await SMBTransferCoordinator.shared.localFile(
                for: remote,
                album: album,
                config: resolved.config
            ) else { return nil }
            return SMBImageDecoder.downsample(fileURL: file, maxPixelSize: maxPixelSize)
        }
        decodes[key] = Decode(id: id, task: task)
        let image = await task.value
        // Publish to the memory cache before removing the in-flight slot, so
        // a request arriving in between cannot start a duplicate decode.
        if let image {
            SMBImageMemoryCache.store(image, forKey: key)
        }
        if decodes[key]?.id == id {
            decodes[key] = nil
        }
        return image
    }
}

// MARK: - Materialization for share sheets

enum SMBFileMaterializer {
    struct MaterializedFile {
        let url: URL
        /// Removes the temporary share-name link/copy; never the cache file.
        let cleanup: () -> Void
    }

    /// Returns a local file for any folder-album URL. Local folders pass
    /// through untouched; SMB files are downloaded (or served from the
    /// original cache) because system share targets cannot read a virtual
    /// scheme. The share sheet displays the URL's last path component, so the
    /// cache file is exposed under its real name instead of the hashed
    /// cache key.
    static func materialized(for url: URL) async -> MaterializedFile? {
        guard let remote = SMBVirtualURL(url: url) else {
            return MaterializedFile(url: url, cleanup: {})
        }
        guard let album = SMBFolderLibrary.load().first(where: { $0.id == remote.albumID }),
              let resolved = SMBConfiguration.config(forFolder: album)
        else { return nil }
        guard let cached = await SMBTransferCoordinator.shared.localFile(
            for: remote,
            album: album,
            config: resolved.config
        ) else { return nil }
        return shareCopy(of: cached, named: (remote.path as NSString).lastPathComponent)
    }

    static func isSMB(_ url: URL) -> Bool {
        SMBVirtualURL(url: url) != nil
    }

    private static func shareCopy(of file: URL, named name: String) -> MaterializedFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhotoVaultShare-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(
                name.isEmpty ? file.lastPathComponent : name
            )
            do {
                try FileManager.default.linkItem(at: file, to: destination)
            } catch {
                try FileManager.default.copyItem(at: file, to: destination)
            }
            return MaterializedFile(url: destination, cleanup: {
                try? FileManager.default.removeItem(at: directory)
            })
        } catch {
            // A hashed name is better than a share that cannot open the file.
            return MaterializedFile(url: file, cleanup: {})
        }
    }
}
