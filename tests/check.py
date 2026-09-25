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
'''+ r'''
// backup-card events of card-backup --auto-swap
assert(cliEvent("XCOIN-EVENT card-swap")?.prompt["phase"] as? String == "swap")
let removed = cliEvent("XCOIN-EVENT card-removed\r", budget: 90)!.prompt
assert(removed["phase"] as? String == "tap" && removed["blank"] as? Bool == true && removed["seconds"] as? Int == 90)
assert(cliEvent("XCOIN-EVENT card-provisioning")?.prompt["phase"] as? String == "provisioning" && cliEvent("XCOIN-EVENT card-wait", budget: 120)?.prompt["seconds"] as? Int == 120)
// RECEIVE: the payment URI; amounts in whole sats, canonical, dot decimals
let payTo = "TESTADDR"
assert(paymentURI(payTo, amount: "", hrp: "txa") == "xcoin:" + payTo && paymentURI(payTo.uppercased(), amount: " 1.50 ", hrp: "txa") == "xcoin:" + payTo + "?amount=1.5")
assert(paymentURI(payTo, amount: "0.00000001", hrp: "txa") == "xcoin:" + payTo + "?amount=0.00000001" && paymentURI(payTo, amount: "100000000", hrp: "txa") == "xcoin:" + payTo + "?amount=100000000" && paymentURI(payTo, amount: "99999999.99999999", hrp: "txa") == "xcoin:" + payTo + "?amount=99999999.99999999" && sats(xcf: "100000000") == 10_000_000_000_000_000)
for bad in ["0", "0.0", "100000000.00000001", "100000001", "1000000000", "1,5", "1e3", "-1", "1.123456789", ".", "abc"] { assert(paymentURI(payTo, amount: bad, hrp: "txa") == nil) }
assert(paymentURI(payTo, amount: "", hrp: "xpa") == nil && paymentURI("txa1rbad", amount: "", hrp: "txa") == nil)
// card-status → the header's facts, typed and JSON-safe
let st = cardStatusInfo(["card": true, "format": "mmm2", "family": "ab12", "count": 2, "backup_supported": true, "note": "", "cards": [["uid": "04AA", "label": "primary", "permanent": true, "created": "2026-09-24"], ["uid": "04BB", "label": "backup", "permanent": false, "created": 1790000000]]], format: "mmm2")
assert(st["count"] as? Int == 2 && st["backup_supported"] as? Bool == true && (st["cards"] as? [[String: Any]])?.last?["created"] as? String == "1790000000" && JSONSerialization.isValidJSONObject(st))
let dex = cardStatusInfo(["card": true, "format": "mmm5", "family": NSNull(), "count": NSNull(), "backup_supported": false, "note": "made with dex-wallet-cli", "cards": [Any]()], format: "mmm5")
assert(dex["count"] == nil && dex["family"] == nil && dex["backup_supported"] as? Bool == false && JSONSerialization.isValidJSONObject(dex))
assert(cardStatusInfo(nil, format: "mmm5")["backup_supported"] as? Bool == false && cardStatusInfo(nil, format: "mmm2")["unknown"] as? Bool == true && cardStatusInfo(["card": false], format: "mmm1")["card"] as? Bool == false)
// the reader reset the card mid-read: a retry line on the banner (CANCEL still allowed: a read, never a write)
let retry = cliEvent("XCOIN-EVENT card-retry 2\r")!.prompt
assert(retry["phase"] as? String == "retry" && retry["attempt"] as? Int == 2 && cliEvent("XCOIN-EVENT card-retry")?.prompt["attempt"] as? Int == 1)
// an answered refusal: transaction i of n, a bounded reason token; not a banner event
let rj = cliRejected("XCOIN-EVENT rejected 1 1 txn-mempool-conflict\r")!
assert(rj.i == 1 && rj.n == 1 && rj.reason == "txn-mempool-conflict" && cliEvent("XCOIN-EVENT rejected 1 1 x") == nil)
assert(cliRejected("XCOIN-EVENT rejected 3 4 bad-txns-inputs-missingorspent")!.i == 3 && cliRejected("XCOIN-EVENT rejected 3 4")!.reason == "refused")
assert(cliRejected("XCOIN-EVENT rejected 5 4 x") == nil && cliRejected("XCOIN-EVENT rejected 0 1 x") == nil && cliRejected("XCOIN-EVENT rejected x") == nil && cliRejected("XCOIN-EVENT broadcast 1 1 " + tx) == nil)
assert(cliRejected("XCOIN-EVENT rejected 1 1 <b>" + String(repeating: "z", count: 100))!.reason == "b" + String(repeating: "z", count: 63))
assert(refusedText("Tap…\nXCOIN-EVENT rejected 1 1 insufficient-fee\nerror: Nothing was sent: these coins were already spent. (bad-txns-inputs-missingorspent)\n") == "Nothing was sent: these coins were already spent. (bad-txns-inputs-missingorspent)")
assert(refusedText("") == "Nothing was sent: the network refused the transaction.")
// a split send's later refusal: the CLI's JSON carries it raw ("broadcast rejected: <reason>"); MMM says it in plain words, the raw reason kept
let spentTwice = "these coins are already being spent by an earlier send that has not confirmed yet. Wait for the next block, then send again."
assert(plainBroadcastError("broadcast rejected: txn-mempool-conflict") == spentTwice + " (txn-mempool-conflict)")
assert(plainBroadcastError("broadcast rejected: insufficient fee, rejecting replacement ab; new feerate 1 <= old 2") == spentTwice + " (insufficient fee, rejecting replacement ab; new feerate 1 <= old 2)")
assert(plainBroadcastError("Broadcast rejected: bad-txns-inputs-missingorspent") == "these coins were already spent. (bad-txns-inputs-missingorspent)" && plainBroadcastError("broadcast rejected: missing-inputs") == "these coins were already spent. (missing-inputs)")
assert(plainBroadcastError("broadcast rejected: replacement-failed") == spentTwice + " (replacement-failed)" && plainBroadcastError("broadcast rejected: min relay fee not met, 100 < 200") == "its fee is below the network's minimum relay fee. Send again with a higher fee. (min relay fee not met, 100 < 200)")
assert(plainBroadcastError("broadcast rejected: bad-txout-below-min-value") == "an amount in it is below the network's smallest allowed output (0.00010000 XID, 10,000 sat). (bad-txout-below-min-value)")
assert(plainBroadcastError("broadcast rejected: something-new") == "the network refused this transaction. (something-new)" && plainBroadcastError("broadcast rejected:") == "the network refused this transaction.")
let lostLine = "cannot reach the explorer at https://x.example: timed out", worded = "these coins were already spent. (bad-txns-inputs-missingorspent)"
assert(plainBroadcastError(lostLine) == lostLine && plainBroadcastError(worded) == worded)   // a lost connection, or words already plain: as they are
assert(cliEvent("XCOIN-EVENT card-retry 1", budget: 45)?.prompt["seconds"] as? Int == 45)   // the CLI waits for the card again: a whole budget
for reason in ["insufficient fee", "txn-mempool-conflict", "bad-txns-inputs-missingorspent", "min relay fee not met, 100 < 200", "bad-txout-below-min-value", "dust", "something-new", ""] {
    print("REJECT_PLAIN " + String(data: try! JSONSerialization.data(withJSONObject: [reason, rejectPlain(reason)]), encoding: .utf8)!)
}
// the forum identity as the CLI prints it
assert(validIdentity("xid1" + String(repeating: "q", count: 58)) && !validIdentity("xid1" + String(repeating: "b", count: 58)) && !validIdentity("xid1q") && !validIdentity(payTo))
'''.replace('TESTADDR', test) + '\nprint("9 address validation cases and the wallet event (card-retry with its budget, rejected), error-text, refusal-text, later-refusal plain words, amount, explorer-link, payment-URI, card-status and identity helpers passed")\n')
subprocess.run(['swiftc','-module-cache-path',str(root/'build/module-cache'),str(swift),'-o',str(root/'build/address-tests')],check=True)
out=subprocess.run([str(root/'build/address-tests')],check=True,capture_output=True,text=True).stdout
print('\n'.join(l for l in out.splitlines() if not l.startswith('REJECT_PLAIN ')))
# MMM words a later refusal as the wallet CLI's reject_plain does: the same words for the contract's reasons
import json,os
from decimal import Decimal,InvalidOperation
cli_py=Path(os.environ.get('XCOIN_WALLET_SRC',str(Path.home()/'x-Coin/xcoin-wallet')))/'wallet_cli.py'
if cli_py.exists():
    t=cli_py.read_text();ns={'Decimal':Decimal,'InvalidOperation':InvalidOperation,'WalletError':Exception,'re':__import__('re')}
    for head in ['def money(','def fmt(','def reject_plain(']:
        i=t.index(head);exec(t[i:t.index('\ndef ',i+1)],ns)
    ns['DUST_CHANGE']=Decimal(__import__('re').search(r'^DUST_CHANGE = Decimal\("([0-9.]+)"\)',t,__import__('re').M).group(1))
    for l in out.splitlines():
        if l.startswith('REJECT_PLAIN '):
            reason,words=json.loads(l[len('REJECT_PLAIN '):])
            assert ns['reject_plain'](reason)==words,(reason,words,ns['reject_plain'](reason))
    print('Later-refusal words match the wallet CLI\'s reject_plain ('+str(cli_py)+')')
else: print('wallet CLI source not found: the reject_plain cross-check was skipped')
feature=root/'build/feature-tests';feature.mkdir(exist_ok=True)
(feature/'main.swift').write_text(r'''import Foundation
import CoreImage
import ImageIO
var s = MiningSchedule()
let base = ScheduleSensors(onAC: true, idleSeconds: 0, minute: 12 * 60, thermal: .nominal)
func with(_ f: (inout ScheduleSensors) -> Void) -> ScheduleSensors { var x = base; f(&x); return x }
func at(_ h: Int, _ m: Int) -> ScheduleSensors { with { $0.minute = h * 60 + m } }
assert(scheduleHold(s, base) == nil && scheduleHold(s, with { $0.thermal = .critical; $0.onAC = false; $0.idleSeconds = 0 }) == nil)   // the default never holds
s.hot = true
assert(scheduleHold(s, with { $0.thermal = .serious })?.code == "hot" && scheduleHold(s, with { $0.thermal = .critical })?.reason == "the Mac is hot (critical)" && scheduleHold(s, with { $0.thermal = .fair }) == nil)
s.mode = "power"
assert(scheduleHold(s, with { $0.onAC = false })?.code == "power" && scheduleHold(s, base) == nil && scheduleHold(s, with { $0.onAC = nil }) == nil)   // unreadable power never holds
assert(scheduleHold(s, with { $0.onAC = false; $0.thermal = .serious })?.code == "hot")   // heat first
s.mode = "idle"; s.idle = 10
assert(scheduleHold(s, with { $0.idleSeconds = 599 })?.code == "idle" && scheduleHold(s, with { $0.idleSeconds = 600 }) == nil)
s.mode = "hours"; s.from = "09:00"; s.to = "17:00"
assert(scheduleHold(s, at(9, 0)) == nil && scheduleHold(s, at(16, 59)) == nil && scheduleHold(s, at(17, 0))?.code == "hours" && scheduleHold(s, at(8, 59))?.code == "hours")
s.from = "22:00"; s.to = "07:00"   // overnight
assert(scheduleHold(s, at(22, 0)) == nil && scheduleHold(s, at(23, 59)) == nil && scheduleHold(s, at(0, 0)) == nil && scheduleHold(s, at(6, 59)) == nil)
assert(scheduleHold(s, at(7, 0))?.code == "hours" && scheduleHold(s, at(21, 59))?.code == "hours" && scheduleHold(s, at(12, 0))?.reason == "outside mining hours 22:00–07:00")
func sch(_ mode: String, _ idle: Any, _ from: String, _ to: String) -> MiningSchedule? { MiningSchedule(["mode": mode, "idle": idle, "from": from, "to": to, "hot": true]) }
assert(sch("hours", 10, "22:00", "07:00") != nil && sch("hours", 10, "22:00", "22:00") == nil && sch("always", 10, "22:00", "22:00") != nil)
assert(sch("idle", 1, "22:00", "07:00") != nil && sch("idle", 120, "22:00", "07:00") != nil && sch("idle", 0, "22:00", "07:00") == nil && sch("idle", 121, "22:00", "07:00") == nil)
assert(sch("sometimes", 10, "22:00", "07:00") == nil && sch("hours", 10, "24:00", "07:00") == nil && sch("hours", 10, "7:00", "08:00") == nil && sch("hours", 10, "07:60", "08:00") == nil)
let saved = MiningSchedule(sch("idle", "30", "01:00", "02:00")!.dict)!
assert(saved.mode == "idle" && saved.idle == 30 && saved.hot && saved.from == "01:00" && MiningSchedule(MiningSchedule().dict) == MiningSchedule())
assert(minuteOfDay("00:00") == 0 && minuteOfDay("23:59") == 1439 && minuteOfDay("12:5") == nil)
let live = readScheduleSensors()
assert(live.idleSeconds >= 0 && (0..<1440).contains(live.minute))
// QR: decodes to the URI at level M; black and white only; 4-module quiet zone; finder patterns where they belong (not mirrored)
func finder(_ px: [UInt8], _ size: Int, _ r0: Int, _ c0: Int) -> Bool {
    for i in 0..<7 { for j in 0..<7 {
        let dark = px[((r0 + i) * 8 + 4) * size + (c0 + j) * 8 + 4] == 0, ring = i == 0 || i == 6 || j == 0 || j == 6, core = (2...4).contains(i) && (2...4).contains(j)
        if dark != (ring || core) { return false }
    } }
    return true
}
let addr = "TESTADDR"
for uri in ["xcoin:" + addr, "xcoin:" + addr + "?amount=12345678.12345678", "xcoin:" + addr + "?amount=0.5"] {
    let q = qrPNG(uri)!
    assert(q.dataURL.hasPrefix("data:image/png;base64,"))
    let png = Data(base64Encoded: String(q.dataURL.dropFirst("data:image/png;base64,".count)))!
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil)!
    let size = img.width, n = q.modules - 8
    assert(size == q.modules * 8 && img.height == size && n >= 21 && (n - 21) % 4 == 0)
    var px = [UInt8](repeating: 128, count: size * size)
    px.withUnsafeMutableBytes { CGContext(data: $0.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size)) }
    assert(Set(px).isSubset(of: [0, 255]))
    for i in 0..<size { for k in 0..<32 { assert(px[k * size + i] == 255 && px[(size - 1 - k) * size + i] == 255 && px[i * size + k] == 255 && px[i * size + size - 1 - k] == 255) } }
    assert(finder(px, size, 4, 4) && finder(px, size, 4, 4 + n - 7) && finder(px, size, 4 + n - 7, 4) && !finder(px, size, 4 + n - 7, 4 + n - 7))
    let f = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!.features(in: CIImage(cgImage: img)).first as? CIQRCodeFeature
    assert(f?.messageString == uri && (f?.symbolDescriptor as? CIQRCodeDescriptor)?.errorCorrectionLevel == .levelM)
}
assert(qrPNG("") == nil)
print("Schedule holds (always, heat, power, idle, same-day and overnight hours), its validation and live sensors, and QR decode/level M/quiet zone/orientation passed")
'''.replace('TESTADDR', test))
subprocess.run(['swiftc','-module-cache-path',str(root/'build/module-cache'),str(root/'Schedule.swift'),str(root/'QRCode.swift'),str(feature/'main.swift'),'-o',str(feature/'run')],check=True)
subprocess.run([str(feature/'run')],check=True)
subprocess.run(['node','--check',str(root/'app.js')],check=True)
# The real App code, headless: a recording page (no window, no menu bar item), a fake wallet CLI and home,
# a keychain-free ForumCredential, injected schedule sensors, /bin/sleep as the engine. No NFC, no network.
import shutil,os
hz=root/'build/harness';shutil.rmtree(hz,ignore_errors=True);(hz/'home/.xcoin').mkdir(parents=True);(hz/'fake').mkdir()
(hz/'home/.xcoin/wallet004.mmm').write_bytes(b'XCOINMMM2\n\0\0fake card wallet for the harness')
app_src=source[:source.index('@main\nstruct MMMMain')];(hz/'App.swift').write_text(app_src)
subprocess.run(['swiftc','-module-cache-path',str(root/'build/module-cache'),str(hz/'App.swift')]+[str(root/f) for f in ['MenuBar.swift','Pickaxe.swift','PoolCredential.swift','WalletService.swift','Schedule.swift','QRCode.swift']]+[str(root/'tests/harness/ForumCredentialStub.swift'),str(root/'tests/harness/main.swift'),'-o',str(hz/'mmm-harness'),'-framework','Cocoa','-framework','WebKit','-framework','Security','-framework','LocalAuthentication','-framework','IOKit','-framework','CoreImage'],check=True)
env={**os.environ,'CFFIXED_USER_HOME':str(hz/'home'),'HOME':str(hz/'home'),'XCOIN_WALLET_CLI':str(root/'tests/harness/fakecli'),'FAKE_DIR':str(hz/'fake'),'XCOIN_CARD_TIMEOUT':'5'}
subprocess.run([str(hz/'mmm-harness'),test,main],check=True,env=env,timeout=300)
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
assert 'func walletFinish(_ phase: String, _ extra: [String: Any] = [:]) { walletBusy = false; walletJob = nil; emit(["type": "cardPrompt", "phase": phase].merging(extra) { $1 }) }' in source
def body(text, start, end):
    i = text.index(start); return text[i:text.index(end, i)]
# 1. broadcast-begin commits the job on the reader thread: cancel() and the timeout refuse; only the n x 180 s backstop may stop it
assert 'static func broadcastBegin(_ line: String) -> Int?' in wallet and 'if let n = broadcastBegin(s) ?? provisioningBegin(s), commit(job, p) {' in wallet
assert 'guard !committed else { lock.unlock(); return false }' in body(wallet, 'func cancel() -> Bool', 'var isCommitted')
assert 'guard backstop || !committed else { return false }' in wallet and 'if more > 0 { arm(more) } else if job.expire() { signalTrees([pid], grace: 5) }' in wallet
assert 'Double(n) * broadcastBackstop) { if p.isRunning, job.expire(backstop: true)' in wallet and 'static let broadcastBackstop: TimeInterval = 180' in wallet
cancel = body(source, '@MainActor func walletCancel()', '/// LOCK:')
assert 'if walletCommitted { refuse(); return }' in cancel and 'guard job.cancel() else { refuse(); return }' in cancel
assert cancel.count('walletOp += 1') == 1 and cancel.index('walletOp += 1') < cancel.index('guard job.cancel()')   # a running CLI's exit still reports
assert 'if locks, !walletCommitted { walletCommitted = true; if !walletBackingUp, !walletNewCard { walletSendNote(["committed": true]) } }' in source   # a card write is no send
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
assert "'BROADCASTING — CANNOT CANCEL'" in page and "if(cardLocked(cardPhase))return;" in page and "cardLocked=p=>p==='broadcasting'||p==='provisioning'" in page
assert "txList('SENT:'" in page and "txList('NOT BROADCAST:',unsent.slice(1)" in page
# NOT SENT only where the network ANSWERED with a refusal (msg.refused); a lost connection's txid stays "check this txid"
unknown_path = body(page, "else{if(unsent[0])", "showReceipt(!!msg.partial")
assert 'NOT SENT' not in unknown_path and "Check this txid on the explorer before re-sending" in unknown_path
assert page.count("NOT SENT — THE NETWORK REFUSED IT") == 3 and "if(rf&&!ids.length){head.append(el('b','NOT SENT — THE NETWORK REFUSED IT'))" in page and "else if(rf){rest.push(el('small',`TRANSACTION ${rf.i} OF ${n}: NOT SENT — THE NETWORK REFUSED IT`" in page
refused_done = body(source, 'func walletSendDone(', '// Sign in to MineDifferent')
assert 'if let rj = walletRejected, r.code != 0 {' in refused_done and 'rj.i == 1' not in refused_done   # any refusal with nothing sent (the node path's check can name a later transaction) and 'walletFinish("failed", ["refused": true])' in refused_done and 'let refused = complete ? nil : walletRejected.flatMap { $0.i == txids.count + 1 ? $0 : nil }' in refused_done and '(d["broadcast_rejected"] as? Bool) == true' in refused_done
assert 'if let r = cliRejected(line) { walletRejected = r; return }' in body(source, 'func walletProgress(', 'func backupPrompt(') and 'walletCardSeen = false; walletRejected = nil' in source
# 7. quitting never kills a committed send: terminateAll skips it (commit shares its lock), the quit waits for the report
assert 'running.filter { !committed.contains($0.key) && $0.value.isRunning }' in wallet and 'if let n = broadcastBegin(s) ?? provisioningBegin(s), commit(job, p) {' in wallet
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
# 11. backup cards: card-provisioning commits the run like broadcast-begin (no CANCEL, no timeout, quits wait); card-status never taps
assert 'static func provisioningBegin(_ line: String) -> Int? { line.contains("XCOIN-EVENT card-provisioning") ? 1 : nil }' in wallet
backup = body(source, '@MainActor func walletBackup(', '// ── Mining schedule')
assert '["--json", "--file", f.path, "card-backup", "--auto-swap"]' in backup and 'gate: walletAuth)' in backup and backup.index('approve(') < backup.index('self.walletBackupRun(f, op: op)') < backup.index('WalletService.run(')
assert backup.count('walletBackupRun(') == 2   # run only after Touch ID
assert 'self.walletBackupDone(r, f)\n            self.quitIfReported()' in backup and 'if walletCancelling, unstarted { walletCancelled("Cancelled — nothing was written to a new card."); return }' in backup
assert 'let unstarted = !walletCommitted || cardWriteUnstarted(r)' in backup and 'why.lowercased().contains("do not rely on that card") ? why :' in backup   # the CLI's own warning is not said twice
assert '["--json", "--file", f.path, "card-status"], passphrase: ""' in source and 'if let sel { cardStatusRefresh(sel) }' in source and 'state["backup"] = backupState(sel)' in source
assert 'let refuse = { self.emit(self.walletLockedPrompt()) }' in cancel and 'emit(walletLockedPrompt(), menu: false)' in quit
assert 'return ["type": "cardPrompt", "phase": "provisioning", "written": walletWritten, "new": walletNewCard]' in source and 'if walletCommitted, p["cardRead"] != nil { walletWritten = true }' in source   # nothing after the write starts unlocks CANCEL
assert '"type": "walletCardCreated"' in source and "case 'walletCardCreated':" in page
# 12. FORUM: identity from key 101 of the bound/default wallet, on request only, cached per file identity; SETUP keeps mining only
ident = body(source, '@MainActor func forumIdentity(', '// ── WALLET tab: RECEIVE')
assert '"identity", "--index", "101"]' in ident and 'ids[key] = xid' in ident and 'let key = walletFileKey(f.path)' in ident and 'gate: walletAuth)' in ident
assert 'if let bound = ForumCredential.file, ForumCredential.exists()' in body(source, 'func forumWallet()', 'func forumIdCache()')
assert 'case "forumIdentity": forumIdentity(' in source and 'forumIdentity' not in body(source, 'func webView(_ webView: WKWebView, didFinish', 'func emit(')   # never read at load
assert 'let forumURL = URL(string: "https://minedifferent.com")!' in source and 'case "openForum": NSWorkspace.shared.open(forumURL)' in source
html=(root/'index.html').read_text()
vs,vf,vc=html.index('id="view-setup"'),html.index('id="view-forum"'),html.index('id="view-create"')
assert vc < vf < vs and html.index('id="loginForm"') > vf and html.index('id="loginForm"') < vs and html.index('id="scheduleForm"') > vs
assert html.index('id="tab-create"') < html.index('id="tab-forum"') < html.index('id="tab-setup"')
# 13. RECEIVE: the QR is drawn natively, level M, no third-party code, no network
qr=(root/'QRCode.swift').read_text()
assert 'CIFilter(name: "CIQRCodeGenerator")' in qr and 'f.setValue("M", forKey: "inputCorrectionLevel")' in qr and 'shouldInterpolate: false' in qr and 'http' not in qr
assert 'qrPNG(uri)' in body(source, 'func walletQR(', '// ── Backup cards') and 'qrcode' not in page.lower().replace('qr code','')
# 14. schedule: persisted, cleared by NUKE, never fights a manual STOP, gate before every engine start
nuke = body(source, '@MainActor func nukeInputs()', '// ── WALLET tab')
assert '"miningSchedule", "forumIdByFile", "forumLastSignIn",' in nuke and 'schedule = MiningSchedule(); schedulePaused = false; scheduleOverride = nil' in nuke
assert 'UserDefaults.standard.set(s.dict, forKey: "miningSchedule")' in source and 'case "stop": manualStop()' in source and 'menuBar.onStop = { [weak self] in self?.manualStop() }' in source
start = body(source, '@MainActor func start(user: Bool = false) async {', 'let host = p["host",default:""]')
assert start.index('if let hold = scheduleHoldNow(), scheduleOverride != hold.code {') < start.index('launching = true')
tick = body(source, '@MainActor func scheduleTick()', 'func scheduleEngineEnded()')
assert tick.index('guard !quitPending else { return }') < tick.index('let hold = scheduleHoldNow()')
assert 'guard process == nil, !launching, !quitPending else { return }' in start and 'guard process == nil, !launching, !quitPending else { return }' in body(source, '@MainActor func mineAnyway()', '@MainActor func scheduleSave(')
assert 'else if hold == nil, schedulePaused, process == nil, !launching {' in tick   # resumes only what the schedule held
assert 'schedulePaused = false; scheduleStopping = false; scheduleOverride = nil' in body(source, 'func manualStop()', '@MainActor func mineAnyway()')
assert 'Schedule.swift QRCode.swift -o "$APP/Contents/MacOS/MMM"' in (root/'build.sh').read_text() and '-framework IOKit -framework CoreImage' in (root/'build.sh').read_text()
assert 'case "schedule":' in menubar and '"Paused"' in menubar
# 15. layout: fixes the headless-Chrome probe verified (overflow, spill, overlap), and contrast computed from the stylesheet
assert '.hash-panel{min-width:0}' in css                                                  # a long pause status never pushes START off-screen
# the lime panel follows the hero's own height: the offer and the held note take the title's place; the footnote, tagline and title size give way when the hero is short
assert '.hero-grid{container-type:size}' in css and '.control-panel:has(#schedOffer:not([hidden])) :is(.eyebrow,h2),.control-panel:has(#actionNote.held:not([hidden])) :is(.eyebrow,h2){display:none}' in css
assert '@container (max-height:250px){.control-panel .eyebrow{display:none}}' in css and '@container (max-height:228px){.sched-offer small{display:none}}' in css and '@media(min-height:781px){@container (max-height:225px){.control-panel h2{font-size:26px}}}' in css
assert 'max-height:720px){.control-panel:has(#schedOffer' not in css and '@media(max-height:900px){.intro .eyebrow{display:none}}@media(min-height:901px){.intro{height:auto}}' in css   # the dashboard tagline is never cut off
assert "$('actionNote').classList.toggle('held',sched.paused&&!running)" in page
assert 'grid-template-areas:"lbl amt" "who note"' in css and 'has-rv' not in css + page and 'rv-btn' not in css + page   # RECEIVE left the row; label over address, balance over note
wstate = html[html.index('class="wallet-state"'):html.index('id="walletLockBtn"')]
assert 'id="walletRxBtn"' in wstate and wstate.index('id="walletRxBtn"') < wstate.index('id="walletState"')   # RECEIVE sits in the header beside LOCK
assert 'aria-modal="true"' in html and "for(const e of rvBeneath())e.inert=true" in page and "if(open&&back&&!$('walletRxBtn').hidden)$('walletRxBtn').focus()" in page
note_rule = css[css.index('.backup-badge.note{'):css.index('}', css.index('.backup-badge.note{'))]
assert 'white-space:normal' in note_rule and 'clamp' not in note_rule and 'overflow:hidden' not in note_rule and "cls='note';tip=text" in page and ".dex{" not in css   # the whole note, wrapped
assert '"note": text(d["note"], 600)' in source
assert '.backup-prompt .text-button{padding:0;border:0;background:transparent' in css   # LATER is never a white box
assert "$('rvQr').hidden=!!m.error" in page                                            # no empty white QR box on an error
import re
def hexrgb(h):
    h=h.lstrip('#'); h=''.join(c*2 for c in h) if len(h)==3 else h; return [int(h[i:i+2],16) for i in (0,2,4)]
def lum(h):
    f=lambda v:(v/255)/12.92 if v/255<=0.03928 else ((v/255+0.055)/1.055)**2.4
    r,g,b=hexrgb(h); return 0.2126*f(r)+0.7152*f(g)+0.0722*f(b)
def ratio(a,b):
    x,y=sorted([lum(a),lum(b)],reverse=True); return (x+0.05)/(y+0.05)
light_err=re.search(r'\n\.rv-note\.err\{color:(#[0-9a-fA-F]{3,6})',css).group(1); dark_err=re.search(r'\[data-theme=dark\] \.rv-note\.err\{color:(#[0-9a-fA-F]{3,6})',css).group(1)
assert '.wallet-receive{' in css and 'background:var(--paper)' in css[css.index('.wallet-receive{'):css.index('}',css.index('.wallet-receive{'))]
assert ratio(light_err,'#ffffff')>=4.5 and ratio(dark_err,'#10110e')>=4.5, (light_err,dark_err)
m=re.search(r'\[data-theme=dark\] \.engine-log pre\{background:(#[0-9a-fA-F]{6});color:(#[0-9a-fA-F]{6})\}',css)
assert m and ratio(m.group(2),m.group(1))>=4.5 and 'pre{background:var(--ink);color:#bbb;' in css and ratio('#bbbbbb','#0a0a0a')>=4.5   # the engine log, both themes
# 16. start(): a quit that began during any of its network waits launches nothing; the harness never uses 47476
start_all = body(source, '@MainActor func start(user: Bool = false) async {', '/// RESET:')
assert start_all.count('guard process == nil, profile == p, !quitPending else { return }') == 2 and 'guard process == nil, profile == p else' not in start_all
assert source.count('47476') == 1 and 'var statsPort = 47476' in source and '"--stats-port",String(statsPort)]' in source and '"http://127.0.0.1:\\(statsPort)/health"' in source and '"http://127.0.0.1:\\(statsPort)/stats"' in source
# 17. a reader reset: a fresh card wait on the banner, and the run's timeout grows by it
assert 'if phase == "retry" { walletJob?.extend(by: TimeInterval(cardWaitBudget(ProcessInfo.processInfo.environment))) }' in source and 'let more = job.takeExtension()' in wallet
assert "if(cardWaits(m.phase)&&(m.phase==='tap'||m.seconds))" in page and "Math.floor((on-15000)/4000)%2===0" in page   # the hint first at 15 s
# 18. a later refusal in plain words; new card wallets commit their card write like a backup card
assert 'let why = (d["broadcast_error"] as? String).map(plainBroadcastError) ??' in source
create = body(source, 'func walletCreate(name rawName: String', 'func walletUnlock(')
assert 'let op = walletBegin(); walletNewCard = card' in create and create.count('self.quitIfReported()') == 2 and 'self.walletNewCardFailed(r, newKeys: self.cardKeyFiles().subtracting(keysBefore), path: path, name: name)' in create
newfail = body(source, 'func walletNewCardFailed(', 'func cardKeyFiles()')
assert newfail.index('if FileManager.default.fileExists(atPath: path) {') < newfail.index('No wallet was created')   # a wallet file already written is never "no wallet was created"
assert 'walletNewCard ? "Finishing the new card — MMM quits when it is done."' in quit and 'walletBackingUp || walletNewCard ? ["type": "cardPrompt", "phase": "provisioning", "quitting": quitPending, "new": walletNewCard]' in source
keys = body(source, 'func cardKeyFiles()', 'func walletUnlock(')
assert 'contentsOfDirectory' in keys and 'Data(contentsOf' not in keys and 'String(contentsOf' not in keys   # key file names only, never their contents
assert 'var signal: Int32 = 0' in wallet and 'signal: p.terminationReason == .uncaughtSignal ? p.terminationStatus : 0)' in wallet
# 21. the SIGKILL after a SIGTERM's grace spares a run that committed during it (only the backstop forces it); a timeout is a run the timeout ended
assert 'let spared = force ? [] : committedPids()' in wallet and 'send(SIGKILL, to: alive(stoppable()))' in wallet and 'signalTrees([pid], grace: 5, force: true)' in wallet
assert wallet.count('force: true') == 1 and 'timedOut: job.didExpire && p.terminationReason == .uncaughtSignal' in wallet
# 22. page: RECEIVE closes on leaving WALLET; controls under the banner are inert while it shows; metrics fit; the log wraps; the heading is not cut
assert "if(name!=='wallet'&&!$('walletReceive').hidden)closeReceive();" in page and "if(name==='create'&&!$('walletSeedBox').hidden)$('walletSeedBox').scrollIntoView({block:'nearest'});" in page
assert "function bannerCover(up){for(const e of document.querySelectorAll('.view>.workspace:first-child>.panel-title :is(button,a,input,select),#payout'))e.inert=up}" in page
assert "b.hidden=false;bannerCover(true);" in page and "if(end)cardTimer=setTimeout(bannerHide,4000);" in page and page.count('bannerHide()') >= 2 and "$('cardBanner').hidden=true" not in page.replace("function bannerHide(){$('cardBanner').hidden=true;", '')
assert "main:has(#cardBanner:not([hidden])) :is(#view-setup,#view-create .workspace,#view-forum .workspace){scroll-padding-top:72px}" in css
assert "notice('Write the seed of '+msg.name+' on paper now: it is on the NEW WALLET tab and is shown only once.',true)" in page
assert "fitMetrics();" in body(page, 'function render(){', 'function setRunning(') and "renderLog();receiptFit();fitMetrics()" in page
assert '.engine-log pre{white-space:pre-wrap;word-break:normal;overflow-wrap:anywhere}' in css and 'while(n>1&&e.scrollHeight>e.clientHeight+1)' in page
assert '@media(max-height:780px){.intro{align-items:flex-start}.intro h1{margin-top:3px}}' in css
assert '@media(max-height:680px){#walletPanel:has(#walletReceipt:not([hidden])) .backup-badge.note{font-size:9px;line-height:1.2;letter-spacing:0}}' in css
harness = (root/'tests/harness/fakecli').read_text()
assert '"broadcast rejected: missing-inputs"' in harness and 'bad-txns-inputs-missingorspent' not in harness   # what the explorer path really answers (testmempoolaccept)
# 19. the balances keep one whole row after a send: the receipt gives way first, down to 45 px (probe-verified at 940x612…1100x740)
assert '.wallet-balances{flex:1;min-height:min(78px,max(44px,calc(100cqh - var(--wa-rest) - 45px)));' in css and 'container-type:size;--wa-rest:113px}' in css and '.wallet-body{--wa-rest:93px}}' in css and 'min-height:48px;overflow-y:auto' not in css
assert '.metric strong{display:block;font-size:23px;margin-top:12px;letter-spacing:-1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}' in css
assert "const hashUnit=h=>h>=1e15?[1e15,'P']:h>=1e12?[1e12,'T']:h>=1e9?[1e9,'G']:[1e6,'M'];" in page and "b.scrollIntoView({block:'nearest'})" in page
assert "document.addEventListener('keydown',rvKeys);" in page and '$(\'walletReceive\').onkeydown' not in page and 'aria-label="Receive XID" tabindex="-1"' in html
# 20. contrast: the focus ring on every surface it sits on (3:1), NUKE's small label (4.5:1, both themes, hover), placeholders (4.5:1)
ring=re.search(r':focus-visible\{outline:3px solid (#[0-9a-fA-F]{6});',css).group(1)
for bg in ['#ffffff','#c7ff2e','#ffe0d9','#f4f4ef','#10110e','#151810','#1d2313']: assert ratio(ring,bg)>=3,(ring,bg,ratio(ring,bg))
nl=re.search(r'#nukeBtn\{border:2px solid (#[0-9a-fA-F]{6});color:(#[0-9a-fA-F]{6});',css); nd=re.search(r'\[data-theme=dark\] #nukeBtn\{border-color:(#[0-9a-fA-F]{6});color:(#[0-9a-fA-F]{6})\}\[data-theme=dark\] #nukeBtn:hover\{background:(#[0-9a-fA-F]{6});color:(#[0-9a-fA-F]{6})\}',css)
assert ratio(nl.group(2),'#ffffff')>=4.5 and ratio('#ffffff',re.search(r'#nukeBtn:hover\{background:(#[0-9a-fA-F]{6});color:#fff\}',css).group(1))>=4.5 and ratio(nd.group(2),'#151810')>=4.5 and ratio(nd.group(4),nd.group(3))>=4.5
assert '::placeholder{color:var(--muted);opacity:1}' in css and ratio('#6b6b63','#ffffff')>=4.5 and ratio('#a0a596','#10110e')>=4.5 and '--muted:#6b6b63' in css and '--muted:#a0a596' in css
print('Page layout fixes (hero min-width, lime panel sized by its hero with the offer and held note in the title\'s place, tagline, two-line wallet rows, RECEIVE in the header, modal RECEIVE, note badge, LATER, QR box) and contrast of RECEIVE errors and the engine log in both themes passed')
print('Balances keep a whole row after a send, metric values never wrap (and shrink to fit), focus ring / NUKE / placeholder contrast, RECEIVE keys document-wide and closed off its tab, seed box in view, controls under the card banner inert, engine log wrapped, dashboard heading whole passed')
print('SIGKILL spared for a run committed during the grace, timeouts only for runs the timeout ended, refusals with nothing sent for any transaction, and a written new-card wallet file never reported as not created passed')
print('Password pipe, JSON escaping, log redaction, wallet events/cancel/split contract, broadcast commit, cancel reporting, Touch ID gates, fresh balance check, quit deferral and single quit path, send record, message types, save refusal, explorer links, backup-card and new-card commit and cancel, card-status, forum identity, RECEIVE QR, schedule contract and quit guard (after network waits too), refused sends in plain words, reader-reset timeout, and JS syntax passed')
