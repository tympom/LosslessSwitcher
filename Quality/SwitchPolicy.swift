//
//  SwitchPolicy.swift
//  LosslessSwitcher
//
//  Foundation-only decision logic, kept free of CoreAudio, OSLog and AppKit so that
//  Tests/Regression can build it on any Swift toolchain.
//

import Foundation

/// One Music `ampplay` format line (`play> cm>> mediaFormatinfo '<name>', sdFormatID = alac, ...`).
/// The track name is `<private>` unless private log data is enabled for com.apple.Music.
struct AmpplayEntry {
    let date: Date
    let trackName: String?
    let isLossless: Bool
    let bitDepth: Int?
    let sampleRate: Double // Hz
    let message: String

    static func parse(_ entries: [SimpleConsole]) -> [AmpplayEntry] {
        entries.compactMap(parse)
    }

    static func parse(_ entry: SimpleConsole) -> AmpplayEntry? {
        let message = entry.message
        guard message.contains("mediaFormatinfo"),
              let rateText = field("asbdSampleRate", in: message, until: " kHz"),
              let kHz = Double(rateText), kHz > 0,
              let formatID = field("sdFormatID", in: message, until: ",")
        else { return nil }
        let depth = field("sdBitDepth", in: message, until: " bit").flatMap { Int($0) }
        var name = trackName(in: message)
        if name == "<private>" { name = nil }
        return AmpplayEntry(date: entry.date, trackName: name, isLossless: formatID == "alac",
                            bitDepth: depth, sampleRate: (kHz * 1000).rounded(), message: message)
    }

    var namesHidden: Bool { trackName == nil }

    var stat: CMPlayerStats {
        CMPlayerStats(sampleRate: sampleRate, bitDepth: bitDepth ?? 24, date: date, priority: 6, message: message)
    }

    /// `key = value<terminator>`; the terminator may also be the end of the message.
    private static func field(_ key: String, in message: String, until terminator: String) -> String? {
        guard let keyRange = message.range(of: key + " = ") else { return nil }
        let rest = message[keyRange.upperBound...]
        let end = rest.range(of: terminator)?.lowerBound ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The name is quoted and may itself contain quotes or commas, so it ends at the
    /// quote before `, sdFormatID` when that field follows, else at the next quote.
    private static func trackName(in message: String) -> String? {
        guard let key = message.range(of: "mediaFormatinfo"),
              let open = message[key.upperBound...].firstIndex(of: "'")
        else { return nil }
        let rest = message[message.index(after: open)...]
        if let end = rest.range(of: "', sdFormatID") {
            return String(rest[..<end.lowerBound])
        }
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<close])
    }
}

enum SwitchSource: Equatable {
    case exactMatch
    case timeWindow

    var label: String {
        switch self {
        case .exactMatch: return "exact track match (Music ampplay log)"
        case .timeWindow: return "time window (CoreAudio decoder log)"
        }
    }
}

enum SwitchChoice {
    /// Keep waiting for a later attempt.
    case wait(note: String?)
    case use(CMPlayerStats, source: SwitchSource, note: String?)
    /// Final attempt without a usable line.
    case none(note: String?)
}

enum SwitchPolicy {
    /// Lines older than this are not considered for exact matching.
    static let exactMatchLookback: TimeInterval = 300

