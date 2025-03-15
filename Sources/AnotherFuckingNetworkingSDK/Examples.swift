import Foundation

// MARK: - Example Models and Requests

/// A sample user model.
public struct User: Decodable {
    public let id: Int
    public let name: String
    
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// A sample request object conforming to `Request`.
public struct GetUserRequest: Request {
    public typealias ReturnType = User
    
    public let userID: Int
    public var path: String { "users/\(userID)" }
    public var method: HTTPMethod { .get }
    
    public init(userID: Int) {
        self.userID = userID
    }
}

/// A sample paginated request.
public struct ListUsersRequest: PaginatedRequest {
    public typealias ReturnType = User
    
    public var path: String { "users" }
    public var method: HTTPMethod { .get }
    
    public let page: Int
    public let pageSize: Int
    
    public init(page: Int, pageSize: Int) {
        self.page = page
        self.pageSize = pageSize
    }
}

// MARK: - Example Usage

/// Some test usage example.
@available(iOS 15.0, macOS 12.0, *)
public func exampleAFUsage() async {
    APIClient.shared.baseURL = URL(string: "https://api.example.com")
    APIClient.shared.globalHeaders = ["Authorization": "Bearer YOLO-Token"]
    
    do {
        // 1) Basic user fetch
        let userReq = GetUserRequest(userID: 42)
        let user = try await APIClient.shared.send(userReq)
        print("Got user: \(user.name)")
        
        // 2) Paginated fetch (page 1)
        let listReq = ListUsersRequest(page: 1, pageSize: 10)
        let response = try await APIClient.shared.sendPage(listReq)
        print("Items: \(response.items.count), currentPage: \(response.currentPage)")
        
        // 3) Next page if available
        if let nextPage = response.nextPage {
            let nextReq = ListUsersRequest(page: nextPage, pageSize: 10)
            let nextResp = try await APIClient.shared.sendPage(nextReq)
            print("Fetched next page: \(nextResp.currentPage)")
        }
        
    } catch {
        print("🔥 AnotherFuckingNetworkingSDK error: \(error)")
    }
} 