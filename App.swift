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
        case "walletRefresh": walletRefresh()
        case "walletUnlock": walletUnlock(passphrase: b["passphrase"] as? String ?? "", remember: b["remember"] as? Bool ?? false)
        case "walletSelect": if let f = b["file"] as? String { walletSelect(file: f, index: b["index"] as? Int) }
        case "nuke": nukeInputs()
        case "walletCreate":
            walletCreate(name: b["name"] as? String ?? "", passphrase: b["passphrase"] as? String ?? "", card: b["card"] as? Bool ?? false)
        case "walletWatchAdd":
            if let a = (b["address"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
               validAddress(a, hrp: walletHrp()) {
                var w = UserDefaults.standard.stringArray(forKey: "walletWatched") ?? []
                if !w.contains(a) { w.append(a) }
                UserDefaults.standard.set(w, forKey: "walletWatched")
                walletRefresh()
            } else {
                emit(["type": "walletStatus", "state": "fail", "message": "Not a valid \(walletHrp())1r… address to watch."])
            }
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
    /// RESET: forget everything MMM remembers — saved passphrase, wallet
    /// selections, custom paths, watched addresses, mining setup, pool
    /// password — as if freshly installed. Wallet FILES are never touched.
    @MainActor func nukeInputs() {
        guard process == nil else {
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
    /// Derived-address cache key: one address per (file, index) pair.
    func walletAddrKey(_ path: String, _ idx: Int) -> String { path + "#" + String(idx) }

    func walletState() -> [String: Any] {
        let files = walletFiles(), sel = selectedWallet()
        let selPath = sel?.path ?? ""
        let selIdx = walletIndex(for: selPath)
        let hasPass = walletPassCache()[selPath] ?? (sel?.card == true)   // a card wallet always has one
        let credUsable = (sel?.isDefault == true) && ForumCredential.exists()
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
                "watched": UserDefaults.standard.stringArray(forKey: "walletWatched") ?? [],
                "cliFound": WalletService.cliPath() != nil]
    }
    @MainActor func walletRefresh() {
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
                if let u = try? await get(origin + "/api/utxos/" + addr) {
                    var spendable = 0, immature = 0
                    for x in (u["utxos"] as? [[String: Any]] ?? []) {
                        let sats = (x["amount_sats"] as? Int) ?? 0
                        if (x["immature"] as? Bool) == true { immature += sats } else { spendable += sats }
                    }
                    balances[addr] = ["spendable_sats": spendable, "immature_sats": immature, "height": u["height"] ?? 0]
                }
            }
            if let main = state["walletAddress"] as? String, !main.isEmpty,
               let carried = state["walletCarried"] as? String, !carried.isEmpty, carried != main {
                if let u = try? await get(origin + "/api/utxos/" + carried) {
                    var cs = 0, ci = 0
                    for x in (u["utxos"] as? [[String: Any]] ?? []) {
                        let sats = (x["amount_sats"] as? Int) ?? 0
                        if (x["immature"] as? Bool) == true { ci += sats } else { cs += sats }
                    }
                    if var row = balances[main] as? [String: Any] {
                        row["spendable_sats"] = ((row["spendable_sats"] as? Int) ?? 0) + cs
                        row["immature_sats"] = ((row["immature_sats"] as? Int) ?? 0) + ci
                        row["carried_sats"] = cs + ci
                        balances[main] = row
                    }
                } else {
                    // Half a balance must never look like the whole: show it as unavailable.
                    balances.removeValue(forKey: main)
                }
            }
            state["balances"] = balances
            emit(["type": "wallet", "data": state])
        }
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
    /// Create a wallet in ~/.xcoin through the CLI. Normal wallets get a
    /// one-time seed reveal for the paper backup; card wallets never reveal a
    /// seed by design (the backup is a duplicate card via `card-backup`).
    func walletCreate(name rawName: String, passphrase: String, card: Bool) {
        guard !walletBusy else { return }
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
        walletBusy = true
        emit(["type": "walletStatus", "state": "working",
              "message": card ? "Provisioning — when asked, tap and HOLD the NEW card on the reader…" : "Creating \(name)…"])
        var args = ["--json", "--file", path, "new", "--offline"]
        if card { args.append("--card") }
        WalletService.run(args, passphrase: passphrase, timeout: card ? 400 : 120) { [weak self] r in
            guard let self else { return }
            guard r.code == 0, WalletService.json(r)?["file"] != nil else {
                self.walletBusy = false
                self.emit(["type": "walletStatus", "state": "fail",
                           "message": r.stderr.isEmpty ? "Could not create the wallet." : String(r.stderr.suffix(300))])
                return
            }
            UserDefaults.standard.set(path, forKey: "walletFile")
            self.setWalletIndex(0, for: path)
            var passes = self.walletPassCache(); passes[path] = !passphrase.isEmpty || card
            UserDefaults.standard.set(passes, forKey: "walletPassByFile")
            if card {
                self.walletBusy = false
                self.emit(["type": "walletStatus", "state": "ok",
                           "message": "Card wallet created — the seed is sealed to the card and never shown. Make a duplicate with `xcoin-wallet-cli card-backup`. Unlock to derive its address (another tap)."])
                self.walletRefresh()
                return
            }
            // one-time seed reveal for the paper backup, then derive the address
            WalletService.run(["--json", "--file", path, "seed", "--yes", "--no-clear"], passphrase: passphrase, timeout: 60) { r2 in
                self.walletBusy = false
                if r2.code == 0, let seed = WalletService.json(r2)?["seed"] as? String {
                    self.emit(["type": "walletSeed", "name": name, "seed": seed])
                } else {
                    self.emit(["type": "walletStatus", "state": "fail",
                               "message": "Wallet created, but the seed reveal failed — run `xcoin-wallet-cli --file ~/.xcoin/\(name) seed` in Terminal to back it up NOW."])
                }
                self.walletUnlock(passphrase: passphrase, remember: false)
            }
        }
    }
    func walletUnlock(passphrase: String, remember: Bool) {
        guard !walletBusy, let sel = selectedWallet() else { return }
        if sel.card, passphrase.isEmpty {
            emit(["type": "walletStatus", "state": "fail", "message": "This is a card wallet — its passphrase is required (it guards the card keys)."]); return
        }
        let idx = walletIndex(for: sel.path)
        walletBusy = true
        emit(["type": "walletStatus", "state": "working",
              "message": sel.card ? "Unlocking — tap your xCoin card on the NFC reader when prompted…" : "Unlocking the wallet…"])
        WalletService.run(["--json", "--hrp", walletHrp(), "--file", sel.path, "address", "--index", String(idx)],
                          passphrase: passphrase, timeout: sel.card ? 300 : 180) { [weak self] r in
            guard let self else { return }
            self.walletBusy = false
            guard r.code == 0, let d = WalletService.json(r), let addr = d["address"] as? String else {
                self.emit(["type": "walletStatus", "state": "fail",
                           "message": r.stderr.isEmpty ? "Could not unlock \(sel.name) — is one set up? Run `xcoin-wallet-cli new`." : String(r.stderr.suffix(300))])
                return
            }
            var addrs = self.walletAddrCache(); addrs[self.walletAddrKey(sel.path, idx)] = addr
            UserDefaults.standard.set(addrs, forKey: "walletAddrByFile2")
            if let carried = d["carried_address"] as? String {
                var c = self.walletCarriedCache(); c[self.walletAddrKey(sel.path, idx)] = carried
                UserDefaults.standard.set(c, forKey: "walletCarriedByFile2")
            }
            var passes = self.walletPassCache(); passes[sel.path] = !passphrase.isEmpty
            UserDefaults.standard.set(passes, forKey: "walletPassByFile")
            if remember, !passphrase.isEmpty, sel.isDefault {
                try? ForumCredential.save(passphrase)
                self.emit(["type": "forumCred", "saved": ForumCredential.exists()])   // the SETUP tab shares this credential
            }
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
        guard let amt = Double(amount), amt > 0 else {
            emit(["type": "walletStatus", "state": "fail", "message": "Enter an amount above zero."]); return
        }
        let origin = profile["explorer"] ?? ""
        let credUsable = sel.isDefault && ForumCredential.exists()
        let hasPass = walletPassCache()[sel.path] ?? sel.card
        // A passphrase-protected wallet needs the passphrase from somewhere:
        // the send form's field, or (default wallet only) the saved credential.
        if hasPass, formPass.isEmpty, !credUsable {
            emit(["type": "walletStatus", "state": "fail",
                  "message": "Type this wallet's passphrase in the send form (only the default wallet can use the saved Touch ID passphrase)."]); return
        }
        walletBusy = true
        emit(["type": "walletStatus", "state": "working", "message": "Waiting for Touch ID…"])
        // Touch ID (or the Mac password) approves EVERY send, saved passphrase or not.
        ForumCredential.authenticate(reason: "send \(amount) XCF to \(String(dest.prefix(12)))… from \(sel.name)") { [weak self] ok, why in
            guard let self else { return }
            guard ok else { self.walletBusy = false; self.emit(["type": "walletStatus", "state": "fail", "message": why ?? "Touch ID failed."]); return }
            let pw = !formPass.isEmpty ? formPass : (credUsable ? ((try? ForumCredential.load()) ?? "") : "")
            self.emit(["type": "walletStatus", "state": "working",
                       "message": sel.card ? "Signing — tap your xCoin card on the NFC reader…" : "Signing offline and broadcasting…"])
            Task { @MainActor in
                // Never sign against an explorer serving a different chain.
                if let stats = try? await self.get(origin + "/api/stats"), let ehrp = stats["hrp"] as? String, ehrp != hrp {
                    self.walletBusy = false
                    self.emit(["type": "walletStatus", "state": "fail", "message": "The explorer is serving a different network — fix the explorer URL in SETUP."]); return
                }
                let idx = self.walletIndex(for: sel.path)
                WalletService.run(["--json", "--explorer", origin, "--hrp", hrp, "--file", sel.path, "send", dest, amount, "--index", String(idx), "--yes"],
                                  passphrase: pw, timeout: sel.card ? 300 : 180) { r in
                    self.walletBusy = false
                    guard r.code == 0, let d = WalletService.json(r), (d["broadcast"] as? Bool) == true, let txid = d["txid"] as? String else {
                        self.emit(["type": "walletStatus", "state": "fail",
                                   "message": r.stderr.isEmpty ? "The send did not complete." : String(r.stderr.suffix(300))])
                        return
                    }
                    self.emit(["type": "walletStatus", "state": "ok", "message": "Sent."])
                    self.emit(["type": "walletSent", "txid": txid, "fee": d["fee"] as? String ?? "?",
                               "vsize": d["vsize"] as? Int ?? 0, "change": d["change"] as? String ?? "0"])
                    self.walletRefresh()
                }
            }
        }
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
