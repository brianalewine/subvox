import XCTest
@testable import Subvox

final class PassageTests: XCTestCase {
    @MainActor
    func testWordPreparationPrecedesCaptureClock() async throws {
        let trainer = PassageTrainer()
        let before = ProcessInfo.processInfo.systemUptime
        let capture = Task { try await trainer.captureWindow(duration: 0.05, preparationDuration: 0.15) }
        defer { capture.cancel() }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(trainer.isPreparingWord)
        XCTAssertEqual(trainer.wordStartedAt, 0)
        let start = try await capture.value
        XCTAssertGreaterThanOrEqual(start - before, 0.15)
        XCTAssertFalse(trainer.isPreparingWord)
    }

    @MainActor
    func testSettingsSurviveRelaunchIncludingNestedAndLiveSpeedChanges() throws {
        let suite = "Subvox.SettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.screen = .decode
        model.passageMode = false
        model.singleWordRepetitions = 12
        model.passage.text = "A custom passage."
        model.passage.repetitions = 7
        model.passage.secondsPerWord = 2.8
        model.passage.autoContinue = true
        model.decodeReading.secondsPerWord = 2.2
        model.decodeMode = .auto
        model.maxDistance = 2.4
        model.minConfidence = 0.2
        model.featureSet = [.acceleration, .rotation]
        model.capture.triggerRatio = 4.5
        model.audio.preferredDeviceUID = "test-device-uid"
        model.recorder.condition = .whisper
        model.recorder.prompt = "Saved prompt"

        let restored = AppModel(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.screen, .decode)
        XCTAssertFalse(restored.passageMode)
        XCTAssertEqual(restored.singleWordRepetitions, 12)
        XCTAssertEqual(restored.passage.text, "A custom passage.")
        XCTAssertEqual(restored.passage.repetitions, 7)
        XCTAssertEqual(restored.passage.secondsPerWord, 2.8)
        XCTAssertTrue(restored.passage.autoContinue)
        XCTAssertEqual(restored.decodeReading.secondsPerWord, 2.2)
        XCTAssertEqual(restored.decodeMode, .auto)
        XCTAssertEqual(restored.maxDistance, 2.4)
        XCTAssertEqual(restored.minConfidence, 0.2)
        XCTAssertEqual(restored.featureSet, [.acceleration, .rotation])
        XCTAssertEqual(restored.capture.triggerRatio, 4.5)
        XCTAssertEqual(restored.audio.preferredDeviceUID, "test-device-uid")
        XCTAssertEqual(restored.recorder.condition, .whisper)
        XCTAssertEqual(restored.recorder.prompt, "Saved prompt")
        XCTAssertFalse(restored.passage.running)
        XCTAssertFalse(restored.recorder.isRecording)
        XCTAssertFalse(restored.audio.isRunning)
        restored.passage.secondsPerWord = 3.2
        XCTAssertEqual(AppModel(defaults: defaults).passage.secondsPerWord, 3.2)
    }

    func testStillnessRejectsAccelerationAndRotationIndependently() {
        let quiet = (0..<100).map { MotionSample(t: Double($0) / 50, accel: (0.001, 0, 0), rotation: (0.001, 0, 0)) }
        XCTAssertTrue(PassageAlignment.isStill(quiet))
        XCTAssertFalse(PassageAlignment.isStill([]))
        XCTAssertFalse(PassageAlignment.isStill((0..<100).map {
            MotionSample(t: Double($0) / 50, accel: (0.02, 0, 0))
        }))
        XCTAssertFalse(PassageAlignment.isStill((0..<100).map {
            MotionSample(t: Double($0) / 50, rotation: (0.1, 0, 0))
        }))
    }

