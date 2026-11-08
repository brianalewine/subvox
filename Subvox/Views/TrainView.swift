import SwiftUI
import Charts

struct TrainView: View {
    @Environment(AppModel.self) private var model
    @State private var newWord = ""

    @State private var trainingScores: [String: WordScore] = [:]

    var body: some View {
        @Bindable var model = model
        @Bindable var passage = model.passage
        HSplitView {
            if !model.passageMode && !model.passage.running { vocabulary
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.passage.running {
                    Picker("Training mode", selection: $model.passageMode) {
                        Text("Passage").tag(true)
                        Text("Single word").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.capture.isCapturing || model.passage.running)
                    }
                    if model.passageMode || model.passage.running || model.passage.awaitingNextSession {
                        PassagePanel()
                    } else {
                        GroupBox("Single word practice") {
                        VStack(alignment: .leading, spacing: 12) {
                        Text(model.selectedWord ?? "Choose a word").font(.largeTitle.bold())
                        Text("Practice a reading made entirely of this word.").foregroundStyle(.secondary)
                        Stepper("\(model.singleWordRepetitions) words per reading", value: $model.singleWordRepetitions, in: 1...20)
                        Stepper(String(format: "%.1f seconds per word", passage.secondsPerWord),
                                value: $passage.secondsPerWord, in: 0.8...4, step: 0.2)
                        Button("Practice selected word") {
                            guard let word = model.selectedWord else { return }
                            let queue = Array(repeating: word, count: model.singleWordRepetitions)
                            model.passage.start(queue: queue, passesOverride: 1, save: model.savePassage)
                        }.buttonStyle(.borderedProminent)
                        .disabled(model.motion.status != .streaming || model.selectedWord == nil || model.capture.isCapturing)
                        }.padding(8)
                        }
                        DisclosureGroup("Manual capture") { capturePanel }
                        TrainingResultsView(passage: model.passage)
                        if model.motion.status != .streaming { Text(model.motion.status.label).foregroundStyle(.secondary) }
                    }
                    if !model.passage.running {
                        DisclosureGroup("Recorded takes") { takes }
                    }
                }
                .padding(20)
            }
            .frame(minWidth: 520)
        }
    }

    private var vocabulary: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            List(selection: $model.selectedWord) {
                Section("Lowest accuracy first") {
                    ForEach(rankedWords, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Text(accuracy(word).map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "Unscored")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .tag(word)
                        .contextMenu {
                            Button("Delete “\(word)” and its takes", role: .destructive) { model.removeWord(word) }
                        }
                    }
                }
            }
            HStack {
                TextField("Add word", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addWord)
                Button("Add", systemImage: "plus", action: addWord)
                    .labelStyle(.iconOnly)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .task(id: model.trainingRevision) {
            let classifier = model.classifier
            let work = Task.detached(priority: .utility) {
                classifier?.trainingScores() ?? [:]
            }
            let scores = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            if !Task.isCancelled { trainingScores = scores }
        }
    }

    private func accuracy(_ word: String) -> Double? {
        let train = trainingScores[word] ?? WordScore()
        let decode = model.dataset.decodeScores?[word] ?? WordScore()
        return WordScore(correct: train.correct + decode.correct, total: train.total + decode.total).accuracy
    }

    private var rankedWords: [String] {
        model.dataset.vocabulary.sorted { (accuracy($0) ?? 2, $0) < (accuracy($1) ?? 2, $1) }
    }

    private var capturePanel: some View {
        let word = model.selectedWord ?? "—"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Silently mouth “\(word)” while holding Space. Keep your head still; aim for 8–10 takes per word.")
                .foregroundStyle(.secondary)
            HoldToCaptureButton(
                title: "Mouth “\(word)”",
                isCapturing: model.capture.isCapturing,
                isEnabled: model.selectedWord != nil && model.motion.status == .streaming,
                onBegin: model.capture.begin,
                onEnd: model.capture.end)
            if model.motion.status != .streaming {
                Label(model.motion.status.label, systemImage: "airpodspro")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var takes: some View {
        let groups = Dictionary(grouping: model.dataset.templates, by: \.readingID)
        VStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty { Text("No recorded takes yet.").foregroundStyle(.secondary) }
            ForEach(groups.compactMap { $0.key }.sorted {
                (groups[$0]?.first?.createdAt ?? .distantPast) > (groups[$1]?.first?.createdAt ?? .distantPast)
            }, id: \.self) { id in
                if let takes = groups[id], let first = takes.first {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(takes.prefix(8).map(\.label).joined(separator: " ")).lineLimit(1)
                            Text("\(first.createdAt.formatted()) · \(takes.count) takes").font(.caption)
                        }
                        Spacer()
                        Button("Delete reading", role: .destructive) { model.deleteReading(id) }
                    }
                }
            }
            if let individual = groups[nil] {
                DisclosureGroup("Individual and earlier takes (\(individual.count))") {
                    ForEach(individual.reversed()) { take in
                        HStack {
                            Text(take.label)
                            Text(take.createdAt.formatted()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Delete", role: .destructive) { model.deleteTemplate(take.id) }
                        }
                    }
                }
            }
        }
    }

    private func addWord() {
        model.addWord(newWord)
        newWord = ""
    }
}

