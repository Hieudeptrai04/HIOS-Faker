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
#import <sys/utsname.h>
#import <sys/stat.h>
#import <sys/attr.h>
#import <fcntl.h>
#import <dirent.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <errno.h>
#import <math.h>
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
// LAYER 21 (virtual camera): AVFoundation gives AVCaptureVideoDataOutput +
// AVAssetReader; CoreMedia/CoreVideo the CMSampleBuffer/CVPixelBuffer types;
// CoreImage the scale+format-convert render; os/lock the feeder mutex.
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <os/lock.h>
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
// Roothide JB root prefix. On rootless (Dopamine 2) dlsym("rootdir") returns
// NULL and we fall back to "/var/jb". On roothide the bootstrap exposes
// rootdir() which fills a buffer with the real, randomized JB root path.
static const char *ci_rh_prefix(void) {
    static char buf[512] = {0};
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
        typedef void (*rootdir_fn_t)(char *, size_t);
        rootdir_fn_t fn = (rootdir_fn_t)(uintptr_t)dlsym(RTLD_DEFAULT, "rootdir");
        if (fn) fn(buf, sizeof(buf) - 1);
        if (!buf[0]) strlcpy(buf, "/var/jb", sizeof(buf));
        // strip trailing slash
        size_t n = strlen(buf);
        while (n > 0 && buf[n - 1] == '/') buf[--n] = '\0';
    });
    return buf;
}

static char kDbgPath[512] = "";

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
    if (g_dbgOn < 0) {
        // P0-2: .debug.off has the HIGHEST priority — if present, logging is OFF
        // even when .debug exists. Release ships neither, so the default is OFF.
        char ci_dbg_flag[512], ci_dbg_off[512];
        snprintf(ci_dbg_flag, sizeof(ci_dbg_flag), "%s/etc/changeinfoios/.debug",     ci_rh_prefix());
        snprintf(ci_dbg_off,  sizeof(ci_dbg_off),  "%s/etc/changeinfoios/.debug.off", ci_rh_prefix());
        int on = (access(ci_dbg_flag, F_OK) == 0);
        if (on && access(ci_dbg_off, F_OK) == 0) on = 0;
        g_dbgOn = on ? 1 : 0;
    }
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
static NSString *kConfigPath = nil; // initialized in %ctor via ci_rh_prefix()
static NSString *const kReloadNote  = @"com.changeinfoios.v3/ReloadConfig";
static NSString *const kLegacyNote  = @"com.changeinfoios/ReloadConfig";
static NSString *const kAppNote     = @"com.changeinfoios/ReloadPrefs"; // app sends this

// Reload notifications race with hook reads on background queues. Keep the
// ARC strong pointer and its gates under one lock, then return a retained
// snapshot so an old dictionary cannot be released under a reader.
static NSDictionary *g_config = nil;
static dispatch_once_t g_loadOnce;
static os_unfair_lock g_cfgLock = OS_UNFAIR_LOCK_INIT;
// Hide-JB stays independent of the license gate. Once this dylib is injected,
// exposing rootless paths merely because a token expired is inconsistent.
static volatile int g_hideJBOn = 1;

// Narrow exemption for this tweak's own config/restore reads. The app itself
// must not see /var/jb/etc/changeinfoios through the hooked filesystem APIs.
static __thread int g_ciInternalFS = 0;
class CIInternalFSGuard {
public:
    CIInternalFSGuard()  { g_ciInternalFS++; }
    ~CIInternalFSGuard() { g_ciInternalFS--; }
private:
    CIInternalFSGuard(const CIInternalFSGuard &);
    CIInternalFSGuard &operator=(const CIInternalFSGuard &);
};

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
static int g_targetOK = 0;
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

static int computeLicOKForConfig(NSDictionary *config) {
    id tv = config[@"_ci_lic_tok"];
    if (![tv isKindOfClass:[NSString class]]) return 0;
    NSString *tok = (NSString *)tv;
    NSRange bar = [tok rangeOfString:@"|"];
    if (bar.location == NSNotFound) return 0;
    NSString *es  = [tok substringToIndex:bar.location];
    NSString *sig = [tok substringFromIndex:bar.location + 1];
    if (!es.length || !sig.length) return 0;
    if ([es longLongValue] <= (long long)time(NULL)) return 0;     // expired
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
    return strcmp(hex, [sig UTF8String]) == 0 ? 1 : 0;
}

// The static substrate filter is a superset. targetBundles is the operation's
// actual allowlist, preventing a Viber profile from reaching an unselected
// Zalo process (and vice versa). Extensions inherit their parent bundle target.
static int configTargetsCurrentProcess(NSDictionary *config) {
    id raw = config[@"targetBundles"];
    if (![raw isKindOfClass:[NSArray class]] || [(NSArray *)raw count] == 0) return 0;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid.length) return 0;
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:[NSString class]] || ![(NSString *)item length]) continue;
        NSString *target = (NSString *)item;
        if ([bid isEqualToString:target] ||
            [bid hasPrefix:[target stringByAppendingString:@"."]]) return 1;
        if ([bid isEqualToString:@"com.apple.WebKit.WebContent"] &&
            [target isEqualToString:@"com.apple.mobilesafari"]) return 1;
    }
    return 0;
}

static NSString *boardConfigForProductType(NSString *pt) {
    static NSDictionary *m = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"iPhone8,1":@"N71AP", @"iPhone8,2":@"N66AP", @"iPhone8,4":@"N69AP",
            @"iPhone9,1":@"D10AP", @"iPhone9,2":@"D11AP",
            @"iPhone10,1":@"D20AP", @"iPhone10,2":@"D21AP", @"iPhone10,3":@"D22AP",
            @"iPhone10,6":@"D221AP", @"iPhone11,2":@"D321AP", @"iPhone11,6":@"D331pAP",
            @"iPhone11,8":@"N841AP", @"iPhone12,1":@"N104AP", @"iPhone12,3":@"D421AP",
            @"iPhone12,5":@"D431AP", @"iPhone12,8":@"D79AP", @"iPhone13,1":@"D52gAP",
            @"iPhone13,2":@"D53gAP", @"iPhone13,3":@"D53pAP", @"iPhone13,4":@"D54pAP",
        };
    });
    return pt.length ? m[pt] : nil;
}

static NSDictionary *ci_cfprefsConfig(void) {
    CFStringRef appID = CFSTR("com.changeinfoios");
    CFPreferencesAppSynchronize(appID);
    CFArrayRef keys = CFPreferencesCopyKeyList(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) return nil;
    CFDictionaryRef vals = CFPreferencesCopyMultiple(keys, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(keys);
    if (!vals) return nil;
    return (__bridge_transfer NSDictionary *)vals;
}

static NSDictionary *ci_cfprefsSharedConfig(void) {
    CFStringRef appID = CFSTR("com.changeinfoios.shared");
    CFPreferencesAppSynchronize(appID);
    CFArrayRef keys = CFPreferencesCopyKeyList(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) return nil;
    CFDictionaryRef vals = CFPreferencesCopyMultiple(keys, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(keys);
    if (!vals) return nil;
    return (__bridge_transfer NSDictionary *)vals;
}

static NSString *ci_findHIOSAppContainer(void) {
    static NSString *cached = nil;
    static dispatch_once_t tok;
    dispatch_once(&tok, ^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        Class LSProxy = NSClassFromString(@"LSApplicationProxy");
        SEL proxySel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (LSProxy && [LSProxy respondsToSelector:proxySel]) {
            id proxy = [LSProxy performSelector:proxySel withObject:@"com.changeinfoios.v3.app"];
            SEL dcSel = NSSelectorFromString(@"dataContainerURL");
            if ([proxy respondsToSelector:dcSel]) {
                NSURL *url = [proxy performSelector:dcSel];
                if ([url isKindOfClass:[NSURL class]] && [(NSURL *)url path].length)
                    cached = [[(NSURL *)url path] copy];
            }
        }
#pragma clang diagnostic pop
        if (!cached) {
            NSString *root = @"/var/mobile/Containers/Data/Application";
            NSArray *uuids = [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:root error:nil];
            for (NSString *uuid in uuids) {
                NSString *full = [root stringByAppendingPathComponent:uuid];
                NSString *meta = [full stringByAppendingPathComponent:
                    @".com.apple.mobile_container_manager.metadata.plist"];
                NSDictionary *md = [NSDictionary dictionaryWithContentsOfFile:meta];
                if ([md[@"MCMMetadataIdentifier"] isEqualToString:@"com.changeinfoios.v3.app"]) {
                    cached = [full copy];
                    break;
                }
            }
        }
        NSLog(@"[ChangeInfoIos-MG] HIOS container: %@", cached ?: @"(not found)");
    });
    return cached;
}

static long long ci_extractSaveTs(NSDictionary *d) {
    id v = d[@"_ci_save_ts"];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v longLongValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v longLongValue];
    return 0;
}

static const char *g_lastSrc = "none";

