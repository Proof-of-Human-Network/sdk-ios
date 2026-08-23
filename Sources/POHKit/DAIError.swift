import Foundation

/// Errors thrown by DAIClient.
public enum DAIError: Error, LocalizedError {
    case invalidBaseURL
    /// HTTP non-2xx. `body` is the parsed JSON dictionary when available
    /// (e.g. 412 HF_DATASET_DOWNLOAD_REQUIRED with datasetId).
    case httpError(statusCode: Int, message: String, body: [String: Any]? = nil)
    case decodingError(Error)
    case requestTimeout
    case jobTimedOut(jobId: String, lastStatus: String)
    case emptyInputs

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid base URL"
        case .httpError(let code, let msg, _):
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

    /// Structured JSON body from the miner when present (412 dataset prompts, etc.).
    public var body: [String: Any]? {
        if case .httpError(_, _, let body) = self { return body }
        return nil
    }
}
