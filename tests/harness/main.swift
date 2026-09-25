// Headless App harness: the real App code with a recording page, a fake wallet CLI, a fake home,
// injected schedule sensors and a stand-in engine (/bin/sleep). No window, no menu bar item, no NFC,
// no network, no keychain (ForumCredential is a stub), never port 47476.
import Cocoa
import WebKit
import CoreImage
setvbuf(stdout, nil, _IOLBF, 0)
final class Recorder: WKWebView {
    var messages: [[String: Any]] = []
    override func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        let json = javaScriptString.dropFirst("window.receive(".count).dropLast()
        if let d = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] { messages.append(d) }
    }
}
let fakeDir = ProcessInfo.processInfo.environment["FAKE_DIR"]!
let domain = Bundle.main.executableURL!.lastPathComponent   // this binary's own defaults, emptied before and after
UserDefaults.standard.removePersistentDomain(forName: domain)
var failed = 0
func check(_ c: Bool, _ what: String) { if !c { failed += 1; print("FAIL:", what) } }
func pump(_ secs: Double, until: () -> Bool = { false }) { let end = Date() + secs; while Date() < end && !until() { RunLoop.main.run(until: Date() + 0.02) } }
let app = App()
let rec = Recorder(frame: .zero, configuration: WKWebViewConfiguration())
app.web = rec
func of(_ type: String) -> [[String: Any]] { rec.messages.filter { $0["type"] as? String == type } }
func since(_ n: Int, _ type: String) -> [[String: Any]] { Array(rec.messages.dropFirst(n)).filter { $0["type"] as? String == type } }
let A = CommandLine.arguments[1], M = CommandLine.arguments[2]   // a testnet and a mainnet witness-v3 address
/// A local HTTP stand-in on 127.0.0.1 (an ephemeral port, never 47476): it records each request and
/// answers only when released, so a test can act while MMM waits on the network.
final class HoldServer {
    private let fd: Int32, lock = NSLock()
    private var requests: [String] = []
    let port: UInt16, release = DispatchSemaphore(value: 0)
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return requests }
    init() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = 0; a.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(fd, 8)
        var b = sockaddr_in(), len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &b) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        self.fd = fd; port = UInt16(bigEndian: b.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil); if c < 0 { return }
                var buf = [UInt8](repeating: 0, count: 8192); let k = read(c, &buf, buf.count)
                let line = String(decoding: buf.prefix(max(0, k)), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
                lock.lock(); requests.append(line); lock.unlock()
                release.wait()
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let body = path == "/api/stats" ? "{\"hrp\":\"xpa\",\"charter\":{\"genesis_is_final\":true}}" : path == "/api/block/0" ? "{\"time\":1700000000}" : ""
                let head = "HTTP/1.1 " + (body.isEmpty ? "404 Not Found" : "200 OK") + "\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                let out = Array((head + body).utf8); _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }
                close(c)
            }
        }
    }
}
final class Flag { var on = false }
MainActor.assumeIsolated {
// ── RECEIVE ──
app.walletQR(["address": A, "amount": " 1.50 ", "seq": 7])
var q = of("walletQR").last!
check(q["uri"] as? String == "xcoin:\(A)?amount=1.5" && q["seq"] as? Int == 7 && q["address"] as? String == A, "QR uri/seq")
if let s = q["png"] as? String, let d = Data(base64Encoded: String(s.dropFirst("data:image/png;base64,".count))), let img = CIImage(data: d) {
    let f = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)!.features(in: img).first as? CIQRCodeFeature
    check(f?.messageString == "xcoin:\(A)?amount=1.5", "QR decodes to the URI")
} else { check(false, "QR png") }
app.walletQR(["address": A, "amount": "1,5", "seq": 8]); q = of("walletQR").last!
check(q["png"] == nil && (q["error"] as? String ?? "").hasPrefix("Amount:"), "QR refuses a comma amount")
app.walletQR(["address": "xpa" + A.dropFirst(3), "amount": "", "seq": 9]); q = of("walletQR").last!
check(q["png"] == nil && (q["error"] as? String ?? "").contains("txa1r"), "QR refuses another network's address")
print("RECEIVE: URI, seq, native QR decode, amount and network refusals")
// ── backup card: the protocol's banner phases, commit, cancel ──
let files = app.walletFiles()
check(files.count == 1 && files[0].card && files[0].format == "mmm2" && files[0].isDefault, "fake home wallet sniffed as mmm2 card")
let wf = files[0]
func backup(_ mode: String) -> Int {
    setenv("FAKE_MODE", mode, 1)
    let n = rec.messages.count, op = app.walletBegin(); app.walletBackingUp = true; app.walletBackupRun(wf, op: op)
    return n
}
var n = backup("ok")
pump(15) { !app.walletBusy }
let phases = since(n, "cardPrompt").map { p -> String in
    var s = p["phase"] as? String ?? "?"
    if p["blank"] as? Bool == true { s += "+blank" }; if p["written"] as? Bool == true { s += "+written" }; if p["cardRead"] as? Bool == true { s += "+read" }
    if let sec = p["seconds"] as? Int { s += "(\(sec))" }
    return s }
