import Foundation

/// Indexes the user's shared folders and answers incoming search/browse/
/// upload requests. Virtual paths always use backslash separators, matching
/// Soulseek conventions ("\@user\folder\... " style is not used; we publish
/// "\share-name\relative\path.mp3").
public final class SharesManager {
    /// Real local directories currently shared.
    private(set) public var sharedDirectories: [URL] = []
    /// Virtual root name (first path component) → real directory.
    private(set) public var shareRoots: [String: URL] = [:]
    /// Virtual directory path (backslash-separated, leading "\") → files.
    private(set) public var folders: [String: [RemoteFileInfo]] = [:]
    /// Virtual file path → real file URL, for upload serving.
    private(set) public var fileMap: [String: URL] = [:]

    public private(set) var isScanning = false
    public private(set) var lastScanDate: Date?
    /// Phrases the server told us to exclude from search responses.
    public var excludedPhrases: [String] = []

    public var sharedFileCount: UInt32 { UInt32(fileMap.count) }
    public var sharedFolderCount: UInt32 { UInt32(folders.count) }

    private let scanQueue = DispatchQueue(label: "slsk.shares.scan", qos: .utility)

    public init() {}

    // MARK: Configuration

    /// Update shared directories; roots are named after their last path
    /// component. Call `rescan()` afterwards.
    public func setSharedDirectories(_ urls: [URL]) {
        sharedDirectories = urls
        var roots: [String: URL] = [:]
        for url in urls {
            var name = url.lastPathComponent
            if name.isEmpty { name = "Shared" }
            var unique = name
            var counter = 2
            while roots[unique] != nil, counter < 100 {
                unique = "\(name) (\(counter))"
                counter += 1
            }
            roots[unique] = url
        }
        shareRoots = roots
    }

    public var rootNames: [String] { Array(shareRoots.keys.sorted()) }

    // MARK: Scanning

    /// Scan all shares on a background queue; `completion` runs on the
    /// calling queue.
    public func rescan(completion: (() -> Void)? = nil) {
        guard !isScanning else {
            completion?()
            return
        }
        isScanning = true
        let roots = shareRoots
        scanQueue.async { [weak self] in
            guard let self else { return }
            var folders: [String: [RemoteFileInfo]] = [:]
            var fileMap: [String: URL] = [:]
            let fileManager = FileManager.default

            for (rootName, rootURL) in roots {
                #if canImport(Darwin)
                let secured = rootURL.startAccessingSecurityScopedResource()
                defer { if secured { rootURL.stopAccessingSecurityScopedResource() } }
                #endif

                let base = rootURL.standardizedFileURL.path
                var directories: [String] = [base]
                var index = 0
                while index < directories.count {
                    let directory = directories[index]
                    index += 1
                    guard let contents = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
                    for entry in contents {
                        let fullPath = directory + "/" + entry
                        var isDirectory: ObjCBool = false
                        guard fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) else { continue }
                        if isDirectory.boolValue {
                            directories.append(fullPath)
                        } else if let info = Self.fileInfo(rootName: rootName, basePath: base,
                                                           filePath: fullPath, url: URL(fileURLWithPath: fullPath)) {
                            folders[info.folderKey, default: []].append(info.file)
                            fileMap[info.file.virtualPath] = info.url
                        }
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.folders = folders
                self.fileMap = fileMap
                self.isScanning = false
                self.lastScanDate = Date()
                completion?()
            }
        }
    }

    private static func fileInfo(rootName: String, basePath: String, filePath: String,
                                 url: URL) -> (folderKey: String, file: RemoteFileInfo, url: URL)? {
        let relative = String(filePath.dropFirst(basePath.count + 1))
        if relative.isEmpty { return nil }
        let components = [rootName] + relative.split(separator: "/").map(String.init)
        let fileName = components.last ?? ""
        let folderComponents = components.dropLast()
        guard !fileName.hasPrefix("."), !folderComponents.isEmpty else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: filePath)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let virtualPath = "\\" + folderComponents.joined(separator: "\\") + "\\" + fileName
        let folderKey = "\\" + folderComponents.joined(separator: "\\")
        return (folderKey, RemoteFileInfo(virtualPath: virtualPath, size: size), url)
    }

    // MARK: Search

    /// Match a tokenized query against the share index (AND semantics).
    public func search(query: SearchQuery, maxResults: Int = 250) -> [RemoteFileInfo] {
        var results: [RemoteFileInfo] = []
        guard !query.includedWords.isEmpty else { return results }
        for folder in folders.keys.sorted() where !isExcluded(folder) {
            for file in folders[folder] ?? [] {
                if results.count >= maxResults { return results }
                if matches(file: file, query: query) {
                    results.append(file)
                }
            }
        }
        return results
    }