private struct PassagePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var passage = model.passage
        let count = PassageAlignment.words(in: passage.text).count
        VStack(alignment: .leading, spacing: 10) {
            if passage.running {
                ReadingTranscript(passage: passage)
                HStack {
                    Stepper(String(format: "%.1f seconds per word", passage.secondsPerWord),
                            value: $passage.secondsPerWord, in: 0.8...4, step: 0.2)
                    Spacer()
                    Button("Stop reading") { passage.stop() }
                }
            } else {
                Text("Passage training").font(.title2.bold())
                Text("Mouth the highlighted word, then relax. Space pauses; Esc stops training.")
                    .foregroundStyle(.secondary)
                GroupBox("Passage") {
                VStack(alignment: .leading, spacing: 12) {
                Menu(PassageAlignment.readings.first { $0.text == passage.text }?.title ?? "Custom passage") {
                    ForEach(PassageAlignment.readings, id: \.title) { reading in
                        Button(reading.title) { passage.text = reading.text }
                    }
                }
                TextEditor(text: $passage.text).font(.body).frame(minHeight: 64)
                    .border(.secondary.opacity(0.3))
                Text("\(count) words · up to 150 per passage").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
                }
                GroupBox("Pace & continuation") {
                VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Stepper("\(passage.repetitions) readings", value: $passage.repetitions, in: 1...10)
                    Stepper(String(format: "%.1f seconds per word", passage.secondsPerWord), value: $passage.secondsPerWord, in: 0.8...4, step: 0.2)
                }
                Toggle("Automatically continue training sessions", isOn: $passage.autoContinue)
                Text(passage.autoContinue ? "Continue to the next reading or session after a 5-second countdown." : "Press Enter between every reading and session. No countdown in manual mode.")
                    .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
                }
                Button("Start passage") { model.startPassage() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.motion.status != .streaming || !(1...150).contains(count))
                if !(1...150).contains(count) {
                    Text("Enter between 1 and 150 words.").foregroundStyle(.secondary)
                }
                if model.motion.status != .streaming { Text(model.motion.status.label).foregroundStyle(.orange) }
            }
            TrainingResultsView(passage: passage)
        }
        .onDisappear { passage.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in passage.stop() }
        .onChange(of: model.motion.status) { _, status in
            if status != .streaming { passage.stop() }
        }
    }
}

struct TrainingResultsView: View {
    let passage: PassageTrainer

    private var words: [String] {
        Set(passage.savedByWord.keys).union(passage.skippedByWord.keys).sorted()
    }

