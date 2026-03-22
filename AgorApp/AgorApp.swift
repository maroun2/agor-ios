import SwiftUI

@main
struct AgorApp: App {
    @State private var appViewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(appViewModel: appViewModel)
                .preferredColorScheme(nil) // Follow system
        }
    }
}
