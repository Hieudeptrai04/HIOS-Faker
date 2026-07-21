// ChangeInfoIosMG v3.0.0 — single-dylib MG spoof.
//
// Loads into target apps (Zalo / FB / TikTok / IG / AIDA64 / Shopee).
// Hooks one symbol: MGCopyAnswer (via fishhook lazy-binding rebind).
// Reads spoof config from /var/jb/etc/changeinfoios/config.plist.
// Hot-path is zero-alloc + zero-NSLog to keep target apps smooth.
//
// Why single dylib (not v2.x per-app tweaks):
//   - 1 dylib mmap'd N times vs N dylibs = less RAM
//   - 1 fishhook trampoline vs N = less perf overhead per call
//   - All target apps share same key map / config reload notify

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <notify.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <string.h>
#import <strings.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <errno.h>
#import <ifaddrs.h>
#import <net/if_dl.h>
#import <net/if.h>
#import <IOKit/IOKitLib.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKUserScript.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <PushKit/PKPushRegistry.h>
#import <AdSupport/ASIdentifierManager.h>
#import <Security/Security.h>
#import <DeviceCheck/DeviceCheck.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import "fishhook.h"

// MSHookFunction — provided by ellekit/CydiaSubstrate. Used for IOKit
// framework functions which fishhook can't rebind (they're indirect
// symbol stubs / direct calls, not lazy-bound). Declared extern "C"
// to avoid C++ name mangling (Logos preprocesses .xm as .mm).
#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

// ============================================================
// dbglog — append-only file logger using plain C stdio. NEVER use
// NSLog / NSString / NSDate inside the IORegistry hook path: they
// allocate, which on first-touch can hit IOKit (NSLocale region
// lookup, memory tag metadata) → re-enters our hook. fopen/fwrite
// are pure syscalls and safe even when g_inIOReg is set.
// Capped at kMaxDbgLines so a runaway hook doesn't fill /var.
// ============================================================
static FILE *g_dbglog = NULL;
static pthread_mutex_t g_dbglog_mu = PTHREAD_MUTEX_INITIALIZER;
static long g_dbglog_count = 0;
static const long kMaxDbgLines = 4000;
static const char *kDbgPath = "/var/jb/etc/changeinfoios/v3_mg_debug.log";

// Per-app tmp path (always writable from inside the app sandbox).
// /var/jb/etc/ writes silently fail from sandboxed App Store apps —
// even with 0666 perms, sandbox profile denies writes outside container.
// Resolved on first dbglog call via NSTemporaryDirectory().
static char g_dbgTmpPath[256] = "";
static char g_dbgTmpResolved = 0;

// Stealth gate (4.0.11): by DEFAULT write NO debug files anywhere. Leaving a
// v3_mg_debug.log inside every injected app's own tmp is a trivially-detectable
// "this process is hooked" artifact — Zalo can scan its OWN sandbox (no JB
// bypass needed) and flag/ban. Logging is OFF unless the marker file
// /var/jb/etc/changeinfoios/.debug exists (touch it to enable while debugging).
static int g_dbgOn = -1;
static int ci_dbgEnabled(void) {
    if (g_dbgOn < 0)
        g_dbgOn = (access("/var/jb/etc/changeinfoios/.debug", F_OK) == 0) ? 1 : 0;
    return g_dbgOn;
}

__attribute__((format(printf, 1, 2)))
static void dbglog(const char *fmt, ...) {
    if (!ci_dbgEnabled()) return;
    if (g_dbglog_count > kMaxDbgLines) return;
    pthread_mutex_lock(&g_dbglog_mu);
    if (g_dbglog_count > kMaxDbgLines) { pthread_mutex_unlock(&g_dbglog_mu); return; }

    // Lazy resolve per-app tmp on first call (NSTemporaryDirectory
    // requires Foundation initialized — safe in %ctor since Logos
    // runs after Foundation +load chain).
    if (!g_dbgTmpResolved) {
        g_dbgTmpResolved = 1;
        @autoreleasepool {
            NSString *tmp = NSTemporaryDirectory();
            if (tmp && tmp.length) {
                NSString *p = [tmp stringByAppendingPathComponent:@"v3_mg_debug.log"];
                strncpy(g_dbgTmpPath, [p UTF8String], sizeof(g_dbgTmpPath) - 1);
            }
        }
    }

    // Try both targets; sandboxed apps will only succeed on the tmp one,
    // SpringBoard/daemons on the /var/jb one. Either is enough.
    if (!g_dbglog) g_dbglog = fopen(kDbgPath, "a");
    FILE *tmpf = (g_dbgTmpPath[0]) ? fopen(g_dbgTmpPath, "a") : NULL;

    if (g_dbglog || tmpf) {
        char buf[1024];
        va_list ap; va_start(ap, fmt);
        int n = vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        if (n < 0) n = 0;
        if ((size_t)n >= sizeof(buf)) n = sizeof(buf) - 1;
        if (g_dbglog) { fwrite(buf, 1, n, g_dbglog); fflush(g_dbglog); }
        if (tmpf)     { fwrite(buf, 1, n, tmpf);     fclose(tmpf); }
        g_dbglog_count++;
    }
    pthread_mutex_unlock(&g_dbglog_mu);
}

// Process-name cached once — getprogname() is async-signal-safe and
// doesn't allocate. Used in every dbglog line so we can tell which
// app produced each entry when many apps share the log file.
static const char *g_procname = "?";

// ============================================================
// Config — backed by /var/jb/etc/changeinfoios/config.plist.
// Reloaded on darwin notify "com.changeinfoios.v3/ReloadConfig".
// Atomic pointer swap so hot-path readers never lock.
// ============================================================
static NSString *const kConfigPath = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kReloadNote  = @"com.changeinfoios.v3/ReloadConfig";
static NSString *const kLegacyNote  = @"com.changeinfoios/ReloadConfig";
static NSString *const kAppNote     = @"com.changeinfoios/ReloadPrefs"; // app sends this

// Plain strong ARC pointer + dispatch_once init. NSDictionary is
// immutable; multi-threaded reads are safe. The 8-byte aligned pointer
// store is atomic on arm64, so a concurrent reload can never tear the
// pointer — worst case a thread reads the previous dict for a few ns.
// Avoid _Atomic + ARC; their interaction releases too eagerly and the
// dylib crashes inside objc_retain when Firebase reads systemVersion
// from a background queue (observed in AIDA64 crash log 2026-05-25).
static NSDictionary *g_config = nil;
static dispatch_once_t g_loadOnce;

// ============================================================
// License gate. Spoofing is allowed ONLY when config holds a valid signed
// token "_ci_lic_tok" = "<epoch>|<HMAC(epoch|deviceUDIDhash, secret)>" that the
// host app writes after a server-validated, unexpired license. The signature is
// bound to the device UDID, so a token copied to another device fails (see
// tw_deviceMGHash / computeLicOK). The <epoch> is MIN(licenseExpiry, lastOnlineCheck+grace),
// so an offline/revoked user can't keep spoofing past the grace window. Writing
// config.plist by hand (SSH) still cannot enable spoofing (no secret). Secret is
// obfuscated (bytes XOR 0x37) — the SAME bytes as the app's ci_licSecret().
// ============================================================
#import <CommonCrypto/CommonCrypto.h>
#import <time.h>
#import <sys/time.h>
#import <dlfcn.h>
static int g_licOK = 0;
static NSString *tw_licSecret(void) {
    static NSString *s = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        static const unsigned char kS[] = {
            0x5f, 0x71, 0x0e, 0x5c, 0x66, 0x05, 0x5a, 0x6d, 0x00, 0x41, 0x6f, 0x06,
            0x47, 0x65, 0x03, 0x59, 0x7b, 0x0f, 0x40, 0x75, 0x01, 0x54, 0x63, 0x04,
            0x4e, 0x73, 0x02, 0x44, 0x70, 0x07, 0x56, 0x7d, 0x52, 0x62, 0x05, 0x5e,
            0x78, 0x0e, 0x45, 0x7c, 0x03, 0x5b, 0x7a, 0x00, 0x59, 0x67, 0x06, 0x46,
            0x61, 0x0f, 0x4f, 0x6d, 0x04, 0x55, 0x79, 0x01,
        };
        char buf[sizeof(kS) + 1];
        for (size_t i = 0; i < sizeof(kS); i++) buf[i] = kS[i] ^ 0x37;
        buf[sizeof(kS)] = 0;
        s = [NSString stringWithUTF8String:buf];
    });
    return s;
}
// SHA-256 hex of a string — matches the host app's -[CILicenseManager sha256Hex:].
static NSString *tw_sha256Hex(NSString *s) {
    const char *c = [s UTF8String];
    unsigned char d[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(c, (CC_LONG)strlen(c), d);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + i*2, 3, "%02x", d[i]);
    return [NSString stringWithUTF8String:hex];
}

// Strong, un-spoofable device id via MobileGestalt: sha256("HIOSv3|"+realUDID),
// matching the host app's -[CILicenseManager deviceUDID] MG path. Returns nil if
// MGCopyAnswer is restricted in this (sandboxed) process. Cached once — the
// hardware id never changes. We resolve MGCopyAnswer through a fresh dlsym
// pointer (the GENUINE function, not our hooked binding): fishhook only rebinds
// caller GOT entries, so the dlsym'd address runs the real implementation — no
// recursion into the hook, no cfg() re-entry, no deadlock. (Same as the app.)
static NSString *tw_deviceMGHash(void) {
    static NSString *mgCached = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *real = nil;
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (h) {
            CFTypeRef (*MG)(CFStringRef) = (CFTypeRef(*)(CFStringRef))dlsym(h, "MGCopyAnswer");
            if (MG) {
                CFTypeRef v = MG(CFSTR("UniqueDeviceID"));
                if (v) {
                    if (CFGetTypeID(v) == CFStringGetTypeID() &&
                        CFStringGetLength((CFStringRef)v) >= 16)
                        real = [(__bridge NSString *)v copy];
                    CFRelease(v);
                }
            }
        }
        if (real.length >= 16)
            mgCached = tw_sha256Hex([@"HIOSv3|" stringByAppendingString:real]);
    });
    return mgCached;
}

// Does the token signature match HMAC("<es>|<udid>") for this candidate udid?
static BOOL tw_sigOK(NSString *es, NSString *sig, NSString *udid) {
    if (!udid.length) return NO;
    NSString *canon = [NSString stringWithFormat:@"%@|%@", es, udid];
    const char *k = [tw_licSecret() UTF8String];
    const char *m = [canon UTF8String];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, k, strlen(k), m, strlen(m), mac);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + i*2, 3, "%02x", mac[i]);
    return strcmp(hex, [sig UTF8String]) == 0;
}

static void computeLicOK(void) {
    g_licOK = 0;
    id tv = g_config[@"_ci_lic_tok"];
    if (![tv isKindOfClass:[NSString class]]) return;
    NSString *tok = (NSString *)tv;
    NSRange bar = [tok rangeOfString:@"|"];
    if (bar.location == NSNotFound) return;
    NSString *es  = [tok substringToIndex:bar.location];
    NSString *sig = [tok substringFromIndex:bar.location + 1];
    if (!es.length || !sig.length) return;
    if ([es longLongValue] <= (long long)time(NULL)) return;     // expired
    // Token is signed over the epoch ONLY (HMAC(es)). Device-binding was REVERTED:
    // computing the device id here called the MSHookFunction-patched MGCopyAnswer,
    // which re-entered cfg()'s dispatch_once and DEADLOCKED the target app's launch
    // (Zalo "treo → văng", 19s scene-create watchdog, via Firebase reading
    // -[UIDevice systemVersion] → our hook → getConfigStr → cfg → computeLicOK →
    // tw_deviceMGHash → MGCopyAnswer → hooked_MGCopyAnswer → cfg re-entry). Anti-
    // sharing is enforced by the SERVER-side UDID bind + grace-bounded expiry (#4),
    // neither of which touches MobileGestalt.
    const char *k = [tw_licSecret() UTF8String];
    const char *m = [es UTF8String];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, k, strlen(k), m, strlen(m), mac);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + i*2, 3, "%02x", mac[i]);
    if (strcmp(hex, [sig UTF8String]) == 0) g_licOK = 1;
}

static void reloadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    g_config = d ?: @{};
    computeLicOK();
}

static inline NSDictionary *cfg(void) {
    dispatch_once(&g_loadOnce, ^{ reloadConfig(); });
    // Not licensed → empty config → every spoof read returns nil → tweak is a
    // no-op (real values pass through). Fail-closed, never crashes.
    return g_licOK ? g_config : @{};
}

static inline id getConfig(NSString *k) { return cfg()[k]; }
static inline NSString *getConfigStr(NSString *k) {
    id v = cfg()[k];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return nil;
}
static inline BOOL getConfigBool(NSString *k) {
    id v = cfg()[k];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        return [s isEqualToString:@"1"] || [s isEqualToString:@"true"] || [s isEqualToString:@"yes"];
    }
    return NO;
}

static int64_t configValueAsMGInteger(NSString *configKey) {
    id val = getConfig(configKey);
    if (!val) return 0;
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val longLongValue];
    if ([val isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)val stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) return 0;
        if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
            unsigned long long u = 0;
            NSScanner *sc = [NSScanner scannerWithString:s];
            if ([sc scanHexLongLong:&u]) return (int64_t)u;
        }
        return (int64_t)[s longLongValue];
    }
    return 0;
}

// ============================================================
// MG key → config key mapping. Copied verbatim from v2 Tweak.xm
// (extracted lines 1097-1207). Order: identity > radio > hardware
// caps > version > misc. If a target SDK reads a key not in this
// map, the unhooked call returns the real value — add the alias
// here if you observe a fingerprint mismatch.
// ============================================================
static NSDictionary *g_mgKeyMap = nil;
static void initMGKeyMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_mgKeyMap = @{
            @"UniqueDeviceID":@"UniqueDeviceID", @"SerialNumber":@"SerialNumber",
            @"UniqueChipID":@"UniqueChipID",
            @"InternationalMobileEquipmentIdentity":@"InternationalMobileEquipmentIdentity",
            @"InternationalMobileEquipmentIdentity2":@"InternationalMobileEquipmentIdentity2",
            @"MobileEquipmentIdentifier":@"MobileEquipmentIdentifier",
            @"IntegratedCircuitCardIdentity":@"IntegratedCircuitCardIdentity",
            @"IntegratedCircuitCardIdentity2":@"IntegratedCircuitCardIdentity2",
            @"PhoneNumber":@"PhoneNumber",
            @"ProductType":@"ProductType", @"HardwareModel":@"HardwareModel",
            @"HWModelStr":@"HWModelStr", @"ModelNumber":@"ModelNumber",
            @"RegionCode":@"RegionCode", @"RegionInfo":@"RegionInfo",
            @"WiFiAddress":@"WiFiAddress", @"BluetoothAddress":@"BluetoothAddress",
            @"EthernetAddress":@"EthernetAddress",
            @"BoardId":@"BoardId", @"HardwarePlatform":@"BoardId",
            @"ChipID":@"ChipID", @"FirmwareVersion":@"FirmwareVersion",
            @"BasebandVersion":@"BasebandVersion",
            @"BasebandSerialNumber":@"BasebandSerialNumber",
            @"BasebandChipId":@"BasebandChipId", @"BasebandCertId":@"BasebandCertId",
            @"BuildVersion":@"BuildVersion",
            @"ProductBuildVersion":@"BuildVersion",
            @"OSBuildVersion":@"BuildVersion",
            @"SoftwareBundleVersion":@"BuildVersion",
            @"ProductVersion":@"systemVersion",          // was unset -> leaked REAL iOS
            @"ProductVersionString":@"systemVersion",
            @"MaxSupportedOSVersion":@"systemVersion",
            // NOTE: "SupportedOSVersions" intentionally NOT mapped — iOS returns
            // a CFArray for it, but our hook can only emit a CFString, which would
            // type-confuse (and possibly crash) a CFArray caller. Let it pass
            // through to the real (harmless) value.
            @"DeviceColor":@"DeviceColor",
            @"DeviceEnclosureColor":@"DeviceEnclosureColor",
            @"DiskUsage":@"DiskUsage", @"TotalDiskCapacity":@"TotalDiskCapacity",
            @"TotalSystemAvailable":@"TotalSystemAvailable",
            @"BatteryCurrentCapacity":@"BatteryCurrentCapacity",
            @"BatteryIsCharging":@"BatteryIsCharging",
            @"BatterySerialNumber":@"BatterySerialNumber",
            @"BootNonce":@"BootNonce",
            @"DeviceName":@"DeviceNameMG",
            @"UserAssignedDeviceName":@"UserAssignedDeviceName",
            @"MarketingName":@"MarketingName",
            @"AirplaneMode":@"AirplaneMode",
            @"MobileSubscriberCountryCode":@"carrierMCC",   // match the faked carrier
            @"MobileSubscriberNetworkCode":@"carrierMNC",
            @"SIMTrayStatus":@"SIMTrayStatus",
            @"HasFaceID":@"HasFaceID", @"HasTouchID":@"HasTouchID",
            @"HasMesa":@"HasTouchID", @"HasHomeButton":@"HasHomeButton",
            @"HasOLEDDisplay":@"HasOLEDDisplay",
            @"Has5GUW":@"Has5G", @"HasNFC":@"HasNFC",
            @"HasCellularConnectivity":@"HasCellularConnectivity",
            @"HasBaseband":@"HasCellularConnectivity",
            @"InitialActivationDate":@"InitialActivationDate",
            @"ActivationState":@"ActivationState",
            @"ActivationStateAcknowledged":@"ActivationStateAcknowledged",
            @"DeviceVariant":@"DeviceVariant", @"DeviceVariantGUID":@"DeviceVariantGUID",
            @"RegulatoryModelNumber":@"RegulatoryModelNumber",
            @"MLBSerialNumber":@"SerialNumber",
            @"AirTelephonyCapability":@"HasCellularConnectivity",
            @"ApNonce":@"identifierForVendor", @"SEPNonce":@"identifierForVendor",
            @"BoardSerialNumber":@"SerialNumber",
            @"PartitionType":@"PartitionType",
            @"ProductHash":@"ProductType",
            @"DeviceClassNumber":@"ChipID",
            @"DeviceClass":@"DeviceClass",
        };
    });
}

// Keys whose iOS API returns an NSNumber (integer). Returning an
// NSString here would crash the caller via CFNumberGetValue.
static NSSet *g_intKeys = nil;
// Keys whose iOS API returns a CFBoolean. The host writes these as NSNumber(BOOL);
// they used to fall through to the NSString-only getConfigStr branch (→ nil → real
// capability leaked, a clean fingerprint mismatch). Route them through
// getConfigBool → a real CFBoolean, matching what libMobileGestalt returns.
static NSSet *g_boolKeys = nil;
static void initIntKeys(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_intKeys = [NSSet setWithObjects:
            @"TotalDiskCapacity", @"TotalSystemAvailable", @"DiskUsage",
            @"BatteryCurrentCapacity", @"ChipID", @"BoardId",
            @"HardwarePlatform", @"UniqueChipID", nil];
        g_boolKeys = [NSSet setWithObjects:
            @"BatteryIsCharging", @"AirplaneMode",
            @"HasFaceID", @"HasTouchID", @"HasMesa", @"HasHomeButton",
            @"HasOLEDDisplay", @"Has5GUW", @"HasNFC",
            @"HasCellularConnectivity", @"HasBaseband",
            @"AirTelephonyCapability", nil];
    });
}

