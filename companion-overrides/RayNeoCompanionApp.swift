import SwiftUI

@main
struct RayNeoCompanionApp: App {
    @StateObject private var store = CompanionStore.forCurrentLaunch()
    @StateObject private var notebooks = IONotebookStore()

    var body: some Scene {
        WindowGroup {
            IOCompanionRoot()
                .environmentObject(store)
                .environmentObject(notebooks)
                .environmentObject(store.archive)
                .environmentObject(store.archive.audioInspection)
                .environmentObject(store.books)
                .environmentObject(store.voice)
                .environmentObject(store.codex)
                .environmentObject(store.codexPush)
                .environmentObject(store.timeline)
                .environmentObject(store.recordingASR)
                .environmentObject(store.features)
                .environmentObject(store.notifications)
                .environmentObject(store.headControlTest)
                .environmentObject(store.automaticWeather)
                .environmentObject(store.qweather)
                .tint(Palette.green)
                .preferredColorScheme(.light)
        }
    }
}

// Existing detail screens use this preference to keep their controls reachable.
struct CompanionTabBarHiddenPreference: PreferenceKey {
    static var defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
