import SmartWearCore
import SwiftUI

@main
struct SmartWearLabApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task {
                    AppStateHolder.shared = app
                    if DemoData.isOn { DemoData.load(into: app) } else { AutoTest.runIfRequested(app) }
                }
        }
    }
}