// ============================================================
// MGCopyAnswer hook. Hot path runs hundreds-of-thousands of times
// per session in chat / feed scrolling — every alloc costs.
// Re-entry guard: hook MAY recurse if CFLog/NSLog reach back into
// MG. Thread-local guard short-circuits the second pass.
// ============================================================
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef property);
static MGCopyAnswer_t orig_MGCopyAnswer = NULL;
__thread int g_inMG = 0;

// Memoized real-MGCopyAnswer passthrough (0x8BADF00D fix, 4.1.5).
//
// ROOT CAUSE, proven on-device: a LICENSED launch answers the hot keys from
// config and launches Zalo fine; an UNLICENSED launch (expired/missing token →
// every value nil) sends EVERY query to the real MGCopyAnswer — and Firebase
// hammers -[UIDevice systemVersion] (→ MGCopyAnswer("ProductVersion")) while
// UIKit hammers the capability keys, so the real fn runs tens of thousands of
// times during scene-create → ~80-100s CPU in <26s wall → FrontBoard watchdog
// SIGKILL ("treo logo → văng", and the crash on restore-to-another-account,
// which relaunches Zalo cold — unlicensed if the restored profile lacks a live
// token). MG hardware/version/capability values are immutable for a process, so
// caching the real answer per key makes the real fn run at most once per key;
// every later query is an O(1) dict hit. Spoofing is untouched — only the
// passthrough (non-spoofed) answers are cached.
static pthread_mutex_t g_mgCacheMu = PTHREAD_MUTEX_INITIALIZER;
static CFMutableDictionaryRef g_mgOrigCache = NULL;

static CFTypeRef mgOrigCached(CFStringRef property) {
    if (!property) return NULL;
    // A few keys genuinely change within a session — never cache them.
    static NSSet *volatileKeys = nil; static dispatch_once_t vo;
    dispatch_once(&vo, ^{
        volatileKeys = [NSSet setWithObjects:
            @"DiskUsage", @"TotalDiskCapacity", @"TotalSystemAvailable",
            @"BatteryCurrentCapacity", @"BatteryIsCharging", @"AirplaneMode", nil];
    });
    if ([volatileKeys containsObject:(__bridge NSString *)property]) {
        g_inMG = 1; CFTypeRef r = orig_MGCopyAnswer(property); g_inMG = 0;
        return r;
    }

    pthread_mutex_lock(&g_mgCacheMu);
    if (!g_mgOrigCache)
        g_mgOrigCache = CFDictionaryCreateMutable(NULL, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFTypeRef cached = g_mgOrigCache ? CFDictionaryGetValue(g_mgOrigCache, property) : NULL;
    if (cached) {
        if (cached != kCFNull) CFRetain(cached);   // hand the caller its own +1
        pthread_mutex_unlock(&g_mgCacheMu);
        return (cached == kCFNull) ? NULL : cached;
    }
    pthread_mutex_unlock(&g_mgCacheMu);

    // Miss: run the real fn ONCE (guarded against re-entry), then cache it.
    g_inMG = 1;
    CFTypeRef r = orig_MGCopyAnswer(property);
    g_inMG = 0;

    pthread_mutex_lock(&g_mgCacheMu);
    if (g_mgOrigCache) CFDictionarySetValue(g_mgOrigCache, property, r ? r : (CFTypeRef)kCFNull);
    pthread_mutex_unlock(&g_mgCacheMu);
    return r;   // caller owns the +1 the real fn returned; the dict took its own
}

static CFTypeRef hooked_MGCopyAnswer(CFStringRef property) {
    if (g_inMG || !property) return orig_MGCopyAnswer(property);

    // Map lookup FIRST (cheap NSDictionary hit). The vast majority of MG
    // queries during scene-create are keys we do NOT spoof — pass them straight
    // through so we never pay for the expensive caller check below.
    //
    // WHY THIS ORDER MATTERS (0x8BADF00D fix): dladdr() walks the loaded-image
    // list and takes the dyld lock. The old code ran it on EVERY MG call, so
    // while Zalo dlopen'd images during scene-create (right after "skip
    // avatar") the main thread kept blocking on that lock → ~19s wall, ~0.2s
    // CPU → FrontBoard "scene-create watchdog" SIGKILL ("văng ra màn hình
    // chính"). Now dladdr fires only for the handful of keys we actually spoof.
    NSString *key = (__bridge NSString *)property;
    NSString *configKey = g_mgKeyMap[key];
    if (!configKey) {
        if (ci_dbgEnabled()) {   // only stringify the key when logging is on
            char kb[128]; kb[0] = 0;
            if (CFStringGetCString(property, kb, sizeof(kb), kCFStringEncodingUTF8) && kb[0])
                dbglog("MG.miss %s %s\n", g_procname, kb);
        }
        return mgOrigCached(property);
    }

    // Resolve the spoof value FIRST, under the re-entry guard. Only if we
    // actually have one do we pay for the dladdr caller-check below.
    //
    // WHY (second half of the 0x8BADF00D fix, 4.1.4): dladdr walks the image
    // list + takes the dyld lock. Running it on EVERY mapped-key query — even
    // when we're going to pass through anyway — re-created the scene-create
    // watchdog stall, because UIKit hammers capability keys (HasFaceID,
    // HasCellularConnectivity, HasTouchID, …) hundreds of times during
    // scene-create, and an UNLICENSED tweak (cfg()==@{} → every value nil)
    // was doing a dyld-locking dladdr on each one for nothing. Now: no spoof
    // value → straight passthrough, no dladdr.
    g_inMG = 1;
    CFTypeRef result = NULL;
    if ([g_boolKeys containsObject:key]) {
        if (getConfig(configKey)) {
            // Real MGCopyAnswer returns a CFBoolean for these keys. Return an
            // actual kCFBoolean (not a boxed NSNumber) so CFEqual /
            // CFBooleanGetValue callers evaluate it correctly. getConfigBool
            // accepts both NSNumber and "1"/"true"/"yes" string forms.
            result = (CFTypeRef)CFRetain(getConfigBool(configKey)
                                         ? kCFBooleanTrue : kCFBooleanFalse);
        }
    } else if ([g_intKeys containsObject:key]) {
        if (getConfig(configKey)) {
            int64_t v = configValueAsMGInteger(configKey);
            result = (__bridge_retained CFTypeRef)@(v);
        }
    } else {
        NSString *s = getConfigStr(configKey);
        if (s) result = (__bridge_retained CFTypeRef)s;
    }
    g_inMG = 0;

    if (!result) return mgOrigCached(property);

    // We have a spoof value → NOW skip UIKit/system-internal callers.
    // MSHookFunction patches MG globally, so UIKit's internal
    // _UIDeviceNativeUserInterfaceIdiomIgnoringClassic also lands here; feeding
    // it a fake ProductType (no matching device plist) → initWithContentsOfFile:
    // throws → std::terminate → SIGABRT. Pass those through (real value).
    Dl_info _di; _di.dli_fname = NULL;
    dladdr(__builtin_return_address(0), &_di);
    if (_di.dli_fname &&
        (strncmp(_di.dli_fname, "/System/Library/", 16) == 0 ||
         strncmp(_di.dli_fname, "/usr/lib/", 9) == 0 ||
         strncmp(_di.dli_fname, "/var/jb/usr/lib/", 16) == 0)) {
        CFRelease(result);
        return mgOrigCached(property);
    }
    return result;
}

// ============================================================
// LAYER 2: IORegistry — AIDA64-style apps read IOPlatformSerialNumber,
// IOPlatformUUID, board-id, model, serial-number, mlb-serial-number
// directly from IOKit registry (bypass MG). Hook both Create + Search.
// ============================================================
typedef CFTypeRef (*IORegCreateCFProp_t)(mach_port_t entry, CFStringRef key,
                                          CFAllocatorRef alloc, uint32_t options);
typedef CFTypeRef (*IORegSearchCFProp_t)(mach_port_t entry, const char *plane,
                                          CFStringRef key, CFAllocatorRef alloc,
                                          uint32_t options);
static IORegCreateCFProp_t orig_IORegCreate = NULL;
static IORegSearchCFProp_t orig_IORegSearch = NULL;

static NSDictionary *g_ioKeyMap = nil;
static void initIOKeyMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_ioKeyMap = @{
            @"IOPlatformSerialNumber":@"IOPlatformSerialNumber",
            @"IOPlatformUUID":@"IOPlatformUUID",
            @"board-id":@"IOBoardId",
            @"product-name":@"hw_machine",       // was unset -> leaked real; reuse fake model id
            @"model":@"hw_machine",              // was unset -> leaked real
            @"serial-number":@"SerialNumber",    // was unset -> leaked REAL serial; now = MG serial
            @"mlb-serial-number":@"IODeviceTreeMLBSerial",
            @"region-info":@"RegionInfo",
            @"region-code":@"RegionCode",
            @"model-number":@"ModelNumber",
            @"config-number":@"ModelNumber",
            @"device_type":@"hw_machine",
            @"target-type":@"hw_machine",
            @"chip-id":@"ChipID",
            @"board":@"IOBoardId",
            @"compatible":@"hw_machine",
            @"system-serial-number":@"IOPlatformSerialNumber",
            // Observed in AIDA64 IORegCreate logs but un-spoofed:
            @"product-id":@"ProductType",
            // Network controllers — AIDA Network tab pulls MAC from IOKit,
            // not from getifaddrs. IOEthernetController + IO80211Controller
            // both expose IOMACAddress as NSData (6 bytes).
            @"IOMACAddress":@"WiFiAddress",
            @"IO80211InterfaceMACAddress":@"WiFiAddress",
            @"IO80211HardwareAddress":@"WiFiAddress",
            @"IOEthernetMACAddress":@"EthernetAddress",
            // NOTE (4.0.9): MetalPluginName/MetalPluginClassName spoof REMOVED.
            // Spoofing only the GPU driver-name strings while gpu_gen/num_cores
            // (GPUConfigurationVariable) + the AGXAccelerator class still report
            // the real chip is an internal contradiction that locked fresh Zalo
            // accounts at registration (4.0.8). Leave GPU identity real and
            // self-consistent, like the stable 4.0.6.
        };
    });
}

// hw.model returns a BOARD ID (e.g. "D22AP" for iPhone X, "D54pAP"
// for 12 Pro Max), NOT a product type string. AIDA's marketing-name
// lookup expects board ID format; feeding it "iPhone13,4" makes the
// table miss and fall back. This table maps ProductType to BoardID
// for the common iPhone models we ship presets for. Add entries as
// the host app's preset DB grows.
static NSString *productTypeToBoardId(NSString *pt) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"iPhone8,4":@"N69uAP",                               // SE 1
            @"iPhone8,1":@"N71AP",   @"iPhone8,2":@"N66AP",       // 6s / 6s Plus
            @"iPhone9,1":@"D10AP",   @"iPhone9,2":@"D11AP",       // 7 / 7 Plus (US)
            @"iPhone9,3":@"D101AP",  @"iPhone9,4":@"D111AP",      // 7 / 7 Plus (intl)
            @"iPhone10,1":@"D20AP",  @"iPhone10,2":@"D21AP",      // 8 / 8 Plus (US)
            @"iPhone10,4":@"D201AP", @"iPhone10,5":@"D211AP",     // 8 / 8 Plus (intl)
            @"iPhone10,3":@"D22AP",  @"iPhone10,6":@"D221AP",     // X
            @"iPhone11,2":@"D321AP",                              // XS
            @"iPhone11,4":@"D331AP", @"iPhone11,6":@"D331pAP",    // XS Max
            @"iPhone11,8":@"N841AP",                              // XR
            @"iPhone12,1":@"N104AP",                              // 11
            @"iPhone12,3":@"D421AP", @"iPhone12,5":@"D431AP",     // 11 Pro / Max
            @"iPhone12,8":@"D79AP",                               // SE 2
            @"iPhone13,1":@"D52gAP", @"iPhone13,2":@"D53gAP",     // 12 mini / 12
            @"iPhone13,3":@"D53pAP", @"iPhone13,4":@"D54pAP",     // 12 Pro / Pro Max
            @"iPhone14,2":@"D63AP",  @"iPhone14,3":@"D64AP",      // 13 Pro / Pro Max
            @"iPhone14,4":@"D16AP",  @"iPhone14,5":@"D17AP",      // 13 mini / 13
            @"iPhone14,6":@"D49AP",                               // SE 3
            @"iPhone14,7":@"D27AP",  @"iPhone14,8":@"D28AP",      // 14 / 14 Plus
            @"iPhone15,2":@"D73AP",  @"iPhone15,3":@"D74AP",      // 14 Pro / Pro Max
            @"iPhone15,4":@"D37AP",  @"iPhone15,5":@"D38AP",      // 15 / 15 Plus
            @"iPhone16,1":@"D83AP",  @"iPhone16,2":@"D84AP",      // 15 Pro / Pro Max
        };
    });
    return map[pt];
}

// Forward decl — defined down in the libc-hook section.
static BOOL parseMAC6(const char *s, uint8_t out[6]);

static CFTypeRef ci_ioLookup(NSString *keyStr) {
    NSString *configKey = g_ioKeyMap[keyStr];
    if (!configKey) return NULL;
    NSString *val = getConfigStr(configKey);
    if (!val) return NULL;
    // Device-tree serial keys are stored as NSData (raw bytes) in IOKit.
    if ([keyStr isEqualToString:@"serial-number"] ||
        [keyStr isEqualToString:@"mlb-serial-number"] ||
        [keyStr isEqualToString:@"system-serial-number"]) {
        NSData *d = [val dataUsingEncoding:NSUTF8StringEncoding];
        return (__bridge_retained CFTypeRef)d;
    }
    // IOMACAddress / IO80211*MACAddress / IOEthernetMACAddress = 6 raw bytes.
    // IOKit stores them as NSData, not "aa:bb:..." string. AIDA reads via
    // bytes → format-prints as colon-separated. Wrong encoding = no spoof.
    if ([keyStr isEqualToString:@"IOMACAddress"] ||
        [keyStr isEqualToString:@"IO80211InterfaceMACAddress"] ||
        [keyStr isEqualToString:@"IO80211HardwareAddress"] ||
        [keyStr isEqualToString:@"IOEthernetMACAddress"]) {
        uint8_t b[6];
        if (parseMAC6([val UTF8String], b)) {
            return (__bridge_retained CFTypeRef)[NSData dataWithBytes:b length:6];
        }
        return NULL;
    }
    return (__bridge_retained CFTypeRef)val;
}

// ============================================================
// GPU identity spoof (4.0.9-test). The GPU node (AGXAccelerator*) hard-codes
// the REAL chip across ~8 interlocking keys. Faking a different model leaves
// the GPU shouting the true SoC -> Zalo reads MetalPluginName /
// MetalPluginClassName and reports the real device (an A11 -> "iPhone X")
// despite a spoofed hw.machine. 4.0.8 spoofed only the two driver-name
// strings while gpu_gen / num_cores / class still leaked the real chip =
// internal contradiction = account lock. So here we spoof the WHOLE
// chip-encoding set CONSISTENTLY from the per-chip profile the host app wrote
// into config (gpu_metalName etc.) — present ONLY when the faked ProductType
// differs from the real one; absent -> these helpers no-op -> real GPU.
// ============================================================
static BOOL ci_isGPUNode(mach_port_t entry) {
    io_name_t cls;
    if (IOObjectGetClass(entry, cls) == KERN_SUCCESS) {
        if (strncmp(cls, "AGXAccelerator", 14) == 0) return YES;
        if (strncmp(cls, "AGXDevice", 9) == 0)       return YES;
        if (strncmp(cls, "IOGPU", 5) == 0)           return YES;
    }
    return NO;
}

// GPUConfigurationVariable dict, rebuilt from the spoofed gpu_gen / num_cores
// so it can't contradict MetalPluginName (the 4.0.8 failure mode).
static CFTypeRef ci_gpuConfigVar(void) {
    NSString *g = getConfigStr(@"gpu_gen");
    NSString *c = getConfigStr(@"gpu_cores");
    if (!g.length || !c.length) return NULL;
    int gi = g.intValue, ci = c.intValue;
    if (gi <= 0 || ci <= 0) return NULL;
    NSDictionary *d = @{ @"gpu_gen":@(gi), @"num_cores":@(ci),
                         @"num_gps":@(ci),  @"num_frags":@(ci),
                         @"usc_gen":@(gi >= 13 ? 4 : 2), @"num_mgpus":@(1) };
    return (__bridge_retained CFTypeRef)d;
}

// GPU-UNIQUE keys — these names exist ONLY on the GPU node, so spoofing them
// on any node is collision-free.
static CFTypeRef ci_gpuUnique(NSString *key) {
    NSString *ck = nil;
    if      ([key isEqualToString:@"MetalPluginName"])         ck = @"gpu_metalName";
    else if ([key isEqualToString:@"MetalPluginClassName"])    ck = @"gpu_metalClass";
    else if ([key isEqualToString:@"MetalStatisticsName"])     ck = @"gpu_metalStats";
    else if ([key isEqualToString:@"GPUConfigurationVariable"]) return ci_gpuConfigVar();
    if (ck) { NSString *v = getConfigStr(ck); if (v.length) return (__bridge_retained CFTypeRef)[v copy]; }
    return NULL;
}

// GENERIC IOKit keys that ALSO live on non-GPU nodes — only spoof once the
// caller has confirmed `entry` is the GPU node (else we'd corrupt others).
static CFTypeRef ci_gpuGeneric(NSString *key) {
    if      ([key isEqualToString:@"IOClass"])                 { NSString *v = getConfigStr(@"gpu_ioClass");     if (v.length) return (__bridge_retained CFTypeRef)[v copy]; }
    else if ([key isEqualToString:@"CFBundleIdentifier"] ||
             [key isEqualToString:@"CFBundleIdentifierKernel"]){ NSString *v = getConfigStr(@"gpu_bundleId");    if (v.length) return (__bridge_retained CFTypeRef)[v copy]; }
    else if ([key isEqualToString:@"IONameMatched"])           { NSString *v = getConfigStr(@"gpu_nameMatched"); if (v.length) return (__bridge_retained CFTypeRef)[v copy]; }
    else if ([key isEqualToString:@"IONameMatch"])             { NSString *v = getConfigStr(@"gpu_nameMatched"); if (v.length) return (__bridge_retained CFTypeRef)@[v]; }
    return NULL;
}

static BOOL ci_isGenericGPUKey(NSString *key) {
    return [key isEqualToString:@"IOClass"] ||
           [key isEqualToString:@"CFBundleIdentifier"] ||
           [key isEqualToString:@"CFBundleIdentifierKernel"] ||
           [key isEqualToString:@"IONameMatched"] ||
           [key isEqualToString:@"IONameMatch"];
}