static void reloadConfig(void) {
    CIInternalFSGuard fsGuard;
    const char *src = "none";
    NSDictionary *best = nil;
    long long bestTs = 0;

    struct { NSDictionary *d; const char *name; } candidates[8];
    int n = 0;

    NSDictionary *d1 = ci_cfprefsConfig();
    if (d1) candidates[n++] = (typeof(candidates[0])){d1, "CFPreferences"};
    dbglog("reload.d1 CFPrefs keys=%ld ts=%lld pt=%s\n",
           d1 ? (long)d1.count : -1, ci_extractSaveTs(d1),
           d1[@"ProductType"] ? [d1[@"ProductType"] UTF8String] : "(nil)");

    NSDictionary *d2 = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    if (d2) candidates[n++] = (typeof(candidates[0])){d2, "kConfigPath"};
    dbglog("reload.d2 kConfigPath keys=%ld ts=%lld pt=%s path=%s\n",
           d2 ? (long)d2.count : -1, ci_extractSaveTs(d2),
           d2[@"ProductType"] ? [d2[@"ProductType"] UTF8String] : "(nil)",
           [kConfigPath UTF8String]);

    NSString *inContainer = [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Preferences/com.changeinfoios.plist"];
    NSDictionary *d3 = [NSDictionary dictionaryWithContentsOfFile:inContainer];
    if (d3) candidates[n++] = (typeof(candidates[0])){d3, "in-container"};
    dbglog("reload.d3 inContainer keys=%ld ts=%lld\n",
           d3 ? (long)d3.count : -1, ci_extractSaveTs(d3));

    NSDictionary *d4 = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.changeinfoios.plist"];
    if (d4) candidates[n++] = (typeof(candidates[0])){d4, "direct-/var/mobile"};
    dbglog("reload.d4 /var/mobile keys=%ld ts=%lld\n",
           d4 ? (long)d4.count : -1, ci_extractSaveTs(d4));

    NSDictionary *d5 = [NSDictionary dictionaryWithContentsOfFile:
        @"/tmp/com.changeinfoios.config.plist"];
    if (d5) candidates[n++] = (typeof(candidates[0])){d5, "/tmp-fallback"};
    dbglog("reload.d5 /tmp keys=%ld ts=%lld\n",
           d5 ? (long)d5.count : -1, ci_extractSaveTs(d5));

    NSDictionary *d6 = ci_cfprefsSharedConfig();
    if (d6) candidates[n++] = (typeof(candidates[0])){d6, "CFPrefs-shared"};
    dbglog("reload.d6 CFPrefs-shared keys=%ld ts=%lld\n",
           d6 ? (long)d6.count : -1, ci_extractSaveTs(d6));

    NSString *hiosContainer = ci_findHIOSAppContainer();
    dbglog("reload hiosContainer=%s\n", hiosContainer ? [hiosContainer UTF8String] : "(nil)");
    if (hiosContainer) {
        NSDictionary *d7 = [NSDictionary dictionaryWithContentsOfFile:
            [hiosContainer stringByAppendingPathComponent:@"Documents/ci_config_mirror.plist"]];
        if (d7) candidates[n++] = (typeof(candidates[0])){d7, "hios-mirror"};
        dbglog("reload.d7 hios-mirror keys=%ld ts=%lld\n",
               d7 ? (long)d7.count : -1, ci_extractSaveTs(d7));
        NSDictionary *d8 = [NSDictionary dictionaryWithContentsOfFile:
            [hiosContainer stringByAppendingPathComponent:
                @"Library/Preferences/com.changeinfoios.plist"]];
        if (d8) candidates[n++] = (typeof(candidates[0])){d8, "hios-prefs"};
        dbglog("reload.d8 hios-prefs keys=%ld ts=%lld\n",
               d8 ? (long)d8.count : -1, ci_extractSaveTs(d8));
    }

    for (int i = 0; i < n; i++) {
        long long ts = ci_extractSaveTs(candidates[i].d);
        if (!best || ts > bestTs) {
            best = candidates[i].d;
            bestTs = ts;
            src = candidates[i].name;
        }
    }
    dbglog("reload.WINNER src=%s ts=%lld n=%d\n", src, bestTs, n);

    NSDictionary *d = best ?: @{};
    g_lastSrc = src;
    NSString *pt = [d[@"ProductType"] isKindOfClass:[NSString class]] ? d[@"ProductType"] : nil;
    NSString *board = boardConfigForProductType(pt);
    if (board.length) {
        NSMutableDictionary *normalized = [d mutableCopy];
        id hm = normalized[@"HardwareModel"];
        if (![hm isKindOfClass:[NSString class]] || ![(NSString *)hm length] || [hm isEqual:pt]) {
            normalized[@"HardwareModel"] = board;
            normalized[@"HWModelStr"] = board;
            normalized[@"hw_model"] = board;
        }
        id ioBoard = normalized[@"IOBoardId"];
        if (![ioBoard isKindOfClass:[NSString class]] || ![(NSString *)ioBoard length] || [ioBoard isEqual:pt])
            normalized[@"IOBoardId"] = board;
        d = [normalized copy];
    }
    int licOK = computeLicOKForConfig(d);
    int targetOK = configTargetsCurrentProcess(d);
    id hideValue = d[@"hideJailbreak"];
    int hideJB = [hideValue respondsToSelector:@selector(boolValue)] ? [hideValue boolValue] : 1;
    os_unfair_lock_lock(&g_cfgLock);
    g_config = d;
    g_licOK = licOK;
    g_targetOK = targetOK;
    g_hideJBOn = hideJB;
    os_unfair_lock_unlock(&g_cfgLock);

    NSLog(@"[ChangeInfoIos-MG] config: src=%s keys=%lu pt=%@ ts=%lld lic=%d target=%d",
          src, (unsigned long)d.count, pt ?: @"(nil)", bestTs, licOK, targetOK);
}

static inline NSDictionary *cfg(void) {
    dispatch_once(&g_loadOnce, ^{ reloadConfig(); });
    os_unfair_lock_lock(&g_cfgLock);
    NSDictionary *snapshot = (g_licOK && g_targetOK) ? g_config : @{};
    os_unfair_lock_unlock(&g_cfgLock);
    return snapshot;
}

static inline id getConfig(NSString *k) { return cfg()[k]; }
static inline NSString *getConfigStr(NSString *k) {
    id v = cfg()[k];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return nil;
}
// P0-5: coordinate/double reader that accepts BOTH NSNumber and NSString and
// validates finiteness. The proxy/GPS-sync path once wrote lat/lon as NSNumber,
// which getConfigStr ignored → the location hook saw "no coordinate" and leaked
// the REAL device GPS. Returns NO (leaving *out untouched) on missing/non-finite.
static inline BOOL ci_configDouble(NSString *k, double *out) {
    id v = cfg()[k];
    double d;
    if ([v isKindOfClass:[NSNumber class]]) d = [(NSNumber *)v doubleValue];
    else if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) d = [(NSString *)v doubleValue];
    else return NO;
    if (!isfinite(d)) return NO;
    if (out) *out = d;
    return YES;
}
// A usable fake GPS fix exists only when both coords are present AND in range.
static inline BOOL ci_hasFakeCoord(void) {
    double la, lo;
    return ci_configDouble(@"latitude", &la) && ci_configDouble(@"longitude", &lo)
        && fabs(la) <= 90.0 && fabs(lo) <= 180.0;
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
            @"WiFiAddress":@"WiFiAddress", @"WifiAddress":@"WiFiAddress", @"BluetoothAddress":@"BluetoothAddress",
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
            // --- Base64/hashed MG key forms (anti-spoof bypass) ---
            // libMobileGestalt identifies keys globally by these base64 hashes;
            // apps (Zalo) query the hash form directly to dodge a plaintext-only
            // map. Hashes verified against this device's MG cache (hash -> value).
            @"0+nc/Udy4WNG8S+Q7a/s1A":@"ProductType",
            @"h9jDsbgj7xIVeIQ8S3/X3Q":@"ProductType",     // duplicate ProductType hash
            @"Z/dqyWS6OZTRy10UcmUAhw":@"MarketingName",
            @"bbtR9jQx50Fv5Af/affNtA":@"MarketingName",    // duplicate MarketingName hash
            @"h63QSdBCiT/z0WU6rdQv6Q":@"RegionCode",
            @"zHeENZu+wbg7PUprwNwBWg":@"RegionInfo",
            @"LeSRsiLoJCMhjn6nd6GWbQ":@"FirmwareVersion",
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
    BOOL stringSpoof = NO;   // 4.3.41: only string device keys need the caller-check
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
        if (s) { result = (__bridge_retained CFTypeRef)s; stringSpoof = YES; }
    }
    g_inMG = 0;

    if (!result) return mgOrigCached(property);

    // 4.3.41b: off the main thread, hand back the spoof directly and never touch
    // dladdr. The std::terminate this caller-check guards against is a MAIN-THREAD
    // UIKit path (_UIDeviceNativeUserInterfaceIdiomIgnoringClassic loading a device
    // plist), so off-main there is nothing to guard. This closes the last launch
    // deadlock vector: a spoofed STRING key (ProductType/SerialNumber/UniqueDeviceID
    // /…) queried on a background thread during the +[FIRApp configure] dlopen
    // window would otherwise run dladdr -> dyld loader lock -> wedge, exactly like
    // the CoreTelephony hasBaseband thread did. Main-thread callers keep the full
    // guard below (main-thread dladdr is a recursive lock acquire, never blocks).
    if (!pthread_main_np()) return result;

    // We have a spoof value → skip UIKit/system-internal callers so a fake device
    // key can't crash them. The std::terminate this guards against is specific to a
    // fake STRING key: UIKit's _UIDeviceNativeUserInterfaceIdiomIgnoringClassic reads
    // a spoofed ProductType, does initWithContentsOfFile: on a device plist that
    // doesn't exist → throws → SIGABRT. A fake CFBoolean/CFNumber (the capability
    // keys HasFaceID / HasCellularConnectivity / hasBaseband / HasTouchID …, which
    // UIKit and CoreTelephony query hundreds of times during scene-create) never
    // triggers a plist lookup and is safe to hand back fake. So only STRING spoofs
    // pay the dladdr caller-check.
    //
    // 4.3.41: this is what removes the launch-time background-thread dladdr that
    // wedged on the dyld lock (T2 = CoreTelephony hasBaseband → MGCopyAnswer): a
    // boolean/int key now returns without ever touching dladdr. dladdr still takes
    // the dyld loader lock, so keeping it off the hot capability path is what makes
    // the launch dyld-lock-contention-safe.
    if (stringSpoof) {
        Dl_info _di; _di.dli_fname = NULL;
        dladdr(__builtin_return_address(0), &_di);
        if (_di.dli_fname &&
            (strncmp(_di.dli_fname, "/System/Library/", 16) == 0 ||
             strncmp(_di.dli_fname, "/usr/lib/", 9) == 0 ||
             strncmp(_di.dli_fname, "/var/jb/usr/lib/", 16) == 0 ||
             (strncmp(_di.dli_fname, ci_rh_prefix(), strlen(ci_rh_prefix())) == 0 &&
              _di.dli_fname[strlen(ci_rh_prefix())] == '/'))) {
            CFRelease(result);
            return mgOrigCached(property);
        }
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
typedef int (*uname_t)(struct utsname *);
static sysctlbyname_t orig_sysctlbyname = NULL;
static sysctl_raw_t   orig_sysctl_raw   = NULL;
static getifaddrs_t   orig_getifaddrs   = NULL;
static gethostname_t  orig_gethostname  = NULL;
static uname_t        orig_uname        = NULL;

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
            // ZCH-07 FIX: kern.osrelease is the DARWIN kernel release
            // ("23.5.0"), NOT the iOS marketing version. Mapping it to
            // systemVersion emitted a malformed "17.5" AND contradicted
            // uname().release (left real at hooked_uname) — two different
            // answers for the same kernel version. Leave osrelease unmapped
            // so it passes through the real Darwin string, consistent with
            // uname. (kern.osproductversion below is the correct iOS-version
            // key and stays mapped to systemVersion.)
            @"kern.osproductversion": @"systemVersion",
            @"kern.boottime":         @"kern_boottime",
            @"kern.uuid":             @"IOPlatformUUID",
            @"kern.bootsessionuuid":  @"bootSessionUUID",
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
    if (!oldlenp) { errno = EINVAL; return -1; }
    size_t avail = *oldlenp;
    if (avail < need) {
        // P1-2: never index oldp[avail-1] when avail==0 (out-of-bounds write).
        if (avail > 0) {
            memcpy(oldp, s, avail - 1);   // truncate, leave room for NUL
            ((char*)oldp)[avail - 1] = 0;
        }
        *oldlenp = need;                  // report required size
        errno = ENOMEM;
        return -1;
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

// uname() → struct utsname. .machine leaks the REAL model ("iPhone10,3") at the
// BSD layer, bypassing every MobileGestalt/UIDevice spoof — Zalo references
// uname 5× (proven on-device). Rewrite .machine (and .nodename to match the
// gethostname spoof) from config; leave sysname/release/version untouched (the
// Darwin kernel string is identical for the real running iOS, and remapping it
// to a claimed iOS is error-prone). g_inUname guards Foundation re-entry.
__thread int g_inUname = 0;
static int hooked_uname(struct utsname *u) {
    if (!orig_uname) return -1;              // never call uname() by name → recursion
    int rc = orig_uname(u);
    if (rc != 0 || !u || g_inUname) return rc;
    g_inUname = 1;
    NSString *m = getConfigStr(@"hw_machine");
    if (m.length) strlcpy(u->machine, [m UTF8String], sizeof(u->machine));
    NSString *nn = getConfigStr(@"deviceName");
    if (nn.length) strlcpy(u->nodename, [nn UTF8String], sizeof(u->nodename));
    dbglog("uname %s -> machine=%s node=%s\n", g_procname, u->machine, u->nodename);
    g_inUname = 0;
    return rc;
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

// 4.3.30: set to 1 by ci_runOneShotIfDue ONLY when it actually wipes for a fresh
// register (a real Change Device this session) — NOT by the restore path. Gates the
// keychain device-id block below so restores/normal launches are untouched.
static int g_freshRegisterWipe = 0;

// RE-ENABLED 4.3.30, but GATED to the fresh-register window. WHY re-enabled:
// live keychain-2.db proved the one-shot SecItemDelete does NOT actually remove
// Zalo's device-id items (12 shared + 2 ext group SURVIVE — cdat unchanged, from
// both the in-app tweak AND the host). So on a fresh register the OLD device id
// (kZAIDForDevice etc.) is still readable → every account on this phone shares it
// → VNG correlates → ban. Since we cannot DELETE the item, we make Zalo NOT SEE it
// during fresh register: return errSecItemNotFound for the device-id accounts so
// Zalo generates + registers with a brand-new id (uncorrelated). This runs ONLY
// while g_freshRegisterWipe==1 (a real Change Device this launch); on RRS restore
// and every normal launch it is 0 → pass through, so a kept/restored account reads
// its stable device id and stays a trusted device (the reason the old always-on
// block was disabled). Restore path never sets g_freshRegisterWipe.
static BOOL isZaloFingerprintQuery(CFDictionaryRef query) {
    if (!g_freshRegisterWipe || !query) return NO;
    CFStringRef acc = (CFStringRef)CFDictionaryGetValue(query, kSecAttrAccount);
    if (!acc || CFGetTypeID(acc) != CFStringGetTypeID()) return NO;
    char ab[80]; ab[0] = 0;
    if (!CFStringGetCString(acc, ab, sizeof(ab), kCFStringEncodingUTF8) || !ab[0]) return NO;
    for (int i = 0; kZaloFpAccounts[i]; i++)
        if (strcmp(ab, kZaloFpAccounts[i]) == 0) return YES;
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
    // kSecAttrSynchronizableAny matches BOTH local and iCloud-Keychain
    // (synchronizable) items. Without it SecItemDelete only removes non-sync
    // items, so a device-id stored as a synchronizable keychain entry survived
    // the wipe AND re-synced from iCloud even after an app delete — that is why a
    // device with iCloud Keychain ON (e.g. a heavily-reused iPhone) stayed
    // "detected" while a device with it OFF worked.
    for (id cls in classes) {
        // App's default access group (no group pin → all default-group matches).
        if (SecItemDelete((__bridge CFDictionaryRef)@{
                (__bridge id)kSecClass: cls,
                (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny }) == errSecSuccess) n++;
        // Explicit shared access group(s).
        for (NSString *g in groups) {
            NSDictionary *q = @{ (__bridge id)kSecClass: cls,
                                 (__bridge id)kSecAttrAccessGroup: g,
                                 (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny };
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
    if ([v isKindOfClass:[NSString class]] || [v isKindOfClass:[NSNumber class]])
        return v;
    // Drop anything NOT plist-serializable (opaque CFTypeRef / SecAccessControlRef
    // etc.). Returning it verbatim made NSPropertyListSerialization fail wholesale
    // → a 0-byte hios_keychain.plist even when 7 items were read. The dropped attrs
    // are never the login-critical ones (acct/svce/agrp are data/strings, v_Data is
    // wrapped), so re-add still works.
    return nil;
}
static id ci_kcUnwrap(id v) {
    if ([v isKindOfClass:[NSDictionary class]] && ((NSDictionary *)v)[@"__b"]) {
        NSData *d = [[NSData alloc] initWithBase64EncodedString:((NSDictionary *)v)[@"__b"] options:0];
        return d ?: v;
    }
    return v;
}

static void ci_dumpKeychain(void) {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hios_keychain.plist"];
    // Publish only after a complete in-memory serialization. Leaving an older
    // mtime on failure is intentional: the host freshness check rejects it, while
    // a concurrent complete host-side dump is never deleted by this writer.
    if (!orig_SecItemCopyMatching) {
        dbglog("Keychain.dump.INVALID %s copy-matching-unavailable\n", g_procname);
        return;   // origs not installed yet
    }
    NSArray *classes = @[ (__bridge id)kSecClassGenericPassword,
                          (__bridge id)kSecClassInternetPassword,
                          (__bridge id)kSecClassCertificate,
                          (__bridge id)kSecClassKey,
                          (__bridge id)kSecClassIdentity ];
    NSMutableArray *out = [NSMutableArray array];
    BOOL incomplete = NO;
    for (id cls in classes) {
        // Step 1: ENUMERATE attributes only (NO bulk data), INCLUDING iCloud-
        // synchronizable items. The old single "attributes+data+MatchLimitAll"
        // query returned 0 for Viber for two reasons: (a) that combo fails
        // wholesale (errSecItemNotFound / InteractionNotAllowed) when ANY item's
        // data can't be bulk-returned, and (b) the default query (no
        // kSecAttrSynchronizable) SKIPS synchronizable items — exactly where
        // Viber keeps the key that decrypts SecureStorage.data. So a Viber dump
        // came out empty and cross-device restore had no key → stayed logged out.
        // Enumerate here; fetch each secret one-by-one below.
        NSDictionary *enumQ = @{ (__bridge id)kSecClass:              cls,
                                 (__bridge id)kSecMatchLimit:         (__bridge id)kSecMatchLimitAll,
                                 (__bridge id)kSecReturnAttributes:   (__bridge id)kCFBooleanTrue,
                                 (__bridge id)kSecReturnPersistentRef: (__bridge id)kCFBooleanTrue,
                                 (__bridge id)kSecAttrSynchronizable: (__bridge id)kSecAttrSynchronizableAny };
        CFTypeRef res = NULL;
        // orig_ bypasses our own blocking hook so ALL items are captured.
        OSStatus st = orig_SecItemCopyMatching((__bridge CFDictionaryRef)enumQ, &res);
        NSArray *arr = @[];
        if (st == errSecSuccess && res) {
            if (CFGetTypeID(res) == CFArrayGetTypeID()) {
                arr = (__bridge NSArray *)res;
            } else if (CFGetTypeID(res) == CFDictionaryGetTypeID()) {
                arr = @[ (__bridge id)res ];
            } else {
                incomplete = YES;
            }
        } else if (st != errSecItemNotFound) {
            // Locked keychain / entitlement / interaction failures must abort the
            // whole dump. Publishing the other classes would create a partial RRS.
            incomplete = YES;
        }
        int got = 0;
        for (id itd in arr) {
            if (![itd isKindOfClass:[NSDictionary class]]) {
                incomplete = YES;
                continue;
            }
            NSDictionary *it = (NSDictionary *)itd;
            NSMutableDictionary *ser = [NSMutableDictionary dictionary];
            ser[@"class"] = cls;   // SecItemCopyMatching doesn't return the class
            for (NSString *k in it) {
                // v_PersistentRef is only for re-fetching the data below; it is
                // device-scoped and not a valid add attribute — never serialize it.
                if ([k isEqualToString:@"v_PersistentRef"] || [k isEqualToString:@"persistref"]) continue;
                id v = it[k];
                if ([v isKindOfClass:[NSDate class]]) continue;   // cdat/mdat read-only
                id w = ci_kcWrap(v);
                if (w) ser[k] = w;
            }
            // Step 2: fetch THIS item's secret DATA by its PERSISTENT REF. The ref
            // targets the exact item even though Viber stores binary acct/svce
            // (which made acct/svce matching unreliable), and per-item read avoids
            // the bulk-ReturnData failure. None of Viber's items are biometric
            // (all ck/cku/aku), so this never prompts / never hangs.
            id pref = it[@"v_PersistentRef"] ?: it[@"persistref"];
            if (pref) {
                NSDictionary *dq = @{ (__bridge id)kSecValuePersistentRef: pref,
                                      (__bridge id)kSecReturnData:          (__bridge id)kCFBooleanTrue };
                CFTypeRef dref = NULL;
                OSStatus dst = orig_SecItemCopyMatching((__bridge CFDictionaryRef)dq, &dref);
                if (dst == errSecSuccess && dref && CFGetTypeID(dref) == CFDataGetTypeID())
                    ser[@"v_Data"] = ci_kcWrap((__bridge NSData *)dref);
                if (dref) CFRelease(dref);
            }
            BOOL passwordItem = [cls isEqual:(__bridge id)kSecClassGenericPassword] ||
                                [cls isEqual:(__bridge id)kSecClassInternetPassword];
            if (passwordItem && !ser[@"v_Data"]) {
                incomplete = YES;
                dbglog("Keychain.dump.INVALID %s class=%s missing-data\n", g_procname,
                       [[cls description] UTF8String]);
                continue;
            }
            [out addObject:ser];
            got++;
        }
        if (res) CFRelease(res);
        dbglog("Keychain.dump.cls %s st=%d items=%d\n", g_procname, (int)st, got);
    }
    if (incomplete || out.count == 0) {
        dbglog("Keychain.dump.INVALID %s incomplete=%d items=%lu -> kept-stale\n",
               g_procname, (int)incomplete, (unsigned long)out.count);
        return;
    }
    NSError *serr = nil;
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:out
                        format:NSPropertyListXMLFormat_v1_0 options:0 error:&serr];
    BOOL wrote = (plist.length > 0) && [plist writeToFile:path atomically:YES];
    if (wrote) chmod([path fileSystemRepresentation], 0600);   // P0-2: keychain secret at rest, owner-only
    dbglog("Keychain.dump %s items=%lu serialized=%lu wrote=%d err=%s -> %s\n", g_procname,
           (unsigned long)out.count, (unsigned long)plist.length, (int)wrote,
           serr ? [[serr localizedDescription] UTF8String] : "-", [path UTF8String]);
}

// Defined below with the one-shot device-reset. The restore needs them to write the
// wipe's ack into the TARGET's OWN Documents (cross-device: that ack was previously
// written to the HIOS app's container, so the target's copy was missing and the
// one-shot wiped the login we just restored → the user had to import twice).
static NSString *ci_docPath(NSString *name);
static NSString *ci_readTrim(NSString *path);
static int g_wipeConsumed = 0;   // one-shot process guard; a flagged restore also sets it to keep the restored login

static void ci_restoreKeychainIfFlagged(void) {
    CIInternalFSGuard fsGuard;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid.length) return;
    NSString *shared = [NSString stringWithFormat:@"%s/etc/changeinfoios", ci_rh_prefix()];
    NSString *pFlag = [shared stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"restore_%@.flag", bid]];
    NSString *pDump = [shared stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"dump_%@.plist", bid]];
    NSString *lFlag = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hios_keychain_restore.flag"];
    NSString *lDump = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hios_keychain.plist"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dump = nil, *flag = nil;
    if ([fm fileExistsAtPath:pFlag] && [fm fileExistsAtPath:pDump]) {
        dump = pDump; flag = pFlag;   // primary
    } else if ([fm fileExistsAtPath:lFlag] && [fm fileExistsAtPath:lDump]) {
        dump = lDump; flag = lFlag;   // legacy
    }
    if (!dump) return;   // nothing flagged for this app → no-op
    BOOL primaryTransaction = [flag isEqualToString:pFlag] && [dump isEqualToString:pDump];

    // Use a host-minted transaction token plus dump identity for the run-once
    // guard. NSUserDefaults is inside the restored Data container, so a plain
    // boolean/mtime marker can travel from the SOURCE phone and falsely suppress
    // the keychain replay on the DESTINATION phone.
    NSDictionary *dumpAttrs = [fm attributesOfItemAtPath:dump error:nil];
    NSDate *mt = [dumpAttrs fileModificationDate];
    double mtime = mt ? [mt timeIntervalSince1970] : 0;
    unsigned long long dumpSize = [dumpAttrs[NSFileSize] unsignedLongLongValue];
    NSString *flagToken = ci_readTrim(flag);
    NSString *txnKey = flagToken.length
        ? [NSString stringWithFormat:@"%@|%.6f|%llu", flagToken, mtime, dumpSize]
        : nil;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // Suppress the one-shot device-reset (ci_runOneShotIfDue, later in this same
    // %ctor) for this just-restored container. On a CROSS-DEVICE target that wipe was
    // DUE — it neutralises itself via .ci_gen_ack in THIS process's own Documents, but
    // the restore only ever wrote that ack into the HIOS app's container, so Viber's
    // copy was missing → the wipe erased the keychain + app-group we just restored,
    // and the login only "stuck" on the SECOND import (that first wipe wrote the ack).
    // A restore flag means the user wants THIS login kept: ack the current generation
    // HERE, in the target's own Documents, BEFORE the wipe reads it, and guard this
    // launch. A later real Change Device rewrites .ci_gen, so the ack stops matching
    // and the wipe correctly fires again then.
    g_wipeConsumed = 1;
    NSString *currentGen = getConfigStr([@"wipe_gen_" stringByAppendingString:bid]);
    if (!currentGen.length) currentGen = getConfigStr(@"wipe_gen");
    NSString *storedGen = ci_readTrim(ci_docPath(@".ci_gen"));
    BOOL ackRequired = storedGen.length && currentGen.length &&
                       [storedGen isEqualToString:currentGen];
    BOOL ackOK = YES;
    if (ackRequired) {
        NSString *ackP = ci_docPath(@".ci_gen_ack");
        BOOL wrote = ackP && [currentGen writeToFile:ackP atomically:YES
                                            encoding:NSUTF8StringEncoding error:nil];
        NSString *check = ci_readTrim(ackP);
        ackOK = wrote && [check isEqualToString:currentGen];
    }

    // Check the marker only AFTER suppressing/verifying the one-shot. Returning
    // before this protection let a later launch wipe a successfully restored login.
    BOOL alreadyDone = txnKey.length &&
        [[ud stringForKey:@"_ci_kc_done_txn"] isEqualToString:txnKey];
    if (alreadyDone && ackOK) {
        [fm removeItemAtPath:lFlag error:nil];
        return;
    }

    // Apply SYNCHRONOUSLY here in %ctor — BEFORE the app's own code (main /
    // didFinishLaunching) reads its session. CROSS-DEVICE is the reason: the target
    // phone has NO residual keychain, so a delayed/background apply let the app read
    // SecureStorage.data with no matching key on its FIRST launch → it decided
    // "logged out" (and rewrote that state), so the user had to import the .rrs a
    // SECOND time to get it right. Viber's items are few (7) and non-biometric, so
    // this runs in well under a second — far below the ~20s FrontBoard launch
    // watchdog (the old "inline crashed" was a much bigger/blocking replay).
    // IMPORTANT: commit the run-once marker only AFTER every item was replayed.
    // Marking it first turned a transient SecItemAdd/parse failure into a permanent
    // false success: the first launch showed Login and refused to retry until the
    // user imported the exact same snapshot a second time.
    @autoreleasepool {
    NSData *data = [NSData dataWithContentsOfFile:dump];
    id items = data.length ? [NSPropertyListSerialization propertyListWithData:data
                                  options:0 format:NULL error:NULL] : nil;
    BOOL parsedOK = [items isKindOfClass:[NSArray class]];
    int total = parsedOK ? (int)[(NSArray *)items count] : 0;
    int applied = 0, failed = 0;
    OSStatus lastError = errSecSuccess;
    NSMutableArray<NSDictionary *> *prepared = [NSMutableArray array];
    if (!parsedOK) {
        failed = 1;
        lastError = errSecDecode;
    } else if (total == 0) {
        failed = 1;
        lastError = errSecItemNotFound;
    } else {
        for (id itd in (NSArray *)items) {
            if (![itd isKindOfClass:[NSDictionary class]]) {
                failed++;
                lastError = errSecParam;
                continue;
            }
            @autoreleasepool {
                NSMutableDictionary *add = [NSMutableDictionary dictionary];
                BOOL itemValid = YES;
                for (id rawKey in (NSDictionary *)itd) {
                    if (![rawKey isKindOfClass:[NSString class]]) {
                        itemValid = NO;
                        break;
                    }
                    NSString *k = (NSString *)rawKey;
                    if ([k isEqualToString:@"cdat"] || [k isEqualToString:@"mdat"]) continue;
                    id value = ci_kcUnwrap(((NSDictionary *)itd)[k]);
                    if (!value || !([value isKindOfClass:[NSString class]] ||
                                    [value isKindOfClass:[NSNumber class]] ||
                                    [value isKindOfClass:[NSData class]])) {
                        itemValid = NO;
                        break;
                    }
                    add[k] = value;
                }
                id itemClass = add[(__bridge id)kSecClass];
                BOOL knownClass = [itemClass isEqual:(__bridge id)kSecClassGenericPassword] ||
                                  [itemClass isEqual:(__bridge id)kSecClassInternetPassword] ||
                                  [itemClass isEqual:(__bridge id)kSecClassCertificate] ||
                                  [itemClass isEqual:(__bridge id)kSecClassKey] ||
                                  [itemClass isEqual:(__bridge id)kSecClassIdentity];
                if (!itemValid || !knownClass) {
                    failed++;
                    lastError = errSecParam;
                    continue;   // malformed entry; do not commit this transaction
                }
                BOOL passwordItem = [itemClass isEqual:(__bridge id)kSecClassGenericPassword] ||
                                    [itemClass isEqual:(__bridge id)kSecClassInternetPassword];
                if (passwordItem &&
                    ![add[(__bridge id)kSecValueData] isKindOfClass:[NSData class]]) {
                    // Metadata without v_Data cannot restore the session/decryption
                    // secret. Treat it as a failed transaction, never as success.
                    failed++;
                    lastError = errSecDecode;
                    continue;
                }
                [prepared addObject:[add copy]];
            }
        }
    }
    // Pass 2 mutates the keychain only after EVERY serialized item passed pass 1.
    // A malformed late entry can therefore never leave a half-applied login.
    BOOL inputOK = parsedOK && txnKey.length && total > 0 && failed == 0 &&
                   prepared.count == (NSUInteger)total;
    if (inputOK) {
        for (NSDictionary *preparedItem in prepared) {
            @autoreleasepool {
                NSMutableDictionary *add = [preparedItem mutableCopy];
                NSMutableDictionary *del = nil;
                if (add[@"acct"] || add[@"svce"] || add[@"srvr"] || add[@"atag"] || add[@"labl"]) {
                    del = [NSMutableDictionary dictionary];
                    for (NSString *dk in @[ @"class", @"acct", @"agrp", @"svce",
                                             @"srvr", @"ptcl", @"atyp", @"port",
                                             @"path", @"sdmn", @"atag", @"labl" ])
                        if (add[dk]) del[dk] = add[dk];
                    del[(__bridge id)kSecAttrSynchronizable] =
                        (__bridge id)kSecAttrSynchronizableAny;
                    SecItemDelete((__bridge CFDictionaryRef)del);
                }
                OSStatus st = orig_SecItemAdd ? orig_SecItemAdd((__bridge CFDictionaryRef)add, NULL)
                                              : SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                if (st != errSecSuccess) {
                    // One short in-process retry handles a transient keychain lock
                    // without letting the app observe a partial session.
                    usleep(50000);
                    if (del.count) SecItemDelete((__bridge CFDictionaryRef)del);
                    st = orig_SecItemAdd ? orig_SecItemAdd((__bridge CFDictionaryRef)add, NULL)
                                         : SecItemAdd((__bridge CFDictionaryRef)add, NULL);
                }
                if (st == errSecSuccess) {
                    applied++;
                } else {
                    // Never retry without agrp: that would put the credential in
                    // the wrong access group and create a false restore success.
                    failed++;
                    lastError = st;
                    break;
                }
            }
        }
    }
    BOOL keychainOK = inputOK && failed == 0 && applied == total;
    BOOL replayOK = keychainOK && ackOK;
    BOOL committed = NO;
    if (replayOK) {
        [ud removeObjectForKey:@"_ci_kc_retry_txn"];
        [ud setObject:txnKey forKey:@"_ci_kc_done_txn"];
        if (mtime > 0) [ud setDouble:mtime forKey:@"_ci_kc_done"];   // legacy diagnostic
        committed = [ud synchronize] &&
                    [[ud stringForKey:@"_ci_kc_done_txn"] isEqualToString:txnKey];
        if (committed) [fm removeItemAtPath:lFlag error:nil];
    } else if (keychainOK) {
        [ud removeObjectForKey:@"_ci_kc_retry_txn"];
        [ud synchronize];
    }
    dbglog("Keychain.restore(sync) %s input=%d keychain=%d ackRequired=%d ackOK=%d applied=%d/%d failed=%d last=%d committed=%d bid=%s\n",
           g_procname, (int)inputOK, (int)keychainOK, (int)ackRequired, (int)ackOK,
           applied, total, failed, (int)lastError, (int)committed, [bid UTF8String]);
    if (!keychainOK && primaryTransaction && txnKey.length &&
        ![[ud stringForKey:@"_ci_kc_retry_txn"] isEqualToString:txnKey]) {
        // Fail closed once so this first launch cannot rewrite restored databases
        // as logged-out after a partial add. The next launch retries this txn.
        [ud setObject:txnKey forKey:@"_ci_kc_retry_txn"];
        BOOL armed = [ud synchronize] &&
                     [[ud stringForKey:@"_ci_kc_retry_txn"] isEqualToString:txnKey];
        dbglog("Keychain.restore FAIL-CLOSED %s armed=%d err=%d applied=%d/%d\n",
               g_procname, (int)armed, (int)lastError, applied, total);
        if (armed) _exit(0);
    }
    } // @autoreleasepool
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
    NSString *pt = getConfigStr(@"ProductType");
    if ([pt hasPrefix:@"iPhone"]) return @"iPhone";
    NSString *v = getConfigStr(@"deviceModel");
    dbglog("UIDevice.model %s spoof=%c\n", g_procname, v?'Y':'N');
    return v ?: %orig;
}
- (NSString *)localizedModel {
    NSString *pt = getConfigStr(@"ProductType");
    if ([pt hasPrefix:@"iPhone"]) return @"iPhone";
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
    if (ci_hasFakeCoord()) return YES;
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
    if (ci_hasFakeCoord() && (real == 3 || real == 4)) return 3;
    return real;
}
- (int)authorizationStatus {
    int real = %orig;
    if (ci_hasFakeCoord() && (real == 3 || real == 4)) return 3;
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
    double la, lo;
    if (!ci_configDouble(@"latitude", &la) || !ci_configDouble(@"longitude", &lo) ||
        fabs(la) > 90.0 || fabs(lo) > 180.0) {   // P0-5: fail-closed, never leak real GPS
        %orig;
        return;
    }
    CLLocationCoordinate2D c = {la, lo};
    double alt = 15.0; ci_configDouble(@"altitude", &alt);
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
    double la, lo;
    if (!ci_configDouble(@"latitude", &la) || !ci_configDouble(@"longitude", &lo) ||
        fabs(la) > 90.0 || fabs(lo) > 180.0) return %orig;   // P0-5: fail-closed
    // Only hand out a fake fix when location is ACTUALLY authorized. A
    // notDetermined/denied app whose -location returns a real coordinate is an
    // impossible iOS state (no auth -> nil) that anti-fraud flags. [self
    // authorizationStatus] is our hooked value: the real status while not
    // granted, AuthorizedAlways(3) once granted. When not granted, fall through
    // to %orig (which is nil for an unauthorized app) → stays consistent.
    int st = (int)[self authorizationStatus];
    if (st != 3 && st != 4) return %orig;
    CLLocationCoordinate2D c = {la, lo};
    double alt = 15.0; ci_configDouble(@"altitude", &alt);
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
    // ZCH-10 R2 FIX: was unconditional YES — leaked a spoofed capability even
    // when the license gate is closed (cfg() empty) or no carrier is configured,
    // contradicting the fail-closed carrierName/MCC/MNC getters above. Gate it on
    // the same signal so licensed→spoof, unlicensed/no-carrier→real (%orig).
    return getConfigStr(@"carrierName") ? YES : %orig;
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
         // Canvas LSB noise — anti-fingerprint. ZJB-05/R3-01 FIX: the R2 version
         // XOR-mutated the SOURCE canvas each call; XOR is self-inverse so two
         // consecutive toDataURL() alternated noisy/original (A/B/A/B) — proven by
         // scratchpad/canvas_test.js (distinct=2). Now: perturb → serialize →
         // RESTORE the original pixel. Output is STABLE across repeated reads
         // (distinct=1) and the source canvas is unchanged after the call, while
         // still differing from the true canvas (anti-fingerprint preserved).
         "var _cn=(sw*131+sh*17+hc*7)&255;"
         "var _ot=HTMLCanvasElement.prototype.toDataURL;"
         "HTMLCanvasElement.prototype.toDataURL=function(){"
         "var c=this.getContext&&this.getContext('2d');"
         "if(c&&this.width>0&&this.height>0){"
         "try{var id=c.getImageData(0,0,1,1);"
         "var _o0=id.data[0];"
         "id.data[0]=(_o0^_cn)&255;c.putImageData(id,0,0);"
         "var _r=_ot.apply(this,arguments);"
         "id.data[0]=_o0;c.putImageData(id,0,0);"
         "return _r;}catch(e){}}"
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
    // ZJB-05 FIX: buildWKJSSpoof() ALWAYS returns a script (it falls back to
    // vi/VN + default dims), so the old `if(js)` injected a navigator/screen/
    // canvas/WebGL override into EVERY WKWebView even when there is no licensed
    // profile — a pure-downside active-tampering signal (overrides whose
    // Function.toString() leaks JS source, plus per-call canvas LSB noise) with
    // nothing to spoof. Only inject when a real profile is present (ProductType
    // is nil when the license gate is closed → cfg() is empty).
    if (getConfigStr(@"ProductType")) {
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
    }
    return v;
}
%end

// ============================================================
// LAYER 9: Jailbreak hiding — block common JB detection vectors.
// Hooks: stable libc/Foundation path probes, URL schemes, installed-app lookup,
// environment/fork probes and a consistent index-based dyld view.
// Our own config access uses a thread-local internal scope; the config directory
// is no longer exposed process-wide.
// ============================================================

// A path that media/camera tweaks (VCam) legitimately store user data at.
// These are NOT jailbreak-detection targets — anti-fraud SDKs probe app and
// binary paths (Cydia, apt, bash, substrate), never a user video file — so
// exempting them lets VCam read its source while real JB paths stay hidden.
// VCam (vcamrootless) uses /var/jb/var/mobile/Library/temp.mov and
// /var/jb/var/mobile/Library/vcam_is_mirrored_mark.
static BOOL isTweakDataPath(const char *path) {
    if (!path) return NO;
    // A substring/extension exemption was far too broad: a JB probe could simply
    // put "vcam" or ".mov" in its path. Allow only VCam's two known data files.
    // Paths are built dynamically so they track the roothide JB root.
    const char *pfx = ci_rh_prefix();
    char v1[512], v2[512], v3[512], v4[512];
    snprintf(v1, sizeof(v1), "%s/var/mobile/Library/temp.mov",             pfx);
    snprintf(v2, sizeof(v2), "%s/var/mobile/Library/vcam_is_mirrored_mark", pfx);
    snprintf(v3, sizeof(v3), "/private%s/var/mobile/Library/temp.mov",             pfx);
    snprintf(v4, sizeof(v4), "/private%s/var/mobile/Library/vcam_is_mirrored_mark", pfx);
    return (strcmp(path, v1) == 0 || strcmp(path, v2) == 0 ||
            strcmp(path, v3) == 0 || strcmp(path, v4) == 0);
}

// ZJB-03/R3-13 STATIC-PARTIAL: textual path canonicalization (collapse '.'/'..'/
// duplicate-slash). Relative paths ARE resolved against the real cwd via getcwd()
// so a relative JB path is caught regardless of the caller's cwd — therefore this
// is NOT syscall-free on the relative branch. Returns a TYPED status; the caller
// applies exemptions ONLY on CI_CANON_OK. This closes the lexical-alias + relative
// vectors ONLY. Separate stable wrappers cover fstatat/getattrlist/readlink/opendir,
// but open/openat/realpath remain unhooked, symlinks are not resolved, and getcwd-
// failure/chdir races remain limitations. Hide-JB therefore remains PARTIAL.
//
// P1 contract fix: overflow/cwd-failure RETURN IMMEDIATELY during parse (out[0]=0)
// so a partial output can never be built or trusted. The old single BOOL + the
// `if(!complete) break` in the copy loop made a >512-segment path emit only the
// first segment ("/var"), which then slipped past the hide table — that is fixed
// here by separating PARSE status (early-return) from OUTPUT truncation.
// INVARIANT: sizeof(canon) (1024) is far larger than the longest kHide entry
// (~27B) + 1 boundary byte, so an OUT_TRUNCATED prefix still fully contains any
// hide prefix — the hide table stays reliable on a truncated prefix.
#define CI_CANON_MAXSEG 512
typedef enum {
    CI_CANON_OK = 0,          // fully canonicalized; `out` is complete
    CI_CANON_INVALID,         // NULL/empty input or bad args; `out` empty
    CI_CANON_CWD_FAILED,      // relative input but getcwd failed/non-absolute; `out` empty
    CI_CANON_SEG_OVERFLOW,    // > CI_CANON_MAXSEG segments; parse aborted; `out` empty
    CI_CANON_OUT_TRUNCATED,   // parse OK but output buffer too small; `out` = valid canonical PREFIX
} ci_canon_status;
static ci_canon_status ci_canonPath(const char *in, char *out, size_t outsz) {
    if (out && outsz) out[0] = 0;
    if (!out || outsz == 0 || !in || in[0] == '\0') return CI_CANON_INVALID;  // NULL/empty ⇒ INVALID (never cwd)
    int saved_errno = errno;                                                  // preserve caller errno around getcwd
    const char *segs[CI_CANON_MAXSEG]; size_t seglen[CI_CANON_MAXSEG]; int nseg = 0;
    char cwd[1024];
    if (in[0] != '/') {                                                       // relative → seed from REAL cwd
        if (getcwd(cwd, sizeof(cwd)) == NULL || cwd[0] != '/') {
            errno = saved_errno; out[0] = 0; return CI_CANON_CWD_FAILED;      // do NOT rootify the input
        }
        for (const char *p = cwd; *p; ) {
            while (*p == '/') p++;
            if (!*p) break;
            const char *s = p; while (*p && *p != '/') p++;
            size_t len = (size_t)(p - s);
            if (len == 1 && s[0] == '.') continue;
            if (len == 2 && s[0] == '.' && s[1] == '.') { if (nseg > 0) nseg--; continue; }
            if (nseg >= CI_CANON_MAXSEG) { errno = saved_errno; out[0] = 0; return CI_CANON_SEG_OVERFLOW; }
            segs[nseg] = s; seglen[nseg] = len; nseg++;
        }
    }
    for (const char *p = in; *p; ) {                                          // apply the input segments
        while (*p == '/') p++;
        if (!*p) break;
        const char *s = p; while (*p && *p != '/') p++;
        size_t len = (size_t)(p - s);
        if (len == 1 && s[0] == '.') continue;                               // "."
        if (len == 2 && s[0] == '.' && s[1] == '.') { if (nseg > 0) nseg--; continue; }  // ".."
        if (nseg >= CI_CANON_MAXSEG) { errno = saved_errno; out[0] = 0; return CI_CANON_SEG_OVERFLOW; }
        segs[nseg] = s; seglen[nseg] = len; nseg++;
    }
    errno = saved_errno;
    if (nseg == 0) {                                                          // canonical root "/"
        if (outsz >= 2) { out[0] = '/'; out[1] = 0; return CI_CANON_OK; }
        out[0] = 0; return CI_CANON_OUT_TRUNCATED;
    }
    size_t o = 0;                                                            // build output; parse already OK
    for (int i = 0; i < nseg; i++) {
        if (o + 1 >= outsz) { out[o] = 0; return CI_CANON_OUT_TRUNCATED; }
        out[o++] = '/';
        for (size_t j = 0; j < seglen[i]; j++) {
            if (o + 1 >= outsz) { out[o] = 0; return CI_CANON_OUT_TRUNCATED; }
            out[o++] = segs[i][j];
        }
    }
    out[o] = 0;
    return CI_CANON_OK;
}

static BOOL isJBPath(const char *path) {
    if (!g_hideJBOn || g_ciInternalFS > 0 || !path) return NO;
    // ZJB-03/R3-13: canonicalize FIRST (collapse '.'/'..'/dup-slash, NO disk I/O),
    // then run BOTH exemptions and hide-checks on the RESOLVED path. Running
    // exemptions on the RAW path let alias forms escape hiding, e.g.
    //   /var/jb/etc/changeinfoios/../../Applications/Sileo.app   (cfg-dir prefix escape)
    //   /var/mobile/vcam/../../../Applications/Cydia.app         (vcam exemption escape)
    // Canonicalizing before the exemption closes that. This still covers ONLY the
    // lexical-alias vector. Raw open/openat/realpath and symlink resolution remain
    // outside this layer, so filesystem hide is still partial.
    char canon[1024];
    ci_canon_status st = ci_canonPath(path, canon, sizeof(canon));
    // ITEM 1 — ERROR PARITY: for ANY non-OK status (INVALID / CWD_FAILED /
    // SEG_OVERFLOW / OUT_TRUNCATED) return NO so the hook PASSES THROUGH to the
    // ORIGINAL syscall and the OS returns the real result + errno. We must NOT
    // fabricate ENOENT for an over-long / unresolvable / >512-segment path — that
    // would mask ENAMETOOLONG (or a genuine ENOENT vs EACCES) and is itself a
    // detectable tell, and such paths are not realistic anti-fraud JB probes. ONLY
    // a fully-OK canonicalization is trusted to hide. (getcwd-failure / >512-seg /
    // symlink stay LIMITATIONS — see report.)
    if (st != CI_CANON_OK) return NO;
    const char *cp = canon;
    {
        // Only exact camera-tweak data files are exempt. Config/restore access is
        // authorized by CIInternalFSGuard, never by a globally-visible path prefix.
        if (isTweakDataPath(cp)) return NO;
    }
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
        "/private/var/lib/dpkg", "/private/var/lib/cydia", "/private/var/cache/apt",
        "/Library/PreferenceBundles", "/Library/PreferenceLoader",
        "/private/var/stash", "/var/stash", "/var/log/apt", "/var/log/dpkg.log",
        "/usr/bin/apt", "/usr/bin/apt-get", "/usr/bin/dpkg",
        "/usr/lib/libhooker.dylib", "/usr/lib/libsubstitute.dylib", "/usr/lib/ellekit",
        "/usr/sbin/frida-server", "/usr/bin/frida-server", "/FridaGadget.dylib",
        "/.installed_unc0ver", "/.bootstrapped_electra", "/.bootstrapped",
        "/taurine", "/var/binpack", "/private/var/binpack", "/jb",
        "/Applications/Filza.app",
        "/.procursus_trap",   // Procursus bootstrap marker
        "/var/.roothide",     // roothide presence marker
        "/private/var/.roothide",
        "/.installed_palera1n",
        NULL
    };
    // Boundary-aware prefix match on the canonical path: a hide entry matches only
    // when the next char is '/' or end-of-string, so "/var/jb" hides "/var/jb" and
    // "/var/jb/..." but NOT a real path like "/var/jbx" (old strncmp prefix hid it —
    // a false positive that itself signalled tampering on legit look-alike paths).
    for (int i = 0; kHide[i]; i++) {
        size_t hl = strlen(kHide[i]);
        if (strncmp(cp, kHide[i], hl) == 0 && (cp[hl] == '\0' || cp[hl] == '/'))
            return YES;
    }
    // Also hide the roothide JB prefix when it differs from /var/jb.
    // iOS /var is a symlink to /private/var; ci_canonPath is textual-only so
    // "/private/<rh>" and "<rh>" are distinct canonical forms — cover both.
    {
        const char *rh = ci_rh_prefix();
        size_t rl = strlen(rh);
        if (strncmp(cp, rh, rl) == 0 && (cp[rl] == '\0' || cp[rl] == '/'))
            return YES;
        if (strncmp(rh, "/private/", 9) == 0) {
            // rh already has /private/: also try without it (/var/... form)
            const char *rh2 = rh + 8; size_t rl2 = rl - 8;
            if (strncmp(cp, rh2, rl2) == 0 && (cp[rl2] == '\0' || cp[rl2] == '/'))
                return YES;
        } else {
            // rh lacks /private/: also try with it (/private/var/... form)
            char priv[528];
            snprintf(priv, sizeof(priv), "/private%s", rh);
            size_t pl = strlen(priv);
            if (strncmp(cp, priv, pl) == 0 && (cp[pl] == '\0' || cp[pl] == '/'))
                return YES;
        }
    }
    return NO;
}

typedef int (*stat_fn_t)(const char *, struct stat *);
typedef int (*access_fn_t)(const char *, int);
typedef int (*dladdr_fn_t)(const void *, Dl_info *);
static stat_fn_t   orig_stat_fn   = NULL;
static stat_fn_t   orig_lstat_fn  = NULL;
static access_fn_t orig_access_fn = NULL;
static dladdr_fn_t orig_dladdr_fn = NULL;

// Pass-through for callers whose immediate caller is a JB tweak dylib, so
// they can reach their own files under /var/jb/. Single-frame check via
// __builtin_return_address(1) — cheap and safe. (The earlier backtrace-based
// multi-frame walk caused severe lag + watchdog kills during video calls:
// AVFoundation enumerates dyld images on the camera hot path, and running
// backtrace()+dladdr on every call hung the app. VCam's own files are now
// handled by the isTweakDataPath() whitelist in isJBPath(), which doesn't
// need any caller detection — so a fast single-frame check is sufficient.)
static BOOL statCallerIsJBTweak(void) {
    // 4.3.41b: never touch dladdr off the main thread. This exemption only ever
    // says YES for a peer JB tweak reading its own /var/jb tree — which never
    // happens inside an injected app (the tweak's OWN reads are already exempted
    // earlier by g_ciInternalFS/CIInternalFSGuard). So off-main the honest answer
    // is "not a peer tweak" = NO = hide, and we skip the dladdr entirely. That
    // matters because dladdr takes the dyld loader lock: a background-thread JB
    // probe during the launch dlopen window (an anti-fraud SDK statting
    // /Applications/Cydia.app, /bin/bash, /var/jb/...) would otherwise block on
    // the lock the main thread holds mid-dlopen -> the 0x8BADF00D launch deadlock.
    // On the main thread dladdr is a recursive lock acquire and never blocks, so
    // the real check (and the %ctor tweak-self exemption) is preserved there.
    if (!pthread_main_np()) return NO;
    Dl_info di; di.dli_fname = NULL;
    int ok = orig_dladdr_fn ? orig_dladdr_fn(__builtin_return_address(1), &di)
                            : dladdr(__builtin_return_address(1), &di);
    if (!ok) return NO;
    if (!di.dli_fname) return NO;
    if (strncmp(di.dli_fname, "/var/jb/Library/", 16) == 0 ||
        strncmp(di.dli_fname, "/var/jb/usr/lib/", 16) == 0 ||
        strncmp(di.dli_fname, "/private/var/jb/Library/", 24) == 0) return YES;
    // Check roothide dynamic prefix (both /var/... and /private/var/... forms).
    {
        const char *rh = ci_rh_prefix();
        size_t rl = strlen(rh);
        char lib_chk[512], usr_chk[512];
        snprintf(lib_chk, sizeof(lib_chk), "%s/Library/", rh);
        snprintf(usr_chk, sizeof(usr_chk), "%s/usr/lib/", rh);
        if (strncmp(di.dli_fname, lib_chk, rl + 9) == 0 ||
            strncmp(di.dli_fname, usr_chk, rl + 9) == 0) return YES;
        // /private/ alias
        char priv_lib[536], priv_usr[536];
        if (strncmp(rh, "/private/", 9) == 0) {
            // strip /private and check bare form
            snprintf(priv_lib, sizeof(priv_lib), "%s/Library/", rh + 8);
            snprintf(priv_usr, sizeof(priv_usr), "%s/usr/lib/", rh + 8);
        } else {
            snprintf(priv_lib, sizeof(priv_lib), "/private%s/Library/", rh);
            snprintf(priv_usr, sizeof(priv_usr), "/private%s/usr/lib/", rh);
        }
        size_t pl = strlen(priv_lib), pu = strlen(priv_usr);
        if (strncmp(di.dli_fname, priv_lib, pl) == 0 ||
            strncmp(di.dli_fname, priv_usr, pu) == 0) return YES;
        (void)rl;
    }
    return NO;
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
// removed for a variadic-ABI crash). Our own debug/config work is authorized by
// the internal scope or by the /var/jb caller check; app callers see those paths hidden.
typedef FILE *(*fopen_fn_t)(const char *, const char *);
static fopen_fn_t orig_fopen_fn = NULL;
static FILE *hook_fopen_fn(const char *path, const char *mode) {
    if (path && isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return NULL; }
    return orig_fopen_fn(path, mode);
}

// Non-variadic filesystem APIs that bypass stat/access/fopen. Unlike open/openat,
// these do not have the ABI/watchdog regression seen in 4.3.23. For *at variants
// we only evaluate absolute paths or AT_FDCWD; a relative path against another
// dirfd must pass through because resolving it would add fcntl/I/O recursion.
typedef int (*fstatat_fn_t)(int, const char *, struct stat *, int);
// sandbox_check() returns 0 when the sandbox ALLOWS an operation, non-zero when it
// denies. On a jailbroken device the sandbox is bypassed so the check returns 0 for
// paths like /bin/bash — exposing the JB to apps that call it as a probe.
// We intercept it and return EPERM for any JB path (value 1 matches stock iOS deny).
// Only the SANDBOX_FILTER_PATH (type 1) variant carries a path arg; other types pass
// through unchanged. Variadic is safe on ARM64 — named args are in x0-x7 registers.
#include <sandbox.h>
typedef int (*sandbox_check_fn_t)(pid_t, const char *, int, ...);
static sandbox_check_fn_t orig_sandbox_check_fn = NULL;
static int hook_sandbox_check_fn(pid_t pid, const char *op, int type, ...) {
    if (g_hideJBOn && type == 1 /* SANDBOX_FILTER_PATH */) {
        va_list ap; va_start(ap, type);
        const char *path = va_arg(ap, const char *);
        va_end(ap);
        if (path && isJBPath(path) && !statCallerIsJBTweak()) return 1;
        return orig_sandbox_check_fn ? orig_sandbox_check_fn(pid, op, type, path) : 0;
    }
    // For non-path filter types we can't safely extract the va_arg on all ABIs —
    // pass through by calling the original with no extra arg (type alone determines
    // the sandbox deny for non-path checks, which is fine).
    return orig_sandbox_check_fn ? orig_sandbox_check_fn(pid, op, type) : 0;
}

typedef int (*faccessat_fn_t)(int, const char *, int, int);
typedef int (*getattrlist_fn_t)(const char *, struct attrlist *, void *, size_t, unsigned long);
typedef ssize_t (*readlink_fn_t)(const char *, char *, size_t);
typedef ssize_t (*readlinkat_fn_t)(int, const char *, char *, size_t);
typedef DIR *(*opendir_fn_t)(const char *);
typedef struct dirent *(*readdir_fn_t)(DIR *);
typedef int (*readdir_r_fn_t)(DIR *, struct dirent *, struct dirent **);
typedef int (*closedir_fn_t)(DIR *);
static fstatat_fn_t     orig_fstatat_fn = NULL;
static faccessat_fn_t   orig_faccessat_fn = NULL;
static getattrlist_fn_t orig_getattrlist_fn = NULL;
static readlink_fn_t    orig_readlink_fn = NULL;
static readlinkat_fn_t  orig_readlinkat_fn = NULL;
static opendir_fn_t     orig_opendir_fn = NULL;
static readdir_fn_t     orig_readdir_fn = NULL;
static readdir_r_fn_t   orig_readdir_r_fn = NULL;
static closedir_fn_t    orig_closedir_fn = NULL;

static inline BOOL ci_atPathCanResolve(int fd, const char *path) {
    return path && (path[0] == '/' || fd == AT_FDCWD);
}
static int hook_fstatat_fn(int fd, const char *path, struct stat *buf, int flags) {
    if (ci_atPathCanResolve(fd, path) && isJBPath(path) && !statCallerIsJBTweak()) {
        errno = ENOENT; return -1;
    }
    return orig_fstatat_fn(fd, path, buf, flags);
}
static int hook_faccessat_fn(int fd, const char *path, int mode, int flags) {
    if (ci_atPathCanResolve(fd, path) && isJBPath(path) && !statCallerIsJBTweak()) {
        errno = ENOENT; return -1;
    }
    return orig_faccessat_fn(fd, path, mode, flags);
}
static int hook_getattrlist_fn(const char *path, struct attrlist *attrs, void *buf,
                               size_t size, unsigned long options) {
    if (path && isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return -1; }
    return orig_getattrlist_fn(path, attrs, buf, size, options);
}
static ssize_t hook_readlink_fn(const char *path, char *buf, size_t size) {
    if (path && isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return -1; }
    ssize_t rc = orig_readlink_fn(path, buf, size);
    if (rc > 0 && buf && buf[0] == '/') {
        char target[1024];
        size_t n = ((size_t)rc < sizeof(target) - 1) ? (size_t)rc : sizeof(target) - 1;
        memcpy(target, buf, n); target[n] = 0;
        // 4.3.40: cheap lexical check first; dladdr (dyld lock) only on a JB hit.
        if (isJBPath(target) && !statCallerIsJBTweak()) { errno = ENOENT; return -1; }
    }
    return rc;
}
static ssize_t hook_readlinkat_fn(int fd, const char *path, char *buf, size_t size) {
    if (ci_atPathCanResolve(fd, path) && isJBPath(path) && !statCallerIsJBTweak()) {
        errno = ENOENT; return -1;
    }
    ssize_t rc = orig_readlinkat_fn(fd, path, buf, size);
    if (rc > 0 && buf && buf[0] == '/') {
        char target[1024];
        size_t n = ((size_t)rc < sizeof(target) - 1) ? (size_t)rc : sizeof(target) - 1;
        memcpy(target, buf, n); target[n] = 0;
        // 4.3.40: cheap lexical check first; dladdr (dyld lock) only on a JB hit.
        if (isJBPath(target) && !statCallerIsJBTweak()) { errno = ENOENT; return -1; }
    }
    return rc;
}

typedef struct ci_dir_track {
    DIR *dir;
    char base[1024];
    struct ci_dir_track *next;
} ci_dir_track;
static pthread_mutex_t g_dirTrackMu = PTHREAD_MUTEX_INITIALIZER;
static ci_dir_track *g_dirTracks = NULL;

static void ci_trackDir(DIR *dir, const char *path) {
    if (!dir || !path) return;
    char canon[1024];
    if (ci_canonPath(path, canon, sizeof(canon)) != CI_CANON_OK) return;
    ci_dir_track *node = (ci_dir_track *)calloc(1, sizeof(ci_dir_track));
    if (!node) return;
    node->dir = dir;
    strlcpy(node->base, canon, sizeof(node->base));
    pthread_mutex_lock(&g_dirTrackMu);
    node->next = g_dirTracks;
    g_dirTracks = node;
    pthread_mutex_unlock(&g_dirTrackMu);
}
static BOOL ci_dirBase(DIR *dir, char *out, size_t outSize) {
    BOOL found = NO;
    pthread_mutex_lock(&g_dirTrackMu);
    for (ci_dir_track *n = g_dirTracks; n; n = n->next) {
        if (n->dir == dir) { strlcpy(out, n->base, outSize); found = YES; break; }
    }
    pthread_mutex_unlock(&g_dirTrackMu);
    return found;
}
static void ci_untrackDir(DIR *dir) {
    pthread_mutex_lock(&g_dirTrackMu);
    ci_dir_track **link = &g_dirTracks;
    while (*link) {
        if ((*link)->dir == dir) {
            ci_dir_track *old = *link;
            *link = old->next;
            free(old);
            break;
        }
        link = &(*link)->next;
    }
    pthread_mutex_unlock(&g_dirTrackMu);
}
// 4.3.40: a directory can only expose a JB entry through readdir if it is a
// PARENT of a hidden path. Every hidden path lives at canonical depth <= 4
// (/private/var/lib/dpkg, /usr/lib/libhooker.dylib, /Library/MobileSubstrate,
// /Applications/Sileo.app, ...) or under /var/jb, so only shallow system dirs
// (depth <= 3) and the /var/jb tree ever need readdir tracking; an app container
// (depth >= 6) never does. This replaces the dladdr() caller check that ran on
// EVERY successful opendir. dladdr takes the dyld lock, and Firebase Crashlytics
// enumerates directories during scene-create while Zalo is still dlopen-ing
// frameworks, so the main thread blocked on that lock until FrontBoard's
// 0x8BADF00D watchdog killed Zalo. Same stall class the 4.1.4 MGCopyAnswer fix
// removed. The caller exemption is not needed to decide *tracking*: at worst
// another JB tweak's own readdir gets JB names filtered, which is harmless.
static BOOL ci_dirMayListJB(const char *path) {
    if (!path) return NO;
    char canon[1024];
    if (ci_canonPath(path, canon, sizeof(canon)) != CI_CANON_OK) return NO;
    if (strncmp(canon, "/var/jb", 7) == 0 || strncmp(canon, "/private/var/jb", 15) == 0) return YES;
    // roothide prefix — both /var/... and /private/var/... forms
    { const char *rh = ci_rh_prefix(); size_t rl = strlen(rh);
      if (strncmp(canon, rh, rl) == 0 && (canon[rl] == '\0' || canon[rl] == '/')) return YES;
      char rh_alt[528]; size_t al;
      if (strncmp(rh, "/private/", 9) == 0) {
          snprintf(rh_alt, sizeof(rh_alt), "%s", rh + 8); al = rl - 8;
      } else {
          snprintf(rh_alt, sizeof(rh_alt), "/private%s", rh); al = strlen(rh_alt);
      }
      if (strncmp(canon, rh_alt, al) == 0 && (canon[al] == '\0' || canon[al] == '/')) return YES; }
    int depth = 0;
    for (const char *p = canon; *p; p++) if (*p == '/' && p[1]) depth++;
    return depth <= 3;
}
static DIR *hook_opendir_fn(const char *path) {
    if (path && isJBPath(path) && !statCallerIsJBTweak()) { errno = ENOENT; return NULL; }
    DIR *dir = orig_opendir_fn(path);
    if (dir && g_hideJBOn && g_ciInternalFS == 0 && ci_dirMayListJB(path)) ci_trackDir(dir, path);
    return dir;
}
static struct dirent *hook_readdir_fn(DIR *dir) {
    if (!orig_readdir_fn) { errno = EBADF; return NULL; }
    if (!g_hideJBOn || g_ciInternalFS > 0) return orig_readdir_fn(dir);
    char base[1024];
    if (!ci_dirBase(dir, base, sizeof(base))) return orig_readdir_fn(dir);
    for (;;) {
        struct dirent *ent = orig_readdir_fn(dir);
        if (!ent) return NULL;
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) return ent;
        char full[2048];
        int n = snprintf(full, sizeof(full), "%s/%s", base, ent->d_name);
        if (n <= 0 || (size_t)n >= sizeof(full) || !isJBPath(full)) return ent;
    }
}
// readdir_r — reentrant variant; same filtering logic as readdir.
static int hook_readdir_r_fn(DIR *dir, struct dirent *entry, struct dirent **result) {
    if (!orig_readdir_r_fn) { if (result) *result = NULL; return EBADF; }
    if (!g_hideJBOn || g_ciInternalFS > 0) return orig_readdir_r_fn(dir, entry, result);
    char base[1024];
    if (!ci_dirBase(dir, base, sizeof(base))) return orig_readdir_r_fn(dir, entry, result);
    for (;;) {
        int rc = orig_readdir_r_fn(dir, entry, result);
        if (rc != 0 || !result || !*result) return rc;
        struct dirent *ent = *result;
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) return 0;
        char full[2048];
        int n = snprintf(full, sizeof(full), "%s/%s", base, ent->d_name);
        if (n <= 0 || (size_t)n >= sizeof(full) || !isJBPath(full)) return 0;
        // entry was a JB path — skip and try the next one
    }
}
static int hook_closedir_fn(DIR *dir) {
    ci_untrackDir(dir);
    return orig_closedir_fn(dir);
}

// getenv — hide the injection env vars some anti-fraud SDKs probe.
typedef char *(*getenv_fn_t)(const char *);
static getenv_fn_t orig_getenv_fn = NULL;
static char *hook_getenv_fn(const char *name) {
    if (g_hideJBOn && name && (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
                 strcmp(name, "_MSSafeMode") == 0 ||
                 strcmp(name, "_SubstrateMode") == 0 ||
                 strcmp(name, "JBROOT") == 0 ||          // roothide bootstrap exports JB root
                 strcmp(name, "ROOTHIDE_APP_ROOT") == 0 ||
                 strcmp(name, "_SafeMode") == 0)) return NULL;
    return orig_getenv_fn(name);
}

// NOTE (4.3.24): open()/openat()/fstatat() hooks REVERTED. They were re-added in
// 4.3.23 to close the biggest file-check gap, but on-device they reproduced the
// exact FrontBoard scene-create watchdog that the 4.x removal note warned about:
// Zalo hung on the launch icon then bounced to the home screen ("treo logo →
// văng"). open() fires enormously during dlopen/scene-create (Zalo loads hundreds
// of images), and hooking a VARIADIC syscall on this hot path — even with a
// correct-looking va_arg pattern — trips the watchdog. Isolation test confirmed:
// with the camera spoof DISABLED, Zalo still died, so the file hooks (not the
// camera) were the cause. Reverted to the stable stat/lstat/access/fopen set.
// The open() JB-hide gap stays OPEN; closing it needs a non-hot-path technique
// (kernel-level or a dedicated JB-hide tweak), not an inline libc hook here.

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
    // 4.3.40: decide whether there is ANYTHING to hide before paying for the
    // dladdr() caller check. This method sits on Zalo's launch path (Firebase
    // Crashlytics enumerates its report dirs inside +[FIRApp configure]) and
    // dladdr takes the dyld lock while the app is still dlopen-ing frameworks —
    // the unconditional check that used to be here was the exact frame pinning
    // the main thread until FrontBoard's 0x8BADF00D watchdog killed Zalo
    // (Sep 3, "văng" ~44 min into a session). App-container listings never
    // contain a JB entry, so they now return with O(n) string work and no lock.
    NSMutableArray *out = nil;
    for (NSUInteger i = 0; i < orig.count; i++) {
        NSString *item = orig[i];
        NSString *full = [path stringByAppendingPathComponent:item];
        if (isJBPath([full UTF8String])) {
            if (!out) {
                // First hidden entry: a JB tweak listing its own tree keeps it.
                if (statCallerIsJBTweak()) return orig;
                out = [NSMutableArray arrayWithCapacity:orig.count];
                [out addObjectsFromArray:[orig subarrayWithRange:NSMakeRange(0, i)]];
            }
            continue;   // hidden
        }
        if (out) [out addObject:item];
    }
    return out ?: orig;
}
%end

