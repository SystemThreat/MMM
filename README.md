# MMM — Nerd Stats Edition

Native Mac miner for xCoin Ӿ (XID). Testnet A is retiring and testnet B is launching; mainnet genesis is November 1, 2026. Supply is capped at 100,000,000 XID, issued by "the Annual Tenth": a 6.25 / 12.5 / 25 XID warm-up, 50 XID per block to block 220,000, then 10% less every 110,000 blocks down to a 1.5 XID floor.

Native Apple Silicon macOS app wrapping the existing NerdMiner MetalDAG engine, with a local WebKit dashboard. macOS 14+ and Xcode Command Line Tools are required to build.

```sh
./build.sh             # build/MMM.app, including the black / acid-lime MMM icon
./build.sh --install   # also install to ~/Applications and pin to the Dock
python3 tests/check.py # address / integration checks and a headless App harness (fake wallet CLI), without starting mining
```

Open MMM, enter the payout address, IP address (or hostname), port, worker and optional pool password, then Start Mining. Those four connection fields start blank. Start saves the current settings. Pool passwords are saved in macOS Keychain when you save Setup and travel to the engine through stdin; they are never stored in preferences or printed in logs. Saving an empty password clears the credential for that connection. Stop or explicitly quitting MMM terminates only the engine process MMM launched. Minimizing or closing the main window keeps MMM and its mining engine running in the menu bar. This uses ordinary Stratum TCP, whose pool authentication is not encrypted.

Testnet A addresses (`txa1r…`) and mainnet addresses (`xpa1r…`) are validated as 32-byte witness-v3 bech32m addresses. Select the matching network. Mainnet requires an explorer reporting `hrp=xpa`, a final genesis charter and a block-zero timestamp; that timestamp is passed as the MetalDAG epoch base. Mainnet will not silently replace the selected testnet network. Configure its pool and explorer when they are available.

The testnet explorer defaults to https://superknet.com. The existing miner documentation identifies the rehearsal pool as 172.96.186.49 port 3335; it is deliberately not prefilled. No wallet keys or seed phrases are needed. The GUI does not generate a wallet or invent a payout address.

## Window and menu bar

Dashboard, Blocks, Miners, Wallet, New Wallet, Forum and Setup are seven separate tabs sized to the window. Block and miner tables have Previous / Next controls; the Setup log shows its latest lines with a Copy Log button for the full recent log. The green dark-mode switch remembers your preference and initially follows the system appearance.

The menu-bar pickaxe shows the local hashrate and animates while the engine runs (respects Reduce Motion). Click it for a native black-and-lime dropdown with shares, blocks, uptime, Stop Mining and Full View. While the mining schedule holds the engine it reads Paused, with the reason in its tooltip and dropdown. Full View or clicking the Dock icon restores the main window. Closing the main window hides it; use Quit MMM to stop the app and engine. Local stats refresh independently every two seconds, even when an explorer request is slow or the window is minimized. The build script shows named stages, commands, process IDs, elapsed time and compiler error logs.

The mini explorer reads `/api/stats`, `/api/network` and the eight latest `/api/block/<height>` records. Recent blocks show actual coinbase outputs, truncated payout addresses and tetromino marks. Pool online status uses the last activity timestamp (five minutes); pool block counters are explicitly separate from chain-confirmed rewards. Missing connections show unavailable states rather than sample data. The current explorer's registry determines which miners are visible; it is not a discovery protocol for every miner worldwide.

Tetromino artwork reuses MineDifferent's HMAC-SHA256 / xorshift128 generator. Payout addresses seed the marks because the explorer does not provide the corresponding private-key-derived forum identity. Equal payout addresses have equal marks; mainnet and testnet address strings may have different marks.

`Engine/` is a self-contained copy of the user's Miner sources, preserving its license. The only mining-protocol changes are stdin password support and safe JSON escaping / redaction of authorization. The original Miner directory is untouched. The native app uses local stats port 47476 to avoid the CLI's default companion port. Signing is local ad-hoc signing, not Apple notarization.

## Automatic mining

Start mining when MMM opens is enabled by default. Uncheck it in Setup to disable it; the checkbox saves immediately and does not stop a current session. On each app launch MMM makes one automatic start attempt using saved valid connection settings. Incomplete settings open Setup instead. Mainnet keeps its existing genesis checks. This does not add MMM as a macOS login item. Save Setup once after upgrading so any required pool password is stored in Keychain; macOS may request Keychain access after a rebuild.

## Mining schedule

