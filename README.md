# 🔥 AnotherFuckingNetworkingSDK 🔥

Yet another Swift networking library, but this one actually doesn't suck. It's lightweight, powerful, and built for modern Swift with async/await. No bullshit, just clean API calls. ✨

Is it missing functionality? Maybe. But it fucking works, and you can just email < Your email here > with your complaints or contribute. Or don't. Whatever. 🤷‍♂️

## ✨ Features

- ✅ 100% Swift, built for modern concurrency with async/await 🚀
- ✅ Type-safe API requests and responses (so you can stop guessing what the hell your API returns) 🧩
- ✅ Built-in pagination support that doesn't make you want to throw your laptop 💻🪟
- ✅ Clear error handling that actually tells you what went wrong 🚨
- ✅ Request logging with cURL command generation (inspect your requests like a grown-up) 🔍
- ✅ Mocking support that makes testing not completely suck 🧪
- ✅ Zero dependencies because who needs that fucking headache 🏝️
- ✅ Works on iOS 15+, macOS 12+, and other Apple platforms nobody cares about 🍎

## 📦 Installation

### Swift Package Manager

Add the following to your `Package.swift` file, or don't, I'm not your mom: 👩‍👧

```swift
dependencies: [
    .package(url: "https://github.com/MikesHorcrux/AnotherFuckingNetworkingSDK.git", from: "1.0.0")
]
```

Or in Xcode:
1. Go to File → Add Packages... 📁
2. Enter the repository URL: `https://github.com/MikesHorcrux/AnotherFuckingNetworkingSDK.git`
3. Click "Add Package" and wait for Xcode to inevitably freeze for no reason ⏳❄️

## 🚀 Quick Start

### 1. Configure the client 🔧

```swift
import AnotherFuckingNetworkingSDK

// Set up the global shared client (the lazy way)
APIClient.shared.baseURL = URL(string: "https://api.example.com")
APIClient.shared.globalHeaders = ["Authorization": "Bearer YOUR_TOKEN"]

// Or be a fucking professional and create your own instance
let client = APIClient(baseURL: URL(string: "https://api.example.com"))
```

### 2. Define your models 📊

Make sure they conform to `Decodable` or you're gonna have a bad time: 💀

```swift
struct User: Decodable {
    let id: Int
    let name: String
    let email: String
    let isAdmin: Bool
    
    // Handle snake_case if your backend devs hate camelCase
    enum CodingKeys: String, CodingKey {
        case id, name, email
        case isAdmin = "is_admin"
    }
}
```

### 3. Create request types 📝

This is where the magic happens. Each API endpoint gets its own request type: 🪄

```swift
// Simple GET request
struct GetUserRequest: Request {
    typealias ReturnType = User // Tell it what you expect back
    
    let userID: Int
    var path: String { "users/\(userID)" } // Define the endpoint path
}

// POST request with a body
struct CreateUserRequest: Request {
    typealias ReturnType = User
    
    let name: String
    let email: String
    let password: String
    
    var path: String { "users" }
    var method: HTTPMethod { .post } // Override the default GET
    
    // Define the request body
    var body: Data? {
        try? JSONEncoder().encode([
            "name": name,
            "email": email,
            "password": password
        ])
    }
}

// Request with query parameters
struct SearchUsersRequest: Request {
    typealias ReturnType = [User]
    
    let query: String
    let limit: Int
    
    var path: String { "users/search" }
    
    var queryItems: [URLQueryItem]? {
        [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
    }
}

// Request with custom headers
struct AuthenticateRequest: Request {
    typealias ReturnType = AuthResponse
    
    let username: String
    let password: String
    
    var path: String { "auth/login" }
    var method: HTTPMethod { .post }
    
    var headers: [String: String]? {
        ["Content-Type": "application/json"] 
    }
    
    var body: Data? {
        try? JSONEncoder().encode([
            "username": username,
            "password": password
        ])
    }
}
```

### 4. Make API calls with async/await ⚡

```swift
func fetchUser(id: Int) async {
    do {
        let userRequest = GetUserRequest(userID: id)
        let user = try await APIClient.shared.send(userRequest)
        print("Got user: \(user.name), \(user.email)")
    } catch let error as NetworkError {
        handleNetworkError(error)
    } catch {
        print("Some other shit went wrong: \(error)")
    }
}
```

### 5. Paginated requests that don't suck 📄📄📄

