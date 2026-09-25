# Verification

- Native GUI and bundled MetalDAG engine compile successfully with the installed Swift toolchain.
- Installed app signature and Info.plist validate; all WebKit resources and the ICNS icon are present.
- Nine address checks pass: testnet, mainnet, uppercase, cross-network rejection, checksum rejection, mixed-case rejection, witness-v2 rejection and nonzero padding rejection.
- JavaScript syntax passes and script-to-address decoding matches a real block from the live testnet explorer.
- Live explorer APIs returned testnet A height 872, 14-coin coinbase payouts and the miner registry during verification.
- Password input is transported through stdin, JSON-escaped for Stratum authorization, and redacted from engine logging. Password is not stored in preferences.
- Project copied to /Users/david/x-Coin/MMM; app copied to /Users/david/Applications/MMM.app. One MMM Dock entry is persisted.

Desktop control was unavailable in this session. LaunchServices returned -10827 despite a present, executable, signed arm64 binary; Dock refresh was blocked by process-control restrictions. The native app window and live mining session were not visually/end-to-end verified. Open MMM from your Applications folder in your normal desktop session. No mining was started because no payout address or connection settings were supplied. Mainnet activation is implemented and address-tested; live mainnet mining awaits the launched network and its endpoints.

## Four-tab and menu-bar update

- Compiled the updated native app with MenuBar.swift; signed app verification passes.
- Functional JavaScript tests pass for tab selection, hidden panels, pagination boundaries, short table heights and saved dark/light theme selection.
- All nine payout-address checks continue to pass.
- Checked balanced HTML and four labelled tab panels. Tables paginate based on the available view height; the engine log displays only its latest fitting lines and supports copying the retained log.
- Build stages now show their real command, process ID, elapsed time, spinner, success or error output. A full build completed all five stages.
- Menu-bar implementation uses native NSStatusItem / NSPopover, a template pickaxe with Reduce Motion support, independent local stats polling and explicit window restoration. A mining activity assertion keeps the app active while hidden and prevents idle system sleep during a mining session. Explicit sleep/lid closure can still suspend the Mac.
- Source and compiled app updated in /Users/david/x-Coin/MMM. The installed app is left for the user to quit and update with ./build.sh --install so an ongoing mining session is not interrupted.
- Native visual inspection and live menu-bar interaction were not available in this session; these remain desktop verification steps after installation.

## Large interface update

Enlarged body/table text to 16 px, form fields to 18 px, navigation to 16 px and principal buttons to 17 px. Increased tracking, line heights, table rows and control sizes. The menu-bar dropdown is now 400 × 400 with larger native labels and buttons. Pagination reads row/header dimensions from CSS so increasing font size reduces rows instead of overflowing. Short windows omit the decorative dashboard heading and footer to preserve working space. JS functional checks, Swift compilation and signed bundle verification pass. Desktop visual verification remains pending.

## Automatic mining update

Compiled and signed the default-on app-launch mining change, immediate Setup opt-out, and Keychain credential storage. Nine address checks and six startup-configuration cases pass, alongside existing view/theme checks. Keychain access and actual automatic mining were not exercised against the user account or GPU. No login item was added.
