import AppKit

@MainActor
final class InteractionSoundPlayer {
    private let startSound: NSSound?
    private let endSound: NSSound?

    init() {
        startSound = NSSound(named: "Pop") ?? NSSound(named: "Tink")
        endSound = NSSound(named: "Tink") ?? NSSound(named: "Pop")
        startSound?.volume = 0.22
        endSound?.volume = 0.22
    }

    func playStart() {
        startSound?.stop()
        startSound?.play()
    }

    func playEnd() {
        endSound?.stop()
        endSound?.play()
    }
}