Setup → SCHEDULE: Always (the default); only on the power adapter; only when the Mac has been
idle for N minutes (1–120); or only between two times (overnight ranges such as 22:00–07:00
work). "Pause when the Mac is hot" adds a heat check (thermal state serious or critical). MMM
checks every 20 seconds (heat at once). When the schedule says pause, a running engine is stopped
gracefully and the dashboard and menu bar say PAUSED BY SCHEDULE and why; it starts again when
the schedule allows. Auto-start and START MINING follow the schedule too: a START while it holds
says why and offers MINE ANYWAY (runs until the schedule's verdict next changes) or STAY STOPPED.
A manual STOP is never undone by the schedule, and while MMM is quitting (waiting for a send or a
backup card to finish) nothing starts mining. The schedule is saved on change; NUKE clears it.

## Wallet tab — send XID

The WALLET tab turns MMM into a spending wallet without ever holding a key.
Balances are public reads of the configured explorer (`/api/utxos`); unlocking
derives this Mac's wallet address (key index 0) through the bundled xcoin-wallet
CLI, and every send is approved with Touch ID (or the Mac password). Signing
happens in the CLI's offline keytool — the ML-DSA-65 witness v3 path validated
against the node's own test vectors — and the explorer only relays the one
signed transaction. The wallet passphrase travels exclusively over the child
process's stdin, is stored (if you opt in) in the login Keychain, and is never
placed in an argument list, an environment variable, or a log. If your mining
payout address differs from the wallet's key 0, the tab shows both balances and
says plainly which one a send draws from.

Once a send starts broadcasting it can no longer be cancelled. Quitting MMM then
(⌘Q, the menu bar, the Dock, logout, `kill`), however often, waits for it to
finish, records its outcome (one that did not all go out is shown again on the
WALLET tab at the next launch) and quits. A partial send's receipt lists its txids
under SENT and NOT BROADCAST, and first the one whose broadcast result is unknown.
If MMM dies mid-broadcast anyway (a crash, a force quit), the wallet CLI still
finishes its broadcasts, and the next launch says so with the wallet address:
check it on the explorer before sending again.

When the explorer or node answers a send with a refusal (for example, the coins
are already being spent by an earlier send that has not confirmed yet), nothing of
it went out, and the receipt says so with certainty: NOT SENT — THE NETWORK REFUSED
IT, with the reason in plain words and in full; the send form keeps what you typed
so you can send again after the next block. If a later transaction of a split send
is refused, the receipt lists what went out under SENT and the refused one and the
rest under NOT SENT, again with the reason in plain words. Only a lost connection
(no answer at all) keeps the "check this txid on the explorer" wording.

The card banner counts down each tap. If nothing is read for 15 seconds it adds
NOTHING DETECTED? UNPLUG THE READER, PLUG IT BACK IN, TAP AGAIN; if the reader resets
the card while it is being read, the banner says so and the wallet CLI reads it
again (never during a write) while you keep the card on the reader. That new wait
gets its own countdown (and the same hint after 15 seconds), and the action's time
limit grows by it. While the banner shows, Tab skips the buttons it covers (the
WALLET header's buttons, BLOCKS' REFRESH, SETUP's auto-start box and NUKE, the
dashboard's payout line); they come back when it closes.

RECEIVE (in the WALLET header, beside LOCK, once unlocked) shows a QR code of the payment request
`xcoin:<address>`, or `xcoin:<address>?amount=<xcf>` when an amount is typed (dot
decimals, up to 8), with the request and the plain address to copy. MMM draws the
QR itself with Core Image (error correction M, black on white with a quiet zone, in
either theme); nothing goes over the network. While it is open, Tab stays inside it;
Escape or CLOSE returns to the RECEIVE button. Going to another tab closes it.

Card wallets show their backup state in the WALLET header, read with
`card-status` (no tap): BACKED UP ✓ (N cards) or NO BACKUP CARD ⚠. When a backup
card cannot be made on this Mac (the cards were set up on another Mac, the card
libraries are missing, or a dex-wallet-era wallet), the header shows the CLI's reason
instead, in a plain badge, and no MAKE BACKUP CARD button. MAKE BACKUP CARD asks for Touch ID,
then runs `card-backup --auto-swap`: tap the wallet card, and when the banner says
so, swap it for a new blank card — no key press. CANCEL works until the new card is
being written; from then on nothing interrupts the write (quitting waits for it). A
CANCEL, quit or time limit that arrives just as the write begins does not cut it off
either: the write finishes (after a CANCEL, MMM says it came too late).
Right after a card wallet is created, NEW WALLET asks for a backup card at once:
without one, losing the card loses the wallet. Creating a card wallet follows the
same rule as a backup card: once the wallet CLI says the new card is being written,
CANCEL is refused and quitting waits. If a creation stops part-way, MMM says whether
the new card was left part-way set up (a key file for it appeared on this Mac):
then do not rely on that card. If the wallet file was already saved when it stopped,
MMM says so instead: UNLOCK it with the new card to check that the card opens it.
A normal wallet's seed is shown once on NEW WALLET; if it arrives while you are on
another tab, the notice says it is waiting there until you press I WROTE IT DOWN.

## Forum sign-in (MineDifferent)

FORUM tab → **SIGN IN TO MINEDIFFERENT**. One click mints a challenge, signs it
with this Mac's wallet key (index 101, the forum identity convention) using the
bundled engine, and opens a one-time login link in your browser. If your wallet
carries a passphrase, type it in the field first — it travels only over the
engine's stdin, never argv or the environment. Leave **Remember with Touch ID**
checked and, after the first sign-in that works, the passphrase is kept in your
login Keychain: from then on the button is SIGN IN WITH TOUCH ID and reading it
back always demands Touch ID (or your Mac password when the lid is closed).
FORGET SAVED PASSPHRASE removes it. No password, no email: the account IS the
post-quantum signature.

SHOW MY IDENTITY reads your forum name — the xid1… of key index 101 of the wallet
that signs in (the one the saved passphrase belongs to, else the default) — with its
mark and COPY. It is a sign-in name, not a payment address: nothing can be paid to
it. Reading it may take the passphrase (typed, or the saved one after Touch ID) or a
card tap; MMM then remembers it for that wallet file. The tab also shows the last
sign-in from this Mac and opens the forum.

The same thing from Terminal, if you prefer:

```
~/Applications/MMM.app/Contents/Resources/NerdMiner login
```