    private func isExcluded(_ path: String) -> Bool {
        let lowered = path.lowercased()
        return excludedPhrases.contains { lowered.contains($0.lowercased()) }
    }

    private func matches(file: RemoteFileInfo, query: SearchQuery) -> Bool {
        let lowered = file.virtualPath.lowercased()
        for word in query.includedWords where !lowered.contains(word) {
            return false
        }
        for word in query.excludedWords where lowered.contains(word) {
            return false
        }
        for phrase in query.excludedPhrases where lowered.contains(phrase) {
            return false
        }
        return true
    }

    // MARK: Browse / folder contents

    public func browseResponseData() throws -> Data {
        var b = MessageBuffer()
        b.writeUInt32(UInt32(folders.count))
        for folder in folders.keys.sorted() {
            b.writeString(folder)
            let files = folders[folder] ?? []
            b.writeUInt32(UInt32(files.count))
            for file in files {
                FileListCodec.packFileInfo(file, into: &b)
            }
        }
        b.writeUInt32(0) // unknown field sent by official clients
        return try Zlib.compress(b.data)
    }

    public func folderContents(for virtualFolder: String) -> [String: [RemoteFileInfo]] {
        var result: [String: [RemoteFileInfo]] = [:]
        let normalized = virtualFolder.hasSuffix("\\") ? String(virtualFolder.dropLast()) : virtualFolder
        if let files = folders[normalized] {
            result[normalized] = files
            return result
        }
        // Include subfolders when a parent folder was requested.
        for (folder, files) in folders.sorted(by: { $0.key < $1.key })
            where folder == normalized || folder.hasPrefix(normalized + "\\") {
            result[folder] = files
        }
        return result
    }

    public func folderContentsResponseData(token: UInt32, folder: String) throws -> Data {
        var b = MessageBuffer()
        b.writeUInt32(token)
        b.writeString(folder)
        let contents = folderContents(for: folder)
        b.writeUInt32(UInt32(contents.count))
        for (name, files) in contents.sorted(by: { $0.key < $1.key }) {
            b.writeString(name)
            b.writeUInt32(UInt32(files.count))
            for file in files {
                FileListCodec.packFileInfo(file, into: &b)
            }
        }
        return try Zlib.compress(b.data)
    }

    // MARK: Upload lookups

    public func realURL(forVirtualPath path: String) -> URL? {
        if let url = fileMap[path] { return url }
        // Tolerate forward-slash variants sent by some clients.
        let backslashed = path.replacingOccurrences(of: "/", with: "\\")
        return fileMap[backslashed]
    }

    public func isShared(virtualPath: String) -> Bool {
        realURL(forVirtualPath: virtualPath) != nil
    }
}

/// Parsed search query: included words (AND), excluded words (-word) and
/// quoted phrases ("some phrase" / -"excluded phrase").
public struct SearchQuery: Equatable {
    public var rawText: String
    public var includedWords: [String] = []
    public var excludedWords: [String] = []
    public var includedPhrases: [String] = []
    public var excludedPhrases: [String] = []

    public init(_ text: String) {
        rawText = text
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            var isExcluded = false
            if text[index] == "-" {
                isExcluded = true
                index = text.index(after: index)
            }

            if index < text.endIndex, text[index] == "\"" {
                index = text.index(after: index)
                var phrase = ""
                while index < text.endIndex, text[index] != "\"" {
                    phrase.append(text[index])
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    index = text.index(after: index) // closing quote
                }
                let cleaned = phrase.lowercased()
                if !cleaned.isEmpty {
                    if isExcluded {
                        excludedPhrases.append(cleaned)
                    } else {
                        includedPhrases.append(cleaned)
                    }
                }
            } else {
                var word = ""
                while index < text.endIndex, text[index] != " " {
                    word.append(text[index])
                    index = text.index(after: index)
                }
                let cleaned = word.lowercased().filter { !$0.isPunctuation || $0 == "." || $0 == "-" || $0 == "_" }
                if !cleaned.isEmpty {
                    if isExcluded {
                        excludedWords.append(cleaned)
                    } else {
                        includedWords.append(cleaned)
                    }
                }
            }
        }

        // A lone quoted phrase should still be searchable word-by-word.
        if includedWords.isEmpty, !includedPhrases.isEmpty {
            includedWords = includedPhrases.flatMap { $0.split(separator: " ").map(String.init) }
        }
    }
}