// ============================================================
// NSBundle enumeration hiding.
// Anti-fraud SDKs (Zalo, ByteDance) call +[NSBundle allBundles] /
// +[NSBundle allFrameworks] to enumerate loaded frameworks independent
// of dyld hooks — this strips JB-path entries from both lists.
%hook NSBundle
+ (NSArray *)allBundles {
    NSArray *orig = %orig;
    if (!g_hideJBOn) return orig;
    NSMutableArray *out = nil;
    for (NSUInteger i = 0; i < orig.count; i++) {
        NSBundle *b = orig[i];
        NSString *bp = b.bundlePath;
        if (bp && isJBPath(bp.UTF8String)) {
            if (!out) {
                out = [NSMutableArray arrayWithCapacity:orig.count];
                [out addObjectsFromArray:[orig subarrayWithRange:NSMakeRange(0, i)]];
            }
            continue;
        }
        if (out) [out addObject:b];
    }
    return out ?: orig;
}
+ (NSArray *)allFrameworks {
    NSArray *orig = %orig;
    if (!g_hideJBOn) return orig;
    NSMutableArray *out = nil;
    for (NSUInteger i = 0; i < orig.count; i++) {
        NSBundle *b = orig[i];
        NSString *bp = b.bundlePath;
        if (bp && isJBPath(bp.UTF8String)) {
            if (!out) {
                out = [NSMutableArray arrayWithCapacity:orig.count];
                [out addObjectsFromArray:[orig subarrayWithRange:NSMakeRange(0, i)]];
            }
            continue;
        }
        if (out) [out addObject:b];
    }
    return out ?: orig;
}
%end

