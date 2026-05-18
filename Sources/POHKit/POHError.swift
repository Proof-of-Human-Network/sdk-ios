import Foundation

/// Errors thrown by POHClient.
public enum POHError: Error, LocalizedError {
    case invalidBaseURL
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case requestTimeout
    case jobTimedOut(jobId: String, lastStatus: String)
    case emptyInputs

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid base URL"
        case .httpError(let code, let msg):
            return "HTTP \(code): \(msg)"
        case .decodingError(let err):
            return "Decoding failed: \(err.localizedDescription)"
        case .requestTimeout:
            return "Request timed out"
        case .jobTimedOut(let id, let status):
            return "Job \"\(id)\" did not complete in time (last status: \(status))"
        case .emptyInputs:
            return "inputs array must not be empty"
        }
    }
}