// Per-key GPU spoof for the IORegSearch/Create hooks.
static CFTypeRef ci_gpuSpoof(mach_port_t entry, NSString *key) {
    // GPU spoof is OFF unless the host wrote a profile (it doesn't by default —
    // it was reverted because faking the Metal driver name crashes Zalo's
    // camera/video). Cheap dict lookup short-circuits the whole path (incl. the
    // IOObjectGetClass call) so this is truly inert when disabled.
    if (!getConfigStr(@"gpu_metalName")) return NULL;
    CFTypeRef u = ci_gpuUnique(key);
    if (u) return u;
    // Only pay the IOObjectGetClass cost for ambiguous generic keys.
    if (ci_isGenericGPUKey(key) && ci_isGPUNode(entry)) return ci_gpuGeneric(key);
    return NULL;
}

// Re-entry guard: NSData/NSString creation inside ci_ioLookup may call
// IORegistry under the hood (NSLocale region lookup, memory tagging
// metadata) → re-enters our hook → infinite recursion → AIDA64 burns
// 40s CPU → frontboard scene-update watchdog kills (0x8BADF00D).
__thread int g_inIOReg = 0;

static CFTypeRef hooked_IORegCreate(mach_port_t entry, CFStringRef key,
                                     CFAllocatorRef alloc, uint32_t options) {
    if (g_inIOReg || !key) return orig_IORegCreate(entry, key, alloc, options);
    g_inIOReg = 1;
    initIOKeyMap();
    char kb[128]; kb[0] = 0;
    CFStringGetCString(key, kb, sizeof(kb), kCFStringEncodingUTF8);
    CFTypeRef sp = ci_gpuSpoof(entry, (__bridge NSString *)key);
    if (!sp) sp = ci_ioLookup((__bridge NSString *)key);
    dbglog("IORegCreate %s key=%s spoof=%c\n", g_procname, kb, sp ? 'Y' : 'N');
    g_inIOReg = 0;
    if (sp) return sp;
    return orig_IORegCreate(entry, key, alloc, options);
}

static CFTypeRef hooked_IORegSearch(mach_port_t entry, const char *plane,
                                     CFStringRef key, CFAllocatorRef alloc,
                                     uint32_t options) {
    if (g_inIOReg || !key) return orig_IORegSearch(entry, plane, key, alloc, options);
    g_inIOReg = 1;
    initIOKeyMap();
    char kb[128]; kb[0] = 0;
    CFStringGetCString(key, kb, sizeof(kb), kCFStringEncodingUTF8);
    CFTypeRef sp = ci_gpuSpoof(entry, (__bridge NSString *)key);
    if (!sp) sp = ci_ioLookup((__bridge NSString *)key);
    dbglog("IORegSearch %s plane=%s key=%s spoof=%c\n",
           g_procname, plane ? plane : "?", kb, sp ? 'Y' : 'N');
    g_inIOReg = 0;
    if (sp) return sp;
    return orig_IORegSearch(entry, plane, key, alloc, options);
}

// ============================================================
// IORegistryEntryCreateCFProperties (plural) — returns the WHOLE
// property dict for an IOKit node. AIDA64's "Device" tab pulls
// IOPlatformExpertDevice via this call and iterates the dict locally,
// so the per-key hooks above NEVER fire. We must intercept the dict
// and replace any spoofable keys before returning.
//
// Signature differs from the Create singular variant:
//   kern_return_t (mach_port_t entry, CFMutableDictionaryRef *out,
//                  CFAllocatorRef alloc, uint32_t options)
// The returned dict is sometimes immutable despite the type tag —
// always make a mutable copy, mutate, and swap.
// ============================================================
typedef kern_return_t (*IORegCreateCFProps_t)(mach_port_t entry,
                                               CFMutableDictionaryRef *out,
                                               CFAllocatorRef alloc,
                                               uint32_t options);
static IORegCreateCFProps_t orig_IORegCreateProps = NULL;

static kern_return_t hooked_IORegCreateProps(mach_port_t entry,
                                              CFMutableDictionaryRef *out,
                                              CFAllocatorRef alloc,
                                              uint32_t options) {
    if (g_inIOReg || !out) return orig_IORegCreateProps(entry, out, alloc, options);
    g_inIOReg = 1;
    kern_return_t kr = orig_IORegCreateProps(entry, out, alloc, options);
    if (kr == 0 && *out) {
        initIOKeyMap();
        CFIndex total = CFDictionaryGetCount(*out);
        // CHEAP pre-scan before the costly mutable copy. The GPU / IOSurface
        // nodes fetched constantly during image/video render carry a huge
        // IOReportLegend dict; copying it on every fetch added needless
        // scene-create overhead. CFDictionaryContainsKey is O(1) + zero alloc —
        // only copy when this dict actually holds something we spoof.
        BOOL needCopy = NO;
        for (NSString *ioKey in g_ioKeyMap) {
            if (CFDictionaryContainsKey(*out, (__bridge CFStringRef)ioKey)) { needCopy = YES; break; }
        }
        // GPU node only matters when the GPU spoof is actually configured
        // (default OFF — it was reverted because it crashed Zalo camera/video).
        if (!needCopy && getConfigStr(@"gpu_metalName") &&
            CFDictionaryContainsKey(*out, CFSTR("MetalPluginName"))) needCopy = YES;
        if (!needCopy) {
            dbglog("IORegCreateProps %s keys=%ld replaced=0 skip\n", g_procname, (long)total);
            g_inIOReg = 0;
            return kr;
        }
        CFMutableDictionaryRef mut = CFDictionaryCreateMutableCopy(alloc, 0, *out);
        int replaced = 0;
        if (mut) {
            for (NSString *ioKey in g_ioKeyMap) {
                CFStringRef cfKey = (__bridge CFStringRef)ioKey;
                if (!CFDictionaryContainsKey(mut, cfKey)) continue;
                CFTypeRef sp = ci_ioLookup(ioKey);
                if (sp) {
                    CFDictionarySetValue(mut, cfKey, sp);
                    CFRelease(sp);
                    replaced++;
                }
            }
            // GPU node: presence of MetalPluginName identifies the dict as the
            // AGXAccelerator node — replace the WHOLE chip-encoding set (unique
            // + generic) so an app iterating the dict locally can't catch a
            // real gpu_gen / IOClass contradicting the spoofed driver name.
            if (CFDictionaryContainsKey(mut, CFSTR("MetalPluginName"))) {
                NSArray *gk = @[@"MetalPluginName", @"MetalPluginClassName",
                                @"MetalStatisticsName", @"GPUConfigurationVariable",
                                @"IOClass", @"CFBundleIdentifier",
                                @"CFBundleIdentifierKernel", @"IONameMatched",
                                @"IONameMatch"];
                for (NSString *k in gk) {
                    CFStringRef cfk = (__bridge CFStringRef)k;
                    if (!CFDictionaryContainsKey(mut, cfk)) continue;
                    CFTypeRef sp = ci_gpuUnique(k);
                    if (!sp) sp = ci_gpuGeneric(k);
                    if (sp) {
                        CFDictionarySetValue(mut, cfk, sp);
                        CFRelease(sp);
                        replaced++;
                    }
                }
            }
            if (replaced > 0) {
                CFRelease(*out);
                *out = mut;
            } else {
                CFRelease(mut);
            }
        }
        dbglog("IORegCreateProps %s keys=%ld replaced=%d\n",
               g_procname, (long)total, replaced);
    } else {
        dbglog("IORegCreateProps %s kr=%d out=%p\n",
               g_procname, (int)kr, (void *)(out ? *out : NULL));
    }
    g_inIOReg = 0;
    return kr;
}

// ============================================================
// LAYER 2b: libc syscalls. Device-info viewers like AIDA64 do NOT
// link libMobileGestalt or IOKit — verified by `otool -L AIDA64_c3`
// showing only Foundation/UIKit/CoreTelephony/SystemConfiguration.
// They read hardware identity directly via libc:
//   - sysctlbyname("hw.machine") / "hw.model" → model identifier
//   - getifaddrs() → MAC addresses on AF_LINK sockaddrs
//   - gethostname() → device name (sometimes)
// MGCopyAnswer + IORegistry hooks above are useless for AIDA but
// still needed for Zalo/FB/IG (which DO use libMobileGestalt via
// Firebase / analytics SDKs).
//
// All three are lazy-bound in apps → fishhook rebinds them.
// ============================================================
typedef int (*sysctlbyname_t)(const char *, void *, size_t *, void *, size_t);
typedef int (*sysctl_raw_t)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*getifaddrs_t)(struct ifaddrs **);
typedef int (*gethostname_t)(char *, size_t);
static sysctlbyname_t orig_sysctlbyname = NULL;
static sysctl_raw_t   orig_sysctl_raw   = NULL;
static getifaddrs_t   orig_getifaddrs   = NULL;
static gethostname_t  orig_gethostname  = NULL;

// Re-entry guard mirrors IOReg pattern. NSString/CFString allocation
// inside the hook can itself call sysctlbyname (Foundation queries
// hw.physicalcpu for thread pool sizing on first touch) → recursion.
// Shared by both sysctlbyname and raw sysctl hooks so the inner
// orig_sysctlbyname→sysctl() chain doesn't re-enter either hook.
__thread int g_inSysctl = 0;

// sysctl key → config key. AIDA strings confirmed only hw.model +
// hw.machine, but apps in the wild query the whole hw.* and kern.*
// tree, so spoof everything we have data for.
static NSDictionary *g_sysctlMap = nil;
static void initSysctlMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_sysctlMap = @{
            @"hw.machine":     @"hw_machine",
            @"hw.model":       @"hw_model",
            @"hw.product":     @"hw_machine",
            @"hw.targettype":  @"hw_machine",
            @"hw.memsize":     @"hw_memsize",
            @"hw.physmem":     @"hw_memsize",
            @"hw.ncpu":        @"processorCount",
            @"hw.activecpu":   @"processorCount",
            @"hw.physicalcpu": @"hw_physicalcpu",
            @"hw.logicalcpu":  @"hw_logicalcpu_max",
            @"hw.logicalcpu_max":  @"hw_logicalcpu_max",
            @"hw.physicalcpu_max": @"hw_physicalcpu",
            @"kern.hostname":         @"deviceName",
            @"kern.osversion":        @"BuildVersion",
            @"kern.osrelease":        @"systemVersion",
            @"kern.osproductversion": @"systemVersion",
            @"kern.boottime":         @"kern_boottime",
            @"kern.uuid":             @"IOPlatformUUID",
            // Hardware serial / UUID — strongest persistent identifiers.
            // Previously unmapped, so sysctlbyname("hw.serialnumber") leaked
            // the REAL device serial despite all MobileGestalt spoofing.
            @"hw.serialnumber":       @"SerialNumber",
            @"hw.serialnum":          @"SerialNumber",
            @"hw.boardserialnumber":  @"SerialNumber",
            @"hw.uuid":               @"IOPlatformUUID",
        };
    });
}

// Return 0 = success on string copy. Honors oldp==NULL probe-for-size
// pattern (caller calls twice: once with NULL to learn size, once with buf).
static int writeStringSysctl(const char *s, void *oldp, size_t *oldlenp) {
    size_t need = strlen(s) + 1;
    if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }
    if (!oldlenp) return -1;
    size_t avail = *oldlenp;
    if (avail < need) {
        memcpy(oldp, s, avail);          // truncate, still set size
        ((char*)oldp)[avail - 1] = 0;
        *oldlenp = need;
        return -1;                        // ENOMEM equivalent
    }
    memcpy(oldp, s, need);
    *oldlenp = need;
    return 0;
}

static int writeIntegerSysctl(int64_t v, void *oldp, size_t *oldlenp, size_t width) {
    if (!oldp) { if (oldlenp) *oldlenp = width; return 0; }
    if (!oldlenp || *oldlenp < width) return -1;
    if (width == 4) { uint32_t u = (uint32_t)v; memcpy(oldp, &u, 4); }
    else            { uint64_t u = (uint64_t)v; memcpy(oldp, &u, 8); }
    *oldlenp = width;
    return 0;
}

// ============================================================
// Chip-spec CPU/cache spoof. When the faked ProductType's SoC differs from the
// real silicon (e.g. claiming iPhone 12 / A14 on a physical iPhone X / A11),
// these sysctls leak the REAL chip — cpufamily is the strongest chip
// discriminator, and Zalo's anti-fraud SDK was observed reading hw.l2cachesize.
// Returning the FAKED chip's values keeps the hardware profile consistent.
// cpufamily constants are from <mach/machine.h> (A11 value verified on-device).
// Cache sizes are best-effort per generation.
// ============================================================
typedef struct {
    uint32_t cpufamily, cpusubfamily, cputype, cpusubtype;
    int64_t  l1i, l1d, l2, cacheline, tbfreq;
} ChipSpec;

static BOOL chipSpecForProductType(NSString *pt, ChipSpec *out) {
    if (!pt) return NO;
    ChipSpec s = {0};
    s.cputype = 16777228;   // CPU_TYPE_ARM64 (same for every modern iPhone)
    s.cpusubfamily = 1;
    s.cacheline = 128;      // 128-byte lines on all Apple A-series (verified A11)
    s.tbfreq = 24000000;
    if ([pt hasPrefix:@"iPhone8,"]) {           // A9 Twister (6s / 6s Plus / SE1)
        s.cpufamily = 0x92fb37c8; s.cpusubtype = 1; s.cacheline = 64;
        s.l1i = 65536;  s.l1d = 65536;  s.l2 = 3145728;
    } else if ([pt hasPrefix:@"iPhone9,"]) {    // A10 Fusion (7 / 7 Plus)
        s.cpufamily = 0x67ceee93; s.cpusubtype = 1; s.cacheline = 64;
        s.l1i = 65536;  s.l1d = 65536;  s.l2 = 3145728;
    } else if ([pt hasPrefix:@"iPhone10,"]) {   // A11 Bionic (8 / 8+ / X)
        s.cpufamily = 0xe81e7ef6; s.cpusubtype = 1;   // verified: dump -400654602 == 0xE81E7EF6
        s.l1i = 49152;  s.l1d = 32768;  s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone11,"]) {   // A12 (XS / XS Max / XR)
        s.cpufamily = 0x07d34b9f; s.cpusubtype = 2;
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone12,"]) {   // A13 (11 / 11 Pro / 11 Pro Max)
        s.cpufamily = 0x462504d2; s.cpusubtype = 2;
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone13,"]) {   // A14 (12 / 12 mini / 12 Pro / Max)
        s.cpufamily = 0x1b588bb3; s.cpusubtype = 2;
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone14,"]) {   // A15 (13 series / 14 / 14 Plus / SE3)
        s.cpufamily = 0xda33d83d; s.cpusubtype = 2;
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone15,"]) {   // A16 (14 Pro / Max / 15 / 15 Plus)
        s.cpufamily = 0x8765edea; s.cpusubtype = 2;
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone16,"]) {   // A17 Pro (15 Pro / 15 Pro Max)
        s.cpufamily = 0x2876f5b5; s.cpusubtype = 2;
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt isEqualToString:@"iPhone17,1"] ||
               [pt isEqualToString:@"iPhone17,2"]) {   // A18 Pro (16 Pro / 16 Pro Max)
        s.cpufamily = 0x75d4acb9; s.cpusubtype = 2;     // TAHITI
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone17,"]) {           // A18 (16 / 16 Plus / 16e)
        s.cpufamily = 0x204526d0; s.cpusubtype = 2;     // TUPAI
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt isEqualToString:@"iPhone18,1"] ||
               [pt isEqualToString:@"iPhone18,2"] ||
               [pt isEqualToString:@"iPhone18,4"]) {   // A19 Pro (17 Pro / Pro Max / Air)
        s.cpufamily = 0xab345f09; s.cpusubtype = 2;     // THERA
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else if ([pt hasPrefix:@"iPhone18,"]) {           // A19 (17)
        s.cpufamily = 0x01d7a72b; s.cpusubtype = 2;     // TILOS
        s.l1i = 131072; s.l1d = 131072; s.l2 = 8388608;
    } else {
        return NO;   // unknown SoC → don't spoof (avoid inventing wrong data)
    }
    *out = s;
    return YES;
}

// Returns YES + fills *outVal if `name` is a chip-spec sysctl we should spoof
// for the currently-configured ProductType.
static BOOL chipIntForSysctl(const char *name, int64_t *outVal) {
    NSString *pt = getConfigStr(@"ProductType");
    if (!pt) return NO;
    ChipSpec s;
    if (!chipSpecForProductType(pt, &s)) return NO;
    if (strcmp(name, "hw.cpufamily")      == 0) { *outVal = (int64_t)s.cpufamily;    return YES; }
    if (strcmp(name, "hw.cpusubfamily")   == 0) { *outVal = (int64_t)s.cpusubfamily; return YES; }
    if (strcmp(name, "hw.cputype")        == 0) { *outVal = (int64_t)s.cputype;      return YES; }
    if (strcmp(name, "hw.cpusubtype")     == 0) { *outVal = (int64_t)s.cpusubtype;   return YES; }
    if (strcmp(name, "hw.l1icachesize")   == 0) { *outVal = s.l1i;       return YES; }
    if (strcmp(name, "hw.l1dcachesize")   == 0) { *outVal = s.l1d;       return YES; }
    if (strcmp(name, "hw.l2cachesize")    == 0) { *outVal = s.l2;        return YES; }
    if (strcmp(name, "hw.cachelinesize")  == 0) { *outVal = s.cacheline; return YES; }
    if (strcmp(name, "hw.tbfrequency")    == 0) { *outVal = s.tbfreq;    return YES; }
    if (strcmp(name, "hw.perflevel0.l2cachesize") == 0 ||
        strcmp(name, "hw.perflevel1.l2cachesize") == 0) { *outVal = s.l2;  return YES; }
    if (strcmp(name, "hw.perflevel0.l1icachesize") == 0 ||
        strcmp(name, "hw.perflevel1.l1icachesize") == 0) { *outVal = s.l1i; return YES; }
    if (strcmp(name, "hw.perflevel0.l1dcachesize") == 0 ||
        strcmp(name, "hw.perflevel1.l1dcachesize") == 0) { *outVal = s.l1d; return YES; }
    return NO;
}

