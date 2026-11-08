import Foundation

extension ActivitySnapshot {
    public func validate(template: String) throws {
        guard (0...9_007_199_254_740_991).contains(revision),
              validText(title, limit: 120), validText(status, limit: 240) else {
            throw ActivityFailure("INVALID_INPUT", "Invalid revision or activity text.")
        }
        if let staleAt = staleAt, !(0...8_640_000_000_000_000).contains(staleAt) {
            throw ActivityFailure("INVALID_INPUT", "Invalid stale timestamp.")
        }
        if template == "progress", let progress = progress, timer == nil,
           progress.isFinite, (0...1).contains(progress) { return }
        if template == "timer", progress == nil, let timer = timer,
           timer.startedAt >= 0, timer.endsAt <= 8_640_000_000_000_000,
           timer.endsAt > timer.startedAt { return }
        throw ActivityFailure("INVALID_INPUT", "Snapshot must match the activity template.")
    }
    private func validText(_ text: String, limit: Int) -> Bool {
        !text.unicodeScalars.allSatisfy(isSchemaWhitespace) && text.unicodeScalars.count <= limit
    }
    private func isSchemaWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0d, 0x20, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029,
             0x202f, 0x205f, 0x3000, 0xfeff: return true
        default: return false
        }
    }
}

extension StartRequest {
    public func validate() throws {
        guard schemaVersion == 1, ["none", "notification"].contains(fallback),
              activityKey.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", options: .regularExpression) != nil else {
            throw ActivityFailure("INVALID_INPUT", "Invalid activity key, schema version, or fallback.")
        }
        try snapshot.validate(template: template)
    }
}

extension EndPolicy {
    public func validate(now: Date = Date()) throws {
        if ["default", "immediate"].contains(kind), at == nil { return }
        guard kind == "after", let at = at else {
            throw ActivityFailure("INVALID_INPUT", "Invalid dismissal policy.")
        }
        let delay = Double(at) / 1000 - now.timeIntervalSince1970
        guard delay > 0, delay <= 4 * 60 * 60 else {
            throw ActivityFailure("INVALID_INPUT", "Dismissal must be within the next four hours.")
        }
    }
}

public enum PayloadLimit {
    public static let bytes = 4096
    public static func check(attributes: LiveActivityAttributes, snapshot: ActivitySnapshot) throws {
        struct Payload: Encodable { let attributes: LiveActivityAttributes; let contentState: ActivitySnapshot }
        let data = try JSONEncoder().encode(Payload(attributes: attributes, contentState: snapshot))
        guard data.count <= bytes else {
            throw ActivityFailure("PAYLOAD_TOO_LARGE", "Activity attributes and state exceed 4 KB.")
        }
    }
}