    @MainActor
    func testNoisyCalibrationWaitsForExplicitRetry() async throws {
        let trainer = PassageTrainer()
        trainer.start(queue: ["test"], passesOverride: 1, save: { _ in XCTFail("No word should be captured") })
        let stream = Task { @MainActor in
            while !Task.isCancelled {
                trainer.ingest(MotionSample(t: ProcessInfo.processInfo.systemUptime, accel: (0.03, 0, 0)))
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { stream.cancel(); trainer.stop() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(trainer.countdown, 3)
        XCTAssertFalse(trainer.isMeasuringStillness)
        for _ in 0..<350 {
            if trainer.awaitingCalibrationRetry { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(trainer.awaitingCalibrationRetry)
        XCTAssertNotNil(trainer.calibrationWarning)
        XCTAssertNil(trainer.cueIndex)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(trainer.awaitingCalibrationRetry)
        trainer.retryCalibration()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(trainer.awaitingCalibrationRetry)
        XCTAssertNil(trainer.calibrationWarning)
        XCTAssertEqual(trainer.countdown, 3)
        XCTAssertFalse(trainer.isMeasuringStillness)
        trainer.stop()
        XCTAssertFalse(trainer.awaitingCalibrationRetry)
        XCTAssertNil(trainer.countdown)
    }

    @MainActor
    func testValidTakesPersistBeforeStopAndAreNotDuplicatedOnCompletion() async throws {
        for stopMidway in [true, false] {
            let trainer = PassageTrainer()
            trainer.secondsPerWord = 0.4
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
            defer { try? FileManager.default.removeItem(at: url) }
            var saved: [Template] = []
            trainer.start(queue: ["first", "second", "third"], passesOverride: 1, save: { takes in
                saved += takes
                try JSONEncoder().encode(saved).write(to: url, options: .atomic)
            })
            let stream = Task { @MainActor in
                while !Task.isCancelled {
                    let now = ProcessInfo.processInfo.systemUptime
                    let elapsed = now - trainer.wordStartedAt
                    let active = trainer.cueIndex != nil && !trainer.isPreparingWord && (0.10...0.26).contains(elapsed)
                    trainer.ingest(MotionSample(t: now, rotation: (active ? 0.1 : 0.001, 0, 0)))
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            defer { stream.cancel(); trainer.stop() }
            for _ in 0..<1100 {
                if stopMidway ? trainer.cueIndex == 2 : trainer.awaitingNextSession { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            if stopMidway {
                XCTAssertEqual(trainer.cueIndex, 2)
                trainer.stop()
                XCTAssertTrue(trainer.stoppedEarly)
                XCTAssertEqual(trainer.completedReadings, 0)
            } else {
                XCTAssertTrue(trainer.awaitingNextSession)
                XCTAssertEqual(trainer.completedReadings, 1)
            }
            let persisted = try JSONDecoder().decode([Template].self, from: Data(contentsOf: url))
            XCTAssertEqual(persisted.map(\.label), stopMidway ? ["first", "second"] : ["first", "second", "third"])
            XCTAssertEqual(Set(persisted.map(\.id)).count, persisted.count)
            XCTAssertEqual(Set(persisted.compactMap(\.readingID)).count, 1)
            XCTAssertEqual(trainer.savedByWord.values.reduce(0, +), persisted.count)
            XCTAssertEqual(trainer.lastWordOutcome, .saved)
            XCTAssertEqual(trainer.lastFinishedWord, stopMidway ? "second" : "third")
            if !stopMidway {
                let text = trainer.text
                XCTAssertEqual(trainer.cycleSingleWord(1, vocabulary: ["first", "other"]), "other")
                XCTAssertEqual(trainer.sessionTitle, "other")
                XCTAssertEqual(trainer.cycleSingleWord(-1, vocabulary: ["first", "other"]), "first")
                XCTAssertEqual(trainer.cycleSingleWord(-1, vocabulary: ["first", "other"]), "other")
                XCTAssertNil(trainer.cycleSingleWord(1, vocabulary: []))
                XCTAssertEqual(trainer.text, text)
                trainer.startNextSession(save: { _ in })
                XCTAssertEqual(trainer.queuedWords, ["other", "other", "other"])
                XCTAssertEqual(trainer.plannedReadings, 1)
            }
        }
    }

    @MainActor
    func testManualContinuationWaitsBetweenReadingsWithoutCountdown() async throws {
        let trainer = PassageTrainer()
        trainer.secondsPerWord = 0.06
        trainer.start(queue: ["test"], passesOverride: 2, save: { _ in })
        let stream = Task { @MainActor in
            while !Task.isCancelled {
                trainer.ingest(MotionSample(t: ProcessInfo.processInfo.systemUptime, rotation: (0.001, 0, 0)))
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        defer { stream.cancel(); trainer.stop() }
        for _ in 0..<400 {
            if trainer.awaitingNextSession { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(trainer.awaitingNextSession)
        XCTAssertTrue(trainer.running)
        XCTAssertEqual(trainer.completedReadings, 1)
        XCTAssertEqual(trainer.lastWordOutcome, .skipped)
        XCTAssertEqual(trainer.lastFinishedWord, "test")
        XCTAssertNil(trainer.countdown)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(trainer.awaitingNextSession)
        XCTAssertNil(trainer.nextSessionCountdown)
        trainer.autoContinue = true
        let continuation = Task { await trainer.autoContinueNext(save: { _ in }) }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(trainer.nextSessionCountdown, 5)
        continuation.cancel()
        await continuation.value
        trainer.startNextSession(save: { _ in })
        XCTAssertFalse(trainer.awaitingNextSession)
        XCTAssertNil(trainer.nextSessionCountdown)
        XCTAssertNil(trainer.countdown)
        XCTAssertEqual(trainer.completedReadings, 1)
    }

    @MainActor
    func testPauseRestartsCaptureWindowAndStopClearsPause() async throws {
        let trainer = PassageTrainer()
        trainer.start(queue: ["test"], passesOverride: 1, save: { _ in
            XCTFail("An interrupted window must not save a take")
        })
        defer { trainer.stop() }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(trainer.countdown, 3)
        XCTAssertEqual(trainer.completedWords, 0)
        let originalStart = trainer.wordStartedAt
        trainer.togglePause()
        XCTAssertTrue(trainer.paused)
        XCTAssertTrue(trainer.running)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(trainer.wordStartedAt, originalStart)
        trainer.togglePause()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(trainer.wordStartedAt, originalStart)
        trainer.togglePause()
        trainer.stop()
        XCTAssertFalse(trainer.running)
        XCTAssertFalse(trainer.paused)
        XCTAssertFalse(trainer.awaitingNextSession)
        XCTAssertNil(trainer.countdown)
    }

    func testTokenizationPreservesOrderAndRepetitions() {
        XCTAssertEqual(PassageAlignment.words(in: "“Don’t infer,” don't! Re-test."),
                       ["don't", "infer", "don't", "re", "test"])
    }

    func testLegacyDatasetLoadsWithoutReadingOrScoreMetadata() throws {
        let json = #"{"vocabulary":["yes"],"templates":[{"id":"56D0DECE-F654-4361-8AEE-2503890D9200","label":"yes","samples":[],"createdAt":0}]}"#
        let dataset = try JSONDecoder().decode(Dataset.self, from: Data(json.utf8))
        XCTAssertEqual(dataset.templates.first?.label, "yes")
        XCTAssertNil(dataset.templates.first?.readingID)
        XCTAssertNil(dataset.decodeScores)
    }

    func testAlignmentRequiresAnIntactWindowWithInteriorMotion() {
        func samples(active: Range<Int>) -> [MotionSample] {
            (0..<40).map { i in
                MotionSample(t: Double(i) / 25, rotation: (active.contains(i) ? 0.1 : 0.001, 0, 0))
            }
        }
        func aligned(_ window: [MotionSample]) -> Template? {
            PassageAlignment.template(word: "infer", samples: window, from: 0, to: 1.6, threshold: 0.02)
        }
        let good = samples(active: 8..<20)
        XCTAssertEqual(aligned(good)?.samples, Array(good[6...21]))
        XCTAssertNil(aligned(samples(active: 0..<0)))
        XCTAssertNil(aligned(samples(active: 33..<40)))
        XCTAssertNil(aligned(Array(good.prefix(10)) + Array(good.suffix(20))))
    }
}
