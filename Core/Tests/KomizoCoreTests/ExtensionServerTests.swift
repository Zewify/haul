import Foundation
import Testing
@testable import KomizoCore

final class RecordingDelegate: ExtensionServerDelegate, @unchecked Sendable {
    let lock = NSLock()
    var approve = true
    var pairRequests: [PairRequest] = []
    var received: [(IncomingDownload, Bool)] = []
    let id = UUID()

    func server(_ server: ExtensionServer, approvePairing request: PairRequest) async -> Bool {
        lock.withLock { pairRequests.append(request) }
        return approve
    }

    func server(_ server: ExtensionServer, receive download: IncomingDownload, media: Bool) async throws -> UUID {
        lock.withLock { received.append((download, media)) }
        return id
    }

    var inspected: [InspectRequest] = []
    func server(_ server: ExtensionServer, inspect request: InspectRequest) async -> [InspectedMedia] {
        lock.withLock { inspected.append(request) }
        return request.items.map { InspectedMedia(url: $0.url, duration: 6, video: true, audio: false, width: 720, height: 1280) }
    }
}

struct ExtensionServerTests {
    let delegate = RecordingDelegate()
    let token = "secret-token-1234567890"

    func makeServer(media: Bool = false) throws -> ExtensionServer {
        let status = ServerStatus(version: "0.1", features: .init(media: media))
        let server = ExtensionServer(port: 0, token: token, status: status, delegate: delegate)
        try server.start()
        return server
    }

