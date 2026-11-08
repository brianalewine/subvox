import Foundation
import Observation

enum PassageAlignment {
    // Initial stillness targets for calibration, independent of the learned word signal.
    static let stillAccelerationLimit = 0.01 // g, gravity removed
    static let stillRotationLimit = 0.05 // radians / second

    static func acceleration(_ sample: MotionSample) -> Double {
        sqrt(sample.ax * sample.ax + sample.ay * sample.ay + sample.az * sample.az)
    }

    static func rotation(_ sample: MotionSample) -> Double {
        sqrt(sample.rx * sample.rx + sample.ry * sample.ry + sample.rz * sample.rz)
    }

    static func isStill(_ samples: [MotionSample]) -> Bool {
        guard !samples.isEmpty else { return false }
        let acceleration = samples.map(acceleration).sorted()
        let rotation = samples.map(rotation).sorted()
        let percentile = min(samples.count - 1, samples.count * 9 / 10)
        return acceleration[percentile] <= stillAccelerationLimit && rotation[percentile] <= stillRotationLimit
    }
    static let readings: [(title: String, text: String)] = [
        ("Research methods", "Define the hypothesis. Identify each variable and specify the outcome. Select a representative sample. Describe the procedure, document the evidence, and explain how another researcher could replicate the experiment."),
        ("Statistics", "Estimate the population mean. Calculate the variance and standard deviation. Compare the median across groups. Interpret the confidence interval. Discuss sampling bias, statistical significance, correlation, and the limits of causal inference."),
        ("Argument and writing", "State the thesis and establish its context. Examine the author's premise. Use a citation to support the claim. Address a plausible objection. Synthesize competing perspectives and revise the conclusion."),
        ("Biology", "A mutation can alter the structure of a protein. Trace the mechanism from gene expression to a measurable trait. Explain how natural selection changes the frequency of an allele across generations."),
        ("Economics and policy", "Scarcity forces a household to allocate resources. Estimate the opportunity cost of each alternative. Evaluate how an incentive changes demand. Distinguish an equitable distribution from an efficient allocation."),
        ("Computing", "Design an algorithm to traverse a network. Choose a data structure and specify a constraint. Compare memory consumption, latency, and computational complexity. Verify that the implementation preserves the invariant."),
        ("Humanities", "Examine the primary source in its historical context. Consider the narrator's perspective and the audience. Interpret the metaphor. Compare conflicting accounts before attributing motive or drawing an analogy."),
        ("Physical sciences", "Model the transfer of momentum during a collision. Predict the change in kinetic energy. Measure the displacement and acceleration. Check the equilibrium assumption and quantify uncertainty in the final result."),
        ("Everyday commands", commands)
    ]
    static let commands = "Yes, open the door. No, close the window. Go left, turn right. Step back, move forward. Start here, stop there. Next, open the map. Then close the map."

    static func words(in text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    static func intact(_ samples: [MotionSample], from start: Double, to end: Double) -> Bool {
        guard samples.count >= 6, let first = samples.first, let last = samples.last,
              first.t - start < 0.15, end - last.t < 0.15 else { return false }
        return zip(samples, samples.dropFirst()).allSatisfy { $1.t > $0.t && $1.t - $0.t < 0.15 }
    }

    static func template(word: String, samples: [MotionSample], from start: Double,
                         to end: Double, threshold: Double) -> Template? {
        guard intact(samples, from: start, to: end) else { return nil }
        let active = samples.indices.filter { MotionFeatures.energy(samples[$0]) > threshold }
        guard active.count >= 3, let first = active.first, let last = active.last,
              samples[last].t - samples[first].t >= 0.10,
              samples[first].t - start >= 0.04, end - samples[last].t >= 0.06 else { return nil }
        let bounds = max(0, first - 2)...min(samples.count - 1, last + 2)
        return Template(label: word, samples: Array(samples[bounds]))
    }
}

@MainActor @Observable
final class PassageTrainer {
    enum WordOutcome: Equatable { case saved, skipped }
    private(set) var lastWordOutcome: WordOutcome?
    private(set) var lastFinishedWord = ""
    private(set) var isPreparingWord = false
    private(set) var preparationStartedAt: TimeInterval = 0
    static let wordPreparationSeconds: TimeInterval = 0.6
    var text = PassageAlignment.readings[0].text { didSet { onSettingsChange?() } }
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored var onSettingsChange: (() -> Void)?
    var repetitions = 4 { didSet { onSettingsChange?() } }
    var secondsPerWord = 1.6 { didSet { onSettingsChange?() } }
    var autoContinue = false { didSet { onSettingsChange?() } }
    private(set) var countdown: Int?
    private(set) var isMeasuringStillness = false
    private(set) var awaitingCalibrationRetry = false
    private(set) var calibrationWarning: String?
    private(set) var nextSessionCountdown: Int?
    private(set) var completedWords = 0
    private(set) var savedByWord: [String: Int] = [:]
    private(set) var skippedByWord: [String: Int] = [:]
    private(set) var completedReadings = 0
    private(set) var plannedReadings = 0
    private(set) var stoppedEarly = false
    private(set) var failureMessage: String?
    private var passageChanged = false
    private(set) var queuedWords: [String] = []
    private(set) var running = false
    private(set) var paused = false
    private(set) var awaitingNextSession = false
    private var pauseRevision = 0
    private var sessionQueue: [String]?
    private var sessionPasses: Int?
    private(set) var cueIndex: Int?
    private(set) var wordStartedAt: TimeInterval = 0
    private(set) var wordDuration: TimeInterval = 1.6
    private(set) var cue = ""
    private(set) var detail = ""
    private(set) var report = ""
    @ObservationIgnored private var recording: [MotionSample] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    var nextWord: String? {
        guard let cueIndex, queuedWords.indices.contains(cueIndex + 1) else { return nil }
        return queuedWords[cueIndex + 1]
    }

