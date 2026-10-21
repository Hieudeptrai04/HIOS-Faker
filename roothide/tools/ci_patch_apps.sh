#!/bin/sh
# ci_patch_apps.sh - enable target apps for tweak injection on roothide.
# Called from postinst: ci_patch_apps.sh <etc_dir> <ms_dir>
#
# Roothide's dyldhook_merge loader only injects tweaks
# (/usr/lib/TweakInject/*.dylib) into app bundles that carry a sibling
# .jbroot symlink pointing at the jbroot. The RootHide Bootstrap app
# (/var/jb/Applications/RootHide.app/RootHide) ships with the private
# com.apple.private.security.storage.AppBundles entitlement and exposes an
# "enableapp <bundlePath>" CLI that performs the full backup + .jbroot
# symlink + uicache re-register sequence. Kernel AMFI validates RootHide's
# cdhash against the trustcache on exec and grants it those entitlements
# regardless of the caller's uid context, so our postinst (plain dpkg
# sudo-root) can delegate the privileged bundle write to RootHide instead
# of trying to patch Mach-O binaries ourselves - the previous insert_dylib
# path always failed with EPERM at open() because dpkg's postinst context
# lacks AppBundles.
#
# Reference: roothide/Bootstrap/main.m "enableapp" branch; AppEnabler.m.

ETC="${1:?usage: ci_patch_apps.sh <etc_dir> <ms_dir>}"
MS="${2:?}"

# Locate RootHide bootstrap binary across possible mount paths.
ROOTHIDE=""
for p in /var/jb/Applications/RootHide.app/RootHide \
         /Applications/RootHide.app/RootHide; do
    if [ -x "$p" ]; then
        ROOTHIDE="$p"
        break
    fi
done

if [ -z "$ROOTHIDE" ]; then
    echo "[ci_patch] RootHide app not found, cannot auto-enable targets"
    echo "[ci_patch] install RootHide Bootstrap then reinstall ChangeInfoIos"
    exit 0
fi

echo "[ci_patch] RootHide binary: $ROOTHIDE"

# Common target bundles the tool is expected to spoof against. Enabling
# here means dyldhook will load /usr/lib/TweakInject/ChangeInfoIos*.dylib
# into these apps on their NEXT launch. The dylib's own %ctor + per-process
# guard still restricts behavior to the apps the user actually selected via
# Change Device's targetBundles, so pre-enabling a wider list only means
# more apps get the lightweight JB-hide layer loaded; identity spoof stays
# scoped to user-selected targets.
TARGET_APP_NAMES="Zalo Viber Facebook Instagram Telegram AIDA64 Shadowrocket"

enable_bundle() {
    bundle_path="$1"
    name="$2"
    if [ ! -d "$bundle_path" ]; then
        return 0
    fi
    if [ -L "$bundle_path/.jbroot" ]; then
        echo "[ci_patch] $name already enabled (.jbroot present)"
        return 0
    fi
    echo "[ci_patch] enabling $name -> $bundle_path"
    # RootHide asserts getuid() == 0 at entry; postinst is already root.
    out="$("$ROOTHIDE" enableapp "$bundle_path" 2>&1)"
    rc=$?
    if [ $rc -ne 0 ]; then
        echo "[ci_patch] enableapp FAILED for $name (rc=$rc): $out"
        return $rc
    fi
    if [ -L "$bundle_path/.jbroot" ]; then
        echo "[ci_patch] $name enabled OK"
    else
        echo "[ci_patch] enableapp rc=0 but .jbroot missing for $name"
    fi
    return 0
}

# Walk every installed user bundle; enable any whose .app name matches
# our target list.
for uuid_dir in /var/containers/Bundle/Application/*/; do
    [ -d "$uuid_dir" ] || continue
    for name in $TARGET_APP_NAMES; do
        bundle="${uuid_dir}${name}.app"
        [ -d "$bundle" ] && enable_bundle "$bundle" "$name"
    done
done

echo "[ci_patch] done"
exit 0