// ============================================================
// LAYER 22: APNS device-token spoof (reg-die fix, 4.3.30).
//
// The STANDARD APNS push token (delivered to the app delegate's
// -application:didRegisterForRemoteNotificationsWithDeviceToken:) is device+install
// stable — it does NOT change across a Change Device (rm -rf of the container does
// not reissue it). Zalo sends it to VNG, so every account registered from one phone
// carries the SAME token → VNG correlates → ban. (Only the VoIP token was spoofed
// before — LAYER 20 — via PKPushRegistry; the standard APNS token was a KNOWN GAP.)
// We runtime-swizzle the app delegate's didRegister... to hand it the per-Change-
// Device fake token (config apnsTokenSpoof, the same 32-byte value LAYER 20 uses),
// so the token Zalo forwards to VNG rotates per identity and can't correlate.
// Independent of the camera swizzle (different selector, own state).
// ============================================================
static SEL g_apnsSel = NULL;
static os_unfair_lock g_apnsLock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef g_apnsIMPs = NULL;   // Method* -> original IMP

static NSData *ci_fakeAPNSToken(void) {
    NSString *hex = getConfigStr(@"apnsTokenSpoof");
    if (hex.length < 64) return nil;                 // need >=32 bytes
    NSMutableData *d = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int b = 0;
        NSScanner *sc = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        if (![sc scanHexInt:&b]) return nil;
        uint8_t byte = (uint8_t)(b & 0xff);
        [d appendBytes:&byte length:1];
    }
    return d.length >= 32 ? [d copy] : nil;
}