    var body: some View {
        if !words.isEmpty || passage.stoppedEarly || passage.failureMessage != nil {
            GroupBox("Training results") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 24) {
                        Label("\(passage.savedByWord.values.reduce(0, +)) saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Label("\(passage.skippedByWord.values.reduce(0, +)) skipped", systemImage: "minus.circle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Text("\(passage.completedReadings) / \(passage.plannedReadings) readings")
                    }.font(.callout.bold())
                    if !words.isEmpty {
                        ScrollView {
                            Chart(words, id: \.self) { word in
                                BarMark(x: .value("Takes", passage.savedByWord[word, default: 0]), y: .value("Word", word))
                                    .foregroundStyle(by: .value("Result", "Saved"))
                                BarMark(x: .value("Takes", passage.skippedByWord[word, default: 0]), y: .value("Word", word))
                                    .foregroundStyle(by: .value("Result", "Skipped"))
                            }
                            .chartForegroundStyleScale(["Saved": Color.green, "Skipped": Color.orange])
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
                            .frame(height: CGFloat(max(100, words.count * 24)))
                            .padding(.trailing, 12)
                        }.frame(height: CGFloat(min(200, max(120, words.count * 24 + 40))))
                    }
                    if passage.stoppedEarly {
                        Label("Stopped before the current reading finished.", systemImage: "stop.circle.fill")
                            .font(.headline).foregroundStyle(.red)
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.red.opacity(0.3)))
                    }
                    if let message = passage.failureMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }.padding(8)
            }
        }
    }
}

private struct CalibrationMovementView: View {
    let sample: MotionSample?
    var duringTraining = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !duringTraining {
            Text("Keep both bars in the green zone")
                .font(.headline).foregroundStyle(.primary)
            }
            if let sample {
                let acceleration = PassageAlignment.acceleration(sample)
                let rotation = PassageAlignment.rotation(sample)
                if duringTraining {
                    HStack(spacing: 20) {
                        movementBar("Acceleration", value: acceleration, limit: PassageAlignment.stillAccelerationLimit, units: "g")
                        movementBar("Head rotation", value: rotation, limit: PassageAlignment.stillRotationLimit, units: "rad/s")
                    }
                } else {
                movementBar("Acceleration", value: acceleration, limit: PassageAlignment.stillAccelerationLimit,
                            units: "g")
                movementBar("Head rotation", value: rotation, limit: PassageAlignment.stillRotationLimit,
                            units: "rad/s")
                }
            } else {
                Text("Waiting for headphone motion…").foregroundStyle(.secondary)
            }
            if !duringTraining {
            Text("Relax your jaw and rest your head. The 2-second measurement checks your overall movement.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: 500)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    private func movementBar(_ title: String, value: Double, limit: Double, units: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.3f %@", value, units)).monospacedDigit()
                    .foregroundStyle(value <= limit ? .green : .orange)
            }
            LevelMeter(value: value / (limit * 3), marker: 1.0 / 3,
                       tint: value <= limit ? .green : .orange)
            Text(String(format: "Resting target: below %.3f %@", limit, units))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct TrainingLiveStatsView: View {
    let passage: PassageTrainer

    var body: some View {
        HStack(alignment: .center, spacing: 32) {
            total(passage.savedByWord.values.reduce(0, +), title: "Saved", icon: "checkmark.circle.fill", color: .green)
            total(passage.skippedByWord.values.reduce(0, +), title: "Skipped", icon: "minus.circle.fill", color: .orange)
            Divider().frame(height: 72)
            VStack(alignment: .leading, spacing: 8) {
                Text(passage.lastWordOutcome == nil ? "Live results" : passage.lastFinishedWord)
                    .font(.title2.bold()).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.6)
                if let outcome = passage.lastWordOutcome {
                    Label(outcome == .saved ? "Saved" : "Skipped",
                          systemImage: outcome == .saved ? "checkmark.circle.fill" : "minus.circle.fill")
                        .font(.title3.bold())
                        .foregroundStyle(outcome == .saved ? Color.green : Color.orange)
                } else {
                    Text("Waiting for first word").font(.callout).foregroundStyle(.secondary)
                }
            }.frame(width: 190, alignment: .leading)
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
    }

    private func total(_ count: Int, title: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(count.formatted()).font(.system(size: 56, weight: .semibold, design: .rounded)).monospacedDigit()
            Label(title, systemImage: icon).font(.title3.bold())
        }.foregroundStyle(color)
    }
}

