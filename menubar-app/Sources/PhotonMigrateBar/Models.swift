import Foundation

/// Mirrors the Go side's `upload.Session`. Stored in the Keychain -- these
/// are live credentials, so they deliberately never touch the database or
/// any plain file.
struct ProtonSession: Codable {
    let uid: String
    let accessToken: String
    let refreshToken: String
    let saltedKeyPass: String
}

/// Mirrors `loginOutcome` from the Go binary: a discriminated result so a
/// completed login and "solve this human-verification challenge and retry"
/// are distinguishable without scraping error text.
struct LoginOutcome: Codable {
    let status: String // "ok" | "hv_required"
    let session: ProtonSession?
    let hvToken: String?
    let hvMethods: [String]?
}

/// A human-verification challenge Proton wants solved before login can
/// proceed, rendered via Proton's own hosted verify.proton.me page.
struct HVChallenge: Identifiable, Equatable {
    let token: String
    let methods: [String]
    var id: String { token }
}

/// The result of the user solving an HVChallenge in the webview: the method
/// actually used (may differ from the initially offered one, e.g. if the
/// user switched from captcha to email within Proton's widget) and the
/// token it handed back via postMessage.
struct HVProof {
    let method: String
    let token: String
}

struct StatusCounts: Codable {
    let pending: Int
    let uploaded: Int
    let skippedDuplicate: Int
    let failed: Int

    enum CodingKeys: String, CodingKey {
        case pending = "Pending"
        case uploaded = "Uploaded"
        case skippedDuplicate = "SkippedDuplicate"
        case failed = "Failed"
    }

    static let empty = StatusCounts(pending: 0, uploaded: 0, skippedDuplicate: 0, failed: 0)
}
