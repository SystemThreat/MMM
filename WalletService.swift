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
    struct CLIResult { let code: Int32; let stdout: String; let stderr: String }

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
    /// Calls back on the main queue.
    static func run(_ args: [String], passphrase: String, timeout: TimeInterval = 180, done: @escaping (CLIResult) -> Void) {
        guard let cli = cliPath() else {
            done(CLIResult(code: -1, stdout: "", stderr: "wallet CLI not found — reinstall MMM or clone github.com/SystemThreat/xcoin-wallet to ~/x-Coin/wallet-cli"))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["--passphrase-fd", "0"] + args
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe
            do { try p.run() } catch {
                DispatchQueue.main.async { done(CLIResult(code: -1, stdout: "", stderr: error.localizedDescription)) }
                return
            }
            inPipe.fileHandleForWriting.write(Data((passphrase + "\n").utf8))
            try? inPipe.fileHandleForWriting.close()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let result = CLIResult(code: p.terminationStatus,
                                   stdout: String(data: out, encoding: .utf8) ?? "",
                                   stderr: String(data: err, encoding: .utf8) ?? "")
            DispatchQueue.main.async { done(result) }
        }
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
