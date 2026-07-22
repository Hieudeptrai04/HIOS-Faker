# ChangeInfoIos v3 — HIOS Faker (rewrite for smoothness)

Device-spoof jailbreak tweak for popular iOS apps (Zalo, Facebook, TikTok, Instagram, Shopee, etc.). Focused architecture: **ZERO inject into target apps** — all device-fake happens in `mobilegestaltd` + `CoreTelephony` daemons. Container reset is pure shell.

**Use case**: register multiple accounts on popular social/e-commerce apps without lag or account locks. NOT for banking eKYC.

## Architecture

| Component | Lines | Purpose |
|---|---|---|
| `app/` HIOS Faker UI | ~2500 | Vietnamese UI, app picker, preset library, Change Device button, RRS backup/restore |
| `tweak-mg/` MG dylib | ~200 | Hooks `MGCopyAnswer` in `MobileGestaltHelper` — spoofs UDID/Serial/IMEI/Model/OS/MAC |
| `tweak-ct/` CT dylib | ~100 | Hooks `CTCarrier` in `CoreTelephony` — spoofs carrier name/MCC/MNC/region |
| Shell reset | inline | Wipes app data + keychain on Change Device (no tweak needed) |

Total ≈ 3500 lines (vs v2.x 18000+).

## Build

```sh
# In each tweak directory
make package FINALPACKAGE=1 ARCHS="arm64 arm64e"

# Or run CI on push to master — see .github/workflows/build.yml
```

## Install

```sh
# Via Sileo (after CI publishes)
# Add source: https://hieudeptrai04.github.io/HIOS-Faker-v3/
# Install: HIOS Faker v3
```

## Differences from v2.x

| | v2.x | v3 |
|---|---|---|
| Inject into target apps | Yes (every ticked app) | **No** |
| Lag during chat scroll | Visible on A11 | None |
| Spoof coverage | Same | Same |
| Code size | ~18000 lines | ~3500 lines |
| Support banking eKYC | Partial | No (intentionally out of scope) |

See [PLAN.md](PLAN.md) for full design rationale.
