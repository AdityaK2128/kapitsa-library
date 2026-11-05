import Foundation
import Security

/// Web search and page reading for Chat. The design is oMLX's built-in web search (github.com/jundot/omlx,
/// omlx/websearch.py, Apache License 2.0), written again in Swift: the chat offers the model two tools,
/// web_search and fetch_url, only on its own requests; Nearloop runs them and hands back a payload that is
/// always readable ({"ok": true, …} or {"ok": false, "error": …}), so the model can relay a failure.
/// Providers: DuckDuckGo (no key), Brave Search (the user's key) or a SearXNG server (the user's address).
enum WebSearch {
    enum Provider: String, CaseIterable, Identifiable {
        case duckduckgo, brave, searxng
        var id: String { rawValue }
        var title: String {
            switch self {
            case .duckduckgo: return "DuckDuckGo"
            case .brave: return "Brave Search"
            case .searxng: return "SearXNG"
            }
        }
    }

    struct Result: Codable, Hashable {
        let title: String
        let url: String
        let snippet: String
        var host: String { URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? url }
    }

    /// A picture found by image_search: the image itself, a small preview, and the page it comes from.
    struct ImageResult: Codable, Hashable {
        let title: String
        let image: String
        let thumbnail: String
        let page: String
        var width: Int?
        var height: Int?
        var host: String { URL(string: page)?.host?.replacingOccurrences(of: "www.", with: "") ?? page }
    }

    struct Failure: Error {
        let code: String
        let message: String
        var needsUser = false
    }

    struct Page {
        let url: String
        let text: String
        let truncated: Bool
    }

    // Caps from oMLX; the page length is lower by default, since local models have smaller contexts.
    static let maxQuery = 300, maxURL = 2048, maxTitle = 160, maxSnippet = 500
    static let maxBody = 2 * 1024 * 1024, maxRedirects = 3, timeout: TimeInterval = 20
    static let settingsHint = "Settings › Chat"

    // MARK: Settings

    static var provider: Provider { Provider(rawValue: Prefs.defaults.string(forKey: "searchProvider") ?? "") ?? .duckduckgo }
    static var resultCount: Int { min(10, max(1, Prefs.defaults.object(forKey: "searchResults") as? Int ?? 5)) }
    static var pageCharacters: Int { max(2_000, Prefs.defaults.object(forKey: "pageCharacters") as? Int ?? 12_000) }
    static var searxngURL: String { Prefs.defaults.string(forKey: "searxngURL") ?? "" }

    // MARK: Tools as the model sees them

    static let tools: [[String: Any]] = [
        ["type": "function", "function": [
            "name": "web_search",
            "description": "Search the web. Returns the top results with title, URL and a snippet. Use it for anything recent, specific or uncertain.",
            "parameters": ["type": "object", "properties": ["query": ["type": "string", "description": "What to search for"]], "required": ["query"]],
        ]],
        ["type": "function", "function": [
            "name": "image_search",
            "description": "Find pictures on the web. Returns image URLs with the page each comes from. Use it when seeing something helps: what a thing, place, person or product looks like, or a diagram.",
            "parameters": ["type": "object", "properties": ["query": ["type": "string", "description": "What to find pictures of"]], "required": ["query"]],
        ]],
        ["type": "function", "function": [
            "name": "fetch_url",
            "description": "Read a public web page as text, for details a search snippet doesn't give.",
            "parameters": ["type": "object", "properties": ["url": ["type": "string", "description": "An http or https URL"]], "required": ["url"]],
        ]],
    ]

    static func payload(_ failure: Failure) -> String {
        json(["ok": false, "error": ["code": failure.code, "message": failure.message, "user_action_required": failure.needsUser]])
    }

