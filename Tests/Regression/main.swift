import Foundation
struct SimpleConsole { let date: Date; let message: String }
let event = Date(timeIntervalSince1970: 100)
func stat(_ offset: Double, _ rate: Double) -> CMPlayerStats {
    CMPlayerStats(sampleRate: rate, bitDepth: 24, date: event.addingTimeInterval(offset), priority: 5)
}
func check(_ stats: [CMPlayerStats], _ expected: Double?, _ label: String) {
    precondition(RateSelection.candidate(stats, near: event)?.sampleRate == expected, label)
    print("PASS: \(label)")
}
check([stat(-4, 192000)], nil, "reject stale previous-track logs")
check([stat(4, 192000)], nil, "reject late next-track preload")
check([stat(1.8, 192000), stat(-0.1, 44100)], 44100, "prefer transition log over newer prefetch")
check([stat(-0.1, 44100), stat(1.8, 192000)], 44100, "selection independent of log ordering")
check([stat(0.8, 96000)], 96000, "accept delayed decoder log")
check([], nil, "missing logs do not invent fallback")
check([stat(0, 0)], nil, "reject invalid sample rate")
check([stat(0.5, 96000), stat(-0.5, 44100)], 44100, "tie prefers earlier log")

func entry(_ text: String, _ offset: Double = 0) -> SimpleConsole {
    SimpleConsole(date: event.addingTimeInterval(offset), message: text)
}
let prefix = "ACAppleLosslessDecoder.cpp Input format: "
let complete = entry(prefix + "2 ch, 96000 Hz, from 24-bit source")
let parsed = CMPlayerParser.parseCoreAudioConsoleLogs([complete])
precondition(parsed.count == 1 && parsed[0].sampleRate == 96000 && parsed[0].bitDepth == 24)
print("PASS: complete decoder line")
let incomplete = CMPlayerParser.parseCoreAudioConsoleLogs([
 entry(prefix + "2 ch, 192000 Hz"), entry(prefix + "from 16-bit source")])
precondition(incomplete.isEmpty)
print("PASS: never combine fields from different log entries")
let multiple = CMPlayerParser.parseCoreAudioConsoleLogs([
 entry(prefix + "2 ch, 192000 Hz, from 24-bit source", 1.8),
 entry(prefix + "2 ch, 44100 Hz, from 16-bit source", -0.1)])
precondition(multiple.count == 2)
precondition(RateSelection.candidate(multiple, near: event)?.sampleRate == 44100)
print("PASS: parse all candidates and reject newer prefetch")

// Apply once per change: a pre-event line waits for the final attempt.
func choice(_ decoder: [CMPlayerStats], _ ampplay: [AmpplayEntry]? = nil, title: String? = nil,
            final: Bool = false) -> SwitchChoice {
    SwitchPolicy.choose(decoder: decoder, ampplay: ampplay, title: title, event: event, isFinal: final)
}
func used(_ c: SwitchChoice) -> (Double, SwitchSource)? {
    if case .use(let s, let source, _) = c { return (s.sampleRate, source) }
    return nil
}
func waits(_ c: SwitchChoice) -> Bool { if case .wait = c { return true }; return false }
func none(_ c: SwitchChoice) -> Bool { if case .none = c { return true }; return false }

precondition(used(choice([stat(0.4, 96000)]))?.0 == 96000)
print("PASS: post-event decoder line applies at once")
precondition(waits(choice([stat(-0.5, 96000)])))
precondition(used(choice([stat(-0.5, 96000)], final: true))?.0 == 96000)
print("PASS: pre-event decoder line waits for the final attempt")
precondition(waits(choice([])) && none(choice([], final: true)))
print("PASS: no line waits, then reports none")

// Exact matching through the ampplay line.
func amp(_ name: String, _ kHz: String, _ format: String = "alac", _ offset: Double = 0) -> AmpplayEntry {
    let message = "play> cm>> mediaFormatinfo '\(name)', sdFormatID = \(format), sdBitDepth = 24 bit, asbdSampleRate = \(kHz) kHz, sdBitRate = 0 kbps"
    return AmpplayEntry.parse(SimpleConsole(date: event.addingTimeInterval(offset), message: message))!
}
let quoted = amp("Don't Stop, Me Now", "96.0")
precondition(quoted.trackName == "Don't Stop, Me Now" && quoted.sampleRate == 96000 && quoted.bitDepth == 24 && quoted.isLossless)
print("PASS: ampplay parse with quote and comma in name")
precondition(amp("<private>", "44.1").trackName == nil && amp("x", "44.1", "aac ").isLossless == false)
print("PASS: private names hidden, AAC is not lossless")
precondition(amp("x", "88.2").sampleRate == 88200)
print("PASS: kHz converted to Hz")

let preloadNext = amp("Next Song", "192.0", "alac", -60)
let current = amp("Current Song", "44.1", "alac", -120)
let r1 = used(choice([stat(0.2, 192000)], [preloadNext, current], title: "current  song"))
precondition(r1?.0 == 44100 && r1?.1 == .exactMatch)
print("PASS: exact match beats a newer preload and a decoder line")
precondition(waits(choice([stat(0.2, 192000)], [preloadNext], title: "Other")))
precondition(used(choice([stat(0.2, 192000)], [preloadNext], title: "Other", final: true))?.1 == .timeWindow)
print("PASS: names visible without a match wait, then fall back to the time window")
let hidden = amp("<private>", "96.0")
precondition(used(choice([stat(0.2, 48000)], [hidden], title: "Current Song"))?.1 == .timeWindow)
print("PASS: hidden names fall back to the time window at once")
let stale = amp("Current Song", "96.0", "alac", -(SwitchPolicy.exactMatchLookback + 1))
precondition(used(choice([], [stale], title: "Current Song")) == nil)
print("PASS: exact match ignores lines older than the lookback")

// Rate and depth choice.
let supported: [Double] = [44100, 48000, 88200, 96000]
precondition(SwitchPolicy.targetRate(source: 96000, supported: supported, preferMultiples: false) == 96000)
precondition(SwitchPolicy.targetRate(source: 176400, supported: supported, preferMultiples: false) == 96000)
precondition(SwitchPolicy.targetRate(source: 176400, supported: supported, preferMultiples: true) == 88200)
print("PASS: target rate nearest, or family multiple")
precondition(SwitchPolicy.nearestBitDepth(source: 24, available: [16, 32]) == 32)
precondition(SwitchPolicy.nearestBitDepth(source: 16, available: [16, 24, 32]) == 16)
precondition(SwitchPolicy.nearestBitDepth(source: 24, available: []) == nil)
print("PASS: nearest bit depth, ties go up")
precondition(!SwitchPolicy.needsSwitch(currentRate: 96000, targetRate: 96000))
precondition(SwitchPolicy.needsSwitch(currentRate: 44100, targetRate: 96000))
print("PASS: same rate never switches (no depth-only change)")

// Decision log.
var log = DecisionLog()
for i in 0..<(DecisionLog.capacity + 5) {
    log.append(DecisionRecord(time: event.addingTimeInterval(Double(i)), track: "t\(i)", trigger: "track change", action: "a"))
}
precondition(log.records.count == DecisionLog.capacity && log.records.first?.track == "t5")
log.update(recordAt: event.addingTimeInterval(Double(DecisionLog.capacity + 4))) { $0.readback = "96.0 kHz" }
precondition(log.records.last?.readback == "96.0 kHz")
precondition(log.report(device: "X8").contains("readback: 96.0 kHz"))
print("PASS: decision log is bounded and updates by time")
