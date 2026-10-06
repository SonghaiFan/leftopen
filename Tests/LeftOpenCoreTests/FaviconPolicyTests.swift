import Foundation
import XCTest
@testable import LeftOpenCore

final class FaviconPolicyTests: XCTestCase {
    func testOnlySameOriginHTTPImagesAreAllowed() throws {
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:3000/"))
        for value in ["/favicon.ico", "icons/icon.png", "http://127.0.0.1:3000/icon"] {
            let url = try XCTUnwrap(URL(string: value, relativeTo: origin)?.absoluteURL)
            XCTAssertTrue(FaviconPolicy.isSameOrigin(url, as: origin))
        }
        for value in ["https://example.com/icon", "//example.com/icon", "https://127.0.0.1:3000/icon",
                      "http://127.0.0.1:3001/icon", "file:///tmp/icon", "data:image/png;base64,AA==",
                      "http://user:password@127.0.0.1:3000/icon"] {
            let url = try XCTUnwrap(URL(string: value, relativeTo: origin)?.absoluteURL)
            XCTAssertFalse(FaviconPolicy.isSameOrigin(url, as: origin), value)
        }
        XCTAssertTrue(FaviconPolicy.isSameOrigin(URL(string: "https://example.com:443/icon")!,
                                               as: URL(string: "https://example.com/")!))
    }

    func testSelfSignedCertificatesAreLimitedToLiteralLoopback() {
        for host in ["127.0.0.1", "::1", "[::1]"] {
            XCTAssertTrue(FaviconPolicy.allowsSelfSignedCertificate(host: host))
        }
        for host in ["example.com", "192.168.1.20", "localhost.example.com", "localhost"] {
            XCTAssertFalse(FaviconPolicy.allowsSelfSignedCertificate(host: host))
        }
    }
}
