import Foundation

extension LifecycleTests {
    /// What this layer answers for one fixture request: the error code, or nil and the weight.
    static func layoutVerdict(_ command: String, _ input: Data) -> (code: String?, weight: Int?) {
        let decoder = JSONDecoder()
        do {
            switch command {
            case "start_layout":
                let request = try decoder.decode(LayoutRequest.self, from: input)
                try request.validate()
                return (nil, request.weight)
            case "update_layout":
                let request = try decoder.decode(LayoutUpdateRequest.self, from: input)
                try request.validate()
                return (nil, request.weight)
            case "end_layout":
                let request = try decoder.decode(LayoutEndRequest.self, from: input)
                try request.validate()
                return (nil, request.snapshot.map(\.values.wireWeight))
            default:
                return ("INVALID_INPUT", nil)
            }
        } catch let failure as ActivityFailure {
            return (failure.code, nil)
        } catch is DecodingError {
            return ("INVALID_INPUT", nil)
        } catch { fatalError("Unexpected error \(error)") }
    }

    /// What this layer answers for an update after a start, as `LayoutActivityController.update` checks it: the
    /// update alone, then against the stored layout and styles. The weight is the stored part plus the new values.
    static func updateVerdict(_ start: Data, _ update: Data) -> (code: String?, weight: Int?) {
        let decoder = JSONDecoder()
        do {
            let request = try decoder.decode(LayoutRequest.self, from: start)
            try request.validate()
            let next = try decoder.decode(LayoutUpdateRequest.self, from: update)
            try next.validate()
            try next.snapshot.validate(replacing: request.snapshot, in: request.document)
            return (nil, request.document.weight + next.weight)
        } catch let failure as ActivityFailure {
            return (failure.code, nil)
        } catch is DecodingError {
            return ("INVALID_INPUT", nil)
        } catch { fatalError("Unexpected error \(error)") }
    }

    /// What this layer answers for an end with final content after a start, as `LayoutActivityController.end` checks it.
    static func endVerdict(_ start: Data, _ end: Data) -> (code: String?, weight: Int?) {
        let decoder = JSONDecoder()
        do {
            let request = try decoder.decode(LayoutRequest.self, from: start)
            try request.validate()
            let next = try decoder.decode(LayoutEndRequest.self, from: end)
            try next.validate()
            guard let snapshot = next.snapshot else { return (nil, nil) }
            try snapshot.validate(replacing: request.snapshot, in: request.document)
            return (nil, request.document.weight + snapshot.values.wireWeight)
        } catch let failure as ActivityFailure {
            return (failure.code, nil)
        } catch is DecodingError {
            return ("INVALID_INPUT", nil)
        } catch { fatalError("Unexpected error \(error)") }
    }

    /// The request decoded and encoded again, for comparing with the wire input.
    static func reencoded(_ command: String, _ input: Data) throws -> Data {
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        switch command {
        case "start_layout": return try encoder.encode(decoder.decode(LayoutRequest.self, from: input))
        case "update_layout": return try encoder.encode(decoder.decode(LayoutUpdateRequest.self, from: input))
        default: return try encoder.encode(decoder.decode(LayoutEndRequest.self, from: input))
        }
    }

    // AK-CONTRACT-2, AK-CONTRACT-4, AK-CONTRACT-5, AK-CONTRACT-6, AK-CONTRACT-12, AK-END-6
    @MainActor static func testLayoutFixtures() throws {
        guard CommandLine.arguments.count > 1 else { fatalError("Pass the path of tests/fixtures/layout-requests.json") }
        let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let fixtures = try JSONSerialization.jsonObject(with: file) as? [String: [[String: Any]]],
              let valid = fixtures["valid"], let invalid = fixtures["invalid"] else { fatalError("Unreadable layout fixtures") }
        expect(valid.count >= 100 && invalid.count >= 100, "layout fixtures are loaded")
        var names = Set<String>()
        func read(_ fixture: [String: Any]) throws -> (name: String, command: String, input: Data) {
            guard let name = fixture["name"] as? String, let command = fixture["command"] as? String,
                  let input = fixture["input"] else { fatalError("Malformed layout fixture") }
            guard names.insert(name).inserted else { fatalError("Duplicate fixture name \(name)") }
            return (name, command, try JSONSerialization.data(withJSONObject: input, options: [.fragmentsAllowed]))
        }
        for fixture in valid {
            let (name, command, input) = try read(fixture)
            let verdict = layoutVerdict(command, input)
            expect(verdict.code == nil, "fixture must be accepted: \(name), got \(verdict.code ?? "")")
            let weight = fixture["weight"] as? Int
            let content = (fixture["input"] as? [String: Any])?["snapshot"] != nil
            expect((weight != nil) == (command != "end_layout" || content), "fixture states its weight: \(name)")
            expect(verdict.weight == weight, "fixture weight: \(name), expected \(weight ?? -1), got \(verdict.weight ?? -1)")
            let wire = try canonical(reencoded(command, input)) == canonical(input)
            expect(wire, "fixture encodes to its wire shape with absent members omitted: \(name)")
        }
        for fixture in invalid {
            let (name, command, input) = try read(fixture)
            guard let code = fixture["code"] as? String else { fatalError("Fixture without a code: \(name)") }
            let verdict = layoutVerdict(command, input)
            expect(verdict.code == code, "fixture must be rejected with \(code): \(name), got \(verdict.code ?? "accepted")")
        }
        guard let updates = fixtures["updates"] else { fatalError("Layout fixtures without updates") }
        expect(updates.count >= 20, "update fixtures are loaded")
        for fixture in updates {
            guard let name = fixture["name"] as? String, let start = fixture["start"], let update = fixture["update"] else {
                fatalError("Malformed update fixture")
            }
            guard names.insert(name).inserted else { fatalError("Duplicate fixture name \(name)") }
            let (started, next) = (try JSONSerialization.data(withJSONObject: start), try JSONSerialization.data(withJSONObject: update))
            expect(layoutVerdict("start_layout", started).code == nil, "the start of an update fixture is valid: \(name)")
            let verdict = updateVerdict(started, next)
            if let code = fixture["code"] as? String {
                expect(verdict.code == code, "update fixture must be rejected with \(code): \(name), got \(verdict.code ?? "accepted")")
            } else {
                let weight = fixture["weight"] as? Int
                expect(verdict.code == nil && verdict.weight == weight,
                       "update fixture must be accepted with weight \(weight ?? -1): \(name), got \(verdict.code ?? String(verdict.weight ?? -1))")
            }
        }
        guard let ends = fixtures["ends"] else { fatalError("Layout fixtures without ends") }
        expect(ends.count >= 4, "end fixtures are loaded")
        for fixture in ends {
            guard let name = fixture["name"] as? String, let start = fixture["start"], let end = fixture["end"] else {
                fatalError("Malformed end fixture")
            }
            guard names.insert(name).inserted else { fatalError("Duplicate fixture name \(name)") }
            let verdict = endVerdict(try JSONSerialization.data(withJSONObject: start), try JSONSerialization.data(withJSONObject: end))
            let expected = fixture["code"] as? String, weight = fixture["weight"] as? Int
            expect(verdict.code == expected && verdict.weight == weight,
                   "end fixture \(name): expected \(expected ?? String(weight ?? -1)), got \(verdict.code ?? String(verdict.weight ?? -1))")
        }
        print("Layout fixtures: \(valid.count) valid and \(invalid.count) invalid requests, \(updates.count) updates and \(ends.count) ends match")
    }
}
