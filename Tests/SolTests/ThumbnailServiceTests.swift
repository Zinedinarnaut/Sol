import AppKit
import Foundation
import XCTest
@testable import Sol

final class ThumbnailServiceTests: XCTestCase, @unchecked Sendable {
    func testArtworkProviderPrefersExactTitleIDOverSearchOrder() async throws {
        let title = "Exact Artwork Match \(UUID().uuidString)"
        let titleID = String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        ).uppercased()
        let imageData = try makeJPEG(width: 600, height: 840)
        let searchData = Data(
            """
            {
              "response": {
                "docs": [
                  {
                    "title": "A Similar Result",
                    "application_id_s": "0100000000000000",
                    "image_url": "https://www.nintendo.com/media/wrong.jpg"
                  },
                  {
                    "title": "The Exact Result",
                    "application_id_s": "\(titleID)",
                    "image_url": "https://www.nintendo.com/media/correct.jpg"
                  }
                ]
              }
            }
            """.utf8
        )

        MockBackgroundURLProtocol.responseProvider = { request in
            let data: Data
            switch request.url?.host {
            case "api.nlib.cc":
                throw URLError(.resourceUnavailable)
            case "search.nintendo-europe.com":
                data = searchData
            case "www.nintendo.com":
                XCTAssertEqual(request.url?.path, "/media/correct.jpg")
                data = imageData
            default:
                throw URLError(.unsupportedURL)
            }
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": request.url?.host == "www.nintendo.com"
                            ? "image/jpeg"
                            : "application/json"
                    ]
                )
            )
            return (response, data)
        }
        defer {
            MockBackgroundURLProtocol.responseProvider = nil
            ImageCache.shared.remove(forKey: titleID)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBackgroundURLProtocol.self]
        let service = ThumbnailService(session: URLSession(configuration: configuration))
        let game = Game(
            id: titleID,
            title: title,
            titleId: titleID,
            fileURL: URL(fileURLWithPath: "/tmp/\(title).nsp"),
            hoursPlayed: 0,
            lastPlayed: nil
        )

        let image = await service.fetchThumbnail(for: game)

        XCTAssertEqual(image?.size.width, 600)
        XCTAssertEqual(image?.size.height, 840)
    }

    func testFetchBackgroundUpgradesPlatformPreviewToOriginalArtwork() async throws {
        let title = "Background Test \(UUID().uuidString)"
        let imageData = try makeJPEG(width: 2_000, height: 1_000)
        let searchData = Data(
            """
            {
              "response": {
                "docs": [
                  {
                    "image_url_h2x1_s": "https://www.nintendo.com/media/background_image500w.jpg"
                  }
                ]
              }
            }
            """.utf8
        )

        MockBackgroundURLProtocol.responseProvider = { request in
            let data: Data
            switch request.url?.host {
            case "search.nintendo-europe.com":
                data = searchData
            case "www.nintendo.com":
                XCTAssertEqual(request.url?.path, "/media/background.jpg")
                data = imageData
            default:
                throw URLError(.unsupportedURL)
            }
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": request.url?.host == "www.nintendo.com" ? "image/jpeg" : "application/json"]
                )
            )
            return (response, data)
        }
        defer {
            MockBackgroundURLProtocol.responseProvider = nil
            ImageCache.shared.remove(forKey: backgroundCacheKey(for: title))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBackgroundURLProtocol.self]
        let service = ThumbnailService(session: URLSession(configuration: configuration))
        let game = Game(
            id: title,
            title: title,
            titleId: nil,
            fileURL: URL(fileURLWithPath: "/tmp/\(title).nsp"),
            hoursPlayed: 0,
            lastPlayed: nil
        )

        let image = await service.fetchBackground(for: game)

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 2_000)
        XCTAssertEqual(image?.size.height, 1_000)
        XCTAssertNotNil(ImageCache.shared.imageData(forKey: backgroundCacheKey(for: title)))
    }

    func testFetchBackgroundFallsBackToCachedCover() async throws {
        let title = "Cover Fallback Test \(UUID().uuidString)"
        let coverData = try makeJPEG(width: 500, height: 500)
        XCTAssertNotNil(ImageCache.shared.store(data: coverData, forKey: title, fileExtension: "jpg"))

        MockBackgroundURLProtocol.responseProvider = { request in
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/plain"]
                )
            )
            return (response, Data())
        }
        defer {
            MockBackgroundURLProtocol.responseProvider = nil
            ImageCache.shared.remove(forKey: title)
            ImageCache.shared.remove(forKey: backgroundCacheKey(for: title))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBackgroundURLProtocol.self]
        let service = ThumbnailService(session: URLSession(configuration: configuration))
        let game = Game(
            id: title,
            title: title,
            titleId: nil,
            fileURL: URL(fileURLWithPath: "/tmp/\(title).nsp"),
            hoursPlayed: 0,
            lastPlayed: nil
        )

        let image = await service.fetchBackground(for: game)

        XCTAssertNotNil(image)
        XCTAssertEqual(image?.size.width, 500)
        XCTAssertEqual(image?.size.height, 500)
    }

    private func backgroundCacheKey(for title: String) -> String {
        let storedVersion = UserDefaults.standard.integer(forKey: "backgroundCacheVersion")
        let version = max(storedVersion, 2)
        return "\(title):bg-v\(version)"
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(NSColor.systemBlue.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let representation = NSBitmapImageRep(cgImage: image)
        return try XCTUnwrap(
            representation.representation(
                using: .jpeg,
                properties: [.compressionFactor: 0.85]
            )
        )
    }
}

private final class MockBackgroundURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responseProvider: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let provider = try XCTUnwrap(Self.responseProvider)
            let (response, data) = try provider(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
