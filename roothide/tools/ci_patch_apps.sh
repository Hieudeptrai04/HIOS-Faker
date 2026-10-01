#!/bin/sh
# ci_patch_apps.sh — force-inject tweak into apps that systemhook skips
# Called from postinst: ci_patch_apps.sh <etc_dir> <ms_dir>
#
# For each app that systemhook fails to inject (e.g. Zalo), this script:
# 1. Copies our dylib + libsubstrate into AppName.app/Frameworks/
# 2. Patches the app binary to add LC_LOAD_DYLIB -> our dylib
# 3. Re-signs + adds to trustcache
#
# The tweak's %ctor already gates per-app activation via targetBundles,
# so injecting into extra apps is safe — unselected apps only get JB-hide.

set -e

ETC="${1:?usage: ci_patch_apps.sh <etc_dir> <ms_dir>}"
MS="${2:?}"

INSERT="$ETC/insert_dylib"
MG_DYLIB="$MS/ChangeInfoIosMG.dylib"
LIBSUB="$MS/libsubstrate.dylib"

# Fallback libsubstrate location
[ -f "$LIBSUB" ] || LIBSUB="/usr/lib/TweakInject/libsubstrate.dylib"
[ -f "$LIBSUB" ] || LIBSUB="/usr/lib/libsubstrate.dylib"

if [ ! -x "$INSERT" ]; then
    echo "[ci_patch] insert_dylib not found, skipping"
    exit 0
fi
if [ ! -f "$MG_DYLIB" ]; then
    echo "[ci_patch] MG dylib not found, skipping"
    exit 0
fi

# Resolve tools
LDID=""
for l in /usr/bin/ldid /var/jb/usr/bin/ldid; do
    [ -x "$l" ] && LDID="$l" && break
done
JBCTL=""
for c in /usr/bin/jbctl /var/jb/basebin/jbctl /basebin/jbctl; do
    [ -x "$c" ] && JBCTL="$c" && break
done

patch_app() {
    APP_PATH="$1"
    APP_NAME="$2"
    APP_BIN="$APP_PATH/$APP_NAME"

    if [ ! -f "$APP_BIN" ]; then
        echo "[ci_patch] binary not found: $APP_BIN"
        return 1
    fi

    FW_DIR="$APP_PATH/Frameworks"
    mkdir -p "$FW_DIR" 2>/dev/null || true

    DYLIB_NAME="ChangeInfoIosMG.dylib"
    DYLIB_PATH="@executable_path/Frameworks/$DYLIB_NAME"

    # Check if already patched (dylib exists in Frameworks)
    if [ -f "$FW_DIR/$DYLIB_NAME" ]; then
        # Check if the dylib is current (same size as source)
        SRC_SIZE=$(wc -c < "$MG_DYLIB" 2>/dev/null || echo 0)
        DST_SIZE=$(wc -c < "$FW_DIR/$DYLIB_NAME" 2>/dev/null || echo 1)
        if [ "$SRC_SIZE" = "$DST_SIZE" ]; then
            echo "[ci_patch] $APP_NAME already patched and current"
            return 0
        fi
    fi

    echo "[ci_patch] patching $APP_NAME..."

    # Copy dylibs into app's Frameworks
    cp "$MG_DYLIB" "$FW_DIR/$DYLIB_NAME"
    if [ -f "$LIBSUB" ]; then
        cp "$LIBSUB" "$FW_DIR/libsubstrate.dylib"
    fi
    chmod 755 "$FW_DIR/$DYLIB_NAME" "$FW_DIR/libsubstrate.dylib" 2>/dev/null || true
    chown _installd:_installd "$FW_DIR/$DYLIB_NAME" "$FW_DIR/libsubstrate.dylib" 2>/dev/null || true

    # Sign the dylibs in Frameworks
    if [ -n "$LDID" ]; then
        "$LDID" -S "$FW_DIR/$DYLIB_NAME" 2>/dev/null || true
        "$LDID" -S "$FW_DIR/libsubstrate.dylib" 2>/dev/null || true
    fi

    # Trust dylibs
    if [ -n "$JBCTL" ]; then
        "$JBCTL" trust "$FW_DIR/$DYLIB_NAME" 2>/dev/null || \
        "$JBCTL" trustcache add "$FW_DIR/$DYLIB_NAME" 2>/dev/null || true
        "$JBCTL" trust "$FW_DIR/libsubstrate.dylib" 2>/dev/null || \
        "$JBCTL" trustcache add "$FW_DIR/libsubstrate.dylib" 2>/dev/null || true
    fi

    # Back up the original binary before patching
    BACKUP_DIR="$ETC/backup"
    mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    BACKUP_FILE="$BACKUP_DIR/${APP_NAME}.orig"
    if [ ! -f "$BACKUP_FILE" ]; then
        cp "$APP_BIN" "$BACKUP_FILE" 2>/dev/null || true
        echo "[ci_patch] backed up original to $BACKUP_FILE"
    fi

    # Patch the binary — insert_dylib checks for duplicates
    "$INSERT" "$APP_BIN" "$DYLIB_PATH" 2>&1 || {
        echo "[ci_patch] insert_dylib failed for $APP_NAME"
        return 1
    }

    # Re-sign the patched binary
    if [ -n "$LDID" ]; then
        "$LDID" -S "$APP_BIN" 2>/dev/null || true
    fi

    # Trust the patched binary
    if [ -n "$JBCTL" ]; then
        "$JBCTL" trust "$APP_BIN" 2>/dev/null || \
        "$JBCTL" trustcache add "$APP_BIN" 2>/dev/null || true
    fi

    echo "[ci_patch] $APP_NAME patched OK"
    return 0
}

# ── Find and patch known problematic apps ──
# Zalo: systemhook does not inject DYLD_INSERT_LIBRARIES into this app.
for uuid_dir in /var/containers/Bundle/Application/*/; do
    [ -d "$uuid_dir" ] || continue
    # Check for Zalo.app
    if [ -d "${uuid_dir}Zalo.app" ]; then
        patch_app "${uuid_dir}Zalo.app" "Zalo"
    fi
done

echo "[ci_patch] done"
exit 0
