import AVFoundation
import CoreAudio
import Foundation
import Speech

final class SpeechTranscriber: NSObject {
    var onFinalText: ((String) -> Void)?
    var onStatusUpdate: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var onRecordingStateChange: ((Bool) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionEngine: SFSpeechRecognizer?
    private var pendingFinalizeWorkItem: DispatchWorkItem?

    private var granted = false
    private(set) var isRecording: Bool = false
    private var isStopping: Bool = false
    private var committedTranscript = ""
    private var liveTranscript = ""
    private var bestTranscriptInCurrentSegment = ""
    private var previousDefaultInputDevice: AudioDeviceID?

    private var autoDetectMicrophone = true
    private var selectedMicrophoneUID = ""
    private var enableContextualBias = true
    private var keepTextAcrossPauses = true
    private var preferOnDeviceRecognition = true
    private var finalizeDelaySeconds: TimeInterval = 0.35
    private var customContextPhrases: [String] = []

    override init() {
        let locale = Locale.current
        self.recognitionEngine = SFSpeechRecognizer(locale: locale)
        super.init()
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            switch status {
            case .authorized:
                self?.requestedAudioPermission()
            default:
                self?.update("Speech permission not granted")
            }
        }
    }

    func applyMicrophoneSettings(autoDetect: Bool, microphoneUID: String) {
        autoDetectMicrophone = autoDetect
        selectedMicrophoneUID = microphoneUID
    }

    func applyRecognitionSettings(
        enableContextualBias: Bool,
        keepTextAcrossPauses: Bool,
        preferOnDeviceRecognition: Bool,
        finalizeDelaySeconds: TimeInterval,
        customContextPhrases: String
    ) {
        self.enableContextualBias = enableContextualBias
        self.keepTextAcrossPauses = keepTextAcrossPauses
        self.preferOnDeviceRecognition = preferOnDeviceRecognition
        self.finalizeDelaySeconds = min(1.2, max(0.15, finalizeDelaySeconds))
        self.customContextPhrases = parseCustomPhrases(customContextPhrases)
    }