check(phases == ["signing", "tap(60)", "signing+read", "swap", "tap+blank(5)", "tap+blank(45)", "provisioning", "provisioning+written", "done"], "backup banner phases: \(phases)")
check((since(n, "walletBackupDone").last?["cards"] as? Int) == 2 && (since(n, "walletStatus").last?["state"] as? String) == "ok", "backup done: 2 cards, ok")
check(FileManager.default.fileExists(atPath: fakeDir + "/written"), "backup written")
pump(5) { since(n, "walletBackup").contains { ($0["data"] as? [String: Any])?["count"] as? Int == 2 } }
check(since(n, "walletBackup").contains { ($0["data"] as? [String: Any])?["count"] as? Int == 2 && $0["file"] as? String == wf.path }, "badge refreshed from card-status after the backup")
print("backup: phases \(phases.joined(separator: " → "))")
// CANCEL before the write: the CLI tree is stopped, nothing written
n = backup("slowblank")
pump(10) { since(n, "cardPrompt").contains { $0["phase"] as? String == "tap" && $0["seconds"] as? Int == 45 } }
app.walletCancel()
pump(10) { !app.walletBusy }
let pid = Int32((try? String(contentsOfFile: fakeDir + "/pid", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
check(pid > 0 && kill(pid, 0) != 0, "cancelled CLI is gone")
check(since(n, "walletStatus").last?["message"] as? String == "Cancelled — nothing was written to a new card." && since(n, "cardPrompt").last?["phase"] as? String == "cancelled", "cancel before the write reported")
check(!FileManager.default.fileExists(atPath: fakeDir + "/written") && !since(n, "cardPrompt").contains { $0["phase"] as? String == "provisioning" }, "nothing written after cancel")
// CANCEL during the write: refused, the write finishes
n = backup("slowwrite")
pump(10) { since(n, "cardPrompt").contains { $0["phase"] as? String == "provisioning" } }
let before = rec.messages.count
app.walletCancel()
check(Array(rec.messages.dropFirst(before)).first?["phase"] as? String == "provisioning" && !app.walletCancelling, "cancel refused during the write")
pump(10) { !app.walletBusy }
check(since(n, "walletStatus").last?["state"] as? String == "ok" && FileManager.default.fileExists(atPath: fakeDir + "/written"), "the write finished after a refused cancel")
// a failure after the write began says not to rely on that card
n = backup("failwrite")
pump(10) { !app.walletBusy }
var said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said.lowercased().components(separatedBy: "do not rely on that card").count == 2 && since(n, "cardPrompt").last?["phase"] as? String == "failed", "failed write reported, its warning once: \(said)")
n = backup("failwrite-old")   // a CLI whose words do not say it: MMM does
pump(10) { !app.walletBusy }
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said == "error: the new card stopped answering\nThe write did not finish cleanly: do not rely on that card. Make another backup with a fresh blank card.", "an older CLI's failed write gets MMM's warning: \(said)")
// a CANCEL whose SIGTERM crossed card-provisioning: in the CLI's pause the card is untouched; past it the CLI ignores the
// SIGTERM, and MMM, which read card-provisioning during the 1 s grace, never follows with a SIGKILL: the write finishes
for (mode, want, phase) in [("crossterm", "Cancelled — nothing was written to a new card.", "cancelled"),
                            ("crosskill", "The cancel came too late: the write had already begun, and it finished. Backup card written ✓ (UID 04BB) — ", "done")] {
    try? FileManager.default.removeItem(atPath: fakeDir + "/written")
    n = backup(mode)
    pump(10) { since(n, "cardPrompt").contains { $0["phase"] as? String == "tap" && $0["seconds"] as? Int == 45 } }
    app.walletCancel()
    pump(10) { !app.walletBusy }
    said = since(n, "walletStatus").last?["message"] as? String ?? ""
    check(said.hasPrefix(want) && since(n, "cardPrompt").last?["phase"] as? String == phase && since(n, "cardPrompt").contains { $0["phase"] as? String == "provisioning" }, "\(mode): \(said)")
    check(FileManager.default.fileExists(atPath: fakeDir + "/written") == (mode == "crosskill"), "\(mode): the card write \(mode == "crosskill" ? "finished (no SIGKILL mid-write)" : "never began")")
}
// a write SIGKILLed mid-way (a crash, or the n x 180 s backstop): it may be half written, and MMM says so
n = backup("selfkill")
pump(10) { !app.walletBusy }
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said == "The backup card was not made.\nThe write did not finish cleanly: do not rely on that card. Make another backup with a fresh blank card." && since(n, "cardPrompt").last?["phase"] as? String == "failed", "a write killed mid-way: \(said)")
print("backup: cancel before the write stops the CLI; cancel during the write refused; failed write warned once; a cancel crossing card-provisioning reported by how the CLI ended (in the pause: nothing written; past it: no SIGKILL, the write finishes); a write killed mid-way warned")
// ── the SIGKILL after a SIGTERM's grace spares a run that committed during the grace (cancel, quit, timeout) ──
func commitRun(_ mode: String, timeout: TimeInterval = 60, _ act: (WalletService.Job) -> Void = { _ in }) -> WalletService.CLIResult? {
    setenv("FAKE_MODE", mode, 1)
    let done = Flag(); var out: WalletService.CLIResult?
    let job = WalletService.run(["--json", mode], passphrase: "", timeout: timeout) { out = $0; done.on = true }
    pump(1)   // the fake is in its wait
    act(job)
    pump(15) { done.on }
    return out
}
var cr = commitRun("commitcross") { $0.cancel() }
check(cr?.code == 0 && cr?.signal == 0 && cr?.stdout.contains("\"ok\"") == true, "cancel: a run that committed in the grace is not SIGKILLed: \(String(describing: cr))")
cr = commitRun("commitcross") { _ in WalletService.terminateAll(grace: 1) }
check(cr?.code == 0 && cr?.signal == 0, "quit: terminateAll spares a run that committed in the grace: \(String(describing: cr))")
cr = commitRun("commitcross", timeout: 1.5)
check(cr?.code == 0 && cr?.signal == 0 && cr?.timedOut == false, "timeout: a run that committed as it fired is not SIGKILLed, and not reported as stopped: \(String(describing: cr))")
cr = commitRun("stubborn") { $0.cancel() }
check(cr?.signal == SIGKILL, "a run that ignores SIGTERM with nothing committed is still SIGKILLed: \(String(describing: cr))")
print("SIGKILL after the grace: spared for a run that committed during it (cancel, quit, timeout), still sent to one that did not")
// ── FORUM identity: key 101, typed passphrase over stdin, cached per file identity ──
setenv("FAKE_MODE", "ok", 1)
n = rec.messages.count
app.forumIdentity(passphrase: "pw")
pump(10) { !app.walletBusy }
let xid = "xid1" + String(repeating: "q", count: 58)
check(since(n, "forumIdentity").last?["xid"] as? String == xid && since(n, "forumIdentity").last?["wallet"] as? String == "wallet004.mmm", "identity shown for the default wallet")
let calls = { (try? String(contentsOfFile: fakeDir + "/calls.log", encoding: .utf8))?.components(separatedBy: "\n").filter { $0.contains(" identity ") }.count ?? 0 }
let c1 = calls()
n = rec.messages.count; app.forumIdentity(passphrase: "")
check(calls() == c1 && since(n, "forumIdentity").last?["xid"] as? String == xid && !app.walletBusy, "cached: no second CLI run")
UserDefaults.standard.removeObject(forKey: "forumIdByFile"); setenv("FAKE_MODE", "idfail", 1)
n = rec.messages.count; app.forumIdentity(passphrase: "pw"); pump(10) { !app.walletBusy }
check(since(n, "walletStatus").last?["state"] as? String == "fail" && since(n, "forumIdentity").last?["xid"] as? String == "", "identity failure shown, nothing cached")
print("FORUM: identity read with the typed passphrase, cached per file identity, failure reported")
// ── schedule: pause, blocked START, MINE ANYWAY, resume, manual STOP never undone ──
var sensors = ScheduleSensors(onAC: true, idleSeconds: 0, minute: 720, thermal: .nominal)
app.scheduleSensors = { sensors }
app.schedule = MiningSchedule(["mode": "power", "idle": 10, "from": "22:00", "to": "07:00", "hot": true])!
var engines: [Process] = []
func engine() { let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["300"]
    p.terminationHandler = { _ in DispatchQueue.main.async { app.process = nil; app.scheduleEngineEnded() } }
    try! p.run(); engines.append(p); app.process = p }
