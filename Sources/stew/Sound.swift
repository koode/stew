import AudioToolbox
import Foundation

/// Plays the arrival sound through the system sound server.
///
/// NSSound starts CoreAudio inside the daemon, which on some Macs turns on voice
/// processing and makes macOS ask for microphone access. A system sound plays in the
/// sound server process instead, so the daemon never opens an audio device itself.
enum ArrivalSound {
    private static var cache: [String: SystemSoundID] = [:]

    /// Silences every arrival sound. `stew snapshot` and the headless test daemon build real
    /// panels nobody sees, so a sound from them would reach the user with nothing on screen.
    static var isMuted = Paths.headless

    /// Plays the named system sound ("Glass"). Nil or empty means no sound.
    static func play(_ name: String?) {
        guard !isMuted, let name, !name.isEmpty, let soundID = soundID(for: name) else { return }
        AudioServicesPlaySystemSound(soundID)
    }

    /// The file behind a sound name, from the same folders the Sound settings use.
    static func url(for name: String) -> URL? {
        let folders = ["/System/Library/Sounds", Paths.home + "/Library/Sounds", "/Library/Sounds"]
        for folder in folders {
            for fileExtension in ["aiff", "aif", "caf", "wav"] {
                let path = "\(folder)/\(name).\(fileExtension)"
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    private static func soundID(for name: String) -> SystemSoundID? {
        if let cached = cache[name] { return cached }
        guard let url = url(for: name) else {
            Log.write("no system sound named \(name)")
            return nil
        }
        var soundID: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &soundID)
        guard status == kAudioServicesNoError else {
            Log.write("cannot load sound \(name): OSStatus \(status)")
            return nil
        }
        cache[name] = soundID
        return soundID
    }
}
