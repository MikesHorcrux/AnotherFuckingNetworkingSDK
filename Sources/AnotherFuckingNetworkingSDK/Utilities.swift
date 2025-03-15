import Foundation
import os.log
import Security

// MARK: - NetworkingLogger

/// For those who want to see cURL commands in the console.
public struct NetworkingLogger {
    private let logger = Logger(subsystem: "com.your-org.AnotherFuckingNetworkingSDK", category: "Networking")
    private let queue = DispatchQueue(label: "AnotherFuckingNetworkingSDKLoggerQueue")
    
    public init() {}
    
    public func log(request: URLRequest) {
        queue.async {
            let curlStr = request.curl
            self.logger.debug("🍺 Outgoing request:\n\(curlStr)")
        }
    }
    
    public func log(response: URLResponse, data: Data) {
        queue.async {
            guard let httpResp = response as? HTTPURLResponse,
                  let urlString = httpResp.url?.absoluteString else {
                self.logger.error("❗️Invalid HTTPURLResponse or missing URL.")
                return
            }
            let status = httpResp.statusCode
            let prettyJSON = self.prettyPrintedJSON(from: data) ?? (String(data: data, encoding: .utf8) ?? "<no body>")
            self.logger.info("🍻 Response \(status) from \(urlString):\n\(prettyJSON)")
        }
    }
    
    private func prettyPrintedJSON(from data: Data) -> String? {
        do {
            let object = try JSONSerialization.jsonObject(with: data, options: [])
            let prettyData = try JSONSerialization.data(withJSONObject: object, options: .prettyPrinted)
            return String(data: prettyData, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

// MARK: - Dictionary Merge

extension Dictionary {
    public func merged(with dict: [Key: Value]) -> [Key: Value] {
        var copy = self
        for (k, v) in dict {
            copy[k] = v
        }
        return copy
    }
}

// MARK: - URLRequest + cURL

extension URLRequest {
    /// A command so you can curl the fuck out of it
    var curl: String {
        let newLine = " \\\n"
        return "curl " + curlComponents.map(\.option).joined(separator: newLine)
    }
    
    private var curlComponents: [CurlComponent] {
        var comps: [CurlComponent] = []
        comps.append(.url(url?.absoluteString ?? ""))
        comps.append(.method(httpMethod ?? "GET"))
        
        if let headers = allHTTPHeaderFields {
            for (key, value) in headers {
                comps.append(.header(key: key, value: value))
            }
        }
        
        if let httpBody = httpBody,
           let bodyString = String(data: httpBody, encoding: .utf8),
           !bodyString.isEmpty {
            comps.append(.body(bodyString))
        }
        
        return comps
    }
    
    private enum CurlComponent {
        case url(String)
        case method(String)
        case header(key: String, value: String)
        case body(String)
        
        var option: String {
            switch self {
            case .url(let urlStr):
                return "-i '\(urlStr)'"
            case .method(let m):
                return "-X \(m)"
            case .header(let k, let v):
                return "-H '\(k): \(v)'"
            case .body(let b):
                return "--data '\(b)'"
            }
        }
    }
}

// MARK: - RandomNonce (Optional)

extension String {
    public static func randomNonce(length: Int = 32) -> String? {
        precondition(length > 0)
        let charset: Array<Character> = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        
        while remainingLength > 0 {
            var random: UInt8 = 0
            let errorCode = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard errorCode == errSecSuccess else {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with code \(errorCode)")
            }
            
            if random < charset.count {
                result.append(charset[Int(random)])
                remainingLength -= 1
            }
        }
        return result
    }
} 