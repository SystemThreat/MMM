import Cocoa
import WebKit
import LocalAuthentication

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
    var statsPort = 47476   // the engine's stats server (a test harness picks its own, never this one)
    var generation = 0
    var profile: [String: String] = ["network":"testnet", "explorer":"https://superknet.com", "host":"", "port":"", "address":"", "worker":"", "mode":"solo"]
    var lastStats: [String: Any] = [:]
    var signalSources: [DispatchSourceSignal] = []
    let page = Bundle.main.resourceURL!.appendingPathComponent("index.html")
    // Request is an idle timeout (reset by every byte); Resource caps the whole
    // exchange, so a slow-drip explorer can't hold busy/walletBusy/launching.
    let session = URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 30; return c }())
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults:["autoStartMining":true])
        if let saved = UserDefaults.standard.dictionary(forKey: "profile") as? [String: String] { profile.merge(saved) { _, new in new } }
        schedule = (UserDefaults.standard.dictionary(forKey: "miningSchedule")).flatMap(MiningSchedule.init) ?? MiningSchedule()
        WalletService.reapOrphans()
        catchQuits()
        lastSendAtLaunch()
        // A passphrase saved before credentials were bound to a file belonged to the default wallet.
        if ForumCredential.file == nil, ForumCredential.exists(), let d = walletFiles().first(where: { $0.isDefault }) { ForumCredential.file = walletFileKey(d.path) }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "native")
        web = PageWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width:1280,height:800)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1240,screen.width-40), height: min(780,screen.height-70)), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "MMM — Nerd Stats Edition"
        window.minSize = NSSize(width: 940, height: 640)
        window.delegate = self; window.isReleasedWhenClosed = false
        window.contentView = web
        window.center(); window.makeKeyAndOrderFront(nil)
        makeMenus()
        loadPage()
        scheduleBegin()
        NSApp.activate(ignoringOtherApps: true)
    }
    func makeMenus() {
        menuBar = MenuBarController()
        menuBar.onShow = { [weak self] in self?.showFullWindow() }
        menuBar.onStop = { [weak self] in self?.manualStop() }
        menuBar.onQuit = { [weak self] in self?.quit(nil) }
        let menu = NSMenu(); let item = NSMenuItem(); menu.addItem(item)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit MMM", action: #selector(quit(_:)), keyEquivalent: "q").target = self; item.submenu = appMenu
        let edit = NSMenuItem(); menu.addItem(edit); let em = NSMenu(title:"Edit"); edit.submenu = em
        for (title, action, key) in [("Copy", "copy:", "c"),("Paste","paste:","v"),("Select All","selectAll:","a"),("Cut","cut:","x")] { em.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        NSApp.mainMenu = menu
    }
    /// Every quit request: ⌘Q, the menu bar's, the quit Apple event (Dock, logout), kill/logout signals.
    /// While a quit waits for a committed send, the rest are ignored: a second terminate: quits at once.
    @objc func quit(_ sender: Any?) {
        guard !quitPending else { showFullWindow(); return }
        NSApp.terminate(sender)
    }
    @objc func quitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) { quit(nil) }
    /// The quit Apple event (replacing AppKit's, so after launch) and kill/pkill/logout signals take
    /// quit(_:), so no card-reader child is orphaned and a committed send finishes first.
    /// Signals are caught (not SIG_IGN): children get the default action back on exec.
    func catchQuits() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
        for sig in [SIGTERM, SIGHUP, SIGINT] {
            signal(sig) { _ in }
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [weak self] in
                WalletService.terminateAll(grace: 1)                       // even if the main thread is stuck
                // a run-loop block, as ⌘Q is: inside a main-queue block AppKit's terminate-later wait
                // could not run the main queue, where the committed send reports
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { self?.quit(nil) }
                CFRunLoopWakeUp(CFRunLoopGetMain())
                DispatchQueue.global().async {
                    // a committed send ends at its exit or its backstop; then the main thread has 5 s to report it and quit
                    while WalletService.committedRunning { usleep(100_000) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { signal(sig, SIG_DFL); kill(getpid(), sig) }
                }
            }
            source.resume(); signalSources.append(source)
        }
    }
    func loadPage() { web.loadFileURL(page, allowingReadAccessTo: Bundle.main.resourceURL!) }
    /// Only the bundled page may load, and only it may talk to the native bridge.
    func isPage(_ url: URL?) -> Bool { url.map { $0.isFileURL && $0.standardizedFileURL.path == page.standardizedFileURL.path } ?? false }
    /// The page's process died (crash, memory pressure): reload it; didFinish restores its state.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loadPage() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        emit(["type":"profile", "data":profile])
        emit(["type":"autoStartPreference","enabled":UserDefaults.standard.bool(forKey:"autoStartMining")])
        emit(["type":"forumCred","saved":ForumCredential.exists()])
        emit(forumState(), menu: false)
        scheduleEmit(force: true)
        if let last = lastSendShown { emitLastSend(last) }
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in Task { @MainActor in self?.refreshMiner() } }
        if let statsTimer { RunLoop.main.add(statsTimer,forMode:.common) }
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        if didAttemptAutoStart {   // a reloaded page starts blank: tell it what the first load was told
            emit(["type":"credential","password":password])
            if process != nil { emit(["type":"started"], menu: false) }
        } else {
            didAttemptAutoStart = true
            Task { @MainActor in
                defer { if let last = lastSendShown { emitLastSend(last) } }   // again after the auto-start's own notices: this one matters more
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
    func emit(_ value: [String: Any], menu: Bool = true) {
        if menu { menuBar?.update(value) }
        // data(withJSONObject:) raises (uncatchable by try?) on NaN/inf; never let it
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let json = String(data:data, encoding:.utf8) else { return }
        web.evaluateJavaScript("window.receive(\(json))", completionHandler:nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isPage(message.frameInfo.request.url), let b = message.body as? [String:Any], let action = b["action"] as? String else { return }
        guard !quitPending || ["copy", "open", "refresh", "walletRefresh", "walletCancel", "forumRefresh"].contains(action) else { return }   // quitting: nothing new starts
        switch action {
        case "save": saveSetup(b)
        case "autoStartPreference":
            guard let enabled = b["enabled"] as? Bool else { return }
            UserDefaults.standard.set(enabled,forKey:"autoStartMining")
            emit(["type":"autoStartPreference","enabled":enabled])
        case "start": Task { await start(user: true) }
        case "login": forumLogin(passphrase: b["passphrase"] as? String ?? "", remember: b["remember"] as? Bool ?? false)
        case "loginTouch": loginTouch()
        case "loginForget":
            ForumCredential.forget()
            emit(["type": "forumCred", "saved": false])
            emit(["type": "loginStatus", "state": "idle", "message": "Saved passphrase removed. Type it to sign in."])
        case "stop": manualStop()
        case "mineAnyway": mineAnyway()
        case "scheduleStay": schedulePaused = false; scheduleEmit(force: true)
        case "schedule": scheduleSave(b)
        case "forumRefresh": emit(forumState(), menu: false)
        case "forumIdentity": forumIdentity(passphrase: b["passphrase"] as? String ?? "")
        case "openForum": NSWorkspace.shared.open(forumURL)
        case "walletQR": walletQR(b)
        case "walletBackup": if let f = b["file"] as? String { walletBackup(file: f) }
        case "walletRefresh": walletRefresh()
        case "walletUnlock": walletUnlock(passphrase: b["passphrase"] as? String ?? "", remember: b["remember"] as? Bool ?? false)
        case "walletSelect": if let f = b["file"] as? String { walletSelect(file: f, index: b["index"] as? Int) }
        case "walletCancel": walletCancel()
        case "walletLock": walletLock()
        case "nuke": nukeInputs()
        case "walletCreate":
            walletCreate(name: b["name"] as? String ?? "", passphrase: b["passphrase"] as? String ?? "", card: b["card"] as? Bool ?? false)
        case "walletWatchAdd": walletWatch(b["address"] as? String ?? "")
        case "walletWatchRemove":
            if let a = b["address"] as? String {
                var w = UserDefaults.standard.stringArray(forKey: "walletWatched") ?? []
                w.removeAll { $0 == a }
                UserDefaults.standard.set(w, forKey: "walletWatched")
                walletRefresh()
            }
        case "walletBrowse": Task { @MainActor in walletBrowse() }
        case "walletSend":
            guard let dest = b["dest"] as? String, let amount = b["amount"] as? String else { return }
            walletSend(dest: dest, amount: amount, formPass: b["passphrase"] as? String ?? "")
        case "refresh": refresh(); refreshMiner()
        case "minimize": window.miniaturize(nil)
        case "copy": if let s = b["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType:.string) }
        case "open": if let url = explorerLink(b) { NSWorkspace.shared.open(url) }
        default: break
        }
    }
    func saveSetup(_ b: [String: Any]) {
        guard process == nil, let p = b["profile"] as? [String:String] else { return }
        guard !walletBusy else {   // the network and explorer stay those of the running action and its receipt
            emit(["type":"setupRequired","message":"A wallet action is running. Let it finish (or CANCEL it), then save the setup."]); return
        }
        let submittedPassword = b["password"] as? String ?? ""
        var nextProfile = profile; nextProfile.merge(p) { _,new in new }
        do { try PoolCredential.save(submittedPassword,profile:nextProfile) }
        catch { emit(["type":"setupRequired","message":error.localizedDescription]); return }
        password = submittedPassword
        profile.merge(p) { _, new in new }; generation += 1; lastStats = [:]
        UserDefaults.standard.set(profile, forKey:"profile"); emit(["type":"reset"]); menuBar.update(["type":"profile","data":profile]); refresh()
        if b["startAfterSave"] as? Bool == true { Task { await start(user: true) } }
    }
    /// The page's explorer link. A receipt names the explorer its send used: only the
    /// configured one, or one a send (or the last session's) used, is taken.
    func explorerLink(_ b: [String: Any]) -> URL? {
        let origin = b["origin"] as? String, base = origin ?? profile["explorer"] ?? ""
        guard let path = b["path"] as? String, origin == nil || origin == profile["explorer"] || explorersUsed.contains(base) else { return nil }
        return explorerURL(base, path)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) { decisionHandler(isPage(navigationAction.request.url) ? .allow : .cancel) }
    func get(_ url: String, local: Bool = false) async throws -> [String:Any] {
        guard let u = URL(string:url), ["https","http"].contains(u.scheme ?? "") else { throw NSError(domain:"Invalid endpoint URL",code:1) }
        var r = URLRequest(url:u)
        if local { r.setValue("GUI", forHTTPHeaderField:"X-NerdMiner-MD") }
        let (d,response) = try await session.data(for:r)
        // isValidJSONObject: the parser turns -1e309 into -inf, which emit could never send on
        guard (response as? HTTPURLResponse)?.statusCode == 200, let j = try JSONSerialization.jsonObject(with:d) as? [String:Any], JSONSerialization.isValidJSONObject(j) else { throw NSError(domain:"Endpoint did not return valid JSON",code:1) }
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
                if let height = stats["height"] as? Int, height >= 0 {   // height-7 must not overflow
                    var blocks = [[String:Any]]()
                    for h in stride(from:height, through:max(0,height-7), by:-1) {
                        if let block = try? await get(origin + "/api/block/\(h)") { blocks.append(block) }
                    }
                    if generation == revision { emit(["type":"blocks","data":blocks]) }
                }
            } catch { if generation == revision { lastStats = [:]; emit(["type":"offline","message":error.localizedDescription]) } }
        }
    }
    /// Every engine start: auto-start, a schedule resume, START (`user`), MINE ANYWAY. While the
    /// schedule holds mining (and MINE ANYWAY did not override that hold) it is held, not started.
    @MainActor func start(user: Bool = false) async {
        guard process == nil, !launching, !quitPending else { return }   // quitting: a committed send or card write is finishing
        if let hold = scheduleHoldNow(), scheduleOverride != hold.code {
            schedulePaused = true; scheduleReason = hold.reason
            scheduleEmit(event: user ? "blocked" : "paused"); return
        }
        launching = true; defer { launching = false }
        let p = profile, address = p["address",default:""]
        let isTest = p["network"] == "testnet"
        guard validAddress(address, hrp:isTest ? "txa" : "xpa") else { emit(["type":"error","message":"Enter a valid witness v3 \(isTest ? "txa1r" : "xpa1r") payout address with a correct bech32m checksum."]); return }
        let host = p["host",default:""]
        guard !host.isEmpty, host.range(of: "^[a-zA-Z0-9.-]+$", options: .regularExpression) != nil, let port = UInt16(p["port",default:""]), port > 0, !p["worker",default:""].isEmpty else { emit(["type":"error","message":"Enter an IP address or hostname, port (1–65535), and worker name."]); return }
        var args = [address,"--pool",host + ":" + String(port),"--worker",p["worker",default:""],"--mode",p["mode"] == "shared" ? "shared":"solo","--stats-port",String(statsPort)]
        if !isTest {
            do {
                let stats = try await get(p["explorer",default:""] + "/api/stats")
                guard stats["hrp"] as? String == "xpa", (stats["charter"] as? [String:Any])?["genesis_is_final"] as? Bool == true else { throw NSError(domain:"Mainnet genesis is not final on this explorer",code:1) }
                let genesis = try await get(p["explorer",default:""] + "/api/block/0")
                guard let time = genesis["time"] as? Int, time > 0 else { throw NSError(domain:"Missing mainnet genesis time",code:1) }
                args += ["--base",String(time)]
            } catch { emit(["type":"error","message":error.localizedDescription]); return }
        }
        // each wait above and below is a chance for a quit to have begun (a committed send finishing): launch nothing then
        guard process == nil, profile == p, !quitPending else { return }
        if (try? await get("http://127.0.0.1:\(statsPort)/health", local:true)) != nil { emit(["type":"error","message":"MMM stats port \(statsPort) is already in use. Stop the other MMM session first."]); return }
        guard process == nil, profile == p, !quitPending else { return }
        // a bundle without its engine: say so (a Process with no launch path would raise and end MMM)
        guard let engine = Bundle.main.url(forResource:"NerdMiner",withExtension:nil) else { emit(["type":"error","message":"The mining engine is missing from MMM.app. Reinstall MMM, then start again."]); return }
        let task = Process(); task.executableURL = engine; task.arguments = args
        let input = Pipe(); task.standardInput = input
        args += ["--password-stdin"]; task.arguments = args
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        let lines = EngineLines(), eof = DispatchSemaphore(value: 0)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; eof.signal(); return }
            DispatchQueue.main.async { if let text = lines.take(data) { self?.emit(["type":"log","message":String(text.suffix(3000))]) } }
        }
        task.terminationHandler = { [weak self] task in
            _ = eof.wait(timeout: .now() + 1)   // the last line (the exit reason) is logged before "stopped"
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                if let text = lines.take(Data(), flush: true) { self?.emit(["type":"log","message":String(text.suffix(3000))]) }
                self?.process = nil; if let activity = self?.miningActivity { ProcessInfo.processInfo.endActivity(activity); self?.miningActivity = nil }
                var stopped: [String: Any] = ["type":"stopped","code":task.terminationStatus]
                if let reason = lines.lastError { stopped["reason"] = reason }
                self?.emit(stopped)
                self?.scheduleEngineEnded()
            }
        }
        do { try task.run(); input.fileHandleForWriting.write(Data((password + "\n").utf8)); try? input.fileHandleForWriting.close(); process = task; miningActivity = ProcessInfo.processInfo.beginActivity(options:[.userInitiated,.idleSystemSleepDisabled],reason:"MMM background mining"); emit(["type":"started"]); refreshMiner(); refresh() }
        catch { emit(["type":"error","message":error.localizedDescription]) }
    }
    /// RESET: forget everything MMM remembers — saved passphrase, wallet
    /// selections, custom paths, watched addresses, mining setup, pool
    /// password — as if freshly installed. Wallet FILES are never touched.
    @MainActor func nukeInputs() {
        guard process == nil, !launching else {
            emit(["type": "error", "message": "Stop mining first — the reset clears the mining setup."]); return
        }
        guard !walletBusy, loginProcess == nil else {
            emit(["type": "error", "message": "Wait for the current wallet action to finish, then reset."]); return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset MMM to a fresh start?"
        alert.informativeText = """
        Clears: the saved wallet passphrase (Touch ID), wallet file and key-index selections, custom wallet paths, watched addresses, the mining setup (payout address, pool, worker), the mining schedule, the saved pool password, the auto-start choice, and the remembered forum identity and sign-in time.

        Not touched: your wallet files in ~/.xcoin and ~/.dex-wallet, and your coins. Nothing on-chain changes.
        """
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // main-actor work keeps running inside the modal loop: a start may have finished meanwhile
        guard process == nil, !launching, !walletBusy, loginProcess == nil else {
            emit(["type": "error", "message": "Mining or a wallet action started while the reset dialog was open. Stop it first, then reset."]); return
        }

        ForumCredential.forget()
        PoolCredential.forgetAll()
        for key in ["profile", "autoStartMining", "walletFile", "walletIndexByFile", "walletAddrByFile",
                    "walletAddrByFile2", "walletCarriedByFile2",
                    "walletPassByFile", "walletCustomPaths", "walletWatched",
                    "miningSchedule", "forumIdByFile", "forumLastSignIn",
                    "walletAddress", "walletHasPassphrase"] {          // last two: keys from earlier builds
            UserDefaults.standard.removeObject(forKey: key)
        }
        profile = ["network":"testnet", "explorer":"https://superknet.com", "host":"", "port":"", "address":"", "worker":"", "mode":"solo"]
        password = ""; generation += 1; lastStats = [:]
        schedule = MiningSchedule(); schedulePaused = false; scheduleOverride = nil; cardStatusCache = [:]
        emit(["type": "reset"])
        emit(["type": "nuked"])
        emit(["type": "profile", "data": profile])
        emit(["type": "credential", "password": ""])
        emit(["type": "forumCred", "saved": false])
        emit(["type": "loginStatus", "state": "idle"])
        emit(forumState(), menu: false)
        scheduleEmit(force: true)
        emit(["type": "autoStartPreference", "enabled": UserDefaults.standard.bool(forKey: "autoStartMining")])
        menuBar.update(["type": "profile", "data": profile])
        refresh()
        walletRefresh()
        emit(["type": "setupRequired", "message": "MMM was reset to a fresh start. Your wallet files were not touched. Enter a payout address and pool to mine again."])
    }

    // ── WALLET tab: balances via the explorer, sends via the wallet CLI ──────
    // The GUI never touches a key. Balances are public reads of the explorer's
    // /api/utxos; unlock and send shell out to the wallet CLI (whose offline
    // keytool signs) against WHICHEVER wallet file the user selected — the
    // standard ~/.xcoin candidates, the dex-wallet-era files, or a custom path.
    // Card wallets (XCOINMMM5, and card-kind v2/v3/v4) additionally wait for
    // the NTAG 424 NFC tap inside the CLI; the status line says so.
    var walletBusy = false
    func walletHrp() -> String { profile["network"] == "mainnet" ? "xpa" : "txa" }

    struct WalletFile { let name: String; let path: String; let format: String; let card: Bool; let isDefault: Bool }
    /// First bytes tell the format: "XCOINMMM<v>\n" then (v4) a kind byte.
    func sniffFormat(_ path: String) -> (String, Bool) {
        guard let fh = FileHandle(forReadingAtPath: path) else { return ("unreadable", false) }
        let head = (try? fh.read(upToCount: 12)) ?? Data()
        try? fh.close()
        guard head.count >= 10, let magic = String(data: head.prefix(10), encoding: .ascii), magic.hasPrefix("XCOINMMM") else {
            return (path.hasSuffix(".seed") ? "seed" : "unknown", false)
        }
        let v = String(magic.dropFirst(8).prefix(1))
        let card = v == "2" || v == "3" || v == "5" || (v == "4" && head.count > 10 && (head[10] == 2 || head[10] == 3))
        return ("mmm" + v, card)
    }
    /// Every wallet file we can offer: ~/.xcoin (with the CLI's default
    /// precedence), the dex-wallet era's ~/.dex-wallet, then custom paths.
    func walletFiles() -> [WalletFile] {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        var out: [WalletFile] = []; var seen = Set<String>()
        let xcoin = home.appendingPathComponent(".xcoin")
        let xmmms = ((try? fm.contentsOfDirectory(atPath: xcoin.path)) ?? []).filter { $0.hasSuffix(".mmm") }.sorted()
        var defaultPath = ""
        if xmmms.contains("wallet.mmm") { defaultPath = xcoin.appendingPathComponent("wallet.mmm").path }
        else if let first = xmmms.first { defaultPath = xcoin.appendingPathComponent(first).path }
        else if fm.fileExists(atPath: xcoin.appendingPathComponent("wallet.seed").path) { defaultPath = xcoin.appendingPathComponent("wallet.seed").path }
        for dir in [".xcoin", ".dex-wallet"] {
            let d = home.appendingPathComponent(dir)
            var names = ((try? fm.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.hasSuffix(".mmm") }.sorted()
            if fm.fileExists(atPath: d.appendingPathComponent("wallet.seed").path) { names.append("wallet.seed") }
            for n in names {
                let path = d.appendingPathComponent(n).path
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                let (fmt, card) = sniffFormat(path)
                out.append(WalletFile(name: dir == ".xcoin" ? n : dir + "/" + n, path: path, format: fmt, card: card, isDefault: path == defaultPath))
            }
        }
        for path in UserDefaults.standard.stringArray(forKey: "walletCustomPaths") ?? [] where fm.fileExists(atPath: path) && !seen.contains(path) {
            seen.insert(path)
            let (fmt, card) = sniffFormat(path)
            out.append(WalletFile(name: (path as NSString).abbreviatingWithTildeInPath, path: path, format: fmt, card: card, isDefault: path == defaultPath))
        }
        return out
    }
    func selectedWallet() -> WalletFile? {
        let files = walletFiles()
        if let want = UserDefaults.standard.string(forKey: "walletFile"), !want.isEmpty,
           let f = files.first(where: { $0.path == want }) { return f }
        return files.first(where: { $0.isDefault }) ?? files.first
    }
    /// v2 caches: the CLI's primary address became the standard two-leaf tree
    /// (ML-DSA + SLH-DSA fallback); the single-leaf form is "carried".
    func walletAddrCache() -> [String: String] { (UserDefaults.standard.dictionary(forKey: "walletAddrByFile2") as? [String: String]) ?? [:] }
    func walletCarriedCache() -> [String: String] { (UserDefaults.standard.dictionary(forKey: "walletCarriedByFile2") as? [String: String]) ?? [:] }
    func walletPassCache() -> [String: Bool] { (UserDefaults.standard.dictionary(forKey: "walletPassByFile") as? [String: Bool]) ?? [:] }
    /// The selected key index, remembered per wallet file (0 = payment key,
    /// 101 = the forum-identity convention; any uint32 derives a real key).
    func walletIndex(for path: String) -> Int {
        ((UserDefaults.standard.dictionary(forKey: "walletIndexByFile") as? [String: Int]) ?? [:])[path] ?? 0
    }
    func setWalletIndex(_ idx: Int, for path: String) {
        var d = (UserDefaults.standard.dictionary(forKey: "walletIndexByFile") as? [String: Int]) ?? [:]
        d[path] = max(0, idx)
        UserDefaults.standard.set(d, forKey: "walletIndexByFile")
    }
    /// A wallet file's identity: path + inode + birth time. A file deleted and
    /// re-created, or rewritten by the CLI (encrypt replaces it), is a new
    /// identity, so nothing cached or saved for the old one applies to it.
    func walletFileKey(_ path: String) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let birth = Int((((a[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1e6).rounded())
        return path + "#" + String((a[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0) + "." + String(birth)
    }
    /// Derived-address cache key: one address per (file identity, network, index).
    func walletAddrKey(_ path: String, _ idx: Int) -> String { walletFileKey(path) + "#" + walletHrp() + "#" + String(idx) }
    /// Only the v5 one-file card format must have a passphrase; v2 cards and v1 files may have none.
    func passphraseRequired(_ f: WalletFile?) -> Bool { f?.format == "mmm5" }
    /// The saved Touch ID passphrase stands in only for the default wallet file it was verified against.
    func credUsable(_ f: WalletFile?) -> Bool { guard let f, f.isDefault else { return false }; return ForumCredential.file == walletFileKey(f.path) && ForumCredential.exists() }

    func walletState() -> [String: Any] {
        let files = walletFiles(), sel = selectedWallet()
        let selPath = sel?.path ?? ""
        let selIdx = walletIndex(for: selPath)
        let hasPass = walletPassCache()[walletFileKey(selPath)] ?? passphraseRequired(sel)
        let credUsable = self.credUsable(sel)
        return ["payout": profile["address"] ?? "",
                "walletAddress": walletAddrCache()[walletAddrKey(selPath, selIdx)] ?? "",
                "walletCarried": walletCarriedCache()[walletAddrKey(selPath, selIdx)] ?? "",
                "selectedIndex": selIdx,
                "wallets": files.map { ["name": $0.name, "file": $0.path, "format": $0.format, "card": $0.card, "default": $0.isDefault, "selected": $0.path == selPath] },
                "selected": selPath,
                "selectedCard": sel?.card ?? false,
                "selectedIsDefault": sel?.isDefault ?? false,
                "needsPassphraseEntry": hasPass && !credUsable,
                "credSaved": ForumCredential.exists(),
                "watched": (UserDefaults.standard.stringArray(forKey: "walletWatched") ?? []).filter { $0.hasPrefix(walletHrp() + "1") },
                "backup": backupState(sel),
                "cliFound": WalletService.cliPath() != nil]
    }
    var walletGen = 0
    /// Spendable and immature sums of an /api/utxos reply, or nil when an amount
    /// is missing or outside 0...MAX_MONEY or a sum overflows: shown as unavailable.
    func utxoSums(_ u: [String: Any]) -> (spendable: Int, immature: Int)? {
        var s = 0, i = 0
        for x in (u["utxos"] as? [[String: Any]] ?? []) {
            guard let sats = x["amount_sats"] as? Int, (0...21_000_000 * 100_000_000).contains(sats) else { return nil }
            if (x["immature"] as? Bool) == true { guard let t = sum(i, sats) else { return nil }; i = t }
            else { guard let t = sum(s, sats) else { return nil }; s = t }
        }
        return (s, i)
    }
    @MainActor func walletRefresh() {
        walletGen += 1
        let gen = walletGen
        var state = walletState()
        let sel = selectedWallet()
        if let sel { cardStatusRefresh(sel) }
        let origin = profile["explorer"] ?? ""
        Task { @MainActor in
            var balances: [String: Any] = [:]
            var seen = Set<String>()
            var lookups: [String] = []
            for key in ["payout", "walletAddress"] { if let a = state[key] as? String { lookups.append(a) } }
            lookups += (state["watched"] as? [String]) ?? []
            for addr in lookups {
                guard !addr.isEmpty, !seen.contains(addr) else { continue }
                seen.insert(addr)
                if let u = try? await get(origin + "/api/utxos/" + addr), let t = utxoSums(u) {
                    balances[addr] = ["spendable_sats": t.spendable, "immature_sats": t.immature, "height": u["height"] ?? 0]
                }
            }
            if let main = state["walletAddress"] as? String, !main.isEmpty,
               let carried = state["walletCarried"] as? String, !carried.isEmpty, carried != main {
                if let u = try? await get(origin + "/api/utxos/" + carried), let c = utxoSums(u) {
                    if var row = balances[main] as? [String: Any] {
                        if let s = sum((row["spendable_sats"] as? Int) ?? 0, c.spendable), let i = sum((row["immature_sats"] as? Int) ?? 0, c.immature), let t = sum(c.spendable, c.immature) {
                            row["spendable_sats"] = s; row["immature_sats"] = i; row["carried_sats"] = t
                            balances[main] = row
                        } else { balances.removeValue(forKey: main) }
                    }
                } else {
                    // Half a balance must never look like the whole: show it as unavailable.
                    balances.removeValue(forKey: main)
                }
            }
            guard gen == walletGen else { return }   // a newer refresh (other file, NUKE…) superseded this one
            state["balances"] = balances
            state["backup"] = backupState(sel)   // card-status may have answered while the explorer did
            walletSpendable = balances.compactMapValues { ($0 as? [String: Any])?["spendable_sats"] as? Int }
            emit(["type": "wallet", "data": state])
        }
    }
    func walletWatch(_ raw: String) {
        let a = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard validAddress(a, hrp: walletHrp()) else {   // not any wallet action's status
            emit(["type": "error", "message": "Not a valid \(walletHrp())1r… address to watch."], menu: false); return
        }
        var w = UserDefaults.standard.stringArray(forKey: "walletWatched") ?? []
        if !w.contains(a) { w.append(a) }
        UserDefaults.standard.set(w, forKey: "walletWatched")
        walletRefresh()
    }
    func walletSelect(file: String, index: Int? = nil) {
        guard walletFiles().contains(where: { $0.path == file }) else { return }
        UserDefaults.standard.set(file, forKey: "walletFile")
        if let index { setWalletIndex(index, for: file) }
        Task { @MainActor in walletRefresh() }
    }
    @MainActor func walletBrowse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xcoin")
        panel.message = "Choose a wallet file (.mmm, or a legacy .seed)"
        panel.begin { [weak self] resp in
            guard let self, resp == .OK, let url = panel.url else { return }
            var custom = UserDefaults.standard.stringArray(forKey: "walletCustomPaths") ?? []
            if !custom.contains(url.path) { custom.append(url.path) }
            UserDefaults.standard.set(custom, forKey: "walletCustomPaths")
            UserDefaults.standard.set(url.path, forKey: "walletFile")
            Task { @MainActor in self.walletRefresh() }
        }
    }
    // One wallet action at a time. walletOp numbers it; a CANCEL before its CLI starts
    // bumps it, so that action's late callbacks (Touch ID, balance/explorer check) do nothing.
    // A running CLI is stopped instead, and its own exit reports what happened.
    var walletOp = 0
    var walletJob: WalletService.Job?
    var walletSentIds: [String] = []           // what the running send's backend accepted: honest if it dies midway
    var walletTxTotal = 0
    var walletCommitted = false                // broadcast-begin seen: no CANCEL from here
    var walletCancelling = false               // CANCEL stopped the CLI; its exit reports
    var walletWritten = false                  // a card read after card-provisioning: the card write finished
    var walletSpendable: [String: Int] = [:]   // address → spendable sats (carried included), last refresh
    var walletCardSeen = false                 // this action waited for or read a card
    var walletSendFrom = (address: "", explorer: "")
    var walletRejected: (i: Int, n: Int, reason: String)?   // the network ANSWERED no to transaction i of n (XCOIN-EVENT rejected)
    var explorersUsed = Set<String>()          // explorers sends used (or the last session's did): receipt links may open them
    var quitReply: (() -> Void)?               // a quit waiting for the committed send to be reported
    var quitPending = false                    // set with quitReply, never cleared: MMM is quitting
    var lastSendShown: [String: Any]?          // the last session's send, reported at page load until a new send starts
    /// A send past broadcast-begin (or a backup card past card-provisioning) not reported yet (its exit may still be queued).
    var sendCommitted: Bool { walletBusy && (walletCommitted || walletJob?.isCommitted == true) }
    /// Touch ID of one caller. Sign-in and sends each have their own, so one's prompt
    /// never drops or dismisses the other's pending approval.
    final class AuthGate {
        private(set) var op = 0
        var ctx: LAContext?
        var pending: Bool { ctx != nil }
        func next() -> Int { op += 1; return op }
        /// Dismiss the pending prompt and drop its answer; true if one was up.
        @discardableResult func dismiss() -> Bool { op += 1; let had = ctx; ctx = nil; had?.invalidate(); return had != nil }
    }
    let walletAuth = AuthGate(), loginAuth = AuthGate()
    /// A card action may take the CLI's card-wait budget plus 90 s, then it is stopped (never after broadcast-begin).
    var cardTimeout: TimeInterval { TimeInterval(cardWaitBudget(ProcessInfo.processInfo.environment) + 90) }
    func walletBegin() -> Int {
        walletBusy = true; walletOp += 1; walletJob = nil; walletSentIds = []; walletTxTotal = 0; walletCommitted = false; walletCancelling = false; walletCardSeen = false; walletRejected = nil
        walletBackingUp = false; walletSwapSeen = false; walletNewCard = false; walletWritten = false
        return walletOp
    }
    /// Every wallet action ends here: not busy, no child, the banner closed as `phase`.
    func walletFinish(_ phase: String, _ extra: [String: Any] = [:]) { walletBusy = false; walletJob = nil; emit(["type": "cardPrompt", "phase": phase].merging(extra) { $1 }) }
    func walletFail(_ message: String) { walletFinish("failed"); emit(["type": "walletStatus", "state": "fail", "message": message]) }
    func walletCancelled(_ message: String = "Cancelled.") { walletFinish("cancelled"); emit(["type": "walletStatus", "state": "fail", "message": message]) }
    func cliFailure(_ r: WalletService.CLIResult, _ fallback: String) -> String {
        let text = cliErrorText(r.stderr, fallback: fallback)
        return r.timedOut ? "The wallet CLI did not finish in time and was stopped. " + text : text
    }
    /// A stderr line of action `op`: XCOIN-EVENT lines drive the page's banner. Read until
    /// the CLI exits, CANCEL or not: a broadcast it reports is part of the final report.
    func walletProgress(_ line: String, op: Int) {
        guard op == walletOp, walletBusy else { return }
        if let r = cliRejected(line) { walletRejected = r; return }   // certain: refused, not lost; the exit reports it
        guard let e = cliEvent(line, budget: cardWaitBudget(ProcessInfo.processInfo.environment)) else { return }
        var prompt = e.prompt
        if walletBackingUp || walletNewCard { prompt = backupPrompt(prompt) }
        let phase = prompt["phase"] as? String, locks = phase == "broadcasting" || phase == "provisioning"   // from here CANCEL is refused
        if let n = prompt["n"] as? Int { walletTxTotal = max(walletTxTotal, n) }
        if phase == "tap" || phase == "retry" || prompt["cardRead"] != nil { walletCardSeen = true }
        if phase == "retry" { walletJob?.extend(by: TimeInterval(cardWaitBudget(ProcessInfo.processInfo.environment))) }   // the CLI waits for the card again, a whole budget
        if phase == "signing", prompt["i"] != nil, walletCardSeen { prompt["card"] = true }   // "keep the card on the reader" only after a card wait
        if locks, !walletCommitted { walletCommitted = true; if !walletBackingUp, !walletNewCard { walletSendNote(["committed": true]) } }
        if let t = e.txid, !walletSentIds.contains(t) { walletSentIds.append(t); walletSendNote(["txids": walletSentIds]) }
        if locks, quitPending { prompt["quitting"] = true }
        if !walletCancelling || locks { emit(prompt) }   // after CANCEL only a broadcast (or a card write) still shows
    }
    /// A card write's events on the banner (a backup card, or a new card wallet's card): after
    /// card-swap, or for a new wallet, a tap is for a blank card; from card-provisioning on every
    /// prompt is the write, CANCEL locked until the end. A card read after it: the write is done.
    func backupPrompt(_ p: [String: Any]) -> [String: Any] {
        let phase = p["phase"] as? String
        if phase == "swap" { walletSwapSeen = true }
        if walletCommitted || phase == "provisioning" {
            if walletCommitted, p["cardRead"] != nil { walletWritten = true }
            return ["type": "cardPrompt", "phase": "provisioning", "written": walletWritten, "new": walletNewCard]
        }
        var q = p
        if phase == "tap", walletSwapSeen || walletNewCard { q["blank"] = true }
        return q
    }
    /// A card write that stopped with SIGTERM before any card read after card-provisioning died in
    /// the CLI's pause: from the pause's end until the write is done the CLI ignores SIGTERM (only
    /// SIGKILL stops it there), so the card was never written.
    func cardWriteUnstarted(_ r: WalletService.CLIResult) -> Bool { walletCommitted && !walletWritten && r.signal == SIGTERM }
    /// The banner of a committed action: its CANCEL stays locked until the action ends.
    func walletLockedPrompt() -> [String: Any] {
        walletBackingUp || walletNewCard ? ["type": "cardPrompt", "phase": "provisioning", "quitting": quitPending, "new": walletNewCard]
            : ["type": "cardPrompt", "phase": "broadcasting", "n": walletTxTotal, "i": walletSentIds.count, "quitting": quitPending]
    }
    /// Touch ID through `gate`, announced on the banner; CANCEL dismisses the system prompt.
    func approve(_ reason: String, gate: AuthGate, _ done: @escaping (Bool, String?) -> Void) {
        let mine = gate.next()
        emit(["type": "cardPrompt", "phase": "touchid"])
        var answered = false   // no Touch ID on this Mac: answered before authenticate returns
        let ctx = ForumCredential.authenticate(reason: reason) { ok, why in
            answered = true
            guard mine == gate.op else { return }   // dismissed
            gate.ctx = nil
            done(ok, why)
        }
        if !answered, mine == gate.op { gate.ctx = ctx }
    }
    /// CANCEL. Before the CLI starts (Touch ID, balance or explorer check): ends the send,
    /// nothing signed. While it runs: stops its whole process tree, and its exit reports what
    /// actually happened. From broadcast-begin on: refused, the result follows at its exit.
    @MainActor func walletCancel() {
        guard walletBusy else {
            // no wallet action: the banner can only be a sign-in's Touch ID prompt, or stale
            let dismissed = loginAuth.dismiss()
            emit(["type": "cardPrompt", "phase": dismissed ? "cancelled" : "done"])
            if dismissed { emit(["type": "loginStatus", "state": "fail", "message": "Sign-in cancelled."]) }
            return
        }
        // stopping a broadcast could hide whether a transaction went out
        let refuse = { self.emit(self.walletLockedPrompt()) }
        if walletCommitted { refuse(); return }
        guard let job = walletJob else {
            walletAuth.dismiss(); walletOp += 1
            walletCancelled("Cancelled — nothing was sent."); return
        }
        guard job.cancel() else { refuse(); return }   // committed on the reader thread; its event is on the way
        walletCancelling = true
    }
    /// LOCK: forget the address derived for this file, network and key index, so
    /// the unlock form (and its card tap) is back. No restart; nothing else is forgotten.
    @MainActor func walletLock() {
        guard !walletBusy, let sel = selectedWallet() else { return }
        let key = walletAddrKey(sel.path, walletIndex(for: sel.path))
        for name in ["walletAddrByFile2", "walletCarriedByFile2"] {
            if var d = UserDefaults.standard.dictionary(forKey: name) { d.removeValue(forKey: key); UserDefaults.standard.set(d, forKey: name) }
        }
        emit(["type": "walletLocked"])
        walletRefresh()
    }
    /// Create a wallet in ~/.xcoin through the CLI. Normal wallets get a
    /// one-time seed reveal for the paper backup; card wallets never reveal a
    /// seed by design (the backup is a duplicate card via `card-backup`).
    func walletCreate(name rawName: String, passphrase: String, card: Bool) {
        guard !walletBusy else {
            emit(["type": "error", "message": "Another wallet action is still running — wait for it to finish, then create."], menu: false); return
        }
        var name = rawName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "wallet.mmm" }
        if !name.hasSuffix(".mmm") { name += ".mmm" }
        guard name.range(of: "^[A-Za-z0-9._-]{1,60}$", options: .regularExpression) != nil, !name.hasPrefix(".") else {
            emit(["type": "walletStatus", "state": "fail", "message": "Wallet names are plain: letters, digits, dot, dash, underscore."]); return
        }
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xcoin").appendingPathComponent(name).path
        guard !FileManager.default.fileExists(atPath: path) else {
            emit(["type": "walletStatus", "state": "fail", "message": "\(name) already exists — pick another name."]); return
        }
        if card, passphrase.isEmpty {
            emit(["type": "walletStatus", "state": "fail", "message": "A card wallet needs a passphrase (it guards the card keys)."]); return
        }
        let op = walletBegin(); walletNewCard = card
        let keysBefore = card ? cardKeyFiles() : []
        emit(["type": "walletStatus", "state": "working",
              "message": card ? "Provisioning — when asked, tap and HOLD the NEW card on the reader…" : "Creating \(name)…"])
        var args = ["--json", "--file", path, "new", "--offline"]
        if card { args.append("--card") }
        walletJob = WalletService.run(args, passphrase: passphrase, timeout: card ? cardTimeout : 120,
                                      progress: { [weak self] line in self?.walletProgress(line, op: op) }) { [weak self] r in
            guard let self, op == self.walletOp else { return }
            guard r.code == 0, WalletService.json(r)?["file"] != nil else {
                if card { self.walletNewCardFailed(r, newKeys: self.cardKeyFiles().subtracting(keysBefore), path: path, name: name) }
                else if self.walletCancelling { self.walletCancelled() } else { self.walletFail(self.cliFailure(r, "Could not create the wallet.")) }
                self.quitIfReported()
                return
            }
            // a new file at a used path: drop everything cached for the one it replaced
            for key in ["walletAddrByFile2", "walletCarriedByFile2", "walletPassByFile"] {
                if let d = UserDefaults.standard.dictionary(forKey: key) { UserDefaults.standard.set(d.filter { !$0.key.hasPrefix(path + "#") }, forKey: key) }
            }
            UserDefaults.standard.set(path, forKey: "walletFile")
            self.setWalletIndex(0, for: path)
            var passes = self.walletPassCache(); passes[self.walletFileKey(path)] = !passphrase.isEmpty || card
            UserDefaults.standard.set(passes, forKey: "walletPassByFile")
            if card {
                let late = self.walletCancelling ? "The cancel came too late: the new card was already being written, and it finished. " : ""
                self.walletFinish("done")
                self.emit(["type": "walletStatus", "state": "ok",
                           "message": late + "Card wallet created — the seed is sealed to the card and never shown. Make a backup card now. Unlock to derive its address (another tap)."])
                self.emit(["type": "walletCardCreated", "name": name, "file": path], menu: false)
                self.walletRefresh()
                self.quitIfReported()
                return
            }
            // one-time seed reveal for the paper backup, then derive the address
            self.walletJob = WalletService.run(["--json", "--file", path, "seed", "--yes", "--no-clear"], passphrase: passphrase, timeout: 60) { r2 in
                guard op == self.walletOp else { return }
                guard r2.code == 0, let seed = WalletService.json(r2)?["seed"] as? String else {
                    // Keep this warning on screen: no automatic unlock whose own status could replace it.
                    self.walletFail("Wallet created, but the seed reveal failed — run `xcoin-wallet-cli --file ~/.xcoin/\(name) seed` in Terminal to back it up NOW.")
                    return
                }
                self.walletFinish("done")
                self.emit(["type": "walletSeed", "name": name, "seed": seed])
                self.walletUnlock(passphrase: passphrase, remember: false)
            }
        }
    }
    /// A card wallet's creation that did not finish. What happened to the new card: a key file the
    /// CLI saved during this run (it saves one before it changes the card's keys) or a write that
    /// began (card-provisioning, unless it stopped in the CLI's pause) means it may be part-way set
    /// up; the CLI's own words say so when it knows. The wallet file at `path` (it did not exist
    /// before) is written only once the card is set up: if it is there, the wallet was created and
    /// only the run's last step (sealing the card, the final report) did not confirm.
    func walletNewCardFailed(_ r: WalletService.CLIResult, newKeys: Set<String>, path: String, name: String) {
        if FileManager.default.fileExists(atPath: path) {
            let why = walletCancelling ? "Cancelled as the new card was being finished." : cliFailure(r, "The new card wallet did not report finishing.")
            walletFail(why + "\n\(name) was saved, so the new card was set up, but its last step did not confirm. Before you use \(name), UNLOCK it with the new card to check that the card opens it.")
            walletRefresh()
            return
        }
        let touched = !newKeys.isEmpty || (walletCommitted && !cardWriteUnstarted(r))
        if walletCancelling, !touched {
            walletCancelled(walletCommitted ? "Cancelled — no wallet was created, and nothing was written to the new card." : "Cancelled — no wallet was created."); return
        }
        var why = walletCancelling ? "Cancelled." : cliFailure(r, "Could not create the wallet.")
        if !touched, walletCommitted { why += " It stopped before the write began: nothing was written to the new card." }
        if touched, !why.lowercased().contains("do not rely on that card") {
            let uids = newKeys.sorted().map { String($0.dropFirst("card-".count).dropLast(".auth".count)) }
            why += "\nNo wallet was created, but the new card" + (uids.isEmpty ? "" : " (UID " + uids.joined(separator: ", ") + ")") + " was part-way set up: do not rely on that card."
        }
        walletFail(why)
    }
    /// Names of this Mac's card key files (~/.xcoin/card-<UID>.auth): names only, never opened.
    func cardKeyFiles() -> Set<String> {
        let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xcoin")
        return Set(((try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []).filter { $0.range(of: "^card-[0-9A-Fa-f]{2,64}\\.auth$", options: .regularExpression) != nil })
    }
    func walletUnlock(passphrase: String, remember: Bool) {
        guard !walletBusy, let sel = selectedWallet() else { return }
        if passphraseRequired(sel), passphrase.isEmpty {
            emit(["type": "walletStatus", "state": "fail", "message": "This card wallet's passphrase is required (it guards the card keys in the file)."]); return
        }
        // keys fixed now: the network or the file may change while the CLI runs
        let idx = walletIndex(for: sel.path), fileKey = walletFileKey(sel.path), addrKey = walletAddrKey(sel.path, idx)
        let op = walletBegin()
        emit(["type": "walletStatus", "state": "working",
              "message": sel.card ? "Unlocking — tap your xCoin card on the NFC reader when prompted…" : "Unlocking the wallet…"])
        walletJob = WalletService.run(["--json", "--hrp", walletHrp(), "--file", sel.path, "address", "--index", String(idx)],
                                      passphrase: passphrase, timeout: sel.card ? cardTimeout : 180,
                                      progress: { [weak self] line in self?.walletProgress(line, op: op) }) { [weak self] r in
            guard let self, op == self.walletOp else { return }
            guard r.code == 0, let d = WalletService.json(r), let addr = d["address"] as? String else {
                if self.walletCancelling { self.walletCancelled() } else { self.walletFail(self.cliFailure(r, "Could not unlock \(sel.name) — is one set up? Run `xcoin-wallet-cli new`.")) }
                return
            }
            var addrs = self.walletAddrCache(); addrs[addrKey] = addr
            UserDefaults.standard.set(addrs, forKey: "walletAddrByFile2")
            if let carried = d["carried_address"] as? String {
                var c = self.walletCarriedCache(); c[addrKey] = carried
                UserDefaults.standard.set(c, forKey: "walletCarriedByFile2")
            }
            var passes = self.walletPassCache(); passes[fileKey] = !passphrase.isEmpty
            UserDefaults.standard.set(passes, forKey: "walletPassByFile")
            if remember, !passphrase.isEmpty, sel.isDefault {
                try? ForumCredential.save(passphrase, file: fileKey)
                self.emit(["type": "forumCred", "saved": ForumCredential.exists()])   // the SETUP tab shares this credential
            }
            self.walletFinish("done")
            self.emit(["type": "walletStatus", "state": "ok", "message": "Wallet unlocked."])
            self.walletRefresh()
        }
    }
    func walletSend(dest: String, amount: String, formPass: String) {
        guard !walletBusy, let sel = selectedWallet() else { return }
        let hrp = walletHrp()
        guard validAddress(dest, hrp: hrp) else {
            emit(["type": "walletStatus", "state": "fail", "message": "The destination is not a valid witness v3 \(hrp)1r… address."]); return
        }
        guard let amt = Double(amount), amt.isFinite, amt > 0 else {
            emit(["type": "walletStatus", "state": "fail", "message": "Enter an amount above zero."]); return
        }
        let origin = profile["explorer"] ?? ""
        let credUsable = self.credUsable(sel)
        let hasPass = walletPassCache()[walletFileKey(sel.path)] ?? passphraseRequired(sel)
        // A passphrase-protected wallet needs the passphrase from somewhere:
        // the send form's field, or (default wallet only) the saved credential.
        if hasPass, formPass.isEmpty, !credUsable {
            emit(["type": "walletStatus", "state": "fail",
                  "message": "Type this wallet's passphrase in the send form (only the default wallet can use the saved Touch ID passphrase)."]); return
        }
        let idx = walletIndex(for: sel.path)   // the key named in the prompt is the key that signs
        let addrKey = walletAddrKey(sel.path, idx), addr = walletAddrCache()[addrKey] ?? "", carried = walletCarriedCache()[addrKey] ?? ""
        let op = walletBegin()
        // Touch ID (or the Mac password) approves EVERY send, saved passphrase or not;
        // the prompt shows the whole destination, so a look-alike can't pass for it.
        let authorize = { [weak self] in
            guard let self else { return }
            self.emit(["type": "walletStatus", "state": "working", "message": "Waiting for Touch ID…"])
            self.approve("send \(amount) XCF to \(dest.lowercased()) from \(sel.name), key index \(idx)", gate: self.walletAuth) { [weak self] ok, why in
                guard let self, op == self.walletOp else { return }
                guard ok else { self.walletFail(why ?? "Touch ID failed."); return }
                let pw = !formPass.isEmpty ? formPass : (credUsable ? ((try? ForumCredential.load()) ?? "") : "")
                self.emit(["type": "cardPrompt", "phase": "signing"])   // until the CLI reports its card wait
                self.emit(["type": "walletStatus", "state": "working",
                           "message": sel.card ? "Signing — tap your xCoin card on the NFC reader…" : "Signing offline and broadcasting…"])
                Task { @MainActor in
                    // Never sign against an explorer serving a different chain.
                    if let stats = try? await self.get(origin + "/api/stats"), let ehrp = stats["hrp"] as? String, ehrp != hrp {
                        guard op == self.walletOp else { return }
                        self.walletFail("The explorer is serving a different network — fix the explorer URL in SETUP."); return
                    }
                    guard op == self.walletOp else { return }   // cancelled during the explorer check
                    self.walletSendRun(["--json", "--explorer", origin, "--hrp", hrp, "--file", sel.path, "send", dest, amount, "--index", String(idx), "--split", "--yes"],
                                       passphrase: pw, card: sel.card, op: op, from: addr, explorer: origin)
                }
            }
        }
        // More than the balance on screen: refused before Touch ID and the tap, but only if a
        // fresh read agrees (coins may have arrived since); an unreadable one leaves it to the CLI.
        guard let want = sats(xcf: amount), let cached = walletSpendable[addr], want >= cached else { authorize(); return }
        emit(["type": "walletStatus", "state": "working", "message": "Checking the balance…"])
        Task { @MainActor in
            let fresh = await self.freshSpendable(addr, carried: carried, origin: origin)
            guard op == self.walletOp else { return }   // cancelled meanwhile
            if let fresh {
                self.walletSpendable[addr] = fresh
                if want >= fresh {
                    self.walletFinish("done")
                    self.emit(["type": "walletStatus", "state": "fail", "message": want > fresh
                        ? "\(amount) XCF is more than this wallet's spendable balance (\(xcfText(fresh)) XCF at key index \(idx)). Nothing was signed."
                        : "\(amount) XCF is this wallet's whole spendable balance — leave room for the network fee. Nothing was signed."])
                    return
                }
            }
            authorize()
        }
    }
    /// Spendable sats of a key's two-leaf and carried addresses, read now; nil if a read fails.
    func freshSpendable(_ addr: String, carried: String, origin: String) async -> Int? {
        var total = 0
        for a in carried.isEmpty || carried == addr ? [addr] : [addr, carried] {
            guard let u = try? await get(origin + "/api/utxos/" + a), let t = utxoSums(u), let s = sum(total, t.spendable) else { return nil }
            total = s
        }
        return total
    }
    /// --split plans a large payment as several transactions, all signed after ONE
    /// unlock (one tap). A CLI too old for it rejects the flag before any card wait.
    func walletSendRun(_ args: [String], passphrase: String, card: Bool, op: Int, from address: String = "", explorer: String = "") {
        let events = args.contains("--split")
        lastSendShown = nil; walletSendFrom = (address, explorer); explorersUsed.insert(explorer)
        // kept from the start: MMM may die mid-broadcast; a CLI without events may broadcast at any time
        UserDefaults.standard.set(["time": Date().timeIntervalSince1970, "address": address, "explorer": explorer, "committed": !events, "txids": [String]()], forKey: "walletLastSend")
        walletJob = WalletService.run(args, passphrase: passphrase, timeout: card ? cardTimeout : 180,
                                      progress: { [weak self] line in self?.walletProgress(line, op: op) }) { [weak self] r in
            guard let self, op == self.walletOp else { return }
            if r.code == 2, !self.walletCancelling, events, r.stderr.contains("unrecognized arguments: --split") {
                self.walletSendRun(args.filter { $0 != "--split" }, passphrase: passphrase, card: card, op: op, from: address, explorer: explorer); return
            }
            self.walletSendDone(r, events: events)
            self.quitIfReported()
        }
    }
    func walletSendNote(_ changes: [String: Any]) {
        var d = UserDefaults.standard.dictionary(forKey: "walletLastSend") ?? [:]
        d.merge(changes) { $1 }
        UserDefaults.standard.set(d, forKey: "walletLastSend")
    }
    /// The outcome, kept as soon as it is known: a quit may follow at once.
    func walletSendOutcome(_ outcome: String, _ message: String, txids: [String] = [], receipt: [String: Any]? = nil) {
        var o: [String: Any] = ["outcome": outcome, "message": message, "txids": txids, "partial": outcome == "partial",
                                "unsent_txids": receipt?["unsent_txids"] ?? [String](), "done": Date().timeIntervalSince1970, "quit": quitPending]
        if let receipt { o["receipt"] = receipt }
        walletSendNote(o)
    }
    /// At launch: a send MMM died during (committed, no outcome) is reported on every launch
    /// until the next send; one that ended while MMM was quitting, once.
    func lastSendAtLaunch() {
        guard let last = UserDefaults.standard.dictionary(forKey: "walletLastSend") else { return }
        // Any send whose CLI started but whose outcome never got recorded: even before broadcast-begin
        // was read, the line may have reached the pipe just before MMM died and the orphan went on.
        let unreported = last["outcome"] == nil
        guard unreported || (last["quit"] as? Bool == true && last["outcome"] as? String != "sent") else { return }
        lastSendShown = last
        if let e = last["explorer"] as? String { explorersUsed.insert(e) }
        if !unreported { walletSendNote(["quit": false]) }
    }
    func emitLastSend(_ last: [String: Any]) {
        let addr = last["address"] as? String ?? ""
        guard last["outcome"] != nil else {
            emit(["type": "sendInterrupted", "address": addr, "explorer": last["explorer"] ?? "", "txids": last["txids"] ?? [String](),
                  "message": (last["committed"] as? Bool == true
                      ? "MMM was closed while a send was broadcasting. Check this wallet on the explorer before sending again."
                      : "MMM was closed while a send was being prepared. It most likely did not go out, but check this wallet on the explorer before sending again.")
                      + (addr.isEmpty ? "" : "\nWallet: " + addr)], menu: false)
            return
        }
        if var r = last["receipt"] as? [String: Any] { r["type"] = "walletSent"; r["relaunch"] = true; emit(r, menu: false) }
        emit(["type": "error", "message": "MMM quit as its last send ended: " + (last["message"] as? String ?? "")], menu: false)
    }
    /// The deferred quit goes on once the committed send is reported and recorded.
    func quitIfReported() {
        guard let reply = quitReply, !sendCommitted else { return }
        quitReply = nil; reply()
    }
    /// Report exactly what went out, CANCEL or not: every txid the CLI (or, if it died, its
    /// broadcast events) reported; for a partial send how many of how many, why, and the
    /// txid whose broadcast result is unknown. "Nothing was sent" only before broadcast-begin
    /// of a CLI that reports it (`events`: one too old for --split reports nothing).
    func walletSendDone(_ r: WalletService.CLIResult, events: Bool = true) {
        let json = WalletService.json(r), d = json ?? [:], out = (d["broadcast"] as? Bool) == true
        var txids = out ? (d["txids"] as? [String]) ?? (d["txid"] as? String).map { [$0] } ?? [] : []
        if txids.isEmpty { txids = walletSentIds }   // no JSON: what the backend had accepted, per event
        let total = max((d["transactions"] as? Int) ?? walletTxTotal, txids.count, 1)
        let complete = r.code == 0 && out && (d["partial"] as? Bool) != true && txids.count >= total
        let failure = r.code == 0 ? "The send did not complete." : cliFailure(r, "The send did not complete.")
        // no JSON, no "error:" line: the CLI never said how it ended (backstop, crash, a lost cancel race); its prompts are no answer
        let silent = json == nil && !r.stderr.contains("error: ")
        let unknown = " — MMM cannot tell whether " + (txids.isEmpty ? "a transaction" : "any other transaction") + " went out. Check this wallet on the explorer before sending again."
        defer { walletRefresh() }
        guard !txids.isEmpty else {
            if walletCancelling, !walletCommitted, events {
                walletSendOutcome("cancelled", "Cancelled — nothing was sent."); walletCancelled("Cancelled — nothing was sent."); return
            }
            // the explorer or node answered with a refusal and nothing went out: the first transaction's (explorer or node), or on
            // the node path a later one's in the check before any broadcast. The CLI emits "rejected" only when nothing was sent,
            // and says why in plain words
            if let rj = walletRejected, r.code != 0 {
                let message = refusedText(r.stderr)
                let receipt: [String: Any] = ["type": "walletSent", "txids": [String](), "transactions": rj.n, "partial": false, "explorer": walletSendFrom.explorer,
                                              "refused": ["i": rj.i, "n": rj.n, "reason": rj.reason], "message": message]
                walletSendOutcome("refused", message, receipt: receipt)
                walletFinish("failed", ["refused": true])
                emit(receipt)
                emit(["type": "walletStatus", "state": "fail", "message": message])
                return
            }
            // stopped after broadcast-begin, or a CLI that never says how far it got: nothing is known either way
            let began = events ? " after its broadcast began" : ""
            let message = silent && (walletCommitted || walletCancelling || !events)
                ? (walletCancelling ? "Cancelled" + (events ? " as the broadcast began" : "") : r.timedOut ? "The wallet CLI did not finish in time and was stopped" + began : "The send stopped" + began) + unknown
                : failure
            walletSendOutcome("failed", message); walletFail(message)
            return
        }
        let why = (d["broadcast_error"] as? String).map(plainBroadcastError) ?? (silent ? (r.timedOut ? "the wallet CLI did not finish in time and was stopped" : "the wallet CLI stopped without a final report") + unknown : failure)
        walletFinish(complete ? "done" : "failed")
        var sent: [String: Any] = ["type": "walletSent", "txid": txids[0], "txids": txids, "transactions": total, "partial": !complete, "explorer": walletSendFrom.explorer,
                                   "amount": d["amount"] as? String ?? "", "fee": d["fee"] as? String ?? "", "vsize": d["vsize"] as? Int ?? 0, "change": d["change"] as? String ?? ""]
        // refused: the network answered no to the next one, so it (and the rest) certainly did not go out; else the first unsent is unknown
        // (the event, or a CLI that marks the partial send's JSON broadcast_rejected instead)
        let refused = complete ? nil : walletRejected.flatMap { $0.i == txids.count + 1 ? $0 : nil }
            ?? ((d["broadcast_rejected"] as? Bool) == true ? (i: txids.count + 1, n: total, reason: "refused") : nil)
        if !complete {
            sent["broadcast_error"] = why
            if let u = d["unsent_txids"] as? [String], !u.isEmpty { sent["unsent_txids"] = u }   // the first: result unknown, unless refused
            if let rj = refused { sent["refused"] = ["i": rj.i, "n": rj.n, "reason": rj.reason] }
        }
        let message = complete ? (walletCancelling ? "The cancel came too late: sent." : "Sent.")
            : refused.map { "Sent \(txids.count) of \(total) transactions. The network refused transaction \($0.i), so it was not sent" + ($0.i < total ? ", and the rest were never broadcast" : "") + ": \(why)" }
            ?? "Sent \(txids.count) of \(total) transactions: \(why)"
        walletSendOutcome(complete ? "sent" : "partial", message, txids: txids, receipt: sent)
        if complete { emit(["type": "walletStatus", "state": "ok", "message": message]) }
        emit(sent)
        if !complete { emit(["type": "walletStatus", "state": "fail", "message": message]) }
    }

    /// SETUP's Touch ID sign-in with the saved passphrase.
    func loginTouch() {
        // the banner and the card reader belong to a running wallet action
        guard !walletBusy else {
            emit(["type": "loginStatus", "state": "fail", "message": "A wallet action is running (it may be waiting for Touch ID or your card). Let it finish or CANCEL it, then sign in."]); return
        }
        guard !loginAuth.pending else { return }   // its prompt is already up
        // sign with the file the saved passphrase belongs to, not whatever is default now
        let bound = ForumCredential.file, wallet = walletFiles().first { walletFileKey($0.path) == bound }?.path
        if bound != nil, wallet == nil {
            emit(["type": "loginStatus", "state": "fail", "message": "The saved passphrase belongs to a wallet file that has since changed or moved. Type the passphrase to sign in, or Forget the saved one."]); return
        }
        approve("sign in to MineDifferent with your saved wallet passphrase", gate: loginAuth) { [weak self] ok, why in
            guard let self else { return }
            if !self.walletBusy { self.emit(["type": "cardPrompt", "phase": ok ? "done" : "failed"]) }   // else a send started since owns the banner
            if ok, let pw = try? ForumCredential.load() { self.forumLogin(passphrase: pw, remember: false, wallet: wallet) }
            else { self.emit(["type": "loginStatus", "state": "fail", "message": why ?? "Touch ID failed."]) }
        }
    }
    // Sign in to MineDifferent with the bundled engine: `NerdMiner login` mints a
    // challenge, the wallet CLI signs it with key index 101 (the forum identity),
    // and we open the one-time link it prints. The passphrase travels only over
    // the child's stdin, and only if the wallet actually asks for one.
    func forumLogin(passphrase: String, remember: Bool, wallet: String? = nil) {
        guard loginProcess == nil else { return }
        let signer = wallet ?? walletFiles().first(where: { $0.isDefault })?.path   // the file NerdMiner signs with
        let task = Process()
        task.executableURL = Bundle.main.url(forResource: "NerdMiner", withExtension: nil)
        task.arguments = ["login", "--no-open", "--passphrase-stdin"] + (wallet.map { ["--wallet", $0] } ?? [])
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
                self?.emit(["type": "log", "source": "login", "message": String(text.suffix(3000))])
                if let link, let url = URL(string: link) {
                    NSWorkspace.shared.open(url)
                    self?.forumSignedIn()
                    self?.emit(["type": "loginStatus", "state": "ok", "message": "Signed in — your browser opened the one-time login link."])
                }
            }
        }
        task.terminationHandler = { [weak self] t in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.loginProcess = nil
                if t.terminationStatus != 0 {
                    self?.emit(["type": "loginStatus", "state": "fail", "message": "Sign-in failed — the engine log (SETUP tab) has the exact error."])
                } else {
                    if !opened { self?.forumSignedIn(); self?.emit(["type": "loginStatus", "state": "ok", "message": "Signed in."]) }
                    // remember only a passphrase that just proved itself
                    if remember, !passphrase.isEmpty, let signer, (try? ForumCredential.save(passphrase, file: self?.walletFileKey(signer) ?? "")) != nil {
                        self?.emit(["type": "forumCred", "saved": true])
                    }
                }
            }
        }
        do {
            try WalletService.launch(task)   // tracked: its wallet CLI child may be waiting on the card
            input.fileHandleForWriting.write(Data((passphrase + "\n").utf8))
            try? input.fileHandleForWriting.close()
            loginProcess = task
            emit(["type": "loginStatus", "state": "running", "message": "Signing the forum challenge with this Mac's wallet key…"])
        } catch { emit(["type": "loginStatus", "state": "fail", "message": error.localizedDescription]) }
    }
    // ── FORUM tab: the forum identity (key index 101) and the last sign-in ──
    let forumURL = URL(string: "https://minedifferent.com")!
    /// The wallet the forum signs with: the one the saved passphrase is bound to, else the default.
    func forumWallet() -> WalletFile? {
        let files = walletFiles()
        if let bound = ForumCredential.file, ForumCredential.exists(), let f = files.first(where: { walletFileKey($0.path) == bound }) { return f }
        return files.first(where: { $0.isDefault })
    }
    func forumIdCache() -> [String: String] { (UserDefaults.standard.dictionary(forKey: "forumIdByFile") as? [String: String]) ?? [:] }
    func forumState(_ state: String = "idle") -> [String: Any] {
        let f = forumWallet()
        return ["type": "forumIdentity", "state": state, "wallet": f?.name ?? "", "card": f?.card ?? false,
                "xid": f.flatMap { forumIdCache()[walletFileKey($0.path)] } ?? "", "last": UserDefaults.standard.double(forKey: "forumLastSignIn")]
    }
    func forumSignedIn() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "forumLastSignIn")
        emit(forumState(), menu: false)
    }
    /// SHOW MY IDENTITY: `identity --index 101` of the forum wallet, run as a wallet action (card
    /// tap and CANCEL on the banner). The saved passphrase is read only after Touch ID. Cached per file identity.
    @MainActor func forumIdentity(passphrase typed: String) {
        guard !walletBusy else {
            emit(["type": "error", "message": "A wallet action is running (it may be waiting for Touch ID or your card). Let it finish or CANCEL it, then show your identity."], menu: false); return
        }
        guard let f = forumWallet() else { emit(["type": "error", "message": "No wallet file found — create one in NEW WALLET first."], menu: false); return }
        let key = walletFileKey(f.path)
        if forumIdCache()[key] != nil { emit(forumState(), menu: false); return }
        let saved = typed.isEmpty && ForumCredential.exists() && ForumCredential.file == key
        let hasPass = walletPassCache()[key] ?? passphraseRequired(f)
        if hasPass, typed.isEmpty, !saved {
            emit(["type": "error", "message": "\(f.name) has a passphrase: type it in the passphrase field, then SHOW MY IDENTITY."], menu: false); return
        }
        let op = walletBegin()
        emit(["type": "walletStatus", "state": "working", "message": f.card ? "Reading your forum identity — tap your xCoin card when asked…" : "Reading your forum identity…"])
        emit(forumState("working"), menu: false)
        let run = { [weak self] (pw: String) in
            guard let self else { return }
            self.walletJob = WalletService.run(["--json", "--hrp", self.walletHrp(), "--file", f.path, "identity", "--index", "101"], passphrase: pw, timeout: f.card ? self.cardTimeout : 120,
                                               progress: { [weak self] line in self?.walletProgress(line, op: op) }) { [weak self] r in
                guard let self, op == self.walletOp else { return }
                guard r.code == 0, let xid = WalletService.json(r)?["identity"] as? String, validIdentity(xid) else {
                    if self.walletCancelling { self.walletCancelled() } else { self.walletFail(self.cliFailure(r, "Could not read the forum identity of \(f.name).")) }
                    self.emit(self.forumState(), menu: false); return
                }
                var ids = self.forumIdCache(); ids[key] = xid
                UserDefaults.standard.set(ids, forKey: "forumIdByFile")
                self.walletFinish("done")
                self.emit(["type": "walletStatus", "state": "ok", "message": "Forum identity read."])
                self.emit(self.forumState(), menu: false)
                self.walletRefresh()
            }
        }
        guard saved, hasPass else { run(typed); return }
        approve("show your forum identity (key index 101 of \(f.name)) with your saved wallet passphrase", gate: walletAuth) { [weak self] ok, why in
            guard let self, op == self.walletOp else { return }
            guard ok, let pw = try? ForumCredential.load() else { self.walletFail(why ?? "The saved passphrase could not be read."); self.emit(self.forumState(), menu: false); return }
            self.emit(["type": "cardPrompt", "phase": "signing"])   // until the CLI reports a card wait
            run(pw)
        }
    }

    // ── WALLET tab: RECEIVE — a payment request drawn as a QR here (CoreImage), no network ──
    func walletQR(_ b: [String: Any]) {
        let address = (b["address"] as? String ?? "").lowercased(), amount = b["amount"] as? String ?? ""
        var reply: [String: Any] = ["type": "walletQR", "address": address, "seq": b["seq"] as? Int ?? 0]
        if let uri = paymentURI(address, amount: amount, hrp: walletHrp()), let qr = qrPNG(uri) {
            reply["uri"] = uri; reply["png"] = qr.dataURL; reply["modules"] = qr.modules
        } else {
            reply["error"] = validAddress(address, hrp: walletHrp()) ? "Amount: above 0, at most 21,000,000, up to 8 decimals, with a dot (e.g. 1.5)." : "Not a \(walletHrp())1r… address of this network."
        }
        emit(reply, menu: false)
    }

    // ── Backup cards: card-status (no tap) for the WALLET header; MAKE BACKUP CARD ──
    var cardStatusCache: [String: [String: Any]] = [:]   // file identity → card-status, typed
    var cardStatusRunning = Set<String>()
    var walletBackingUp = false                          // the running wallet action is card-backup
    var walletSwapSeen = false                           // …past card-swap: a tap is for the blank card
    var walletNewCard = false                            // the running wallet action is new --card (its card write commits like a backup's)
    func backupState(_ f: WalletFile?) -> [String: Any] { f.flatMap { $0.card ? cardStatusCache[walletFileKey($0.path)] : nil } ?? [:] }
    func cardStatusRefresh(_ f: WalletFile) {
        let key = walletFileKey(f.path)
        guard f.card, !quitPending, WalletService.cliPath() != nil, cardStatusRunning.insert(key).inserted else { return }
        WalletService.run(["--json", "--file", f.path, "card-status"], passphrase: "", timeout: 30) { [weak self] r in
            guard let self else { return }
            self.cardStatusRunning.remove(key)
            let info = cardStatusInfo(r.code == 0 ? WalletService.json(r) : nil, format: f.format)
            self.cardStatusCache[key] = info
            if let sel = self.selectedWallet(), self.walletFileKey(sel.path) == key { self.emit(["type": "walletBackup", "file": f.path, "data": info], menu: false) }
        }
    }
    /// MAKE BACKUP CARD: Touch ID, then `card-backup --auto-swap`: the wallet card is read, swapped
    /// on the reader for a blank one, and a copy written and sealed. CANCEL until card-provisioning;
    /// from then on the write is committed like a broadcast: no CANCEL, no timeout, quits wait for it.
    @MainActor func walletBackup(file: String) {
        guard !walletBusy else {
            emit(["type": "error", "message": "Another wallet action is still running — wait for it to finish, then make the backup card."], menu: false); return
        }
        guard let f = walletFiles().first(where: { $0.path == file }), f.card else { return }
        guard f.format == "mmm2" else {
            emit(["type": "error", "message": "\(f.name) is a dex-wallet-era card wallet: make its backup cards with dex-wallet-cli."], menu: false); return
        }
        let op = walletBegin(); walletBackingUp = true
        emit(["type": "walletStatus", "state": "working", "message": "Backup card for \(f.name): approve with Touch ID…"])
        approve("make a backup card for \(f.name) — its card key is copied to a new blank card", gate: walletAuth) { [weak self] ok, why in
            guard let self, op == self.walletOp else { return }
            guard ok else { self.walletFail(why ?? "Touch ID failed."); return }
            self.walletBackupRun(f, op: op)
        }
    }
    func walletBackupRun(_ f: WalletFile, op: Int) {
        emit(["type": "cardPrompt", "phase": "signing"])   // until the CLI reports its card wait
        emit(["type": "walletStatus", "state": "working", "message": "Backup card: tap and hold your wallet card, then swap it for a new blank card when the banner says so…"])
        let budget = cardWaitBudget(ProcessInfo.processInfo.environment)   // three waits: the wallet card, its removal, the blank card
        walletJob = WalletService.run(["--json", "--file", f.path, "card-backup", "--auto-swap"], passphrase: "", timeout: TimeInterval(3 * budget + 90),
                                      progress: { [weak self] line in self?.walletProgress(line, op: op) }) { [weak self] r in
            guard let self, op == self.walletOp else { return }
            self.walletBackupDone(r, f)
            self.quitIfReported()
        }
    }
    func walletBackupDone(_ r: WalletService.CLIResult, _ f: WalletFile) {
        defer { walletRefresh() }
        let d = WalletService.json(r) ?? [:]
        guard r.code == 0, d["ok"] as? Bool == true else {
            let unstarted = !walletCommitted || cardWriteUnstarted(r)   // a cancel (or quit, or timeout) that crossed card-provisioning stopped it in the pause
            if walletCancelling, unstarted { walletCancelled("Cancelled — nothing was written to a new card."); return }
            let why = walletCancelling ? "Cancelled as the write began." : cliFailure(r, "The backup card was not made.")
            if !walletCommitted { walletFail(why) }
            else if unstarted { walletFail(why + " It stopped before the write began: nothing was written to the new card.") }
            else { walletFail(why.lowercased().contains("do not rely on that card") ? why : why + "\nThe write did not finish cleanly: do not rely on that card. Make another backup with a fresh blank card.") }
            return
        }
        let n = d["cards"] as? Int, uid = d["card_uid"] as? String ?? ""
        let late = walletCancelling ? "The cancel came too late: the write had already begun, and it finished. " : ""
        walletFinish("done")
        let message = late + "Backup card written ✓" + (uid.isEmpty ? "" : " (UID \(uid))") + (n.map { " — \($0) cards now open \(f.name)." } ?? ".") + " Keep it apart from your wallet card."
        emit(["type": "walletStatus", "state": "ok", "message": message])
        emit(["type": "walletBackupDone", "file": f.path, "cards": n ?? 0, "message": message], menu: false)
    }

    // ── Mining schedule (SETUP): holds and resumes the engine; never undoes a manual STOP ──
    var schedule = MiningSchedule()
    var schedulePaused = false         // MMM would mine but the schedule holds it: resumed when allowed
    var scheduleStopping = false       // the schedule is stopping the engine
    var scheduleOverride: String?      // MINE ANYWAY: the hold it overrode, until the schedule's verdict changes
    var scheduleReason = ""
    var scheduleTimer: Timer?
    var scheduleSent = ""
    var scheduleSensors: () -> ScheduleSensors = { readScheduleSensors() }   // a test harness feeds its own
    func scheduleHoldNow() -> (code: String, reason: String)? { scheduleHold(schedule, scheduleSensors()) }
    func scheduleBegin() {
        scheduleTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in Task { @MainActor in self?.scheduleTick() } }
        if let scheduleTimer { RunLoop.main.add(scheduleTimer, forMode: .common) }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.scheduleTick() } }
    }
    @MainActor func scheduleTick() {
        guard !quitPending else { return }   // quitting: the quit stopped the engine; nothing restarts it while a committed action finishes
        let hold = scheduleHoldNow()
        if let hold { scheduleReason = hold.reason }
        if let o = scheduleOverride, hold?.code != o { scheduleOverride = nil }
        if hold != nil, scheduleOverride == nil, let p = process, !scheduleStopping {
            schedulePaused = true; scheduleStopping = true; p.terminate()   // scheduleEngineEnded reports it
        } else if hold == nil, schedulePaused, process == nil, !launching {
            schedulePaused = false
            scheduleEmit(event: "resumed")
            Task { await start() }   // one attempt per resume, like the auto-start
            return
        }
        scheduleEmit()
    }
    func scheduleEngineEnded() {
        if scheduleStopping { scheduleStopping = false; scheduleEmit(event: "paused") }
        else { schedulePaused = false; scheduleOverride = nil; scheduleEmit() }
    }
    /// STOP (page or menu bar): the schedule drops its wish to mine, so it never restarts this session.
    func manualStop() {
        schedulePaused = false; scheduleStopping = false; scheduleOverride = nil
        process?.terminate(); scheduleEmit()
    }
    @MainActor func mineAnyway() {
        guard process == nil, !launching, !quitPending else { return }
        scheduleOverride = scheduleHoldNow()?.code; schedulePaused = false
        Task { await start(user: true) }
    }
    @MainActor func scheduleSave(_ b: [String: Any]) {
        guard let s = MiningSchedule(b) else {
            emit(["type": "error", "message": "Schedule not saved: idle minutes are 1–120 and the two times must differ (HH:MM)."], menu: false)
            scheduleEmit(force: true); return
        }
        schedule = s; scheduleOverride = nil   // a new schedule ends MINE ANYWAY
        UserDefaults.standard.set(s.dict, forKey: "miningSchedule")
        scheduleTick(); scheduleEmit(event: "saved")
    }
    /// The page's and the menu bar's schedule state: sent when it changes, or with an event.
    func scheduleEmit(event: String? = nil, force: Bool = false) {
        let hold = scheduleHoldNow()?.reason ?? "", reason = schedulePaused ? scheduleReason : ""
        let key = [schedule.mode, String(schedule.idle), schedule.from, schedule.to, String(schedule.hot), String(schedulePaused), reason, hold, String(scheduleOverride != nil)].joined(separator: "|")
        guard force || event != nil || key != scheduleSent else { return }
        scheduleSent = key
        var m: [String: Any] = ["type": "schedule", "data": schedule.dict, "paused": schedulePaused, "reason": reason, "hold": hold, "override": scheduleOverride != nil]
        if let event { m["event"] = event }
        emit(m)
    }
    func showFullWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool { sender.orderOut(nil); return false }
    func applicationShouldHandleReopen(_ sender:NSApplication, hasVisibleWindows flag:Bool) -> Bool { showFullWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    /// Children die first, while the app still runs: each wallet/login child's whole
    /// process tree, SIGKILL for whatever ignores SIGTERM for a second. A committed send is
    /// left to finish (stopping it could hide whether a transaction went out): MMM quits
    /// once it is reported and recorded.
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        process?.terminate(); WalletService.terminateAll(grace: 1)
        guard sendCommitted else { return .terminateNow }
        quitPending = true; quitReply = { sender.reply(toApplicationShouldTerminate: true) }
        emit(walletLockedPrompt(), menu: false)
        menuBar?.update(["type": "error", "message": walletBackingUp ? "Finishing the backup card — MMM quits when it is done." : walletNewCard ? "Finishing the new card — MMM quits when it is done." : "Finishing a broadcast — MMM quits when it is done."])
        showFullWindow()
        return .terminateLater
    }
    func applicationWillTerminate(_ notification:Notification) { timer?.invalidate(); statsTimer?.invalidate(); menuBar?.invalidate(); process?.terminate(); loginProcess?.terminate(); WalletService.terminateAll() }
    @MainActor func refreshMiner() {
        guard let owner = process, !statsBusy else { return }
        statsBusy = true
        Task { @MainActor in
            defer { statsBusy = false }
            do {
                let stats = try await get("http://127.0.0.1:\(statsPort)/stats",local:true)
                guard process === owner else { return }
                emit(["type":"miner","data":stats])
            } catch {
                guard process === owner else { return }
                emit(["type":"minerPending","message":"Waiting for mining engine statistics…"])
            }
        }
    }
}
/// a + b + …, or nil on overflow (Swift traps on it, even in -O builds).
func sum(_ xs: Int...) -> Int? {
    var t = 0
    for x in xs { let r = t.addingReportingOverflow(x); if r.overflow { return nil }; t = r.partialValue }
    return t
}
/// Engine output arrives in pipe-sized chunks that split lines anywhere. Only
/// whole lines are filtered and passed on, so a line split across chunks can't
/// slip part of the companion token past the redaction. Main queue only.
final class EngineLines {
    private var pending = Data()
    private(set) var lastError: String?   // the engine's exit reason, "error: <reason>"
    func take(_ data: Data, flush: Bool = false) -> String? {
        pending.append(data)
        var cut = flush ? pending.endIndex : pending.lastIndex(of: 0x0A).map { pending.index(after: $0) } ?? pending.startIndex
        if cut == pending.startIndex, pending.count > 65536 { cut = pending.endIndex - 256 }   // no newline in 64 KiB: pass it on, keep a tail for the filter
        guard cut > pending.startIndex else { return nil }
        let text = String(decoding: pending[..<cut], as: UTF8.self)
        pending = Data(pending[cut...])
        let kept = text.components(separatedBy: "\n").filter { !$0.contains("Companion token:") }
        if let e = kept.last(where: { $0.hasPrefix("error: ") }) { lastError = String(e.dropFirst(7)) }
        return kept.joined(separator: "\n")
    }
}
/// A file or URL dragged onto the window would replace the bundled page (and
/// inherit the native bridge); such drops are refused. Text drags into fields still work.
final class PageWebView: WKWebView {
    private func loads(_ s: NSDraggingInfo) -> Bool { s.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { loads(s) ? [] : super.draggingEntered(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation { loads(s) ? [] : super.draggingUpdated(s) }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { loads(s) ? false : super.performDragOperation(s) }
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
/// One stderr line of the wallet CLI's XCOIN_EVENTS protocol → the page's cardPrompt,
/// plus the txid a broadcast event reports. Other lines, and "done" (the exit code
/// decides done or failed), → nil.
func cliEvent(_ line: String, budget: Int = 60) -> (prompt: [String: Any], txid: String?)? {
    guard let at = line.range(of: "XCOIN-EVENT ") else { return nil }
    let f = line[at.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
    guard let kind = f.first else { return nil }
    let i = f.count > 1 ? Int(f[1]) : nil, n = f.count > 2 ? Int(f[2]) : nil
    switch kind {
    case "card-wait":
        let s = f.count > 1 ? Double(f[1]).flatMap { $0.isFinite ? Int(min(300, max(1, $0)).rounded()) : nil } : nil
        return (["type": "cardPrompt", "phase": "tap", "seconds": s ?? budget], nil)
    case "card-ok": return (["type": "cardPrompt", "phase": "signing", "cardRead": true], nil)
    case "card-swap": return (["type": "cardPrompt", "phase": "swap"], nil)
    case "card-removed": return (["type": "cardPrompt", "phase": "tap", "blank": true, "seconds": budget], nil)   // the blank card's wait
    case "card-provisioning": return (["type": "cardPrompt", "phase": "provisioning"], nil)
    case "card-retry":   // the reader reset the card during a READ: the CLI reconnects and reads again (never during a write)
        return (["type": "cardPrompt", "phase": "retry", "attempt": max(1, i ?? 1), "seconds": budget], nil)   // it waits for the card again, a whole budget
    case "signing":
        guard let i, let n, i >= 1, i <= n else { return nil }
        return (["type": "cardPrompt", "phase": "signing", "i": i, "n": n], nil)
    case "broadcast-begin":   // i is its n: the send can no longer be cancelled
        guard let i, i >= 1 else { return nil }
        return (["type": "cardPrompt", "phase": "broadcasting", "n": i], nil)
    case "broadcast":
        guard let i, let n, i >= 1, i <= n, f.count > 3, f[3].range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil else { return nil }
        return (["type": "cardPrompt", "phase": "broadcasting", "i": i, "n": n], f[3].lowercased())
    default: return nil
    }
}
/// "XCOIN-EVENT rejected <i> <n> <reason-token>": the explorer or node ANSWERED with a refusal of
/// transaction i of n, so it was not accepted (and nothing after it was broadcast). The token is
/// bounded to plain reason characters; nil for any other line.
func cliRejected(_ line: String) -> (i: Int, n: Int, reason: String)? {
    guard let at = line.range(of: "XCOIN-EVENT rejected ") else { return nil }
    let f = line[at.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
    guard f.count >= 2, let i = Int(f[0]), let n = Int(f[1]), i >= 1, i <= n else { return nil }
    let token = String((f.count > 2 ? f[2] : "").filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.:".contains($0)) }.prefix(64))
    return (i, n, token.isEmpty ? "refused" : token)
}
/// A network reject reason in plain words, as the wallet CLI's reject_plain words it (the caller keeps the raw reason).
func rejectPlain(_ reason: String) -> String {
    let r = reason.lowercased(), has = { (keys: [String]) in keys.contains { r.contains($0) } }
    if has(["txn-mempool-conflict", "insufficient fee", "replacement-failed", "bip125-replacement-disallowed", "too many potential replacements", "replacement-adds-unconfirmed"]) {
        return "these coins are already being spent by an earlier send that has not confirmed yet. Wait for the next block, then send again."
    }
    if has(["missingorspent", "missing-inputs", "inputs missing or spent"]) { return "these coins were already spent." }
    if r.contains("mempool min fee not met") { return "its fee is below what the network accepts right now. Send again with a higher fee." }
    if r.contains("min relay fee not met") { return "its fee is below the network's minimum relay fee. Send again with a higher fee." }
    if r.contains("below-min") || r.hasPrefix("dust") { return "an amount in it is below the network's smallest allowed output (0.00010000 XCF, 10,000 sat)." }
    if has(["bad_hex", "decode failed"]) { return "the transaction could not be read." }
    if has(["too_large", "tx-size"]) { return "the transaction is too large." }
    return "the network refused this transaction."
}
/// A split send's broadcast_error: a later transaction's refusal, which the CLI's JSON carries as
/// "broadcast rejected: <reason>", in plain words with the raw reason in parentheses; other text as it is.
func plainBroadcastError(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines), prefix = "broadcast rejected:"
    guard t.lowercased().hasPrefix(prefix) else { return s }
    let reason = t.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    return reason.isEmpty ? rejectPlain("") : rejectPlain(reason) + " (" + reason + ")"
}
/// A refused send in the CLI's own plain words ("Nothing was sent: …"), whole, without its "error: " prefix.
func refusedText(_ stderr: String) -> String {
    let t = cliErrorText(stderr, fallback: "Nothing was sent: the network refused the transaction.")
    return t.hasPrefix("error: ") ? String(t.dropFirst(7)) : t
}
/// "xcoin:<address>[?amount=<xcf>]": a valid address of `hrp`; the optional amount above 0, at most
/// 21 million, dot decimals, written canonically ("1.50" → "1.5"). nil otherwise.
func paymentURI(_ address: String, amount: String, hrp: String) -> String? {
    guard validAddress(address, hrp: hrp) else { return nil }
    let a = "xcoin:" + address.lowercased(), t = amount.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return a }
    guard let s = sats(xcf: t), s > 0, s <= 21_000_000 * 100_000_000 else { return nil }
    return a + "?amount=" + xcfText(s)
}
/// A forum identity as the CLI prints it: xid1 and bech32 characters.
func validIdentity(_ s: String) -> Bool { s.range(of: "^xid1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{38,90}$", options: .regularExpression) != nil }
/// The WALLET header's backup facts from `card-status --json`, typed and bounded. A CLI without
/// card-status: the fixed answer for a dex-era (mmm5) file, else unknown.
func cardStatusInfo(_ d: [String: Any]?, format: String) -> [String: Any] {
    let text = { (v: Any?, n: Int) in String(((v as? String) ?? (v as? NSNumber)?.stringValue ?? "").prefix(n)) }
    guard let d, let card = d["card"] as? Bool else {
        return format == "mmm5" ? ["card": true, "format": format, "backup_supported": false, "note": "Backups of dex-wallet-era card wallets are made with dex-wallet-cli."]
            : ["card": true, "format": format, "unknown": true]
    }
    var out: [String: Any] = ["card": card, "format": d["format"] is String ? text(d["format"], 16) : format, "backup_supported": d["backup_supported"] as? Bool ?? false, "note": text(d["note"], 600),
                              "cards": ((d["cards"] as? [[String: Any]]) ?? []).prefix(32).map { ["uid": text($0["uid"], 32), "label": text($0["label"], 40), "permanent": $0["permanent"] as? Bool ?? false, "created": text($0["created"], 32)] }]
    if let n = d["count"] as? Int, n >= 0 { out["count"] = n }
    if let f = d["family"] as? String { out["family"] = String(f.prefix(64)) }
    return out
}
/// The CLI's card-wait budget: XCOIN_CARD_TIMEOUT (5…300 s), else 60 s.
func cardWaitBudget(_ env: [String: String]) -> Int {
    env["XCOIN_CARD_TIMEOUT"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { min(300, max(5, $0)) } ?? 60
}
/// A failed CLI run in its own words: stderr without XCOIN-EVENT lines, from its
/// first "error:" line on when it printed one (prompts before it are noise). Whole,
/// not a 300-character tail: the notice scrolls.
func cliErrorText(_ stderr: String, fallback: String) -> String {
    let lines = stderr.components(separatedBy: "\n").filter { !$0.contains("XCOIN-EVENT ") }
    let from = lines.firstIndex { $0.contains("error: ") } ?? 0
    let text = lines[from...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? fallback : text.count > 4000 ? "…" + text.suffix(4000) : text
}
/// An explorer link: `base` an http(s) URL with a host and no user, query or fragment,
/// `path` one of the page's /tx|address|block/<id> links; else nil.
func explorerURL(_ base: String, _ path: String) -> URL? {
    guard let b = URLComponents(string: base), ["http", "https"].contains(b.scheme?.lowercased() ?? ""), !(b.host ?? "").isEmpty,
          b.user == nil, b.password == nil, b.query == nil, b.fragment == nil,
          path.range(of: "^/(tx|address|block)/[0-9A-Za-z]{1,128}$", options: .regularExpression) != nil else { return nil }
    return URL(string: base + path)
}
/// "12.5" → 1_250_000_000, exactly (no floating point); nil for anything else.
func sats(xcf s: String) -> Int? {
    guard !s.isEmpty, s != ".", s.range(of: "^[0-9]{0,8}(\\.[0-9]{0,8})?$", options: .regularExpression) != nil else { return nil }
    let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let frac = parts.count > 1 ? String(parts[1]).padding(toLength: 8, withPad: "0", startingAt: 0) : "0"
    return (Int(parts[0]) ?? 0) * 100_000_000 + (Int(frac) ?? 0)
}
func xcfText(_ sats: Int) -> String {
    let frac = String(format: "%08ld", sats % 100_000_000).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    return String(sats / 100_000_000) + (frac.isEmpty ? "" : "." + frac)
}
@main
struct MMMMain {
    static func main() {
        let delegate = App()
        NSApplication.shared.delegate = delegate
        withExtendedLifetime(delegate) { NSApplication.shared.run() }
    }
}
