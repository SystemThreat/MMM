//
//  WalletService.swift — the GUI side of the WALLET tab.
//
//  Locates the xCoin wallet CLI and runs it with the passphrase written to the
//  child's stdin (--passphrase-fd 0): never argv, never the environment. Keys
//  and seeds never enter this process — the CLI's native keytool derives and
//  signs offline on this Mac, and the explorer only ever sees public data
//  (address UTXOs in, one signed transaction out).
//
import Foundation

enum WalletService {
    struct CLIResult { let code: Int32; let stdout: String; let stderr: String; var timedOut = false }
    /// One CLI run. cancel() also works before the child exists: it is then never started.
    /// From the child's "XCOIN-EVENT broadcast-begin" on, the run is committed: neither
    /// cancel() nor the timeout stops it, since a transaction may be on its way out.
    final class Job {
        private let lock = NSLock()
        private var process: Process?, cancelled = false, expired = false, committed = false
        /// SIGTERM the child's whole tree, SIGKILL what is left after 1 s. Any thread.
        /// false, and nothing signalled, once the run is committed.
        @discardableResult func cancel() -> Bool {
            lock.lock()
            guard !committed else { lock.unlock(); return false }
            cancelled = true; let p = process; lock.unlock()
            if let p, p.isRunning { let pid = p.processIdentifier; DispatchQueue.global().async { signalTrees([pid], grace: 1) } }
            return true
        }
        var isCommitted: Bool { lock.lock(); defer { lock.unlock() }; return committed }
        fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        /// false: cancelled while it launched, so the caller stops it
        fileprivate func attach(_ p: Process) -> Bool { lock.lock(); defer { lock.unlock() }; process = p; return !cancelled }
        fileprivate func detach() { lock.lock(); process = nil; lock.unlock() }
        /// true the first time only
        fileprivate func commit() -> Bool { lock.lock(); defer { lock.unlock() }; let first = !committed; committed = true; return first }
        /// A timer fired: true = stop the child. After commit only the backstop may.
        fileprivate func expire(backstop: Bool = false) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard backstop || !committed else { return false }
            expired = true; return true
        }
        fileprivate var didExpire: Bool { lock.lock(); defer { lock.unlock() }; return expired }
    }
    /// n of a "XCOIN-EVENT broadcast-begin <n>" line (n >= 1), else nil.
    static func broadcastBegin(_ line: String) -> Int? {
        guard let at = line.range(of: "XCOIN-EVENT broadcast-begin ") else { return nil }
        guard let n = line[at.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).first.flatMap({ Int($0) }), n >= 1 else { return nil }
        return n
    }
    /// After broadcast-begin the timeout no longer applies; this bound replaces it. Each
    /// broadcast is one HTTP call the CLI caps at 60 s, so 180 s per transaction trips only
    /// on a wedged CLI, whose result is unknown either way (without it MMM stays busy forever).
    static let broadcastBackstop: TimeInterval = 180

    /// Every child still running that talks to the card reader: wallet CLI runs,
    /// and the forum sign-in (whose engine runs the CLI in yet another process
    /// group). A child blocked in a smart-card call outlives its timeout timer if
    /// MMM quits, and an orphan stuck in SCardConnect blocks every later card tap
    /// — so MMM kills each child's whole process tree on quit. Pids and start
    /// times are also kept in defaults: when MMM dies without quitting (a crash,
    /// SIGKILL) the next launch reaps whatever is still orphaned.
    private static let lock = NSLock()
    private static var running: [ObjectIdentifier: Process] = [:]
    private static var committed = Set<ObjectIdentifier>()   // past broadcast-begin: terminateAll leaves them to finish
    private static let childrenKey = "walletChildren", committedKey = "walletChildrenCommitted"   // the latter: pids a later launch leaves to finish
    private static func saved() -> [String: Double] { UserDefaults.standard.dictionary(forKey: childrenKey) as? [String: Double] ?? [:] }

    /// Run `p` as a tracked child (chains any terminationHandler already set).
    static func launch(_ p: Process) throws {
        let then = p.terminationHandler
        p.terminationHandler = { proc in forget(proc); then?(proc) }
        lock.lock(); running[ObjectIdentifier(p)] = p; lock.unlock()
        do { try p.run() } catch { forget(p); throw error }
        guard let k = procs(KERN_PROC_PID, p.processIdentifier).first else { return }
        lock.lock(); defer { lock.unlock() }
        guard running[ObjectIdentifier(p)] != nil else { return }        // already exited
        var d = saved(); d[String(p.processIdentifier)] = started(k); UserDefaults.standard.set(d, forKey: childrenKey)
    }
    private static func forget(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        running.removeValue(forKey: ObjectIdentifier(p))
        if committed.remove(ObjectIdentifier(p)) != nil { UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: committedKey) ?? []).filter { $0 != String(p.processIdentifier) }, forKey: committedKey) }
        var d = saved(); if d.removeValue(forKey: String(p.processIdentifier)) != nil { UserDefaults.standard.set(d, forKey: childrenKey) }
    }
    /// SIGTERM every tracked child's process tree but a committed send's (only its n x 180 s
    /// backstop may stop it); with `grace`, wait for them and SIGKILL what is left. Any thread.
    static func terminateAll(grace: TimeInterval = 0) {
        lock.lock(); let roots = running.filter { !committed.contains($0.key) && $0.value.isRunning }.map { $0.value.processIdentifier }; lock.unlock()
        signalTrees(roots, grace: grace)
    }
    /// A run past broadcast-begin is still going. Any thread.
    static var committedRunning: Bool { lock.lock(); defer { lock.unlock() }; return !committed.isEmpty }
    /// broadcast-begin: under the same lock as terminateAll, so either it signalled first
    /// (the CLI's grace pause, nothing sent) or it skips the child. true the first time only.
    fileprivate static func commit(_ job: Job, _ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard job.commit() else { return false }
        if running[ObjectIdentifier(p)] != nil {
            committed.insert(ObjectIdentifier(p))
            UserDefaults.standard.set((UserDefaults.standard.stringArray(forKey: committedKey) ?? []) + [String(p.processIdentifier)], forKey: committedKey)
        }
        return true
    }
    /// At launch: kill the trees of children a previous MMM left orphaned, but a send's
    /// past broadcast-begin: it is left to finish its broadcasts (the CLI outlives MMM's closed pipes).
    static func reapOrphans() {
        let table = procs()
        var orphans: [pid_t] = []
        lock.lock()
        var d = saved()
        let spare = Set(UserDefaults.standard.stringArray(forKey: committedKey) ?? [])
        for (k, start) in d {
            guard let pid = pid_t(k), let e = table.first(where: { $0.kp_proc.p_pid == pid }), abs(started(e) - start) < 0.001 else { d[k] = nil; continue }
            if e.kp_eproc.e_ppid == 1 { if !spare.contains(k) { orphans.append(pid) }; d[k] = nil }   // else: another MMM still owns it
        }
        UserDefaults.standard.set(d, forKey: childrenKey)
        UserDefaults.standard.set(spare.filter { d[$0] != nil }.sorted(), forKey: committedKey)
        lock.unlock()
        if !orphans.isEmpty { DispatchQueue.global().async { signalTrees(orphans, grace: 2) } }
    }
    /// Signal each root and all its descendants, whatever process group they
    /// run in (NSTask gives every child its own). SIGCONT wakes a stopped child
    /// so it can act on the SIGTERM.
    private static func signalTrees(_ roots: [pid_t], grace: TimeInterval) {
        let table = procs(), me = getpid(), myGroup = getpgrp()
        var pids = Set<pid_t>(), queue = roots
        while let p = queue.popLast() {
            guard p > 1, p != me, pids.insert(p).inserted else { continue }
            queue += table.filter { $0.kp_eproc.e_ppid == p }.map { $0.kp_proc.p_pid }
        }
        guard !pids.isEmpty else { return }
        func send(_ sig: Int32, to targets: Set<pid_t>) {
            for p in targets { if getpgid(p) == p, p != myGroup { killpg(p, sig) }; kill(p, sig) }
        }
        send(SIGTERM, to: pids); send(SIGCONT, to: pids)
        guard grace > 0 else { return }
        func alive() -> Set<pid_t> { Set(procs().filter { pids.contains($0.kp_proc.p_pid) && Int32($0.kp_proc.p_stat) != SZOMB }.map { $0.kp_proc.p_pid }) }
        let deadline = Date() + grace
        while Date() < deadline, !alive().isEmpty { usleep(20_000) }
        send(SIGKILL, to: alive())
    }
    private static func started(_ k: kinfo_proc) -> Double {
        Double(k.kp_proc.p_un.__p_starttime.tv_sec) + Double(k.kp_proc.p_un.__p_starttime.tv_usec) / 1e6
    }
    private static func procs(_ what: Int32 = KERN_PROC_ALL, _ arg: Int32 = 0) -> [kinfo_proc] {
        var mib = [CTL_KERN, KERN_PROC, what, arg], size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var out = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = out.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &out, &size, nil, 0) == 0 else { return [] }
        return Array(out.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    /// Locate the wallet CLI launcher. Order: $XCOIN_WALLET_CLI, the copy
    /// bundled in MMM.app (Resources/wallet/), then the canonical install.
    static func cliPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let p = env["XCOIN_WALLET_CLI"] { candidates.append(p) }
        if let r = Bundle.main.resourcePath { candidates.append(r + "/wallet/xcoin-wallet-cli") }
        candidates.append(NSString(string: "~/x-Coin/wallet-cli/xcoin-wallet-cli").expandingTildeInPath)
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return nil
    }

    /// Run the CLI once. The passphrase goes over stdin, paired with
    /// --passphrase-fd 0; a wallet without a passphrase reads an empty line.
    /// XCOIN_EVENTS=1 makes the CLI report its card/signing progress as
    /// "XCOIN-EVENT …" stderr lines; each stderr line reaches `progress` as it
    /// arrives. Calls back on the main queue, every line before `done`.
    /// broadcast-begin commits the job on the reader thread, before `progress` sees it.
    @discardableResult
    static func run(_ args: [String], passphrase: String, timeout: TimeInterval = 180, progress: ((String) -> Void)? = nil, done: @escaping (CLIResult) -> Void) -> Job {
        let job = Job()
        guard let cli = cliPath() else {
            DispatchQueue.main.async { done(CLIResult(code: -1, stdout: "", stderr: "wallet CLI not found — reinstall MMM or clone github.com/SystemThreat/xcoin-wallet to ~/x-Coin/wallet-cli")) }
            return job
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["--passphrase-fd", "0"] + args
            var env = ProcessInfo.processInfo.environment; env["XCOIN_EVENTS"] = "1"; p.environment = env
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            guard !job.isCancelled else { DispatchQueue.main.async { done(CLIResult(code: -1, stdout: "", stderr: "cancelled")) }; return }
            do { try launch(p) } catch {
                DispatchQueue.main.async { done(CLIResult(code: -1, stdout: "", stderr: error.localizedDescription)) }
                return
            }
            inPipe.fileHandleForWriting.write(Data((passphrase + "\n").utf8))
            try? inPipe.fileHandleForWriting.close()
            if !job.attach(p) { DispatchQueue.global().async { signalTrees([p.processIdentifier], grace: 1) } }
            let pid = p.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning, job.expire() { signalTrees([pid], grace: 5) } }
            // Drain both pipes at once: a child blocked on a full stderr pipe never closes stdout.
            let err = NSMutableData(), drained = DispatchGroup()
            DispatchQueue.global().async(group: drained) {
                let h = errPipe.fileHandleForReading
                var line = Data()
                func deliver(_ d: Data) {
                    let s = String(decoding: d, as: UTF8.self)
                    if let n = broadcastBegin(s), commit(job, p) {
                        DispatchQueue.global().asyncAfter(deadline: .now() + Double(n) * broadcastBackstop) { if p.isRunning, job.expire(backstop: true) { signalTrees([pid], grace: 5) } }
                    }
                    if let progress { DispatchQueue.main.async { progress(s) } }
                }
                while true {
                    let chunk = h.availableData
                    if chunk.isEmpty { break }
                    err.append(chunk)
                    line.append(chunk)
                    while let nl = line.firstIndex(of: 0x0A) { deliver(line[line.startIndex..<nl]); line = Data(line[line.index(after: nl)...]) }
                }
                if !line.isEmpty { deliver(line) }
            }
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            drained.wait()
            p.waitUntilExit()
            job.detach()
            let result = CLIResult(code: p.terminationStatus,
                                   stdout: String(data: out, encoding: .utf8) ?? "",
                                   stderr: String(data: err as Data, encoding: .utf8) ?? "",
                                   timedOut: job.didExpire)
            DispatchQueue.main.async { done(result) }
        }
        return job
    }

    /// The JSON object the CLI printed. --json output is pretty-printed and
    /// multi-line, so parse the whole stdout first; the per-line reverse scan
    /// remains for outputs where one JSON line follows other text.
    static func json(_ r: CLIResult) -> [String: Any]? {
        if let d = try? JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: Any] { return d }
        for line in r.stdout.split(separator: "\n").reversed() {
            if let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { return d }
        }
        return nil
    }
}
