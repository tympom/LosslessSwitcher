//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio
import CoreAudioTypes
import MediaRemoteAdapter

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice? // auto if nil
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?
    @Published var currentBitDepth: Int?
    @Published var enableBitDepthDetection = Defaults.shared.userPreferBitDepthDetection
    
    private var enableBitDepthDetectionCancellable: AnyCancellable?
    
    private let coreAudio = SimplyCoreAudio()
    
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?
    private var timerCancellable: AnyCancellable?
    private var outputSelectionCancellable: AnyCancellable?
    
    private var consoleQueue = DispatchQueue(label: "consoleQueue", qos: .userInteractive)
    
    private var processQueue = DispatchQueue(label: "processQueue", qos: .userInitiated)
    
    private var previousSampleRate: Float64?
    private var previousBitDepth: Int?
    var trackAndSample = [MediaTrack : Float64]()
    var trackAndBitDepth = [MediaTrack : Int]()
    var previousTrack: MediaTrack?
    var currentTrack: MediaTrack?
    
    private var detectionGeneration = 0
    private var lastPlaybackPosition: Double?
    private var lastPlaybackObservation: Date?
    private var wasPlaying = false
    private var resolvedGeneration = 0
    private var decisions = DecisionLog()
    private let logDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private enum Trigger {
        static let trackChange = "track change"
        static let resume = "resume"
        static let seek = "seek"
    }
    var timerActive = false
    var timerCalls = 0
    
    init() {
        self.outputDevices = self.coreAudio.allOutputDevices
        self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
        self.getDeviceSampleRate()
        
        changesCancellable =
            NotificationCenter.default.publisher(for: .deviceListChanged).sink(receiveValue: { _ in
                self.outputDevices = self.coreAudio.allOutputDevices
            })
        
        defaultChangesCancellable =
            NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged).sink(receiveValue: { _ in
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            })
        
        outputSelectionCancellable = $selectedOutputDevice.sink(receiveValue: { _ in
            self.getDeviceSampleRate()
        })
        
        enableBitDepthDetectionCancellable = Defaults.shared.$userPreferBitDepthDetection.sink(receiveValue: { newValue in
            self.enableBitDepthDetection = newValue
        })

        
    }
    
    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
        timerCancellable?.cancel()
        enableBitDepthDetectionCancellable?.cancel()
        //timer.upstream.connect().cancel()
    }
    
    func getDeviceSampleRate() {
        let defaultDevice = self.selectedOutputDevice ?? self.defaultOutputDevice
        guard let sampleRate = defaultDevice?.nominalSampleRate else { return }
        self.updateSampleRate(sampleRate, bitDepth: nil)
    }
    
    func getSampleRateFromAppleScript() -> Double? {
        let scriptContents = "tell application \"Music\" to get sample rate of current track"
        var error: NSDictionary?
        
        if let script = NSAppleScript(source: scriptContents) {
            let output = script.executeAndReturnError(&error).stringValue
            
            if let error = error {
                print("[APPLESCRIPT] - \(error)")
            }
            guard let output = output else { return nil }

            if output == "missing value" {
                return nil
            }
            else {
                return Double(output)
            }
        }
        
        return nil
    }
    
    func getAllStats() -> [CMPlayerStats] {
        var allStats = [CMPlayerStats]()
        
        do {
//            let musicLogs = try Console.getRecentEntries(type: .music)
            let coreAudioLogs = try Console.getRecentEntries(type: .coreAudio)
//            let coreMediaLogs = try Console.getRecentEntries(type: .coreMedia)
            
//            allStats.append(contentsOf: CMPlayerParser.parseMusicConsoleLogs(musicLogs))
//            if enableBitDepthDetection {
                allStats.append(contentsOf: CMPlayerParser.parseCoreAudioConsoleLogs(coreAudioLogs))
//            }
//            else {
//                allStats.append(contentsOf: CMPlayerParser.parseCoreMediaConsoleLogs(coreMediaLogs))
//            }

//            allStats.sort(by: {$0.priority > $1.priority})
            print("[getAllStats] \(allStats)")
        }
        catch {
            print("[getAllStats, error] \(error)")
        }
        
        return allStats
    }
    
    // All device and track state is accessed on the main queue. Only log reads
    // run in the background; generation tokens reject results from old tracks,
    // and `resolvedGeneration` makes each change apply at most once.
    private func beginDetection(at event: Date, trigger: String) {
        detectionGeneration += 1
        let generation = detectionGeneration
        let track = currentTrack
        let delays = [0.35, 1.0, 2.0, 3.0]
        for (index, delay) in delays.enumerated() {
            let isFinal = index == delays.count - 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isPending(generation) else { return }
                let exact = Defaults.shared.userPreferExactTrackMatching
                self.processQueue.async { [weak self] in
                    guard let self else { return }
                    let decoder = self.getAllStats()
                    let ampplay = exact ? self.getAmpplayEntries() : nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isPending(generation) else { return }
                        let choice = SwitchPolicy.choose(decoder: decoder, ampplay: ampplay, title: track?.title,
                                                         event: event, isFinal: isFinal)
                        self.handle(choice, event: event, trigger: trigger, track: track, generation: generation)
                    }
                }
            }
        }
    }

    private func isPending(_ generation: Int) -> Bool {
        detectionGeneration == generation && resolvedGeneration != generation
    }

    func getAmpplayEntries() -> [AmpplayEntry] {
        do {
            let entries = try Console.getRecentEntries(type: .music, seconds: SwitchPolicy.exactMatchLookback)
            return AmpplayEntry.parse(entries)
        }
        catch {
            print("[getAmpplayEntries, error] \(error)")
            return []
        }
    }

    private func handle(_ choice: SwitchChoice, event: Date, trigger: String, track: MediaTrack?, generation: Int) {
        let trackName = [track?.artist, track?.title].compactMap { $0 }.joined(separator: " - ")
        var record = DecisionRecord(time: Date(), track: trackName.isEmpty ? "unknown track" : trackName,
                                    trigger: trigger, action: "")
        switch choice {
        case .wait:
            return
        case .use(let stat, let source, let note):
            resolvedGeneration = generation
            record.source = source.label
            record.line = DecisionLog.describe(stat, event: event, formatter: logDateFormatter)
            if let note { record.notes.append(note) }
            apply(source: stat.sampleRate, bitDepth: stat.bitDepth, record: record, generation: generation)
        case .none(let note):
            resolvedGeneration = generation
            if let note { record.notes.append(note) }
            // Resume and seek log no new format line; only a track change may fall back.
            if Defaults.shared.userPreferBaseRateFallback, trigger == Trigger.trackChange {
                record.source = "fallback: no lossless line after a track change"
                let device = selectedOutputDevice ?? defaultOutputDevice
                let depth = device?.streams(scope: .output)?.first?.physicalFormat.map { Int($0.mBitsPerChannel) }
                apply(source: 44100, bitDepth: depth ?? 24, record: record, generation: generation)
            } else {
                record.action = "no change: no usable format line"
                decisions.append(record)
            }
        }
    }

    private func apply(source rate: Double, bitDepth: Int, record: DecisionRecord, generation: Int) {
        var record = record
        guard let device = selectedOutputDevice ?? defaultOutputDevice,
              let supported = device.nominalSampleRates,
              let target = SwitchPolicy.targetRate(source: rate, supported: supported,
                                                   preferMultiples: Defaults.shared.userPreferSampleRateMultiples)
        else {
            record.action = "no change: no output device or supported rates"
            decisions.append(record)
            return
        }
        let currentRate = device.nominalSampleRate
        var targetDepth: Int?
        var format: AudioStreamBasicDescription?
        if enableBitDepthDetection {
            let formats = (getFormats(device: device) ?? []).filter { $0.mSampleRate == target }
            if let depth = SwitchPolicy.nearestBitDepth(source: bitDepth, available: formats.map { Int($0.mBitsPerChannel) }) {
                targetDepth = depth
                format = formats.first { Int($0.mBitsPerChannel) == depth }
            }
        }
        record.target = DecisionLog.describe(rate: target, bitDepth: targetDepth)
        guard SwitchPolicy.needsSwitch(currentRate: currentRate, targetRate: target) else {
            record.action = "no change: device already at \(DecisionLog.describe(rate: currentRate, bitDepth: nil))"
            if targetDepth != nil, targetDepth != currentPhysicalBitDepth(device) {
                record.notes.append("bit depth left at \(currentPhysicalBitDepth(device).map { String($0) } ?? "?") bit: depth changes only with a rate change")
            }
            decisions.append(record)
            updateSampleRate(currentRate ?? target, bitDepth: currentPhysicalBitDepth(device))
            return
        }
        record.action = "switched from \(DecisionLog.describe(rate: currentRate, bitDepth: currentPhysicalBitDepth(device)))"
        decisions.append(record)
        setFormat(device: device, rate: target, format: format)
        verify(device: device, rate: target, format: format, recordTime: record.time, retried: false, generation: generation)
    }

    private func setFormat(device: AudioDevice, rate: Double, format: AudioStreamBasicDescription?) {
        if let format {
            setFormats(device: device, format: format)
        } else {
            device.setNominalSampleRate(rate)
        }
    }

    /// Reads the device back after CoreAudio settles; retries a mismatch once (only
    /// while the same change is current) and shows the readback, not the request.
    private func verify(device: AudioDevice, rate: Double, format: AudioStreamBasicDescription?,
                        recordTime: Date, retried: Bool, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self else { return }
            let actualRate = device.nominalSampleRate
            let actualDepth = self.currentPhysicalBitDepth(device)
            let rateOK = actualRate == rate
            let depthOK = format.map { Int($0.mBitsPerChannel) == actualDepth } ?? true
            let readback = DecisionLog.describe(rate: actualRate, bitDepth: actualDepth)
            if !(rateOK && depthOK), !retried, self.detectionGeneration == generation {
                self.decisions.update(recordAt: recordTime) { $0.notes.append("readback \(readback) mismatched; retried once") }
                self.setFormat(device: device, rate: rate, format: format)
                self.verify(device: device, rate: rate, format: format, recordTime: recordTime, retried: true, generation: generation)
                return
            }
            self.decisions.update(recordAt: recordTime) {
                $0.readback = readback + (rateOK && depthOK ? "" : " (MISMATCH)")
            }
            if let actualRate { self.updateSampleRate(actualRate, bitDepth: actualDepth) }
        }
    }

    private func currentPhysicalBitDepth(_ device: AudioDevice) -> Int? {
        device.streams(scope: .output)?.first?.physicalFormat.map { Int($0.mBitsPerChannel) }
    }

    func recentDecisionsReport() -> String {
        decisions.report(device: (selectedOutputDevice ?? defaultOutputDevice)?.name)
    }

    func getFormats(device: AudioDevice) -> [AudioStreamBasicDescription]? {
        // new sample rate + bit depth detection route
        let streams = device.streams(scope: .output)
        let availableFormats = streams?.first?.availablePhysicalFormats?.compactMap({$0.mFormat})
        return availableFormats
    }
    
    func setFormats(device: AudioDevice?, format: AudioStreamBasicDescription?) {
        guard let device, let format else { return }
        let streams = device.streams(scope: .output)
        if streams?.first?.physicalFormat != format {
            streams?.first?.physicalFormat = format
        }
    }
    
    func updateSampleRate(_ sampleRate: Float64, bitDepth: Int?) {
        self.previousSampleRate = sampleRate
        self.previousBitDepth = bitDepth
        DispatchQueue.main.async { [self] in
            let readableSampleRate = sampleRate / 1000
            self.currentSampleRate = readableSampleRate
            self.currentBitDepth = bitDepth
            
            let delegate = AppDelegate.instance
            
            if enableBitDepthDetection {
                if let bitDepth = bitDepth {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / %d bit", readableSampleRate, bitDepth)
                } else {
                    delegate?.statusItemTitle = String(format: "%.1f kHz / ? bit", readableSampleRate)
                }
            } else {
                delegate?.statusItemTitle = String(format: "%.1f kHz", readableSampleRate)
            }
        }
        self.runUserScript(sampleRate, bitDepth: bitDepth)
    }
    
    func runUserScript(_ sampleRate: Float64, bitDepth: Int?) {
        guard let scriptPath = Defaults.shared.shellScriptPath else { return }
        let argumentSampleRate = String(Int(sampleRate))
        var arguments = [argumentSampleRate]
        
        // Add bit depth as second argument if available
        if let bitDepth = bitDepth {
            arguments.append(String(bitDepth))
        }
        
        Task.detached {
            let scriptURL = URL(fileURLWithPath: scriptPath)
            do {
                let task = try NSUserUnixTask(url: scriptURL)
                try await task.execute(withArguments: arguments)
            }
            catch {
                print("TASK ERR \(error)")
            }
        }
    }
    
    func trackDidChange(_ newTrack: TrackInfo, observedAt: Date) {
        let track = MediaTrack(trackInfo: newTrack)
        guard track.isMusicApp, newTrack.payload.isPlaying == true else {
            detectionGeneration += 1
            wasPlaying = false
            return
        }
        let position = newTrack.payload.elapsedTimeMicros.map { $0 / 1_000_000 }
        var didSeek = false
        if let position, let previous = lastPlaybackPosition, let date = lastPlaybackObservation {
            didSeek = abs(position - previous - observedAt.timeIntervalSince(date)) > 1.0
        }
        let trigger: String? = track != currentTrack ? Trigger.trackChange
            : !wasPlaying ? Trigger.resume
            : didSeek ? Trigger.seek : nil
        previousTrack = currentTrack
        currentTrack = track
        lastPlaybackPosition = position
        lastPlaybackObservation = observedAt
        wasPlaying = true
        if let trigger { beginDetection(at: observedAt, trigger: trigger) }
    }
}
