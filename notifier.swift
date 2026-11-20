// Lensbell.app: posts a real macOS notification with the capture attached.
// It stays in Notification Center; clicking it opens the full image in Preview.
//   Lensbell notify <image> <title> <subtitle>
//   (launched with no args by macOS when the user clicks a notification)
import Cocoa
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let args = CommandLine.arguments
    var handled = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if args.count >= 5 && args[1] == "notify" {
            post(imagePath: args[2], title: args[3], subtitle: args[4])
        } else {
            // Launched by a notification click: wait briefly for the response.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if !self.handled { NSApp.terminate(nil) }
            }
        }
    }

    func post(imagePath: String, title: String, subtitle: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                FileHandle.standardError.write("notifications not authorized: \(String(describing: error))\n".data(using: .utf8)!)
                exit(2)
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = subtitle
            content.sound = .default
            content.threadIdentifier = "ezviz"
            content.userInfo = ["image": imagePath]

            // The attachment API moves the file, so hand it a temporary copy.
            let src = URL(fileURLWithPath: imagePath)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "." + (src.pathExtension.isEmpty ? "jpg" : src.pathExtension))
            if (try? FileManager.default.copyItem(at: src, to: tmp)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "capture", url: tmp, options: nil) {
                content.attachments = [attachment]
            }

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error = error {
                    FileHandle.standardError.write("post failed: \(error)\n".data(using: .utf8)!)
                    exit(3)
                }
                // Stay alive a moment in case the user clicks right away.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if !self.handled { exit(0) }
                }
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        handled = true
        if let path = response.notification.request.content.userInfo["image"] as? String,
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