static void ci_hookedDidRegisterAPNS(id self, SEL _cmd, id app, NSData *deviceToken) {
    NSData *fake = ci_fakeAPNSToken();
    NSData *tok = (fake.length ? fake : deviceToken);   // fall back to real if no config
    dbglog("APNS.spoof %s realLen=%lu fake=%c\n", g_procname,
           (unsigned long)deviceToken.length, fake ? 'Y' : 'N');
    IMP orig = NULL;
    Method m = class_getInstanceMethod([self class], _cmd);
    if (m) {
        os_unfair_lock_lock(&g_apnsLock);
        if (g_apnsIMPs) orig = (IMP)CFDictionaryGetValue(g_apnsIMPs, m);
        os_unfair_lock_unlock(&g_apnsLock);
    }
    if (orig)
        ((void(*)(id, SEL, id, NSData *))orig)(self, _cmd, app, tok);
    // else: delegate had no original impl (we added it) → nothing downstream to call.
}

static void ci_apnsSwizzleDelegate(Class c) {
    if (!c || !g_apnsSel) return;
    os_unfair_lock_lock(&g_apnsLock);
    if (!g_apnsIMPs) g_apnsIMPs = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    Method m = class_getInstanceMethod(c, g_apnsSel);
    if (m) {
        IMP cur = method_getImplementation(m);
        if (cur != (IMP)ci_hookedDidRegisterAPNS) {
            IMP old = method_setImplementation(m, (IMP)ci_hookedDidRegisterAPNS);
            CFDictionarySetValue(g_apnsIMPs, (const void *)m, (const void *)old);
            dbglog("APNS.swizzle %s cls=%s\n", g_procname, class_getName(c));
        }
    } else {
        // Delegate doesn't implement it — add it so the spoof still applies. No
        // original to chain to; the app just won't get the (now-faked) callback,
        // which is fine (it wasn't handling it anyway).
        class_addMethod(c, g_apnsSel, (IMP)ci_hookedDidRegisterAPNS, "v@:@@");
        dbglog("APNS.addMethod %s cls=%s\n", g_procname, class_getName(c));
    }
    os_unfair_lock_unlock(&g_apnsLock);
}

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    NSString *s = url.scheme.lowercaseString;
    if (g_hideJBOn && ([s isEqualToString:@"cydia"]     || [s isEqualToString:@"sileo"] ||
        [s isEqualToString:@"zbra"]      || [s isEqualToString:@"filza"] ||
        [s isEqualToString:@"santander"] || [s isEqualToString:@"undecimus"] ||
        [s isEqualToString:@"zebra"]     || [s isEqualToString:@"activator"] ||
        [s isEqualToString:@"apt-repo"]  || [s isEqualToString:@"cydia-repo"] ||
        [s isEqualToString:@"installer"] || [s isEqualToString:@"postbox"] ||
        [s isEqualToString:@"dopamine"]  || [s isEqualToString:@"trollstore"] ||
        [s isEqualToString:@"odyssey"]   || [s isEqualToString:@"palera1n"] ||
        [s isEqualToString:@"roothide"])) {
        return NO;
    }
    return %orig;
}
- (void)setDelegate:(id)delegate {
    // LAYER 22: swizzle the app delegate's APNS-token callback so Zalo forwards our
    // rotating fake token to VNG. Only when licensed (gate matches the rest).
    if (delegate && g_licOK && g_targetOK) ci_apnsSwizzleDelegate([delegate class]);
    %orig;
}
%end

