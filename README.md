# Subvox

A macOS prototype that tests whether AirPods Pro head-motion data (`CMHeadphoneMotionManager`) carries enough information to turn **silently mouthed words into text**.

It doesn't use a language model. It's a small-vocabulary template recognizer plus a statistical test that tells you whether the signal is real.

## Build & run

```sh
brew install xcodegen   # once
xcodegen generate
open Subvox.xcodeproj   # ⌘R
```

Or from the command line:

```sh
xcodebuild -project Subvox.xcodeproj -scheme Subvox -derivedDataPath build build
open build/Build/Products/Debug/Subvox.app
xcodebuild -project Subvox.xcodeproj -scheme Subvox -derivedDataPath build test
```

Requires macOS 14+, AirPods Pro or another headphone that supports head tracking, connected as the Mac's audio output. On first launch, grant **Motion**. The mic and speech prompts only appear when you start the mic.

The project uses local ad-hoc signing. You can copy the built Subvox.app into your Applications folder and open it from Finder.

## Passage training

In **Train → Passage**, choose one of eight academic readings, select everyday commands, or paste up to 150 words from your own course material. Click **Start passage** once. Hold still during the two-second calibration, then silently mouth each cue once and relax before the next. A slower pace gives longer terms more room. Each completed reading adds the accepted word motions to the same training set used by Decode. The summary lists missed words. Stopping discards the unfinished reading.

The app timestamps the displayed prompts and checks for motion above your resting level inside each interval. It skips quiet, clipped, and interrupted intervals. A skipped prompt cannot shift subsequent labels. The label comes from the cue, so moving your head or mouthing a different word can still produce a mislabeled take.

For a practical accuracy check, reseat the headphones and choose **Decode → Start scored reading**. This scores new takes against the existing classifier and leaves them out of training. The denominator includes every prompt, including weak captures and decoder rejections. Single Word ranks terms by combined held-out training results and scored Decode attempts. Words without evidence appear last. Recorded takes are grouped by reading, with older and manual takes available individually. Exact word forms need their own examples.

The academic passages are original topic-based prompts. For choosing additional words across subjects, see [Coxhead’s Academic Word List](https://www.wgtn.ac.nz/lals/resources/academicwordlist). The target-word approach follows the limited-vocabulary task design discussed in [Speech Commands](https://arxiv.org/abs/1804.03209). Accuracy on AirPods motion needs to be measured on your own recordings.

## Screens

| Screen | What it does |
|---|---|
| **Sensors** | Live plots of user acceleration, rotation rate and attitude, the measured sample rate, a mic input picker and level meter, and a recorder for experiment sessions. |
| **Train** | Pick a word, hold **Space**, mouth it, release. Each take is stored as a template. **Evaluate** runs leave-one-out classification and a 500× label-permutation test, then shows accuracy against chance, a p-value and a confusion matrix. The feature checkboxes (acceleration / rotation / attitude) let you test which channels carry the signal. |
| **Decode** | The motion-to-text screen. Hold Space, or use auto-detect after calibrating the noise floor. Each segment is DTW-matched against your templates and added to the transcript. A live mic transcript runs alongside it for comparison. |

## How decoding works

1. **Segmentation** (`CaptureController`). Space-hold, or an energy trigger above a calibrated noise floor with pre-roll and hangover.
2. **Features** (`MotionFeatures`). Per frame: user acceleration (3), rotation rate (3), and attitude change since the start of the segment (3). Each channel is mean-centered, and quiet lead-in and lead-out frames are trimmed.
3. **Matching** (`DTW`, `TemplateClassifier`). Each channel is z-scaled across the training set. Matching is 1-nearest-neighbour per word, using dynamic time warping with a Sakoe–Chiba band. A segment is rejected if the best distance is above *max distance* or the margin to the runner-up is below *min confidence*.
4. **Is it real?** (`Evaluation`). The leave-one-out accuracy is compared with the same procedure run on shuffled labels. If p < 0.05, the motion stream distinguishes your words better than chance.

## Experiment protocol

Use **Record Session** in the toolbar or on the Sensors screen. Recordings go to `~/Documents/Subvox/Sessions/<timestamp>-<condition>/`:

- `motion.csv`: every motion sample. `t` is seconds from session start.
- `audio.caf`: microphone audio, if the mic is running.
- `events.csv`: every Space-held segment, with its label or prediction.
- `meta.json`: condition, prompt, and the audio start offset for aligning audio with motion.

Suggested runs: the same 5-word script under **Normal speech**, **Whisper** and **Silent mouthing**, 10 reps each. Then, in Train, compare the Evaluate results across feature sets.

The training set lives at `~/Library/Application Support/Subvox/dataset.json`.

## Known limits

- Headphone motion is processed and low-rate (roughly 25 Hz on AirPods). The speech-detecting accelerometer and the inward mic are not exposed. Expect jaw and head movement, not vocal vibration.
- Templates are user- and session-specific. Re-seating the AirPods can shift the signal.
- Choosing AirPods as the mic input switches them to the Bluetooth headset (HFP) profile.