    static func payload(_ results: [Result]) -> String {
        json(["ok": true, "provider": provider.title, "results": results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] }])
    }

    static func payload(_ images: [ImageResult]) -> String {
        json(["ok": true, "provider": provider.title, "images": images.map { ["title": $0.title, "image_url": $0.image, "page_url": $0.page] }])
    }

    static func payload(_ page: Page) -> String {
        json(["ok": true, "url": page.url, "content": page.text, "truncated": page.truncated])
    }

    private static func json(_ object: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: Search

    static func search(_ query: String) async -> Swift.Result<[Result], Failure> {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery))
        guard !trimmed.isEmpty else { return .failure(Failure(code: "invalid_arguments", message: "web_search needs a non-empty query.")) }
        do {
            let rows: [Result]
            switch provider {
            case .duckduckgo: rows = try await duckDuckGo(trimmed)
            case .brave: rows = try await brave(trimmed)
            case .searxng: rows = try await searxng(trimmed)
            }
            var results: [Result] = []
            for row in rows {
                if let clean = sanitize(title: row.title, url: row.url, snippet: row.snippet), !results.contains(where: { $0.url == clean.url }) {
                    results.append(clean)
                }
                if results.count >= resultCount { break }
            }
            return .success(results)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure(code: "request_failed", message: "The search failed: \(error.localizedDescription)"))
        }
    }

    /// Only http(s) links with a host and no embedded credentials reach the model.
    static func sanitize(title: String, url: String, snippet: String) -> Result? {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, url.count <= maxURL, let parts = URLComponents(string: url),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        let cleanTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitle))
        return Result(title: cleanTitle.isEmpty ? host : cleanTitle, url: url,
                      snippet: String(snippet.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxSnippet)))
    }

    private static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        return URLSession(configuration: configuration)
    }

    private static func check(_ response: URLResponse, _ source: String) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return
        case 401: throw Failure(code: "invalid_authentication", message: "\(source) rejected the key (HTTP 401). Check it in \(settingsHint).", needsUser: true)
        case 402: throw Failure(code: "insufficient_funds", message: "\(source) says the account is out of credits (HTTP 402).", needsUser: true)
        case 403: throw Failure(code: "plan_access", message: "\(source) denied access for this plan (HTTP 403).", needsUser: true)
        case 429: throw Failure(code: "rate_limited", message: "\(source) is limiting requests (HTTP 429). Try again shortly.")
        case 500...: throw Failure(code: "provider_unavailable", message: "\(source) is unavailable (HTTP \(status)).")
        default: throw Failure(code: "request_failed", message: "\(source) answered HTTP \(status).")
        }
    }

    /// DuckDuckGo's HTML results page, the no-JavaScript version, which needs no key.
    private static func duckDuckGo(_ query: String) async throws -> [Result] {
        var request = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: query)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await session.data(for: request)
        try check(response, "DuckDuckGo")
        let html = String(decoding: data, as: UTF8.self)
        if html.range(of: "anomaly-modal", options: .caseInsensitive) != nil || html.contains("challenge-form") {
            throw Failure(code: "rate_limited", message: "DuckDuckGo asked to verify a person is searching. Try again later, or choose Brave Search or SearXNG in \(settingsHint).", needsUser: true)
        }
        return parseDuckDuckGo(html)
    }

    static func parseDuckDuckGo(_ html: String) -> [Result] {
        let link = try! NSRegularExpression(pattern: #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let snippet = try! NSRegularExpression(pattern: #"class="result__snippet"[^>]*>(.*?)</a>"#, options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        let links = link.matches(in: html, range: range)
        let snippets = snippet.matches(in: html, range: range)
        func group(_ match: NSTextCheckingResult, _ index: Int) -> String {
            Range(match.range(at: index), in: html).map { String(html[$0]) } ?? ""
        }
        return links.enumerated().compactMap { index, match in
            var href = HTMLText.decodeEntities(group(match, 1))
            // Some results are wrapped in DuckDuckGo's redirect: //duckduckgo.com/l/?uddg=<the address>
            if href.contains("duckduckgo.com/l/"), let target = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href)?
                .queryItems?.first(where: { $0.name == "uddg" })?.value {
                href = target
            }
            if href.contains("duckduckgo.com/y.js") { return nil }  // an advert
            let text = index < snippets.count ? group(snippets[index], 1) : ""
            return Result(title: HTMLText.inline(group(match, 2)), url: href, snippet: HTMLText.inline(text))
        }
    }

    private static func brave(_ query: String) async throws -> [Result] {
        guard let key = Keychain.read("braveSearchKey"), !key.isEmpty else {
            throw Failure(code: "missing_api_key", message: "No Brave Search API key is set. Add one in \(settingsHint).", needsUser: true)
        }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: String(resultCount))]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response, "Brave Search")
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = ((object?["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return rows.map { Result(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", snippet: HTMLText.inline($0["description"] as? String ?? "")) }
    }

    private static func searxng(_ query: String) async throws -> [Result] {
        let base = searxngURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty, var components = URLComponents(string: base + "/search") else {
            throw Failure(code: "missing_api_key", message: "No SearXNG address is set. Add one in \(settingsHint).", needsUser: true)
        }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw Failure(code: "invalid_arguments", message: "The SearXNG address isn’t valid.", needsUser: true) }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response, "SearXNG")
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(code: "invalid_response", message: "SearXNG didn’t answer with JSON. Turn on the JSON format in its settings.yml.", needsUser: true)
        }
        return ((object["results"] as? [[String: Any]]) ?? []).map {
            Result(title: $0["title"] as? String ?? "", url: $0["url"] as? String ?? "", snippet: $0["content"] as? String ?? "")
        }
    }

    // MARK: Images

    static func images(_ query: String) async -> Swift.Result<[ImageResult], Failure> {
        let trimmed = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxQuery))
        guard !trimmed.isEmpty else { return .failure(Failure(code: "invalid_arguments", message: "image_search needs a non-empty query.")) }
        do {
            let rows: [ImageResult]
            switch provider {
            case .duckduckgo: rows = try await duckDuckGoImages(trimmed)
            case .brave: rows = try await braveImages(trimmed)
            case .searxng: rows = try await searxngImages(trimmed)
            }
            var results: [ImageResult] = []
            for row in rows where sanitize(title: row.title, url: row.image, snippet: "") != nil && !results.contains(where: { $0.image == row.image }) {
                let thumbnail = sanitize(title: "", url: row.thumbnail, snippet: "") != nil ? row.thumbnail : row.image
                results.append(ImageResult(title: String(HTMLText.inline(row.title).prefix(maxTitle)), image: row.image, thumbnail: thumbnail,
                                           page: sanitize(title: "", url: row.page, snippet: "") != nil ? row.page : row.image,
                                           width: row.width, height: row.height))
                if results.count >= 8 { break }
            }
            return .success(results)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(Failure(code: "request_failed", message: "The image search failed: \(error.localizedDescription)"))
        }
    }

    private static let browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// DuckDuckGo's image results: a token from the results page, then its JSON list.
    private static func duckDuckGoImages(_ query: String) async throws -> [ImageResult] {
        var page = URLComponents(string: "https://duckduckgo.com/")!
        page.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "iax", value: "images"), URLQueryItem(name: "ia", value: "images")]
        var first = URLRequest(url: page.url!)
        first.setValue(browser, forHTTPHeaderField: "User-Agent")
        let (html, response) = try await session.data(for: first)
        try check(response, "DuckDuckGo")
        let text = String(decoding: html, as: UTF8.self)
        guard let range = text.range(of: #"vqd=["']?[0-9-]+"#, options: .regularExpression),
              let token = text[range].split(whereSeparator: { $0 == "=" || $0 == "\"" || $0 == "'" }).last else {
            throw Failure(code: "provider_unavailable", message: "DuckDuckGo’s image search didn’t answer as expected. Try again, or choose Brave Search or SearXNG in \(settingsHint).")
        }
        var list = URLComponents(string: "https://duckduckgo.com/i.js")!
        list.queryItems = [URLQueryItem(name: "l", value: "us-en"), URLQueryItem(name: "o", value: "json"), URLQueryItem(name: "q", value: query),
                           URLQueryItem(name: "vqd", value: String(token)), URLQueryItem(name: "f", value: ",,,,,"), URLQueryItem(name: "p", value: "1")]
        var second = URLRequest(url: list.url!)
        second.setValue(browser, forHTTPHeaderField: "User-Agent")
        second.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
        let (data, listResponse) = try await session.data(for: second)
        try check(listResponse, "DuckDuckGo")
        let rows = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return rows.map {
            ImageResult(title: $0["title"] as? String ?? "", image: $0["image"] as? String ?? "", thumbnail: $0["thumbnail"] as? String ?? "",
                        page: $0["url"] as? String ?? "", width: $0["width"] as? Int, height: $0["height"] as? Int)
        }
    }

    private static func braveImages(_ query: String) async throws -> [ImageResult] {
        guard let key = Keychain.read("braveSearchKey"), !key.isEmpty else {
            throw Failure(code: "missing_api_key", message: "No Brave Search API key is set. Add one in \(settingsHint).", needsUser: true)
        }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/images/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "10")]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try check(response, "Brave Search")
        let rows = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return rows.map {
            ImageResult(title: $0["title"] as? String ?? "", image: ($0["properties"] as? [String: Any])?["url"] as? String ?? "",
                        thumbnail: ($0["thumbnail"] as? [String: Any])?["src"] as? String ?? "", page: $0["url"] as? String ?? "")
        }
    }

    private static func searxngImages(_ query: String) async throws -> [ImageResult] {
        let base = searxngURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard !base.isEmpty, var components = URLComponents(string: base + "/search") else {
            throw Failure(code: "missing_api_key", message: "No SearXNG address is set. Add one in \(settingsHint).", needsUser: true)
        }
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "categories", value: "images")]
        guard let url = components.url else { throw Failure(code: "invalid_arguments", message: "The SearXNG address isn’t valid.", needsUser: true) }
        let (data, response) = try await session.data(for: URLRequest(url: url))
        try check(response, "SearXNG")
        let rows = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        return rows.map {
            ImageResult(title: $0["title"] as? String ?? "", image: $0["img_src"] as? String ?? "",
                        thumbnail: $0["thumbnail_src"] as? String ?? "", page: $0["url"] as? String ?? "")
        }
    }

    /// Whether the app may load a picture from this address: http(s), and not this Mac or a private
    /// network given as a name or a literal address (a model could otherwise point it at local services).
    static func loadable(_ address: String) -> Bool {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".internal") { return false }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return isPublic(withUnsafeBytes(of: &v4) { Array($0) }) }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if inet_pton(AF_INET6, bare, &v6) == 1 { return isPublic(withUnsafeBytes(of: &v6) { Array($0) }) }
        return true
    }

    // MARK: Reading a page

    static func fetch(_ address: String) async -> Swift.Result<Page, Failure> {
        let limit = pageCharacters
        var current = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects.shared, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            // Redirects are followed by hand, so every hop passes the same checks.
            for _ in 0...maxRedirects {
                let url = try validate(current)
                try await requirePublic(url.host ?? "")
                var request = URLRequest(url: url, timeoutInterval: timeout)
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Nearloop", forHTTPHeaderField: "User-Agent")
                request.setValue("text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await session.bytes(for: request)
                let http = response as? HTTPURLResponse
                let status = http?.statusCode ?? 0
                if [301, 302, 303, 307, 308].contains(status) {
                    guard let location = http?.value(forHTTPHeaderField: "Location"), let next = URL(string: location, relativeTo: url) else {
                        throw Failure(code: "invalid_response", message: "The site redirected without saying where.")
                    }
                    current = next.absoluteString
                    continue
                }
                try check(response, "The web server")
                let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                let readable: Set<String> = ["", "text/html", "application/xhtml+xml", "text/plain", "text/markdown", "application/json"]
                guard readable.contains(type) else {
                    throw Failure(code: "invalid_response", message: "That page is \(type), not a web page or text, so it can’t be read.")
                }
                var body = Data()
                var cut = false
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= maxBody { cut = true; break }
                }
                var text = ["", "text/html", "application/xhtml+xml"].contains(type) ? HTMLText.readable(String(decoding: body, as: UTF8.self))
                                                                                     : String(decoding: body, as: UTF8.self)
                if text.count > limit { text = String(text.prefix(limit)); cut = true }
                return .success(Page(url: current, text: text, truncated: cut))
            }
            throw Failure(code: "request_failed", message: "Gave up after \(maxRedirects) redirects.")
        } catch let failure as Failure {
            return .failure(failure)
        } catch let error as URLError where error.code == .timedOut {
            return .failure(Failure(code: "request_failed", message: "The page didn’t respond within \(Int(timeout)) seconds."))
        } catch {
            return .failure(Failure(code: "request_failed", message: "Reading the page failed: \(error.localizedDescription)"))
        }
    }

    static func validate(_ address: String) throws -> URL {
        guard !address.isEmpty, address.count <= maxURL, let url = URL(string: address) else {
            throw Failure(code: "invalid_arguments", message: "fetch_url needs an http(s) URL up to \(maxURL) characters.")
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw Failure(code: "invalid_arguments", message: "Only http and https pages can be read.") }
        guard let host = url.host, !host.isEmpty else { throw Failure(code: "invalid_arguments", message: "The URL has no host.") }
        guard url.user == nil, url.password == nil else { throw Failure(code: "invalid_arguments", message: "URLs with a user name or password aren’t allowed.") }
        return url
    }

    /// Refuses hosts that resolve to this Mac or a private network (loopback, LAN, link-local, carrier NAT,
    /// IPv6 local), so a page can't point the model at the Kapitsa server, a router or other local services.
    static func requirePublic(_ host: String) async throws {
        let addresses = await Task.detached { resolve(host) }.value
        guard !addresses.isEmpty else { throw Failure(code: "request_failed", message: "Couldn’t find the site \(host).") }
        if addresses.contains(where: { !isPublic($0) }) {
            throw Failure(code: "invalid_arguments", message: "Pages on this Mac or a private network can’t be read.")
        }
    }

    private static func resolve(_ host: String) -> [[UInt8]] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var found: [[UInt8]] = []
        for info in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let address = info.pointee.ai_addr else { continue }
            if info.pointee.ai_family == AF_INET {
                var v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                found.append(withUnsafeBytes(of: &v4) { Array($0) })
            } else if info.pointee.ai_family == AF_INET6 {
                var v6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                found.append(withUnsafeBytes(of: &v6) { Array($0) })
            }
        }
        return found
    }

    static func isPublic(_ bytes: [UInt8]) -> Bool {
        var b = bytes
        // An IPv4-mapped IPv6 address (::ffff:a.b.c.d) is judged as the IPv4 address.
        if b.count == 16, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { b = Array(b[12...]) }
        if b.count == 4 {
            switch (b[0], b[1]) {
            case (0, _), (10, _), (127, _): return false
            case (100, 64...127): return false            // carrier-grade NAT
            case (169, 254): return false                  // link-local, cloud metadata
            case (172, 16...31), (192, 168): return false
            case (192, 0) where b[2] == 0 || b[2] == 2: return false
            case (198, 18...19): return false              // benchmarking
            case (198, 51) where b[2] == 100: return false // documentation
            case (203, 0) where b[2] == 113: return false  // documentation
            case (224...255, _): return false              // multicast and reserved
            default: return true
            }
        }
        guard b.count == 16 else { return false }
        if b.allSatisfy({ $0 == 0 }) || (b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1) { return false }  // :: and ::1
        if b[0] & 0xfe == 0xfc { return false }            // unique local fc00::/7
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }  // link-local fe80::/10
        if b[0] == 0xff { return false }                   // multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return false }  // documentation
        return true
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        static let shared = NoRedirects()
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// Turns HTML into text a model can read: the main content, with headings, list items and paragraphs on
/// their own lines, and scripts, styles and navigation left out.
enum HTMLText {
    static func readable(_ html: String) -> String {
        var text = html
        // The article or main element when the page has one, else the body.
        for tag in ["article", "main", "body"] {
            if let range = text.range(of: "(?s)<\(tag)[\\s>].*</\(tag)>", options: [.regularExpression, .caseInsensitive]) {
                text = String(text[range]); break
            }
        }
        let dropped = ["script", "style", "noscript", "svg", "template", "iframe", "nav", "footer", "header", "form", "aside", "button", "select"]
        for tag in dropped {
            text = text.replacingOccurrences(of: "(?s)<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<h([1-6])\\b[^>]*>", with: "\n\n## ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n- ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<(br|hr)\\b[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</(p|div|section|h[1-6]|tr|table|ul|ol|pre|blockquote|dd|dt)>", with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "</t[dh]>", with: " | ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "[ \\t\\u{00A0}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for line in lines {
            if line.isEmpty || line == "-" { if out.last?.isEmpty == false { out.append("") } } else { out.append(line) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A fragment of HTML on one line: tags removed, entities decoded.
    static func inline(_ html: String) -> String {
        decodeEntities(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'", "mdash": "—", "ndash": "–",
                     "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™"]
        let pattern = try! NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z0-9]+);")
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            let entity = String(text[name])
            if let value = named[entity] {
                result += value
            } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"), let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()), let scalar = Unicode.Scalar(code) {
                result.unicodeScalars.append(scalar)
            } else {
                result += text[whole]
            }
            last = whole.upperBound
        }
        return result + text[last...]
    }
}

/// A secret kept in the login keychain, such as the Brave Search key.
enum Keychain {
    private static let service = "com.adityak2128.nearloop"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func write(_ account: String, _ value: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
