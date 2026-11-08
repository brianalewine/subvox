import Foundation
import Observation

enum PassageAlignment {
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
    var text = PassageAlignment.readings[0].text
    var testReading = false
    var repetitions = 4
    var secondsPerWord = 1.6
    private(set) var queuedWords: [String] = []
    private(set) var running = false
    private(set) var cueIndex: Int?
    private(set) var cue = ""
    private(set) var detail = ""
    private(set) var report = ""
    @ObservationIgnored private var recording: [MotionSample] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func ingest(_ sample: MotionSample) {
        if running { recording.append(sample) }
    }

    func stop() {
        guard running else { return }
        task?.cancel()
        finish("Stopped before the current reading finished.")
    }

    private func finish(_ message: String) {
        running = false
        recording.removeAll()
        task = nil
        report = [report, message].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    func start(queue: [String]? = nil, passesOverride: Int? = nil, save: @escaping ([Template]) throws -> Void, score: (([Template], Int) -> String)? = nil) {
        let words = queue ?? PassageAlignment.words(in: text)
        guard !running, !words.isEmpty, queue != nil || words.count <= 150 else { return }
        running = true
        cueIndex = nil
        report = ""
        cue = "Hold still"
        detail = "Measuring resting motion"
        let passes = passesOverride ?? (score == nil ? repetitions : 1)
        queuedWords = words
        task = Task {
            do {
                var total = 0
                var missed: [String: Int] = [:]
                for pass in 1...passes {
                    try Task.checkCancellation()
                    recording.removeAll(keepingCapacity: true)
                    cueIndex = nil
                    cue = "Hold still"
                    detail = "Reading \(pass) of \(passes) · measuring resting motion"
                    let baselineStart = now
                    try await Task.sleep(for: .seconds(2))
                    let baseline = recording.filter { $0.t >= baselineStart }
                    guard PassageAlignment.intact(baseline, from: baselineStart, to: now) else {
                        finish("Motion stream interrupted. Reconnect your headphones and start again.")
                        return
                    }
                    let energy = baseline.map(MotionFeatures.energy).sorted()
                    let median = energy[energy.count / 2]
                    let threshold = max(0.001, median * 2, energy[energy.count * 9 / 10] * 1.4)
                    var boundaries: [Double] = []
                    for (index, word) in words.enumerated() {
                        cueIndex = index
                        cue = word
                        detail = "Reading \(pass) of \(passes) · word \(index + 1) of \(words.count)"
                        boundaries.append(now)
                        try await Task.sleep(for: .seconds(secondsPerWord))
                    }
                    boundaries.append(now)
                    cueIndex = nil
                    cue = "Rest"
                    try await Task.sleep(for: .milliseconds(250))
                    var takes: [Template] = []
                    for (i, word) in words.enumerated() {
                        let start = boundaries[i], end = boundaries[i + 1]
                        let window = recording.filter { $0.t >= start && $0.t < end }
                        if let take = PassageAlignment.template(word: word, samples: window,
                                                                from: start, to: end, threshold: threshold) {
                            takes.append(take)
                        } else {
                            missed[word, default: 0] += 1
                        }
                    }
                    if let score {
                        finish(score(takes, words.count))
                        return
                    }
                    if !takes.isEmpty { try save(takes) }
                    total += takes.count
                    report = "\(total) word takes saved across \(pass) of \(passes) readings."
                    if !missed.isEmpty {
                        report += " Skipped: " + missed.keys.sorted().map { "\($0) ×\(missed[$0]!)" }.joined(separator: ", ") + "."
                    }
                }
                finish("")
            } catch is CancellationError {
                return
            } catch {
                finish("Couldn’t save this reading. \(error.localizedDescription)")
            }
        }
    }
}
