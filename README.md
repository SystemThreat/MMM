# MMM — Nerd Stats Edition

Native Mac miner for xCoin Ӿ (XID). Mainnet is live since September 26, 2026 at 00:00 UTC (explorer: superknet.com); testnet A is retired. Supply is capped at 100,000,000 XID, issued by "the Annual Tenth": a 6.25 / 12.5 / 25 XID warm-up, 50 XID per block to block 220,000, then 10% less every 110,000 blocks down to a 1.5 XID floor.

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

`Engine/` is a self-contained copy of the user's Miner sources, under the same license as the app. The only mining-protocol changes are stdin password support and safe JSON escaping / redaction of authorization. The original Miner directory is untouched. The native app uses local stats port 47476 to avoid the CLI's default companion port. Signing is local ad-hoc signing, not Apple notarization.

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

## Wallets and the forum

MMM is a miner. Its tabs are DASHBOARD, BLOCKS, MINERS and SETUP; the WALLET, NEW WALLET and FORUM tabs were removed on 2026-10-23. Sending, receiving, making wallets and backup cards, and signing in to MineDifferent now happen in **XID Wallet for Mac** ([SystemThreat/apple-mac-xcoin-wallet-gui](https://github.com/SystemThreat/apple-mac-xcoin-wallet-gui)) or the xcoin-wallet CLI. MMM only needs the payout address you type in SETUP.

Wallet files MMM made earlier are untouched in `~/.xcoin` (and card keys in `~/.dex-wallet`); XID Wallet and the CLI open them.

## The hashrate chart

The dashboard's chart shows the last 150 readings (about five minutes), scaled to their own range (at least 1% of the peak), so real swings in the hashrate are visible instead of a flat line near the top.

## License

MMM is **proprietary, source-available software** (see [LICENSE](LICENSE)). The code is
public so anyone can inspect and audit what runs on their Mac, and build it to check that a
release matches this source. Redistribution, modified versions and commercial use need
written permission. Releases before 2026-09-26 were published under the MIT License and stay
under it for those versions. The bundled wallet CLI (MIT) and its post-quantum crypto code
(CC0) keep their own licenses.

