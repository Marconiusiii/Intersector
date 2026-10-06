import AVFoundation
import Foundation
import Testing
@testable import Intersector

@MainActor
struct AudioSessionTests {
	@Test func playerCompletionReleasesOnlyItsOwnSessionUse() throws {
		var events: [String] = []
		let session = IntersectorAudioSession(activate: { events.append("activate") }, deactivate: { events.append("deactivate") }, startPlayback: { _ in true }, stopPlayback: { _ in })
		let player = try Self.silentPlayer()
		session.play(player)
		let speech = session.acquire()
		player.delegate?.audioPlayerDidFinishPlaying?(player, successfully: true)
		#expect(events == ["activate"])
		session.release(speech)
		#expect(events == ["activate", "deactivate"])
	}

	@Test func replacementPlayerDoesNotDeactivateSessionAndIgnoresOldCallback() throws {
		var events: [String] = []
		let session = IntersectorAudioSession(activate: { events.append("activate") }, deactivate: { events.append("deactivate") }, startPlayback: { _ in true }, stopPlayback: { _ in })
		let first = try Self.silentPlayer()
		let second = try Self.silentPlayer()
		session.play(first)
		let oldDelegate = first.delegate
		session.play(second, replacing: first)
		oldDelegate?.audioPlayerDidFinishPlaying?(first, successfully: true)
		#expect(events == ["activate"])
		second.delegate?.audioPlayerDecodeErrorDidOccur?(second, error: nil)
		#expect(events == ["activate", "deactivate"])
	}

	@Test func failedPlayerStartReleasesSession() throws {
		var events: [String] = []
		let session = IntersectorAudioSession(activate: { events.append("activate") }, deactivate: { events.append("deactivate") }, startPlayback: { _ in false }, stopPlayback: { _ in })
		session.play(try Self.silentPlayer())
		#expect(events == ["activate", "deactivate"])
	}

	@Test func speechCompletionLeavesPlayingEffectActive() {
		var events: [String] = []
		let session = IntersectorAudioSession(activate: { events.append("activate") }, deactivate: { events.append("deactivate") })
		let effect = session.acquire()
		let speech = session.acquire()
		#expect(events == ["activate"])
		session.release(speech)
		#expect(events == ["activate"])
		session.release(effect)
		#expect(events == ["activate", "deactivate"])
	}

	@Test func effectCompletionLeavesSpeechActive() {
		var deactivations = 0
		let session = IntersectorAudioSession(activate: {}, deactivate: { deactivations += 1 })
		let effect = session.acquire()
		let speech = session.acquire()
		session.release(effect)
		#expect(deactivations == 0)
		session.release(speech)
		#expect(deactivations == 1)
	}

	@Test func staleCompletionCannotDeactivateReplacementPlayback() {
		var events: [String] = []
		let session = IntersectorAudioSession(activate: { events.append("activate") }, deactivate: { events.append("deactivate") })
		let oldEffect = session.acquire()
		let newEffect = session.acquire()
		session.release(oldEffect)
		session.release(oldEffect)
		session.release(UUID())
		#expect(events == ["activate"])
		session.release(newEffect)
		#expect(events == ["activate", "deactivate"])
	}

	@Test func rapidOffTransitionKeepsEffectAndNewSpeechInOneSession() {
		var events: [String] = []
		let session = IntersectorAudioSession(activate: { events.append("activate") }, deactivate: { events.append("deactivate") })
		let onEffect = session.acquire()
		let onSpeech = session.acquire()
		session.release(onSpeech)
		let offEffect = session.acquire()
		session.release(onEffect)
		let offSpeech = session.acquire()
		session.release(onSpeech)
		session.release(offEffect)
		#expect(events == ["activate"])
		session.release(offSpeech)
		#expect(events == ["activate", "deactivate"])
		let nextEffect = session.acquire()
		#expect(events == ["activate", "deactivate", "activate"])
		session.release(nextEffect)
	}

	@Test func failedActivationCanRetryOnNextUse() {
		struct ActivationFailure: Error {}
		var attempts = 0
		var deactivations = 0
		let session = IntersectorAudioSession(activate: {
			attempts += 1
			if attempts == 1 { throw ActivationFailure() }
		}, deactivate: { deactivations += 1 })
		let effect = session.acquire()
		let speech = session.acquire()
		#expect(attempts == 2)
		session.release(effect)
		#expect(deactivations == 0)
		session.release(speech)
		#expect(deactivations == 1)
	}
	private static func silentPlayer() throws -> AVAudioPlayer {
		// One silent PCM sample. Playback itself is injected, so tests emit no audio.
		let wave: [UInt8] = [
			82,73,70,70,38,0,0,0,87,65,86,69,102,109,116,32,
			16,0,0,0,1,0,1,0,34,86,0,0,68,172,0,0,2,0,16,0,
			100,97,116,97,2,0,0,0,0,0
		]
		return try AVAudioPlayer(data: Data(wave))
	}
}

