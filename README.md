# Antigravity on macOS with `sandbox-exec`

This repo contains a small launcher script that runs **Antigravity** (Electron app) under macOS’ Seatbelt sandbox using `sandbox-exec`, with a custom SBPL profile.

The goal here is simple: **reduce the default filesystem blast radius** while keeping the app usable (GUI, network, OAuth flows, integrated terminal).

## Commits welcome

- This was baked by a non-expert since I could not find anything equivalent online. Please do contribute! :)

## What’s in this repo

- `antigravity-sandbox-macos.sh`
   The launcher. It generates and uses a sandbox profile and then starts Antigravity. Path chosen:  `~/bin/antigravity-sandbox-macos.sh`
- What's not in the repo: `mkdir -p "${HOME}/AIProjects/Antigravity && mkdir -p "${HOME}/AIProjects/Shared `

## Requirements

- Antigravity installed at `/Applications/Antigravity.app`
   (or override the path with env vars, see below)

## Install

```
chmod +x ./antigravity-sandbox-macos.sh
```

(Optional) Put it somewhere on your PATH, e.g.:

```
mkdir -p ~/bin
cp ./antigravity-sandbox-macos.sh ~/bin/
chmod +x ~/bin/antigravity-sandbox-macos.sh
```

## Usage

### Basic (most people will NOT want to use this)

```
./antigravity-sandbox-macos.sh
```

### Persist your real config (for login / OAuth, configs etc)

If you want Antigravity to reuse your existing state (tokens, settings, etc.) instead of the sandbox home:

```
ANTIGRAVITY_PERSIST_REAL_CONFIG=1 ./antigravity-sandbox-macos.sh
```

This does *not* grant broad access to your entire home directory — only to the specific config/state directories the script wires up.

### Allow other project folders (RW) with persistence

By default, the sandbox only has write access to its sandbox home + temp. If you want it to work in specific folders, pass them explicitly:

```
ANTIGRAVITY_WORKDIR1="$HOME/AIProjects/Antigravity" \
ANTIGRAVITY_WORKDIR2="$HOME/AIProjects/Shared" \
ANTIGRAVITY_PERSIST_REAL_CONFIG=1 ./antigravity-sandbox-macos.sh
```

### Override app path

If your app isn’t in `/Applications`:

```
ANTIGRAVITY_APP_BUNDLE="/path/to/Antigravity.app" ./antigravity-sandbox-macos.sh
```

## What the sandbox actually does

High-level behavior:

- Runs Antigravity under Seatbelt via `sandbox-exec`
- Uses a **sandbox HOME** at:
   `~/.sandboxes/antigravity-home`
- Allows writes only to:
  - sandbox HOME
  - a per-run temp dir under `/private/tmp`
  - the explicit work dirs you opt into
  - optional real config dirs when `ANTIGRAVITY_PERSIST_REAL_CONFIG=1` is set
- Keeps the rest read-only or denied by default

With the default profile:

- It can freely write inside the sandbox home and any work dirs you allow.
- It should **not** be able to write to arbitrary system locations or your whole home.
- The profile includes a deny rule for raw disk device nodes (`/dev/disk*`, `/dev/rdisk*`) to make “wipe via block device” style mistakes much harder.

Still:

- If you give it write access to a folder, it can delete everything in that folder.
- Network access is allowed (the app needs it).
- If you approve password prompts / admin dialogs, you can still authorize admin actions.

## Notes / limitations

- `sandbox-exec` is deprecated by Apple (but still present on current macOS). Future macOS versions may change behavior.
- Electron apps spawn multiple helper processes (GPU, network, utility). Some warnings are expected.
- You may see logs like `SetApplicationIsDaemon ... paramErr (-50)`. That’s usually an Electron helper attempting an API call that doesn’t matter for normal operation.

## Troubleshooting

### Check sandbox denials

If something doesn’t work, the fastest way to see what got blocked:

```
log stream --style syslog --predicate 'process == "sandboxd"'
```

### Integrated terminal problems

The integrated terminal needs PTY access. The profile includes PTY rules; if you use a non-standard shell path, set it explicitly:

```
ANTIGRAVITY_SANDBOX_SHELL=/bin/zsh ./antigravity-sandbox-macos.sh
```
