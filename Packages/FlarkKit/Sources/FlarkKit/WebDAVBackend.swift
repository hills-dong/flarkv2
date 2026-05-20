import Foundation

/// WebDAV storage over URLSession. No server logic: concurrency safety comes
/// from unique per-author/append filenames + content-addressed immutable
/// blobs, plus conditional requests for the rare mutable manifest.
public final class WebDAVBackend: StorageBackend, @unchecked Sendable {
    private let base: URL          // e.g. https://dav.example.com/flark/
    private let session: URLSession
    private let authHeader: String

    public init(baseURL: URL, username: String, password: String,
                session: URLSession = .shared) {
        // ensure trailing slash so relative joins land inside the Space
        self.base = baseURL.absoluteString.hasSuffix("/")
            ? baseURL : URL(string: baseURL.absoluteString + "/")!
        self.session = session
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        self.authHeader = "Basic \(token)"
    }

    private func url(_ path: String) -> URL {
        path.isEmpty ? base : base.appendingPathComponent(path)
    }

    private func request(_ method: String, _ path: String) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        return r
    }

    private func mapStatus(_ code: Int) -> StorageError {
        switch code {
        case 401, 403: return .unauthorized
        case 404, 409: return .notFound
        case 412, 405: return .preconditionFailed
        case 423, 429: return .server(code)
        default: return .server(code)
        }
    }

    public func list(_ directory: String) async throws -> [StorageEntry] {
        var r = request("PROPFIND", directory)
        r.setValue("1", forHTTPHeaderField: "Depth")
        r.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        r.httpBody = Data("""
        <?xml version="1.0"?><d:propfind xmlns:d="DAV:">\
        <d:prop><d:resourcetype/><d:getetag/></d:prop></d:propfind>
        """.utf8)
        let (data, resp) = try await dataTask(r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return [] }
        guard (200..<300).contains(code) || code == 207 else { throw mapStatus(code) }
        return PropfindParser.parse(data, base: base, requested: directory)
    }

    public func get(_ path: String) async throws -> (data: Data, etag: String?) {
        let (data, resp) = try await dataTask(request("GET", path))
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw mapStatus(code) }
        return (data, http?.value(forHTTPHeaderField: "ETag"))
    }

    /// Real conditional GET. With `knownEtag`, sends `If-None-Match` and maps
    /// 304 to nil so the sync engine can skip re-folding unchanged files —
    /// crucial once a long-lived "active" file is re-PUT on every event and
    /// 20 peers would otherwise re-download it every 15 s poll round.
    /// `reloadIgnoringLocalCacheData` keeps `URLCache.shared` from converting
    /// the 304 into a transparent 200 before we see it.
    public func get(_ path: String, ifNoneMatch knownEtag: String?) async throws -> (data: Data, etag: String?)? {
        var r = request("GET", path)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let known = knownEtag {
            r.setValue(known, forHTTPHeaderField: "If-None-Match")
        }
        let (data, resp) = try await dataTask(r)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 304 { return nil }
        guard (200..<300).contains(code) else { throw mapStatus(code) }
        return (data, http?.value(forHTTPHeaderField: "ETag"))
    }

    public func put(_ path: String, data: Data, precondition: WritePrecondition) async throws {
        var r = request("PUT", path)
        r.httpBody = data
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        switch precondition {
        case .none: break
        case .createOnly: r.setValue("*", forHTTPHeaderField: "If-None-Match")
        case .ifMatch(let tag): r.setValue(tag, forHTTPHeaderField: "If-Match")
        }
        let (_, resp) = try await dataTask(r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 409 { // missing parent collection — create then retry once
            try await ensureParents(of: path)
            let (_, resp2) = try await dataTask(r)
            let code2 = (resp2 as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code2) else { throw mapStatus(code2) }
            return
        }
        guard (200..<300).contains(code) else { throw mapStatus(code) }
    }

    public func makeDirectory(_ path: String) async throws {
        let (_, resp) = try await dataTask(request("MKCOL", path))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 405 == already exists, which is fine.
        guard (200..<300).contains(code) || code == 405 else { throw mapStatus(code) }
    }

    public func exists(_ path: String) async throws -> Bool {
        let (_, resp) = try await dataTask(request("HEAD", path))
        return (200..<300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func delete(_ path: String) async throws {
        let (_, resp) = try await dataTask(request("DELETE", path))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        // 404/409 == already gone, which satisfies the postcondition.
        guard (200..<300).contains(code) || code == 404 || code == 409 else {
            throw mapStatus(code)
        }
    }

    private func ensureParents(of path: String) async throws {
        let parts = path.split(separator: "/").dropLast()
        var acc = ""
        for p in parts {
            acc = acc.isEmpty ? String(p) : "\(acc)/\(p)"
            try? await makeDirectory(acc)
        }
    }

    /// Retry transient failures (locked / rate-limited / 5xx) with backoff.
    /// Every attempt — success, retry, or final failure — is logged via
    /// `FlarkLog` so the in-app diagnostics page reflects the real network
    /// traffic to/from the WebDAV server.
    private func dataTask(_ request: URLRequest, attempt: Int = 0) async throws -> (Data, URLResponse) {
        let method = request.httpMethod ?? "?"
        let logPath = request.url?.path ?? ""
        let start = Date()
        do {
            let (data, resp) = try await session.data(for: request)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let retryable = [423, 429, 500, 502, 503, 504].contains(code) && attempt < 4
            FlarkLog.shared.record(
                code >= 400 ? (retryable ? .warn : .error) : .info,
                .storage, method,
                path: logPath,
                detail: "HTTP \(code)\(attempt > 0 ? " · attempt \(attempt + 1)" : "")",
                bytes: data.count,
                durationMs: ms)
            if retryable {
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 300_000_000))
                return try await dataTask(request, attempt: attempt + 1)
            }
            return (data, resp)
        } catch {
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            FlarkLog.shared.record(
                attempt < 3 ? .warn : .error,
                .storage, method,
                path: logPath,
                detail: "transport: \(error.localizedDescription)\(attempt > 0 ? " · attempt \(attempt + 1)" : "")",
                durationMs: ms)
            if attempt < 3 {
                try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 300_000_000))
                return try await dataTask(request, attempt: attempt + 1)
            }
            throw StorageError.transport(String(describing: error))
        }
    }
}

