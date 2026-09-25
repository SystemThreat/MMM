"""Address validation and native bridge contract regression checks; no mining."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
source=(root/'App.swift').read_text()
validator='import Foundation\n'+source[source.index('func validAddress('):source.index('@main')]
# Real witness-v3 testnet address and independently encode a matching mainnet script.
charset='qpzry9x8gf2tvdw0s3jn54khce6mua7l'
test='txa1r4dygyzk5mw0cv7ujekjkcql3wz9cgrwcc327h57kcva579644vpqhk4h48'
def encode(hrp,data):
    chk=1
    for v in [ord(c)>>5 for c in hrp]+[0]+[ord(c)&31 for c in hrp]+data+[0]*6:
        top=chk>>25;chk=((chk&0x1ffffff)<<5)^v
        for i,g in enumerate([0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]):
            if (top>>i)&1:chk^=g
    chk^=0x2bc830a3
    return hrp+'1'+''.join(charset[v] for v in data+[(chk>>(5*(5-i)))&31 for i in range(6)])
data=[charset.index(c) for c in test[4:-6]]
main=encode('xpa',data)
cases=[(test,'txa',True),(main,'xpa',True),(test,'xpa',False),(main,'txa',False),(test[:-1]+'q','txa',False),(test.upper(),'txa',True),('T'+test[1:],'txa',False),(encode('txa',[2]+data[1:]),'txa',False),(encode('txa',data[:-1]+[data[-1]|1]),'txa',False)]
checks='\n'.join(f'assert(validAddress("{a}", hrp:"{h}") == {str(ok).lower()})' for a,h,ok in cases)
(root/'build').mkdir(exist_ok=True)
swift=root/'build/AddressTests.swift';swift.write_text(validator+'\n'+checks+'\n'+f'''
var config = ["network":"testnet","address":"{test}","host":"127.0.0.1","port":"3335","worker":"test"]
assert(startupSettingsComplete(config))
config["network"]="mainnet"; assert(!startupSettingsComplete(config))
config["address"]="{main}"; assert(startupSettingsComplete(config))
config["port"]=""; assert(!startupSettingsComplete(config))
config["port"]="3335"; config["worker"]=""; assert(!startupSettingsComplete(config))
assert(!startupSettingsComplete([:]))
// XCOIN_EVENTS stderr protocol → the page's cardPrompt (and the txid a broadcast reports)
let tx = String(repeating: "ab", count: 32)
assert(cliEvent("XCOIN-EVENT card-wait 60")?.prompt["phase"] as? String == "tap")
assert(cliEvent("XCOIN-EVENT card-wait 45")?.prompt["seconds"] as? Int == 45)
assert(cliEvent("XCOIN-EVENT card-wait 999")?.prompt["seconds"] as? Int == 300)
assert(cliEvent("XCOIN-EVENT card-ok")?.prompt["cardRead"] as? Bool == true)
let sig = cliEvent("XCOIN-EVENT signing 2 4")!.prompt
assert(sig["phase"] as? String == "signing" && sig["i"] as? Int == 2 && sig["n"] as? Int == 4)
let bc = cliEvent("XCOIN-EVENT broadcast 1 4 \\(tx.uppercased())\\r")!
assert(bc.prompt["phase"] as? String == "broadcasting" && bc.prompt["i"] as? Int == 1 && bc.txid == tx)
assert(cliEvent("XCOIN-EVENT broadcast 5 4 \\(tx)") == nil && cliEvent("XCOIN-EVENT broadcast 1 4 xyz") == nil && cliEvent("XCOIN-EVENT signing 0 0") == nil)
assert(cliEvent("XCOIN-EVENT done") == nil && cliEvent("Tap and hold the card on the reader (2 interface(s))...") == nil)
// broadcast-begin: the banner locks CANCEL (phase broadcasting, nothing sent yet: no i, no txid)
let bb = cliEvent("XCOIN-EVENT broadcast-begin 4\\r")!
assert(bb.prompt["phase"] as? String == "broadcasting" && bb.prompt["n"] as? Int == 4 && bb.prompt["i"] == nil && bb.txid == nil)
assert(cliEvent("XCOIN-EVENT broadcast-begin 0") == nil && cliEvent("XCOIN-EVENT broadcast-begin x") == nil && cliEvent("XCOIN-EVENT broadcast-begin") == nil)
assert(cardWaitBudget([:]) == 60 && cardWaitBudget(["XCOIN_CARD_TIMEOUT": "120"]) == 120)
assert(cardWaitBudget(["XCOIN_CARD_TIMEOUT": "1"]) == 5 && cardWaitBudget(["XCOIN_CARD_TIMEOUT": "900"]) == 300 && cardWaitBudget(["XCOIN_CARD_TIMEOUT": "soon"]) == 60)
// a failed run's own words, whole: from "error:" on, event lines and prompts dropped
let long = "error: this payment needs 180 inputs, more than the 72 one standard transaction can carry — " + String(repeating: "x", count: 400) + "\\n  split the send"
assert(cliErrorText("Tap your wallet card on the reader…\\nXCOIN-EVENT card-wait 60\\n" + long + "\\n", fallback: "f") == long)
assert(cliErrorText("XCOIN-EVENT card-wait 60\\n\\n", fallback: "f") == "f")
assert(cliErrorText("usage: xcoin-wallet-cli\\nxcoin-wallet-cli: error: unrecognized arguments: --split\\n", fallback: "f") == "xcoin-wallet-cli: error: unrecognized arguments: --split")
// amounts compared with the balance in whole sats, never floating point
assert(sats(xcf: "12.5") == 1_250_000_000 && sats(xcf: "0.00000001") == 1 && sats(xcf: ".5") == 50_000_000 && sats(xcf: "7.") == 700_000_000)
assert(sats(xcf: "1.123456789") == nil && sats(xcf: "1e3") == nil && sats(xcf: "") == nil && sats(xcf: ".") == nil && sats(xcf: "-1") == nil && sats(xcf: "0x10") == nil)
assert(xcfText(1_250_000_000) == "12.5" && xcfText(700_000_000) == "7" && xcfText(1) == "0.00000001")
// explorer links: an http(s) origin with a host, nothing after it; only the page's own link paths
assert(explorerURL("https://superknet.com", "/tx/" + tx)?.absoluteString == "https://superknet.com/tx/" + tx)
assert(explorerURL("http://127.0.0.1:8080", "/address/txa1rabc")?.absoluteString == "http://127.0.0.1:8080/address/txa1rabc" && explorerURL("https://x.com/explorer", "/block/12") != nil)
assert(explorerURL("javascript:alert(1)", "/tx/ab") == nil && explorerURL("file:///etc", "/tx/ab") == nil && explorerURL("https://u:p@x.com", "/tx/ab") == nil && explorerURL("", "/tx/ab") == nil)
assert(explorerURL("https://x.com?q=1", "/tx/ab") == nil && explorerURL("https://x.com#f", "/tx/ab") == nil && explorerURL("https://", "/tx/ab") == nil)
assert(explorerURL("https://x.com", "//evil.com/tx/ab") == nil && explorerURL("https://x.com", "/tx/../ab") == nil && explorerURL("https://x.com", "/tx/ab?x") == nil && explorerURL("https://x.com", "/wallet/ab") == nil && explorerURL("https://x.com", "/tx/") == nil)
'''+ '\nprint("9 address validation cases and the wallet event, error-text, amount and explorer-link helpers passed")\n')
subprocess.run(['swiftc','-module-cache-path',str(root/'build/module-cache'),str(swift),'-o',str(root/'build/address-tests')],check=True)
subprocess.run([str(root/'build/address-tests')],check=True)
subprocess.run(['node','--check',str(root/'app.js')],check=True)
engine=(root/'Engine/main.swift').read_text()
assert 'cfg.password = readLine()' in engine
assert '[credentials redacted]' in engine
assert 'request("mining.authorize", [config.worker, config.password])' in engine   # JSON-encoded by JSONSerialization, never interpolated
assert 'submittedPassword = b["password"]' in source
assert 'register(defaults:["autoStartMining":true])' in source
assert 'UserDefaults.standard.set(enabled,forKey:"autoStartMining")' in source
wallet=(root/'WalletService.swift').read_text()
assert 'env["XCOIN_EVENTS"] = "1"; p.environment = env' in wallet                 # events on, rest of the environment inherited
assert 'signalTrees([pid], grace: 1)' in wallet                                   # CANCEL: SIGTERM the tree, SIGKILL after 1 s
assert 'progress: ((String) -> Void)? = nil' in wallet and 'drained.wait()' in wallet
assert '"--index", String(idx), "--split", "--yes"]' in source                   # every send may split
assert 'case "walletCancel": walletCancel()' in source and 'case "walletLock": walletLock()' in source
assert 'cardWaitBudget(ProcessInfo.processInfo.environment) + 90' in source
# busy is set in one place and cleared in one place, which also closes the page's banner
assert source.count('walletBusy = true') == 1 and source.count('walletBusy = false') - source.count('var walletBusy = false') == 1
assert 'func walletFinish(_ phase: String) { walletBusy = false; walletJob = nil; emit(["type": "cardPrompt", "phase": phase]) }' in source
def body(text, start, end):
    i = text.index(start); return text[i:text.index(end, i)]
# 1. broadcast-begin commits the job on the reader thread: cancel() and the timeout refuse; only the n x 180 s backstop may stop it
assert 'static func broadcastBegin(_ line: String) -> Int?' in wallet and 'if let n = broadcastBegin(s), commit(job, p) {' in wallet
assert 'guard !committed else { lock.unlock(); return false }' in body(wallet, 'func cancel() -> Bool', 'var isCommitted')
assert 'guard backstop || !committed else { return false }' in wallet and 'if p.isRunning, job.expire() { signalTrees' in wallet
assert 'Double(n) * broadcastBackstop) { if p.isRunning, job.expire(backstop: true)' in wallet and 'static let broadcastBackstop: TimeInterval = 180' in wallet
cancel = body(source, '@MainActor func walletCancel()', '/// LOCK:')
assert 'if walletCommitted { refuse(); return }' in cancel and 'guard job.cancel() else { refuse(); return }' in cancel
assert cancel.count('walletOp += 1') == 1 and cancel.index('walletOp += 1') < cancel.index('guard job.cancel()')   # a running CLI's exit still reports
assert 'if broadcasting, !walletCommitted { walletCommitted = true; walletSendNote(["committed": true]) }' in source
# 2. cancel is reported from what the run did: nothing sent only before broadcast-begin (of a CLI that reports it)
done = body(source, 'func walletSendDone(', '// Sign in to MineDifferent')
assert 'if walletCancelling, !walletCommitted, events {\n                walletSendOutcome("cancelled", "Cancelled — nothing was sent."); walletCancelled("Cancelled — nothing was sent."); return' in done
assert 'if txids.isEmpty { txids = walletSentIds }' in done and 'let events = args.contains("--split")' in source and 'self.walletSendDone(r, events: events)' in source
assert '!self.walletCancelling, events, r.stderr' in source                        # no retry after CANCEL
# 3. separate Touch ID gates; no sign-in prompt while a wallet action runs
assert 'let walletAuth = AuthGate(), loginAuth = AuthGate()' in source and 'authOp' not in source
assert 'gate: loginAuth)' in source and 'gate: self.walletAuth)' in source
assert 'case "loginTouch": loginTouch()' in source
login = body(source, 'func loginTouch()', '// Sign in to MineDifferent')
assert login.index('guard !walletBusy else {') < login.index('approve(') and 'guard !loginAuth.pending' in login
# 4. unsent_txids reach the page: its first is the unknown one
assert 'sent["unsent_txids"] = u' in done
# 5. the pre-check refuses only against a fresh balance; an unreadable one goes on to the CLI
send = body(source, 'func walletSend(', 'func freshSpendable(')
assert 'let fresh = await self.freshSpendable(addr, carried: carried, origin: origin)' in send and 'if want >= fresh {' in send
assert send.index('if let fresh {') < send.index('authorize()\n        }')
# 6. CANCEL with nothing running closes the banner (done), cancelled only for a dismissed sign-in prompt
assert 'emit(["type": "cardPrompt", "phase": dismissed ? "cancelled" : "done"])' in cancel
page=(root/'app.js').read_text()
assert "locked?'BROADCASTING — CANNOT CANCEL'" in page and "if(cardPhase==='broadcasting')return;" in page
assert "'NOT SENT" not in page and "txList('SENT:'" in page and "txList('NOT BROADCAST:',unsent.slice(1)" in page
# 7. quitting never kills a committed send: terminateAll skips it (commit shares its lock), the quit waits for the report
assert 'running.filter { !committed.contains($0.key) && $0.value.isRunning }' in wallet and 'if let n = broadcastBegin(s), commit(job, p) {' in wallet
assert 'lock.lock(); defer { lock.unlock() }\n        guard job.commit() else { return false }' in wallet
quit = body(source, 'func applicationShouldTerminate(', 'func applicationWillTerminate(')
assert quit.index('WalletService.terminateAll(grace: 1)') < quit.index('guard sendCommitted else { return .terminateNow }') < quit.index('return .terminateLater')
assert 'self.walletSendDone(r, events: events)\n            self.quitIfReported()' in source
sig = body(source, 'func catchQuits()', 'func loadPage()')
assert 'DispatchQueue.main.async' not in sig and 'CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { self?.quit(nil) }' in sig   # never from a main-queue block
assert sig.index('while WalletService.committedRunning') < sig.index('kill(getpid(), sig)')
assert source.count('forKey: "walletLastSend")') >= 3 and 'lastSendAtLaunch()' in body(source, 'func applicationDidFinishLaunching', 'func makeMenus()')
# 10. every quit request takes quit(_:): once a quit waits for a committed send, the rest are ignored (a second terminate: quits at once)
assert source.count('NSApp.terminate(') == 1 and 'guard !quitPending else { showFullWindow(); return }\n        NSApp.terminate(sender)' in body(source, '@objc func quit(', 'func catchQuits()')
assert 'setEventHandler(self, andSelector: #selector(quitEvent(_:withReplyEvent:)), forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))' in sig
assert 'withReplyEvent reply: NSAppleEventDescriptor) { quit(nil) }' in source and 'catchQuits()\n        lastSendAtLaunch()' in source   # after AppKit installed its own
menus = body(source, 'func makeMenus()', '@objc func quit(')
assert 'menuBar.onQuit = { [weak self] in self?.quit(nil) }' in menus and 'action: #selector(quit(_:)), keyEquivalent: "q").target = self' in menus
menubar = (root/'MenuBar.swift').read_text()
assert '@objc func quitApp() { onQuit?() }' in menubar and 'terminate' not in menubar
assert source.count('quitPending = true') == 1 and 'quitPending = true; quitReply = {' in quit and 'quitPending = false' not in source.replace('var quitPending = false', '')
assert 'r["relaunch"] = true' in body(source, 'func emitLastSend(', 'func quitIfReported(')   # the page shows it on the WALLET tab
# 8. refusals that are not the running action's result never pose as its walletStatus
assert '"type": "error", "message": "Not a valid' in body(source, 'func walletWatch(', 'func walletSelect(')
assert '"type": "error", "message": "Another wallet action is still running' in source
save = body(source, 'func saveSetup(', 'func explorerLink(')
assert save.index('guard !walletBusy else {') < save.index('PoolCredential.save(')
assert 'explorerURL(base, path)' in body(source, 'func explorerLink(', 'func webView(') and '"explorer": walletSendFrom.explorer' in source
status_case = next(l for l in page.split('\n') if l.startswith(" case 'walletStatus':"))
assert 'cardPrompt(' not in status_case                                               # only cardPrompt's terminal phases close the banner
assert "'FINISHING BROADCAST — MMM WILL QUIT WHEN IT IS DONE'" in page and "(m.card?' — KEEP THE CARD ON THE READER':'')" in page
assert 'if !spare.contains(k) { orphans.append(pid) }' in wallet                   # the next launch leaves a committed orphan to finish
# 9. the receipt grows to fit, a partial one takes the row, and says so when it must scroll
css=(root/'style.css').read_text()
assert 'max-height:104px' not in css and '.wallet-receipt.partial{max-width:none;flex:1}' in css and '.wallet-receipt.more::after{' in css
assert '.wallet-foot:has(>.wallet-receipt.partial:not([hidden])) .wallet-note{display:none}' in css
print('Password pipe, JSON escaping, log redaction, wallet events/cancel/split contract, broadcast commit, cancel reporting, Touch ID gates, fresh balance check, quit deferral and single quit path, send record, message types, save refusal, explorer links, and JS syntax passed')
