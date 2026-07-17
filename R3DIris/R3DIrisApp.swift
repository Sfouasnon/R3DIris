//  R3DIrisApp.swift

import SwiftUI

@main
struct R3DIrisApp: App {
    @StateObject private var bench = BenchController()
    @StateObject private var array = ArrayController()

    init() {
        // Dock-icon belt and suspenders: the asset-catalog AppIcon needs a
        // clean build (and sometimes an icon-cache flush) before Finder/Dock
        // pick it up. Setting the runtime icon from the bundled fallback
        // render guarantees the mark shows while the app is running.
        if let url = Bundle.main.url(forResource: "AppIconFallback", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bench)
                .environmentObject(array)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
