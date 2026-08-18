import SwiftUI

struct ContentView: View {
    var body: some View {
        RootTabView()
    }
}

#Preview {
    ContentView()
        .environmentObject(PlaybackEngine())
        .environmentObject(SourceManager())
        .environmentObject(PlaylistStore())
        .environmentObject(ScriptStore())
        .environmentObject(SettingsStore())
}