    var isSingleWordSession: Bool { sessionQueue != nil }
    var sessionPreview: String {
        if let sessionQueue, let word = sessionQueue.first {
            return "\(sessionQueue.count) repetitions of “\(word)”"
        }
        return text
    }
    var sessionTitle: String {
        if let word = sessionQueue?.first { return word }
        return PassageAlignment.readings.first { $0.text == text }?.title ?? "Custom passage"
    }

    func startNextSession(save: @escaping ([Template]) throws -> Void, skipInitialCountdown: Bool = false) {
        if running && awaitingNextSession {
            awaitingNextSession = false
            nextSessionCountdown = nil
            if !passageChanged { return }
            task?.cancel()
            finish("")
        }
        start(queue: sessionQueue, passesOverride: sessionPasses, save: save,
              skipInitialCountdown: skipInitialCountdown)
    }

    func autoContinueNext(save: @escaping ([Template]) throws -> Void) async {
        guard autoContinue, awaitingNextSession else { return }
        defer { if !Task.isCancelled { nextSessionCountdown = nil } }
        do {
            for remaining in (1...5).reversed() {
                nextSessionCountdown = remaining
                try await Task.sleep(for: .seconds(1))
            }
            try Task.checkCancellation()
            guard awaitingNextSession else { return }
            startNextSession(save: save, skipInitialCountdown: true)
        } catch { }
    }

    func ingest(_ sample: MotionSample) {
        if running && !paused && !awaitingNextSession && !awaitingCalibrationRetry { recording.append(sample) }
    }

    func retryCalibration() {
        guard awaitingCalibrationRetry else { return }
        awaitingCalibrationRetry = false
        calibrationWarning = nil
    }