static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                                void *newp, size_t newlen) {
    if (g_inSysctl || !name || newp) {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    g_inSysctl = 1;
    initSysctlMap();

    // Chip-spec CPU/cache spoof — keep the SoC profile consistent with the
    // faked ProductType. Match the caller's expected integer width by probing
    // the real sysctl first (these vary: cpufamily=4B, cache sizes often 8B).
    {
        int64_t chipVal = 0;
        if (chipIntForSysctl(name, &chipVal)) {
            size_t ol = 0;
            orig_sysctlbyname(name, NULL, &ol, NULL, 0);
            size_t width = (ol == 4) ? 4 : 8;
            int rc = writeIntegerSysctl(chipVal, oldp, oldlenp, width);
            dbglog("sysctl.chip %s name=%s -> %lld (w=%zu) rc=%d\n",
                   g_procname, name, (long long)chipVal, width, rc);
            g_inSysctl = 0;
            return rc;
        }
    }

    NSString *ns = [NSString stringWithUTF8String:name];
    NSString *cfgKey = g_sysctlMap[ns];
    if (!cfgKey) {
        // Log hw.* and kern.* misses so we can see what the app actually queries
        if (strncmp(name, "hw.", 3) == 0 || strncmp(name, "kern.", 5) == 0)
            dbglog("sysctl.miss %s name=%s\n", g_procname, name);
        g_inSysctl = 0;
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    id v = getConfig(cfgKey);
    if (!v) {
        dbglog("sysctl.nocfg %s name=%s cfgKey=%s\n", g_procname, name, [cfgKey UTF8String]);
        g_inSysctl = 0;
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }

    // Real iOS hw.model returns a BOARD ID ("D22AP"), not a ProductType
    // ("iPhone10,3"). If our config gives us a ProductType, translate.
    if ([(NSString *)ns isEqualToString:@"hw.model"] &&
        [v isKindOfClass:[NSString class]] &&
        [(NSString *)v hasPrefix:@"iPhone"]) {
        NSString *board = productTypeToBoardId((NSString *)v);
        if (board) v = board;
    }

    // kern.boottime returns a struct timeval (16B on arm64), NOT a bare int.
    // Routing it through the integer writer truncated to 8B with garbage tv_usec
    // and a wrong *oldlenp. Emit a full, correctly-sized struct timeval here.
    if ([ns isEqualToString:@"kern.boottime"] && [v isKindOfClass:[NSNumber class]]) {
        struct timeval tv; memset(&tv, 0, sizeof(tv));
        tv.tv_sec = (time_t)[(NSNumber *)v longLongValue];
        int brc;
        if (!oldp) {
            if (oldlenp) *oldlenp = sizeof(tv);
            brc = 0;
        } else if (oldlenp && *oldlenp >= sizeof(tv)) {
            memcpy(oldp, &tv, sizeof(tv));
            *oldlenp = sizeof(tv);
            brc = 0;
        } else {
            brc = -1;
        }
        dbglog("sysctl.boottime %s sec=%lld rc=%d\n", g_procname, (long long)tv.tv_sec, brc);
        g_inSysctl = 0;
        return brc;
    }

    int rc;
    if ([v isKindOfClass:[NSString class]]) {
        const char *sp = [(NSString *)v UTF8String];
        rc = writeStringSysctl(sp, oldp, oldlenp);
        dbglog("sysctl %s name=%s -> '%s' rc=%d\n", g_procname, name, sp, rc);
    } else if ([v isKindOfClass:[NSNumber class]]) {
        // Probe orig to learn caller's expected width (int vs long).
        size_t origLen = 0;
        orig_sysctlbyname(name, NULL, &origLen, NULL, 0);
        size_t width = (origLen == 4) ? 4 : 8;
        rc = writeIntegerSysctl([(NSNumber *)v longLongValue], oldp, oldlenp, width);
        dbglog("sysctl %s name=%s -> %lld (w=%zu) rc=%d\n",
               g_procname, name, [(NSNumber *)v longLongValue], width, rc);
    } else {
        rc = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    g_inSysctl = 0;
    return rc;
}

// Raw sysctl() hook — AIDA64 and similar apps bypass sysctlbyname() by
// calling sysctl({CTL_HW, HW_MACHINE}, ...) with numeric MIBs directly.
// sysctlbyname() itself calls sysctl() internally, so we share g_inSysctl
// to prevent re-entry: if the inner orig_sysctlbyname→sysctl() chain fires,
// g_inSysctl is already 1 and we pass through instantly.
static int hooked_sysctl_raw(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                               void *newp, size_t newlen) {
    if (g_inSysctl || !name || newp || namelen < 2) {
        return orig_sysctl_raw(name, namelen, oldp, oldlenp, newp, newlen);
    }
    g_inSysctl = 1;

    const char *spoofed = NULL;
    if (name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE) {
            NSString *v = getConfigStr(@"hw_machine");
            if (v) spoofed = [v UTF8String];
        } else if (name[1] == HW_MODEL) {
            NSString *v = getConfigStr(@"hw_model");
            if (v) {
                if ([v hasPrefix:@"iPhone"] || [v hasPrefix:@"iPad"] ||
                    [v hasPrefix:@"iPod"]) {
                    NSString *board = productTypeToBoardId(v);
                    if (board) v = board;
                }
                spoofed = [v UTF8String];
            }
        }
    }

    if (spoofed) {
        int rc = writeStringSysctl(spoofed, oldp, oldlenp);
        dbglog("sysctl_raw %s mib=[%d,%d] -> '%s' rc=%d\n",
               g_procname, name[0], name[1], spoofed, rc);
        g_inSysctl = 0;
        return rc;
    }

    g_inSysctl = 0;
    return orig_sysctl_raw(name, namelen, oldp, oldlenp, newp, newlen);
}

// gethostname → spoof to deviceName if set.
__thread int g_inHostname = 0;
static int hooked_gethostname(char *buf, size_t len) {
    if (g_inHostname || !buf || len == 0) return orig_gethostname(buf, len);
    g_inHostname = 1;
    NSString *v = getConfigStr(@"deviceName");
    if (!v) { g_inHostname = 0; return orig_gethostname(buf, len); }
    const char *s = [v UTF8String];
    size_t need = strlen(s);
    size_t cap = len - 1;
    size_t cp = need < cap ? need : cap;
    memcpy(buf, s, cp);
    buf[cp] = 0;
    g_inHostname = 0;
    dbglog("gethostname %s -> %s\n", g_procname, buf);
    return 0;
}

// Parse "aa:bb:cc:dd:ee:ff" → 6 raw bytes. Returns YES on success.
static BOOL parseMAC6(const char *s, uint8_t out[6]) {
    if (!s) return NO;
    unsigned int b[6];
    if (sscanf(s, "%x:%x:%x:%x:%x:%x", &b[0],&b[1],&b[2],&b[3],&b[4],&b[5]) != 6) return NO;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)(b[i] & 0xff);
    return YES;
}

// getifaddrs → call orig, walk linked list, replace MAC bytes in
// every AF_LINK sockaddr_dl based on interface name. The struct is
// mutable from the caller's view (caller passes it to freeifaddrs);
// rewriting the 6 bytes of MAC in place is safe — same alloc, same
// length, just different content.
__thread int g_inIfaddrs = 0;
static int hooked_getifaddrs(struct ifaddrs **ifap) {
    int rc = orig_getifaddrs(ifap);
    if (rc != 0 || g_inIfaddrs || !ifap || !*ifap) return rc;
    g_inIfaddrs = 1;

    NSString *wifiStr = getConfigStr(@"WiFiAddress");
    NSString *btStr   = getConfigStr(@"BluetoothAddress");
    NSString *ethStr  = getConfigStr(@"EthernetAddress");
    uint8_t wifi[6], bt[6], eth[6];
    BOOL hasWifi = wifiStr && parseMAC6([wifiStr UTF8String], wifi);
    BOOL hasBT   = btStr   && parseMAC6([btStr   UTF8String], bt);
    BOOL hasEth  = ethStr  && parseMAC6([ethStr  UTF8String], eth);

    int replaced = 0;
    for (struct ifaddrs *p = *ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)p->ifa_addr;
        if (sdl->sdl_alen != 6) continue;
        const char *nm = p->ifa_name ?: "";
        const uint8_t *src = NULL;
        // en0 = WiFi on iOS; en1 / en2 = USB-eth / hotspot; bridge0 = bridge.
        // awdl0 / llw0 = peer-to-peer WiFi → keep as WiFi MAC.
        if      (strncmp(nm, "en0",    3) == 0 && hasWifi) src = wifi;
        else if (strncmp(nm, "awdl",   4) == 0 && hasWifi) src = wifi;
        else if (strncmp(nm, "llw",    3) == 0 && hasWifi) src = wifi;
        else if (strncmp(nm, "en",     2) == 0 && hasEth)  src = eth;
        else if (strncmp(nm, "bridge", 6) == 0 && hasEth)  src = eth;
        else if (strncmp(nm, "bluetooth", 9) == 0 && hasBT) src = bt;
        if (!src) continue;
        memcpy(LLADDR(sdl), src, 6);
        replaced++;
    }
    dbglog("getifaddrs %s replaced=%d\n", g_procname, replaced);
    g_inIfaddrs = 0;
    return rc;
}

// ============================================================
// SystemConfiguration: SCDynamicStoreCopyComputerName returns the
// user-visible device name ("Hieu's iPhone") for apps that don't use
// UIDevice.name (e.g. AIDA64 — it links SystemConfiguration.framework).
// MSHookFunction patches the symbol directly via dlsym.
// ============================================================
typedef CFStringRef (*SCDSCopyComputerName_t)(void *store, void *nameEncoding);
static SCDSCopyComputerName_t orig_SCDSCopyComputerName = NULL;

__thread int g_inSCDSName = 0;
static CFStringRef hooked_SCDSCopyComputerName(void *store, void *nameEncoding) {
    if (g_inSCDSName) return orig_SCDSCopyComputerName(store, nameEncoding);
    g_inSCDSName = 1;
    NSString *v = getConfigStr(@"deviceName");
    if (v) {
        dbglog("SCDSCopyComputerName %s -> %s\n", g_procname, [v UTF8String]);
        if (nameEncoding) *((CFStringEncoding *)nameEncoding) = kCFStringEncodingUTF8;
        g_inSCDSName = 0;
        return (CFStringRef)CFBridgingRetain([v copy]);
    }
    CFStringRef r = orig_SCDSCopyComputerName(store, nameEncoding);
    g_inSCDSName = 0;
    return r;
}

// ============================================================
// CNCopyCurrentNetworkInfo — returns SSID / BSSID of connected WiFi.
// AIDA64 reads WiFi network name from here, not from getifaddrs.
// Located in NetworkExtension.framework (iOS 14+). Intercepted via
// MSHookFunction since it's a C function, not lazy-bound in most apps.
// ============================================================
typedef CFDictionaryRef (*CNCopyCurrentNetworkInfo_t)(CFStringRef ifName);
static CNCopyCurrentNetworkInfo_t orig_CNCopyCurrentNetworkInfo = NULL;

static CFDictionaryRef hooked_CNCopyCurrentNetworkInfo(CFStringRef ifName) {
    CFDictionaryRef orig = orig_CNCopyCurrentNetworkInfo(ifName);
    if (!orig) return orig; // not connected — don't fake connectivity
    NSString *ssid = getConfigStr(@"wifiSSID");
    if (!ssid) return orig;
    NSMutableDictionary *d = [(__bridge NSDictionary *)orig mutableCopy];
    CFRelease(orig);
    d[@"SSID"] = ssid;
    d[@"SSIDDATA"] = [ssid dataUsingEncoding:NSUTF8StringEncoding];
    NSString *bssid = getConfigStr(@"wifiBSSID");
    if (bssid) d[@"BSSID"] = bssid;
    dbglog("CNCopyCurrentNetworkInfo %s ssid=%s\n", g_procname, [ssid UTF8String]);
    return (CFDictionaryRef)CFBridgingRetain(d);
}

// ============================================================
// LAYER 11: Keychain device-fingerprint isolation — Zalo reg-ban fix.
//
// Zalo stores a persistent device ID in Keychain that survives app
// reinstalls. During registration this ID is sent to VNG servers and
// cross-checked against the ban list. If the device was previously
// used for a banned account → instant ban on every new registration.
//
// Exact account names discovered via Keychain dump of vn.com.vng.zingalo:
//   kZAIDForDevice      — 32-char hex, the primary device fingerprint
//   zda_device_udid     — UUID format device ID
//   kZAIDForAdvertisingKey — Advertising UUID stored by Zalo (not IDFA)
//   kSecurityIndentifierKey — Security fingerprint (VNG's internal misspelling)
//   deviceUUID / deviceModel — ZaloSDK cached identity (svce: ...zalosdk)
//   firstTimeInstallApp / installSource — controls fresh-install flow
//   Firebase FID        — Firebase Installation ID used for analytics tracking
//
// Hook: SecItemCopyMatching returns errSecItemNotFound for these keys when
// identity spoofing is active. Zalo generates fresh IDs → clean registration.
// SecItemAdd is NOT blocked (new IDs for this session are stored normally).
// ============================================================
#import <Security/Security.h>

// Exact account names to block — from live Keychain dump of Zalo 23.x
static const char * const kZaloFpAccounts[] = {
    "kZAIDForDevice",           // Primary device fingerprint (32-char hex)
    "kZAIDForAdvertisingKey",   // Zalo advertising UUID (different from IDFA)
    "zda_device_udid",          // Device UDID (UUID format)
    "kSecurityIndentifierKey",  // Security fingerprint (note VNG typo)
    "kThisDeviceOnlyKey",       // Device-only preference flag
    "_pfo",                     // Platform fingerprint object
    // ZaloSDK (svce: vn.com.vng.zingalo.zalosdk)
    "deviceUUID",               // SDK device UUID
    "deviceModel",              // SDK cached model — inconsistency with MG spoof
    "firstTimeInstallApp",      // First-install flow controller
    "installSource",            // Install source tag
    NULL
};

typedef OSStatus (*SecItemCopyMatching_t)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*SecItemDelete_t)(CFDictionaryRef);
static SecItemCopyMatching_t orig_SecItemCopyMatching = NULL;

static BOOL isZaloFingerprintQuery(CFDictionaryRef query) {
    (void)query;
    // v4.1.8 — DISABLED (always pass through). The keychain READ + WRITE blocks
    // used to run on every launch, which meant Zalo could NEVER read or persist a
    // device id: every account looked like a brand-new device forever, and an
    // ADManager .adbk restore never came back as a "trusted device" (thiết bị
    // quen). Device separation between registrations is now handled by a ONE-SHOT
    // synchronous keychain wipe that fires exactly once per Change Device (see
    // ci_runOneShotIfDue) — BEFORE Zalo's own code runs — so stale ids are gone
    // without ever blocking the fresh/restored id that must persist. Blocking is
    // therefore both unnecessary and actively harmful, so it is removed.
    return NO;
}

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (isZaloFingerprintQuery(query)) {
        CFStringRef acc = (CFStringRef)CFDictionaryGetValue(query, kSecAttrAccount);
        char ab[64]; ab[0] = 0;
        if (acc && CFGetTypeID(acc) == CFStringGetTypeID())
            CFStringGetCString(acc, ab, sizeof(ab), kCFStringEncodingUTF8);
        dbglog("Keychain.block %s acct=%s\n", g_procname, ab);
        return errSecItemNotFound;
    }
    return orig_SecItemCopyMatching(query, result);
}

// Wipe Zalo's stored device fingerprints from Keychain.
// Called when running inside Zalo's process on identity reload (ReloadConfig).
// From inside the target process we have Zalo's keychain-access-groups entitlement
// so SecItemDelete succeeds where it would fail from an outside process.
// includeFirebase: YES only on a real Change Device (notify_cb) so a fresh
// identity gets a fresh Firebase FID. The per-launch autoWipe passes NO —
// deleting the FID on every launch forced a ~3s network re-registration at
// Zalo's "create account" step. Keeping it lets Firebase cache its FID.
static void wipeZaloKeychainFingerprints(BOOL includeFirebase) {
    NSString *const kAgrp = @"CVB6BX97VM.group.keychain.vn.com.vng.zalo";
    int deleted = 0;
    for (int i = 0; kZaloFpAccounts[i]; i++) {
        NSDictionary *q = @{
            (__bridge id)kSecClass:           (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount:     [NSString stringWithUTF8String:kZaloFpAccounts[i]],
            (__bridge id)kSecAttrAccessGroup: kAgrp,
        };
        if (SecItemDelete((__bridge CFDictionaryRef)q) == errSecSuccess) deleted++;
    }
    if (includeFirebase) {
        // Delete Firebase Installation record (matches by service, not account)
        NSDictionary *fbq = @{
            (__bridge id)kSecClass:           (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService:     @"com.firebase.FIRInstallations.installations",
            (__bridge id)kSecAttrAccessGroup: kAgrp,
        };
        if (SecItemDelete((__bridge CFDictionaryRef)fbq) == errSecSuccess) deleted++;
    }
    dbglog("wipeZaloKC %s deleted=%d fb=%d\n", g_procname, deleted, includeFirebase ? 1 : 0);
}

// v4.1.8: FULL keychain sweep — register (one-shot reset) path ONLY.
// wipeZaloKeychainFingerprints above is surgical: 10 named accounts, generic-
// password class, one access group. Once the per-launch read/write blocks are
// removed (they used to mask this), a device id Zalo stored under ANY other class
// (Key/Identity/Certificate/InternetPassword) or access group (e.g. zalosdk), or
// under a renamed/new key, would SURVIVE a Change Device and link account A→B →
// ban. On the register launch the container was just rm -rf'd, so there is no
// session to preserve: nuke every keychain item the process can reach, across all
// 5 classes, in the app's default group AND the shared Zalo group. Scoped by
// Zalo's own entitlement, so it can never touch another app. Synchronous, once.
static void ci_wipeZaloKeychainFull(void) {
    NSArray *classes = @[ (__bridge id)kSecClassGenericPassword,
                          (__bridge id)kSecClassInternetPassword,
                          (__bridge id)kSecClassKey,
                          (__bridge id)kSecClassCertificate,
                          (__bridge id)kSecClassIdentity ];
    NSMutableArray *groups = [@[ @"CVB6BX97VM.group.keychain.vn.com.vng.zalo" ] mutableCopy];
    // v4.x: Viber persists its device-id in a shared keychain group that survives a
    // Change Device (it is not a Zalo group, so it was never wiped → the account
    // stayed device-linked and re-registration got blocked). When running inside
    // Viber, add its shared group so a Change Device makes Viber look freshly
    // installed. Confirmed on-device: delete+reinstall Viber (which clears this
    // group) let registration succeed — clearing it here reproduces that with no
    // reinstall.
    if (g_procname && strstr(g_procname, "Viber"))
        [groups addObject:@"69V327AA4Z.group.viber.share.keychain"];
    int n = 0;
    for (id cls in classes) {
        // App's default access group (no group pin → all default-group matches).
        if (SecItemDelete((__bridge CFDictionaryRef)@{ (__bridge id)kSecClass: cls }) == errSecSuccess) n++;
        // Explicit shared access group(s).
        for (NSString *g in groups) {
            NSDictionary *q = @{ (__bridge id)kSecClass: cls,
                                 (__bridge id)kSecAttrAccessGroup: g };
            if (SecItemDelete((__bridge CFDictionaryRef)q) == errSecSuccess) n++;
        }
    }
    // Belt-and-braces: named items (covers any group the bare delete missed) + FID.
    wipeZaloKeychainFingerprints(YES);
    dbglog("wipeFull %s classDeletes=%d\n", g_procname, n);
}

// LAYER 11 (cont): Block SecItemAdd/SecItemUpdate for device fingerprint keys.
// SecItemCopyMatching already returns not-found, making Zalo generate a fresh
// device UUID each launch. Without blocking Add/Update, that fresh UUID gets
// written to Keychain and persists until the next wipe — adding noise across
// multiple registrations on the same session. Returning errSecSuccess from Add
// (without actually storing) keeps Zalo happy without persisting anything.
typedef OSStatus (*SecItemAdd_t)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*SecItemUpdate_t)(CFDictionaryRef, CFDictionaryRef);
static SecItemAdd_t    orig_SecItemAdd    = NULL;
static SecItemUpdate_t orig_SecItemUpdate = NULL;

static OSStatus hooked_SecItemAdd(CFDictionaryRef attrs, CFTypeRef *result) {
    if (isZaloFingerprintQuery(attrs)) {
        CFStringRef acc = (CFStringRef)CFDictionaryGetValue(attrs, kSecAttrAccount);
        char ab[64]; ab[0] = 0;
        if (acc && CFGetTypeID(acc) == CFStringGetTypeID())
            CFStringGetCString(acc, ab, sizeof(ab), kCFStringEncodingUTF8);
        dbglog("Keychain.blockAdd %s acct=%s\n", g_procname, ab);
        if (result) *result = NULL;
        return errSecSuccess; // lie to Zalo — it thinks the store succeeded
    }
    return orig_SecItemAdd(attrs, result);
}
static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
    if (isZaloFingerprintQuery(query)) {
        dbglog("Keychain.blockUpdate %s\n", g_procname);
        return errSecItemNotFound;
    }
    return orig_SecItemUpdate(query, attrs);
}