// Known jailbreak store / tool app bundle IDs. An app that enumerates installed
// apps via LSApplicationWorkspace (applicationIsInstalled: / allInstalledApplications)
// instead of calling canOpenURL: can otherwise spot these. Not gated on license —
// same as the NSFileManager / canOpenURL JB-hide hooks (hiding JB is not identity
// spoofing) and it is cheap (never a hot path).
static BOOL ci_isJBBundleID(NSString *bid) {
    if (!g_hideJBOn) return NO;
    if (![bid isKindOfClass:[NSString class]] || !bid.length) return NO;
    static NSSet *jb = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        jb = [NSSet setWithObjects:
            @"com.saurik.Cydia", @"org.coolstar.SileoStore", @"org.coolstar.sileo",
            @"xyz.willy.Zebra", @"com.tigisoftware.Filza", @"com.tigisoftware.ADManager",
            @"science.xnu.undecimus", @"com.electra1112.electra", @"org.coolstar.electra",
            @"com.opa334.Dopamine", @"com.opa334.TrollStore", @"com.opa334.trollstorehelper",
            @"com.roothide.manager", @"com.serena.zebra", @"com.hackyouiphone.chariz",
            @"me.qwq.sileo", @"org.coolstar.SileoNightly", nil];
    });
    if ([jb containsObject:bid]) return YES;
    NSString *l = bid.lowercaseString;   // safety net for obvious forks / renames
    return ([l containsString:@"cydia"]      || [l containsString:@"sileo"] ||
            [l containsString:@".filza"]     || [l containsString:@"trollstore"] ||
            [l containsString:@"dopamine"]   || [l containsString:@"checkra1n"] ||
            [l containsString:@"palera1n"]   || [l containsString:@"roothide"] ||
            [l containsString:@"unc0ver"]    || [l containsString:@"electra"]);
}

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)applicationIsInstalled:(NSString *)bundleID;
- (NSArray *)allInstalledApplications;
@end

%hook LSApplicationWorkspace
- (BOOL)applicationIsInstalled:(NSString *)bundleID {
    if (ci_isJBBundleID(bundleID)) {
        dbglog("LSApp.isInstalled.block %s bid=%s\n", g_procname,
               bundleID ? [bundleID UTF8String] : "?");
        return NO;
    }
    return %orig;
}
- (NSArray *)allInstalledApplications {
    NSArray *orig = %orig;
    if (![orig isKindOfClass:[NSArray class]] || orig.count == 0) return orig;
    // Cheap pre-scan: only rebuild the array if it actually contains a JB app.
    BOOL any = NO;
    for (id p in orig) {
        @try {
            if (ci_isJBBundleID([p valueForKey:@"bundleIdentifier"])) { any = YES; break; }
        } @catch (__unused NSException *e) {}
    }
    if (!any) return orig;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:orig.count];
    for (id p in orig) {
        @try {
            if (!ci_isJBBundleID([p valueForKey:@"bundleIdentifier"])) [out addObject:p];
        } @catch (__unused NSException *e) { [out addObject:p]; }   // unknown → keep
    }
    dbglog("LSApp.allInstalled.filter %s %lu->%lu\n", g_procname,
           (unsigned long)orig.count, (unsigned long)out.count);
    return out;
}
%end

// ============================================================
// LAYER 10: dyld image hiding — still PARTIAL, but index-consistent.
//
// Anti-fraud SDKs (Zalo / TikTok) call _dyld_image_count() then
// iterate _dyld_get_image_name(i) looking for:
//   "substrate", "ellekit", "ChangeInfoIos", "/var/jb/" paths.
// We present a filtered view that skips JB-related images.
//
// Count/name/header/slide share one visible->real index map, and dladdr hides
// addresses owned by known injected images. The ObjC image list, direct Mach-O
// memory walks, hook-integrity checks and add-image callbacks can still expose
// injection; do not advertise this as a full/deep JB hide.
// The file-existence side (stat/lstat/access/fopen) is the intended stable set;
// a global open()/openat() hook is deliberately NOT installed (it tripped
// Zalo's FrontBoard scene-create watchdog).
// ============================================================

static const char * const kDyldHide[] = {
    "ChangeInfoIosMG", "ChangeInfoIos",
    "ellekit", "CydiaSubstrate", "libsubstrate", "substitute",
    "MobileSubstrate", "TweakInject", "Dopamine", "palera1n",
    "libhooker", "libblackjack", "pspawn", "ChOma",
    "roothide", "librooter",  // roothide bootstrap and root-helper dylibs
    NULL
};

static inline BOOL isDyldNameHidden(const char *name) {
    if (!name) return NO;
    for (int i = 0; kDyldHide[i]; i++) {
        if (strstr(name, kDyldHide[i])) return YES;
    }
    if (strstr(name, "/var/jb/") || strstr(name, "/private/var/jb/")) return YES;
    // roothide prefix — check both /var/... and /private/var/... forms
    { const char *rh = ci_rh_prefix();
      char pfx_slash[514]; snprintf(pfx_slash, sizeof(pfx_slash), "%s/", rh);
      if (strstr(name, pfx_slash)) return YES;
      char priv_slash[522];
      if (strncmp(rh, "/private/", 9) == 0)
          snprintf(priv_slash, sizeof(priv_slash), "%s/", rh + 8);  // strip /private
      else
          snprintf(priv_slash, sizeof(priv_slash), "/private%s/", rh);
      if (strstr(name, priv_slash)) return YES; }
    return NO;
}

typedef uint32_t    (*dyld_image_count_fn_t)(void);
typedef const char *(*dyld_image_name_fn_t)(uint32_t);
typedef const struct mach_header *(*dyld_image_header_fn_t)(uint32_t);
typedef intptr_t (*dyld_image_slide_fn_t)(uint32_t);
static dyld_image_count_fn_t  orig_dyld_image_count_fn    = NULL;
static dyld_image_name_fn_t   orig_dyld_get_image_name_fn = NULL;
static dyld_image_header_fn_t orig_dyld_get_image_header_fn = NULL;
static dyld_image_slide_fn_t  orig_dyld_get_image_slide_fn = NULL;

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
static int       g_dyldCachedHideOn  = -1;

// Make the cache reflect `total`. Builds into a fresh local buffer with NO lock
// held (dyld calls happen outside our mutex), then swaps it in under a short lock
// and frees the old buffer. Two racing rebuilders both produce valid maps; last
// swap wins, the loser's buffer is freed. Readers only ever copy an int index out
// under the lock, so a freed buffer can never be dereferenced by another thread.
static BOOL dyldEnsureMap(uint32_t total) {
    int hideSnapshot = g_hideJBOn ? 1 : 0;
    pthread_mutex_lock(&g_dyldMapMu);
    int ok = (g_dyldMapBuilt && total == g_dyldCachedTotal &&
              hideSnapshot == g_dyldCachedHideOn);
    pthread_mutex_unlock(&g_dyldMapMu);
    if (ok) return YES;

    uint32_t *m = (uint32_t *)malloc((total ? total : 1) * sizeof(uint32_t));
    if (!m) return NO;                    // caller falls back to one consistent real view
    uint32_t vis = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *name = orig_dyld_get_image_name_fn(i);
        if (hideSnapshot && isDyldNameHidden(name)) continue;
        m[vis++] = i;
    }

    pthread_mutex_lock(&g_dyldMapMu);
    uint32_t *old = g_dyldVisibleToReal;
    g_dyldVisibleToReal = m;
    g_dyldVisibleCount  = vis;
    g_dyldCachedTotal   = total;
    g_dyldCachedHideOn  = hideSnapshot;
    g_dyldMapBuilt      = 1;
    pthread_mutex_unlock(&g_dyldMapMu);
    free(old);
    return YES;
}

static uint32_t hooked_dyld_image_count(void) {
    if (!orig_dyld_image_count_fn || !orig_dyld_get_image_name_fn)
        return orig_dyld_image_count_fn ? orig_dyld_image_count_fn() : 0;
    uint32_t total = orig_dyld_image_count_fn();
    if (!dyldEnsureMap(total)) return total;
    pthread_mutex_lock(&g_dyldMapMu);
    uint32_t vc = (g_dyldMapBuilt && g_dyldCachedTotal == total) ? g_dyldVisibleCount : total;
    pthread_mutex_unlock(&g_dyldMapMu);
    return vc;
}

static BOOL dyldVisibleToRealIndex(uint32_t index, uint32_t *realOut);

static const char *hooked_dyld_get_image_name(uint32_t index) {
    if (!orig_dyld_get_image_name_fn) return NULL;
    uint32_t real = 0;
    return dyldVisibleToRealIndex(index, &real) ? orig_dyld_get_image_name_fn(real) : NULL;
}

static BOOL dyldVisibleToRealIndex(uint32_t index, uint32_t *realOut) {
    if (!realOut || !orig_dyld_image_count_fn || !orig_dyld_get_image_name_fn) return NO;
    uint32_t total = orig_dyld_image_count_fn();
    if (!dyldEnsureMap(total)) {
        if (index >= total) return NO;
        *realOut = index;
        return YES;
    }
    pthread_mutex_lock(&g_dyldMapMu);
    BOOL ok = g_dyldMapBuilt && g_dyldCachedTotal == total &&
              g_dyldCachedHideOn == (g_hideJBOn ? 1 : 0) &&
              index < g_dyldVisibleCount;
    if (ok) *realOut = g_dyldVisibleToReal[index];
    pthread_mutex_unlock(&g_dyldMapMu);
    return ok;
}

// Keep all index-based dyld APIs on the same filtered view. Previously count/name
// were filtered while header/slide used real indexes, an easy consistency probe.
static const struct mach_header *hooked_dyld_get_image_header(uint32_t index) {
    uint32_t real = 0;
    return (orig_dyld_get_image_header_fn && dyldVisibleToRealIndex(index, &real))
        ? orig_dyld_get_image_header_fn(real) : NULL;
}
static intptr_t hooked_dyld_get_image_slide(uint32_t index) {
    uint32_t real = 0;
    return (orig_dyld_get_image_slide_fn && dyldVisibleToRealIndex(index, &real))
        ? orig_dyld_get_image_slide_fn(real) : 0;
}

static int hooked_dladdr(const void *addr, Dl_info *info) {
    if (!orig_dladdr_fn) return 0;
    int rc = orig_dladdr_fn(addr, info);
    // 4.3.40: name check (cheap) BEFORE the caller check — statCallerIsJBTweak
    // re-enters dladdr, so it must only run when the name is actually hidden.
    if (!g_hideJBOn || g_ciInternalFS > 0 || !rc || !info ||
        !isDyldNameHidden(info->dli_fname) || statCallerIsJBTweak()) return rc;
    memset(info, 0, sizeof(*info));
    return 0;
}

typedef const char **(*objc_copy_image_names_fn_t)(unsigned int *);
typedef const char *(*class_get_image_name_fn_t)(Class);
typedef const char **(*objc_copy_classes_for_image_fn_t)(const char *, unsigned int *);
static objc_copy_image_names_fn_t orig_objc_copy_image_names = NULL;
static class_get_image_name_fn_t orig_class_get_image_name = NULL;
static objc_copy_classes_for_image_fn_t orig_objc_copy_classes_for_image = NULL;

static const char **hooked_objc_copy_image_names(unsigned int *outCount) {
    unsigned int total = 0;
    const char **realNames = orig_objc_copy_image_names
        ? orig_objc_copy_image_names(&total) : NULL;
    if (!realNames || !g_hideJBOn) {
        if (outCount) *outCount = total;
        return realNames;
    }
    unsigned int visible = 0;
    for (unsigned int i = 0; i < total; i++) if (!isDyldNameHidden(realNames[i])) visible++;
    // 4.3.40: nothing hidden (the common case) returns without the dladdr caller
    // check; only a listing that would actually drop a name pays for it.
    if (visible == total || statCallerIsJBTweak()) {
        if (outCount) *outCount = total;
        return realNames;
    }
    const char **filtered = (const char **)calloc((size_t)visible + 1, sizeof(char *));
    if (!filtered) {
        if (outCount) *outCount = total;
        return realNames;
    }
    unsigned int j = 0;
    for (unsigned int i = 0; i < total; i++)
        if (!isDyldNameHidden(realNames[i])) filtered[j++] = realNames[i];
    free((void *)realNames);
    if (outCount) *outCount = visible;
    return filtered;
}

static const char *hooked_class_get_image_name(Class cls) {
    const char *name = orig_class_get_image_name ? orig_class_get_image_name(cls) : NULL;
    if (g_hideJBOn && name && isDyldNameHidden(name) && !statCallerIsJBTweak()) return NULL;
    return name;
}

static const char **hooked_objc_copy_classes_for_image(const char *image, unsigned int *outCount) {
    if (g_hideJBOn && image && isDyldNameHidden(image) && !statCallerIsJBTweak()) {
        if (outCount) *outCount = 0;
        return NULL;
    }
    return orig_objc_copy_classes_for_image
        ? orig_objc_copy_classes_for_image(image, outCount) : NULL;
}

// open()/openat() hooks are NOT installed. Tried twice (4.x and again 4.3.23) —
// both times hooking these hot, variadic syscalls tripped the FrontBoard
// scene-create watchdog on Zalo. Stable non-variadic fstatat/faccessat/readlink/
// getattrlist/opendir coverage is installed instead; raw open/openat stays a
// documented gap rather than reintroducing a known launch crash.

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
static int hooked_fork(void) {
    if (!g_hideJBOn) return orig_fork_fn ? orig_fork_fn() : -1;
    errno = EPERM;
    return -1;
}

