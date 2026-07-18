import Foundation

/// An error produced while constructing an in-memory multipart form body.
public enum MultipartEncodingError: LocalizedError, Equatable, Sendable {
    case invalidBoundary(String)
    case invalidName(String)
    case invalidFilename(String)
    case invalidContentType(String)
    case emptyForm
    case boundaryCollision(partIndex: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidBoundary:
            return "The multipart boundary is invalid."
        case .invalidName:
            return "The multipart field name must be nonempty printable US-ASCII."
        case .invalidFilename:
            return "The multipart filename must be nonempty printable US-ASCII."
        case .invalidContentType:
            return "The multipart content type must be a bare type/subtype value."
        case .emptyForm:
            return "A multipart form must contain at least one part."
        case .boundaryCollision(let partIndex):
            return "Multipart part \(partIndex) contains the selected boundary delimiter marker."
        }
    }
}

/// An ordered, memory-backed `multipart/form-data` body.
///
/// The form preserves duplicate names and insertion order. Encoding validates
/// that the selected boundary delimiter marker does not occur in a payload. Use this type
/// for payloads that are appropriate to materialize completely in memory;
/// large file-backed and streaming bodies require a separate policy.
public struct MultipartFormData: Sendable {
    /// The stable delimiter shared by the body and its Content-Type header.
    public let boundary: String

    private var parts: [Part] = []

    /// Creates a form with a stable, UUID-based boundary.
    public init() {
        boundary = "AFNSDK-\(UUID().uuidString)"
    }

    /// Creates a form with a deterministic caller-supplied boundary.
    public init(boundary: String) throws {
        guard Self.isValidBoundary(boundary) else {
            throw MultipartEncodingError.invalidBoundary(boundary)
        }
        self.boundary = boundary
    }

    /// The exact value to use for the request's Content-Type header.
    public var contentType: String {
        "multipart/form-data; boundary=\"\(boundary)\""
    }

    /// Appends UTF-8 text labeled as `text/plain; charset=utf-8`.
    ///
    /// Standalone CR and LF characters are normalized to CRLF, matching MIME
    /// text and browser form submission conventions.
    public mutating func append(
        _ value: String,
        name: String
    ) throws {
        guard Self.isValidDispositionParameter(name) else {
            throw MultipartEncodingError.invalidName(name)
        }

        parts.append(Part(
            data: Data(Self.normalizedLineEndings(value).utf8),
            name: name,
            filename: nil,
            contentType: "text/plain; charset=utf-8"
        ))
    }

    /// Appends an ordinary binary field.
    ///
    /// Passing `nil` for `contentType` omits that part header.
    public mutating func append(
        _ data: Data,
        name: String,
        contentType: String? = nil
    ) throws {
        guard Self.isValidDispositionParameter(name) else {
            throw MultipartEncodingError.invalidName(name)
        }
        if let contentType, !Self.isValidContentType(contentType) {
            throw MultipartEncodingError.invalidContentType(contentType)
        }

        parts.append(Part(
            data: data,
            name: name,
            filename: nil,
            contentType: contentType
        ))
    }

    /// Appends file data with a filename and media type.
    public mutating func append(
        _ data: Data,
        name: String,
        filename: String,
        contentType: String = "application/octet-stream"
    ) throws {
        guard Self.isValidDispositionParameter(name) else {
            throw MultipartEncodingError.invalidName(name)
        }
        guard Self.isValidDispositionParameter(filename) else {
            throw MultipartEncodingError.invalidFilename(filename)
        }
        guard Self.isValidContentType(contentType) else {
            throw MultipartEncodingError.invalidContentType(contentType)
        }

        parts.append(Part(
            data: data,
            name: name,
            filename: filename,
            contentType: contentType
        ))
    }

    /// Materializes the complete multipart body.
    ///
    /// A fixed boundary and identical ordered parts always produce identical
    /// bytes. Encoding an empty form or a payload containing the selected
    /// boundary delimiter marker fails rather than emitting an ambiguous body.
    public func encode() throws -> Data {
        guard !parts.isEmpty else {
            throw MultipartEncodingError.emptyForm
        }

        let collisionMarker = Data("--\(boundary)".utf8)
        for (index, part) in parts.enumerated()
            where part.data.range(of: collisionMarker) != nil {
            throw MultipartEncodingError.boundaryCollision(partIndex: index)
        }

        var body = Data()
        for part in parts {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8(
                "Content-Disposition: form-data; name=\""
                    + Self.escapedQuotedValue(part.name)
                    + "\""
            )
            if let filename = part.filename {
                body.appendUTF8(
                    "; filename=\""
                        + Self.escapedQuotedValue(filename)
                        + "\""
                )
            }
            body.appendUTF8("\r\n")
            if let contentType = part.contentType {
                body.appendUTF8("Content-Type: \(contentType)\r\n")
            }
            body.appendUTF8("\r\n")
            body.append(part.data)
            body.appendUTF8("\r\n")
        }
        body.appendUTF8("--\(boundary)--\r\n")
        return body
    }

    private static func isValidBoundary(_ value: String) -> Bool {
        let scalars = value.unicodeScalars
        guard !scalars.isEmpty, scalars.count <= 70,
              scalars.last != " " else {
            return false
        }

        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 32, 39, 40, 41, 43, 44, 45, 46, 47, 58, 61, 63,
                 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }

    private static func isValidDispositionParameter(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { scalar in
            (32...126).contains(scalar.value)
        }
    }

    private static func isValidContentType(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty else {
            return false
        }

        return components.allSatisfy { component in
            component.unicodeScalars.allSatisfy { scalar in
                guard scalar != "*" else { return false }
                switch scalar.value {
                case 33, 35...39, 42...43, 45...46, 48...57,
                     65...90, 94...96, 97...122, 124, 126:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private static func escapedQuotedValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func normalizedLineEndings(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
    }
}

private extension MultipartFormData {
    struct Part: Sendable {
        let data: Data
        let name: String
        let filename: String?
        let contentType: String?
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
