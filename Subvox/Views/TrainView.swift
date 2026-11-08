import SwiftUI

struct TrainView: View {
    @Environment(AppModel.self) private var model
    @State private var newWord = ""

    var body: some View {
        @Bindable var model = model
        HSplitView {
            vocabulary
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Training mode", selection: $model.passageMode) {
                        Text("Passage").tag(true)
                        Text("Single word").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.capture.isCapturing || model.passage.running)
                    if model.passageMode { PassagePanel() } else { capturePanel }
                    takes
                    EvaluationPanel()
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
                Section("Vocabulary") {
                    ForEach(model.dataset.vocabulary, id: \.self) { word in
                        HStack {
                            Text(word)
                            Spacer()
                            Text("\(model.templates(for: word).count)")
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
        if let word = model.selectedWord {
            let takes = model.templates(for: word).reversed()
            GroupBox("Takes for “\(word)” (\(takes.count))") {
                if takes.isEmpty {
                    Text("No takes yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        ForEach(Array(takes)) { take in
                            TakeTile(template: take, isNew: take.id == model.lastTemplateID) {
                                model.deleteTemplate(take.id)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private func addWord() {
        model.addWord(newWord)
        newWord = ""
    }
}

private struct TakeTile: View {
    var template: Template
    var isNew: Bool
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SignalPlot(title: "", samples: template.samples, channels: SignalPlot.rotation,
                       minScale: 0.05, height: 44, showsHeader: false)
            HStack {
                Text(String(format: "%.2f s · %d", template.duration, template.samples.count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(isNew ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

private struct EvaluationPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GroupBox("Is there signal? (leave-one-out + permutation test)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Features:")
                    FeatureToggle(title: "Acceleration", option: .acceleration)
                    FeatureToggle(title: "Rotation", option: .rotation)
                    FeatureToggle(title: "Attitude", option: .attitude)
                    Spacer()
                    Button(model.isEvaluating ? "Evaluating…" : "Evaluate") { model.evaluate() }
                        .disabled(model.isEvaluating || model.featureSet.isEmpty)
                }
                if let result = model.evaluation {
                    EvaluationResultView(result: result)
                } else {
                    Text("Needs ≥ 2 words with ≥ 2 takes each. Each take is classified against all the others; the same is repeated with shuffled labels to show what chance looks like.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }
}

private struct FeatureToggle: View {
    @Environment(AppModel.self) private var model
    var title: String
    var option: FeatureSet

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { model.featureSet.contains(option) },
            set: { on in
                if on { model.featureSet.insert(option) } else { model.featureSet.remove(option) }
            }))
        .toggleStyle(.checkbox)
    }
}

private struct EvaluationResultView: View {
    var result: Evaluation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                metric("Accuracy", percent(result.accuracy), highlight: true)
                metric("Chance", percent(result.chance))
                metric("Shuffled 95th pct", percent(result.permutationP95))
                metric("p-value", result.pValue < 0.001 ? "< 0.001" : String(format: "%.3f", result.pValue))
            }
            Text(verdict)
                .font(.callout)
                .foregroundStyle(result.pValue < 0.05 ? .green : .orange)

            ScrollView(.horizontal) {
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    Text("actual ↓ / predicted →").font(.caption2).foregroundStyle(.secondary)
                    ForEach(result.labels, id: \.self) { Text($0).font(.caption2).lineLimit(1) }
                }
                ForEach(result.labels.indices, id: \.self) { row in
                    let total = max(result.confusion[row].reduce(0, +), 1)
                    GridRow {
                        Text(result.labels[row]).font(.caption2).gridColumnAlignment(.trailing)
                        ForEach(result.labels.indices, id: \.self) { col in
                            let count = result.confusion[row][col]
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 36, minHeight: 24)
                                .background((row == col ? Color.green : Color.red)
                                    .opacity(Double(count) / Double(total) * 0.7))
                        }
                    }
                }
            }
            }
        }
    }

    private var verdict: String {
        if result.pValue < 0.05 {
            "Motion carries word information beyond chance across \(result.templateCount) takes."
        } else {
            "Not distinguishable from chance yet — record more takes or try other feature sets."
        }
    }

    private func metric(_ title: String, _ value: String, highlight: Bool = false) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(highlight ? .title2.bold().monospacedDigit() : .title3.monospacedDigit())
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }
}

private struct PassagePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var passage = model.passage
        let count = PassageAlignment.words(in: passage.text).count
        VStack(alignment: .leading, spacing: 10) {
            if passage.running {
                Text(passage.detail).foregroundStyle(.secondary)
                Text(passage.cue).font(.system(size: 48, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 90)
                if let current = passage.cueIndex {
                    let words = PassageAlignment.words(in: passage.text)
                    Text(words.dropFirst(current + 1).prefix(7).joined(separator: " "))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Upcoming words")
                }
                Button("Stop reading") { passage.stop() }
            } else {
                Text("Mouth each word once when it appears, then relax until the next cue. Keep your head still.")
                Menu(PassageAlignment.readings.first { $0.text == passage.text }?.title ?? "Custom passage") {
                    ForEach(PassageAlignment.readings, id: \.title) { reading in
                        Button(reading.title) { passage.text = reading.text }
                    }
                }
                TextEditor(text: $passage.text).font(.body).frame(minHeight: 64)
                    .border(.secondary.opacity(0.3))
                HStack {
                    if !passage.testReading {
                        Stepper("\(passage.repetitions) readings", value: $passage.repetitions, in: 1...10)
                    }
                    Picker("Pace", selection: $passage.secondsPerWord) {
                        Text("1.2 s / word").tag(1.2)
                        Text("1.6 s / word").tag(1.6)
                        Text("2.2 s / word").tag(2.2)
                    }.fixedSize()
                }
                Toggle("Test a fresh reading without adding training data", isOn: $passage.testReading)
                if passage.testReading && model.classifier == nil {
                    Text("Train at least two words and select a feature channel to test a reading.")
                }
                Button(passage.testReading ? "Start test reading" : "Start passage") { model.startPassage() }
                    .disabled(model.motion.status != .streaming || !(1...150).contains(count) || (passage.testReading && model.classifier == nil))
                if !(1...150).contains(count) {
                    Text("Enter between 1 and 150 words.").foregroundStyle(.secondary)
                }
                if model.motion.status != .streaming { Text(model.motion.status.label).foregroundStyle(.orange) }
            }
            if !passage.report.isEmpty { Text(passage.report).font(.callout) }
        }
        .onDisappear { passage.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in passage.stop() }
        .onChange(of: model.motion.status) { _, status in
            if status != .streaming { passage.stop() }
        }
    }
}
