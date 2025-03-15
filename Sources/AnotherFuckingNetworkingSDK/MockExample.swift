import Foundation

// This file contains example code showing how to use the MockAPIClient in tests.
// It's not part of the actual library implementation.

#if DEBUG

// Example test class (would typically be in your test target)
/*
class APIClientTests {
    
    var mockClient: MockAPIClient!
    
    func setUp() {
        mockClient = MockAPIClient()
    }
    
    func tearDown() {
        mockClient.resetMocks()
        mockClient = nil
    }
    
    func testFetchUser() async throws {
        // 1. Create mock data
        let mockUser = User(id: 123, name: "Test User")
        
        // 2. Register the mock response
        mockClient.mock(GetUserRequest.self, with: mockUser)
        
        // 3. Call the method that would use the API
        let user = try await mockClient.send(GetUserRequest(userID: 123))
        
        // 4. Verify results
        XCTAssertEqual(user.id, 123)
        XCTAssertEqual(user.name, "Test User")
        
        // 5. Verify the request was made
        XCTAssertTrue(mockClient.calledRequests.contains("users/123"))
    }
    
    func testPaginatedRequest() async throws {
        // 1. Create mock data
        let mockUsers = [
            User(id: 1, name: "User 1"),
            User(id: 2, name: "User 2")
        ]
        let mockResponse = PaginatedResponse<User>(
            items: mockUsers,
            currentPage: 1,
            totalPages: 1
        )
        
        // 2. Register the mock response
        mockClient.mock(ListUsersRequest.self, with: mockResponse)
        
        // 3. Call the method that would use the API
        let response = try await mockClient.sendPage(ListUsersRequest(page: 1, pageSize: 10))
        
        // 4. Verify results
        XCTAssertEqual(response.items.count, 2)
        XCTAssertEqual(response.items[0].name, "User 1")
        XCTAssertEqual(response.currentPage, 1)
        
        // 5. Verify the request was made
        XCTAssertTrue(mockClient.calledRequests.contains("users?page=1"))
    }
    
    func testErrorHandling() async {
        // 1. Register a mock error
        let mockError = NetworkError.requestFailed(statusCode: 404, data: nil)
        mockClient.mockError(GetUserRequest.self, with: mockError)
        
        // 2. Attempt to call the API
        do {
            _ = try await mockClient.send(GetUserRequest(userID: 999))
            XCTFail("Expected error but got success")
        } catch let error as NetworkError {
            // 3. Verify the correct error is thrown
            if case .requestFailed(let statusCode, _) = error {
                XCTAssertEqual(statusCode, 404)
            } else {
                XCTFail("Wrong error type")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
*/

// Example of integration with your service classes
class UserService {
    private let client: APIClient
    
    // Dependency injection allows for easy mocking
    init(client: APIClient = APIClient.shared) {
        self.client = client
    }
    
    func getUser(id: Int) async throws -> User {
        let request = GetUserRequest(userID: id)
        return try await client.send(request)
    }
    
    func listUsers(page: Int = 1, pageSize: Int = 20) async throws -> PaginatedResponse<User> {
        let request = ListUsersRequest(page: page, pageSize: pageSize)
        return try await client.sendPage(request)
    }
}

#endif 