/// Minimal multistatus parser: collects href + resourcetype + getetag.
final class PropfindParser: NSObject, XMLParserDelegate {
    private var entries: [StorageEntry] = []
    private var elementStack: [String] = []
    private var currentHref = ""
    private var currentIsDir = false
    private var currentEtag: String?
    private var text = ""
    private let basePath: String
    private let requested: String

    static func parse(_ data: Data, base: URL, requested: String) -> [StorageEntry] {
        let p = PropfindParser(basePath: base.path, requested: requested)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.entries
    }

    init(basePath: String, requested: String) {
        self.basePath = basePath
        self.requested = requested
    }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        let name = local(el)
        elementStack.append(name)
        if name == "response" { currentHref = ""; currentIsDir = false; currentEtag = nil }
        text = ""
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        let name = local(el)
        switch name {
        case "href": currentHref = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "collection": currentIsDir = true
        case "getetag": currentEtag = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "response":
            if let rel = relativePath(currentHref), !rel.isEmpty, rel != requested {
                entries.append(StorageEntry(path: rel, isDirectory: currentIsDir,
                                            etag: currentIsDir ? nil : currentEtag))
            }
        default: break
        }
        elementStack.removeLast()
    }

    private func local(_ el: String) -> String {
        el.contains(":") ? String(el.split(separator: ":").last!) : el
    }

    /// Turn an absolute href into a path relative to the Space root.
    private func relativePath(_ href: String) -> String? {
        guard var path = URL(string: href)?.path ?? href.removingPercentEncoding else { return nil }
        if path.hasPrefix(basePath) { path.removeFirst(basePath.count) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !requested.isEmpty, path.hasPrefix(requested) {
            path = String(path.dropFirst(requested.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return requested + (path.isEmpty ? "" : "/" + path)
        }
        return path
    }
}
