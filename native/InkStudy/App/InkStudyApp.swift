import SwiftUI

@main
struct InkStudyApp: App {
    @StateObject private var studio = StudioModel()
    @StateObject private var research = ResearchController()
    @StateObject private var generation = GenerationModel(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("InkStudy"))
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if HINTS_PREVIEW
            HintPreviewHome(research: research)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in if phase != .active { research.saveForBackground() } }
            #else
            ResearchHome(research: research, studio: studio, generation: generation)
                .preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { studio.saveForBackground(); research.saveForBackground() }
                }
            #endif
        }
    }
}
