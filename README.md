# MMM — Nerd Stats Edition

Native Mac miner for xCoin Ӿ (XCF). Testnet A is live now; mainnet genesis is September 30, 2026.

Native Apple Silicon macOS app wrapping the existing NerdMiner MetalDAG engine, with a local WebKit dashboard. macOS 14+ and Xcode Command Line Tools are required to build.

```sh
./build.sh             # build/MMM.app, including the black / acid-lime MMM icon
./build.sh --install   # also install to ~/Applications and pin to the Dock
python3 tests/check.py # address / integration checks, without starting mining
```

Open MMM, enter the payout address, IP address (or hostname), port, worker and optional pool password, then Start Mining. Those four connection fields start blank. Start saves the current settings. Pool passwords are saved in macOS Keychain when you save Setup and travel to the engine through stdin; they are never stored in preferences or printed in logs. Saving an empty password clears the credential for that connection. Stop or explicitly quitting MMM terminates only the engine process MMM launched. Minimizing or closing the main window keeps MMM and its mining engine running in the menu bar. This uses ordinary Stratum TCP, whose pool authentication is not encrypted.

Testnet A addresses (`txa1r…`) and mainnet addresses (`xpa1r…`) are validated as 32-byte witness-v3 bech32m addresses. Select the matching network. Mainnet requires an explorer reporting `hrp=xpa`, a final genesis charter and a block-zero timestamp; that timestamp is passed as the MetalDAG epoch base. Mainnet will not silently replace the selected testnet network. Configure its pool and explorer when they are available.

The testnet explorer defaults to https://superknet.com. The existing miner documentation identifies the rehearsal pool as 172.96.186.49 port 3335; it is deliberately not prefilled. No wallet keys or seed phrases are needed. The GUI does not generate a wallet or invent a payout address.

## Window and menu bar

Dashboard, Blocks, Miners and Setup are four separate tabs sized to the window. Block and miner tables have Previous / Next controls; the Setup log shows its latest lines with a Copy Log button for the full recent log. The green dark-mode switch remembers your preference and initially follows the system appearance.

The menu-bar pickaxe shows the local hashrate and animates while the engine runs (respects Reduce Motion). Click it for a native black-and-lime dropdown with shares, blocks, uptime, Stop Mining and Full View. Full View or clicking the Dock icon restores the main window. Closing the main window hides it; use Quit MMM to stop the app and engine. Local stats refresh independently every two seconds, even when an explorer request is slow or the window is minimized. The build script shows named stages, commands, process IDs, elapsed time and compiler error logs.

The mini explorer reads `/api/stats`, `/api/network` and the eight latest `/api/block/<height>` records. Recent blocks show actual coinbase outputs, truncated payout addresses and tetromino marks. Pool online status uses the last activity timestamp (five minutes); pool block counters are explicitly separate from chain-confirmed rewards. Missing connections show unavailable states rather than sample data. The current explorer's registry determines which miners are visible; it is not a discovery protocol for every miner worldwide.

Tetromino artwork reuses MineDifferent's HMAC-SHA256 / xorshift128 generator. Payout addresses seed the marks because the explorer does not provide the corresponding private-key-derived forum identity. Equal payout addresses have equal marks; mainnet and testnet address strings may have different marks.

`Engine/` is a self-contained copy of the user's Miner sources, preserving its license. The only mining-protocol changes are stdin password support and safe JSON escaping / redaction of authorization. The original Miner directory is untouched. The native app uses local stats port 47476 to avoid the CLI's default companion port. Signing is local ad-hoc signing, not Apple notarization.

## Automatic mining

Start mining when MMM opens is enabled by default. Uncheck it in Setup to disable it; the checkbox saves immediately and does not stop a current session. On each app launch MMM makes one automatic start attempt using saved valid connection settings. Incomplete settings open Setup instead. Mainnet keeps its existing genesis checks. This does not add MMM as a macOS login item. Save Setup once after upgrading so any required pool password is stored in Keychain; macOS may request Keychain access after a rebuild.

## Forum sign-in (MineDifferent)

Setup tab → **SIGN IN TO MINEDIFFERENT**. One click mints a challenge, signs it
with this Mac's wallet key (index 101, the forum identity convention) using the
bundled engine, and opens a one-time login link in your browser. If your wallet
carries a passphrase, type it in the field first — it travels only over the
engine's stdin, never argv or the environment. No password, no email: the
account IS the post-quantum signature.

The same thing from Terminal, if you prefer:

```
~/Applications/MMM.app/Contents/Resources/NerdMiner login
```
