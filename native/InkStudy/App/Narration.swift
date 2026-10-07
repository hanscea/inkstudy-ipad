import SwiftUI
import AVFoundation
import InkStudyCore

@MainActor
protocol SpeechOutput: AnyObject {
    var voiceID: String? { get }
    var onFinish: (() -> Void)? { get set }
    var onStart: (() -> Void)? { get set }
    var onCancel: (() -> Void)? { get set }
    func speak(_ text: String) throws
    func stop()
}

extension SpeechOutput {
    var onStart: (() -> Void)? { get { nil } set {} }
    var onCancel: (() -> Void)? { get { nil } set {} }
}

@MainActor
final class SystemSpeechOutput: NSObject, SpeechOutput, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: ObjectIdentifier?
    var onFinish: (() -> Void)?
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?
    private var voice: AVSpeechSynthesisVoice? { AVSpeechSynthesisVoice(language: "zh-CN") }
    var voiceID: String? { voice?.identifier }
    override init() { super.init(); synthesizer.delegate = self }

    func speak(_ text: String) throws {
        guard let voice else { throw DrawingError.persistence("这台设备尚未提供普通话语音。可在系统的朗读内容设置中下载中文语音。") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        activeUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }
    func stop() {
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func finished(_ id: ObjectIdentifier, cancelled: Bool = false) {
        guard activeUtterance == id else { return }
        activeUtterance = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if cancelled { onCancel?() } else { onFinish?() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance == id else { return }; self.onStart?()
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(id) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(id, cancelled: true) }
    }
}

@MainActor
final class NarrationController: ObservableObject {
    @Published private(set) var currentKey: String?
    @Published private(set) var error: String?
    private let output: any SpeechOutput
    private var operation = 0
    var onPlayback: ((String, HintDeliveryKind) -> Void)?
    private var speaking = false
    init(output: (any SpeechOutput)? = nil) {
        self.output = output ?? SystemSpeechOutput()
        self.output.onStart = { [weak self] in
            guard let self, let key = self.currentKey else { return }
            self.speaking = true; self.onPlayback?(key, .audioStarted)
        }
        self.output.onFinish = { [weak self] in
            guard let self else { return }
            if let key = self.currentKey { self.onPlayback?(key, .audioFinished) }
            self.currentKey = nil; self.speaking = false
        }
        self.output.onCancel = { [weak self] in self?.stop() }
    }
    func toggle(text: String, key: String, recordRequest: (String) async -> Bool) async {
        if currentKey == key { stop(); return }
        stop(); error = nil
        guard let voiceID = output.voiceID else {
            error = "尚未找到普通话语音，请先在系统朗读内容设置中下载。"; onPlayback?(key, .audioFailed); return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let token = operation
        currentKey = key
        let accepted = await recordRequest(voiceID)
        // Navigating or pressing stop while the request is saving must not start speech later.
        guard token == operation else { return }
        guard accepted else { currentKey = nil; return }
        do { try output.speak(text) }
        catch { self.error = error.localizedDescription; onPlayback?(key, .audioFailed); currentKey = nil; output.stop() }
    }
    func stop() {
        if let key = currentKey, speaking { onPlayback?(key, .audioStopped) }
        operation += 1; currentKey = nil; speaking = false; output.stop()
    }
}

struct NarrationButton: View {
    @EnvironmentObject private var narrator: NarrationController
    @ObservedObject var research: ResearchController
    let text: String
    let key: String
    var kind: NarrationKind = .instruction
    var feedbackID: UUID?
    private var active: Bool { narrator.currentKey == key }
    var body: some View {
        if research.state?.configuration.protocolVersion == ResearchProtocol.version {
            Button {
                Task {
                    await narrator.toggle(text: text, key: key) { voiceID in
                        await research.perform(.narrationRequested(text: text, kind: kind, feedbackID: feedbackID, voiceID: voiceID))
                    }
                }
            } label: {
                Label(active ? "停止朗读" : "朗读", systemImage: active ? "stop.fill" : "speaker.wave.2.fill")
                    .font(.caption.weight(.semibold)).padding(.vertical, 5)
            }
            .buttonStyle(.bordered).accessibilityIdentifier("narration-\(key)")
            .disabled(!active && (research.locked || research.canvas?.isDrawing == true || research.state?.activeHelp != nil))
            .onChange(of: key) { previous, _ in if narrator.currentKey == previous { narrator.stop() } }
            .onDisappear { if narrator.currentKey == key { narrator.stop() } }
        }
    }
}
