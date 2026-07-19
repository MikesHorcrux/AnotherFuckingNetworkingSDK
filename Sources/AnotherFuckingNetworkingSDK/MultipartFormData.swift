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
            data: Self.normalizedTextData(value),
            header: Self.headerData(
                name: name,
                filename: nil,
                contentType: "text/plain; charset=utf-8"
            )
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
            header: Self.headerData(
                name: name,
                filename: nil,
                contentType: contentType
            )
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
            header: Self.headerData(
                name: name,
                filename: filename,
                contentType: contentType
            )
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

        let delimiter = Data("--\(boundary)\r\n".utf8)
        let closingDelimiter = Data("--\(boundary)--\r\n".utf8)
        var body = Data()
        if let capacity = Self.encodedCapacity(
            parts: parts,
            delimiterByteCount: delimiter.count,
            closingDelimiterByteCount: closingDelimiter.count
        ) {
            body.reserveCapacity(capacity)
        }

        for part in parts {
            body.append(delimiter)
            body.append(part.header)
            body.append(part.data)
            body.append(13)
            body.append(10)
        }
        body.append(closingDelimiter)
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

    private static func headerData(
        name: String,
        filename: String?,
        contentType: String?
    ) -> Data {
        var header = "Content-Disposition: form-data; name=\""
            + escapedQuotedValue(name)
            + "\""
        if let filename {
            header += "; filename=\"" + escapedQuotedValue(filename) + "\""
        }
        header += "\r\n"
        if let contentType {
            header += "Content-Type: \(contentType)\r\n"
        }
        header += "\r\n"
        return Data(header.utf8)
    }

    private static func normalizedTextData(_ value: String) -> Data {
        let bytes = value.utf8
        var normalizedByteCount = 0
        var previousWasCarriageReturn = false

        for byte in bytes {
            if byte == 10, previousWasCarriageReturn {
                previousWasCarriageReturn = false
                continue
            }
            normalizedByteCount += byte == 10 || byte == 13 ? 2 : 1
            previousWasCarriageReturn = byte == 13
        }

        var data = Data()
        data.reserveCapacity(normalizedByteCount)
        previousWasCarriageReturn = false
        for byte in bytes {
            if byte == 10, previousWasCarriageReturn {
                previousWasCarriageReturn = false
                continue
            }
            if byte == 10 || byte == 13 {
                data.append(13)
                data.append(10)
            } else {
                data.append(byte)
            }
            previousWasCarriageReturn = byte == 13
        }
        return data
    }

    private static func encodedCapacity(
        parts: [Part],
        delimiterByteCount: Int,
        closingDelimiterByteCount: Int
    ) -> Int? {
        var total = closingDelimiterByteCount
        for part in parts {
            guard Self.add(delimiterByteCount, to: &total),
                  Self.add(part.header.count, to: &total),
                  Self.add(part.data.count, to: &total),
                  Self.add(2, to: &total) else {
                return nil
            }
        }
        return total
    }

    private static func add(_ value: Int, to total: inout Int) -> Bool {
        let addition = total.addingReportingOverflow(value)
        guard !addition.overflow else { return false }
        total = addition.partialValue
        return true
    }
}

private extension MultipartFormData {
    struct Part: Sendable {
        let data: Data
        let header: Data
    }
}
