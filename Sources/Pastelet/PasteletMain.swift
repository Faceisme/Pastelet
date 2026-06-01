import AppKit

@main
struct PasteletMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let appDelegate = AppDelegate()
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