```swift
struct ListUsersRequest: PaginatedRequest {
    typealias ReturnType = User
    
    var path: String { "users" }
    let page: Int
    let pageSize: Int
}

func fetchAllUsers() async {
    var currentPage = 1
    var hasMorePages = true
    var allUsers: [User] = []
    
    while hasMorePages {
        do {
            let request = ListUsersRequest(page: currentPage, pageSize: 20)
            let response = try await APIClient.shared.sendPage(request)
            
            allUsers.append(contentsOf: response.items)
            
            // Check if there's a next page
            if let nextPage = response.nextPage {
                currentPage = nextPage
            } else {
                hasMorePages = false
            }
        } catch {
            print("Error fetching users: \(error)")
            hasMorePages = false
        }
    }
    
    print("Fetched a total of \(allUsers.count) users")
}
```

## 🧠 Advanced Usage

### Setting up a proper service layer 🏢

Don't be a barbarian. Structure your API calls in service classes: 🏗️

```swift
class UserService {
    private let client: APIClient
    
    // Dependency injection for testability
    init(client: APIClient = APIClient.shared) {
        self.client = client
    }
    
    func getUser(id: Int) async throws -> User {
        let request = GetUserRequest(userID: id)
        return try await client.send(request)
    }
    
    func createUser(name: String, email: String, password: String) async throws -> User {
        let request = CreateUserRequest(name: name, email: email, password: password)
        return try await client.send(request)
    }
    
    func searchUsers(query: String, limit: Int = 20) async throws -> [User] {
        let request = SearchUsersRequest(query: query, limit: limit)
        return try await client.send(request)
    }
    
    func listUsers(page: Int = 1, pageSize: Int = 20) async throws -> PaginatedResponse<User> {
        let request = ListUsersRequest(page: page, pageSize: pageSize)
        return try await client.sendPage(request)
    }
}
```

### Error handling that actually makes sense 🚫

```swift
func handleNetworkError(_ error: NetworkError) {
    switch error {
    case .invalidURL:
        // You fucked up the URL 🤦‍♂️
        showAlert(title: "Invalid URL", message: "Contact the developer, they can't type URLs correctly")
        
    case .requestFailed(let statusCode, let data):
        // The server fucked up 💩
        switch statusCode {
        case 401:
            // Token expired or invalid
            refreshTokenAndRetry()
        case 403:
            showAlert(title: "Access Denied", message: "You're not allowed to do that, buddy")
        case 404:
            showAlert(title: "Not Found", message: "The thing you're looking for doesn't exist")
        case 500..<600:
            showAlert(title: "Server Error", message: "The server is having a bad day")
        default:
            if let data = data, let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("Server said: \(errorJson)")
            }
            showAlert(title: "Error \(statusCode)", message: "Something went wrong")
        }
        
    case .decodingFailed(let decodingError):
        // The JSON decoder fucked up 💥
        print("Decoding error: \(decodingError)")
        showAlert(title: "Data Error", message: "Could not understand the server response")
        
    case .unknown(let underlyingError):
        // Something else fucked up 🤷‍♂️
        print("Unknown error: \(underlyingError)")
        showAlert(title: "Unknown Error", message: underlyingError.localizedDescription)
    }
}
```

## 🧪 Testing with Mock Responses

Because tests that hit real APIs are stupid and unreliable. 👎

### 1. Set up your test class 🏗️

```swift
import XCTest
@testable import YourAppModule
import AnotherFuckingNetworkingSDK

class UserServiceTests: XCTestCase {
    
    var mockClient: MockAPIClient!
    var userService: UserService!
    
    override func setUp() {
        super.setUp()
        // Create a mock client instead of hitting real APIs
        mockClient = MockAPIClient()
        
        // Inject the mock into your service
        userService = UserService(client: mockClient)
    }
    
    override func tearDown() {
        mockClient.resetMocks()
        mockClient = nil
        userService = nil
        super.tearDown()
    }
```

### 2. Test a successful request ✅

```swift
func testGetUser() async throws {
    // 1. Create fake data 🤥
    let mockUser = User(id: 42, name: "Arthur Dent", email: "arthur@earth.com", isAdmin: false)
    
    // 2. Tell the mock what to return
    mockClient.mock(GetUserRequest.self, with: mockUser)
    
    // 3. Call the API through your service
    let user = try await userService.getUser(id: 42)
    
    // 4. Verify you got what you expected
    XCTAssertEqual(user.id, 42)
    XCTAssertEqual(user.name, "Arthur Dent")
    XCTAssertEqual(user.email, "arthur@earth.com")
    
    // 5. Verify the correct request was made
    XCTAssertTrue(mockClient.calledRequests.contains("users/42"))
}
```

### 3. Test with fake errors ❌

