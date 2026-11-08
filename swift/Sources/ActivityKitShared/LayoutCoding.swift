import Foundation

/// A member name of a JSON object.
struct LayoutMemberKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Reads a JSON object strictly: a member that is unknown, null or of another type fails.
struct LayoutReader {
    static let mismatch = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "The value does not match the layout contract."))
    private let container: KeyedDecodingContainer<LayoutMemberKey>
    private var taken = 0
    init(_ decoder: Decoder) throws { container = try decoder.container(keyedBy: LayoutMemberKey.self) }

    mutating func take<Value: Decodable>(_ name: String) throws -> Value? {
        let key = LayoutMemberKey(name)
        guard container.contains(key) else { return nil }
        taken += 1
        return try container.decode(Value.self, forKey: key)
    }
    mutating func need<Value: Decodable>(_ name: String) throws -> Value {
        guard let value: Value = try take(name) else { throw LayoutReader.mismatch }
        return value
    }
    /// Fails when the object holds a member that nothing read.
    func finish() throws {
        guard container.allKeys.count == taken else { throw LayoutReader.mismatch }
    }
}

/// A value of the wire format: it encodes as JSON and has the contract's payload weight.
protocol LayoutWire: Encodable {
    var wireWeight: Int { get }
}
extension LayoutWire {
    fileprivate func encode(into container: inout KeyedEncodingContainer<LayoutMemberKey>, as name: String) throws {
        try container.encode(self, forKey: LayoutMemberKey(name))
    }
}
extension LayoutWire where Self: RawRepresentable, RawValue == String {
    var wireWeight: Int { rawValue.wireWeight }
}
extension String: LayoutWire { var wireWeight: Int { utf8.count + 2 } }
extension Double: LayoutWire { var wireWeight: Int { 8 } }
extension Int: LayoutWire { var wireWeight: Int { 8 } }
extension Bool: LayoutWire { var wireWeight: Int { 5 } }
extension Array: LayoutWire where Element: LayoutWire {
    var wireWeight: Int { reduce(2) { $0 + $1.wireWeight + 1 } }
}
extension Dictionary: LayoutWire where Key == String, Value: LayoutWire {
    var wireWeight: Int { reduce(2) { $0 + $1.key.utf8.count + 4 + $1.value.wireWeight } }
}

/// The members of a JSON object in wire order; an absent member is nil.
typealias LayoutMembers = [(name: String, value: LayoutWire?)]

/// A wire object: one member list gives both its encoding and its weight.
protocol LayoutObject: LayoutWire {
    var members: LayoutMembers { get }
}
extension LayoutObject {
    var wireWeight: Int {
        members.reduce(2) { total, member in member.value.map { total + member.name.utf8.count + 4 + $0.wireWeight } ?? total }
    }
    func encodeMembers(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: LayoutMemberKey.self)
        for member in members { try member.value?.encode(into: &container, as: member.name) }
    }
}