func lastSchedule(_ n: Int) -> [String: Any] { since(n, "schedule").last ?? [:] }
engine(); sensors.onAC = false; n = rec.messages.count; app.scheduleTick()
pump(5) { app.process == nil }
check(!engines[0].isRunning && lastSchedule(n)["event"] as? String == "paused" && lastSchedule(n)["reason"] as? String == "on battery power" && app.schedulePaused, "battery pauses the engine")
n = rec.messages.count; Task { await app.start(user: true) }; pump(2) { !since(n, "schedule").isEmpty }
check(lastSchedule(n)["event"] as? String == "blocked" && since(n, "error").isEmpty, "START while held: blocked, nothing launched")
n = rec.messages.count; app.mineAnyway(); pump(2) { !since(n, "error").isEmpty }
check(app.scheduleOverride == "power" && since(n, "schedule").isEmpty && (since(n, "error").last?["message"] as? String ?? "").contains("payout address"), "MINE ANYWAY passes the hold (then the empty test profile stops it)")
sensors.thermal = .serious; app.scheduleTick(); check(app.scheduleOverride == nil, "a new hold ends MINE ANYWAY")
sensors.thermal = .nominal; Task { await app.start(user: true) }; pump(2)
check(app.schedulePaused, "held again")
sensors.onAC = true; n = rec.messages.count; app.scheduleTick(); pump(2) { !since(n, "error").isEmpty }
check(lastSchedule(n)["event"] as? String == "resumed" && !app.schedulePaused && !since(n, "error").isEmpty, "allowed again: resumed (start attempted)")
engine(); app.scheduleOverride = "power"; sensors.onAC = false; app.scheduleTick(); pump(0.5)
check(engines[1].isRunning, "MINE ANYWAY keeps mining while its hold lasts")
sensors.onAC = true; app.scheduleTick(); check(app.scheduleOverride == nil, "allowed: MINE ANYWAY over")
sensors.onAC = false; app.scheduleTick(); pump(5) { app.process == nil }; check(!engines[1].isRunning && app.schedulePaused, "the next hold pauses again")
app.manualStop(); sensors.onAC = true; n = rec.messages.count; app.scheduleTick(); pump(1)
check(!app.schedulePaused && since(n, "schedule").allSatisfy { $0["event"] == nil }, "STAY STOPPED / STOP while held: never resumed")
engine(); n = rec.messages.count; app.manualStop(); pump(5) { app.process == nil }
sensors.onAC = false; app.scheduleTick(); sensors.onAC = true; app.scheduleTick(); pump(1)
check(!engines[2].isRunning && !app.schedulePaused && !since(n, "schedule").contains { $0["event"] as? String == "resumed" }, "manual STOP of a running engine is never undone")
// quitting (a committed send or card write finishing): the schedule's resume, START and MINE ANYWAY launch nothing
app.manualStop(); app.schedulePaused = true; sensors.onAC = true; app.quitPending = true
n = rec.messages.count; app.scheduleTick(); Task { await app.start(user: true) }; app.mineAnyway(); pump(2)
check(since(n, "schedule").isEmpty && since(n, "error").isEmpty && app.process == nil && app.schedulePaused && app.scheduleOverride == nil, "quitting: nothing starts the engine")
app.quitPending = false
// …and a quit that begins while start() already waits on the network (the stats port; mainnet: the explorer) launches nothing either
let hold = HoldServer(), savedProfile = app.profile
app.statsPort = Int(hold.port); app.schedulePaused = false; app.scheduleOverride = nil; sensors.onAC = true
for (net, addr) in [("testnet", A), ("mainnet", M)] {
    app.profile = ["network": net, "explorer": "http://127.0.0.1:\(hold.port)", "host": "127.0.0.1", "port": "3335", "address": addr, "worker": "t", "mode": "solo"]
    n = rec.messages.count; let k = hold.seen.count, done = Flag()
    Task { await app.start(user: true); done.on = true }
    pump(5) { hold.seen.count > k }             // start() is waiting on the network
    app.quitPending = true                       // a quit begins: a committed send is finishing
    var answered = k
    pump(10) {
        while answered < hold.seen.count { answered += 1; hold.release.signal() }   // each request answered as it comes
        return done.on
    }
    let asked = Array(hold.seen.dropFirst(k)).map { String($0.split(separator: " ").dropFirst().first ?? "") }
    check(done.on && app.process == nil && since(n, "started").isEmpty && since(n, "error").isEmpty && asked == (net == "testnet" ? ["/health"] : ["/api/stats", "/api/block/0"]), "\(net): a quit during start()'s network wait launches nothing (asked \(asked), \(since(n, "error")))")
    app.quitPending = false
}
app.profile = savedProfile; app.statsPort = 47476
for p in engines where p.isRunning { p.terminate() }
print("schedule: pause, blocked START, MINE ANYWAY until the verdict changes, resume, manual STOP respected, nothing starts while quitting (nor after a network wait a quit began during)")
// ── sends: an answered refusal is NOT SENT with certainty; a lost connection is not; the reader-reset line ──
let T = { (c: Character) in String(repeating: c, count: 64) }
func sendRun(_ mode: String) -> Int {
    setenv("FAKE_MODE", mode, 1)
    let n = rec.messages.count, op = app.walletBegin()
    app.walletSendRun(["--json", "--explorer", "https://x.example", "--hrp", "txa", "--file", wf.path, "send", A, "10", "--index", "0", "--split", "--yes"], passphrase: "", card: true, op: op, from: A, explorer: "https://x.example")
    return n
}
n = sendRun("reject1"); pump(10) { !app.walletBusy }
let rs = since(n, "walletSent").last ?? [:], rf = rs["refused"] as? [String: Any], why = rs["message"] as? String ?? ""
check(rf?["i"] as? Int == 1 && rf?["n"] as? Int == 1 && rf?["reason"] as? String == "insufficient-fee" && (rs["txids"] as? [String])?.isEmpty == true, "refused first transaction: a NOT SENT receipt \(rs)")
check(why.hasPrefix("Nothing was sent: these coins are already being spent") && why.hasSuffix("(insufficient fee)") && since(n, "walletStatus").last?["message"] as? String == why, "refused: the CLI's plain words, whole, without error:")
check(since(n, "cardPrompt").last?["phase"] as? String == "failed" && since(n, "cardPrompt").last?["refused"] as? Bool == true, "refused: the banner ends NOT SENT")
check(since(n, "cardPrompt").contains { $0["phase"] as? String == "retry" && $0["attempt"] as? Int == 1 && $0["seconds"] as? Int == 5 }, "card-retry reaches the banner with a fresh card wait (the budget)")
check((UserDefaults.standard.dictionary(forKey: "walletLastSend")?["outcome"] as? String) == "refused", "refused outcome recorded for a relaunch")
n = sendRun("rejectnode"); pump(10) { !app.walletBusy }   // the node path's check refuses transaction 2 of 3 before any broadcast
let rn = since(n, "walletSent").last ?? [:], rnf = rn["refused"] as? [String: Any], rnWhy = rn["message"] as? String ?? ""
check(rnf?["i"] as? Int == 2 && rnf?["n"] as? Int == 3 && rnf?["reason"] as? String == "min-relay-fee-not-met" && (rn["txids"] as? [String])?.isEmpty == true && rn["transactions"] as? Int == 3, "refused transaction 2 of 3 before any broadcast: a NOT SENT receipt \(rn)")
check(rnWhy.hasPrefix("Nothing was sent: the node refused transaction 2 of 3") && since(n, "walletStatus").last?["message"] as? String == rnWhy && since(n, "cardPrompt").last?["refused"] as? Bool == true, "refused before any broadcast: the CLI's words, the banner ends NOT SENT: \(rnWhy)")
check((UserDefaults.standard.dictionary(forKey: "walletLastSend")?["outcome"] as? String) == "refused", "refused (node path) outcome recorded")
n = sendRun("reject3"); pump(10) { !app.walletBusy }
let pr = since(n, "walletSent").last ?? [:]
check(pr["partial"] as? Bool == true && (pr["refused"] as? [String: Any])?["i"] as? Int == 3 && pr["txids"] as? [String] == [T("a"), T("b")] && pr["unsent_txids"] as? [String] == [T("c"), T("d")], "refused third of four: partial receipt with the refusal marked")
// the real CLI's JSON: "broadcast rejected: <reason>" and broadcast_rejected, no event: MMM says it in plain words, the raw reason kept
let plain3 = "these coins were already spent. (missing-inputs)", status3 = since(n, "walletStatus").last?["message"] as? String ?? ""
check(status3 == "Sent 2 of 4 transactions. The network refused transaction 3, so it was not sent, and the rest were never broadcast: " + plain3 && pr["broadcast_error"] as? String == plain3, "partial refused wording, plain: \(status3)")
check(!status3.contains("broadcast rejected") && ((UserDefaults.standard.dictionary(forKey: "walletLastSend")?["receipt"] as? [String: Any])?["broadcast_error"] as? String) == plain3, "no raw 'broadcast rejected:' on screen or in the kept receipt")
n = sendRun("reject2plain"); pump(10) { !app.walletBusy }   // a CLI that words a later refusal itself (and announces it): as it is
let pj = since(n, "walletSent").last ?? [:], plain2 = "these coins are already being spent by an earlier send that has not confirmed yet. Wait for the next block, then send again. (txn-mempool-conflict)"
check(pj["partial"] as? Bool == true && (pj["refused"] as? [String: Any])?["i"] as? Int == 2 && (pj["refused"] as? [String: Any])?["reason"] as? String == "txn-mempool-conflict" && pj["txids"] as? [String] == [T("a")] && pj["broadcast_error"] as? String == plain2 && since(n, "walletStatus").last?["message"] as? String == "Sent 1 of 3 transactions. The network refused transaction 2, so it was not sent, and the rest were never broadcast: " + plain2, "a CLI's own plain words are not worded twice")
n = sendRun("lost"); pump(10) { !app.walletBusy }
check(since(n, "walletSent").isEmpty && (since(n, "walletStatus").last?["message"] as? String ?? "").contains("Nothing is confirmed sent") && since(n, "cardPrompt").last?["refused"] == nil, "a lost connection is never called refused")
print("sends: refused first → NOT SENT receipt and banner; refused second of three before any broadcast (node path) → NOT SENT; refused third of four → partial with the refusal marked, in plain words; lost connection keeps its look-it-up wording; reader-reset line")
// ── a reader reset: the CLI waits for the card again, so the run's timeout grows by that wait ──
let retried = Flag(), plainRun = Flag()
var rr: WalletService.CLIResult?, pr2: WalletService.CLIResult?
var rjob: WalletService.Job?
rjob = WalletService.run(["--json", "retrytest"], passphrase: "", timeout: 1, progress: { line in if line.contains("XCOIN-EVENT card-retry") { rjob?.extend(by: 3) } }) { rr = $0; retried.on = true }
_ = WalletService.run(["--json", "retrytest"], passphrase: "", timeout: 1) { pr2 = $0; plainRun.on = true }
pump(15) { retried.on && plainRun.on }
check(rr?.code == 0 && rr?.timedOut == false && rr?.signal == 0, "a retry's wait extends the 1 s timeout: \(String(describing: rr))")
check(pr2?.timedOut == true && pr2?.signal == SIGTERM, "without it the timeout stops the run (SIGTERM): \(String(describing: pr2))")
print("reader reset: the timeout grows by the new card wait")
// ── NEW WALLET, card-bound: the new card's write commits like a backup card's; a stop says what happened to the card ──
UserDefaults.standard.set(["outcome": "sent", "message": "an earlier send", "txids": [String]()], forKey: "walletLastSend")   // no "committed": a card write must not add one
let lastSend = UserDefaults.standard.dictionary(forKey: "walletLastSend") as NSDictionary?
let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xcoin").path
@MainActor func create(_ mode: String, _ name: String) -> Int { setenv("FAKE_MODE", mode, 1); let n = rec.messages.count; app.walletCreate(name: name, passphrase: "pw", card: true); return n }
func tapped(_ n: Int) -> Bool { since(n, "cardPrompt").contains { $0["phase"] as? String == "tap" } }
@MainActor func stopAfterTap(_ n: Int, until: () -> Bool = { true }) { pump(10) { tapped(n) && until() }; app.walletCancel(); pump(10) { !app.walletBusy } }
n = create("newwait", "zc1.mmm"); stopAfterTap(n)
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(since(n, "cardPrompt").first { $0["phase"] as? String == "tap" }?["blank"] as? Bool == true, "the new card wallet's tap is for a blank card")
check(said == "Cancelled — no wallet was created." && since(n, "cardPrompt").last?["phase"] as? String == "cancelled" && !FileManager.default.fileExists(atPath: home + "/zc1.mmm"), "new card: cancel while waiting: \(said)")
n = create("newhalf", "zc2.mmm"); stopAfterTap(n) { FileManager.default.fileExists(atPath: home + "/card-04CD.auth") }   // a CLI with no card-provisioning, stopped mid-write
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said == "Cancelled.\nNo wallet was created, but the new card (UID 04CD) was part-way set up: do not rely on that card." && since(n, "cardPrompt").last?["phase"] as? String == "failed", "new card: stopped with its key file saved: \(said)")
n = create("newcross", "zc3.mmm"); stopAfterTap(n)
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said == "Cancelled — no wallet was created, and nothing was written to the new card." && since(n, "cardPrompt").last?["phase"] as? String == "cancelled", "new card: a cancel that crossed card-provisioning (died in the pause): \(said)")
n = create("newprov", "zc4.mmm")
pump(10) { since(n, "cardPrompt").contains { $0["phase"] as? String == "provisioning" } }
let atCancel = rec.messages.count
app.walletCancel()
check(Array(rec.messages.dropFirst(atCancel)).first?["phase"] as? String == "provisioning" && Array(rec.messages.dropFirst(atCancel)).first?["new"] as? Bool == true && !app.walletCancelling && app.walletJob?.isCommitted == true, "new card: CANCEL refused during the write; the run is committed (no timeout, quits wait)")
check(app.walletLockedPrompt()["phase"] as? String == "provisioning" && app.walletLockedPrompt()["new"] as? Bool == true, "new card: the locked banner is the new card's write")
pump(10) { !app.walletBusy }
let newPhases = since(n, "cardPrompt").map { p -> String in
    var s = p["phase"] as? String ?? "?"
    if p["blank"] as? Bool == true { s += "+blank" }; if p["new"] as? Bool == true { s += "+new" }; if p["written"] as? Bool == true { s += "+written" }
    return s }
