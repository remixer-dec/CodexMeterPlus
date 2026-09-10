# CodexMeterPlus

A tiny macOS menu bar app for checking Codex usage across multiple accounts. Minimalistic and free from bloat by design.
  
<img width="364" height="411" alt="изображение" src="https://github.com/user-attachments/assets/3815af8b-3a24-4eca-9334-d4c3f9edf71b" />


It shows the remaining quota for each account, reset times, and a compact menu bar view with the daily usage bar and reset ETA. 
Weekly usage stays inside the popover to keep the menu bar clean. Updates every minute when open and every 5 minutes when closed.

## Features

* Multiple Codex accounts on one screen
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
  CodexMeterPlus.swift \
  -o "$HOME/Applications/CodexMeterPlus"
```

Run it directly:

```bash
"$HOME/Applications/CodexMeterPlus"
```

## Autostart
To make CodexMeterPlus start automatically at login, create a LaunchAgent that points to the compiled binary 
In this exapmple it is stored at `~/Applications/CodexMeterPlus`. 
This script creates the agent, validates it, removes any older registered copy, stops any manually running instance, then loads and starts it:

```bash
#!/bin/bash
set -euo pipefail

APP="$HOME/Applications/CodexMeterPlus"
LABEL="com.codexmeterplus.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/Library/Logs/CodexMeterPlus"
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
pkill -x CodexMeterPlus 2>/dev/null || true
sleep 0.3
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart "gui/$UID/$LABEL"
```

After that, `launchd` keeps the app running in your graphical login session and starts it again automatically after login, so there is no need for `nohup` or `&`. For normal restarts after rebuilding the binary, do not unload and bootstrap the agent again; just run `launchctl kickstart -k "gui/$UID/com.codexmeterplus.agent"`. Logs are written to `~/Library/Logs/CodexMeterPlus/stdout.log` and `~/Library/Logs/CodexMeterPlus/stderr.log`.
  
  
If you use the LaunchAgent setup, to restart it after rebuilding/quitting, use:

```bash
launchctl kickstart -k "gui/$UID/com.codexmeterplus.agent"
```

## Adding accounts

CodexMeterPlus imports the `auth.json` produced by Codex manually via GUI.

To authentificate into codex (CLI), run

```bash
  codex -c 'cli_auth_credentials_store="file"' login --device-auth
```

Then import this file:

```text
~/.codex/auth.json
```


The app stores imported accounts and its settings under:

```text
~/Library/Application Support/CodexMeterPlus/
```

## Notes

CodexMeterPlus uses the same Codex/ChatGPT usage API used by other Codex usage tools. 
It is not an official OpenAI app, and the endpoint is undocumented, so it may need updates if OpenAI changes the API.
The goal is simple: show the useful numbers, stay out of the way, and use almost no resources while doing it.

## License

This repo is distributed under MIT License. Feel free to add any features in your fork. 
I am not planning to add Claude stats and model-based metrics available under higher subscription plans unless I will use them.
