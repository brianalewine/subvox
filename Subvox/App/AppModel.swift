import AppKit
import Observation

struct DecodedWord: Identifiable, Hashable {
    let id = UUID()
    var prediction: Prediction
    var text: String { prediction.best?.label ?? "?" }
}

@MainActor @Observable
final class AppModel {
    enum Screen: String, CaseIterable, Identifiable {
        case sensors = "Sensors"
        case train = "Train"
        case decode = "Decode"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .sensors: "waveform.path.ecg"
            case .train: "square.stack.3d.up"
            case .decode: "text.bubble"
            }
        }
    }

    let motion = HeadphoneMotionService()
    let audio = AudioService()
    let transcriber = MicTranscriber()
    let passage = PassageTrainer()
    let capture = CaptureController()
    let recorder = SessionRecorder()

    var screen: Screen = .train {
        didSet {
            if screen != .train { passage.stop() }
            syncCaptureMode()
        }
    }

    // MARK: Training

    private(set) var dataset = TemplateStore.load()
    var selectedWord: String?
    var featureSet: FeatureSet = .all {
        didSet { rebuildClassifier() }
    }
    private(set) var classifier: TemplateClassifier?
    private(set) var evaluation: Evaluation?
    private(set) var isEvaluating = false
    private(set) var lastTemplateID: Template.ID?

    // MARK: Decoding

    var decodeMode: CaptureController.Mode = .hold {
        didSet { syncCaptureMode() }
    }
    var maxDistance: Double = 1.5
    var minConfidence: Double = 0.05
    private(set) var decoded: [DecodedWord] = []
    private(set) var lastSegment: [MotionSample] = []

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var started = false

    init() {
        selectedWord = dataset.vocabulary.first
        rebuildClassifier()
    }

    func start() {
        guard !started else { return }
        started = true
        motion.onSample = { [weak self] sample in self?.ingest(sample) }
        capture.onSegment = { [weak self] segment in self?.handleSegment(segment) }
        motion.start()
        audio.refreshDevices()
        installKeyMonitor()
    }

    private func ingest(_ sample: MotionSample) {
        passage.ingest(sample)
        if !passage.running { capture.ingest(sample) }
        recorder.record(sample)
    }

    private func syncCaptureMode() {
        capture.autoEnabled = screen == .decode && decodeMode == .auto
    }

    private func handleSegment(_ segment: [MotionSample]) {
        lastSegment = segment
        switch screen {
        case .train:
            guard let word = selectedWord else { return }
            addTemplate(Template(label: word, samples: segment))
            recorder.logEvent(segment, kind: "train", label: word, confidence: nil)
        case .decode:
            guard let classifier else { return }
            let prediction = classifier.predict(segment, maxDistance: maxDistance, minConfidence: minConfidence)
            decoded.append(DecodedWord(prediction: prediction))
            recorder.logEvent(segment, kind: prediction.accepted ? "decode" : "reject",
                              label: prediction.best?.label ?? "", confidence: prediction.confidence)
        case .sensors:
            recorder.logEvent(segment, kind: "segment", label: recorder.prompt, confidence: nil)
        }
    }

    // MARK: Space bar = hold to capture

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard event.keyCode == 49 else { return event }
            let isDown = event.type == .keyDown
            let isRepeat = isDown && event.isARepeat
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.spaceCapturesMotion else { return false }
                if !isDown {
                    self.capture.end()
                } else if !isRepeat {
                    self.capture.begin()
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private var spaceCapturesMotion: Bool {
        // Let text fields keep the space bar.
        if NSApp.keyWindow?.firstResponder is NSText { return false }
        switch screen {
        case .train: return !passage.running && !passageMode && selectedWord != nil
        case .decode: return decodeMode == .hold && classifier != nil
        case .sensors: return recorder.isRecording
        }
    }

    // MARK: Dataset editing

    var passageMode = true

    func startPassage() {
        guard screen == .train, passageMode, motion.status == .streaming, !capture.isCapturing else { return }
        if passage.testReading {
            guard let classifier else { return }
            let distance = maxDistance, confidence = minConfidence
            passage.start(save: savePassage) { takes, count in
                var correct = 0
                var rejected = 0
                var errors: [String: Int] = [:]
                for take in takes {
                    let result = classifier.predict(take.samples, maxDistance: distance, minConfidence: confidence)
                    if !result.accepted {
                        rejected += 1
                    } else if result.best?.label == take.label {
                        correct += 1
                    } else if let label = result.best?.label {
                        errors["\(take.label) → \(label)", default: 0] += 1
                    }
                }
                var summary = "Fresh reading: \(correct) of \(count) prompts correct. " +
                    "\(takes.count - correct - rejected) misclassified, \(rejected) rejected, \(count - takes.count) skipped."
                if !errors.isEmpty {
                    let common = errors.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(3)
                    summary += " Mix-ups: " + common.map { "\($0.key) (\($0.value))" }.joined(separator: ", ") + "."
                }
                return summary
            }
        } else {
            passage.start(save: savePassage)
        }
    }

    func savePassage(_ takes: [Template]) throws {
        var updated = dataset
        for take in takes where !updated.vocabulary.contains(take.label) {
            updated.vocabulary.append(take.label)
        }
        updated.templates += takes
        try TemplateStore.write(updated)
        dataset = updated
        lastTemplateID = takes.last?.id
        if selectedWord == nil { selectedWord = takes.first?.label }
        rebuildClassifier()
    }

    func templates(for word: String) -> [Template] {
        dataset.templates.filter { $0.label == word }
    }

    func addWord(_ raw: String) {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, !dataset.vocabulary.contains(word) else { return }
        dataset.vocabulary.append(word)
        selectedWord = word
        persist()
    }

    func removeWord(_ word: String) {
        dataset.vocabulary.removeAll { $0 == word }
        dataset.templates.removeAll { $0.label == word }
        if selectedWord == word { selectedWord = dataset.vocabulary.first }
        persist()
    }

    func addTemplate(_ template: Template) {
        dataset.templates.append(template)
        lastTemplateID = template.id
        persist()
    }

    func deleteTemplate(_ id: Template.ID) {
        dataset.templates.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        TemplateStore.save(dataset)
        rebuildClassifier()
    }

    private func rebuildClassifier() {
        classifier = TemplateClassifier(templates: dataset.templates, featureSet: featureSet)
        evaluation = nil
    }

    func evaluate() {
        guard !isEvaluating else { return }
        isEvaluating = true
        let templates = dataset.templates
        let featureSet = featureSet
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Evaluation.run(templates: templates, featureSet: featureSet)
            }.value
            self.evaluation = result
            self.isEvaluating = false
        }
    }

    // MARK: Decode transcript

    var transcript: String {
        decoded.filter(\.prediction.accepted).map(\.text).joined(separator: " ")
    }

    func clearDecoded() {
        decoded.removeAll()
        lastSegment = []
    }

    // MARK: Mic

    func toggleMic() async {
        if audio.isRunning {
            transcriber.stop()
            audio.stop()
        } else {
            await audio.start()
            if audio.isRunning { await transcriber.start(sink: audio.sink) }
        }
    }
}
