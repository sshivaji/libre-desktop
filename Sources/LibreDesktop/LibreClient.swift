import Foundation
import CryptoKit

struct LibreAccount: Codable {
    var email: String
    var password: String
    var host: String
    var token: String = ""
    var userID: String = ""
    var expires: Double = 0
    var selectedID: String?
    var displayName: String?
    var isAuthenticated: Bool { !token.isEmpty && !userID.isEmpty && expires > Date().timeIntervalSince1970 + 60 }
}

final class NoLibreRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Credentials may only move via a validated LibreLinkUp region response,
        // never through an arbitrary HTTP redirect.
        completionHandler(nil)
    }
}

final class LibreClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let regions = ["Auto": "api.libreview.io", "AE": "api-ae.libreview.io", "AP": "api-ap.libreview.io", "AU": "api-au.libreview.io", "CA": "api-ca.libreview.io", "CN": "api-cn.myfreestyle.cn", "DE": "api-de.libreview.io", "EU": "api-eu.libreview.io", "EU2": "api-eu2.libreview.io", "FR": "api-fr.libreview.io", "JP": "api-jp.libreview.io", "LA": "api-la.libreview.io", "RU": "api.libreview.ru", "US": "api-us.libreview.io"]
    private let transport: Transport
    init(transport: Transport? = nil) {
        if let transport { self.transport = transport; return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: NoLibreRedirects(), delegateQueue: nil)
        self.transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LibreError.invalidResponse }
            return (data, http)
        }
    }
    static func accountHash(_ userID: String) -> String { SHA256.hash(data: Data(userID.utf8)).map { String(format: "%02x", $0) }.joined() }

    private func request(host: String, path: String, account: LibreAccount? = nil, body: [String: String]? = nil) async throws -> [String: Any] {
        guard Self.regions.values.contains(host), let url = URL(string: "https://\(host)\(path)") else { throw LibreError.unsupportedRegion }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("llu.ios", forHTTPHeaderField: "product")
        request.setValue("4.16.0", forHTTPHeaderField: "version")
        if let account {
            guard !account.token.isEmpty, !account.userID.isEmpty else { throw LibreError.expired }
            request.setValue("Bearer " + account.token, forHTTPHeaderField: "Authorization")
            request.setValue(Self.accountHash(account.userID), forHTTPHeaderField: "Account-Id")
        }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as LibreError { throw error }
        catch { throw LibreError.offline }
        guard data.count <= 5 * 1024 * 1024 else { throw LibreError.invalidResponse }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let status = (json?["status"] as? NSNumber)?.intValue
        if response.statusCode == 429 || status == 429 {
            let nested = ((json?["data"] as? [String: Any])?["data"] as? [String: Any])?["lockout"] as? NSNumber
            let header = response.value(forHTTPHeaderField: "Retry-After")
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let dateDelay = header.flatMap { formatter.date(from: $0) }.map { Int(ceil($0.timeIntervalSinceNow)) }
            let delay = Int(header ?? "") ?? dateDelay ?? nested?.intValue ?? 300
            throw LibreError.throttled(max(60, min(delay, 86400)))
        }
        let step = (json?["data"] as? [String: Any])?["step"] as? [String: Any]
        if status == 4 || step != nil {
            if (step?["type"] as? String)?.lowercased() == "tou" { throw LibreError.termsRequired }
            throw LibreError.accountAction
        }
        if status == 2 { throw LibreError.credentials }
        if response.statusCode == 401 { throw LibreError.expired }
        if response.statusCode == 403 { throw LibreError.accessDenied }
        if response.statusCode >= 500 { throw LibreError.server }
        guard (200..<300).contains(response.statusCode), let json, status == 0 else { throw LibreError.invalidResponse }
        return json
    }

    func authenticate(_ input: LibreAccount) async throws -> LibreAccount {
        var account = input
        account.token = ""; account.userID = ""; account.expires = 0
        var visited = Set<String>()
        for _ in 0..<4 {
            guard visited.insert(account.host).inserted else { throw LibreError.unsupportedRegion }
            let response = try await request(host: account.host, path: "/llu/auth/login", body: ["email": account.email, "password": account.password])
            guard let data = response["data"] as? [String: Any] else { throw LibreError.invalidResponse }
            if data["redirect"] as? Bool == true {
                var region = (data["region"] as? String ?? "").uppercased()
                if ["GB", "UK"].contains(region) { region = "EU2" }
                guard let host = Self.regions[region] else { throw LibreError.unsupportedRegion }
                account.host = host; continue
            }
            guard let ticket = data["authTicket"] as? [String: Any], let token = ticket["token"] as? String, !token.isEmpty,
                  let expires = GlucoseReading.number(ticket["expires"]), expires > Date().timeIntervalSince1970,
                  let user = data["user"] as? [String: Any], let id = user["id"] as? String, !id.isEmpty else { throw LibreError.invalidResponse }
            account.token = token; account.userID = id; account.expires = expires
            return account
        }
        throw LibreError.unsupportedRegion
    }
    func connections(_ account: LibreAccount) async throws -> [LibreConnection] {
        let json = try await request(host: account.host, path: "/llu/connections", account: account)
        guard let raw = json["data"] as? [[String: Any]] else { throw LibreError.invalidResponse }
        let connections = raw.compactMap { LibreConnection.parse($0) }
        guard connections.count == raw.count else { throw LibreError.invalidResponse }
        return connections
    }
    func graph(_ account: LibreAccount, id: String) async throws -> GlucoseSnapshot {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !id.isEmpty, id.count <= 128, id.unicodeScalars.allSatisfy(allowed.contains) else { throw LibreError.invalidResponse }
        let json = try await request(host: account.host, path: "/llu/connections/\(id)/graph", account: account)
        guard let data = json["data"] as? [String: Any] else { throw LibreError.invalidResponse }
        return try GlucoseSnapshot.parse(data, expectedID: id)
    }
}