// ============================================================
// RRS keychain DUMP (backup) + RESTORE (re-apply). The host app posts
// "com.changeinfoios/dump_keychain" before a backup and expects us — running
// INSIDE the target app, so we carry its keychain-access-groups — to serialize
// the app's keychain to <container>/tmp/hios_keychain.plist. On restore the host
// drops restore_<bid>.flag + dump_<bid>.plist in /var/jb/etc/changeinfoios/
// (plus a legacy flag in tmp/); on the next launch our %ctor re-applies the
// snapshot so the app's session + local-DB decryption key come back and it reads
// its RESTORED local data instantly instead of re-syncing everything from the
// server (the old 5–10 min wait). Format = array of item dicts keyed by the
// short SecItem attribute names; binary values (incl. v_Data) are wrapped as
// {"__b": <base64>} — the exact shape the host's dump patcher reads/writes.
// ============================================================
static id ci_kcWrap(id v) {
    if ([v isKindOfClass:[NSData class]])
        return @{ @"__b": [(NSData *)v base64EncodedStringWithOptions:0] };
    return v;   // NSString / NSNumber pass through; NSDate handled by caller
}
static id ci_kcUnwrap(id v) {
    if ([v isKindOfClass:[NSDictionary class]] && ((NSDictionary *)v)[@"__b"]) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:((NSDictionary *)v)[@"__b"] options:0];
        return d ?: v;
    }
    return v;
}

static void ci_dumpKeychain(void) {
    if (!orig_SecItemCopyMatching) return;   // origs not installed yet
    NSArray *classes = @[ (__bridge id)kSecClassGenericPassword,
                          (__bridge id)kSecClassInternetPassword,
                          (__bridge id)kSecClassCertificate,
                          (__bridge id)kSecClassKey,
                          (__bridge id)kSecClassIdentity ];
    NSMutableArray *out = [NSMutableArray array];
    for (id cls in classes) {
        NSDictionary *q = @{ (__bridge id)kSecClass:            cls,
                             (__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitAll,
                             (__bridge id)kSecReturnAttributes: (__bridge id)kCFBooleanTrue,
                             (__bridge id)kSecReturnData:       (__bridge id)kCFBooleanTrue };
        CFTypeRef res = NULL;
        // orig_ bypasses our own blocking hook so ALL items are captured.
        OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)q, &res);
        if (st == errSecSuccess && res) {
            NSArray *arr = (CFGetTypeID(res) == CFArrayGetTypeID())
                           ? (__bridge NSArray *)res : @[ (__bridge id)res ];
            for (id itd in arr) {
                if (![itd isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *it = (NSDictionary *)itd;
                NSMutableDictionary *ser = [NSMutableDictionary dictionary];
                ser[@"class"] = cls;   // SecItemCopyMatching doesn't return the class
                for (NSString *k in it) {
                    id v = it[k];
                    if ([v isKindOfClass:[NSDate class]]) continue;   // cdat/mdat read-only
                    id w = ci_kcWrap(v);
                    if (w) ser[k] = w;
                }
                [out addObject:ser];
            }
        }
        if (res) CFRelease(res);
    }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hios_keychain.plist"];
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:out
                        format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
    if (plist.length) [plist writeToFile:path atomically:YES];
    dbglog("Keychain.dump %s items=%lu -> %s\n", g_procname,
           (unsigned long)out.count, [path UTF8String]);
}

static void ci_restoreKeychainIfFlagged(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid.length) return;
    NSString *shared = @"/var/jb/etc/changeinfoios";
    NSString *pFlag = [shared stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"restore_%@.flag", bid]];
    NSString *pDump = [shared stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"dump_%@.plist", bid]];
    NSString *lFlag = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hios_keychain_restore.flag"];
    NSString *lDump = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hios_keychain.plist"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dump = nil;
    if ([fm fileExistsAtPath:pFlag] && [fm fileExistsAtPath:pDump])       dump = pDump;   // primary
    else if ([fm fileExistsAtPath:lFlag] && [fm fileExistsAtPath:lDump])  dump = lDump;   // legacy
    if (!dump) return;   // nothing flagged for this app → no-op

    // Run-once guard keyed by the dump's mtime, persisted in the app's own
    // NSUserDefaults (survives the tmp purge). We usually CANNOT delete the
    // /var/jb restore flag from a sandboxed app, so without this the restore
    // would repeat every launch.
    NSDate *mt = [[fm attributesOfItemAtPath:dump error:nil] fileModificationDate];
    double mtime = mt ? [mt timeIntervalSince1970] : 0;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (mtime > 0 && [ud doubleForKey:@"_ci_kc_done"] == mtime) {
        [fm removeItemAtPath:lFlag error:nil];
        return;   // already applied this dump
    }

    // CRITICAL: run the SecItem work on a BACKGROUND queue, NEVER inline in
    // %ctor — inline it blocked the app launch ~21s → FrontBoard watchdog
    // SIGKILL (Zalo "treo logo rồi văng"). Off the launch path it cannot
    // watchdog the app.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    @autoreleasepool {
    NSData *data = [NSData dataWithContentsOfFile:dump];
    id items = data.length ? [NSPropertyListSerialization propertyListWithData:data
                                  options:0 format:NULL error:NULL] : nil;
    int applied = 0, total = 0;
    if ([items isKindOfClass:[NSArray class]]) {
        for (id itd in (NSArray *)items) {
            if (![itd isKindOfClass:[NSDictionary class]]) continue;
            total++;
            @autoreleasepool {
                NSMutableDictionary *add = [NSMutableDictionary dictionary];
                for (NSString *k in (NSDictionary *)itd) {
                    if ([k isEqualToString:@"cdat"] || [k isEqualToString:@"mdat"]) continue;
                    add[k] = ci_kcUnwrap(((NSDictionary *)itd)[k]);
                }
                if (!add[@"class"]) continue;   // no kSecClass → cannot add
                // Delete an existing item with the SAME identity first (avoids
                // errSecDuplicateItem). Only when we have identifying attrs, so
                // we never nuke a whole class.
                if (add[@"acct"] || add[@"svce"]) {
                    NSMutableDictionary *del = [NSMutableDictionary dictionary];
                    for (NSString *dk in @[ @"class", @"acct", @"agrp", @"svce" ])
                        if (add[dk]) del[dk] = add[dk];
                    SecItemDelete((__bridge CFDictionaryRef)del);
                }
                OSStatus st = orig_SecItemAdd ? orig_SecItemAdd((__bridge CFDictionaryRef)add, NULL)
                                              : SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                if (st != errSecSuccess && st != errSecDuplicateItem && add[@"agrp"]) {
                    // access group might not be writable from here → retry without it
                    [add removeObjectForKey:@"agrp"];
                    st = orig_SecItemAdd ? orig_SecItemAdd((__bridge CFDictionaryRef)add, NULL)
                                         : SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                }
                if (st == errSecSuccess || st == errSecDuplicateItem) applied++;
            }
        }
    }
    // Mark this dump processed (persists across tmp purge) + clear legacy flag.
    if (mtime > 0) { [ud setDouble:mtime forKey:@"_ci_kc_done"]; }
    [fm removeItemAtPath:lFlag error:nil];
    dbglog("Keychain.restore(bg) %s applied=%d/%d bid=%s\n", g_procname, applied, total, [bid UTF8String]);
    } // @autoreleasepool
    }); // dispatch_async
}

// ============================================================
// LAYER 3: UIDevice ObjC — UIDevice.model / .name / .systemName /
// .systemVersion / .identifierForVendor / .batteryLevel / .batteryState
// AIDA64 + most analytics SDKs query these directly.
// ============================================================
%hook UIDevice
- (NSInteger)userInterfaceIdiom {
    NSString *pt = getConfigStr(@"ProductType");
    if (!pt) return %orig;
    if ([pt hasPrefix:@"iPad"]) return 1; // UIUserInterfaceIdiomPad
    return 0; // UIUserInterfaceIdiomPhone
}
- (NSString *)name {
    NSString *v = getConfigStr(@"deviceName");
    dbglog("UIDevice.name %s spoof=%c orig?=%c\n", g_procname, v?'Y':'N', v?'.':'?');
    return v ?: %orig;
}
- (NSString *)model {
    NSString *v = getConfigStr(@"deviceModel");
    dbglog("UIDevice.model %s spoof=%c\n", g_procname, v?'Y':'N');
    return v ?: %orig;
}
- (NSString *)localizedModel {
    NSString *v = getConfigStr(@"localizedModel"); return v ?: %orig;
}
- (NSString *)systemName {
    NSString *v = getConfigStr(@"systemName"); return v ?: %orig;
}
- (NSString *)systemVersion {
    NSString *v = getConfigStr(@"systemVersion");
    dbglog("UIDevice.systemVersion %s spoof=%c\n", g_procname, v?'Y':'N');
    return v ?: %orig;
}
- (NSUUID *)identifierForVendor {
    NSString *v = getConfigStr(@"identifierForVendor");
    if (v) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:v];
        if (u) return u;
    }
    return %orig;
}
- (float)batteryLevel {
    id v = getConfig(@"batteryLevel");
    return v ? [v floatValue] : %orig;
}
- (long)batteryState {
    id v = getConfig(@"batteryState");
    return v ? (long)[v integerValue] : %orig;
}
%end

// ============================================================
// LAYER 4: CLLocationManager — GPS spoof.
// lat/lon/altitude come from config keys set by ci_applyGeoFromIPAPI
// (proxy-IP path) or the VN-city fallback in ci_randomizeIdentities.
// Authorization silently granted → no permission dialog during reg.
// Fake CLLocation delivered to delegate 300ms after startUpdating.
// ============================================================
%hook CLLocationManager
+ (BOOL)locationServicesEnabled {
    if (getConfigStr(@"latitude")) return YES;
    return %orig;
}
+ (int)authorizationStatus {
    // kCLAuthorizationStatus: 0=notDetermined 1=restricted 2=denied 3=Always 4=WhenInUse.
    // Assert the spoofed Always ONLY when location is ACTUALLY granted. While
    // notDetermined/restricted/denied, return the REAL status — faking "Always"
    // over a notDetermined system (e.g. right after a fresh-install Reset) is a
    // system-vs-app contradiction that LOCKS the account (cost 2 accs on fix9/10).
    // Letting real notDetermined through makes the app show the real prompt; once
    // the user allows, this returns Always and startUpdatingLocation feeds fake.
    int real = %orig;
    if (getConfigStr(@"latitude") && (real == 3 || real == 4)) return 3;
    return real;
}
- (int)authorizationStatus {
    int real = %orig;
    if (getConfigStr(@"latitude") && (real == 3 || real == 4)) return 3;
    return real;
}
- (void)requestWhenInUseAuthorization {
    // Show the REAL system prompt (no more simulated auto-grant). When the user
    // allows, +authorizationStatus returns Always and -startUpdatingLocation
    // feeds the fake fix — the spoof works AND system/app stay consistent.
    %orig;
}
- (void)requestAlwaysAuthorization {
    %orig;
}
- (void)startUpdatingLocation {
    NSString *latS = getConfigStr(@"latitude");
    NSString *lonS = getConfigStr(@"longitude");
    if (!latS || !lonS) {
        %orig;
        return;
    }
    CLLocationCoordinate2D c = {latS.doubleValue, lonS.doubleValue};
    double alt = getConfigStr(@"altitude") ? [getConfigStr(@"altitude") doubleValue] : 15.0;
    CLLocation *fake = [[CLLocation alloc] initWithCoordinate:c
                altitude:alt horizontalAccuracy:10.0 verticalAccuracy:5.0
                timestamp:[NSDate date]];
    dbglog("CLLocation.start %s lat=%.4f lon=%.4f alt=%.0f\n",
           g_procname, c.latitude, c.longitude, alt);
    __weak id<CLLocationManagerDelegate> wdel = self.delegate;
    __weak CLLocationManager *wself = self;
    // 50ms — fast enough to beat locationd's first real-GPS callback,
    // but one runloop after startUpdatingLocation so delegate is ready.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        id<CLLocationManagerDelegate> del = wdel;
        CLLocationManager *mgr = wself;
        if (!del || !mgr) return;
        if ([del respondsToSelector:@selector(locationManager:didUpdateLocations:)])
            [del locationManager:mgr didUpdateLocations:@[fake]];
    });
}
- (void)requestLocation {
    [self startUpdatingLocation];
}
// Significant-location-change service (used by Maps background tracking):
// don't start real monitoring, just deliver one fake fix.
- (void)startMonitoringSignificantLocationChanges {
    [self startUpdatingLocation];
}
- (void)stopMonitoringSignificantLocationChanges {
    /* no-op */
}
- (CLLocation *)location {
    NSString *latS = getConfigStr(@"latitude");
    NSString *lonS = getConfigStr(@"longitude");
    if (!latS || !lonS) return %orig;
    // Only hand out a fake fix when location is ACTUALLY authorized. A
    // notDetermined/denied app whose -location returns a real coordinate is an
    // impossible iOS state (no auth -> nil) that anti-fraud flags. [self
    // authorizationStatus] is our hooked value: the real status while not
    // granted, AuthorizedAlways(3) once granted. When not granted, fall through
    // to %orig (which is nil for an unauthorized app) → stays consistent.
    int st = (int)[self authorizationStatus];
    if (st != 3 && st != 4) return %orig;
    CLLocationCoordinate2D c = {latS.doubleValue, lonS.doubleValue};
    double alt = getConfigStr(@"altitude") ? [getConfigStr(@"altitude") doubleValue] : 15.0;
    return [[CLLocation alloc] initWithCoordinate:c altitude:alt
            horizontalAccuracy:5.0 verticalAccuracy:3.0 timestamp:[NSDate date]];
}
// speedFilter / distanceFilter don't matter since we own the delivery.
- (CLLocationDistance)distanceFilter {
    return kCLDistanceFilterNone;
}
// pausesLocationUpdatesAutomatically = NO prevents iOS from stopping
// our fake delivery when the app "stops moving".
- (BOOL)pausesLocationUpdatesAutomatically {
    return NO;
}
%end

// CLGeocoder: no hook needed. When Maps/Weather call
// [geocoder reverseGeocodeLocation:clm.location], clm.location
// already returns our fake coordinates (hook above). Apple's
// geocoding server receives the fake lat/lon and returns the
// correct fake city — real device location never leaves the device.

// ============================================================
// LAYER 5: NSLocale / NSTimeZone — language, region, timezone spoof.
// Config keys localeIdentifier/localeLanguageCode/localeCountryCode/
// localeCurrencyCode/timezoneName must match GPS city and carrier.
// ============================================================
%hook NSLocale
+ (instancetype)currentLocale {
    static __thread BOOL _inLocale = NO;
    if (_inLocale) return %orig;
    NSString *ident = getConfigStr(@"localeIdentifier");
    if (!ident) return %orig;
    _inLocale = YES;
    NSLocale *fake = [[NSLocale alloc] initWithLocaleIdentifier:ident];
    _inLocale = NO;
    return fake ?: %orig;
}
+ (instancetype)autoupdatingCurrentLocale {
    static __thread BOOL _inAuto = NO;
    if (_inAuto) return %orig;
    _inAuto = YES;
    id r = [self currentLocale];
    _inAuto = NO;
    return r;
}
+ (NSArray *)preferredLanguages {
    NSString *lang = getConfigStr(@"localeLanguageCode");
    NSString *rgn  = getConfigStr(@"localeCountryCode");
    if (!lang) return %orig;
    NSString *tag = rgn ? [NSString stringWithFormat:@"%@-%@", lang, rgn] : lang;
    return @[tag, @"en-US"]; // en-US fallback keeps system string formatting sane
}
%end

%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    static __thread BOOL _inTZ = NO;
    if (_inTZ) return %orig;
    NSString *name = getConfigStr(@"timezoneName");
    if (!name) return %orig;
    _inTZ = YES;
    NSTimeZone *tz = [NSTimeZone timeZoneWithName:name];
    _inTZ = NO;
    return tz ?: %orig;
}
+ (NSTimeZone *)localTimeZone {
    return [self systemTimeZone];
}
+ (NSTimeZone *)defaultTimeZone {
    return [self systemTimeZone];
}
%end

// ============================================================
// LAYER 6: CTCarrier — carrier name / MCC / MNC spoof.
// Apps may call CTTelephonyNetworkInfo.serviceSubscriberCellularProviders
// (returning CTCarrier objects) instead of querying MGCopyAnswer,
// bypassing the MG hook. Hook the CTCarrier ObjC methods directly.
// ============================================================
%hook CTCarrier
- (NSString *)carrierName {
    NSString *v = getConfigStr(@"carrierName");
    dbglog("CTCarrier.carrierName %s -> %s\n", g_procname, v ? [v UTF8String] : "orig");
    return v ?: %orig;
}
- (NSString *)mobileCountryCode {
    return getConfigStr(@"carrierMCC") ?: getConfigStr(@"MobileSubscriberCountryCode") ?: %orig;
}
- (NSString *)mobileNetworkCode {
    return getConfigStr(@"carrierMNC") ?: getConfigStr(@"MobileSubscriberNetworkCode") ?: %orig;
}
- (NSString *)isoCountryCode {
    NSString *iso = getConfigStr(@"carrierISO");
    if (!iso) { iso = getConfigStr(@"RegionCode"); }
    return iso ? iso.lowercaseString : %orig;
}
- (BOOL)allowsVOIP {
    return YES;
}
%end

// ============================================================
// LAYER 7: ASIdentifierManager — IDFA advertising identifier spoof.
// advertisingIdentifier UUID is set in config by ci_randomizeIdentities.
// isAdvertisingTrackingEnabled returns YES so apps don't fall back to
// alternative tracking (which could leak real device identity).
// ============================================================
%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    NSString *v = getConfigStr(@"advertisingIdentifier");
    if (v) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:v];
        if (u) {
            dbglog("IDFA %s -> %s\n", g_procname, [v UTF8String]);
            return u;
        }
    }
    return %orig;
}
- (BOOL)isAdvertisingTrackingEnabled {
    return YES;
}
%end

