#!/bin/sh
# Periodic config sync daemon (roothide).
# The HIOS app is sandboxed and CANNOT write to /tmp directly, so the
# authoritative config lives inside the app's container at
# Documents/ci_config_mirror.plist.  This script stages it to /tmp,
# then distributes to every target: app containers, kConfigPath, and
# shared prefs.  A periodic StartInterval (8 s) keeps things current.

TMP="/tmp/com.changeinfoios.config.plist"

# â”€â”€ Stage 0: find HIOS app mirror (newest write) â”€â”€
for d in /var/mobile/Containers/Data/Application/*/; do
    f="${d}Documents/ci_config_mirror.plist"
    [ -f "$f" ] || continue
    if [ ! -f "$TMP" ] || [ "$f" -nt "$TMP" ]; then
        cp -f "$f" "$TMP" 2>/dev/null
    fi
    break
done

SRC="$TMP"
[ -f "$SRC" ] || exit 0

# â”€â”€ Stage 1: deploy to every app container â”€â”€
for d in /var/mobile/Containers/Data/Application/*/; do
    [ -d "$d" ] || continue
    t="${d}Library/Preferences"
    [ -d "$t" ] || mkdir -p "$t" 2>/dev/null
    cp -f "$SRC" "$t/com.changeinfoios.plist" 2>/dev/null
    chown mobile:mobile "$t/com.changeinfoios.plist" 2>/dev/null
    chmod 0644 "$t/com.changeinfoios.plist" 2>/dev/null
done

# â”€â”€ Stage 2: deploy to jbroot config path (kConfigPath) â”€â”€
if command -v jbroot >/dev/null 2>&1; then
    ROOT="$(jbroot / 2>/dev/null)" || ROOT="/var/jb"
else
    ROOT="/var/jb"
fi
ROOT="${ROOT%/}"
ETC="$ROOT/etc/changeinfoios"
mkdir -p "$ETC" 2>/dev/null
cp -f "$SRC" "$ETC/config.plist" 2>/dev/null
chmod 0666 "$ETC/config.plist" 2>/dev/null

# â”€â”€ Stage 3: deploy to shared prefs â”€â”€
cp -f "$SRC" "/var/mobile/Library/Preferences/com.changeinfoios.plist" 2>/dev/null
chown mobile:mobile "/var/mobile/Library/Preferences/com.changeinfoios.plist" 2>/dev/null
chmod 0644 "/var/mobile/Library/Preferences/com.changeinfoios.plist" 2>/dev/null

# â”€â”€ Stage 4: flush cfprefsd so running apps see on-disk changes â”€â”€
killall cfprefsd 2>/dev/null || true
