# UsageMeterPlus

A tiny macOS menu bar app for checking Codex and Claude usage across multiple accounts. Minimalistic and free from bloat by design.
Formerly known as CodexMeterPlus.

<img width="357" height="405" alt="изображение" src="https://github.com/user-attachments/assets/e92733dc-afce-479b-83a7-fbab8f2cf0a6" />


It shows the remaining quota for each account, reset times, and a compact menu bar view with the 5-hour usage bar and reset ETA.
Weekly usage stays inside the popover to keep the menu bar clean; when that quota is exhausted, the menu bar ETA switches to the number of days until its reset. Updates every minute when open and every 5 minutes when closed.

## Features

* Multiple Codex and Claude accounts on one screen
* Remaining usage instead of consumed usage
* 5-hour and weekly limits
* Reset countdown plus exact reset time
* Compact menu bar status for every account
* Custom bar colors
* Low-frequency polling to avoid unnecessary CPU usage
* No dependencies
* Single Swift file
* Works with Xcode Command Line Tools

## Build

```bash
xcrun swiftc -O -framework Cocoa \
  UsageMeterPlus.swift \
  -o "$HOME/Applications/UsageMeterPlus"
```

Run it directly:

```bash
"$HOME/Applications/UsageMeterPlus"
```

## Autostart
To make UsageMeterPlus start automatically at login, create a LaunchAgent that points to the compiled binary 
In this exapmple it is stored at `~/Applications/UsageMeterPlus`. 
This script creates the agent, validates it, removes any older registered copy, stops any manually running instance, then loads and starts it:

```bash
#!/bin/bash
set -euo pipefail

APP="$HOME/Applications/UsageMeterPlus"
LABEL="com.usagemeterplus.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/UsageMeterPlus"
OUT_LOG="$LOG_DIR/stdout.log"
ERR_LOG="$LOG_DIR/stderr.log"

chmod +x "$APP"
mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>$APP</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>ProcessType</key>
    <string>Interactive</string>

    <key>StandardOutPath</key>
    <string>$OUT_LOG</string>

    <key>StandardErrorPath</key>
    <string>$ERR_LOG</string>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$UID" "$PLIST" 2>/dev/null || true
pkill -x UsageMeterPlus 2>/dev/null || true
sleep 0.3
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart "gui/$UID/$LABEL"
```

After that, `launchd` keeps the app running in your graphical login session and starts it again automatically after login, so there is no need for `nohup` or `&`. For normal restarts after rebuilding the binary, do not unload and bootstrap the agent again; just run `launchctl kickstart -k "gui/$UID/com.usagemeterplus.agent"`. Logs are written to `~/Library/Logs/UsageMeterPlus/stdout.log` and `~/Library/Logs/UsageMeterPlus/stderr.log`.
  
  
If you use the LaunchAgent setup, to restart it after rebuilding/quitting, use:

```bash
launchctl kickstart -k "gui/$UID/com.usagemeterplus.agent"
```

Upgrading from CodexMeterPlus: remove the old agent first with
`launchctl bootout "gui/$UID/com.codexmeterplus.agent"; rm ~/Library/LaunchAgents/com.codexmeterplus.agent.plist`.

## Adding accounts

UsageMeterPlus imports credential files manually via GUI (the `+` button). Codex and Claude files are detected automatically, and both kinds can be selected in one go.

### Codex

To authentificate into codex (CLI), run

```bash
  codex -c 'cli_auth_credentials_store="file"' login --device-auth
```

Then import this file:

```text
~/.codex/auth.json
```

### Claude

UsageMeterPlus imports the OAuth credentials JSON produced by Claude Code (`{"claudeAiOauth": {...}}`), signed in with a Claude Pro/Max/Team subscription.
On macOS Claude Code keeps it in the Keychain, so export it to a file first:

```bash
security find-generic-password -s "Claude Code-credentials" -w > ~/claude-credentials.json
```

On Linux the same JSON is stored at `~/.claude/.credentials.json`.

Anthropic may rotate the refresh token whenever either app refreshes it, which can log the other one out. To keep your everyday Claude Code session untouched, sign in to a separate config dir just for the meter:

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-usagemeter" claude   # then run /login and quit
# mac os
security dump-keychain | grep -o '"Claude Code-credentials-[0-9a-f]*"'   # find the service name
security find-generic-password -s "Claude Code-credentials-XXXXXXXX" -w > ~/claude-credentials.json
# linux
cat ~/.claude/.credentials.json > claude.json
```

Import the exported file, then delete it; the app keeps its own copy.

### Storage

The app stores imported accounts and its settings under:

```text
~/Library/Application Support/UsageMeterPlus/
```

An existing `~/Library/Application Support/CodexMeterPlus/` folder is moved there automatically on first launch.

## Notes

UsageMeterPlus uses the same Codex/ChatGPT usage API used by other Codex usage tools, and the same Claude OAuth usage API used by Claude Code's `/usage` screen.
It is not an official OpenAI or Anthropic app, and the endpoints are undocumented, so it may need updates if either API changes.
The goal is simple: show the useful numbers, stay out of the way, and use almost no resources while doing it.

## License

This repo is distributed under MIT License. Feel free to add any features in your fork. 
I am not planning to add model-based metrics available under higher subscription plans unless I will use them.
