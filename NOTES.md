# ChangeInfoIos v3 — Session Notes (2026-05-25 ~01:00 ICT)

## Current state

**Branch:** `v3` (separate from v2.x `master`)
**Last build:** `v3-3.0.0-fa1a870` — installed on iPhone X iOS 16.7.11

### Installed
- `com.changeinfoios.v3` 3.0.0 — host app + tweak-mg + tweak-ct
- `ai.akemi.appsyncunified` 116.0 (installed today, NOT what fixed inject)

### Required setup quirks (Dopamine 2)
- **Trustcache `add` is per-session.** After every install + each respring,
  must re-add SHA-256 cdhashes via `jbctl trustcache add <hash>`.
- **`launchctl reboot userspace` is required** after first install
  (not just respring) — was the missing piece for App Store app injection.
  Plain `killall -9 SpringBoard` is not enough for Zalo/AIDA to get tweak.
- Tweak.xm CDHash extraction: `ldid -h <dylib> | grep '^CDHash=' | cut -d= -f2`
  (sha256-truncated 20-byte form). NOT `CandidateCDHash sha1=` (40-char SHA-1, wrong).

## Works ✅

After userspace reboot + open AIDA64:
- Device **model** (e.g., iPhone 7 Plus) — via `UIDevice.model` %hook
- **iOS version** + build — via `MGCopyAnswer("ProductVersion")` fishhook
- **Battery percent** — via `MGCopyAnswer("BatteryCurrentCapacity")` + `UIDevice.batteryLevel`

## Doesn't work ❌

Still shows REAL values in AIDA after every attempt:
- Serial Number (Apple)
- IOPlatformSerialNumber
- IOPlatformUUID
- IMEI / MEID
- WiFi/Bluetooth MAC
- Maybe more "mã máy" fields

### What we tried (all failed for serial)
1. **fishhook `IORegistryEntryCreateCFProperty`** — fails silently. fishhook
   only rebinds lazy-bound symbols; IOKit framework is eagerly bound. No effect.
2. **MSHookFunction `IORegistryEntryCreateCFProperty`** — compiled OK after
   `extern "C"` wrap (Logos .xm is preprocessed as .mm). Linked against
   CydiaSubstrate.tbd (which on Dopamine 2 = libellekit). Build pass,
   install pass, trustcache added, userspace rebooted. But marker file
   shows tweak did load yet serial still real → either:
   - MSHookFunction is no-op silently for IOKit functions
   - AIDA reads serial via XPC to `lockdownd` (not via IOKit at all)
   - AIDA caches serial early-init before our hook installs
3. **Re-entry guard added** after AIDA crashed with watchdog 0x8BADF00D
   (42s CPU burn = infinite recursion). Guard prevents recursion, but
   serial still real.

## To investigate tomorrow

1. **Definitive proof MSHookFunction fires.** Add a `NSLog`+marker write
   in `hooked_IORegCreate` for ANY key (not just mapped). If marker grows
   after AIDA open, hook fires → AIDA reads serial elsewhere. If no growth,
   hook silently not firing → use libellekit's `EKHook` instead of MSHookFunction,
   or fishhook+ldsym at the call site.

2. **Where AIDA actually reads serial.** Check AIDA64 binary with `otool -L`
   for IOKit framework link. If absent, AIDA uses XPC to `lockdownd` for
   serial → need to hook lockdown client lib `liblockdown.dylib` or hook
   `xpc_dictionary_get_value` for "DeviceID"-type keys.

3. **Try a tweak whose source is known to spoof serial on Dopamine 2.**
   E.g., `EasyAppleAccount` or similar. See what hook approach they use.

## Quick commands

```bash
# Reinstall latest v3 + add trustcache + userspace reboot
node /c/Users/hn130/Desktop/ChangeInfoIos_full_HANOI/ssh-v3-replace.js
# (script needs SHA edit per build)

# Verify tweak loaded into a process
ssh mobile@192.168.0.8 'cat /var/jb/etc/changeinfoios/v3_mg_loaded.txt'

# Check trustcache for our dylib
ssh mobile@192.168.0.8 'sudo /var/jb/basebin/jbctl trustcache info | grep <hash>'

# Fetch latest AIDA crash
ssh mobile@192.168.0.8 'sudo cat $(ls -t /var/mobile/Library/Logs/CrashReporter/AIDA*.ips | head -1)'
```

## Files state
- `tweak-mg/Tweak.xm` — has MGCopyAnswer fishhook + UIDevice %hook + IORegistry MSHookFunction with re-entry guard
- `tweak-mg/ChangeInfoIosMG.plist` — filter: target App Store apps (Zalo/FB/IG/TikTok/AIDA/Lirum/DeviceDesign/Shopee/Telegram)
- `tweak-mg/Makefile` — links Foundation/CoreFoundation/UIKit/IOKit
- `tweak-ct/` — still stub (Phase 3, CTCarrier hooks deferred)
- `app/main.m` — full v2.x UI wholesale copy (7501 lines)
- `.github/workflows/build.yml` — has on-failure log-upload to Release for anonymous-curl debug

## Pending: cleanup
- 60+ `ssh-*.js` files in `ChangeInfoIos_full_HANOI/` root from this session — most are one-offs, can delete
- Several test/diag scripts (`check-*.js`, `final-test.js`, etc.)
