//  R3DIrisApp.swift

import SwiftUI

@main
struct R3DIrisApp: App {
    @StateObject private var bench = BenchController()
    @StateObject private var array = ArrayController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bench)
                .environmentObject(array)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