check(newPhases == ["tap+blank", "provisioning+new", "provisioning+new", "provisioning+new+written", "done"] && since(n, "walletCardCreated").last?["name"] as? String == "zc4.mmm" && since(n, "walletStatus").last?["state"] as? String == "ok", "new card: \(newPhases)")
check((UserDefaults.standard.dictionary(forKey: "walletLastSend") as NSDictionary?) == lastSend, "a new card's commit never touches the send record")
n = create("newprovfail", "zc5.mmm"); pump(10) { !app.walletBusy }
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said.lowercased().components(separatedBy: "do not rely on that card").count == 2 && said.hasPrefix("error: setting up the new card did not finish"), "new card: the CLI's failed write, its warning once: \(said)")
n = create("newprovold", "zc6.mmm"); pump(10) { !app.walletBusy }
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said == "error: the card stopped answering\nNo wallet was created, but the new card was part-way set up: do not rely on that card.", "new card: a failed write the CLI does not warn about: \(said)")
n = create("newfile", "zc7.mmm"); pump(10) { !app.walletBusy }   // the wallet file was written, then the last step failed: never "No wallet was created"
said = since(n, "walletStatus").last?["message"] as? String ?? ""
check(said == "error: could not seal the card: the key file could not be updated\nzc7.mmm was saved, so the new card was set up, but its last step did not confirm. Before you use zc7.mmm, UNLOCK it with the new card to check that the card opens it." && since(n, "cardPrompt").last?["phase"] as? String == "failed" && !said.contains("No wallet was created"), "new card: the wallet file exists after a failed last step: \(said)")
for f in ["zc4.mmm", "zc7.mmm", "card-04CD.auth", "card-04CE.auth"] { try? FileManager.default.removeItem(atPath: home + "/" + f) }
print("new card wallet: blank-card tap; cancel while waiting; stopped mid-write (key file) or in the pause; the write committed (CANCEL refused, locked banner, no send record); failed writes warned once; a wallet file already written is never reported as not created")
}
UserDefaults.standard.removePersistentDomain(forName: domain)
print(failed == 0 ? "App harness (RECEIVE, backup-card protocol and CANCEL, no SIGKILL for a run committed in the grace, forum identity, schedule state machine and quit guard, refused and lost sends, reader-reset timeout, new card wallets) passed" : "HARNESS: \(failed) failed")
exit(failed == 0 ? 0 : 1)
