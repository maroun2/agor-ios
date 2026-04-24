import Foundation

/// All tunable constants for VoiceActivityDetector in one place.
/// Change any value on `vad.config` at runtime — takes effect on the next audio frame.
/// Codable so the whole struct can be saved/loaded as JSON via UserDefaults.
struct VADConfig: Codable {

    // MARK: - EMA (smoothing)

    /// How fast the smoothed level chases rising RMS — ~65ms to 63% at 47fps.
    /// Lower → slower attack (less reactive to speech onset).
    var emaAttackAlpha: Float = 0.30

    /// How fast the smoothed level falls after sound stops — ~255ms to 63% at 47fps.
    /// Lower → slower release (level stays elevated longer, fewer false silence triggers).
    var emaReleaseAlpha: Float = 0.08

    // MARK: - Noise floor adaptation

    /// Fast rise alpha during the initial calibration window.
    /// Lets the floor converge from 0.001 to actual ambient in ~0.5s (95% in ~1.3s).
    var noiseFloorCalibrationAlpha: Float = 0.15

    /// Slow rise alpha during normal listening.
    /// Low = floor rises gradually so single loud bursts don't inflate it.
    /// Raise (e.g. 0.05) if threshold feels permanently too low after ambient changes.
    var noiseFloorRiseAlpha: Float = 0.02

    /// Fall alpha — how fast the floor drops when the room gets quieter.
    /// Low = slow fall (~1.8s to halve). Raise if you want faster threshold drop after noise ends.
    var noiseFloorFallAlpha: Float = 0.008

    /// Hard cap on the noise floor.
    /// Prevents very loud sustained background from raising the threshold so high that
    /// speech can never be detected. Raise (e.g. 0.020) for noisy venues.
    /// → startThreshold max = maxNoiseFloor × startMultiplier
    var maxNoiseFloor: Float = 0.010

    // MARK: - Calibration

    /// Frames during which speech detection is suppressed so the floor can converge.
    /// ~1.3s at 47fps. Set to 0 with skipCalibration() when resuming.
    var calibrationFrameCount: Int = 60

    // MARK: - Speech confirmation

    /// Consecutive frames above startThreshold required before speech is confirmed.
    /// 12 frames ≈ 250ms — filters keyboard clicks, breaths, short transients.
    /// Raise (e.g. 16–20) to reduce false triggers; lower for faster response.
    var confirmationFrameCount: Int = 12

    // MARK: - Thresholds

    /// startThreshold multiplier when sensitivity = 0.0 (hardest to trigger).
    /// startThreshold = noiseFloor × startMultiplier.
    var startMultiplierAtLowSensitivity: Float = 3.5

    /// startThreshold multiplier when sensitivity = 1.0 (easiest to trigger).
    var startMultiplierAtHighSensitivity: Float = 2.0

    /// endThreshold = startThreshold × hysteresisRatio.
    /// Industry range: 0.60–0.90. Higher = wider gap, harder for noise to keep recording alive.
    /// Raise in noisy environments (e.g. 0.75–0.85) so ambient bursts don't refresh lastSoundTime.
    var hysteresisRatio: Float = 0.65

    /// Multiple of noiseFloor at which floor-rise is suppressed.
    /// Energy above (noiseFloor × suppressRiseGateMultiplier) freezes the floor — it
    /// could be speech, so we don't let the floor chase it.
    /// 2.0 = original safe default (energy > 2× floor triggers freeze).
    /// Lower (e.g. 1.5) for more protection; raise (e.g. 2.5) to allow more floor rise.
    var suppressRiseGateMultiplier: Float = 2.0

    // MARK: - Timing

    /// Seconds of energy below endThreshold before speech is ended. Keep at 3.0 for comfort.
    var silenceDuration: TimeInterval = 3.0

    // MARK: - Derived helpers (read-only)

    func startMultiplier(for sensitivity: Float) -> Float {
        startMultiplierAtLowSensitivity
            - sensitivity * (startMultiplierAtLowSensitivity - startMultiplierAtHighSensitivity)
    }
}
