import SwiftUI

@main
struct CodeQuotaDialApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
