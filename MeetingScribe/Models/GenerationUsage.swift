import Foundation

struct GenerationUsage: Codable, Sendable, Equatable {
    struct Phase: Codable, Sendable, Equatable, Identifiable {
        var id: String { name }
        let name: String
        let inputTokens: Int
        let outputTokens: Int
        let calls: Int
    }

    var phases: [Phase]
    var isEstimated: Bool

    var inputTokens: Int { phases.reduce(0) { $0 + $1.inputTokens } }
    var outputTokens: Int { phases.reduce(0) { $0 + $1.outputTokens } }
    var totalTokens: Int { inputTokens + outputTokens }
    var calls: Int { phases.reduce(0) { $0 + $1.calls } }

    static func estimatedPhase(name: String, input: String, output: String) -> Phase {
        Phase(name: name, inputTokens: TokenEstimator.count(input),
              outputTokens: TokenEstimator.count(output), calls: 1)
    }
}

enum TokenEstimator {
    static func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var ascii = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII { ascii += 1 } else { nonASCII += 1 }
        }
        return max(1, Int(ceil(Double(ascii) / 4 + Double(nonASCII) / 1.5)))
    }
}

struct ModelTokenUsage: Identifiable, Sendable, Equatable {
    var id: String { model }
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let calls: Int
    let meetings: Int
    var totalTokens: Int { inputTokens + outputTokens }
}

enum ApplicationTokenUsage {
    static func aggregate(_ records: [MeetingRecord]) -> [ModelTokenUsage] {
        struct Accumulator { var input = 0; var output = 0; var calls = 0; var meetings = 0 }
        var grouped: [String: Accumulator] = [:]
        for record in records {
            let usages = [record.generationUsage, record.emailDrafts?.hongKongUsage].compactMap { $0 }
            guard !usages.isEmpty else { continue }
            let name = "\(record.backend) · \(record.model)"
            var value = grouped[name] ?? Accumulator()
            for usage in usages {
                value.input += usage.inputTokens
                value.output += usage.outputTokens
                value.calls += usage.calls
            }
            if record.generationUsage != nil { value.meetings += 1 }
            grouped[name] = value
        }
        return grouped.map { name, value in
            ModelTokenUsage(model: name, inputTokens: value.input, outputTokens: value.output,
                            calls: value.calls, meetings: value.meetings)
        }.sorted { $0.totalTokens > $1.totalTokens }
    }
}