    func send(_ server: ExtensionServer, _ method: String, _ path: String, body: String? = nil,
              origin: String? = "chrome-extension://abcdefgh", bearer: String? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)\(path)")!)
        request.httpMethod = method
        if let body { request.httpBody = Data(body.utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as! HTTPURLResponse).statusCode, json)
    }

    @Test func statusIsOpenToAnyone() async throws {
        let server = try makeServer(media: true)
        defer { server.stop() }
        let (status, json) = try await send(server, "GET", "/status", origin: nil)
        #expect(status == 200)
        #expect(json["app"] as? String == "komizo")
        #expect((json["features"] as? [String: Any])?["media"] as? Bool == true)
        #expect(json["paired"] as? Bool == false)
    }

    @Test func pairingApprovedReturnsTheToken() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (status, json) = try await send(server, "POST", "/pair", body: #"{"client":"chrome","name":"Google Chrome"}"#)
        #expect(status == 200)
        #expect(json["token"] as? String == token)
        #expect(delegate.pairRequests.first?.name == "Google Chrome")
    }

    @Test func pairingDeniedIs403() async throws {
        delegate.approve = false
        let server = try makeServer()
        defer { server.stop() }
        let (status, _) = try await send(server, "POST", "/pair", body: #"{"client":"chrome","name":"Chrome"}"#)
        #expect(status == 403)
    }

    @Test func pairingFromAWebPageIsRefused() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (status, _) = try await send(server, "POST", "/pair", body: #"{"client":"chrome","name":"Chrome"}"#, origin: "https://evil.example")
        #expect(status == 403)
        #expect(delegate.pairRequests.isEmpty)
        let (noOrigin, _) = try await send(server, "POST", "/pair", body: #"{"client":"chrome","name":"Chrome"}"#, origin: nil)
        #expect(noOrigin == 403)
    }

    @Test func downloadsNeedTheToken() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let body = #"{"url":"https://example.com/a.zip"}"#
        let (missing, _) = try await send(server, "POST", "/downloads", body: body)
        #expect(missing == 401)
        let (wrong, _) = try await send(server, "POST", "/downloads", body: body, bearer: "nope")
        #expect(wrong == 401)
        #expect(delegate.received.isEmpty)
    }

    @Test func goodDownloadIsHandedToTheDelegate() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let body = #"{"url":"https://example.com/a.zip","filename":"a.zip","referrer":"https://example.com/","cookies":"s=1","userAgent":"UA","headers":{"X-A":"1"}}"#
        let (status, json) = try await send(server, "POST", "/downloads", body: body, bearer: token)
        #expect(status == 201)
        #expect(json["id"] as? String == delegate.id.uuidString)
        let received = try #require(delegate.received.first)
        #expect(received.0.url == "https://example.com/a.zip")
        #expect(received.0.cookies == "s=1")
        #expect(received.0.headers?["X-A"] == "1")
        #expect(received.1 == false)
        let (paired, _) = try await send(server, "GET", "/status", origin: nil)
        _ = paired
    }

    @Test func rejectsNonHTTPURL() async throws {
        let server = try makeServer()
        defer { server.stop() }
        for url in ["file:///etc/passwd", "javascript:alert(1)", "ftp://x/y", "not a url", ""] {
            let (status, _) = try await send(server, "POST", "/downloads", body: "{\"url\":\"\(url)\"}", bearer: token)
            #expect(status == 400, "\(url)")
        }
        #expect(delegate.received.isEmpty)
    }

    @Test func badJSONIs400AndUnknownIs404() async throws {
        let server = try makeServer()
        defer { server.stop() }
        let (bad, _) = try await send(server, "POST", "/downloads", body: "{nope", bearer: token)
        #expect(bad == 400)
        let (unknown, _) = try await send(server, "GET", "/nothing", origin: nil)
        #expect(unknown == 404)
    }

    @Test func mediaIsAccepted() async throws {
        let server = try makeServer(media: true)
        defer { server.stop() }
        let body = #"{"url":"https://example.com/v.m3u8","kind":"hls"}"#
        let (status, _) = try await send(server, "POST", "/media", body: body, bearer: token)
        #expect(status == 201)
        #expect(delegate.received.last?.1 == true)
        #expect(delegate.received.last?.0.kind == "hls")
        let off = try makeServer(media: false)
        defer { off.stop() }
        let (absent, _) = try await send(off, "POST", "/media", body: body, bearer: token)
        #expect(absent == 404, "a build without the grabber still says so")
    }

    @Test func preflightIsAnswered() async throws {
        let server = try makeServer()
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/downloads")!)
        request.httpMethod = "OPTIONS"
        request.setValue("chrome-extension://abc", forHTTPHeaderField: "Origin")
        let (_, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 204)
        #expect(http.value(forHTTPHeaderField: "Access-Control-Allow-Headers")?.contains("Authorization") == true)
    }

    @Test func inspectNeedsTheTokenAndKeepsToWebAddresses() async throws {
        let server = try makeServer(media: true)
        defer { server.stop() }
        let body = #"{"items":[{"url":"https://v.example/a.mp4","kind":"file","cookies":"s=1"},{"url":"file:///etc/passwd","kind":"file"}],"referrer":"https://page.example/"}"#
        let (refused, _) = try await send(server, "POST", "/inspect", body: body)
        #expect(refused == 401)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/inspect")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("chrome-extension://abcdefgh", forHTTPHeaderField: "Origin")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as! HTTPURLResponse).statusCode == 200)
        let found = try JSONDecoder().decode([InspectedMedia].self, from: data)
        #expect(found.map(\.url) == ["https://v.example/a.mp4"], "the file URL never reaches the delegate")
        #expect(found.first?.duration == 6)
        #expect(delegate.lock.withLock { delegate.inspected.first?.items.first?.cookies } == "s=1")
    }

    @Test func tokenCanBeRotated() async throws {
        let server = try makeServer()
        defer { server.stop() }
        server.token = "new-token"
        let (old, _) = try await send(server, "POST", "/downloads", body: #"{"url":"https://e.com/a"}"#, bearer: token)
        #expect(old == 401)
        let (new, _) = try await send(server, "POST", "/downloads", body: #"{"url":"https://e.com/a"}"#, bearer: "new-token")
        #expect(new == 201)
    }
}
