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
    let decodeReading = PassageTrainer()
    let capture = CaptureController()
    let recorder = SessionRecorder()

    var screen: Screen = .train {
        didSet {
            saveSettings()
            if screen != .train { passage.stop() }
            if screen != .decode { decodeReading.stop() }
            syncCaptureMode()
        }
    }

    // MARK: Training

    private(set) var dataset = TemplateStore.load()
    var selectedWord: String? { didSet { saveSettings() } }
    var singleWordRepetitions = 4 { didSet { saveSettings() } }
    var featureSet: FeatureSet = .all {
        didSet { saveSettings(); rebuildClassifier() }
    }
    private(set) var classifier: TemplateClassifier?
    private(set) var evaluation: Evaluation?
    private(set) var isEvaluating = false
    private(set) var lastTemplateID: Template.ID?

    // MARK: Decoding

    var decodeMode: CaptureController.Mode = .hold {
        didSet { saveSettings(); syncCaptureMode() }
    }
    var maxDistance: Double = 1.5 { didSet { saveSettings() } }
    var minConfidence: Double = 0.05 { didSet { saveSettings() } }
    private(set) var decoded: [DecodedWord] = []
    private(set) var lastSegment: [MotionSample] = []

    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var started = false

    @ObservationIgnored private let settingsDefaults: UserDefaults
    @ObservationIgnored private var restoringSettings = true

    init(defaults: UserDefaults = .standard) {
        settingsDefaults = defaults
        decodeReading.onFinish = { [weak self] in self?.persistScores() }
        selectedWord = dataset.vocabulary.first
        if let data = defaults.data(forKey: "settings.v1"),
           let settings = try? JSONDecoder().decode(AppPreferences.self, from: data) {
            screen = Screen(rawValue: settings.screen) ?? .train
            passageMode = settings.passageMode
            if let word = settings.selectedWord, dataset.vocabulary.contains(word) { selectedWord = word }
            singleWordRepetitions = min(20, max(1, settings.singleWordRepetitions))
            passage.text = settings.passageText
            passage.repetitions = min(10, max(1, settings.readings))
            passage.secondsPerWord = min(4, max(0.8, settings.trainingSpeed))
            passage.autoContinue = settings.autoContinue
            decodeReading.secondsPerWord = min(4, max(0.8, settings.decodeSpeed))
            decodeMode = CaptureController.Mode(rawValue: settings.decodeMode) ?? .hold
            maxDistance = min(4, max(0.2, settings.maxDistance))
            minConfidence = min(0.5, max(0, settings.minConfidence))
            featureSet = FeatureSet(rawValue: settings.features).intersection(.all)
            capture.triggerRatio = min(10, max(1.5, settings.triggerRatio))
            audio.preferredDeviceUID = settings.inputDeviceUID
            recorder.condition = SessionRecorder.Condition(rawValue: settings.recordingCondition) ?? .silent
            recorder.prompt = settings.recordingPrompt
        }
        restoringSettings = false
        let changed: () -> Void = { [weak self] in self?.saveSettings() }
        passage.onSettingsChange = changed
        decodeReading.onSettingsChange = changed
        capture.onSettingsChange = changed
        audio.onSettingsChange = changed
        recorder.onSettingsChange = changed
        rebuildClassifier()
        syncCaptureMode()
    }

    private func saveSettings() {
        guard !restoringSettings else { return }
        let settings = AppPreferences(screen: screen.rawValue, passageMode: passageMode,
            selectedWord: selectedWord, singleWordRepetitions: singleWordRepetitions,
            passageText: passage.text, readings: passage.repetitions,
            trainingSpeed: passage.secondsPerWord, autoContinue: passage.autoContinue,
            decodeSpeed: decodeReading.secondsPerWord, decodeMode: decodeMode.rawValue,
            maxDistance: maxDistance, minConfidence: minConfidence, features: featureSet.rawValue,
            triggerRatio: capture.triggerRatio, inputDeviceUID: audio.preferredDeviceUID,
            recordingCondition: recorder.condition.rawValue, recordingPrompt: recorder.prompt)
        if let data = try? JSONEncoder().encode(settings) {
            settingsDefaults.set(data, forKey: "settings.v1")
        }
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
        decodeReading.ingest(sample)
        if !decodeReading.running && !passage.running { capture.ingest(sample) }
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

    // MARK: Keyboard controls

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let trainingKey = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.screen == .train else { return false }
                let passage = self.passage
                let down = event.type == .keyDown && !event.isARepeat
                if passage.awaitingCalibrationRetry && [36, 76].contains(event.keyCode) {
                    if down { passage.retryCalibration() }
                    return true
                }
                if passage.awaitingNextSession {
                    guard [36, 76, 53, 123, 124, 49].contains(event.keyCode) else { return false }
                    if down {
                        switch event.keyCode {
                        case 36, 76:
                            guard self.motion.status == .streaming else { break }
                            passage.startNextSession(save: self.savePassage)
                        case 53: passage.stop()
                        case 123: self.cycleTrainingSelection(-1)
                        case 124: self.cycleTrainingSelection(1)
                        default: break
                        }
                    }
                    return true
                }
                if passage.running && (event.keyCode == 49 || event.keyCode == 53) {
                    if down {
                        if event.keyCode == 49 { passage.togglePause() }
                        else { passage.stop() }
                    }
                    return true
                }
                return false
            }
            if trainingKey { return nil }
            if event.keyCode == 126 || event.keyCode == 125 {
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self else { return false }
                    let reading: PassageTrainer
                    switch self.screen {
                    case .train: reading = self.passage
                    case .decode: reading = self.decodeReading
                    case .sensors: return false
                    }
                    guard reading.running else { return false }
                    if event.type == .keyDown {
                        let change = event.keyCode == 126 ? -0.2 : 0.2
                        reading.secondsPerWord = min(4, max(0.8,
                            ((reading.secondsPerWord + change) * 10).rounded() / 10))
                    }
                    return true
                }
                return consumed ? nil : event
            }
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
        case .decode: return !decodeReading.running && decodeMode == .hold && classifier != nil
        case .sensors: return recorder.isRecording
        }
    }

    // MARK: Dataset editing

    var passageMode = true { didSet { saveSettings() } }

    func cycleTrainingSelection(_ direction: Int) {
        if passage.isSingleWordSession {
            if let word = passage.cycleSingleWord(direction, vocabulary: dataset.vocabulary) {
                selectedWord = word
            }
        } else {
            passage.cyclePassage(direction)
        }
    }

    func startPassage() {
        guard screen == .train, passageMode, motion.status == .streaming, !capture.isCapturing else { return }
        passage.start(save: savePassage)
    }

    var decodePrompt: [String] {
        let trained = Set(classifier?.labels ?? [])
        if let id = dataset.templates.last(where: { $0.readingID != nil })?.readingID {
            let words = dataset.templates.filter { $0.readingID == id && trained.contains($0.label) }.map(\.label)
            if Set(words).count >= 2 { return words }
        }
        let sources = [passage.text] + PassageAlignment.readings.map(\.text)
        let candidates = sources.map { PassageAlignment.words(in: $0).filter(trained.contains) }
        return candidates.first(where: { Set($0).count >= 2 }) ?? trained.sorted()
    }

    private(set) var correct = 0
    private(set) var wrong = 0
    private(set) var rejected = 0
    private(set) var skipped = 0
    var attempted: Int { correct + wrong + rejected + skipped }

    func startDecodeReading() {
        guard screen == .decode, motion.status == .streaming, !decodeReading.running,
              !capture.isCapturing, !capture.isCalibrating, let classifier else { return }
        correct = 0
        wrong = 0
        rejected = 0
        skipped = 0
        clearDecoded()
        let distance = maxDistance, confidence = minConfidence
        decodeReading.start(queue: Array(decodePrompt.prefix(150)), passesOverride: 1, save: { _ in }) { word, take in
            let prediction = await Task.detached(priority: .userInitiated) {
                take.map { classifier.predict($0.samples, maxDistance: distance, minConfidence: confidence) }
            }.value
            guard !Task.isCancelled else { return }
            var score = self.dataset.decodeScores?[word] ?? WordScore()
            score.total += 1
            if let prediction, let take {
                self.lastSegment = take.samples
                self.decoded.append(DecodedWord(prediction: prediction))
                if !prediction.accepted { self.rejected += 1 }
                else if prediction.best?.label == word { self.correct += 1; score.correct += 1 }
                else { self.wrong += 1 }
            } else { self.skipped += 1 }
            if self.dataset.decodeScores == nil { self.dataset.decodeScores = [:] }
            self.dataset.decodeScores?[word] = score
        }
    }

    func persistScores() { TemplateStore.save(dataset) }

    func savePassage(_ takes: [Template]) throws {
        var updated = dataset
        let readingID = passageMode ? UUID() : nil
        let takes = takes.map { original in
            var take = original
            take.readingID = original.readingID ?? readingID
            return take
        }
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
        dataset.decodeScores?[word] = nil
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

    func deleteReading(_ id: UUID) {
        dataset.templates.removeAll { $0.readingID == id }
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

    private(set) var trainingRevision = UUID()

    private func rebuildClassifier() {
        trainingRevision = UUID()
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

private struct AppPreferences: Codable {
    var screen: String
    var passageMode: Bool
    var selectedWord: String?
    var singleWordRepetitions: Int
    var passageText: String
    var readings: Int
    var trainingSpeed: Double
    var autoContinue: Bool
    var decodeSpeed: Double
    var decodeMode: String
    var maxDistance: Double
    var minConfidence: Double
    var features: Int
    var triggerRatio: Double
    var inputDeviceUID: String?
    var recordingCondition: String
    var recordingPrompt: String
}
