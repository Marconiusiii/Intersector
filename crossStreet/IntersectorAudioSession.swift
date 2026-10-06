import AVFoundation
import Foundation

/// Sound effects and app speech share one configuration and retain it until both finish.
@MainActor
final class IntersectorAudioSession {
	static let shared = IntersectorAudioSession(
		activate: {
			let session = AVAudioSession.sharedInstance()
			try session.setCategory(
				.playback, mode: .default,
				options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers]
			)
			try session.setActive(true)
		},
		deactivate: {
			try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
		}
	)

	private let activate: () throws -> Void
	private let deactivate: () throws -> Void
	private let startPlayback: (AVAudioPlayer) -> Bool
	private let stopPlayback: (AVAudioPlayer) -> Void
	private var owners = Set<UUID>()
	private var isSessionActive = false
	private var feedback: [ObjectIdentifier: FeedbackPlayback] = [:]

	init(
		activate: @escaping () throws -> Void,
		deactivate: @escaping () throws -> Void,
		startPlayback: @escaping (AVAudioPlayer) -> Bool = { $0.play() },
		stopPlayback: @escaping (AVAudioPlayer) -> Void = { $0.stop() }
	) {
		self.activate = activate
		self.deactivate = deactivate
		self.startPlayback = startPlayback
		self.stopPlayback = stopPlayback
	}

	func acquire() -> UUID {
		if !isSessionActive {
			do {
				try activate()
				isSessionActive = true
			} catch {}
		}
		let token = UUID()
		owners.insert(token)
		return token
	}

	func release(_ token: UUID) {
		guard owners.remove(token) != nil, owners.isEmpty, isSessionActive else { return }
		do {
			try deactivate()
			isSessionActive = false
		} catch {}
	}

	func play(_ player: AVAudioPlayer, replacing previousPlayer: AVAudioPlayer? = nil) {
		let identifier = ObjectIdentifier(player)
		if feedback[identifier] == nil {
			let playback = FeedbackPlayback(player: player, token: acquire(), session: self)
			feedback[identifier] = playback
			player.delegate = playback
		}
		// Retain the new playback before releasing the old one to avoid a session gap.
		if let previousPlayer, previousPlayer !== player { stop(previousPlayer) }
		if !startPlayback(player) { finishFeedback(player) }
	}

	func stop(_ player: AVAudioPlayer) {
		stopPlayback(player)
		finishFeedback(player)
	}

	private func finishFeedback(_ player: AVAudioPlayer, token: UUID? = nil) {
		let identifier = ObjectIdentifier(player)
		guard let playback = feedback[identifier], token == nil || token == playback.token else { return }
		feedback.removeValue(forKey: identifier)
		player.delegate = nil
		release(playback.token)
	}

	@MainActor
	private final class FeedbackPlayback: NSObject, @preconcurrency AVAudioPlayerDelegate {
		let player: AVAudioPlayer
		let token: UUID
		weak var session: IntersectorAudioSession?

		init(player: AVAudioPlayer, token: UUID, session: IntersectorAudioSession) {
			self.player = player
			self.token = token
			self.session = session
		}

		func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
			session?.finishFeedback(player, token: token)
		}

		func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
			session?.finishFeedback(player, token: token)
		}
	}
}
