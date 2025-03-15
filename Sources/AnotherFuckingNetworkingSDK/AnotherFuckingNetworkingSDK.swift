// The Swift Programming Language
// https://docs.swift.org/swift-book

/// AnotherFuckingNetworkingSDK - A modern, async/await Swift networking library
///
/// This package provides a complete solution for handling network requests in Swift
/// using async/await. Main features include:
///
/// - Type-safe API request/response handling
/// - Pagination support out of the box
/// - Error handling with meaningful error messages
/// - Request logging including cURL command generation
/// - Support for custom headers, query parameters, and request bodies
///
/// Start by instantiating an `APIClient` with your base URL:
///
/// ```swift
/// // Configure the shared client
/// APIClient.shared.baseURL = URL(string: "https://api.example.com")
/// APIClient.shared.globalHeaders = ["Authorization": "Bearer YOUR_TOKEN"]
/// 
/// // Or create your own instance
/// let client = APIClient(baseURL: URL(string: "https://api.example.com"))
/// ```
///
/// Then create request types conforming to the `Request` protocol and use them with the client.
///
/// See the README.md for complete documentation and example usage.

// This file serves as the main entry point and documentation for the library.
// Implementation is split across multiple files:
// 
// - HTTPMethod.swift: HTTP request method enum
// - NetworkError.swift: Error types for network requests
// - Request.swift: Request protocol and its default implementations
// - Pagination.swift: PaginatedRequest protocol and related types
// - APIClient.swift: The main client for making network requests
// - NetworkingLogger.swift: Logger utility for debugging
// - Extensions.swift: Utility extensions (Dictionary, URLRequest, String)
// - Examples.swift: Example models and requests
