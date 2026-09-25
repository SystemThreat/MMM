import Cocoa

/// Native status item: independent of WebKit visibility and explorer requests.
final class MenuBarController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    let rate = NSTextField(labelWithString: "— H/s")
    let state = NSTextField(labelWithString: "MINER STOPPED")
    let network = NSTextField(labelWithString: "TESTNET A")
    let counts = NSTextField(labelWithString: "Accepted —   ·   Rejected —\nBlocks —   ·   Uptime —")
    let message = NSTextField(wrappingLabelWithString: "Open the full view to configure your miner.")
    let stop = NSButton(title: "STOP MINING", target: nil, action: nil)
    var onShow: (() -> Void)?
    var onStop: (() -> Void)?
    var onQuit: (() -> Void)?
    var animation: Timer?
    var frame = 0
    private lazy var pickaxeFrames = (0..<16).map { menuBarPickaxe(angle:26 * sin(Double($0) * .pi / 8)) }
    private var mining = false
    private var paused = ""   // the schedule's reason while it holds a stopped engine
    private var hashrate = "— H/s"
    private let lime = NSColor(calibratedRed:199/255, green:1, blue:46/255, alpha:1)

    override init() {
        super.init()
        guard let button = item.button else { return }
        button.target = self; button.action = #selector(toggle)
        button.font = NSFont.monospacedDigitSystemFont(ofSize:14, weight:.medium)
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel("MMM mining status")
        item.isVisible = true
        let controller = NSViewController()
        let view = NSView(frame:NSRect(x:0,y:0,width:400,height:400))
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor(calibratedWhite:0.035,alpha:1).cgColor
        controller.view = view
        let title = NSTextField(labelWithString:"MMM / NERD STATS")
        title.font = .monospacedSystemFont(ofSize:16,weight:.bold); title.textColor = lime
        state.font = .monospacedSystemFont(ofSize:14,weight:.medium); state.textColor = .lightGray
        rate.font = .monospacedDigitSystemFont(ofSize:44,weight:.bold); rate.textColor = lime
        rate.lineBreakMode = .byTruncatingTail
        network.font = .monospacedSystemFont(ofSize:14,weight:.medium); network.textColor = .white
        counts.font = .monospacedDigitSystemFont(ofSize:15,weight:.regular); counts.textColor = .lightGray
        counts.maximumNumberOfLines = 2
        message.font = .systemFont(ofSize:14); message.textColor = .lightGray
        message.maximumNumberOfLines = 3
        let full = NSButton(title:"↗  FULL VIEW",target:self,action:#selector(showFull))
        full.font = .systemFont(ofSize:16,weight:.semibold); stop.font = .systemFont(ofSize:16,weight:.semibold)
        full.bezelStyle = .rounded; full.contentTintColor = lime
        stop.target = self; stop.action = #selector(stopMining); stop.bezelStyle = .rounded; stop.isEnabled = false
        let buttons = NSStackView(views:[full,stop]); buttons.orientation = .horizontal; buttons.distribution = .fillEqually; buttons.spacing = 10
        let quit = NSButton(title:"Quit MMM and stop mining",target:self,action:#selector(quitApp))
        quit.isBordered = false; quit.font = .systemFont(ofSize:13); quit.contentTintColor = .lightGray
        let stack = NSStackView(views:[title,state,rate,network,counts,message,buttons,quit])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),
            stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20),
            stack.topAnchor.constraint(equalTo:view.topAnchor,constant:20),
            buttons.widthAnchor.constraint(equalTo:stack.widthAnchor),
            message.widthAnchor.constraint(equalTo:stack.widthAnchor),
            rate.widthAnchor.constraint(equalTo:stack.widthAnchor)
        ])
        popover.contentViewController = controller; popover.contentSize = NSSize(width:400,height:400)
        popover.behavior = .transient
        drawStatus()
    }
    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo:button.bounds,of:button,preferredEdge:.minY) }
    }
    @objc func showFull() { popover.performClose(nil); onShow?() }
    @objc func stopMining() { stop.isEnabled = false; state.stringValue = "STOPPING…"; onStop?() }
    @objc func quitApp() { onQuit?() }
    func update(_ event:[String:Any]) {
        let type = event["type"] as? String ?? ""
        switch type {
        case "profile":
            let p = event["data"] as? [String:String] ?? [:]
            network.stringValue = (p["network"] == "mainnet" ? "MAINNET" : "TESTNET A") + (p["worker",default:""].isEmpty ? "" : " / " + p["worker"]!)
        case "started":
            mining = true; paused = ""; hashrate = "Starting…"; rate.stringValue = "Building DAG…"
            state.stringValue = "ENGINE STARTING"; message.stringValue = "Mining continues when the window is minimized or closed."
            stop.isEnabled = true; animate()
        case "miner":
            guard mining else { return }
            let s = event["data"] as? [String:Any] ?? [:]
            let down = s["pool_connected"] as? Bool == false   // hashing is paused until the pool answers
            hashrate = down ? "Reconnecting…" : s["hashrate_pretty"] as? String ?? "— H/s"
            rate.stringValue = down ? "— H/s" : hashrate
            state.stringValue = down ? "RECONNECTING" : (s["running"] as? Bool == true) ? "● MINING" : "ENGINE INITIALIZING"
            let accepted = s["accepted"] as? NSNumber ?? 0, rejected = s["rejected"] as? NSNumber ?? 0
            let blocks = s["blocks_found"] as? NSNumber ?? 0, seconds = s["uptime_s"] as? Int ?? 0
            counts.stringValue = "Accepted \(accepted)   ·   Rejected \(rejected)\nBlocks \(blocks)   ·   Uptime \(seconds / 3600)h \((seconds % 3600) / 60)m"
            message.stringValue = down ? "Pool connection lost — \(s["pool_status"] as? String ?? "reconnecting"). Hashing is paused until the pool answers."
                                       : s["last_event"] as? String ?? "Mining in the background."
        case "minerPending":
            guard mining else { return }; hashrate = "Waiting…"; rate.stringValue = "— H/s"
            state.stringValue = "WAITING FOR ENGINE"; message.stringValue = "Local statistics are unavailable. Waiting for the engine to respond."
        case "stopped":
            mining = false; hashrate = "Idle"; rate.stringValue = "— H/s"; state.stringValue = "MINER STOPPED"
            stop.isEnabled = false; animation?.invalidate(); animation = nil; frame = 0
            let code = (event["code"] as? NSNumber)?.intValue ?? 0   // 0 = done, 15 = SIGTERM (STOP / quit)
            message.stringValue = [0, 15].contains(code) ? "Open the full view to start another session."
                : (event["reason"] as? String).map { "Engine exited (\(code)): \($0)" } ?? "Engine exited (\(code)). Check the engine log."
        case "error": message.stringValue = event["message"] as? String ?? "Check the full view."
        case "schedule":
            guard !mining else { return }
            paused = event["paused"] as? Bool == true ? event["reason"] as? String ?? "" : ""
            state.stringValue = paused.isEmpty ? "MINER STOPPED" : "PAUSED BY SCHEDULE"
            if !paused.isEmpty { message.stringValue = "Paused by schedule — \(paused). Mining resumes when the schedule allows." }
        default: break
        }
        drawStatus()
    }
    private func animate() {
        animation?.invalidate()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animation = Timer.scheduledTimer(withTimeInterval:1.0 / 12.0,repeats:true) { [weak self] _ in
            guard let self else { return }; self.frame = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : (self.frame + 1) % 16; self.drawStatus()
        }
        if let animation { RunLoop.main.add(animation,forMode:.common) }
    }
    private func drawStatus() {
        item.button?.title = " " + (mining ? hashrate : paused.isEmpty ? "Idle" : "Paused")
        item.button?.toolTip = "MMM · \(state.stringValue)" + (mining || paused.isEmpty ? "" : " — " + paused) + " · Click for compact controls"
        item.button?.image = pickaxeFrames[mining ? frame : 0]
    }
    func invalidate() { animation?.invalidate(); NSStatusBar.system.removeStatusItem(item) }
}
