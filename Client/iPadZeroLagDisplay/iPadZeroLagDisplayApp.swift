import SwiftUI

@main
@MainActor
struct iPadZeroLagDisplayApp: App {
    private let capabilities = ClientDeviceCapabilities.resolve(UIDevice.current.userInterfaceIdiom)

    var body: some Scene {
        WindowGroup {
            switch capabilities.family {
            case .phone: PhoneRootView(capabilities: capabilities)
            case .pad: ContentView()
            case .unknown: Text("Remote control is unavailable on this device.")
            }
        }
    }
}