    private func requestedAudioPermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            if granted {
                self?.granted = true
                self?.update("Permissions ready")
            } else {
                self?.update("Microphone permission not granted")
            }
        }
    }

    private func update(_ message: String) {
        DispatchQueue.main.async {
            self.onStatusUpdate?(message)
        }
    }

    @discardableResult
    func startRecording() -> Bool {
        guard granted else {
            update("Permissions missing")
            return false
        }

        guard !isRecording && !isStopping else { return false }
        guard let recognitionEngine else {
            update("No speech recognizer for locale")
            return false
        }
        guard recognitionEngine.isAvailable else {
            update("Speech recognizer unavailable")
            return false
        }

        applyMicSelection()

        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil
        isStopping = false

        committedTranscript = ""
        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
        isRecording = true
        onRecordingStateChange?(true)

        guard startRecognitionTask() else {
            isRecording = false
            onRecordingStateChange?(false)
            return false
        }

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            let audioLevel = self.normalizedAudioLevel(from: buffer)
            DispatchQueue.main.async {
                self.onAudioLevel?(audioLevel)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            update("Listening…")
            return true
        } catch {
            update("Audio setup failed: \(error.localizedDescription)")
            stopRecording(emitFinalText: false)
            return false
        }
    }

    func stopRecording(emitFinalText: Bool = true) {
        guard isRecording || isStopping else {
            onAudioLevel?(0)
            onRecordingStateChange?(false)
            return
        }

        if isRecording {
            isRecording = false
            isStopping = true
            onRecordingStateChange?(false)

            recognitionRequest?.endAudio()

            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            onAudioLevel?(0)
        }

        pendingFinalizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.finalizeStop(emitFinalText: emitFinalText)
        }
        pendingFinalizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + finalizeDelaySeconds, execute: workItem)
    }

    private func finalizeStop(emitFinalText: Bool) {
        pendingFinalizeWorkItem = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        restoreMicSelection()

        let text = mergedTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        committedTranscript = ""
        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
        isStopping = false

        update("Ready")

        if emitFinalText && !text.isEmpty {
            onFinalText?(text)
        }
    }

    private func startRecognitionTask() -> Bool {
        guard let recognitionEngine else {
            update("No speech recognizer for locale")
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = preferOnDeviceRecognition
        }
        request.taskHint = .dictation
        if enableContextualBias {
            var hints = [
                "KeyScribe",
                "OpenClaw",
                "dictation",
                "transcription",
                "macOS"
            ]
            hints.append(contentsOf: customContextPhrases)
            request.contextualStrings = Array(Set(hints)).prefix(80).map { $0 }
        }

        bestTranscriptInCurrentSegment = ""

        recognitionRequest = request
        recognitionTask = recognitionEngine.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            guard self.isRecording || self.isStopping else { return }

            if let error {
                let nsError = error as NSError
                // Ignore expected cancellation noise when we stop/restart the task intentionally.
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    return
                }
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    return
                }

                self.update("Error: \(error.localizedDescription)")
                self.stopRecording(emitFinalText: false)
                return
            }

            guard let result else { return }
            let candidate = result.bestTranscription.formattedString
            self.liveTranscript = candidate

            if self.keepTextAcrossPauses {
                self.updateBestTranscriptForCurrentSegment(with: candidate)
            }

            if result.isFinal {
                if self.keepTextAcrossPauses {
                    self.commitBestSegmentTranscript()
                } else {
                    self.commitLiveTranscript()
                }

                if self.isRecording {
                    _ = self.startRecognitionTask()
                }
            }
        }

        return true
    }

    private func updateBestTranscriptForCurrentSegment(with candidate: String) {
        let candidateText = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingText = bestTranscriptInCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !candidateText.isEmpty else { return }

        if scoreTranscript(candidateText) >= scoreTranscript(existingText) {
            bestTranscriptInCurrentSegment = candidateText
        }
    }

    private func scoreTranscript(_ text: String) -> Int {
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        return words * 100 + text.count
    }

    private func commitBestSegmentTranscript() {
        let fallback = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let best = bestTranscriptInCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        let chunk = scoreTranscript(best) >= scoreTranscript(fallback) ? best : fallback

        guard !chunk.isEmpty else {
            liveTranscript = ""
            bestTranscriptInCurrentSegment = ""
            return
        }

        if committedTranscript.isEmpty {
            committedTranscript = chunk
        } else {
            committedTranscript += " " + chunk
        }

        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
    }

    private func commitLiveTranscript() {
        let chunk = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chunk.isEmpty else { return }

        if committedTranscript.isEmpty {
            committedTranscript = chunk
        } else {
            committedTranscript += " " + chunk
        }
        liveTranscript = ""
        bestTranscriptInCurrentSegment = ""
    }

    private func mergedTranscript() -> String {
        let current = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let best = bestTranscriptInCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = scoreTranscript(best) >= scoreTranscript(current) ? best : current

        if committedTranscript.isEmpty { return tail }
        if tail.isEmpty { return committedTranscript }
        return committedTranscript + " " + tail
    }

    private func parseCustomPhrases(_ text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func applyMicSelection() {
        guard !autoDetectMicrophone else {
            previousDefaultInputDevice = nil
            return
        }

        guard !selectedMicrophoneUID.isEmpty else {
            previousDefaultInputDevice = nil
            return
        }

        guard let selectedDeviceID = MicrophoneManager.deviceID(forUID: selectedMicrophoneUID) else {
            update("Selected microphone no longer available")
            previousDefaultInputDevice = nil
            return
        }

        guard let currentDefault = MicrophoneManager.defaultInputDeviceID() else {
            update("Unable to read default microphone")
            previousDefaultInputDevice = nil
            return
        }

        if currentDefault == selectedDeviceID {
            previousDefaultInputDevice = nil
            return
        }

        let changed = MicrophoneManager.setDefaultInput(deviceID: selectedDeviceID)
        if changed {
            previousDefaultInputDevice = currentDefault
        } else {
            update("Could not switch microphone")
            previousDefaultInputDevice = nil
        }
    }

    private func restoreMicSelection() {
        guard let previous = previousDefaultInputDevice else { return }
        _ = MicrophoneManager.setDefaultInput(deviceID: previous)
        previousDefaultInputDevice = nil
    }

    private func normalizedAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else {
            return 0
        }

        let channelSamples = channelData.pointee
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<frameCount {
            let sample = channelSamples[i]
            sum += sample * sample
        }

        let meanSquare = sum / Float(frameCount)
        let rms = sqrtf(max(meanSquare, 1e-12))
        let db = 20 * log10f(rms)
        let normalized = (db + 70) / 70
        return max(0, min(1, normalized))
    }
}
