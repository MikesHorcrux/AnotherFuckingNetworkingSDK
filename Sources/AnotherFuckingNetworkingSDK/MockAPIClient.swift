import Foundation

/// Mock API client for testing purposes
public final class MockAPIClient: APIClient {
    // Storage for mock responses
    private var mockResponses: [String: Any] = [:]
    private var mockErrors: [String: Error] = [:]
    
    // Tracking of called requests for verification
    private(set) public var calledRequests: [String] = []
    
    // Mock delay for simulating network latency
    public var mockDelay: TimeInterval = 0
    
    /// Initialize a mock client
    public override init(baseURL: URL? = URL(string: "https://mock.api"), 
                         urlSession: URLSession = .shared,
                         logger: NetworkingLogger? = nil) {
        super.init(baseURL: baseURL, urlSession: urlSession, logger: logger)
    }
    
    // MARK: - Mock Setup
    
    /// Register a mock response for a specific request type
    public func mock<R: Request, T: Decodable>(_ requestType: R.Type, with response: T) where R.ReturnType == T {
        let key = String(describing: requestType)
        mockResponses[key] = response
    }
    
    /// Register a mock response for a specific request path
    public func mock<R: Request>(_ request: R, with response: R.ReturnType) {
        let path = request.path
        mockResponses[path] = response
    }
    
    /// Register a mock error for a request type
    public func mockError<R: Request>(_ requestType: R.Type, with error: Error) {
        let key = String(describing: requestType)
        mockErrors[key] = error
    }
    
    /// Register a mock error for a specific request path
    public func mockError<R: Request>(_ request: R, with error: Error) {
        let path = request.path
        mockErrors[path] = error
    }
    
    /// Reset all mocks and tracked requests
    public func resetMocks() {
        mockResponses.removeAll()
        mockErrors.removeAll()
        calledRequests.removeAll()
    }
    
    // MARK: - Overridden Network Methods
    
    /// Override send method to return mock responses
    public override func send<R: Request>(_ request: R) async throws -> R.ReturnType {
        // Record that this request was called
        let requestType = String(describing: type(of: request))
        let path = request.path
        calledRequests.append(path)
        
        // Simulate network delay if configured
        if mockDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(mockDelay * 1_000_000_000))
        }
        
        // Check if we should return a mocked error
        if let error = mockErrors[requestType] ?? mockErrors[path] {
            throw error
        }
        
        // Check if we have a mock response
        if let response = mockResponses[requestType] as? R.ReturnType {
            return response
        }
        
        if let response = mockResponses[path] as? R.ReturnType {
            return response
        }
        
        // No mock found, throw a helpful error
        throw NetworkError.unknown(NSError(
            domain: "MockAPIClient",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "No mock registered for request: \(requestType) with path: \(path)"]
        ))
    }
    
    /// Override sendPage for paginated requests
    public override func sendPage<R: PaginatedRequest>(_ request: R) async throws -> PaginatedResponse<R.ReturnType> {
        // Record that this request was called
        let requestType = String(describing: type(of: request))
        let path = request.path
        calledRequests.append("\(path)?page=\(request.page)")
        
        // Simulate network delay if configured
        if mockDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(mockDelay * 1_000_000_000))
        }
        
        // Check if we should return a mocked error
        if let error = mockErrors[requestType] ?? mockErrors[path] {
            throw error
        }
        
        // Check if we have a mock response
        if let response = mockResponses[requestType] as? PaginatedResponse<R.ReturnType> {
            return response
        }
        
        if let response = mockResponses[path] as? PaginatedResponse<R.ReturnType> {
            return response
        }
        
        // No mock found, create a mock paginated response with empty items
        return PaginatedResponse(items: [], currentPage: request.page, totalPages: request.page)
    }
} 