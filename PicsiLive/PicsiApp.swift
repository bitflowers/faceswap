import SwiftUI

@main
struct PicsiApp: App {
    var body: some Scene {
        WindowGroup {
            PicsiLiveView()
                .preferredColorScheme(.dark)
        }
    }
}
