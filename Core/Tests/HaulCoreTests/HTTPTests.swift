import Foundation
import Testing
@testable import HaulCore

struct HTTPTests {
    @Test func parsesARequestWithBody() throws {
        let raw = Data("POST /downloads HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: 7\r\n\r\n{\"a\":1}".utf8)
        let (request, consumed) = try #require(HTTPRequest.parse(raw))
        #expect(request.method == "POST")
        #expect(request.path == "/downloads")
        #expect(request.headers["content-type"] == "application/json")
        #expect(request.body == Data("{\"a\":1}".utf8))
        #expect(consumed == raw.count)
    }

    @Test func waitsForTheWholeBody() {
        let raw = Data("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n123".utf8)
        #expect(HTTPRequest.parse(raw) == nil)
        #expect(HTTPRequest.parse(Data("GET /sta".utf8)) == nil)
    }

    @Test func badContentLengthsAreRejectedNotCrashed() {
        #expect(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-Length: -5\r\n\r\n".utf8)) == nil)
        #expect(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)) == nil)
        #expect(HTTPRequest.parse(Data("POST /x HTTP/1.1\r\nContent-Length: 99999999999999\r\n\r\n".utf8)) == nil)
    }

    @Test func getWithoutBodyAndQueryStripped() throws {
        let (request, _) = try #require(HTTPRequest.parse(Data("GET /status?x=1 HTTP/1.1\r\n\r\n".utf8)))
        #expect(request.path == "/status")
        #expect(request.body.isEmpty)
    }

    @Test func serialisesJSONResponses() throws {
        struct Reply: Encodable { let ok: Bool }
        let response = HTTPResponse(status: 201, json: Reply(ok: true), origin: "chrome-extension://abc")
        let text = String(decoding: response.serialised(), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 201 Created\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: 11\r\n"))
        #expect(text.contains("Access-Control-Allow-Origin: chrome-extension://abc\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
    }
}