```swift
func testGetUserError() async {
    // 1. Set up a mock error 💣
    let mockError = NetworkError.requestFailed(statusCode: 404, data: nil)
    mockClient.mockError(GetUserRequest.self, with: mockError)
    
    // 2. Try to call the API and expect an error
    do {
        _ = try await userService.getUser(id: 999)
        XCTFail("Expected an error but got success")
    } catch let error as NetworkError {
        // 3. Verify it's the right error
        if case .requestFailed(let statusCode, _) = error {
            XCTAssertEqual(statusCode, 404)
        } else {
            XCTFail("Wrong error type")
        }
    } catch {
        XCTFail("Wrong error type: \(error)")
    }
}
```

### 4. Test paginated responses 📑

```swift
func testListUsers() async throws {
    // 1. Create fake paginated data
    let mockUsers = [
        User(id: 1, name: "User 1", email: "user1@example.com", isAdmin: false),
        User(id: 2, name: "User 2", email: "user2@example.com", isAdmin: true)
    ]
    let mockResponse = PaginatedResponse<User>(
        items: mockUsers,
        currentPage: 1,
        totalPages: 2
    )
    
    // 2. Tell the mock what to return
    mockClient.mock(ListUsersRequest.self, with: mockResponse)
    
    // 3. Call the API
    let response = try await userService.listUsers(page: 1)
    
    // 4. Verify the results
    XCTAssertEqual(response.items.count, 2)
    XCTAssertEqual(response.currentPage, 1)
    XCTAssertEqual(response.totalPages, 2)
    XCTAssertEqual(response.nextPage, 2) // Should have a next page
}
```

### 5. Testing network delays ⏱️

```swift
func testNetworkDelay() async throws {
    // 1. Create mock data
    let mockUser = User(id: 42, name: "Slow Response", email: "slow@example.com", isAdmin: false)
    
    // 2. Set a mock delay (1 second) 🐢
    mockClient.mockDelay = 1.0
    mockClient.mock(GetUserRequest.self, with: mockUser)
    
    // 3. Measure how long it takes
    let startTime = Date()
    _ = try await userService.getUser(id: 42)
    let endTime = Date()
    
    // 4. Verify the delay
    let timeInterval = endTime.timeIntervalSince(startTime)
    XCTAssertGreaterThanOrEqual(timeInterval, 1.0, "Response should be delayed")
}
```

## 🎨 Integration with SwiftUI

Because it's 2024 and people actually use SwiftUI now. 🤷‍♂️

```swift
struct UserProfileView: View {
    let userId: Int
    
    @State private var user: User?
    @State private var isLoading = false
    @State private var error: Error?
    
    private let userService = UserService()
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading user...") 🔄
            } else if let user = user {
                VStack(alignment: .leading, spacing: 8) {
                    Text(user.name)
                        .font(.title)
                    
                    Text(user.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if user.isAdmin {
                        Text("Admin")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }
                .padding()
            } else if let error = error {
                VStack {
                    Text("Error loading user") ⚠️
                        .font(.headline)
                    
                    Text(error.localizedDescription)
                        .font(.body)
                        .foregroundColor(.red)
                    
                    Button("Retry") {
                        loadUser()
                    }
                    .buttonStyle(.bordered)
                    .padding(.top)
                }
                .padding()
            } else {
                Text("No user data") 🤷‍♂️
            }
        }
        .onAppear {
            loadUser()
        }
    }
    
    private func loadUser() {
        isLoading = true
        error = nil
        
        Task {
            do {
                user = try await userService.getUser(id: userId)
                isLoading = false
            } catch {
                self.error = error
                isLoading = false
            }
        }
    }
}
```

## 🚫 Common Issues and Solutions

### "I'm getting a 'No mock registered for request' error" 😱

You forgot to register a mock response. Make sure you call `mockClient.mock(YourRequestType.self, with: yourMockData)` before testing.

### "My JSON decoding is failing" 💥

Your model properties don't match what the API returns. Use `CodingKeys` to map between camelCase Swift properties and snake_case JSON fields. Or tell your backend team to use proper camelCase like civilized people. 🧐

### "My authorization isn't working" 🔒

Did you set the global headers? Check that your token is valid and formatted correctly:

```swift
APIClient.shared.globalHeaders = ["Authorization": "Bearer YOUR_TOKEN"]
```

## 🤝 Contributions

Pull requests are welcome. For major changes, open an issue first to discuss what you'd like to change. Or don't, and just submit something amazing that fixes my broken code. 🛠️

Is something missing? Maybe. Email your-email@example.com with your complaints or - better yet - contribute a fix. 💌

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details. TL;DR: Do whatever the fuck you want with it. 🎉 
