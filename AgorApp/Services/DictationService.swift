import AVFoundation
import Foundation

/// Push-to-talk dictation: record while the mic button is held, transcribe once
/// on release, hand the text back to the caller.
///
/// Deliberately NOT built on ContinuousVoiceService — there is no VAD, no
/// silence detection, no TTS and no turn-taking here. The hold *is* the
/// endpointing: everything between press and release is one utterance.
@Observable
final class DictationService {
    static let shared = DictationService()

    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var fileURL: URL?
    @ObservationIgnored private var toneEngine: AVAudioEngine?

    var isRecording: Bool { state == .recording }

    // MARK: - Recording

    /// Begin recording. Returns false if the mic is unavailable or permission is
    /// denied, so the caller can skip the release handling.
    @discardableResult
    func start() async -> Bool {
        guard state == .idle else { return false }
        guard await Self.hasMicPermission() else {
            AppLogger.shared.log("[Dictation] microphone permission denied", level: .warning, category: "Voice")
            return false
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            AppLogger.shared.log("[Dictation] audio session failed: \(error.localizedDescription)", level: .error, category: "Voice")
            return false
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                AppLogger.shared.log("[Dictation] recorder refused to start", level: .error, category: "Voice")
                return false
            }
            self.recorder = recorder
            self.fileURL = url
            state = .recording
            // Audible "recording started" cue — the button is under the user's
            // thumb, so the visual state change alone is easy to miss.
            playTone(frequency: 880, duration: 0.09)
            AppLogger.shared.log("[Dictation] 🔴 recording started", level: .info, category: "Voice")
            return true
        } catch {
            AppLogger.shared.log("[Dictation] recorder failed: \(error.localizedDescription)", level: .error, category: "Voice")
            return false
        }
    }

    /// Stop recording and transcribe. Returns the recognized text, or nil if
    /// nothing usable was captured.
    func stopAndTranscribe() async -> String? {
        guard state == .recording else { return nil }
        recorder?.stop()
        recorder = nil
        guard let url = fileURL else {
            state = .idle
            return nil
        }
        fileURL = nil

        state = .transcribing
        playTone(frequency: 660, duration: 0.07)
        defer {
            state = .idle
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let raw = try await TranscriptionService.shared.transcribe(audioURL: url)
            // Whisper emits bracketed markers like [BLANK_AUDIO] for non-speech.
            let text = raw
                .replacingOccurrences(of: "\\[[A-Z_]+\\]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                AppLogger.shared.log("[Dictation] empty transcription", level: .warning, category: "Voice")
                return nil
            }
            AppLogger.shared.log("[Dictation] ✅ \"\(text)\"", level: .info, category: "Voice")
            return text
        } catch {
            AppLogger.shared.log("[Dictation] transcription failed: \(error.localizedDescription)", level: .error, category: "Voice")
            return nil
        }
    }

    /// Abandon the recording without transcribing.
    func cancel() {
        guard state == .recording else { return }
        recorder?.stop()
        recorder = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        state = .idle
        AppLogger.shared.log("[Dictation] cancelled", level: .info, category: "Voice")
    }

    // MARK: - Helpers

    private static func hasMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied: return false
            default: return await AVAudioApplication.requestRecordPermission()
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted: return true
            case .denied: return false
            default:
                return await withCheckedContinuation { continuation in
                    session.requestRecordPermission { continuation.resume(returning: $0) }
                }
            }
        }
    }

    /// Short sine tone through AVAudioEngine — routed on the media path so it is
    /// audible at the same level as speech, and works while .playAndRecord is active
    /// (AudioServicesPlaySystemSound uses the quieter ringer path).
    private func playTone(frequency: Float, duration: Double, amplitude: Float = 0.7) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        let sampleRate: Double = 44100
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sampleRate)
            let envelope = 1.0 - (t / Float(duration))  // fade-out avoids a click
            data[i] = sin(2.0 * .pi * frequency * t) * amplitude * envelope
        }

        do {
            try engine.start()
        } catch {
            return
        }
        toneEngine = engine
        player.scheduleBuffer(buffer, completionHandler: nil)
        player.play()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.15) { [weak self] in
            self?.toneEngine?.stop()
            self?.toneEngine = nil
        }
    }
}
