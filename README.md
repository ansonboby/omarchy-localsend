# LocalSend for Omarchy

Native Omarchy Shell integration for [LocalSend](https://localsend.org/): the device lives in your bar and the LocalSend app stays closed. Enter requests are gated behind explicit **Accept / Decline**, transfers stream with live progress, and history survives restarts.

Based on `cryptobredda/omarchy-localsend` (MIT), reworked under this fork's identity with settings, alias continuity, and persistent history on top.

## Features

- Headless controller on the official LocalSend protocol core (v2.2) — no LocalSend GUI, TUI, or tray
- Auto-run device discovery with a manual refresh; share **files, folders, or clipboard text**
- Incoming transfers are **never** auto-accepted: an Accept/Decline card appears in the panel, plus a desktop notification whose click opens the panel
- Live transfer progress, cancel, and error surfacing for both directions
- **Persistent history** (last 24 finished transfers in `~/.local/state/omarchy/localsend-history.json`) shown as RECENT TRANSFERS, with one-click clear
- **Synced with the LocalSend app**: device name follows the app's own (`flutter.ls_alias`) unless overridden; when the app runs, the daemon steps aside and hands it port `53317`, resuming when the app closes
- TLS certificate pinning and a private, 0600 Unix management socket
- Checksum-pinned controller binary: the launcher verifies sha256 **before every execution**

## Install

Quit any running LocalSend GUI first — both programs bind port `53317` — then:

```bash
omarchy plugin add https://github.com/ansonboby/omarchy-localsend --enable --yes
```

## Settings

Settings live inline in the plugin's `shell.json` entry (integrated settings UI, `omarchy-plugin` tooling, or a plain edit all work):

```json
{ "id": "anson.localsend", "destination": "~/Downloads" }
```

| Key | Default | Meaning |
| --- | --- | --- |
| `alias` | *(empty)* | Name other devices see. Empty = the LocalSend app's own device name, then the hostname |
| `destination` | *(XDG Downloads)* | Where accepted files land (`~` allowed) |

Changes apply on the next receiver restart (shell restart, or disable/enable the plugin).

## IPC

```bash
quickshell ipc -p /usr/share/omarchy/shell call anson.localsend open | close | toggle | refresh | clearHistory
```

Keys inside the panel: `esc` close · `r` refresh · `f` share files · `d` share folder · `c` share clipboard · middle-click the bar icon to refresh devices.

## Transfer decisions from a terminal

The controller binary speaks to the daemon's socket directly, which is handy for scripting the phone handoff flow (the same path the panel's Accept button uses):

```bash
~/.config/omarchy/plugins/anson.localsend/bin/localsend-controller snapshot | jq
# then someone sends from a phone on the same Wi-Fi, and the request id appears above
~/.config/omarchy/plugins/anson.localsend/bin/localsend-controller accept --request <request-id>
~/.config/omarchy/plugins/anson.localsend/bin/localsend-controller decline --request <request-id>
~/.config/omarchy/plugins/anson.localsend/bin/localsend-controller cancel --transfer <transfer-id>
```

Incoming files land in the chosen destination with collision-safe names; incoming clipboard text is copied instead of saved.

## Port note — syncing with the LocalSend app

LocalSend traffic binds UDP+TCP `53317`. This plugin syncs with your installed LocalSend app instead of fighting it:

- **Name**: the daemon follows the app's own device name (its `flutter.ls_alias`) unless you set `alias` in settings.
- **Port**: a watcher polls every 0.7 s — when the LocalSend app launches, the daemon shuts down gracefully so the app owns the port (no "offline" error 98 in the app); when the app closes, the daemon takes the port back and re-reads the app's current name.
- The panel shows `APP RUNNING` with a handoff note while the app owns the port; action tiles disable and history stays visible.

Closing/relaunching the shell re-runs only this headless receiver.

## Development

- Controller: Rust under `controller/` (pinned to the official LocalSend core, protocol v2.2), release-built via GitHub Actions and pinned with size + sha256 in `controller-release.env`; the runtime launcher re-verifies both before every launch.
- QML layer: `service/Receiver.qml` supervises one controller daemon per shell session over the private socket; `widget/LocalSendBar.qml` is the panel + bar icon; both follow the Omarchy plugin design language.

Build the controller locally (needs the Rust toolchain): `scripts/build-controller`. Run everything: `scripts/check`.
