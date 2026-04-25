import Foundation

/// All tunable constants for VoiceActivityDetector in one place.
/// Change any value on `vad.config` at runtime — takes effect on the next audio frame.
/// Codable so the whole struct can be saved/loaded as JSON via UserDefaults.
struct VADConfig: Codable, Equatable {

    // MARK: - EMA (smoothing)

    /// How fast the smoothed level chases rising RMS.
    /// Higher → faster reaction to speech onset. 0.50 reaches 63% in ~2 frames at 47fps.
    var emaAttackAlpha: Float = 0.50

    /// How fast the smoothed level falls after sound stops.
    /// Lower → slower release (level stays elevated longer, fewer false silence triggers).
    var emaReleaseAlpha: Float = 0.08

    // MARK: - Noise floor adaptation

    /// Fast rise alpha during the initial calibration window.
    /// Lets the floor converge from 0.001 to actual ambient in ~0.5s.
    var noiseFloorCalibrationAlpha: Float = 0.15

    /// Slow rise alpha during normal listening.
    /// Controls how fast the noise floor tracks upward ambient changes.
    /// 0 = floor never rises after calibration (safest for speech detection).
    var noiseFloorRiseAlpha: Float = 0

    /// Fall alpha — how fast the floor drops when the room gets quieter.
    var noiseFloorFallAlpha: Float = 0.008

    /// Hard cap on the noise floor.
    /// Prevents very loud sustained background from raising the threshold so high that
    /// speech can never be detected.
    /// At 0.005 with startMultiplier 2.25, threshold caps at ~0.011 — normal speech
    /// (0.015+) still triggers easily.
    var maxNoiseFloor: Float = 0.005

    /// Frames after an above-threshold detection during which floor rise is frozen.
    /// Prevents the floor from chasing speech energy during brief pauses between syllables.
    /// 20 frames ≈ 425ms at 47fps.
    var noiseFloorFreezeFrames: Int = 20

    // MARK: - Calibration

    /// Frames during which speech detection is suppressed so the floor can converge.
    /// 20 frames ≈ 0.4s at 47fps — enough for the floor to settle on ambient noise
    /// but short enough that the user hasn't started speaking yet.
    /// Set to 0 with skipCalibration() when resuming.
    var calibrationFrameCount: Int = 20

    // MARK: - Speech confirmation (M-of-N)

    /// Frames above startThreshold required within the confirmation window.
    /// M-of-N is more robust than requiring N consecutive frames — tolerates
    /// brief dips from inter-syllable pauses and natural speech variability.
    var confirmationRequired: Int = 3

    /// Window size (in frames) to look for confirmationRequired hits.
    /// 5 frames ≈ 106ms at 47fps.
    var confirmationWindow: Int = 5

    // MARK: - Thresholds

    /// startThreshold multiplier when sensitivity = 0.0 (hardest to trigger).
    /// startThreshold = noiseFloor × startMultiplier.
    var startMultiplierAtLowSensitivity: Float = 3.0

    /// startThreshold multiplier when sensitivity = 1.0 (easiest to trigger).
    var startMultiplierAtHighSensitivity: Float = 1.5

    /// endThreshold = startThreshold × hysteresisRatio.
    /// Industry range: 0.60–0.90. Higher = wider gap, harder for noise to keep recording alive.
    var hysteresisRatio: Float = 0.65

    /// Multiple of noiseFloor at which floor-rise is suppressed.
    /// Energy above (noiseFloor × suppressRiseGateMultiplier) freezes the floor — it
    /// could be speech, so we don't let the floor chase it.
    var suppressRiseGateMultiplier: Float = 2.0

    // MARK: - Timing

    /// Seconds of energy below endThreshold before speech is ended.
    var silenceDuration: TimeInterval = 3.0

    // MARK: - Derived helpers (read-only)

    func startMultiplier(for sensitivity: Float) -> Float {
        startMultiplierAtLowSensitivity
            - sensitivity * (startMultiplierAtLowSensitivity - startMultiplierAtHighSensitivity)
    }
}