// ============================================================
// LAYER 8: WKWebView — user-agent + LAYER 14: JavaScript fingerprint spoof.
//
// LAYER 8: UA string — zalo_fakeWebViewUA set by ci_randomizeIdentities.
// LAYER 14: Inject WKUserScript at document start to override:
//   navigator.language/languages/platform/maxTouchPoints/hardwareConcurrency
//   screen.width/height/availWidth/availHeight/colorDepth/pixelDepth
//   window.devicePixelRatio
//   HTMLCanvasElement.toDataURL (1-pixel LSB noise per call → unique canvas hash)
//   WebGLRenderingContext.getParameter (UNMASKED_VENDOR/RENDERER → "Apple Inc."/"Apple GPU")
//
// Why: Vietnamese apps (Zalo, Shopee, Facebook) fingerprint the embedded WebView
// JS environment. navigator.language/platform/screen dimensions must match the
// spoofed ProductType + localeIdentifier or the server detects inconsistency.
// ============================================================

// Screen dimensions (CSS logical pixels, not physical) + DPR per ProductType.
// iOS reports screen.width in points (1 pt = DPR physical pixels).
static void screenDimsForProductType(NSString *pt, int *sw, int *sh, double *dpr, int *hc) {
    *sw = 390; *sh = 844; *dpr = 3.0; *hc = 6; // default: iPhone 13/14
    if (!pt || !pt.length) return;
    // SE 2nd/3rd gen (4.7" Retina)
    if ([pt hasPrefix:@"iPhone12,8"] || [pt hasPrefix:@"iPhone14,6"]) {
        *sw = 375; *sh = 667; *dpr = 2.0; *hc = 6;
    // XR / 11 (6.1" LCD, 2x)
    } else if ([pt hasPrefix:@"iPhone11,8"] || [pt hasPrefix:@"iPhone12,1"]) {
        *sw = 414; *sh = 896; *dpr = 2.0; *hc = 6;
    // Xs Max / 11 Pro Max (6.5" OLED, 3x)
    } else if ([pt hasPrefix:@"iPhone12,3"] || [pt hasPrefix:@"iPhone12,5"]) {
        *sw = 414; *sh = 896; *dpr = 3.0; *hc = 6;
    // 12 mini / 13 mini
    } else if ([pt hasPrefix:@"iPhone13,1"] || [pt hasPrefix:@"iPhone14,4"]) {
        *sw = 375; *sh = 812; *dpr = 3.0; *hc = 6;
    // 12 / 13 / 14 / 12 Pro / 13 Pro / 14 Pro (390×844)
    } else if ([pt hasPrefix:@"iPhone13,2"] || [pt hasPrefix:@"iPhone13,3"] ||
               [pt hasPrefix:@"iPhone14,2"] || [pt hasPrefix:@"iPhone14,5"]) {
        *sw = 390; *sh = 844; *dpr = 3.0; *hc = 6;
    // 12 Pro Max / 13 Pro Max / 14 Plus (428×926)
    } else if ([pt hasPrefix:@"iPhone13,4"] || [pt hasPrefix:@"iPhone14,3"]) {
        *sw = 428; *sh = 926; *dpr = 3.0; *hc = 6;
    // 14 Pro / 15 / 15 Pro (393×852)
    } else if ([pt hasPrefix:@"iPhone15,2"] || [pt hasPrefix:@"iPhone15,4"] ||
               [pt hasPrefix:@"iPhone16,1"]) {
        *sw = 393; *sh = 852; *dpr = 3.0; *hc = ([pt hasPrefix:@"iPhone16"] ? 8 : 6);
    // 14 Pro Max / 15 Plus / 15 Pro Max (430×932)
    } else if ([pt hasPrefix:@"iPhone15,3"] || [pt hasPrefix:@"iPhone15,5"] ||
               [pt hasPrefix:@"iPhone16,2"]) {
        *sw = 430; *sh = 932; *dpr = 3.0; *hc = ([pt hasPrefix:@"iPhone16"] ? 8 : 6);
    // iPhone 16 / 16e (393×852 / 390×844 falls to default)
    } else if ([pt isEqualToString:@"iPhone17,3"]) {        // iPhone 16
        *sw = 393; *sh = 852; *dpr = 3.0; *hc = 6;
    } else if ([pt isEqualToString:@"iPhone17,4"]) {        // iPhone 16 Plus
        *sw = 430; *sh = 932; *dpr = 3.0; *hc = 6;
    // iPhone 16 Pro / 17 / 17 Pro (6.3", 402×874)
    } else if ([pt isEqualToString:@"iPhone17,1"] ||
               [pt isEqualToString:@"iPhone18,1"] ||
               [pt isEqualToString:@"iPhone18,3"]) {
        *sw = 402; *sh = 874; *dpr = 3.0; *hc = 6;
    // iPhone 16 Pro Max / 17 Pro Max (6.9", 440×956)
    } else if ([pt isEqualToString:@"iPhone17,2"] ||
               [pt isEqualToString:@"iPhone18,2"]) {
        *sw = 440; *sh = 956; *dpr = 3.0; *hc = 6;
    }
    // NOTE (4.0.6): do NOT add branches for older models (X/XS/8/7/6s/SE).
    // They intentionally fall through to the dpr 3.0 default above. The 4.0.4
    // attempt to return their "correct" low scale (dpr 2.0 for 8/7/6s/SE) made
    // UIScreen.scale/nativeScale mismatch the real device's framebuffer, which
    // crashed Zalo's avatar/image rendering ("văng" after account creation).
    // Reverted to the 4.0.3 behavior — keep scale consistent with real hardware.
}

static NSString *buildWKJSSpoof(void) {
    NSString *lang = getConfigStr(@"localeLanguageCode") ?: @"vi";
    NSString *rgn  = getConfigStr(@"localeCountryCode")  ?: @"VN";
    NSString *tag  = [NSString stringWithFormat:@"%@-%@", lang, rgn];
    int sw, sh, hc; double dpr;
    screenDimsForProductType(getConfigStr(@"ProductType"), &sw, &sh, &dpr, &hc);
    return [NSString stringWithFormat:
        @"(function(){"
         "var l='%@',ls=['%@','en-US'],sw=%d,sh=%d,dpr=%.1f,hc=%d;"
         "function d(o,k,v){"
         "try{Object.defineProperty(o,k,{get:function(){return v;},configurable:true});}catch(e){}}"
         "d(navigator,'language',l);"
         "d(navigator,'languages',Object.freeze(ls));"
         "d(navigator,'platform','iPhone');"
         "d(navigator,'maxTouchPoints',5);"
         "d(navigator,'hardwareConcurrency',hc);"
         "d(screen,'width',sw);d(screen,'height',sh);"
         "d(screen,'availWidth',sw);d(screen,'availHeight',sh-44);"
         "d(screen,'colorDepth',24);d(screen,'pixelDepth',24);"
         "d(window,'devicePixelRatio',dpr);"
         // Canvas 1-pixel LSB noise so hash differs each page load
         "var _ot=HTMLCanvasElement.prototype.toDataURL;"
         "HTMLCanvasElement.prototype.toDataURL=function(){"
         "var c=this.getContext&&this.getContext('2d');"
         "if(c&&this.width>0&&this.height>0){"
         "try{var id=c.getImageData(0,0,1,1);"
         "id.data[0]=(id.data[0]+1)&255;"
         "c.putImageData(id,0,0);}catch(e){}}"
         "return _ot.apply(this,arguments);};"
         // WebGL renderer → Apple GPU (consistent with all real iPhones)
         "function pg(G){"
         "if(!G)return;"
         "var op=G.prototype.getParameter;"
         "G.prototype.getParameter=function(p){"
         "if(p===0x9245)return'Apple Inc.';"
         "if(p===0x9246)return'Apple GPU';"
         "return op.apply(this,arguments);};}"
         "pg(window.WebGLRenderingContext);"
         "if(window.WebGL2RenderingContext)pg(window.WebGL2RenderingContext);"
         "})();",
        tag, tag, sw, sh, dpr, hc];
}

// NOTE (v3.2.8): the v3.2.7 WebView JS additions (Date.getTimezoneOffset / Intl
// timezone / navigator.userAgent / navigator.geolocation overrides + WebRTC
// removal) were REVERTED. They made Zalo's registration WebView ban accounts —
// a clumsy JS spoof (prototype methods whose Function.toString() leaks JS source
// instead of "[native code]", an own-property userAgent getter, and a suspicious
// missing RTCPeerConnection on iOS Safari) reads as ACTIVE TAMPERING, which is a
// stronger ban signal than a real-but-mismatched device. If re-added, the
// overrides MUST be toString-masked to report "[native code]" and WebRTC must be
// candidate-filtered (not removed). See memory: antidetect-audit.

%hook WKWebView
- (NSString *)customUserAgent {
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    return ua ?: %orig;
}
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)cfg {
    WKWebView *v = %orig;
    if (!v) return v;
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    if (ua) [v setCustomUserAgent:ua];
    NSString *js = buildWKJSSpoof();
    if (js) {
        WKUserScript *script = [[WKUserScript alloc]
            initWithSource:js
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
            forMainFrameOnly:NO];
        [v.configuration.userContentController addUserScript:script];
        dbglog("WKWebView.init %s ua+js injected sw=%d\n", g_procname,
               (int)[UIScreen mainScreen].bounds.size.width);
    }
    return v;
}
%end

// ============================================================
// LAYER 9: Jailbreak hiding — block common JB detection vectors.
// Hooks: stat, lstat, access (C), NSFileManager (ObjC),
//        UIApplication -canOpenURL: (URL scheme check).
// Exempts our own config dir so config reads keep working.
// Does NOT hide loaded dylib list — use Shadow/KernBypass for TikTok.
// ============================================================

// A path that media/camera tweaks (VCam) legitimately store user data at.
// These are NOT jailbreak-detection targets — anti-fraud SDKs probe app and
// binary paths (Cydia, apt, bash, substrate), never a user video file — so
// exempting them lets VCam read its source while real JB paths stay hidden.
// VCam (vcamrootless) uses /var/jb/var/mobile/Library/temp.mov and
// /var/jb/var/mobile/Library/vcam_is_mirrored_mark.
static BOOL isTweakDataPath(const char *path) {
    if (strstr(path, "vcam") || strstr(path, "Vcam") || strstr(path, "VCam")) return YES;
    size_t n = strlen(path);
    if (n >= 4) {
        const char *ext = path + n - 4;
        if (strcasecmp(ext, ".mov") == 0 || strcasecmp(ext, ".mp4") == 0 ||
            strcasecmp(ext, ".m4v") == 0)
            return YES;   // video source files for camera tweaks
    }
    return NO;
}

static BOOL isJBPath(const char *path) {
    if (!path) return NO;
    // Never hide our own config directory — reloadConfig must still work
    static const char kCfgDir[] = "/var/jb/etc/changeinfoios/";
    if (strncmp(path, kCfgDir, sizeof(kCfgDir)-1) == 0) return NO;
    // Never hide camera/media tweak data (VCam video + marker files).
    if (isTweakDataPath(path)) return NO;
    static const char * const kHide[] = {
        "/var/jb", "/private/var/jb",
        "/var/lib/apt", "/private/var/lib/apt",
        "/var/lib/cydia", "/var/cache/apt",
        "/Applications/Cydia.app", "/Applications/Sileo.app",
        "/Applications/Zebra.app", "/Applications/filza.app",
        "/Library/MobileSubstrate", "/var/MobileSubstrate",
        "/usr/lib/libsubstrate.dylib", "/usr/lib/substrate",
        "/var/checkra1n.dmg", "/.bootstraprc", "/bootstraprc",
        "/private/etc/apt", "/etc/apt",
        // JB binaries / markers — none ship on stock iOS, so hiding them is safe.
        "/bin/bash", "/bin/sh", "/bin/zsh",
        "/usr/sbin/sshd", "/usr/bin/ssh", "/etc/ssh",
        "/usr/libexec/cydia", "/usr/libexec/substrate",
        "/usr/bin/cycript", "/usr/lib/libcycript.dylib",
        "/usr/lib/TweakInject", "/var/lib/dpkg", "/Library/dpkg",
        "/.installed_unc0ver", "/.bootstrapped_electra", "/.bootstrapped",
        "/taurine", "/var/binpack", "/private/var/binpack", "/jb",
        "/Applications/Filza.app",
        NULL
    };
    for (int i = 0; kHide[i]; i++) {
        if (strncmp(path, kHide[i], strlen(kHide[i])) == 0) return YES;
    }
    return NO;
}

typedef int (*stat_fn_t)(const char *, struct stat *);
typedef int (*access_fn_t)(const char *, int);
static stat_fn_t   orig_stat_fn   = NULL;
static stat_fn_t   orig_lstat_fn  = NULL;
static access_fn_t orig_access_fn = NULL;

// Pass-through for callers whose immediate caller is a JB tweak dylib, so
// they can reach their own files under /var/jb/. Single-frame check via
// __builtin_return_address(1) — cheap and safe. (The earlier backtrace-based
// multi-frame walk caused severe lag + watchdog kills during video calls:
// AVFoundation enumerates dyld images on the camera hot path, and running
// backtrace()+dladdr on every call hung the app. VCam's own files are now
// handled by the isTweakDataPath() whitelist in isJBPath(), which doesn't
// need any caller detection — so a fast single-frame check is sufficient.)
static BOOL statCallerIsJBTweak(void) {
    Dl_info di; di.dli_fname = NULL;
    dladdr(__builtin_return_address(1), &di);
    if (!di.dli_fname) return NO;
    return (strncmp(di.dli_fname, "/var/jb/Library/", 16) == 0 ||
            strncmp(di.dli_fname, "/var/jb/usr/lib/", 16) == 0 ||
            strncmp(di.dli_fname, "/private/var/jb/Library/", 24) == 0);
}

static int hook_stat_fn(const char *path, struct stat *buf) {
    if (isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return -1; }
    return orig_stat_fn(path, buf);
}
static int hook_lstat_fn(const char *path, struct stat *buf) {
    if (isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return -1; }
    return orig_lstat_fn(path, buf);
}
static int hook_access_fn(const char *path, int mode) {
    if (isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return -1; }
    return orig_access_fn(path, mode);
}

// fopen — the single most common JB-file check (fopen("/Applications/Cydia.app"),
// fopen("/bin/bash"), ...). Non-variadic → safe to hook (unlike open(), which was
// removed for a variadic-ABI crash). Our own dbglog targets are exempt: config dir
// is whitelisted in isJBPath and our caller is a /var/jb tweak (statCallerIsJBTweak).
typedef FILE *(*fopen_fn_t)(const char *, const char *);
static fopen_fn_t orig_fopen_fn = NULL;
static FILE *hook_fopen_fn(const char *path, const char *mode) {
    if (path && isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return NULL; }
    return orig_fopen_fn(path, mode);
}

// getenv — hide the injection env vars some anti-fraud SDKs probe.
typedef char *(*getenv_fn_t)(const char *);
static getenv_fn_t orig_getenv_fn = NULL;
static char *hook_getenv_fn(const char *name) {
    if (name && (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
                 strcmp(name, "_MSSafeMode") == 0 ||
                 strcmp(name, "_SubstrateMode") == 0)) return NULL;
    return orig_getenv_fn(name);
}

// NOTE (4.0.6): the realpath() JB-hide hook was REMOVED. It was added in 4.0.4
// and, together with the screen-dims change, is part of the 4.0.4 regression
// that crashed Zalo. The stat/lstat/access/fopen hooks already cover JB-path
// hiding (4.0.3 baseline); realpath is not needed and is left to %orig.

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) return NO;
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) return NO;
    return %orig;
}
- (NSData *)contentsAtPath:(NSString *)path {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) return nil;
    return %orig;
}
- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)err {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) {
        if (err) *err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        return nil;
    }
    return %orig;
}
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)err {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) {
        if (err) *err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        return nil;
    }
    NSArray *orig = %orig;
    if (!orig || orig.count == 0) return orig;
    if (statCallerIsJBTweak()) return orig;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSString *item in orig) {
        NSString *full = [path stringByAppendingPathComponent:item];
        if (!isJBPath([full UTF8String])) [out addObject:item];
    }
    return out;
}
%end

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    NSString *s = url.scheme.lowercaseString;
    if ([s isEqualToString:@"cydia"]     || [s isEqualToString:@"sileo"] ||
        [s isEqualToString:@"zbra"]      || [s isEqualToString:@"filza"] ||
        [s isEqualToString:@"santander"] || [s isEqualToString:@"undecimus"]) {
        return NO;
    }
    return %orig;
}
%end

// ============================================================
// LAYER 10: dyld image list hiding + open() JB path blocking.
//
// Anti-fraud SDKs (Zalo / TikTok) call _dyld_image_count() then
// iterate _dyld_get_image_name(i) looking for:
//   "substrate", "ellekit", "ChangeInfoIos", "/var/jb/" paths.
// We present a filtered view that skips all JB-related images.
//
// open() hook: complements stat/lstat/access — some SDKs call
// open(path, O_RDONLY) to check JB file existence.
// ============================================================

static const char * const kDyldHide[] = {
    "ChangeInfoIosMG", "ChangeInfoIos",
    "ellekit", "CydiaSubstrate", "libsubstrate", "substitute",
    "MobileSubstrate", "TweakInject", "Dopamine", "palera1n",
    "libhooker", "libblackjack", "pspawn", "ChOma",
    NULL
};

static inline BOOL isDyldNameHidden(const char *name) {
    if (!name) return NO;
    for (int i = 0; kDyldHide[i]; i++) {
        if (strstr(name, kDyldHide[i])) return YES;
    }
    if (strstr(name, "/var/jb/") || strstr(name, "/private/var/jb/")) return YES;
    return NO;
}

typedef uint32_t    (*dyld_image_count_fn_t)(void);
typedef const char *(*dyld_image_name_fn_t)(uint32_t);
static dyld_image_count_fn_t  orig_dyld_image_count_fn    = NULL;
static dyld_image_name_fn_t   orig_dyld_get_image_name_fn = NULL;

// Filtered-view cache (0x8BADF00D fix, 4.1.4). The OLD hook was O(N) PER CALL:
// every _dyld_get_image_name(i) re-counted all images AND ran dladdr() on the
// return address. Anti-fraud SDKs — above all FirebaseCrashlytics — enumerate
// the WHOLE image list at launch, so N name-calls × O(N)-per-call = O(N²), and
// the per-call dladdr kept grabbing the dyld lock while Zalo was dlopen'ing more
// images on other threads. On a ~600-image launch that burned ~100s of CPU in
// under 26s wall → FrontBoard scene-create watchdog SIGKILL ("treo logo → văng",
// confirmed: with these hooks removed Zalo launches fine, with them it dies).
//
// Now we cache a visible→real index map, rebuilt only when the real image count
// changes: O(N) once per enumeration, O(1) per name lookup, no per-call dladdr.
// The old caller-passthrough (real list for JB-tweak callers) is dropped — the
// filtered view is self-consistent (count matches names), so app SDKs iterate
// cleanly; a JB tweak that needs a peer dylib resolves it via dlopen(known-path),
// not by scanning this list. The mutex is held ONLY for O(1) reads/swaps and
// never across a dyld call, so it can't invert lock order with dyld's own lock.
static pthread_mutex_t g_dyldMapMu = PTHREAD_MUTEX_INITIALIZER;
static uint32_t  g_dyldCachedTotal   = 0;
static uint32_t  g_dyldVisibleCount  = 0;
static uint32_t *g_dyldVisibleToReal = NULL;   // visible index -> real dyld index
static int       g_dyldMapBuilt      = 0;