static void ci_scrubJBEnvironment(void) {
    if (!g_hideJBOn) return;
    // Constructor injection has already completed, so removing these variables
    // cannot unload a tweak. It also closes direct `environ` / NSProcessInfo probes,
    // which a getenv-only hook did not cover. Turning the option off takes full
    // effect on the next target-app launch, when the variables are not removed.
    unsetenv("DYLD_INSERT_LIBRARIES");
    unsetenv("_MSSafeMode");
    unsetenv("_SubstrateMode");
    unsetenv("SubstrateSafeMode");
    unsetenv("_SafeMode");
    // roothide-specific env vars that expose the JB root path to any caller
    unsetenv("JBROOT");
    unsetenv("ROOTHIDE_APP_ROOT");
}

// Install only the lightweight anti-detection layer here. It deliberately runs
// before the license/target spoof gate: an expired token disables identity spoofing,
// but must not turn the already-injected dylib into an obvious JB signal. Expensive
// MG/sysctl/IORegistry/keychain hooks remain behind the gate in %ctor.
static void ci_installJBHideHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ci_scrubJBEnvironment();

        orig_dladdr_fn = (dladdr_fn_t)dlsym(RTLD_DEFAULT, "dladdr");

        orig_stat_fn   = (stat_fn_t)dlsym(RTLD_DEFAULT, "stat");
        orig_lstat_fn  = (stat_fn_t)dlsym(RTLD_DEFAULT, "lstat");
        orig_access_fn = (access_fn_t)dlsym(RTLD_DEFAULT, "access");
        if (orig_stat_fn)
            MSHookFunction((void *)orig_stat_fn, (void *)hook_stat_fn, (void **)&orig_stat_fn);
        if (orig_lstat_fn)
            MSHookFunction((void *)orig_lstat_fn, (void *)hook_lstat_fn, (void **)&orig_lstat_fn);
        if (orig_access_fn)
            MSHookFunction((void *)orig_access_fn, (void *)hook_access_fn, (void **)&orig_access_fn);

        orig_fopen_fn = (fopen_fn_t)dlsym(RTLD_DEFAULT, "fopen");
        if (orig_fopen_fn)
            MSHookFunction((void *)orig_fopen_fn, (void *)hook_fopen_fn, (void **)&orig_fopen_fn);

        orig_fstatat_fn = (fstatat_fn_t)dlsym(RTLD_DEFAULT, "fstatat");
        orig_faccessat_fn = (faccessat_fn_t)dlsym(RTLD_DEFAULT, "faccessat");
        orig_getattrlist_fn = (getattrlist_fn_t)dlsym(RTLD_DEFAULT, "getattrlist");
        orig_readlink_fn = (readlink_fn_t)dlsym(RTLD_DEFAULT, "readlink");
        orig_readlinkat_fn = (readlinkat_fn_t)dlsym(RTLD_DEFAULT, "readlinkat");
        orig_opendir_fn = (opendir_fn_t)dlsym(RTLD_DEFAULT, "opendir");
        orig_readdir_fn = (readdir_fn_t)dlsym(RTLD_DEFAULT, "readdir");
        orig_readdir_r_fn = (readdir_r_fn_t)dlsym(RTLD_DEFAULT, "readdir_r");
        orig_closedir_fn = (closedir_fn_t)dlsym(RTLD_DEFAULT, "closedir");
        if (orig_fstatat_fn)
            MSHookFunction((void *)orig_fstatat_fn, (void *)hook_fstatat_fn, (void **)&orig_fstatat_fn);
        if (orig_faccessat_fn)
            MSHookFunction((void *)orig_faccessat_fn, (void *)hook_faccessat_fn, (void **)&orig_faccessat_fn);
        if (orig_getattrlist_fn)
            MSHookFunction((void *)orig_getattrlist_fn, (void *)hook_getattrlist_fn, (void **)&orig_getattrlist_fn);
        if (orig_readlink_fn)
            MSHookFunction((void *)orig_readlink_fn, (void *)hook_readlink_fn, (void **)&orig_readlink_fn);
        if (orig_readlinkat_fn)
            MSHookFunction((void *)orig_readlinkat_fn, (void *)hook_readlinkat_fn, (void **)&orig_readlinkat_fn);
        if (orig_opendir_fn)
            MSHookFunction((void *)orig_opendir_fn, (void *)hook_opendir_fn, (void **)&orig_opendir_fn);
        if (orig_readdir_fn)
            MSHookFunction((void *)orig_readdir_fn, (void *)hook_readdir_fn, (void **)&orig_readdir_fn);
        if (orig_readdir_r_fn)
            MSHookFunction((void *)orig_readdir_r_fn, (void *)hook_readdir_r_fn, (void **)&orig_readdir_r_fn);
        if (orig_closedir_fn)
            MSHookFunction((void *)orig_closedir_fn, (void *)hook_closedir_fn, (void **)&orig_closedir_fn);

        orig_sandbox_check_fn = (sandbox_check_fn_t)dlsym(RTLD_DEFAULT, "sandbox_check");
        if (orig_sandbox_check_fn)
            MSHookFunction((void *)orig_sandbox_check_fn, (void *)hook_sandbox_check_fn, (void **)&orig_sandbox_check_fn);

        orig_getenv_fn = (getenv_fn_t)dlsym(RTLD_DEFAULT, "getenv");
        if (orig_getenv_fn)
            MSHookFunction((void *)orig_getenv_fn, (void *)hook_getenv_fn, (void **)&orig_getenv_fn);

        orig_dyld_image_count_fn = (dyld_image_count_fn_t)dlsym(RTLD_DEFAULT, "_dyld_image_count");
        orig_dyld_get_image_name_fn = (dyld_image_name_fn_t)dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
        orig_dyld_get_image_header_fn = (dyld_image_header_fn_t)dlsym(RTLD_DEFAULT, "_dyld_get_image_header");
        orig_dyld_get_image_slide_fn = (dyld_image_slide_fn_t)dlsym(RTLD_DEFAULT, "_dyld_get_image_vmaddr_slide");
        if (orig_dyld_image_count_fn && orig_dyld_get_image_name_fn) {
            MSHookFunction((void *)orig_dyld_image_count_fn, (void *)hooked_dyld_image_count,
                           (void **)&orig_dyld_image_count_fn);
            MSHookFunction((void *)orig_dyld_get_image_name_fn, (void *)hooked_dyld_get_image_name,
                           (void **)&orig_dyld_get_image_name_fn);
            if (orig_dyld_get_image_header_fn)
                MSHookFunction((void *)orig_dyld_get_image_header_fn,
                               (void *)hooked_dyld_get_image_header,
                               (void **)&orig_dyld_get_image_header_fn);
            if (orig_dyld_get_image_slide_fn)
                MSHookFunction((void *)orig_dyld_get_image_slide_fn,
                               (void *)hooked_dyld_get_image_slide,
                               (void **)&orig_dyld_get_image_slide_fn);
        }
        // 4.3.41: DO NOT install a prologue hook on dladdr. A global dladdr patch
        // funnels EVERY dladdr in the process — libMobileGestalt's own internal
        // caller checks, Firebase/Crashlytics image walks, CoreTelephony, the ObjC
        // runtime — through our trampoline + ElleKit's. On ElleKit 1.2 (shipped by
        // the Sep-3 re-jailbreak) that amplified the launch-time dyld-loader-lock
        // hot path into a cross-thread pileup: the main thread mid-dlopen in
        // +[FIRApp configure] held the dyld lock while background threads (a
        // CoreTelephony hasBaseband→MGCopyAnswer dispatch_once, etc.) blocked on it
        // through the wrapped dladdr → 21s hang → FrontBoard 0x8BADF00D. The
        // pre-4.3.36 builds never patched dladdr and were stable, so dropping it
        // restores that behaviour. orig_dladdr_fn stays the REAL dladdr (dlsym'd
        // above) for statCallerIsJBTweak; JB-image hiding is still done by the
        // _dyld_* + objc_copyImageNames/class_getImageName hooks (no dyld lock).
        (void)hooked_dladdr;   // kept for reference; intentionally not installed

        orig_objc_copy_image_names = (objc_copy_image_names_fn_t)dlsym(RTLD_DEFAULT, "objc_copyImageNames");
        orig_class_get_image_name = (class_get_image_name_fn_t)dlsym(RTLD_DEFAULT, "class_getImageName");
        orig_objc_copy_classes_for_image = (objc_copy_classes_for_image_fn_t)dlsym(RTLD_DEFAULT, "objc_copyClassNamesForImage");
        if (orig_objc_copy_image_names)
            MSHookFunction((void *)orig_objc_copy_image_names, (void *)hooked_objc_copy_image_names,
                           (void **)&orig_objc_copy_image_names);
        if (orig_class_get_image_name)
            MSHookFunction((void *)orig_class_get_image_name, (void *)hooked_class_get_image_name,
                           (void **)&orig_class_get_image_name);
        if (orig_objc_copy_classes_for_image)
            MSHookFunction((void *)orig_objc_copy_classes_for_image,
                           (void *)hooked_objc_copy_classes_for_image,
                           (void **)&orig_objc_copy_classes_for_image);

        orig_fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
        if (orig_fork_fn)
            MSHookFunction((void *)orig_fork_fn, (void *)hooked_fork, (void **)&orig_fork_fn);

        dbglog("ctor %s JBhide fs=%p/%p/%p/%p at=%p/%p attr=%p read=%p/%p dir=%p rdr_r=%p dyld=%p/%p/%p/%p dladdr=%p fork=%p sbox=%p\n",
               g_procname, (void *)orig_stat_fn, (void *)orig_lstat_fn,
               (void *)orig_access_fn, (void *)orig_fopen_fn,
               (void *)orig_fstatat_fn, (void *)orig_faccessat_fn,
               (void *)orig_getattrlist_fn, (void *)orig_readlink_fn,
               (void *)orig_readlinkat_fn, (void *)orig_opendir_fn,
               (void *)orig_readdir_r_fn,
               (void *)orig_dyld_image_count_fn, (void *)orig_dyld_get_image_name_fn,
               (void *)orig_dyld_get_image_header_fn, (void *)orig_dyld_get_image_slide_fn,
               (void *)orig_dladdr_fn, (void *)orig_fork_fn,
               (void *)orig_sandbox_check_fn);
    });
}

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
// LAYER 21: Virtual camera (VCam) — feed a user-chosen video/photo into the
// camera pipeline so a video call / camera preview shows the fake media.
//
// TECHNIQUE. The app owns an AVCaptureVideoDataOutput whose delegate receives
//   -captureOutput:didOutputSampleBuffer:fromConnection:
// on the app's own capture queue. That selector can't be %hook'd by name (the
// delegate is an app-defined class), so when the app calls
//   -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
// we runtime-swizzle THAT delegate class's didOutputSampleBuffer:. In the
// swizzle we render our current fake frame INTO the camera's CVPixelBuffer
// (Core Image handles scale + YUV/RGB conversion) and then call the app's own
// original implementation with the now-fake buffer — so the encoder, WebRTC,
// recording, and any preview the app builds FROM the data-output frames all see
// the fake video.
//
// SCOPE / LIMITATIONS (honest — do not oversell):
//   - Covers AVCaptureVideoDataOutput ONLY. AVCapturePhotoOutput (still capture)
//     and AVCaptureMovieFileOutput (direct-to-file record) are NOT covered yet.
//   - A local preview drawn by AVCaptureVideoPreviewLayer renders straight from
//     the capture connection, NOT from the data-output buffer, so the user's OWN
//     on-screen preview MAY still show the real camera even while the frames the
//     app SENDS / processes are fake. What the server / other party sees is faked.
//   - No liveness defeat: a looped clip will not satisfy active liveness
//     (blink / turn-head / depth) challenges.
//   - Orientation: video preferredTransform is applied; front-camera mirroring is
//     left to the app. May need a per-app tweak after on-device testing.
// FAIL-SAFE: any nil / unsupported-format / decode error falls through to the
// REAL frame. The hook never throws out of the app's delegate call.
// ============================================================
static os_unfair_lock g_camLock = OS_UNFAIR_LOCK_INIT;    // guards reader + still image
static BOOL        g_camEnabled  = NO;
static BOOL        g_camIsVideo   = NO;
static NSString   *g_camPath      = nil;
static NSURL      *g_camURL       = nil;
static CIContext  *g_camCtx       = nil;    // cached GPU context
static CIImage    *g_camStill     = nil;    // photo mode
static AVAssetReader          *g_camReader = nil;   // video mode
static AVAssetReaderTrackOutput *g_camOut  = nil;
static CGAffineTransform       g_camXform;          // video track preferredTransform

// Active = licensed (cfg() already gates on g_licOK) + enabled + a media path set.
static inline BOOL ci_camSpoofActive(void) {
    if (!getConfigBool(@"cameraSpoofEnabled")) return NO;
    return getConfigStr(@"cameraSpoofPath").length > 0;
}

// Re-read camera config on ctor / ReloadConfig. Drops the open reader so a newly
// applied clip is picked up on the next frame.
static void ci_camReloadFromConfig(void) {
    NSString *p = getConfigStr(@"cameraSpoofPath");
    os_unfair_lock_lock(&g_camLock);
    g_camEnabled = getConfigBool(@"cameraSpoofEnabled");
    g_camIsVideo = getConfigBool(@"cameraSpoofIsVideo");
    if (p != g_camPath && ![p isEqualToString:g_camPath]) {
        g_camPath = [p copy];
        g_camURL  = p.length ? [NSURL fileURLWithPath:p] : nil;
        g_camReader = nil; g_camOut = nil;   // force reopen
        g_camStill  = nil;
    }
    os_unfair_lock_unlock(&g_camLock);
}

static CIContext *ci_camContext(void) {
    if (!g_camCtx) g_camCtx = [CIContext contextWithOptions:nil];  // GPU-backed default
    return g_camCtx;
}

// Open (or reopen, for looping) the video reader. Caller holds g_camLock.
static BOOL ci_camOpenReaderLocked(void) {
    if (!g_camURL) return NO;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:g_camURL options:nil];
    AVAssetTrack *vt = [[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if (!vt) return NO;
    NSError *err = nil;
    AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (!r) return NO;
    NSDictionary *st = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt outputSettings:st];
    o.alwaysCopiesSampleData = NO;
    if (![r canAddOutput:o]) return NO;
    [r addOutput:o];
    if (![r startReading]) return NO;
    g_camReader = r; g_camOut = o; g_camXform = vt.preferredTransform;
    return YES;
}

// Next decoded video frame as a CIImage (loops at EOF). Caller holds g_camLock.
static CIImage *ci_camNextVideoImageLocked(void) {
    if (!g_camReader && !ci_camOpenReaderLocked()) return nil;
    CMSampleBufferRef sb = [g_camOut copyNextSampleBuffer];
    if (!sb) {                                   // EOF / read error → reopen once (loop)
        g_camReader = nil; g_camOut = nil;
        if (!ci_camOpenReaderLocked()) return nil;
        sb = [g_camOut copyNextSampleBuffer];
        if (!sb) return nil;
    }
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    CIImage *img = pb ? [CIImage imageWithCVPixelBuffer:pb] : nil;   // retains pb
    if (img && !CGAffineTransformIsIdentity(g_camXform))
        img = [img imageByApplyingTransform:g_camXform];
    CFRelease(sb);                               // CIImage keeps its own pb retain
    return img;
}

