import Cocoa
import WebKit

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var process: Process?
    var loginProcess: Process?
    var miningActivity: NSObjectProtocol?
    var password = ""
    var didAttemptAutoStart = false
    var timer: Timer?
    var statsTimer: Timer?
    var statsBusy = false
    var menuBar: MenuBarController!
    var busy = false
    var launching = false
    var generation = 0
    var profile: [String: String] = ["network":"testnet", "explorer":"https://superknet.com", "host":"", "port":"", "address":"", "worker":"", "mode":"solo"]
    var lastStats: [String: Any] = [:]
    let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 12; return c }())
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults:["autoStartMining":true])
        if let saved = UserDefaults.standard.dictionary(forKey: "profile") as? [String: String] { profile.merge(saved) { _, new in new } }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "native")
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width:1280,height:800)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1240,screen.width-40), height: min(780,screen.height-70)), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "MMM — Nerd Stats Edition"
        window.minSize = NSSize(width: 940, height: 640)
        window.delegate = self; window.isReleasedWhenClosed = false
        menuBar = MenuBarController()
        menuBar.onShow = { [weak self] in self?.showFullWindow() }
        menuBar.onStop = { [weak self] in self?.process?.terminate() }
        window.contentView = web
        window.center(); window.makeKeyAndOrderFront(nil)
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit MMM", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = appMenu
        let edit = NSMenuItem(); menu.addItem(edit); let em = NSMenu(title:"Edit"); edit.submenu = em
        for (title, action, key) in [("Copy", "copy:", "c"),("Paste","paste:","v"),("Select All","selectAll:","a"),("Cut","cut:","x")] { em.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        NSApp.mainMenu = menu
        let file = Bundle.main.resourceURL!.appendingPathComponent("index.html")
        web.loadFileURL(file, allowingReadAccessTo: Bundle.main.resourceURL!)
        NSApp.activate(ignoringOtherApps: true)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit(["type":"profile", "data":profile])
        emit(["type":"autoStartPreference","enabled":UserDefaults.standard.bool(forKey:"autoStartMining")])
        emit(["type":"forumCred","saved":ForumCredential.exists()])
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in Task { @MainActor in self?.refreshMiner() } }
        if let statsTimer { RunLoop.main.add(statsTimer,forMode:.common) }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        if !didAttemptAutoStart {
            didAttemptAutoStart = true
            Task { @MainActor in
                do {
                    password = try PoolCredential.load(profile)
                    emit(["type":"credential","password":password])
                    if UserDefaults.standard.bool(forKey:"autoStartMining") {
                        if startupSettingsComplete(profile) { await start() }
                        else { emit(["type":"setupRequired","message":"Automatic mining is on. Save your payout address, IP address, port and worker to enable it on the next launch."]) }
                    }
                } catch { emit(["type":"setupRequired","message":error.localizedDescription]) }
            }
        }
    }
    func emit(_ value: [String: Any]) {
        menuBar?.update(value)
        guard let data = try? JSONSerialization.data(withJSONObject: value), let json = String(data:data, encoding:.utf8) else { return }
        web.evaluateJavaScript("window.receive(\(json))", completionHandler:nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let b = message.body as? [String:Any], let action = b["action"] as? String else { return }
        switch action {
        case "save":
            guard process == nil, let p = b["profile"] as? [String:String] else { return }
            let submittedPassword = b["password"] as? String ?? ""
            var nextProfile = profile; nextProfile.merge(p) { _,new in new }
            do { try PoolCredential.save(submittedPassword,profile:nextProfile) }
            catch { emit(["type":"setupRequired","message":error.localizedDescription]); return }
            password = submittedPassword
            profile.merge(p) { _, new in new }; generation += 1; lastStats = [:]
            UserDefaults.standard.set(profile, forKey:"profile"); emit(["type":"reset"]); menuBar.update(["type":"profile","data":profile]); refresh()
            if b["startAfterSave"] as? Bool == true { Task { await start() } }
        case "autoStartPreference":
            guard let enabled = b["enabled"] as? Bool else { return }
            UserDefaults.standard.set(enabled,forKey:"autoStartMining")
            emit(["type":"autoStartPreference","enabled":enabled])
        case "start": Task { await start() }
        case "login": forumLogin(passphrase: b["passphrase"] as? String ?? "", remember: b["remember"] as? Bool ?? false)
        case "loginTouch":
            ForumCredential.authenticate { [weak self] ok, why in
                guard let self else { return }
                if ok, let pw = try? ForumCredential.load() { self.forumLogin(passphrase: pw, remember: false) }
                else { self.emit(["type": "loginStatus", "state": "fail", "message": why ?? "Touch ID failed."]) }
            }
        case "loginForget":
            ForumCredential.forget()
            emit(["type": "forumCred", "saved": false])
            emit(["type": "loginStatus", "state": "idle", "message": "Saved passphrase removed. Type it to sign in."])
        case "stop": process?.terminate()
        case "refresh": refresh(); refreshMiner()
        case "minimize": window.miniaturize(nil)
        case "copy": if let s = b["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType:.string) }
        case "open":
            if let path = b["path"] as? String, path.hasPrefix("/"), let url = URL(string:(profile["explorer"] ?? "") + path), ["https","http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel) }
    func get(_ url: String, local: Bool = false) async throws -> [String:Any] {
        guard let u = URL(string:url), ["https","http"].contains(u.scheme ?? "") else { throw NSError(domain:"Invalid endpoint URL",code:1) }
        var r = URLRequest(url:u)
        if local { r.setValue("GUI", forHTTPHeaderField:"X-NerdMiner-MD") }
        let (d,response) = try await session.data(for:r)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with:d) as? [String:Any] else { throw NSError(domain:"Endpoint did not return valid JSON",code:1) }
        return j
    }
    @MainActor func refresh() {
        guard !busy else { return }; busy = true
        let revision = generation, origin = profile["explorer"] ?? "", network = profile["network"] ?? "testnet"
        Task { @MainActor in
            defer { busy = false; if generation != revision { refresh() } }
            do {
                let stats = try await get(origin + "/api/stats")
                guard stats["hrp"] as? String == (network == "testnet" ? "txa" : "xpa") else { throw NSError(domain:"Explorer is serving a different network. Configure the correct explorer URL.",code:1) }
                guard generation == revision else { return }
                lastStats = stats; emit(["type":"chain","data":stats])
                do { let n = try await get(origin + "/api/network"); if generation == revision { emit(["type":"network","data":n]) } } catch { emit(["type":"networkError","message":"Miner registry unavailable"]) }
                if let height = stats["height"] as? Int {
                    var blocks = [[String:Any]]()
                    for h in stride(from:height, through:max(0,height-7), by:-1) {
                        if let block = try? await get(origin + "/api/block/\(h)") { blocks.append(block) }
                    }
                    if generation == revision { emit(["type":"blocks","data":blocks]) }
                }
            } catch { if generation == revision { lastStats = [:]; emit(["type":"offline","message":error.localizedDescription]) } }
        }
    }
    @MainActor func start() async {
        guard process == nil, !launching else { return }
        launching = true; defer { launching = false }
        let p = profile, address = p["address",default:""]
        let isTest = p["network"] == "testnet"
        guard validAddress(address, hrp:isTest ? "txa" : "xpa") else { emit(["type":"error","message":"Enter a valid witness v3 \(isTest ? "txa1r" : "xpa1r") payout address with a correct bech32m checksum."]); return }
        let host = p["host",default:""]
        guard !host.isEmpty, host.range(of: "^[a-zA-Z0-9.-]+$", options: .regularExpression) != nil, let port = UInt16(p["port",default:""]), port > 0, !p["worker",default:""].isEmpty else { emit(["type":"error","message":"Enter an IP address or hostname, port (1–65535), and worker name."]); return }
        var args = [address,"--pool",host + ":" + String(port),"--worker",p["worker",default:""],"--mode",p["mode"] == "shared" ? "shared":"solo","--stats-port","47476"]
        if !isTest {
            do {
                let stats = try await get(p["explorer",default:""] + "/api/stats")
                guard stats["hrp"] as? String == "xpa", (stats["charter"] as? [String:Any])?["genesis_is_final"] as? Bool == true else { throw NSError(domain:"Mainnet genesis is not final on this explorer",code:1) }
                let genesis = try await get(p["explorer",default:""] + "/api/block/0")
                guard let time = genesis["time"] as? Int, time > 0 else { throw NSError(domain:"Missing mainnet genesis time",code:1) }
                args += ["--base",String(time)]
            } catch { emit(["type":"error","message":error.localizedDescription]); return }
        }
        guard process == nil, profile == p else { return }
        if (try? await get("http://127.0.0.1:47476/health", local:true)) != nil { emit(["type":"error","message":"MMM stats port 47476 is already in use. Stop the other MMM session first."]); return }
        guard process == nil, profile == p else { return }
        let task = Process(); task.executableURL = Bundle.main.url(forResource:"NerdMiner",withExtension:nil); task.arguments = args
        let input = Pipe(); task.standardInput = input
        args += ["--password-stdin"]; task.arguments = args
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data:data,encoding:.utf8) else { return }
            let clean = text.components(separatedBy:"\n").filter { !$0.contains("Companion token:") }.joined(separator:"\n")
            DispatchQueue.main.async { self?.emit(["type":"log","message":String(clean.suffix(3000))]) }
        }
        task.terminationHandler = { [weak self] task in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self?.process = nil; if let activity = self?.miningActivity { ProcessInfo.processInfo.endActivity(activity); self?.miningActivity = nil }; self?.emit(["type":"stopped","code":task.terminationStatus]) }
        }
        do { try task.run(); input.fileHandleForWriting.write(Data((password + "\n").utf8)); try? input.fileHandleForWriting.close(); process = task; miningActivity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"MMM background mining"); emit(["type":"started"]); refreshMiner(); refresh() }
        catch { emit(["type":"error","message":error.localizedDescription]) }
    }
    // Sign in to MineDifferent with the bundled engine: `NerdMiner login` mints a
    // challenge, the wallet CLI signs it with key index 101 (the forum identity),
    // and we open the one-time link it prints. The passphrase travels only over
    // the child's stdin, and only if the wallet actually asks for one.
    func forumLogin(passphrase: String, remember: Bool) {
        guard loginProcess == nil else { return }
        let task = Process()
        task.executableURL = Bundle.main.url(forResource: "NerdMiner", withExtension: nil)
        task.arguments = ["login", "--no-open", "--passphrase-stdin"]
        let input = Pipe(), pipe = Pipe()
        task.standardInput = input; task.standardOutput = pipe; task.standardError = pipe
        var buffer = ""
        var opened = false
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            buffer += text
            var link: String? = nil
            if !opened, let r = buffer.range(of: "https://[^\\s]+/l/[0-9a-f]{64}", options: .regularExpression) {
                link = String(buffer[r]); opened = true
            }
            DispatchQueue.main.async {
                self?.emit(["type": "log", "message": String(text.suffix(3000))])
                if let link, let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                    self?.emit(["type": "loginStatus", "state": "ok", "message": "Signed in — your browser opened the one-time login link."])
                }
            }
        }
        task.terminationHandler = { [weak self] t in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.loginProcess = nil
                if t.terminationStatus != 0 {
                    self?.emit(["type": "loginStatus", "state": "fail", "message": "Sign-in failed — the engine log below has the exact error."])
                } else {
                    if !opened { self?.emit(["type": "loginStatus", "state": "ok", "message": "Signed in."]) }
                    // remember only a passphrase that just proved itself
                    if remember, !passphrase.isEmpty, (try? ForumCredential.save(passphrase)) != nil {
                        self?.emit(["type": "forumCred", "saved": true])
                    }
                }
            }
        }
        do {
            try task.run()
            input.fileHandleForWriting.write(Data((passphrase + "\n").utf8))
            try? input.fileHandleForWriting.close()
            loginProcess = task
            emit(["type": "loginStatus", "state": "running", "message": "Signing the forum challenge with this Mac's wallet key…"])
        } catch { emit(["type": "loginStatus", "state": "fail", "message": error.localizedDescription]) }
    }
    func showFullWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows flag:Bool) -> Bool { showFullWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification:Notification) { timer?.invalidate(); statsTimer?.invalidate(); menuBar?.invalidate(); process?.terminate(); loginProcess?.terminate() }
    @MainActor func refreshMiner() {
        guard let owner = process, !statsBusy else { return }
        statsBusy = true
        Task { @MainActor in
            defer { statsBusy = false }
            do {
                let stats = try await get("http://127.0.0.1:47476/stats",local:true)
                guard process === owner else { return }
                emit(["type":"miner","data":stats])
            } catch {
                guard process === owner else { return }
                emit(["type":"minerPending","message":"Waiting for mining engine statistics…"])
            }
        }
    }
}
func validAddress(_ address:String, hrp:String) -> Bool {
    guard address == address.lowercased() || address == address.uppercased() else { return false }
    let a = address.lowercased(), charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    guard a.hasPrefix(hrp + "1r"), a.count == hrp.count + 60 else { return false }
    let data = Array(a.dropFirst(hrp.count + 1)); var values = [Int]()
    for c in data { guard let n = charset.firstIndex(of:c) else { return false }; values.append(n) }
    guard values[0] == 3, values[52] & 15 == 0 else { return false }
    let expanded = hrp.utf8.map { Int($0 >> 5) } + [0] + hrp.utf8.map { Int($0 & 31) }
    let gen:[UInt32] = [0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; var chk:UInt32 = 1
    for v in expanded + values { let top = chk >> 25; chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v); for i in 0..<5 where (top >> i) & 1 == 1 { chk ^= gen[i] } }
    return chk == 0x2bc830a3
}
func startupSettingsComplete(_ p:[String:String]) -> Bool {
    let hrp = p["network"] == "mainnet" ? "xpa" : "txa"
    guard validAddress(p["address",default:""],hrp:hrp),
          !p["worker",default:""].isEmpty,
          p["host",default:""].range(of:"^[a-zA-Z0-9.-]+$",options:.regularExpression) != nil,
          let port = UInt16(p["port",default:""]), port > 0 else { return false }
    return true
}
@main
struct MMMMain {
    static func main() {
        let delegate = App()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}