    /// Decides whether the logs collected so far settle the format for one change.
    /// `ampplay` is nil when exact matching is off. A time-window candidate logged
    /// after the event is used at once; one logged before it (possibly the previous
    /// track's decoder) is used only at the final attempt, so a change applies once.
    static func choose(decoder: [CMPlayerStats], ampplay: [AmpplayEntry]?, title: String?,
                       event: Date, isFinal: Bool) -> SwitchChoice {
        var note: String?
        var waitForExact = false
        if let ampplay {
            let lossless = ampplay.filter {
                $0.isLossless && event.timeIntervalSince($0.date) <= exactMatchLookback
            }
            if lossless.isEmpty {
                note = "exact: no lossless ampplay line"
            } else if lossless.allSatisfy(\.namesHidden) {
                note = "exact: track names are <private>; is the logging profile installed?"
            } else if let title, !normalized(title).isEmpty,
                      let match = lossless.filter({ $0.trackName.map(normalized) == normalized(title) })
                                          .max(by: { $0.date < $1.date }) {
                return .use(match.stat, source: .exactMatch, note: nil)
            } else {
                note = "exact: no ampplay line names \"\(title ?? "?")\""
                waitForExact = true
            }
        }
        if waitForExact && !isFinal { return .wait(note: note) }
        if let candidate = RateSelection.candidate(decoder, near: event) {
            if candidate.date >= event || isFinal {
                return .use(candidate, source: .timeWindow, note: note)
            }
            return .wait(note: note)
        }
        return isFinal ? .none(note: note) : .wait(note: note)
    }

    static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Nearest supported rate; with `preferMultiples`, the highest supported rate of
    /// the source's family (44.1 or 48 kHz) below the source when it is unsupported.
    static func targetRate(source: Double, supported: [Double], preferMultiples: Bool) -> Double? {
        guard var rate = supported.min(by: { abs($0 - source) < abs($1 - source) }) else { return nil }
        if preferMultiples, rate != source {
            let base = Int(source) % 44100 == 0 ? 44100 : 48000
            if let best = supported.filter({ Int($0) % base == 0 && $0 < source }).max() {
                rate = best
            }
        }
        return rate
    }

    static func nearestBitDepth(source: Int, available: [Int]) -> Int? {
        available.min(by: { abs($0 - source) < abs($1 - source) || (abs($0 - source) == abs($1 - source) && $0 > $1) })
    }

    /// Bit depth changes only together with a rate change: a depth-only format change
    /// re-clocks the DAC (an audible click) for no audible gain.
    static func needsSwitch(currentRate: Double?, targetRate: Double) -> Bool {
        currentRate != targetRate
    }
}

/// Recent switching decisions, newest last, for "Copy Recent Decisions".
struct DecisionRecord {
    let time: Date
    let track: String
    let trigger: String
    var source: String?
    var line: String?
    var target: String?
    var action: String
    var readback: String?
    var notes: [String] = []
}

struct DecisionLog {
    static let capacity = 30
    private(set) var records: [DecisionRecord] = []

    mutating func append(_ record: DecisionRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
    }

    /// Records are found by time, since indexes shift when old records drop out.
    mutating func update(recordAt time: Date, _ change: (inout DecisionRecord) -> Void) {
        guard let i = records.lastIndex(where: { $0.time == time }) else { return }
        change(&records[i])
    }

    func report(device: String?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var lines = ["LosslessSwitcher recent decisions (device: \(device ?? "unknown"))"]
        if records.isEmpty { lines.append("(none yet)") }
        for record in records {
            lines.append("")
            lines.append("\(formatter.string(from: record.time))  \(record.trigger): \(record.track)")
            lines.append("  action:   \(record.action)")
            if let source = record.source { lines.append("  source:   \(source)") }
            if let line = record.line { lines.append("  line:     \(line)") }
            if let target = record.target { lines.append("  target:   \(target)") }
            if let readback = record.readback { lines.append("  readback: \(readback)") }
            for note in record.notes { lines.append("  note:     \(note)") }
        }
        return lines.joined(separator: "\n")
    }

    static func describe(rate: Double?, bitDepth: Int?) -> String {
        guard let rate else { return "unknown" }
        let kHz = String(format: "%.1f kHz", rate / 1000)
        return bitDepth.map { "\(kHz) / \($0) bit" } ?? kHz
    }

    static func describe(_ stat: CMPlayerStats, event: Date, formatter: DateFormatter) -> String {
        let offset = String(format: "%+.2f s", stat.date.timeIntervalSince(event))
        let text = (stat.message ?? "").prefix(240)
        return "\(formatter.string(from: stat.date)) (\(offset)) \(text)"
    }
}