// Render the current fake frame into the camera's destination buffer. Returns NO
// (→ caller keeps the real frame) on any problem. Never throws.
static BOOL ci_camFillBuffer(CVPixelBufferRef dst) {
    if (!dst) return NO;
    os_unfair_lock_lock(&g_camLock);
    if (!g_camEnabled || !g_camURL) { os_unfair_lock_unlock(&g_camLock); return NO; }

    CIImage *src = nil;
    if (g_camIsVideo) {
        src = ci_camNextVideoImageLocked();
    } else {
        if (!g_camStill) g_camStill = [CIImage imageWithContentsOfURL:g_camURL];
        src = g_camStill;
    }
    if (!src) { os_unfair_lock_unlock(&g_camLock); return NO; }

    CGRect ext = src.extent;
    size_t dw = CVPixelBufferGetWidth(dst), dh = CVPixelBufferGetHeight(dst);
    if (ext.size.width < 1 || ext.size.height < 1 || dw < 1 || dh < 1) {
        os_unfair_lock_unlock(&g_camLock); return NO;
    }
    // Aspect-fill: scale so the source covers the whole destination, center-crop.
    CGFloat s = MAX((CGFloat)dw / ext.size.width, (CGFloat)dh / ext.size.height);
    CIImage *img = [src imageByApplyingTransform:CGAffineTransformMakeScale(s, s)];
    CGRect se = img.extent;
    CGFloat tx = ((CGFloat)dw - se.size.width) * 0.5 - se.origin.x;
    CGFloat ty = ((CGFloat)dh - se.size.height) * 0.5 - se.origin.y;
    img = [img imageByApplyingTransform:CGAffineTransformMakeTranslation(tx, ty)];
    img = [img imageByCroppingToRect:CGRectMake(0, 0, dw, dh)];

    BOOL ok = YES;
    @try {
        [ci_camContext() render:img toCVPixelBuffer:dst];
    } @catch (__unused NSException *e) {
        ok = NO;
    }
    os_unfair_lock_unlock(&g_camLock);
    return ok;
}

// --- delegate swizzle ---------------------------------------------------------
// Original IMPs keyed by the Method object (stable per class; inherited methods
// resolve to the same Method across subclasses, so keying by Method dedupes).
static SEL g_camSel = NULL;
static os_unfair_lock g_camSwzLock = OS_UNFAIR_LOCK_INIT;
static CFMutableDictionaryRef g_camIMPs = NULL;   // Method* -> original IMP

static void ci_camHookedDidOutput(id self, SEL _cmd, AVCaptureOutput *output,
                                  CMSampleBufferRef sbuf, AVCaptureConnection *conn) {
    // Overwrite the frame first (best-effort), then run the app's real code.
    if (sbuf && ci_camSpoofActive()) {
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sbuf);
        if (pb && CFGetTypeID(pb) == CVPixelBufferGetTypeID())
            ci_camFillBuffer((CVPixelBufferRef)pb);
    }
    IMP orig = NULL;
    Method m = class_getInstanceMethod([self class], _cmd);
    if (m) {
        os_unfair_lock_lock(&g_camSwzLock);
        if (g_camIMPs) orig = (IMP)CFDictionaryGetValue(g_camIMPs, m);
        os_unfair_lock_unlock(&g_camSwzLock);
    }
    if (orig)
        ((void(*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))orig)
            (self, _cmd, output, sbuf, conn);
    // else: no saved original (shouldn't happen) → drop the frame rather than crash.
}

static void ci_camSwizzleDelegateClass(Class c) {
    if (!c || !g_camSel) return;
    Method m = class_getInstanceMethod(c, g_camSel);
    if (!m) return;                              // delegate doesn't implement it
    os_unfair_lock_lock(&g_camSwzLock);
    if (!g_camIMPs) g_camIMPs = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
    IMP cur = method_getImplementation(m);
    if (cur != (IMP)ci_camHookedDidOutput) {     // guard: skip already-swizzled (incl. via superclass)
        IMP old = method_setImplementation(m, (IMP)ci_camHookedDidOutput);
        CFDictionarySetValue(g_camIMPs, (const void *)m, (const void *)old);
        dbglog("cam.swizzle %s cls=%s\n", g_procname, class_getName(c));
    }
    os_unfair_lock_unlock(&g_camSwzLock);
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    // Only swizzle when the camera feature is actually ON (licensed + enabled +
    // a clip applied). When OFF, this hook does nothing at all — the camera path
    // is fully inert, so it can never be a factor in a launch/scene-create issue.
    // If the user enables it later, re-opening the camera re-fires this and swizzles.
    if (delegate && ci_camSpoofActive()) ci_camSwizzleDelegateClass([delegate class]);
    %orig;
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
// g_wipeConsumed is defined up near ci_restoreKeychainIfFlagged (that restore sets it
// too, to keep a just-restored login from being wiped by the one-shot below).

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
    // v4.2.6: "Giu dang nhap Viber". When the host enables viberKeepLogin, DISABLE
    // the Viber one-shot device-reset entirely: skip the keychain sweep + app-group
    // wipe so Viber's device-id and login session in its shared keychain group and
    // group.viber.share.container survive launches, Change Device, and 3rd-party
    // backup/restore. Only early-returns for the Viber process — Zalo is untouched.
    // Default OFF keeps the fresh-registration reset for everyone who doesn't opt in.
    if (pn && strstr(pn, "Viber") && getConfigBool(@"viberKeepLogin")) {
        dbglog("oneShot Viber SKIP viberKeepLogin\n");
        return;
    }
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
    // v4.2.7: bound the one-shot to the time window the host stamps at Change
    // Device. wipe_deadline lives in the /var/jb config, which a 3rd-party
    // app-data backup (AppsManager) CANNOT capture. So a container restored
    // later — even one that lost the hidden .ci_gen_ack and would therefore look
    // "due" again — can never re-trigger the wipe and destroy a saved login.
    // Inside the window a real Change Device still wipes exactly once, so the
    // device is clean for a fresh registration. This is what lets "Change sach"
    // and "backup giu dang nhap" both work.
    if (due) {
        long long dl = 0;
        id dlv = getConfig(@"wipe_deadline");
        if ([dlv isKindOfClass:[NSNumber class]])      dl = [(NSNumber *)dlv longLongValue];
        else if ([dlv isKindOfClass:[NSString class]]) dl = [(NSString *)dlv longLongValue];
        if (dl > 0 && (long long)time(NULL) > dl) {
            dbglog("oneShot %s SKIP past wipe_deadline (dl=%lld now=%lld)\n",
                   g_procname, dl, (long long)time(NULL));
            due = NO;
        }
    }
    dbglog("oneShot %s bid=%s Gc=%s Gs=%s Ga=%s due=%d\n", g_procname, bid.UTF8String,
           Gc.UTF8String, Gs.length ? Gs.UTF8String : "-", Ga.length ? Ga.UTF8String : "-", (int)due);
    if (!due) return;

    g_wipeConsumed = 1;
    // 4.3.30: mark this launch as a FRESH REGISTER so isZaloFingerprintQuery blocks
    // the device-id READS Zalo makes later this session (the SecItemDelete sweep
    // below does NOT actually remove them — proven via keychain-2.db). Restore path
    // (ci_restoreKeychainIfFlagged) sets g_wipeConsumed but NOT this, so restores
    // still read their stable id.
    g_freshRegisterWipe = 1;
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
    // v4.x: Viber keeps its device/install-id in SecureStorage.data inside its
    // shared APP-GROUP container (group.viber.share.container), NOT the Data
    // container. The host's Change Device rm -rf only clears the Data container and
    // the keychain sweep above misses this file store, so the id survived and Viber
    // kept recognising the device → re-registration was blocked. Deleting the app
    // clears the app group (why delete+reinstall worked); running inside Viber we
    // hold the app-group entitlement, so wipe it here. %ctor runs before Viber opens
    // the store, so this is safe.
    if (g_procname && strstr(g_procname, "Viber")) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *grp = [fm containerURLForSecurityApplicationGroupIdentifier:
                          @"group.viber.share.container"];
        int agn = 0;
        if (grp) {
            NSArray *items = [fm contentsOfDirectoryAtURL:grp
                              includingPropertiesForKeys:nil options:0 error:nil];
            for (NSURL *it in items) {
                if ([it.lastPathComponent hasPrefix:@".com.apple.mobile_container_manager"])
                    continue;   // keep the container metadata plist
                if ([fm removeItemAtURL:it error:nil]) agn++;
            }
        }
        dbglog("oneShot Viber appgroup wiped=%d\n", agn);
    }
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
    ci_scrubJBEnvironment();
    ci_camReloadFromConfig();   // LAYER 21: pick up a just-applied/cleared camera clip
    // ReloadPrefs after a Change Device may arrive while Zalo is (re)launching —
    // consume the one-shot if this generation is due. No unconditional wipe here
    // any more (that used to destroy restored/kept accounts on every reload).
    ci_runOneShotIfDue();
}

%ctor {
    @autoreleasepool {
        // Initialize roothide-dynamic paths before any config read.
        snprintf(kDbgPath, sizeof(kDbgPath), "%s/etc/changeinfoios/v3_mg_debug.log", ci_rh_prefix());
        kConfigPath = [NSString stringWithFormat:@"%s/etc/changeinfoios/config.plist", ci_rh_prefix()];

        initMGKeyMap();
        initIntKeys();
        reloadConfig();

        const char *pn = getprogname();
        if (pn && pn[0]) g_procname = pn;
        dbglog("ctor pid=%d %s start cfg_keys=%lu\n",
               getpid(), g_procname, (unsigned long)g_config.count);

        // Diagnostic: write load status to the target app's own tmp dir
        // (always writable from inside sandbox, survives until app exit).
        // SSH: find /var/mobile/Containers/Data/Application -name ci_mg_diag.txt
        {
            NSString *tmpDir = NSTemporaryDirectory();
            if (tmpDir.length) {
                CFArrayRef ks = CFPreferencesCopyKeyList(CFSTR("com.changeinfoios"),
                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
                long cfpCount = ks ? (long)CFArrayGetCount(ks) : -1;
                if (ks) CFRelease(ks);
                NSString *inContainerPath = [NSHomeDirectory() stringByAppendingPathComponent:
                    @"Library/Preferences/com.changeinfoios.plist"];
                NSString *pt = g_config[@"ProductType"];
                NSString *mname = g_config[@"MarketingName"];
                NSString *diag = [NSString stringWithFormat:
                    @"loaded=1 t=%ld pid=%d proc=%s\n"
                    @"src=%s\n"
                    @"ProductType=%@\n"
                    @"MarketingName=%@\n"
                    @"kConfigPath=%@\n"
                    @"cfgPath_exists=%d\n"
                    @"inContainer=%@\n"
                    @"inContainer_exists=%d\n"
                    @"sharedPrefs_exists=%d\n"
                    @"cfprefs_keys=%ld\n"
                    @"g_config_count=%lu\n"
                    @"g_licOK=%d g_targetOK=%d\n"
                    @"bundleID=%@\n",
                    (long)time(NULL), getpid(), g_procname,
                    g_lastSrc,
                    pt ?: @"(nil)",
                    mname ?: @"(nil)",
                    kConfigPath,
                    [[NSFileManager defaultManager] fileExistsAtPath:kConfigPath],
                    inContainerPath,
                    [[NSFileManager defaultManager] fileExistsAtPath:inContainerPath],
                    [[NSFileManager defaultManager] fileExistsAtPath:
                        @"/var/mobile/Library/Preferences/com.changeinfoios.plist"],
                    cfpCount,
                    (unsigned long)g_config.count,
                    g_licOK, g_targetOK,
                    [[NSBundle mainBundle] bundleIdentifier]
                ];
                [diag writeToFile:[tmpDir stringByAppendingPathComponent:@"ci_mg_diag.txt"]
                       atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
        }

        // P0-2: with debug OFF (release default) remove any stale artifacts a
        // previous debug build left in THIS app's own sandbox, so the target app
        // cannot scan its own container and flag the injection.
        if (!ci_dbgEnabled()) {
            NSString *tmp = NSTemporaryDirectory();
            if (tmp.length) unlink([[tmp stringByAppendingPathComponent:@"v3_mg_debug.log"] fileSystemRepresentation]);
            NSString *home = NSHomeDirectory();
            if (home.length) unlink([[[home stringByAppendingPathComponent:@"Documents"]
                stringByAppendingPathComponent:@"viber_idquery.log"] fileSystemRepresentation]);
        }

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

        // Lightweight anti-detection stays active even when the license/profile
        // gate below is temporarily invalid. Heavy identity hooks remain gated.
        ci_installJBHideHooks();

        // Expired/missing license disables the expensive identity/keychain hooks
        // below. The small JB-hide layer above remains active because the dylib is
        // already present and otherwise exposes itself. This preserves the old
        // watchdog fix without creating an obvious unlicensed detection state.
        if (!g_licOK || !g_targetOK) {
            dbglog("ctor %s INERT license=%d target=%d (no C hooks) keys=%lu\n",
                   g_procname, g_licOK, g_targetOK, (unsigned long)g_config.count);
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
        orig_uname        = (uname_t)       dlsym(RTLD_DEFAULT, "uname");
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
            { "uname",        (void *)hooked_uname,
              (void **)&orig_uname },
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
        if (orig_uname) {
            MSHookFunction((void *)orig_uname, (void *)hooked_uname,
                           (void **)&orig_uname);
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

        // RRS keychain DUMP + RESTORE — RE-ENABLED 4.3.2 (crash-safe rewrite).
        // The 4.1.3 disable was because the replay ran too eagerly AND a stale
        // restore_*.flag rode inside the backup tar → re-fired every launch and
        // watchdog-crashed ("treo logo → văng"). Both root causes are now fixed:
        //   - dump: READ-ONLY, background queue, writes tmp/hios_keychain.plist.
        //   - restore: background queue + 3s delay (off the launch path) + a
        //     run-once mtime guard in NSUserDefaults so it applies each dump AT
        //     MOST once, and the host now --excludes restore_*.flag / dump_*.plist
        //     from backups so a flag can never ride the tar and re-trigger.
        // Required for Viber: its login credential lives in the keychain
        // (69V327AA4Z.group.viber.share.keychain); restoring only the app-group
        // container (SecureStorage.data) leaves it logged out — confirmed on-device
        // (restoreEntry.log: app-group rc=0 but NO DUMP → Viber still asked login).
        int tKcDump = 0;
        notify_register_dispatch("com.changeinfoios/dump_keychain", &tKcDump,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(int __unused x){
                @autoreleasepool { ci_dumpKeychain(); }
            });
        // Target-app one-time wiring: (1) re-apply a flagged keychain restore, and
        // (2) proactively snapshot the keychain 4s after launch on a BACKGROUND
        // queue. This replaces the 4.3.6 didEnterBackground dump, which ran
        // SYNCHRONOUSLY on the MAIN thread and risked a FrontBoard watchdog SIGKILL
        // ("văng") — that regression is gone. Off the launch/main path it can't
        // stall the app. Firing on every launch means: the user opens Viber
        // (logged in) → 4s later a fresh tmp/hios_keychain.plist (its login items,
        // incl. the SecureStorage decryption key) is on disk → the next backup
        // captures it, whether or not Viber is suspended when Backup is pressed.
        {
            const char *pnk = getprogname();
            BOOL isViber = pnk && strstr(pnk,"Viber");
            BOOL isZalo  = pnk && (strstr(pnk,"Zalo") || strstr(pnk,"zalo") ||
                                   strstr(pnk,"zingalo") || strstr(pnk,"imess"));
            if (isViber || isZalo) {
                ci_restoreKeychainIfFlagged();
                // ZJB-01/R3 FIX: the 4s auto-dump writes tmp/hios_keychain.plist on
                // EVERY launch — a tool-identifying artifact inside the app sandbox.
                // A normal Zalo Change Device (goal: clean device) must leave NO
                // dump, so gate the Zalo auto-dump behind an explicit opt-in
                // (config zaloKeepLogin, default OFF). The on-demand host dump
                // (com.changeinfoios/dump_keychain, registered above) still serves
                // an explicit backup. Viber path UNCHANGED (its login lives in the
                // keychain and needs the pre-staged snapshot).
                if (isViber || getConfigBool(@"zaloKeepLogin")) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        @autoreleasepool { ci_dumpKeychain(); }
                    });
                }
            }
        }
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
            NSString *marker = [NSString stringWithFormat:@"%s/etc/changeinfoios/v3_mg_loaded.txt", ci_rh_prefix()];
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

        // LAYER 22: cache the APNS delegate selector so the UIApplication setDelegate:
        // hook can swizzle didRegisterForRemoteNotificationsWithDeviceToken:.
        g_apnsSel = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);

        // LAYER 21: virtual camera. Cache the delegate selector + load the current
        // camera config so the AVCaptureVideoDataOutput swizzle can fire the moment
        // a target app configures its capture session. Inert until the user applies
        // a clip (ci_camSpoofActive() gate).
        g_camSel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
        ci_camReloadFromConfig();

        dbglog("ctor %s done\n", g_procname);
    }
}
