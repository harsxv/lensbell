// Lensbell popup: shows a capture image at the top-right corner
// without stealing focus. Click = open full image in Preview.
// Right-click = dismiss. Auto-closes after a timeout.
// Usage: popup <image-path> <title> <subtitle> [timeout-seconds]
import Cocoa

let args = CommandLine.arguments
guard args.count >= 4, let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: popup <image> <title> <subtitle> [timeout]\n".data(using: .utf8)!)
    exit(1)
}
let imagePath = args[1]
let titleText = args[2]
let subtitleText = args[3]
let timeout = args.count > 4 ? (Double(args[4]) ?? 12) : 12

final class Panel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ClickView: NSView {
    var onClick: (() -> Void)?
    var onDismiss: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onDismiss?() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let pad: CGFloat = 10
let imgW: CGFloat = 380
let ratio = image.size.width > 0 ? image.size.height / image.size.width : 0.5625
let imgH = (imgW * ratio).rounded()
let textH: CGFloat = 44
let winW = imgW + pad * 2
let winH = imgH + textH + pad * 2

let screen = (NSScreen.main ?? NSScreen.screens.first)!.visibleFrame
let frame = NSRect(x: screen.maxX - winW - 12, y: screen.maxY - winH - 12,
                   width: winW, height: winH)

let panel = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                  backing: .buffered, defer: false)
panel.level = .statusBar
panel.isOpaque = false
panel.backgroundColor = .clear
panel.hasShadow = true
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
bg.material = .popover
bg.blendingMode = .behindWindow
bg.state = .active
bg.wantsLayer = true
bg.layer?.cornerRadius = 16
bg.layer?.masksToBounds = true

let imageView = NSImageView(frame: NSRect(x: pad, y: pad, width: imgW, height: imgH))
imageView.image = image
imageView.imageScaling = .scaleProportionallyUpOrDown
imageView.wantsLayer = true
imageView.layer?.cornerRadius = 10
imageView.layer?.masksToBounds = true

let title = NSTextField(labelWithString: titleText)
title.font = .boldSystemFont(ofSize: 13)
title.lineBreakMode = .byTruncatingTail
title.frame = NSRect(x: pad + 2, y: pad + imgH + 22, width: imgW - 4, height: 18)

let subtitle = NSTextField(labelWithString: subtitleText)
subtitle.font = .systemFont(ofSize: 12)
subtitle.textColor = .secondaryLabelColor
subtitle.lineBreakMode = .byTruncatingTail
subtitle.frame = NSRect(x: pad + 2, y: pad + imgH + 5, width: imgW - 4, height: 16)

let click = ClickView(frame: bg.bounds)
click.onClick = {
    NSWorkspace.shared.open(URL(fileURLWithPath: imagePath))
    app.terminate(nil)
}
click.onDismiss = { app.terminate(nil) }

bg.addSubview(imageView)
bg.addSubview(title)
bg.addSubview(subtitle)
bg.addSubview(click)
panel.contentView = bg

panel.alphaValue = 0
panel.orderFrontRegardless()
NSAnimationContext.runAnimationGroup { ctx in
    ctx.duration = 0.2
    panel.animator().alphaValue = 1
}
NSSound(named: NSSound.Name("Glass"))?.play()

Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
    NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.3
        panel.animator().alphaValue = 0
    }, completionHandler: { app.terminate(nil) })
}

app.run()
