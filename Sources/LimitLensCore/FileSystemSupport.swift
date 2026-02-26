/*
This file encapsulates filesystem traversal and tail-reading primitives used by all
provider adapters. It gives the rest of the system deterministic helpers for finding
recent artifacts and reading only the relevant portion of large files.

It exists as a separate file because direct filesystem enumeration is implementation-heavy
and easy to duplicate incorrectly. Centralizing these operations improves reliability and
keeps adapter code focused on parsing semantics.

This file talks to provider adapters by returning candidate paths and raw text slices,
and it talks to settings logic by consuming configurable source roots.
*/

import Foundation

public enum FileSystemSupport {
    public static func latestDirectory(in rootPath: String) -> URL? {
        let rootURL = URL(fileURLWithPath: rootPath)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let directoryURLs = entries.filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        var latestURL: URL?
        var latestMtime = Date.distantPast

        for candidate in directoryURLs {
            let values = try? candidate.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            if mtime > latestMtime {
                latestMtime = mtime
                latestURL = candidate
            }
        }

        if let latestURL {
            return latestURL
        }

        // If timestamps were unavailable, fall back to deterministic lexicographic order.
        return directoryURLs.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first
    }

    public static func latestFile(
        in rootPath: String,
        matching: (URL) -> Bool
    ) -> URL? {
        let rootURL = URL(fileURLWithPath: rootPath)
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latestURL: URL?
        var latestMtime = Date.distantPast

        while let item = enumerator.nextObject() as? URL {
            guard matching(item) else {
                continue
            }

            let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else {
                continue
            }

            let mtime = values?.contentModificationDate ?? .distantPast
            if mtime > latestMtime {
                latestMtime = mtime
                latestURL = item
            }
        }

        return latestURL
    }

    public static func readTail(from fileURL: URL, maxBytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return ""
        }
        defer {
            try? handle.close()
        }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let start = fileSize > UInt64(maxBytes) ? fileSize - UInt64(maxBytes) : 0

        do {
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
