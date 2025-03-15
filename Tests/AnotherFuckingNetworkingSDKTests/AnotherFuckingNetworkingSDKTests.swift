import XCTest
@testable import AnotherFuckingNetworkingSDK

final class AnotherFuckingNetworkingSDKTests: XCTestCase {
    // Mock API client for testing
    var mockClient: APIClient!
    
    override func setUp() {
        super.setUp()
        mockClient = APIClient(baseURL: URL(string: "https://example.com"))
    }
    
    override func tearDown() {
        mockClient = nil
        super.tearDown()
    }

    func testAPIClientInitialization() {
        XCTAssertNotNil(mockClient)
        XCTAssertEqual(mockClient.baseURL?.absoluteString, "https://example.com")
    }
    
    func testRequestBuilding() {
        // Create a sample request
        let request = SampleGetRequest(id: 123)
        
        // Test path construction
        XCTAssertEqual(request.path, "sample/123")
        
        // Test method type
        XCTAssertEqual(request.method, .get)
        
        // Test URL construction
        let url = request.makeURL(baseURL: URL(string: "https://example.com")!)
        XCTAssertEqual(url?.absoluteString, "https://example.com/sample/123")
    }
    
    func testRequestWithQueryParameters() {
        // Create a sample request with query parameters
        let request = SampleRequestWithQuery(query: "test", limit: 20)
        
        // Test URL construction with query parameters
        let url = request.makeURL(baseURL: URL(string: "https://example.com")!)
        
        // Verify that the URL contains the expected query parameters
        XCTAssertTrue(url?.absoluteString.contains("search=test") ?? false)
        XCTAssertTrue(url?.absoluteString.contains("limit=20") ?? false)
    }
    
    func testRandomNonceGeneration() {
        let nonce1 = String.randomNonce(length: 16)
        let nonce2 = String.randomNonce(length: 16)
        
        XCTAssertNotNil(nonce1)
        XCTAssertNotNil(nonce2)
        XCTAssertEqual(nonce1?.count, 16)
        XCTAssertEqual(nonce2?.count, 16)
        XCTAssertNotEqual(nonce1, nonce2) // Should be random
    }
}

// MARK: - Test helpers

// Sample request for testing
struct SampleGetRequest: Request {
    typealias ReturnType = SampleResponse
    
    let id: Int
    var path: String { "sample/\(id)" }
}

// Sample request with query parameters
struct SampleRequestWithQuery: Request {
    typealias ReturnType = SampleResponse
    
    let query: String
    let limit: Int
    
    var path: String { "search" }
    
    var queryItems: [URLQueryItem]? {
        [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
    }
}

// Sample response structure
struct SampleResponse: Decodable {
    let id: Int
    let name: String
}
