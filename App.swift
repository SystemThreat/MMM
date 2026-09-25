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
        NSApp.activate(ignoringOtherApps: true)
    }
    func makeMenus() {
        menuBar = MenuBarController()
        menuBar.onShow = { [weak self] in self?.showFullWindow() }
        menuBar.onStop = { [weak self] in self?.process?.terminate() }
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
        guard !quitPending || ["copy", "open", "refresh", "walletRefresh", "walletCancel"].contains(action) else { return }   // quitting: nothing new starts
        switch action {
        case "save": saveSetup(b)
        case "autoStartPreference":
            guard let enabled = b["enabled"] as? Bool else { return }
            UserDefaults.standard.set(enabled,forKey:"autoStartMining")
            emit(["type":"autoStartPreference","enabled":enabled])
        case "start": Task { await start() }
        case "login": forumLogin(passphrase: b["passphrase"] as? String ?? "", remember: b["remember"] as? Bool ?? false)
        case "loginTouch": loginTouch()
        case "loginForget":
            ForumCredential.forget()
            emit(["type": "forumCred", "saved": false])
            emit(["type": "loginStatus", "state": "idle", "message": "Saved passphrase removed. Type it to sign in."])
        case "stop": process?.terminate()
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
        if b["startAfterSave"] as? Bool == true { Task { await start() } }
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
        Clears: the saved wallet passphrase (Touch ID), wallet file and key-index selections, custom wallet paths, watched addresses, the mining setup (payout address, pool, worker), the saved pool password, and the auto-start choice.

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
                    "walletAddress", "walletHasPassphrase"] {          // last two: keys from earlier builds
            UserDefaults.standard.removeObject(forKey: key)
        }
        profile = ["network":"testnet", "explorer":"https://superknet.com", "host":"", "port":"", "address":"", "worker":"", "mode":"solo"]
        password = ""; generation += 1; lastStats = [:]
        emit(["type": "reset"])
        emit(["type": "nuked"])
        emit(["type": "profile", "data": profile])
        emit(["type": "credential", "password": ""])
        emit(["type": "forumCred", "saved": false])
        emit(["type": "loginStatus", "state": "idle"])
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
    var walletSpendable: [String: Int] = [:]   // address → spendable sats (carried included), last refresh
    var walletCardSeen = false                 // this action waited for or read a card
    var walletSendFrom = (address: "", explorer: "")
    var explorersUsed = Set<String>()          // explorers sends used (or the last session's did): receipt links may open them
    var quitReply: (() -> Void)?               // a quit waiting for the committed send to be reported
    var quitPending = false                    // set with quitReply, never cleared: MMM is quitting
    var lastSendShown: [String: Any]?          // the last session's send, reported at page load until a new send starts
    /// A send past broadcast-begin that is not reported yet (its exit may still be queued).
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
        walletBusy = true; walletOp += 1; walletJob = nil; walletSentIds = []; walletTxTotal = 0; walletCommitted = false; walletCancelling = false; walletCardSeen = false
        return walletOp
    }
    /// Every wallet action ends here: not busy, no child, the banner closed as `phase`.
    func walletFinish(_ phase: String) { walletBusy = false; walletJob = nil; emit(["type": "cardPrompt", "phase": phase]) }
    func walletFail(_ message: String) { walletFinish("failed"); emit(["type": "walletStatus", "state": "fail", "message": message]) }
    func walletCancelled(_ message: String = "Cancelled.") { walletFinish("cancelled"); emit(["type": "walletStatus", "state": "fail", "message": message]) }
    func cliFailure(_ r: WalletService.CLIResult, _ fallback: String) -> String {
        let text = cliErrorText(r.stderr, fallback: fallback)
        return r.timedOut ? "The wallet CLI did not finish in time and was stopped. " + text : text
    }
    /// A stderr line of action `op`: XCOIN-EVENT lines drive the page's banner. Read until
    /// the CLI exits, CANCEL or not: a broadcast it reports is part of the final report.
    func walletProgress(_ line: String, op: Int) {
        guard op == walletOp, walletBusy, let e = cliEvent(line) else { return }
        var prompt = e.prompt
        let phase = prompt["phase"] as? String, broadcasting = phase == "broadcasting"
        if let n = prompt["n"] as? Int { walletTxTotal = max(walletTxTotal, n) }
        if phase == "tap" || prompt["cardRead"] != nil { walletCardSeen = true }
        if phase == "signing", prompt["i"] != nil, walletCardSeen { prompt["card"] = true }   // "keep the card on the reader" only after a card wait
        if broadcasting, !walletCommitted { walletCommitted = true; walletSendNote(["committed": true]) }
        if let t = e.txid, !walletSentIds.contains(t) { walletSentIds.append(t); walletSendNote(["txids": walletSentIds]) }
        if broadcasting, quitPending { prompt["quitting"] = true }
        if !walletCancelling || broadcasting { emit(prompt) }   // after CANCEL only a broadcast still shows
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
        let refuse = { self.emit(["type": "cardPrompt", "phase": "broadcasting", "n": self.walletTxTotal, "i": self.walletSentIds.count, "quitting": self.quitPending]) }
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
        let op = walletBegin()
        emit(["type": "walletStatus", "state": "working",
              "message": card ? "Provisioning — when asked, tap and HOLD the NEW card on the reader…" : "Creating \(name)…"])
        var args = ["--json", "--file", path, "new", "--offline"]
        if card { args.append("--card") }
        walletJob = WalletService.run(args, passphrase: passphrase, timeout: card ? cardTimeout : 120,
                                      progress: { [weak self] line in self?.walletProgress(line, op: op) }) { [weak self] r in
            guard let self, op == self.walletOp else { return }
            guard r.code == 0, WalletService.json(r)?["file"] != nil else {
                if self.walletCancelling { self.walletCancelled() } else { self.walletFail(self.cliFailure(r, "Could not create the wallet.")) }
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
                self.walletFinish("done")
                self.emit(["type": "walletStatus", "state": "ok",
                           "message": "Card wallet created — the seed is sealed to the card and never shown. Make a duplicate with `xcoin-wallet-cli card-backup`. Unlock to derive its address (another tap)."])
                self.walletRefresh()
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
            // stopped after broadcast-begin, or a CLI that never says how far it got: nothing is known either way
            let began = events ? " after its broadcast began" : ""
            let message = silent && (walletCommitted || walletCancelling || !events)
                ? (walletCancelling ? "Cancelled" + (events ? " as the broadcast began" : "") : r.timedOut ? "The wallet CLI did not finish in time and was stopped" + began : "The send stopped" + began) + unknown
                : failure
            walletSendOutcome("failed", message); walletFail(message)
            return
        }
        let why = d["broadcast_error"] as? String ?? (silent ? (r.timedOut ? "the wallet CLI did not finish in time and was stopped" : "the wallet CLI stopped without a final report") + unknown : failure)
        walletFinish(complete ? "done" : "failed")
        var sent: [String: Any] = ["type": "walletSent", "txid": txids[0], "txids": txids, "transactions": total, "partial": !complete, "explorer": walletSendFrom.explorer,
                                   "amount": d["amount"] as? String ?? "", "fee": d["fee"] as? String ?? "", "vsize": d["vsize"] as? Int ?? 0, "change": d["change"] as? String ?? ""]
        if !complete {
            sent["broadcast_error"] = why
            if let u = d["unsent_txids"] as? [String], !u.isEmpty { sent["unsent_txids"] = u }   // the first: result unknown
        }
        let message = complete ? (walletCancelling ? "The cancel came too late: sent." : "Sent.") : "Sent \(txids.count) of \(total) transactions: \(why)"
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
        emit(["type": "cardPrompt", "phase": "broadcasting", "n": walletTxTotal, "i": walletSentIds.count, "quitting": true], menu: false)
        menuBar?.update(["type": "error", "message": "Finishing a broadcast — MMM quits when it is done."])
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
func cliEvent(_ line: String) -> (prompt: [String: Any], txid: String?)? {
    guard let at = line.range(of: "XCOIN-EVENT ") else { return nil }
    let f = line[at.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
    guard let kind = f.first else { return nil }
    let i = f.count > 1 ? Int(f[1]) : nil, n = f.count > 2 ? Int(f[2]) : nil
    switch kind {
    case "card-wait":
        let s = f.count > 1 ? Double(f[1]).flatMap { $0.isFinite ? Int(min(300, max(1, $0)).rounded()) : nil } : nil
        return (["type": "cardPrompt", "phase": "tap", "seconds": s ?? 60], nil)
    case "card-ok": return (["type": "cardPrompt", "phase": "signing", "cardRead": true], nil)
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
