import Foundation

/// Tunable constants for VoiceActivityDetector (FluidAudio Silero VAD backend).
/// Codable so the struct can be saved/loaded as JSON via UserDefaults.
struct VADConfig: Codable, Equatable {

    // MARK: - Detection threshold

    /// FluidAudio speech probability threshold (0.0–1.0).
    /// Lower = more sensitive (catches quieter speech but more false positives).
    /// Recommended: 0.3–0.6 for noisy, 0.7–0.9 for clean environments.
    var threshold: Float = 0.7

    // MARK: - Timing

    /// Seconds of non-speech after FluidAudio's speechEnd event before we
    /// propagate onSpeechEnd. Acts as a debounce — FluidAudio may fire
    /// speechEnd during brief pauses; this prevents premature cutoff.
    var silenceDuration: TimeInterval = 3.0

    // MARK: - Derived helpers

    /// Maps a 0.0–1.0 sensitivity to a FluidAudio threshold.
    /// sensitivity=0.0 → threshold=0.9 (hardest to trigger)
    /// sensitivity=1.0 → threshold=0.3 (easiest to trigger)
    static func threshold(for sensitivity: Float) -> Float {
        0.9 - sensitivity * 0.6
    }

    /// Inverse: maps a FluidAudio threshold back to sensitivity.
    static func sensitivity(for threshold: Float) -> Float {
        (0.9 - threshold) / 0.6
    }
}
