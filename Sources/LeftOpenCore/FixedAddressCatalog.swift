import Foundation
import Darwin

/// One short-lived address catalog shared by the native UI, CLI and agents.
public struct FixedAddressCatalog: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let binding: FixedAddressBinding
        public let pid: Int32
        public let port: Int
        public let url: URL
        public init(binding: FixedAddressBinding, pid: Int32, port: Int, url: URL) {
            self.binding = binding; self.pid = pid; self.port = port; self.url = url
        }
    }
    public let expiresAt: Date
    public let entries: [Entry]
    public init(expiresAt: Date, entries: [Entry]) { self.expiresAt = expiresAt; self.entries = entries }

    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LeftOpen/FixedAddresses/addresses.json")
    }

    public static func read(at file: URL = Self.file) -> Self? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024 * 1024 + 1), data.count <= 1024 * 1024 else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    public func verified(in activities: [Activity], now: Date = Date()) -> [Entry] {
        guard expiresAt > now, entries.count <= 100 else { return [] }
        return entries.filter { entry in
            guard ["http", "https"].contains(entry.url.scheme), entry.url.user == nil, entry.url.password == nil,
                  entry.url.host == "\(entry.binding.name).localhost", Portless.validName(entry.binding.name),
                  entry.url.port.map({ (1...65535).contains($0) }) ?? true,
                  let target = entry.binding.resolve(in: activities),
                  target.process.pid == entry.pid, target.process.uid == Int32(getuid()), target.listener.port == entry.port else { return false }
            return true
        }
    }

    public func write(to file: URL = Self.file) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