/// Covers navigation and settings while keeping the training controls mounted underneath.
struct TrainingFocusView: View {
    @Environment(AppModel.self) private var model
    @State private var skippedFlash = false

    var body: some View {
        let passage = model.passage
        let timed = passage.running
        GeometryReader { geometry in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if timed && !passage.paused && !passage.isPreparingWord && passage.cueIndex != nil {
                    TimelineView(.animation) { _ in
                        let elapsed = ProcessInfo.processInfo.systemUptime - passage.wordStartedAt
                        let progress = min(1, max(0, elapsed / passage.wordDuration))
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: geometry.size.width * progress)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                Color.orange.opacity(skippedFlash ? 0.3 : 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .animation(.easeOut(duration: 0.2), value: skippedFlash)
                VStack(spacing: 8) {
                    if timed && !passage.awaitingNextSession && passage.cueIndex != nil {
                        HStack {
                            Spacer()
                            CalibrationMovementView(sample: model.motion.latest, duringTraining: true)
                                .frame(width: 480)
                        }
                    }
                VStack(spacing: 20) {
                    if passage.awaitingNextSession {
                        Spacer()
                        Text(passage.running ? "Reading complete" : "Session complete").font(.largeTitle.bold()).foregroundStyle(.primary)
                        TrainingResultsView(passage: passage).frame(maxWidth: 700)
                        HStack {
                            Button("←") { model.cycleTrainingSelection(-1) }
                                .accessibilityLabel(passage.isSingleWordSession ? "Previous word" : "Previous passage")
                            Text(passage.sessionTitle)
                                .font(.title2).foregroundStyle(.primary)
                            Button("→") { model.cycleTrainingSelection(1) }
                                .accessibilityLabel(passage.isSingleWordSession ? "Next word" : "Next passage")
                        }
                        Text(passage.sessionPreview).multilineTextAlignment(.center).lineLimit(4).frame(maxWidth: 700)
                        if let remaining = passage.nextSessionCountdown {
                            Text("Continuing in \(remaining)")
                                .font(.system(size: 44, weight: .semibold, design: .rounded))
                                .foregroundStyle(.primary)
                        }
                        Button(passage.running ? "Press Enter for next reading" : "Press Enter to start next session") { passage.startNextSession(save: model.savePassage) }
                            .disabled(model.motion.status != .streaming)
                        Text(passage.isSingleWordSession ? "← / → choose word · Esc ends training" : "← / → choose passage · Esc ends training")
                        if model.motion.status != .streaming {
                            Text("Reconnect your headphones to continue.")
                        }
                        Button("Stop training") { passage.stop() }
                        Spacer()
                        Color.clear.frame(height: 0)
                            .task(id: passage.sessionPreview) {
                                guard model.motion.status == .streaming else { return }
                                await passage.autoContinueNext(save: model.savePassage)
                            }
                    } else {
                    VStack(spacing: 16) {
                    Spacer()
                    VStack(spacing: 4) {
                    if timed && passage.cueIndex != nil {
                        Label(passage.paused ? "Paused" : passage.isPreparingWord ? "Wait — stay still" : "Mouth it now",
                              systemImage: passage.paused || passage.isPreparingWord ? "hand.raised.fill" : "play.circle.fill")
                            .font(.title3.bold())
                            .foregroundStyle(passage.paused || passage.isPreparingWord ? Color.orange : Color.green)
                            .padding(.horizontal, 18).padding(.vertical, 8)
                            .background(.background, in: Capsule())
                            TimelineView(.animation) { _ in
                                let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - passage.preparationStartedAt) / PassageTrainer.wordPreparationSeconds))
                                GeometryReader { bar in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.orange.opacity(0.15))
                                        Capsule().fill(.orange).frame(width: bar.size.width * progress)
                                    }
                                }
                                .transaction { $0.animation = nil }
                            }
                            .frame(width: 160, height: 6).padding(.bottom, 8)
                            .opacity(passage.isPreparingWord && !passage.paused ? 1 : 0)

                    }
                    Text(timed ? (passage.paused ? "Paused" : passage.countdown.map(String.init) ?? passage.cue) : (model.selectedWord ?? "Mouth a word"))
                        .font(.system(size: min(140, geometry.size.width * 0.16, geometry.size.height * 0.16), weight: .semibold, design: .rounded))
                        .foregroundStyle(.blue)
                        .opacity(passage.isPreparingWord ? 0.4 : 1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 40)
                    if timed && passage.countdown != nil {
                        Text("Get ready to hold still").font(.title2).foregroundStyle(.primary)
                    }
                    if timed && passage.cueIndex == nil {
                        CalibrationMovementView(sample: model.motion.latest)
                        if let warning = passage.calibrationWarning {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).multilineTextAlignment(.center)
                                .frame(maxWidth: 550)
                            Button("Press Enter to redo still measurement") { passage.retryCalibration() }
                                .buttonStyle(.borderedProminent)
                        } else if passage.isMeasuringStillness && !passage.paused {
                            TimelineView(.animation) { _ in
                                ProgressView(value: min(1, max(0, (ProcessInfo.processInfo.systemUptime - passage.wordStartedAt) / passage.wordDuration)))
                            }.frame(maxWidth: 500)
                        }
                    }
                    if timed && passage.countdown == nil, let next = passage.nextWord {
                        Text(next)
                            .font(.system(size: 40, weight: .medium, design: .rounded)).foregroundStyle(.secondary)
                    }
                    }
                    if timed && passage.cueIndex != nil {
                        TrainingLiveStatsView(passage: passage)
                    }
                    Spacer(minLength: 8)
                    if timed {
                        ProgressView(value: Double(passage.completedWords), total: Double(max(1, passage.queuedWords.count)))
                            .frame(maxWidth: 600)
                            .accessibilityLabel("Passage progress")
                        Text("\(passage.completedWords) / \(passage.queuedWords.count) words complete")
                        if passage.paused {
                            Text("Resume at “\(passage.cue)”")
                        }
                        Text(passage.detail)
                        Text(String(format: "%.1f seconds per word · ↑ faster · ↓ slower", passage.secondsPerWord))
                        if !passage.awaitingCalibrationRetry {
                        Text(passage.paused ? "Space to resume · current word restarts" : "Space to pause")
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(.background, in: Capsule())
                            .overlay(Capsule().strokeBorder(.primary.opacity(0.2)))
                        }
                        Button("Stop reading") { passage.stop() }
                            .keyboardShortcut(.escape, modifiers: [])
                    } else {
                        Text("Release Space or the capture button to finish")
                        Button("Stop recording") { model.capture.end() }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
                .padding(.horizontal, 24)
                }
                .padding(.horizontal, 16)
            }
            .task(id: passage.skippedByWord.values.reduce(0, +)) {
                guard !passage.skippedByWord.isEmpty else { skippedFlash = false; return }
                skippedFlash = true
                do { try await Task.sleep(for: .milliseconds(700)) }
                catch { return }
                skippedFlash = false
            }
        }
    }
}

struct ReadingTranscript: View {
    let passage: PassageTrainer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(passage.detail).font(.headline.monospacedDigit())
            Text(String(format: "%.1f seconds per word · ↑ faster · ↓ slower", passage.secondsPerWord))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            if passage.cueIndex == nil { Text(passage.cue).font(.title.bold()) }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(stride(from: 0, to: passage.queuedWords.count, by: 8)), id: \.self) { start in
                            (start..<min(start + 8, passage.queuedWords.count)).reduce(Text("")) { line, i in
                                let current = passage.cueIndex
                                return line + Text(passage.queuedWords[i] + " ")
                                    .font(i == current ? .largeTitle.bold() : .title3)
                                    .foregroundColor(i < (current ?? 0) ? .gray : .primary)
                            }.id(start)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: passage.cueIndex) { _, index in
                    if let index { proxy.scrollTo(index / 8 * 8, anchor: .center) }
                }
            }.frame(height: 200)
        }.padding().background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
