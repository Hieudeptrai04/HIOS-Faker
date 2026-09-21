#!/bin/sh
# WatchPaths daemon: copies config to ALL app containers + jbroot + shared prefs.
# Triggered by launchd when /tmp/com.changeinfoios.config.plist changes.
SRC="/tmp/com.changeinfoios.config.plist"
[ -f "$SRC" ] || exit 0

# Deploy to every app container
for d in /var/mobile/Containers/Data/Application/*/; do
    [ -d "$d" ] || continue
    t="${d}Library/Preferences"
    [ -d "$t" ] || mkdir -p "$t" 2>/dev/null
    cp -f "$SRC" "$t/com.changeinfoios.plist" 2>/dev/null
    chown mobile:mobile "$t/com.changeinfoios.plist" 2>/dev/null
    chmod 0644 "$t/com.changeinfoios.plist" 2>/dev/null
done

# Deploy to jbroot config path
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

# Deploy to shared prefs
cp -f "$SRC" "/var/mobile/Library/Preferences/com.changeinfoios.plist" 2>/dev/null
chown mobile:mobile "/var/mobile/Library/Preferences/com.changeinfoios.plist" 2>/dev/null
chmod 0644 "/var/mobile/Library/Preferences/com.changeinfoios.plist" 2>/dev/null