// Make the cache reflect `total`. Builds into a fresh local buffer with NO lock
// held (dyld calls happen outside our mutex), then swaps it in under a short lock
// and frees the old buffer. Two racing rebuilders both produce valid maps; last
// swap wins, the loser's buffer is freed. Readers only ever copy an int index out
// under the lock, so a freed buffer can never be dereferenced by another thread.
static void dyldEnsureMap(uint32_t total) {
    pthread_mutex_lock(&g_dyldMapMu);
    int ok = (g_dyldMapBuilt && total == g_dyldCachedTotal);
    pthread_mutex_unlock(&g_dyldMapMu);
    if (ok) return;

    uint32_t *m = (uint32_t *)malloc((total ? total : 1) * sizeof(uint32_t));
    if (!m) return;                       // OOM: keep the stale map, degrade gracefully
    uint32_t vis = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *name = orig_dyld_get_image_name_fn(i);
        if (isDyldNameHidden(name)) continue;
        m[vis++] = i;
    }

    pthread_mutex_lock(&g_dyldMapMu);
    uint32_t *old = g_dyldVisibleToReal;
    g_dyldVisibleToReal = m;
    g_dyldVisibleCount  = vis;
    g_dyldCachedTotal   = total;
    g_dyldMapBuilt      = 1;
    pthread_mutex_unlock(&g_dyldMapMu);
    free(old);
}

static uint32_t hooked_dyld_image_count(void) {
    if (!orig_dyld_image_count_fn || !orig_dyld_get_image_name_fn)
        return orig_dyld_image_count_fn ? orig_dyld_image_count_fn() : 0;
    uint32_t total = orig_dyld_image_count_fn();
    dyldEnsureMap(total);
    pthread_mutex_lock(&g_dyldMapMu);
    uint32_t vc = (g_dyldMapBuilt && g_dyldCachedTotal == total) ? g_dyldVisibleCount : total;
    pthread_mutex_unlock(&g_dyldMapMu);
    return vc;
}

static const char *hooked_dyld_get_image_name(uint32_t index) {
    if (!orig_dyld_get_image_name_fn || !orig_dyld_image_count_fn) return NULL;
    uint32_t total = orig_dyld_image_count_fn();
    dyldEnsureMap(total);
    pthread_mutex_lock(&g_dyldMapMu);
    uint32_t real = (g_dyldMapBuilt && g_dyldCachedTotal == total && index < g_dyldVisibleCount)
                    ? g_dyldVisibleToReal[index] : UINT32_MAX;
    pthread_mutex_unlock(&g_dyldMapMu);
    return (real == UINT32_MAX) ? NULL : orig_dyld_get_image_name_fn(real);
}

// open()/openat() hooks removed: variadic signature + Foundation's
// _NSOpenFileDescriptor_Protected calling open() from multiple threads
// simultaneously caused strncmp to receive an invalid kHide[i] pointer
// (0x209) → EXC_BAD_ACCESS. stat/lstat/access hooks cover the same
// JB-path detection paths without the multi-thread re-entry risk.

// ============================================================
// LAYER 12: DeviceCheck — block token generation.
//
// Apple's DeviceCheck API creates a server-side cryptographic token that
// permanently identifies the device even across factory resets. Zalo sends
// this token to VNG servers during registration for hardware-level binding.
// We return DCErrorFeatureUnsupported so Zalo skips DeviceCheck and falls
// back to software fingerprints (which we're already spoofing via LAYER 11).
// ============================================================
%hook DCDevice
- (void)generateTokenWithCompletionHandler:(void(^)(NSData *, NSError *))completion {
    if (completion) {
        NSError *e = [NSError errorWithDomain:DCErrorDomain
                                         code:DCErrorFeatureUnsupported
                                     userInfo:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            dbglog("DeviceCheck.block %s\n", g_procname);
            completion(nil, e);
        });
    }
}
%end

// ============================================================
// LAYER 13: AppTrackingTransparency — return Authorized.
//
// When ATT status is not Authorized, apps use IDFV-based fingerprinting
// fallbacks that correlate across identity changes (IDFV is per vendor,
// survives reinstalls within the same vendor group). Returning Authorized
// makes apps trust the spoofed IDFA instead of using those fallbacks.
// ============================================================
%hook ATTrackingManager
+ (NSUInteger)trackingAuthorizationStatus {
    return 3; // ATTrackingManagerAuthorizationStatusAuthorized
}
%end

// ============================================================
// NSProcessInfo — iOS version must match UIDevice.systemVersion.
// Anti-fraud SDKs compare operatingSystemVersion struct against the
// UIDevice string value; mismatch is flagged as instrumentation.
// ============================================================
%hook NSProcessInfo
- (NSOperatingSystemVersion)operatingSystemVersion {
    NSString *v = getConfigStr(@"systemVersion");
    if (!v) return %orig;
    NSArray<NSString *> *p = [v componentsSeparatedByString:@"."];
    NSOperatingSystemVersion osv = {0, 0, 0};
    if (p.count > 0) osv.majorVersion = [p[0] integerValue];
    if (p.count > 1) osv.minorVersion = [p[1] integerValue];
    if (p.count > 2) osv.patchVersion = [p[2] integerValue];
    return osv;
}
- (BOOL)isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)v {
    NSOperatingSystemVersion ours = [self operatingSystemVersion];
    if (ours.majorVersion != v.majorVersion) return ours.majorVersion > v.majorVersion;
    if (ours.minorVersion != v.minorVersion) return ours.minorVersion > v.minorVersion;
    return ours.patchVersion >= v.patchVersion;
}
- (NSString *)operatingSystemVersionString {
    NSString *v = getConfigStr(@"systemVersion");
    NSString *b = getConfigStr(@"BuildVersion");
    if (!v) return %orig;
    return b ? [NSString stringWithFormat:@"Version %@ (Build %@)", v, b]
             : [NSString stringWithFormat:@"Version %@", v];
}
- (NSUInteger)processorCount {
    id v = getConfig(@"processorCount");
    return v ? (NSUInteger)[v integerValue] : %orig;
}
- (NSUInteger)activeProcessorCount {
    return [self processorCount];
}
// NSProcessInfo.environment NOT hooked — hooking it caused app-wide hangs
// because WebContent (spawned by every WKWebView app) also receives this dylib
// and the hook fired during early process init before ObjC runtime was stable.
%end

// ============================================================
// LAYER 15: UIScreen — DPR + native pixel dimensions must match
// the spoofed ProductType. Do NOT hook bounds — breaks app layout.
// Fingerprinters read scale/nativeScale/nativeBounds separately.
// ============================================================
%hook UIScreen
- (BOOL)isCaptured { return NO; } // block screen-recording JB detection
- (CGFloat)scale {
    NSString *pt = getConfigStr(@"ProductType");
    if (!pt) return %orig;
    int sw, sh, hc; double dpr;
    screenDimsForProductType(pt, &sw, &sh, &dpr, &hc);
    return (CGFloat)dpr;
}
- (CGFloat)nativeScale {
    return [self scale];
}
- (CGRect)nativeBounds {
    NSString *pt = getConfigStr(@"ProductType");
    if (!pt) return %orig;
    int sw, sh, hc; double dpr;
    screenDimsForProductType(pt, &sw, &sh, &dpr, &hc);
    return CGRectMake(0, 0, (CGFloat)(sw * dpr), (CGFloat)(sh * dpr));
}
%end

// ============================================================
// LAYER 16: NSUserDefaults — Zalo caches device fingerprints in
// UserDefaults as a fast read path before falling back to Keychain.
// Block known device-ID keys so every session starts cold and hits
// the Keychain path (which our SecItemCopyMatching hook blocks).
// Conservative exact-match list to avoid breaking unrelated prefs.
// ============================================================
static NSString * const kZaloUDKeys[] = {
    @"kZAIDForDevice", @"kZAIDForAdvertisingKey", @"zda_device_udid",
    @"kSecurityIndentifierKey", @"deviceUUID", @"deviceModel",
    @"firstTimeInstallApp", @"installSource", @"kThisDeviceOnlyKey",
    @"ZADeviceID", @"zalo_device_id", @"za_device_fingerprint",
    @"FIRInstallationsID", @"firebase_iid", @"GoogleAppID",
    nil
};
static BOOL isZaloUDKey(NSString *k) {
    (void)k;
    // v4.1.8 — DISABLED (always pass through), same reasoning as
    // isZaloFingerprintQuery: blocking the UserDefaults device-id reads on every
    // launch stopped Zalo from ever caching a stable id. The one-shot reset
    // (ci_runOneShotIfDue) removes these keys ONCE per Change Device instead.
    return NO;
}
%hook NSUserDefaults
- (id)objectForKey:(NSString *)k {
    if (isZaloUDKey(k)) {
        dbglog("UDef.block %s key=%s\n", g_procname, [k UTF8String]);
        return nil;
    }
    return %orig;
}
- (NSString *)stringForKey:(NSString *)k {
    return isZaloUDKey(k) ? nil : %orig;
}
- (NSData *)dataForKey:(NSString *)k {
    return isZaloUDKey(k) ? nil : %orig;
}
- (BOOL)boolForKey:(NSString *)k {
    return isZaloUDKey(k) ? NO : %orig;
}
%end

// ============================================================
// LAYER 17: CTTelephonyNetworkInfo — radio access technology
// string (CTRadioAccessTechnologyLTE / NR etc.) must be consistent
// with the spoofed carrier and device capabilities.
// ============================================================
%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    NSString *v = getConfigStr(@"carrierRadioAccess") ?: getConfigStr(@"radioAccessTechnology");
    return v ?: %orig;
}
- (NSDictionary *)serviceCurrentRadioAccessTechnology {
    NSString *v = getConfigStr(@"carrierRadioAccess") ?: getConfigStr(@"radioAccessTechnology");
    if (!v) return %orig;
    NSDictionary *o = %orig;
    if (!o || o.count == 0) return o;
    NSMutableDictionary *d = [o mutableCopy];
    for (NSString *k in o) d[k] = v;
    return [d copy];
}
%end

// ============================================================
// LAYER 18: NSMutableURLRequest — patch User-Agent header.
//
// iOS NSURLSession automatically sends a UA like:
//   "AppName/x.y (iPhone; CPU iPhone OS 17_7 like Mac OS X)"
// containing the REAL iOS version. We replace the real version
// segment with the spoofed one so HTTP traffic is consistent.
// Only fires when the real and spoofed versions differ AND the
// UA actually contains the real version string.
// ============================================================
// Cached UA patch strings — built once per process, reused on every request.
// Calling [[UIDevice currentDevice] systemVersion] on every HTTP request
// triggered our UIDevice hook chain repeatedly → severe startup lag.
static NSString *g_uaRealDot  = nil; // "17_7" (real iOS)
static NSString *g_uaSpoofDot = nil; // "16_7" (spoofed iOS)
static void initUAPatch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *spoof = getConfigStr(@"systemVersion");
        if (!spoof) return;
        // Read real iOS version directly from sysctl to avoid ObjC hook chain
        char buf[32] = {0};
        size_t sz = sizeof(buf);
        sysctlbyname("kern.osproductversion", buf, &sz, NULL, 0);
        NSString *real = buf[0] ? [NSString stringWithUTF8String:buf] : nil;
        if (!real || [real isEqualToString:spoof]) return;
        g_uaRealDot  = [real  stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        g_uaSpoofDot = [spoof stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    });
}
static NSString *patchUA(NSString *value) {
    initUAPatch();
    if (!g_uaRealDot || !value) return value;
    if (![value containsString:g_uaRealDot]) return value;
    return [value stringByReplacingOccurrencesOfString:g_uaRealDot withString:g_uaSpoofDot];
}

%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
        value = patchUA(value);
    %orig(value, field);
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
        value = patchUA(value);
    %orig(value, field);
}
%end

// LAYER 19: fork — block process-spawn JB detection.
// popen/system NOT hooked: if app calls popen() and we return NULL,
// the app may fread/fclose(NULL) → crash. fork() is safe to block
// since it returns EPERM on stock iOS too; no app reads its FILE*.
typedef int (*fork_fn_t)(void);
static fork_fn_t orig_fork_fn = NULL;
static int hooked_fork(void) { errno = EPERM; return -1; }

// ============================================================
// LAYER 20: PKPushRegistry — VoIP push token device fingerprint.
//
// The VoIP push token is device-unique and survives app reinstalls.
// It's often used alongside APNS token for device identity.
// We return the XOR-scrambled apnsTokenSpoof value (same derivation
// the app uses for voipTokenPreview) so it looks legitimate but
// changes every Change Device session.
// ============================================================
%hook PKPushRegistry
- (NSData *)pushTokenForType:(NSString *)type {
    NSString *hex = getConfigStr(@"apnsTokenSpoof");
    if (!hex || hex.length < 64) return %orig;
    NSMutableData *d = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int b = 0;
        NSScanner *sc = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        [sc scanHexInt:&b];
        uint8_t byte = (uint8_t)(b ^ 0xA5);
        [d appendBytes:&byte length:1];
    }
    dbglog("PKPushToken.spoof %s type=%s\n", g_procname, [type UTF8String]);
    return [d copy];
}
%end

// ============================================================
// ONE-SHOT device reset (v4.1.8)
// ------------------------------------------------------------
// Goal: register a NEW account on a genuinely brand-new device (owner's revenue),
// while a KEPT / ADManager-.adbk-restored account comes up as a TRUSTED device
// ("thiết bị quen"). The old code wiped + blocked on EVERY launch, so no account
// ever kept a device id and restores never trusted. Now the wipe fires EXACTLY
// ONCE per Change Device.
//
// Trigger = a random 128-bit nonce the host mints per Change Device:
//   config  wipe_gen_<bid> = G     (lives in /var/jb → NOT captured by a .adbk)
//   Documents/.ci_gen      = G     (host stamps the freshly-wiped container)
//   Documents/.ci_gen_ack  = G     (tweak writes after it consumes the one-shot)
// DUE  <=>  Gs == Gc  AND  Ga != Gc.
// A real Change Device makes Gs==Gc (host writes both to the same fresh G, after
// rm -rf'ing the container) → DUE once, then acked. A restored .adbk carries an
// OLD .ci_gen that cannot equal the current config G (and if nothing changed
// since the backup, Ga already == Gc) → NEVER spuriously due. The ack/stamp live
// in the container (they travel in a .adbk) but the identity-MATCH rule makes
// that harmless — magnitude compares would not, which is why a plain counter is
// unsafe here.
static int g_wipeConsumed = 0;   // process guard: the one-shot runs at most once per launch/process

static NSString *ci_docPath(NSString *name) {
    NSString *home = NSHomeDirectory();
    if (!home.length) return nil;
    return [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:name];
}
static NSString *ci_readTrim(NSString *path) {
    if (!path) return nil;
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}
static void ci_runOneShotIfDue(void) {
    if (g_wipeConsumed) return;
    const char *pn = getprogname();
    // v4.x: allow Viber in addition to Zalo. Viber keeps a device-id across Change
    // Device in its shared keychain group + container; the one-shot wipe (extended
    // in ci_wipeZaloKeychainFull) now clears it so re-registration works.
    if (!pn || !(strstr(pn, "Zalo") || strstr(pn, "zalo") ||
                 strstr(pn, "zingalo") || strstr(pn, "imess") ||
                 strstr(pn, "Viber"))) return;
    // Only meaningful while spoofing an identity.
    if (!getConfigStr(@"UniqueDeviceID") && !getConfigStr(@"SerialNumber")) return;

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"vn.com.vng.zingalo";
    NSString *Gc = getConfigStr([@"wipe_gen_" stringByAppendingString:bid]);
    if (!Gc.length) Gc = getConfigStr(@"wipe_gen");   // global fallback
    if (!Gc.length) return;                           // no generation set → KEEP (never wipe)

    NSString *Gs = ci_readTrim(ci_docPath(@".ci_gen"));       // gen that minted this container
    NSString *Ga = ci_readTrim(ci_docPath(@".ci_gen_ack"));   // gen already consumed
    BOOL due = (Gs.length && [Gs isEqualToString:Gc] &&
                (!Ga.length || ![Ga isEqualToString:Gc]));
    dbglog("oneShot %s bid=%s Gc=%s Gs=%s Ga=%s due=%d\n", g_procname, bid.UTF8String,
           Gc.UTF8String, Gs.length ? Gs.UTF8String : "-", Ga.length ? Ga.UTF8String : "-", (int)due);
    if (!due) return;

    g_wipeConsumed = 1;
    // Synchronous FULL keychain sweep FIRST. Runs inside %ctor (or the ReloadPrefs
    // callback) BEFORE Zalo's own code reads the keychain, so account A's ids are
    // gone before Zalo can see them — no read/write block required. Full sweep (all
    // 5 classes, all Zalo access groups) because the read/write blocks that used to
    // mask non-generic-password / other-group device ids are now gone; a surgical
    // 10-name delete would let those survive and link A→B. Fast, safe (container was
    // just rm -rf'd, nothing to preserve on the register path).
    ci_wipeZaloKeychainFull();
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    for (int i = 0; kZaloUDKeys[i]; i++) [ud removeObjectForKey:kZaloUDKeys[i]];
    [ud synchronize];
    // CONSUME IMMEDIATELY — write the ack SYNCHRONOUSLY, right after the keychain+UD
    // wipe and BEFORE any async work. This makes the ".ci_gen==Gc && ack!=Gc" window
    // (the only state in which a captured .adbk could later re-trigger a wipe)
    // sub-millisecond. The tweak owns its own Documents, so this write is reliable.
    // From now on this container KEEPS its identity: later launches, and any .adbk
    // made from it, are not due → no re-wipe.
    NSString *ackPath = ci_docPath(@".ci_gen_ack");
    if (ackPath) [Gc writeToFile:ackPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dbglog("oneShot %s WIPED ack=%s\n", g_procname, Gc.UTF8String);
    // WKWebsiteDataStore must be touched on the main thread (async is fine — the
    // container itself was already rm -rf'd by the host, this is belt-and-braces).
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            WKWebsiteDataStore *store = [WKWebsiteDataStore defaultDataStore];
            [store removeDataOfTypes:[WKWebsiteDataStore allWebsiteDataTypes]
                       modifiedSince:[NSDate distantPast]
                   completionHandler:^{ dbglog("oneShot.WK cleared %s\n", g_procname); }];
            [[UIPasteboard generalPasteboard] setItems:@[]];
        }
    });
}

// ============================================================
// ctor: install hook + register reload notify.
// ============================================================
static void notify_cb(int t) {
    (void)t;
    reloadConfig();
    // ReloadPrefs after a Change Device may arrive while Zalo is (re)launching —
    // consume the one-shot if this generation is due. No unconditional wipe here
    // any more (that used to destroy restored/kept accounts on every reload).
    ci_runOneShotIfDue();
}

