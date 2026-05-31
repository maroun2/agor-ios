import AVFoundation

extension AVSpeechSynthesisVoice {
    /// Best available en-US TTS voice with a fixed priority fallback chain:
    /// 1. Zoe premium (highest quality, female)
    /// 2. Evan premium (male alternative)
    /// 3. Highest-quality en-US voice sorted by quality.rawValue descending
    /// 4. System default en-US
    static func bestAvailable() -> AVSpeechSynthesisVoice? {
        let preferred = [
            "com.apple.voice.premium.en-US.Zoe",
            "com.apple.voice.premium.en-US.Evan",
        ]
        for identifier in preferred {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return voice
            }
        }
        if let best = AVSpeechSynthesisVoice.speechVoices()
            .filter({ $0.language == "en-US" })
            .sorted(by: { $0.quality.rawValue > $1.quality.rawValue })
            .first {
            return best
        }
        return AVSpeechSynthesisVoice(language: "en-US")
    }
}
