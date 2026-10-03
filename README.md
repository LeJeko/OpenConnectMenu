# OpenConnectMenu

[Français](README.fr.md) · **English**

A macOS menu bar app that connects to a VPN using **[openconnect](https://www.infradead.org/openconnect/)**, and never asks for an administrator password again after the initial setup. It supports every protocol openconnect does (Cisco AnyConnect / ocserv, Juniper, GlobalProtect, Pulse, F5, Fortinet, Array); AnyConnect is the one that has been tested.

- One-click connect and disconnect from the menu bar. `openconnect` computes the 6-digit TOTP code for you.
- Password and TOTP secret are stored in the Keychain.
- A small privileged helper (a LaunchDaemon running as root) does the work that needs administrator rights, and only answers the signed app.
- Menu bar icon: closed padlock (connected) · crossed-out padlock (disconnected) · padlock with a circular arrow (operation in progress).
- English and French, following the system language.
- Can be configured by a macOS configuration profile (manual install or MDM).

## Contents

1. [Install](#install)
2. [First run](#first-run)
3. [Everyday use](#everyday-use)
4. [Configuration profile (MDM)](#configuration-profile-mdm)
5. [How it works](#how-it-works)
6. [Security model](#security-model)
7. [Building from source](#building-from-source)
8. [Languages](#languages)
9. [Troubleshooting](#troubleshooting)
10. [Uninstalling](#uninstalling)
11. [Project layout](#project-layout)
12. [Limitations and known issues](#limitations-and-known-issues)
13. [License](#license)

## Install

### With Homebrew (recommended)

```bash
brew install --cask LeJeko/openconnectmenu/openconnectmenu
```

This installs the signed and notarized package and, as a dependency, the `openconnect` formula. Update with `brew upgrade --cask openconnectmenu`.

### With the installer package

Download `OpenConnectMenu-<version>.pkg` from the [Releases](../../releases) page and open it. `openconnect` must be installed separately (`brew install openconnect`); the installer warns you if it cannot find it.

### Requirements

- macOS 13 or later, on **Apple silicon and Intel** (universal binary).
- [Homebrew](https://brew.sh) with `openconnect`.
- A VPN server that speaks one of the protocols **openconnect** supports (AnyConnect / ocserv, Juniper Network Connect, Palo Alto GlobalProtect, Pulse Connect Secure, F5 BIG-IP, Fortinet FortiGate, Array Networks) and authenticates with a username, a password and a **TOTP** code. Only AnyConnect has been tested: see [Limitations](#limitations-and-known-issues).

## First run

Needed once.

1. **Allow the helper.** On first launch the app registers its helper and macOS shows a notification. Go to **System Settings → General → Login Items & Extensions** and enable the *OpenConnectMenu* helper. The menu also offers *Open Login Items…*.
2. **Approve openconnect.** The menu shows "openconnect has not been approved yet". Click **Approve openconnect…**, check the path and version, then enter your administrator password. This is the only administrator password you are ever asked for. See [Binary pinning](#binary-pinning).
3. **Fill in the settings.** Menu → **Settings…**:

| Field | Value |
|---|---|
| Address | The VPN server, `https://…` (required) |
| Protocol | The VPN protocol, `Cisco AnyConnect / ocserv` by default (see the list above) |
| Authentication group | The login group of your VPN profile (optional; its meaning depends on the protocol) |
| User-Agent | Optional. Left empty, openconnect uses the one that fits the protocol. |
| Username | Your VPN username |
| Password | Your VPN password (stored in the Keychain) |
| TOTP secret | Bare Base32 key, `base32:…`, or the full `otpauth://…` URL (stored in the Keychain) |

The secret is normalized: spaces are removed, letters upper-cased, and the `base32:` prefix and `otpauth://` URLs are accepted.

### Getting the TOTP secret

The secret is shown once, when you enroll a new authenticator app with your VPN's identity provider (look for "can't scan the QR code?" or "enter the key manually"). The exact steps depend on the provider.

- If the secret is already in Apple's **Passwords** app, open the entry, click the verification code field, then **Copy Setup URL**, and paste the URL into the settings. The same secret then produces the same codes in both places, so no new method is needed.
- Most authenticator apps cannot reveal the secret of an existing entry. Capture it when you enroll.

Never paste this secret into a chat or a shared terminal: it is equivalent to your second factor. If it has been exposed, delete that method in your account's security settings and enroll a new one.

## Everyday use

| Menu item | Effect |
|---|---|
| Connect / Disconnect | No password prompt. An alert reports a failure. |
| Address, Since | The tunnel's IP address and how long you have been connected. |
| openconnect is not installed | Shown before any other state if `openconnect` cannot be found. **Copy install command…** copies `brew install openconnect`. |
| Helper not reachable → Repair helper… | Shown when macOS says the helper is enabled but it does not answer. See [Troubleshooting](#troubleshooting). |
| Settings… | The settings window. |
| Show log | Opens `/Library/Logs/OpenConnectMenu.log` (openconnect's output, no secrets). |
| Open at login | Launches the app when you log in. |
| Uninstall helper | Unregisters the helper. |
| Quit | Quits the app. A connected VPN stays up. |

Connecting takes about ten seconds; disconnecting a few seconds.

## Configuration profile (MDM)

An organization can impose the server settings with a **macOS configuration profile** (`.mobileconfig`), installed by hand or deployed by an MDM. macOS stores the values in the app's preference domain (its bundle identifier), and the app shows the imposed fields greyed out with a note.

Imposable keys (all optional strings):

| Key | Meaning |
|---|---|
| `server` | VPN address, `https://…` |
| `protocol` | One of `anyconnect`, `nc`, `gp`, `pulse`, `f5`, `fortinet`, `array` |
| `authgroup` | Authentication group |
| `useragent` | User-Agent |
| `username` | Username |

The password and the TOTP secret are never imposed: they are personal and live in each user's Keychain.

**Generating a profile.** `build.sh` imposes `server`, `protocol`, `authgroup` and `useragent` (set `VPN_SERVER`, `VPN_PROTOCOL`, `VPN_AUTHGROUP`, `VPN_USERAGENT`; a field left empty is not imposed). Create `profiles/<name>.env` from [`profiles/example.env`](profiles/example.env), then:

```bash
PROFILE=<name> ./build.sh mobileconfig      # → dist/OpenConnectMenu-<name>.mobileconfig
```

The profile has system scope and the payload type `com.apple.ManagedClient.preferences`. It is **unsigned**: macOS says so on manual installation, and an MDM re-signs it. Profiles in `profiles/` other than the example are ignored by git.

To impose `username` too, or to write the profile by hand or in an MDM, use a *Custom Settings* / `com.apple.ManagedClient.preferences` payload whose domain is the app's bundle identifier and whose forced settings are the keys above.

Check what macOS applied (the file exists only while the profile is installed):

```bash
plutil -p "/Library/Managed Preferences/<bundle-id>.plist"
```

## How it works

```
┌──────────────────────┐   XPC (verified by signature)   ┌────────────────────────────┐
│ OpenConnectMenu.app  │ ──────────────────────────────▶ │ helper (LaunchDaemon, root)│
│ menu bar             │ ◀────────────────────────────── │  · launches openconnect    │
│ settings, Keychain   │                                 │  · tears down the tunnel   │
└──────────────────────┘                                 │  · pins the binaries       │
                                                         └─────────────┬──────────────┘
                                                                       │
                                                          openconnect + vpnc-script
                                                          (Homebrew, /opt/homebrew)
```

- **The app** (no Dock icon) shows the state, reads your settings and sends commands to the helper.
- **The helper** is registered with `SMAppService.daemon`: macOS launches it on demand, as root. It only accepts XPC connections from the app signed by the build's team (`setConnectionCodeSigningRequirement`), and the app only talks to a helper signed by the same team.
- **Connecting**: the helper writes a temporary configuration readable only by root (it contains the TOTP secret), launches `openconnect` and passes the password on standard input, waits for the tunnel to come up (40 s at most), then deletes the configuration.
- **Disconnecting**: see [Limitations](#limitations-and-known-issues). `openconnect` does not react to signals on the tested macOS, so the helper replays the cleanup by hand.
- **State**: the tunnel is detected as the `utun` interface whose IPv4 address points at itself (`inet A --> A`). The range assigned by the server varies; nothing is hard-coded.
- **Updates**: the installer's `postinstall` script restarts the helper and reopens the app. If macOS ever reports the helper as enabled while it does not answer (for example after `brew upgrade`, which removes and reinstalls the service), the app re-registers it by itself after about fifteen seconds, once, unless a VPN was up.

## Security model

- **Root helper and XPC.** The helper only answers the signed app: requirement `anchor apple generic` + identifier + `certificate leaf[subject.OU]` equal to the team identifier. Without a valid signature the connection is refused.
- **Validated input.** The helper validates every field it receives (no control characters, `https://` required, Base32 TOTP secret, protocol taken from a fixed list) and builds the configuration and the command line itself. Nothing that comes from the app is executed as is.
- **Secrets.** Password and TOTP secret live in the Keychain. On the helper side, the password goes through standard input, and the TOTP secret only exists in a temporary `0600` configuration readable by root, deleted as soon as the connection is established or has failed.
- **Log.** Readable by the user (`0644`); it contains openconnect's output, not the secrets.
- **Configuration profile.** It carries no secret. An imposed field cannot be changed from the app.

### Binary pinning

`openconnect` and `vpnc-script` live in `/opt/homebrew`, a folder your account can modify. A helper that ran whatever it finds there without checking would give any program running under your account a way to get root code executed, without any prompt. For that reason:

- on approval, the helper records the **SHA-256** of `openconnect` and `vpnc-script` in `/Library/Application Support/OpenConnectMenu/trust.json` (owned by root);
- before every connection it recomputes the hashes and **refuses** to launch anything if they changed;
- after a `brew upgrade openconnect`, the menu asks again for **Approve openconnect…** (administrator password, verified by the helper through Authorization Services).

**Limits**: the Homebrew libraries that openconnect loads (GnuTLS, etc.) are not verified, and a theoretical race remains between the check and the launch. This is a safeguard, not full isolation.

## Building from source

You need the Xcode command line tools (`xcode-select --install`; full Xcode is not required) and, to run the app, an Apple Developer Program membership: the helper is registered with `SMAppService`, which requires a real signature, and the XPC connection between the app and the helper is verified against your team identifier. **Each person builds and signs their own copy.**

### Configure

```bash
cp config.env.example config.env     # git-ignored: these values are yours
```

Edit `config.env`:

| Variable | Required | Meaning |
|---|---|---|
| `TEAM_ID` | yes | Your Apple team identifier (10 characters) |
| `BUNDLE_ID` | yes | Reverse-DNS bundle identifier, e.g. `com.example.OpenConnectMenu`. The helper (`<BUNDLE_ID>.helper`) and the package (`<BUNDLE_ID>.pkg`) identifiers are derived from it. |
| `IDENTITY`, `INSTALLER_IDENTITY` | no | Signing identities. By default `build.sh` finds the *Developer ID Application* and *Developer ID Installer* certificates of your team in the Keychain, and stops if there are none or several. |
| `NOTARY_PROFILE` | no | A `notarytool` profile. Without it the package is signed but not notarized. |

Any variable can also be passed through the environment, which wins over the file.

### Build

```bash
./build.sh              # build, assemble and sign (output outside the source folder)
./build.sh install      # same, then install into /Applications and launch the app
./build.sh pkg          # same, then build a signed .pkg in dist/
./build.sh mobileconfig # configuration profile, see above
```

| Topic | Explanation |
|---|---|
| Output folder | `~/Library/Caches/OpenConnectMenu/build`. The build compiles a copy of the sources there, so cloud-synced folders (iCloud Drive…) cannot disturb it. |
| Architectures | `arm64` and `x86_64` by default, merged with `lipo` into a universal binary. `ARCHS=arm64 ./build.sh` gives a faster Apple-silicon-only build. |
| Ad-hoc build | `IDENTITY=- NO_TIMESTAMP=1 ./build.sh build` compiles with an ad-hoc signature and no certificate, which is enough to check that the project builds. It is not meant to be run: the helper needs a real team signature. |
| Package output | `DIST=<folder> ./build.sh pkg` (default `./dist`). A package of the same version overwrites the previous one. |
| First signing | macOS asks for access to your private key: choose **Always Allow**, otherwise `codesign` waits forever. |
| Safeguards | The build refuses the example values, malformed identifiers and a missing certificate before compiling anything, and fails if a template placeholder is left unreplaced. |

### The installer package

`./build.sh pkg` builds and signs the app and helper (hardened runtime), stages the content, builds the component package with `pkgbuild`, assembles the final package with `productbuild` (welcome screen, localized texts, pre-install check for `openconnect`) and signs it with a timestamp, then verifies the signature, the contents, the architectures and the signature of the extracted app.

- The app always lands in `/Applications` (it is **not relocatable**) and replaces an identical or older version.
- `pkg-scripts/preinstall` remembers whether the app was running, then quits it. `pkg-scripts/postinstall` restarts the helper and reopens the app (also when the package is reinstalled, as `brew upgrade` does).
- The package lists `._*` entries: that is the `com.apple.provenance` attribute added by macOS, not real files.

### Notarization

Without `NOTARY_PROFILE`, Gatekeeper rejects the package on another Mac ("Unnotarized Developer ID"). To notarize, create a profile once:

```bash
xcrun notarytool store-credentials "my-profile" --apple-id "<your Apple ID>" --team-id <TEAM_ID>
```

It asks for an **app-specific password** (generated at <https://account.apple.com> → Sign-In and Security). Your regular password is rejected. Then:

```bash
NOTARY_PROFILE=my-profile ./build.sh pkg
```

The script uploads the package, waits for the verdict and reads the **status** (not only the exit code). If it is not `Accepted` it prints Apple's log and stops. Otherwise it staples the ticket and checks Gatekeeper. Every run uploads the package to Apple, so use it for a version you intend to ship.

### Icon

The icon (a red tunnel: three concentric arches and a light at the end) is drawn in code in `Icon/make-icon.swift` (CoreGraphics, no dependencies):

```bash
swift Icon/make-icon.swift Icon
iconutil -c icns Icon/AppIcon.iconset -o App/AppIcon.icns
```

The menu bar icon is built from system symbols and adapts to light and dark mode.

## Languages

The interface and the installer are available in **English** (the default) and **French**. French is used when it comes first among the system's preferred languages that the app supports.

- Texts are written **in English in the code**, and the English text is the key: `L("Connect")` in `App/`, plain literals in the SwiftUI views. Translations live in `App/Resources/{en,fr}.lproj/Localizable.strings`.
- **The helper translates nothing.** It runs as root and does not know the user's language: it returns **codes** (`oc_exited`, `timeout`, `oc_not_approved`…), optionally followed by a raw detail. The app translates them (`HelperText` in `App/L10n.swift`).
- The installer's translations are in `pkg-resources/{en,fr}.lproj/`, with an English copy at the root as a fallback.
- The log is openconnect's output, so it is in English.

**Adding or changing a text**: write the English sentence in the code, then add the same key to both `Localizable.strings` files (placeholders such as `%@` must match). A missing key is shown in English.

**Adding a language**: create `App/Resources/<lang>.lproj/Localizable.strings`, add the language to `CFBundleLocalizations` in `App/Info.plist`, and add `pkg-resources/<lang>.lproj/` for the installer.

## Troubleshooting

| Symptom | What to try |
|---|---|
| "Helper not enabled" | Click "Enable helper…". If the app is not in `/Applications`, registration may fail. |
| "Helper needs approval" | Enable it in System Settings → Login Items & Extensions. |
| "Helper not reachable" | The service is registered but does not answer. The app repairs it by itself after about fifteen seconds; otherwise use **Repair helper…**. |
| "openconnect has not been approved yet" or "has changed" | Normal on first launch and after a Homebrew update: "Approve openconnect…". |
| "openconnect is not installed" | **Copy install command…**, run it in Terminal, then reopen the menu. |
| "openconnect (or its vpnc-script) was not found" | Incomplete install: `brew reinstall openconnect`. |
| Connection fails | Open the log. Check the username, the password and that the TOTP secret is the right one, in Base32. |
| `Invalid base32 token string` | The TOTP secret is wrong or mistyped. Re-enter it. |
| Settings fields are greyed out | A configuration profile imposes them. Remove the profile in System Settings to change them. |
| Every helper lookup fails, nothing registers | macOS's background-items daemon may be stuck: `sudo killall backgroundtaskmanagementd`, or restart. |
| `is not a recognized network service` in the log | Harmless: `vpnc-script` looks for a network service for the `utun` interface; DNS is applied another way. |

Command line checks:

```bash
pgrep -l openconnect                                   # is openconnect running?
ifconfig | grep -B1 -A2 -- '-->'                       # tunnel interface
route -n get default | egrep 'gateway|interface'       # default route
scutil --dns | head -12                                # active DNS
tail -n 30 /Library/Logs/OpenConnectMenu.log           # log
```

## Uninstalling

With Homebrew: first choose **Uninstall helper** in the menu (so that macOS also forgets the background item), then:

```bash
brew uninstall --cask openconnectmenu          # add --zap to also remove settings and logs
```

By hand:

1. Menu → **Uninstall helper**, then **Quit**.
2. `rm -rf /Applications/OpenConnectMenu.app`
3. Optional cleanup (`<bundle-id>` is your build's identifier; the official release uses `ch.jeko.OpenConnectMenu`):

   ```bash
   sudo rm -rf "/Library/Application Support/OpenConnectMenu" /Library/Logs/OpenConnectMenu.log
   defaults delete <bundle-id>
   security delete-generic-password -s <bundle-id> -a password
   security delete-generic-password -s <bundle-id> -a totp
   ```

## Project layout

```
.
├── build.sh               Build, assemble, sign, install, .pkg, notarization, configuration profile
├── config.env.example     Template for your local config.env (TEAM_ID, BUNDLE_ID…)
├── profiles/
│   └── example.env        Template for a configuration profile
├── Icon/                  make-icon.swift, preview and iconset
├── pkg-scripts/           preinstall, postinstall
├── pkg-resources/         Installer welcome screen and texts (en, fr, English fallback)
├── pkg-distribution.xml.in
├── Shared/Shared.swift    Constants, signing requirements, types and XPC protocol
├── App/                   Menu bar app: menu, XPC client, settings, translations
└── Helper/                Privileged helper: XPC listener, request validation, connect/disconnect, SHA-256 pinning
```

The resulting bundle:

```
OpenConnectMenu.app/Contents/
├── Info.plist
├── MacOS/OpenConnectMenu                         the app
├── MacOS/<bundle-id>.helper                      the helper
├── Resources/                                    icon and translations
└── Library/LaunchDaemons/<bundle-id>.helper.plist
```

Identifiers (`@BUNDLE_ID@`, `@HELPER_LABEL@`, `@PKG_ID@`, `@TEAM_ID@`) are placeholders in the plists, scripts and distribution template, replaced from `config.env` on a working copy at build time. `Shared.swift` reads them from a generated `BuildConfig.swift`.

## Limitations and known issues

- **`openconnect` does not react to any signal** (TERM, INT and USR1 were tested) on macOS 27.2 beta with openconnect 9.21, even though the kernel shows it intercepts them. The cause is not established. Disconnecting therefore works like this:
  1. `SIGTERM`, wait 2 s (useful if the defect ever disappears);
  2. otherwise, run `vpnc-script` with `reason=disconnect` to restore the saved default route and DNS, then `SIGKILL` the process;
  3. remove the exclusion routes that were added through the original gateway.
- **Manual cleanup**: if the helper is interrupted in the middle of the cleanup, exclusion routes or DNS settings may stay in place. Turning the network off and on again resets everything.
- **One VPN at a time**: tunnel detection assumes no other `utun` interface has a point-to-point IPv4 address pointing at itself.
- **Only AnyConnect is tested.** The protocol setting offers all seven openconnect protocols, and the helper checks that openconnect accepts them, but no connection has been tried with anything other than an AnyConnect server. The authentication flow and the meaning of the "authentication group" differ between protocols, so expect rough edges and please report them.
- **TOTP is required**: the helper always configures openconnect with a TOTP token. Other second factors are not supported.
- **Homebrew only**: `openconnect` is looked up in `/opt/homebrew` (Apple silicon), then `/usr/local` (Intel).
- **The Intel half is untested**: the `x86_64` slice compiles, is signed and passes the `lipo`/`codesign` checks, but has never been run. As far as I know macOS 26 is the last release that supports Intel Macs, so that slice targets macOS 13 to 26.
- **Tested** on Apple silicon with macOS 27 (beta), including `brew upgrade` and a configuration profile installed by hand, against an AnyConnect server. Not tested with an MDM, with another protocol, nor on a second clean Mac.

## License

[MIT](LICENSE). `openconnect` is a separate program (LGPL) that the helper launches; it is not part of this project.