    func captureBaseline(countdownSeconds: Int = 3, duration: Double = 2, requiresStillness: Bool = true) async throws -> [MotionSample] {
        while true {
            if countdownSeconds > 0 {
                cue = "Get ready"
                for remaining in stride(from: countdownSeconds, through: 1, by: -1) {
                    countdown = remaining
                    _ = try await captureWindow(duration: 1)
                }
            }
            countdown = nil
            cue = "Hold still"
            isMeasuringStillness = true
            let start = try await captureWindow(duration: duration)
            isMeasuringStillness = false
            let baseline = recording.filter { $0.t >= start }
            let intact = PassageAlignment.intact(baseline, from: start, to: now)
            if intact && (!requiresStillness || PassageAlignment.isStill(baseline)) { return baseline }
            calibrationWarning = intact
                ? "Too much movement during calibration. Relax your jaw and keep your head still."
                : "Motion samples were interrupted. Check your headphones before retrying."
            cue = "Try again"
            awaitingCalibrationRetry = true
            recording.removeAll(keepingCapacity: true)
            while awaitingCalibrationRetry {
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
        }
    }

    func togglePause() {
        guard running, !awaitingCalibrationRetry else { return }
        paused.toggle()
        pauseRevision += 1
        recording.removeAll(keepingCapacity: true)
    }

    func cyclePassage(_ direction: Int) {
        guard awaitingNextSession else { return }
        let readings = PassageAlignment.readings
        let current = readings.firstIndex { $0.text == text } ?? 0
        text = readings[(current + direction + readings.count) % readings.count].text
        sessionQueue = nil
        sessionPasses = nil
        passageChanged = true
    }

    @discardableResult
    func cycleSingleWord(_ direction: Int, vocabulary: [String]) -> String? {
        guard awaitingNextSession, let queue = sessionQueue, !vocabulary.isEmpty else { return nil }
        let current = vocabulary.firstIndex(of: queue.first ?? "") ?? 0
        let index = (current + direction % vocabulary.count + vocabulary.count) % vocabulary.count
        let word = vocabulary[index]
        sessionQueue = Array(repeating: word, count: queue.count)
        sessionPasses = 1
        return word
    }

    /// A pause invalidates the entire window, including rapid pause/resume pairs.
    func captureWindow(duration: Double, preparationDuration: Double = 0) async throws -> Double {
        while true {
            while paused {
                try await Task.sleep(for: .milliseconds(20))
            }
            try Task.checkCancellation()
            let revision = pauseRevision
            if preparationDuration > 0 {
                isPreparingWord = true
                preparationStartedAt = now
                recording.removeAll(keepingCapacity: true)
                while now - preparationStartedAt < preparationDuration && revision == pauseRevision {
                    try await Task.sleep(for: .milliseconds(20))
                }
                try Task.checkCancellation()
                if revision != pauseRevision { continue }
                isPreparingWord = false
            }
            let start = now
            recording.removeAll(keepingCapacity: true)
            wordStartedAt = start
            wordDuration = duration
            while now - start < duration && revision == pauseRevision {
                try await Task.sleep(for: .seconds(min(0.02, max(0.001, duration - (now - start)))))
            }
            try Task.checkCancellation()
            if revision == pauseRevision { return start }
        }
    }

    func stop() {
        let interrupted = running && !awaitingNextSession
        awaitingNextSession = false
        nextSessionCountdown = nil
        guard running else { return }
        task?.cancel()
        stoppedEarly = interrupted
        finish(interrupted ? "Stopped before the current reading finished." : "")
    }

    private func finish(_ message: String) {
        running = false
        paused = false
        countdown = nil
        isMeasuringStillness = false
        awaitingCalibrationRetry = false
        calibrationWarning = nil
        isPreparingWord = false
        onFinish?()
        recording.removeAll()
        task = nil
        report = [report, message].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func start(queue: [String]? = nil, passesOverride: Int? = nil, save: @escaping ([Template]) throws -> Void, score: ((String, Template?) async -> Void)? = nil, skipInitialCountdown: Bool = false) {
        let words = queue ?? PassageAlignment.words(in: text)
        guard !running, !words.isEmpty, queue != nil || words.count <= 150 else { return }
        running = true
        passageChanged = false
        savedByWord = [:]
        lastWordOutcome = nil
        lastFinishedWord = ""
        skippedByWord = [:]
        completedReadings = 0
        stoppedEarly = false
        failureMessage = nil
        sessionQueue = queue
        sessionPasses = passesOverride
        paused = false
        calibrationWarning = nil
        awaitingCalibrationRetry = false
        awaitingNextSession = false
        cueIndex = nil
        completedWords = 0
        report = ""
        cue = "Hold still"
        detail = "Measuring resting motion"
        let passes = passesOverride ?? (score == nil ? repetitions : 1)
        plannedReadings = passes
        queuedWords = words
        task = Task {
            do {
                var total = 0
                var missed: [String: Int] = [:]
                for pass in 1...passes {
                    try Task.checkCancellation()
                    recording.removeAll(keepingCapacity: true)
                    cueIndex = nil
                    completedWords = 0
                    cue = "Hold still"
                    detail = "Reading \(pass) of \(passes) · measuring resting motion"
                    let baseline: [MotionSample]
                    if score == nil {
                        baseline = try await captureBaseline()
                    } else {
                        let start = try await captureWindow(duration: 2)
                        baseline = recording.filter { $0.t >= start }
                        guard PassageAlignment.intact(baseline, from: start, to: now) else {
                            finish("Motion stream interrupted. Reconnect your headphones and start again.")
                            return
                        }
                    }
                    let energy = baseline.map(MotionFeatures.energy).sorted()
                    let median = energy[energy.count / 2]
                    let threshold = max(0.001, median * 2, energy[energy.count * 9 / 10] * 1.4)
                    let readingID = UUID()
                    for (index, word) in words.enumerated() {
                        cueIndex = index
                        cue = word
                        detail = "Reading \(pass) of \(passes) · word \(index + 1) of \(words.count)"
                        let start = try await captureWindow(duration: secondsPerWord,
                                                            preparationDuration: score == nil ? Self.wordPreparationSeconds : 0)
                        let end = now
                        let window = recording.filter { $0.t >= start && $0.t < end }
                        let take = PassageAlignment.template(word: word, samples: window, from: start, to: end, threshold: threshold)
                        if let score {
                            cueIndex = nil
                            cue = "Rest"
                            await score(word, take)
                            try Task.checkCancellation()
                        } else if var take {
                            take.readingID = readingID
                            try save([take])
                            savedByWord[take.label, default: 0] += 1
                            total += 1
                            lastFinishedWord = word
                            lastWordOutcome = .saved
                        } else {
                            missed[word, default: 0] += 1
                            skippedByWord[word, default: 0] += 1
                            lastFinishedWord = word
                            lastWordOutcome = .skipped
                        }
                        completedWords = index + 1
                    }
                    if score != nil {
                        finish("Reading complete.")
                        return
                    }
                    completedReadings = pass
                    report = "\(total) word takes saved across \(pass) of \(passes) readings."
                    if !missed.isEmpty {
                        report += " Skipped: " + missed.keys.sorted().map { "\($0) ×\(missed[$0]!)" }.joined(separator: ", ") + "."
                    }
                    if pass < passes {
                        awaitingNextSession = true
                        while awaitingNextSession {
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        try Task.checkCancellation()
                    }
                }
                finish("")
                awaitingNextSession = true
            } catch is CancellationError {
                return
            } catch {
                failureMessage = "Couldn’t save this reading. \(error.localizedDescription)"
                finish("Couldn’t save this reading. \(error.localizedDescription)")
            }
        }
    }
}
