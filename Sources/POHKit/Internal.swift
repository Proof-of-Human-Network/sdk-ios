import Foundation

// ── HTTP session abstraction (enables mock injection in tests) ─────────────────

protocol HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

// ── Request body types ─────────────────────────────────────────────────────────

/// Handles the fact that `input` can be a single string or an array.
enum InputValue: Encodable {
    case single(String)
    case multiple([String])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .single(let s):   try c.encode(s)
        case .multiple(let a): try c.encode(a)
        }
    }
}

struct CheckerBody: Encodable {
    let input: InputValue
    let walletAddress: String?
    let chainIds: [String]?
    let txHash: String?
}

// ── Error body decoder ─────────────────────────────────────────────────────────

struct APIErrorBody: Decodable {
    let error: String?
}
