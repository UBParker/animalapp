import AVFoundation
import Foundation

/// Plays a recording, or a time range within it, from a file URL.
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var playingID: UUID?

    private var player: AVAudioPlayer?
    private var stopTimer: Timer?

    func play(url: URL, id: UUID, startS: Double? = nil, endS: Double? = nil) {
        stop()
        do {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            if let startS { p.currentTime = startS }
            p.play()
            player = p
            isPlaying = true
            playingID = id
            if let endS {
                let seconds = max(0.05, endS - (startS ?? 0))
                stopTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.stop() }
                }
            }
        } catch {
            isPlaying = false
            playingID = nil
        }
    }

    func stop() {
        stopTimer?.invalidate()
        stopTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.stop() }
    }
}
