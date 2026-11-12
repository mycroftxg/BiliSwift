import SwiftUI
import HarborCore

@main struct HarborBiliApp:App {
    @State private var account=AccountSession()
    @State private var library=LocalLibrary()
    @State private var playback=PlaybackController()
    @State private var preferences=AppPreferences()
    @State private var presentation=WindowPresentation()
    @State private var updater = UpdateController()
    @State private var checkedOnLaunch = false
    @State private var showsUpdate = false
    var body:some Scene {
        Window("BiliSwift",id:"main") {
            ContentView()
                .environment(account).environment(library).environment(playback).environment(preferences).environment(presentation)
                .frame(minWidth:860,minHeight:600)
                .preferredColorScheme(preferences.colorScheme)
                .task { playback.preferences=preferences;await account.restore() }
                .task {
                    guard !checkedOnLaunch else { return }
                    checkedOnLaunch = true
                    await updater.check()
                    showsUpdate = updater.release != nil
                }
                .sheet(isPresented: $showsUpdate) {
                    UpdatePrompt(updater: updater, preferences: preferences)
                }
        }.defaultSize(width:1320,height:860)
            .commands { CommandGroup(after:.newItem) { Button("暂停／继续播放") { playback.toggle() }.keyboardShortcut("p",modifiers:[.command,.shift]) } }
        Settings { SettingsView().environment(updater).environment(account).environment(library).environment(playback).environment(preferences).preferredColorScheme(preferences.colorScheme) }
    }
}