%ctor {
    @autoreleasepool {
        initMGKeyMap();
        initIntKeys();
        reloadConfig();

        const char *pn = getprogname();
        if (pn && pn[0]) g_procname = pn;
        dbglog("ctor pid=%d %s start cfg_keys=%lu\n",
               getpid(), g_procname, (unsigned long)g_config.count);

        // v4.0.4: lightweight mode for two Apple system apps. The Logos %hook
        // on CLLocationManager is already registered before this point, so the
        // GPS spoof stays active; returning here only skips the heavy C-function
        // hooks (sysctl / IORegistry / JB-hide fishhooks) installed below.
        //  - com.apple.Maps: SAFE to inject and DOES use public CLLocationManager,
        //    so the map shows the faked GPS. We keep it light so the map app
        //    stays rock-solid (verified: CLLocation.start fires, no crash).
        //  - com.apple.weather: also kept out of the filter entirely because the
        //    heavy hooks crash WeatherCore; this bail is belt-and-suspenders.
        NSString *mainBID = [[NSBundle mainBundle] bundleIdentifier];
        if ([mainBID isEqualToString:@"com.apple.weather"] ||
            [mainBID isEqualToString:@"com.apple.Maps"]) {
            dbglog("ctor %s lightweight (loc-hook only, skip C-hooks) %s\n",
                   g_procname, mainBID.UTF8String);
            return;
        }

        // 4.1.6 — UNLICENSED → stay COMPLETELY inert (install no C hooks).
        // A tweak with no valid license spoofs nothing, so every C hook below
        // would only pass through to the real function. But that passthrough,
        // multiplied by the tens of thousands of MG / sysctl / dyld / keychain
        // calls Firebase + UIKit make during Zalo's scene-create, piles up
        // ~55-106s of CPU in <26s wall → FrontBoard scene-create watchdog SIGKILL.
        // Proven on-device (192.168.1.175): a tweak-free process launches fine, a
        // LICENSED launch launches fine (values answered from config, real fns
        // barely called), only UNLICENSED-with-hooks dies — and the user's token
        // had expired, which is exactly the "restore sang acc khác bị văng" path
        // (restore relaunches Zalo cold; if the restored profile carries no live
        // token it comes up unlicensed → crash). So when unlicensed we install
        // NOTHING: identical to tweak-free, no watchdog. The Logos %hooks above
        // stay registered but are each config-gated (→ %orig), so they're just as
        // cheap. Hooks come online on the next launch after the host app writes a
        // live token (it relaunches the target on license / identity change).
        // reloadConfig() above already computed g_licOK from the on-disk token.
        if (!g_licOK) {
            dbglog("ctor %s UNLICENSED → inert (no C hooks, fail-open) keys=%lu\n",
                   g_procname, (unsigned long)g_config.count);
            return;
        }

        // Resolve originals first so the hook can chain to them even
        // if fishhook fails to rebind a particular symbol (e.g. when
        // it's eagerly bound or pre-resolved via __DATA __got).
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (h) orig_MGCopyAnswer = (MGCopyAnswer_t)dlsym(h, "MGCopyAnswer");
        orig_sysctlbyname = (sysctlbyname_t)dlsym(RTLD_DEFAULT, "sysctlbyname");
        orig_getifaddrs   = (getifaddrs_t)  dlsym(RTLD_DEFAULT, "getifaddrs");
        orig_gethostname  = (gethostname_t) dlsym(RTLD_DEFAULT, "gethostname");
        dbglog("ctor %s libMG=%p MG=%p sysctl=%p getif=%p ghn=%p\n",
               g_procname, h, (void *)orig_MGCopyAnswer, (void *)orig_sysctlbyname,
               (void *)orig_getifaddrs, (void *)orig_gethostname);
        // libc orig pointers are always resolvable; MG only present on
        // apps that link libMobileGestalt — don't abort if missing,
        // libc hooks are still useful (this is exactly the AIDA case).
        if (!orig_MGCopyAnswer) {
            dbglog("ctor %s WARN: no MGCopyAnswer (app doesn't link libMG) — libc hooks only\n", g_procname);
        }

        // fishhook for lazy-bound libc / MG symbols. AIDA64 doesn't
        // link libMobileGestalt, so MGCopyAnswer hook is a no-op there;
        // sysctlbyname / getifaddrs / gethostname are how AIDA actually
        // reads model + MAC + hostname.
        struct rebinding rebs[] = {
            { "MGCopyAnswer",  (void *)hooked_MGCopyAnswer,
              (void **)&orig_MGCopyAnswer },
            { "sysctlbyname", (void *)hooked_sysctlbyname,
              (void **)&orig_sysctlbyname },
            { "getifaddrs",   (void *)hooked_getifaddrs,
              (void **)&orig_getifaddrs },
            { "gethostname",  (void *)hooked_gethostname,
              (void **)&orig_gethostname },
        };
        int fh = rebind_symbols(rebs, sizeof(rebs)/sizeof(rebs[0]));
        dbglog("ctor %s fishhook MG+libc rc=%d orig: sysctl=%p getif=%p ghn=%p\n",
               g_procname, fh, (void *)orig_sysctlbyname,
               (void *)orig_getifaddrs, (void *)orig_gethostname);

        // Belt-and-suspenders: MSHookFunction patches the function prologue
        // directly, so it intercepts callers regardless of how they're
        // bound (lazy, eager, __got, __TEXT-encrypted). fishhook misses
        // App Store apps that pre-resolve libc into immediate addresses;
        // MSHookFunction catches everyone since libsystem_c is shared.
        // Pre-resolved orig_* gets overwritten by MSHookFunction with a
        // pointer to the saved prologue trampoline — safe in either case.
        if (orig_sysctlbyname) {
            MSHookFunction((void *)orig_sysctlbyname, (void *)hooked_sysctlbyname,
                           (void **)&orig_sysctlbyname);
        }
        // Raw sysctl() — AIDA64 calls sysctl({CTL_HW, HW_MACHINE}, ...) with
        // numeric MIBs directly, bypassing sysctlbyname entirely. Patch the
        // function prologue in libsystem_c so all callers are intercepted.
        // g_inSysctl is shared with hooked_sysctlbyname to break the inner
        // orig_sysctlbyname → sysctl() chain (prevents double-hook re-entry).
        orig_sysctl_raw = (sysctl_raw_t)dlsym(RTLD_DEFAULT, "sysctl");
        if (orig_sysctl_raw) {
            MSHookFunction((void *)orig_sysctl_raw, (void *)hooked_sysctl_raw,
                           (void **)&orig_sysctl_raw);
        }
        if (orig_getifaddrs) {
            MSHookFunction((void *)orig_getifaddrs, (void *)hooked_getifaddrs,
                           (void **)&orig_getifaddrs);
        }
        if (orig_gethostname) {
            MSHookFunction((void *)orig_gethostname, (void *)hooked_gethostname,
                           (void **)&orig_gethostname);
        }
        // MSHookFunction on MGCopyAnswer — now safe because hooked_MGCopyAnswer
        // uses dladdr(__builtin_return_address(0)) to detect the caller image.
        // Calls from /System/Library/ (UIKit, etc.) pass through to real MG.
        // Calls from app bundles (AIDA64 dlopen/dlsym, analytics SDKs) get faked.
        // This fixes AIDA64 serial/IMEI/UDID — AIDA64 loads MG via dlopen+dlsym,
        // which bypasses fishhook's GOT rebind but IS caught by prologue patching.
        if (orig_MGCopyAnswer) {
            MSHookFunction((void *)orig_MGCopyAnswer, (void *)hooked_MGCopyAnswer,
                           (void **)&orig_MGCopyAnswer);
            dbglog("ctor %s MSHook MGCopyAnswer orig=%p\n",
                   g_procname, (void *)orig_MGCopyAnswer);
        }
        dbglog("ctor %s after MSHook libc orig: sysctl=%p sysctl_raw=%p getif=%p ghn=%p\n",
               g_procname, (void *)orig_sysctlbyname, (void *)orig_sysctl_raw,
               (void *)orig_getifaddrs, (void *)orig_gethostname);

        // SCDynamicStoreCopyComputerName — SystemConfiguration framework,
        // used by apps that bypass UIDevice.name for device name.
        void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
        if (sc) {
            void *scdsName = dlsym(sc, "SCDynamicStoreCopyComputerName");
            if (scdsName) {
                orig_SCDSCopyComputerName = (SCDSCopyComputerName_t)scdsName;
                MSHookFunction(scdsName, (void *)hooked_SCDSCopyComputerName,
                               (void **)&orig_SCDSCopyComputerName);
            }
            dbglog("ctor %s SC=%p SCDSCopyName=%p orig=%p\n",
                   g_procname, sc, scdsName, (void *)orig_SCDSCopyComputerName);
        }

        // CNCopyCurrentNetworkInfo — SSID / BSSID of connected WiFi.
        // Used by AIDA64 and other apps to display WiFi network name.
        // Located in NetworkExtension.framework (iOS 14+).
        void *ne = dlopen("/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension", RTLD_NOW);
        if (ne) {
            void *cnSym = dlsym(ne, "CNCopyCurrentNetworkInfo");
            if (cnSym) {
                orig_CNCopyCurrentNetworkInfo = (CNCopyCurrentNetworkInfo_t)cnSym;
                MSHookFunction(cnSym, (void *)hooked_CNCopyCurrentNetworkInfo,
                               (void **)&orig_CNCopyCurrentNetworkInfo);
            }
            dbglog("ctor %s CNCopyCurrentNetworkInfo=%p orig=%p\n",
                   g_procname, ne ? dlsym(ne,"CNCopyCurrentNetworkInfo") : NULL,
                   (void *)orig_CNCopyCurrentNetworkInfo);
        }

        // IORegistry: fishhook can't rebind IOKit framework calls (eager
        // bind / indirect stubs). Use MSHookFunction (ellekit) instead —
        // patches the function prologue with a branch to our trampoline.
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        dbglog("ctor %s IOKit=%p\n", g_procname, iokit);
        if (iokit) {
            void *createSym = dlsym(iokit, "IORegistryEntryCreateCFProperty");
            void *searchSym = dlsym(iokit, "IORegistryEntrySearchCFProperty");
            void *propsSym  = dlsym(iokit, "IORegistryEntryCreateCFProperties");
            dbglog("ctor %s IOReg syms create=%p search=%p props=%p\n",
                   g_procname, createSym, searchSym, propsSym);

            if (createSym) {
                MSHookFunction(createSym, (void *)hooked_IORegCreate,
                               (void **)&orig_IORegCreate);
                dbglog("ctor %s MSHook IORegCreate orig=%p\n",
                       g_procname, (void *)orig_IORegCreate);
            }
            if (searchSym) {
                MSHookFunction(searchSym, (void *)hooked_IORegSearch,
                               (void **)&orig_IORegSearch);
                dbglog("ctor %s MSHook IORegSearch orig=%p\n",
                       g_procname, (void *)orig_IORegSearch);
            }
            if (propsSym) {
                MSHookFunction(propsSym, (void *)hooked_IORegCreateProps,
                               (void **)&orig_IORegCreateProps);
                dbglog("ctor %s MSHook IORegCreateProps orig=%p\n",
                       g_procname, (void *)orig_IORegCreateProps);
            }
        }

        // LAYER 9: JB hiding — stat / lstat / access
        orig_stat_fn   = (stat_fn_t)  dlsym(RTLD_DEFAULT, "stat");
        orig_lstat_fn  = (stat_fn_t)  dlsym(RTLD_DEFAULT, "lstat");
        orig_access_fn = (access_fn_t)dlsym(RTLD_DEFAULT, "access");
        if (orig_stat_fn)
            MSHookFunction((void*)orig_stat_fn,   (void*)hook_stat_fn,   (void**)&orig_stat_fn);
        if (orig_lstat_fn)
            MSHookFunction((void*)orig_lstat_fn,  (void*)hook_lstat_fn,  (void**)&orig_lstat_fn);
        if (orig_access_fn)
            MSHookFunction((void*)orig_access_fn, (void*)hook_access_fn, (void**)&orig_access_fn);
        // fopen — covers the most common JB-file check (open() stays unhooked).
        orig_fopen_fn = (fopen_fn_t)dlsym(RTLD_DEFAULT, "fopen");
        if (orig_fopen_fn)
            MSHookFunction((void*)orig_fopen_fn, (void*)hook_fopen_fn, (void**)&orig_fopen_fn);
        // getenv — hide DYLD_INSERT_LIBRARIES / substrate env probes.
        orig_getenv_fn = (getenv_fn_t)dlsym(RTLD_DEFAULT, "getenv");
        if (orig_getenv_fn)
            MSHookFunction((void*)orig_getenv_fn, (void*)hook_getenv_fn, (void**)&orig_getenv_fn);
        // (4.0.6: realpath hook removed — see note above; reverted 4.0.4 regression)
        dbglog("ctor %s JBhide stat=%p lstat=%p access=%p fopen=%p getenv=%p\n",
               g_procname, (void*)orig_stat_fn, (void*)orig_lstat_fn, (void*)orig_access_fn,
               (void*)orig_fopen_fn, (void*)orig_getenv_fn);

        // LAYER 10: dyld image list hiding
        orig_dyld_image_count_fn    = (dyld_image_count_fn_t)   dlsym(RTLD_DEFAULT, "_dyld_image_count");
        orig_dyld_get_image_name_fn = (dyld_image_name_fn_t)    dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
        if (orig_dyld_image_count_fn && orig_dyld_get_image_name_fn) {
            MSHookFunction((void*)orig_dyld_image_count_fn,    (void*)hooked_dyld_image_count,
                           (void**)&orig_dyld_image_count_fn);
            MSHookFunction((void*)orig_dyld_get_image_name_fn, (void*)hooked_dyld_get_image_name,
                           (void**)&orig_dyld_get_image_name_fn);
        }
        dbglog("ctor %s dyldHide cnt=%p name=%p\n",
               g_procname, (void*)orig_dyld_image_count_fn, (void*)orig_dyld_get_image_name_fn);

        // LAYER 19: block fork() only — popen/system omitted (crash risk).
        orig_fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
        if (orig_fork_fn)
            MSHookFunction((void*)orig_fork_fn, (void*)hooked_fork, (void**)&orig_fork_fn);
        dbglog("ctor %s fork blocked=%p\n", g_procname, (void*)orig_fork_fn);

        // open()/openat() hooks intentionally not installed — see comment above.

        // LAYER 11: Keychain device-fingerprint isolation
        // MSHookFunction patches the Security.framework prologue so ALL callers
        // (including those with pre-bound symbols via dyld shared cache) are intercepted.
        void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
        if (sec) {
            void *sicm = dlsym(sec, "SecItemCopyMatching");
            if (sicm) {
                orig_SecItemCopyMatching = (SecItemCopyMatching_t)sicm;
                MSHookFunction(sicm, (void *)hooked_SecItemCopyMatching,
                               (void **)&orig_SecItemCopyMatching);
            }
            void *siAdd = dlsym(sec, "SecItemAdd");
            if (siAdd) {
                orig_SecItemAdd = (SecItemAdd_t)siAdd;
                MSHookFunction(siAdd, (void *)hooked_SecItemAdd,
                               (void **)&orig_SecItemAdd);
            }
            void *siUpd = dlsym(sec, "SecItemUpdate");
            if (siUpd) {
                orig_SecItemUpdate = (SecItemUpdate_t)siUpd;
                MSHookFunction(siUpd, (void *)hooked_SecItemUpdate,
                               (void **)&orig_SecItemUpdate);
            }
            dbglog("ctor %s Keychain CopyMatch=%p Add=%p Upd=%p\n",
                   g_procname,
                   (void *)orig_SecItemCopyMatching,
                   (void *)orig_SecItemAdd,
                   (void *)orig_SecItemUpdate);
        }

        // Reload config on any of the 3 notification names:
        //   kReloadNote  = com.changeinfoios.v3/ReloadConfig  (v3 native)
        //   kLegacyNote  = com.changeinfoios/ReloadConfig     (v2 legacy)
        //   kAppNote     = com.changeinfoios/ReloadPrefs      (what app actually sends)
        int t1 = 0, t2 = 0, t3 = 0;
        notify_register_dispatch([kReloadNote UTF8String], &t1,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });
        notify_register_dispatch([kLegacyNote UTF8String], &t2,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });
        notify_register_dispatch([kAppNote UTF8String], &t3,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });

        // RRS keychain dump/restore DISABLED (4.1.3). The in-tweak restore ran at
        // launch and repeatedly watchdog-crashed the target app (Zalo "treo logo
        // → văng"; FRONTBOARD / SIGTRAP with ChangeInfoIosMG in the stack), even
        // after moving it to a background queue — and RRS restore keeps re-dropping
        // stale restore_*.flag files from the tar, so it re-triggered every launch.
        // Reverting to the proven-stable 4.0.x/4.1.0 behavior: NO keychain capture
        // or replay. RRS restore falls back to Zalo's server re-sync (slower, but
        // it NEVER crashes). ci_dumpKeychain / ci_restoreKeychainIfFlagged remain
        // defined but are intentionally NOT wired here.
        (void)&ci_dumpKeychain; (void)&ci_restoreKeychainIfFlagged;   // silence unused
        (void)&tw_deviceMGHash; (void)&tw_sigOK;                       // (device-bind reverted)

        // RestartTarget: app sends this after GPS sync-with-proxy to flush Safari's
        // cached location. Safari / WebContent calls exit(0) so next launch reads
        // the freshly-written coordinates. Other processes ignore it.
        {
            const char *pn = getprogname();
            BOOL isSafari = (pn && (strcmp(pn, "MobileSafari") == 0 ||
                                    strcmp(pn, "SafariViewService") == 0 ||
                                    strcmp(pn, "com.apple.WebKit.WebContent") == 0 ||
                                    strstr(pn, "WebContent") != NULL));
            if (isSafari) {
                int t3 = 0;
                notify_register_dispatch("com.changeinfoios/RestartTarget", &t3,
                    dispatch_get_main_queue(), ^(int __unused x) {
                        dbglog("RestartTarget %s → exit(0)\n", g_procname);
                        exit(0);
                    });
                dbglog("ctor %s registered RestartTarget handler\n", g_procname);
            }
        }

        if (ci_dbgEnabled()) {
            NSString *marker = @"/var/jb/etc/changeinfoios/v3_mg_loaded.txt";
            NSString *exec = [[NSProcessInfo processInfo] processName] ?: @"?";
            NSString *body = [NSString stringWithFormat:@"%@ %@\n", exec, [NSDate date]];
            FILE *f = fopen([marker UTF8String], "a");
            if (f) { fputs([body UTF8String], f); fclose(f); }
        }

        // v4.1.8: ONE-SHOT device reset (replaces the old per-launch autoWipe that
        // wiped keychain + UserDefaults + WKWebView on EVERY Zalo launch). That
        // per-launch wipe was why no account ever became a stable trusted device
        // and why an ADManager .adbk restore always showed "thiết bị mới". The wipe
        // now fires at most ONCE per Change Device; every other launch (and every
        // .adbk restore) is a no-op so the account keeps its identity.
        ci_runOneShotIfDue();

        dbglog("ctor %s done\n", g_procname);
    }
}
