/**
 * ChangeInfoIos Tweak - iOS Device Parameter Spoofer
 * Rootless Jailbreak Compatible (Dopamine / palera1n)
 * iOS 15.0 - 16.7.x
 *
 * Build with Theos:
 *   THEOS_PACKAGE_SCHEME=rootless make package
 *
 * Config file: /var/mobile/Library/Preferences/com.changeinfoios.plist
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
// WebKit import removed v2.3.23 — WKWebView hook is #if-0'd; pulling
// WebKit into the umbrella link list caused substrate to reject the
// dylib in processes where WebKit isn't in the dyld shared cache.
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <arpa/inet.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <sys/time.h>
#import <spawn.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#if __has_include(<CoreTelephony/CTSubscriber.h>)
#import <CoreTelephony/CTSubscriber.h>
#else
@interface CTSubscriber : NSObject
- (NSString *)phoneNumber;
@end
#endif
#import <CoreLocation/CoreLocation.h>
#import <AdSupport/AdSupport.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
// Metal import removed v2.3.23 — %hook NSObject MTLDevice protocol is disabled.

// ATTrackingManager forward declaration (iOS 14+)
@interface ATTrackingManager : NSObject
+ (NSUInteger)trackingAuthorizationStatus;
+ (void)requestTrackingAuthorizationWithCompletionHandler:(void (^)(NSUInteger))completion;
@end

// DeviceCheck forward declarations (iOS 11+) — header may not be in the
// rootless SDK; declare what we hook to avoid pulling DeviceCheck.framework
// into the dylib's link list at load time. We resolve the class at runtime
// via NSClassFromString in the %ctor so the hook only installs when the
// host process actually has DeviceCheck mapped (Zalo, banking apps, etc.).
@interface DCDevice : NSObject
+ (DCDevice *)currentDevice;
- (BOOL)isSupported;
- (void)generateTokenWithCompletionHandler:(void (^)(NSData *token, NSError *error))completion;
@end

@interface DCAppAttestService : NSObject
+ (DCAppAttestService *)sharedService;
- (BOOL)isSupported;
- (void)generateKeyWithCompletionHandler:(void (^)(NSString *keyId, NSError *error))completion;
- (void)attestKey:(NSString *)keyId clientDataHash:(NSData *)hash
    completionHandler:(void (^)(NSData *attestation, NSError *error))completion;
- (void)generateAssertion:(NSString *)keyId clientDataHash:(NSData *)clientDataHash
        completionHandler:(void (^)(NSData *assertion, NSError *error))completion;
@end

// LocalAuthentication forward decl — same reasoning, avoid forced link.
@interface LAContext : NSObject
- (BOOL)canEvaluatePolicy:(NSInteger)policy error:(NSError **)error;
@property (nonatomic, readonly) NSData *evaluatedPolicyDomainState;
@end

// WebKit forward decls. Importing <WebKit/WebKit.h> would pull WebKit
// into the dylib's link list, and substrate then rejects the dylib in
// any process where WebKit isn't in the dyld shared cache (banking apps
// without an embedded browser, etc.). With these light @interface stubs
// we get full Obj-C method-call sugar without a single linkage edge.
@interface WKUserContentController : NSObject
- (void)addUserScript:(id)userScript;
@end
@interface WKUserScript : NSObject
- (instancetype)initWithSource:(NSString *)source
                 injectionTime:(NSInteger)injectionTime
              forMainFrameOnly:(BOOL)forMainFrameOnly;
@end
@interface WKWebViewConfiguration : NSObject
@property (nonatomic, strong) WKUserContentController *userContentController;
@end

// ============================================================
// SHARED C LINKAGE FOR Tweak.xm <-> Hooks.mm
// ============================================================
// When any .mm sibling is in the same Theos target, Tweak.xm is
// preprocessed and compiled as Objective-C++. Without extern "C" on
// the cross-file symbols, C++ mangling breaks link (Tweak.xm defines
// _Z9fakeLayer..., Hooks.mm expects _fakeLayer, and vice versa for
// initCLvlHooks). Forward-declaring in extern "C" forces the matching
// definitions below to inherit C linkage.
#ifdef __cplusplus
extern "C" {
#endif
extern BOOL configLoaded;
id           getConfig(NSString *key);
NSString    *getConfigStr(NSString *key);
BOOL         getConfigBool(NSString *key);
BOOL         fakeLayer(NSString *shortName);
BOOL         jbHideActive(void);
void         reloadConfigFromDisk(void);
void         initCLvlHooks(void); // defined in Hooks.mm
#ifdef __cplusplus
}
#endif

// ============================================================
// CONFIG LOADING
// ============================================================
static NSString *const kConfigPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
static NSDictionary *spoofConfig = nil;
BOOL configLoaded = NO;

// v2.3.26: hot-path — called from every Logos hook via fakeLayer().
// Uses a sticky cache computed once per process so we don't rebuild
// NSArray/NSString comparisons on every frame of every spoofed getter.
extern BOOL g_bundleTargeted;
static BOOL g_targetCacheReady = NO;

static BOOL isCurrentBundleTargeted(void) {
    if (g_targetCacheReady) return g_bundleTargeted;
    // Hooks can fire before %ctor finishes (e.g. +[NSObject initialize]
    // running from linked framework load). Compute lazily on first call
    // if the ctor hasn't set it yet.
    id targets = getConfig(@"targetBundles");
    if (![targets isKindOfClass:[NSArray class]] || ((NSArray *)targets).count == 0) {
        g_bundleTargeted = YES;
        g_targetCacheReady = YES;
        return YES;
    }
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length == 0) {
        g_bundleTargeted = NO;
        g_targetCacheReady = YES;
        return NO;
    }
    for (id item in (NSArray *)targets) {
        if ([item isKindOfClass:[NSString class]] && [(NSString *)item isEqualToString:bid]) {
            g_bundleTargeted = YES;
            g_targetCacheReady = YES;
            return YES;
        }
    }
    g_bundleTargeted = NO;
    g_targetCacheReady = YES;
    return NO;
}

// Forward decl — async fallback path, see below.
static void ci_loadConfigViaCFPreferencesAsync(void);
static NSString *const kSharedConfigPath = @"/var/jb/etc/changeinfoios/config.plist";

// Thread-local bypass for our own SecItem* hooks. When we dump or restore
// keychain entries from inside the tweak we don't want our READ-blocker or
// WRITE-blocker hooks (in Hooks.mm) to interfere. Hook bodies check this
// flag and pass through to %orig when non-zero. Declared up here so the
// keychain helpers below + Hooks.mm extern reference both see it.
__thread int g_ci_skipKeychainHook = 0;

// ====== KEYCHAIN BACKUP / RESTORE ======
// User flow we're solving: register Zalo acc A, take RRS backup, Reset Data,
// register acc B (Zalo overwrites keychain session token), now restore A.
// Container restore brings A's preferences back, but the SHARED keychain at
// /var/Keychains/keychain-2.db has B's session token (not A's). Zalo's launch
// reads the keychain → sees token for B (or no match for A) → forces login.
//
// Fix: dump the host-app's per-bundle keychain entries to a plist on every
// launch (overwritten with current state), include that file in RRS backups
// (already covered by tar of /var/jb/etc/changeinfoios/), and on restore,
// drop a flag file that tells the next launch's tweak %ctor to wipe the
// current entries + reapply the snapshot.

#import <Security/Security.h>

// IMPORTANT: must live in NSTemporaryDirectory() (the calling bundle's
// own /<container>/tmp/), NOT under /var/jb/etc/changeinfoios. Confirmed
// 2026-05-07 that App Store app sandboxes (Zalo et al) can READ /var/jb
// but cannot WRITE there — earlier loaded_<bid>.txt drop into that same
// dir silently failed for the exact same reason. NSTemporaryDirectory()
// is per-bundle scoped by iOS itself, so we don't need bid in the name;
// the host app's tar archives the whole container (incl. tmp/) so the
// dump rides along into RRS, and restore's UUID-rebind copy lands it in
// the new container's tmp/ automatically.
static NSString *ci_keychainBackupPath(NSString *bid) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length == 0) return nil;
    return [tmp stringByAppendingPathComponent:@"hios_keychain.plist"];
}
static NSString *ci_keychainRestoreFlag(NSString *bid) {
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length == 0) return nil;
    return [tmp stringByAppendingPathComponent:@"hios_keychain_restore.flag"];
}

static NSDictionary *ci_encodeKCEntry(NSDictionary *attr) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id key in attr) {
        id val = attr[key];
        if ([val isKindOfClass:[NSData class]]) {
            out[key] = @{@"__t": @"D", @"__b": [val base64EncodedStringWithOptions:0]};
        } else if ([val isKindOfClass:[NSDate class]]) {
            out[key] = @{@"__t": @"T", @"__e": @([(NSDate *)val timeIntervalSince1970])};
        } else if ([val isKindOfClass:[NSString class]] || [val isKindOfClass:[NSNumber class]]) {
            out[key] = val;
        }
        // Skip CFTypeRef wrappers / unknown types — SecItemAdd would reject them anyway.
    }
    return out;
}
static NSMutableDictionary *ci_decodeKCEntry(NSDictionary *enc) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (id key in enc) {
        id v = enc[key];
        if ([v isKindOfClass:[NSDictionary class]] && v[@"__t"]) {
            NSString *t = v[@"__t"];
            if ([t isEqualToString:@"D"]) {
                NSData *d = [[NSData alloc] initWithBase64EncodedString:v[@"__b"] options:0];
                if (d) out[key] = d;
            } else if ([t isEqualToString:@"T"]) {
                out[key] = [NSDate dateWithTimeIntervalSince1970:[v[@"__e"] doubleValue]];
            }
        } else {
            out[key] = v;
        }
    }
    return out;
}

static void ci_dumpKeychain(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;
        g_ci_skipKeychainHook++;
        NSMutableArray *all = [NSMutableArray array];
        NSArray *classes = @[
            (__bridge NSString *)kSecClassGenericPassword,
            (__bridge NSString *)kSecClassInternetPassword,
        ];
        for (NSString *cls in classes) {
            NSDictionary *q = @{
                (__bridge NSString *)kSecClass:           cls,
                (__bridge NSString *)kSecMatchLimit:      (__bridge NSString *)kSecMatchLimitAll,
                (__bridge NSString *)kSecReturnAttributes:@YES,
                (__bridge NSString *)kSecReturnData:      @YES,
            };
            CFTypeRef result = NULL;
            OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
            if (s != errSecSuccess) continue;
            NSArray *items = (__bridge_transfer NSArray *)result;
            for (NSDictionary *item in items) {
                NSMutableDictionary *e = [item mutableCopy];
                e[@"__class"] = cls;
                [all addObject:ci_encodeKCEntry(e)];
            }
        }
        g_ci_skipKeychainHook--;
        NSString *path = ci_keychainBackupPath(bid);
        if (path.length == 0) return;
        BOOL ok = [all writeToFile:path atomically:YES];
        NSLog(@"[ChangeInfoIos] keychain dump: %lu entries %@ %@",
              (unsigned long)all.count, ok ? @"→" : @"FAILED writing", path);
    }
}

// Returns YES if a restore was performed (caller should suppress the next
// dump so we don't immediately overwrite the just-restored snapshot).
static BOOL ci_restoreKeychainIfFlagged(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return NO;
        NSString *flag = ci_keychainRestoreFlag(bid);
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:flag]) return NO;

        NSString *path = ci_keychainBackupPath(bid);
        NSArray *all = [NSArray arrayWithContentsOfFile:path];
        if (![all isKindOfClass:[NSArray class]]) {
            [fm removeItemAtPath:flag error:nil];
            return NO;
        }

        g_ci_skipKeychainHook++;

        // Wipe current bundle's existing entries — for each class, delete
        // EVERY entry. Per-bundle scoping is implicit: the keychain access
        // group is set by Apple based on the calling app's entitlements,
        // so SecItemDelete only sees this bundle's rows.
        for (NSString *cls in @[(__bridge NSString *)kSecClassGenericPassword,
                                (__bridge NSString *)kSecClassInternetPassword]) {
            NSDictionary *q = @{ (__bridge NSString *)kSecClass: cls };
            SecItemDelete((__bridge CFDictionaryRef)q);
        }

        // Read-only / system-managed attrs that SecItemAdd rejects.
        NSArray *stripKeys = @[
            (__bridge NSString *)kSecAttrCreationDate,
            (__bridge NSString *)kSecAttrModificationDate,
            (__bridge NSString *)kSecAttrAccessGroup,
            @"persistref", @"agrp", @"musr", @"sha1", @"cdat", @"mdat", @"pdmn",
        ];

        NSUInteger added = 0;
        for (NSDictionary *enc in all) {
            if (![enc isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *e = ci_decodeKCEntry(enc);
            NSString *cls = e[@"__class"];
            if (!cls) continue;
            [e removeObjectForKey:@"__class"];
            for (NSString *k in stripKeys) [e removeObjectForKey:k];
            e[(__bridge NSString *)kSecClass] = cls;
            OSStatus s = SecItemAdd((__bridge CFDictionaryRef)e, NULL);
            if (s == errSecSuccess) added++;
        }

        g_ci_skipKeychainHook--;

        [fm removeItemAtPath:flag error:nil];
        NSLog(@"[ChangeInfoIos] keychain restore: %lu/%lu entries reapplied",
              (unsigned long)added, (unsigned long)all.count);
        return YES;
    }
}

static void ci_onDumpKeychainNotification(CFNotificationCenterRef center,
                                          void *observer,
                                          CFStringRef name,
                                          const void *object,
                                          CFDictionaryRef userInfo) {
    ci_dumpKeychain();
}

void reloadConfigFromDisk(void) {
    @autoreleasepool {
        // Strategy 0 — sandbox-friendly shared path. Verified live via probe
        // dylib inside AIDA64: /var/jb/etc/changeinfoios/* IS readable from
        // App Store app sandboxes, while /var/mobile/Library/Preferences IS
        // NOT. Host app writes the config here in parallel with the legacy
        // path, so this lookup wins for sandboxed tweaks.
        NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:kSharedConfigPath];

        // Strategy 1 — direct read of the legacy path. Fast, works in system
        // processes (backupd, etc.) and any tweak host with a permissive
        // sandbox. Will silently fail in App Store apps — that's expected.
        if (!config) {
            config = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
        }

        // Strategy 2 — rootless mirror path. Some Dopamine 2 sandbox profiles
        // redirect /var/mobile/Library/Preferences for App Store apps; this
        // alternate prefix is accessible without sandbox permission for that
        // path. Cheap to try synchronously.
        if (!config) {
            config = [NSDictionary dictionaryWithContentsOfFile:
                @"/var/jb/var/mobile/Library/Preferences/com.changeinfoios.plist"];
        }

        if (config) {
            spoofConfig = [config copy];
            configLoaded = YES;
        } else {
            spoofConfig = nil;
            configLoaded = NO;
            // Strategy 3 — cfprefsd over XPC. App Store apps with tight
            // sandboxes can't read /var/mobile/Library/Preferences directly,
            // but cfprefsd (on the receiving end of CFPreferencesCopyMultiple)
            // can. We CANNOT call this synchronously from inside %ctor — the
            // XPC reply needs the main thread runloop, which hasn't been
            // started yet, so the call deadlocks the bootstrap thread (this
            // hung opainject too). Hand it off to a background queue: hooks
            // will fall through to %orig until the load lands a moment later.
            ci_loadConfigViaCFPreferencesAsync();
        }
    }
}

static void ci_loadConfigViaCFPreferencesAsync(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                CFStringRef appID = CFSTR("com.changeinfoios");
                CFArrayRef keys = CFPreferencesCopyKeyList(appID, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
                if (keys && CFArrayGetCount(keys) > 0) {
                    CFDictionaryRef dict = CFPreferencesCopyMultiple(keys, appID, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
                    if (dict) {
                        spoofConfig = [(__bridge NSDictionary *)dict copy];
                        configLoaded = YES;
                        CFRelease(dict);
                        NSLog(@"[ChangeInfoIos] Config loaded (cfprefsd async): %lu keys", (unsigned long)spoofConfig.count);
                    }
                }
                if (keys) CFRelease(keys);
            }
        });
    });
}

static void loadConfig(void) {
    reloadConfigFromDisk();
    if (configLoaded) {
        NSLog(@"[ChangeInfoIos] Config loaded: %lu keys", (unsigned long)spoofConfig.count);
    } else {
        NSLog(@"[ChangeInfoIos] No config file at %@", kConfigPath);
    }
}

static void ci_wipeContainerIfScheduled(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;
        NSString *key = [@"wipe_counter_" stringByAppendingString:bid];
        id v = getConfig(key);
        long long counter = [v respondsToSelector:@selector(longLongValue)] ? [v longLongValue] : 0;
        if (counter <= 0) return;

        NSString *home = NSHomeDirectory();
        if (home.length == 0) return;
        NSString *marker = [home stringByAppendingPathComponent:@".ci_last_wipe"];
        long long last = 0;
        NSString *existing = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
        if (existing) last = [existing longLongValue];
        if (counter <= last) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *subdirs = @[@"Documents", @"Library/Caches", @"Library/Preferences",
                             @"Library/Cookies", @"Library/WebKit", @"Library/Application Support", @"tmp"];
        NSUInteger removed = 0;
        for (NSString *d in subdirs) {
            NSString *full = [home stringByAppendingPathComponent:d];
            NSArray *items = [fm contentsOfDirectoryAtPath:full error:nil];
            for (NSString *item in items) {
                if ([item isEqualToString:@".ci_last_wipe"]) continue;
                NSError *err = nil;
                if ([fm removeItemAtPath:[full stringByAppendingPathComponent:item] error:&err]) removed++;
            }
        }
        [[NSString stringWithFormat:@"%lld", counter] writeToFile:marker
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[ChangeInfoIos] Wiped %@ (counter=%lld, items=%lu)", bid, counter, (unsigned long)removed);
    }
}

static void onPrefsDarwinNotify(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadConfigFromDisk();
    NSLog(@"[ChangeInfoIos] Prefs reloaded (%lu keys)", (unsigned long)(spoofConfig ? spoofConfig.count : 0));
}

id getConfig(NSString *key) {
    if (!configLoaded) reloadConfigFromDisk();
    return spoofConfig ? spoofConfig[key] : nil;
}

NSString *getConfigStr(NSString *key) {
    id val = getConfig(key);
    if ([val isKindOfClass:[NSString class]]) return val;
    if (val) return [NSString stringWithFormat:@"%@", val];
    return nil;
}

BOOL getConfigBool(NSString *key) {
    id val = getConfig(key);
    if (val == nil) {
        if ([key hasPrefix:@"fake_"]) return YES;
        return NO;
    }
    return [val respondsToSelector:@selector(boolValue)] ? [val boolValue] : NO;
}

// Type-safe unsigned converters. NSString does NOT implement
// `unsignedIntegerValue` / `unsignedLongLongValue` — sending those selectors
// to a string raises an NSInvalidArgumentException via __forwarding__ that
// then explodes through `_copyDescription` during scene init (AIDA64 SIGABRT
// post-Reset Data). Old config snapshots persist string forms of numeric
// keys forever, so any hook reading them must coerce safely.
static unsigned long long ci_toULL(id v) {
    if (!v) return 0;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v unsignedLongLongValue];
    if ([v isKindOfClass:[NSString class]]) return (unsigned long long)[(NSString *)v longLongValue];
    return 0;
}
static NSUInteger ci_toUInteger(id v) { return (NSUInteger)ci_toULL(v); }

/* Plist booleans fake_<name> — missing key defaults to ON.
   Short names: uiddevice, hardware, sysctl, ... */
//
// Recursion guard — Telegram (12.6.3) crashed at launch with EXC_BAD_ACCESS
// at SP boundary because:
//   our %hook NSBundle infoDictionary  →  fakeLayer()
//      →  isCurrentBundleTargeted()
//          →  [[NSBundle mainBundle] bundleIdentifier]   // reads InfoDict
//             →  -[NSBundle infoDictionary]              // hits OUR hook
//                →  fakeLayer()  →  …  →  stack overflow
// Per-thread guard breaks the loop: any nested fakeLayer call returns NO
// immediately, the outer hook returns %orig, the original caller proceeds.
static __thread int g_inFakeLayer = 0;

BOOL fakeLayer(NSString *shortName) {
    if (g_inFakeLayer) return NO;
    g_inFakeLayer++;
    BOOL out = NO;
    // Emergency runtime kill-switch — set _ci_skipall=YES via SSH to make
    // every %hook fall through to %orig without re-installing the dylib.
    // Lets us bisect "is the crash from a specific hook return value, or
    // from %ctor/MSHookFunction itself" without a build cycle.
    if (!getConfigBool(@"_ci_skipall") && isCurrentBundleTargeted()) {
        NSString *full = [NSString stringWithFormat:@"fake_%@", shortName];
        out = getConfigBool(full);
    }
    g_inFakeLayer--;
    return out;
}

BOOL jbHideActive(void) {
    if (!fakeLayer(@"jbhide")) return NO;
    id h = getConfig(@"hideJailbreak");
    if (h == nil) return NO;
    return [h boolValue];
}

// ============================================================
// LAYER 1: UIDevice HOOKS  (fake_uiddevice)
// ============================================================
%hook UIDevice

- (NSString *)name {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"deviceName");
    return val ?: %orig;
}

- (NSString *)model {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"deviceModel");
    return val ?: %orig;
}

- (NSString *)localizedModel {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"localizedModel");
    return val ?: %orig;
}

- (NSString *)systemName {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"systemName");
    return val ?: %orig;
}

- (NSString *)systemVersion {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"systemVersion");
    return val ?: %orig;
}

- (NSUUID *)identifierForVendor {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"identifierForVendor");
    if (val) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:val];
        if (uuid) return uuid;
    }
    return %orig;
}

- (float)batteryLevel {
    if (!fakeLayer(@"uiddevice")) return %orig;
    id val = getConfig(@"batteryLevel");
    if (val) return [val floatValue];
    return %orig;
}

- (UIDeviceBatteryState)batteryState {
    if (!fakeLayer(@"uiddevice")) return %orig;
    id val = getConfig(@"batteryState");
    if (val) return (UIDeviceBatteryState)[val integerValue];
    return %orig;
}

- (BOOL)isMultitaskingSupported {
    return YES;
}

- (UIUserInterfaceIdiom)userInterfaceIdiom {
    return UIUserInterfaceIdiomPhone;
}

%end

// ============================================================
// LAYER 2: MGCopyAnswer / libMobileGestalt
// Hook MGCopyAnswer_internal for deep spoofing
// ============================================================
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef property);
static MGCopyAnswer_t orig_MGCopyAnswer = NULL;

// MGGetBoolAnswer - returns bool for properties like "GameCenterEnabled"
typedef BOOL (*MGGetBoolAnswer_t)(CFStringRef property);
static MGGetBoolAnswer_t orig_MGGetBoolAnswer = NULL;

// MGGetStringAnswer - returns string for properties like "DeviceName"
typedef CFTypeRef (*MGGetStringAnswer_t)(CFStringRef property);
static MGGetStringAnswer_t orig_MGGetStringAnswer = NULL;

static NSDictionary *mgKeyMap = nil;

static void initMGKeyMap() {
    if (mgKeyMap) return;
    mgKeyMap = @{
        @"UniqueDeviceID":       @"UniqueDeviceID",
        @"SerialNumber":         @"SerialNumber",
        @"UniqueChipID":         @"UniqueChipID",
        @"InternationalMobileEquipmentIdentity":  @"InternationalMobileEquipmentIdentity",
        @"InternationalMobileEquipmentIdentity2": @"InternationalMobileEquipmentIdentity2",
        @"MobileEquipmentIdentifier":             @"MobileEquipmentIdentifier",
        @"IntegratedCircuitCardIdentity":          @"IntegratedCircuitCardIdentity",
        @"IntegratedCircuitCardIdentity2":         @"IntegratedCircuitCardIdentity2",
        @"PhoneNumber":          @"PhoneNumber",
        @"ProductType":          @"ProductType",
        @"HardwareModel":        @"HardwareModel",
        @"HWModelStr":           @"HWModelStr",
        @"ModelNumber":          @"ModelNumber",
        @"RegionCode":           @"RegionCode",
        @"RegionInfo":           @"RegionInfo",
        @"WiFiAddress":          @"WiFiAddress",
        @"BluetoothAddress":     @"BluetoothAddress",
        @"EthernetAddress":      @"EthernetAddress",
        @"BoardId":              @"BoardId",
        @"HardwarePlatform":     @"BoardId",
        @"ChipID":               @"ChipID",
        @"FirmwareVersion":      @"FirmwareVersion",
        @"BasebandVersion":      @"BasebandVersion",
        @"BasebandSerialNumber": @"BasebandSerialNumber",
        @"BasebandChipId":       @"BasebandChipId",
        @"BasebandCertId":       @"BasebandCertId",
        @"BuildVersion":         @"BuildVersion",
        @"ProductVersion":       @"ProductVersion",
        @"DeviceColor":          @"DeviceColor",
        @"DeviceEnclosureColor": @"DeviceEnclosureColor",
        @"DiskUsage":            @"DiskUsage",
        @"TotalDiskCapacity":    @"TotalDiskCapacity",
        @"TotalSystemAvailable": @"TotalSystemAvailable",
        @"BatteryCurrentCapacity": @"BatteryCurrentCapacity",
        @"BatteryIsCharging":    @"BatteryIsCharging",
        @"BatterySerialNumber":  @"BatterySerialNumber",
        @"BootNonce":            @"BootNonce",
        @"DeviceName":           @"DeviceNameMG",
        @"UserAssignedDeviceName": @"UserAssignedDeviceName",
        @"MarketingName":        @"MarketingName",
        @"AirplaneMode":         @"AirplaneMode",
        @"MobileSubscriberCountryCode": @"MobileSubscriberCountryCode",
        @"MobileSubscriberNetworkCode": @"MobileSubscriberNetworkCode",
        @"SIMTrayStatus":        @"SIMTrayStatus",
    };
}

static int64_t configValueAsMGInteger(NSString *configKey) {
    id val = getConfig(configKey);
    if (!val) return 0;
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val longLongValue];
    if ([val isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0) return 0;
        if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
            unsigned long long u = 0;
            NSScanner *sc = [NSScanner scannerWithString:s];
            if ([sc scanHexLongLong:&u]) return (int64_t)u;
        }
        return (int64_t)[s longLongValue];
    }
    return 0;
}

// Re-entrancy guard for MG hooks. ROOT CAUSE of the previous crash chain:
// our NSLog calls (and any autorelease-pool drain inside the hook) trigger
// CFLog → ASL → libtrace → MGCopyAnswer for the syslog prefix → re-enters
// our hook → if the inner call hits NSLog again → infinite recursion →
// SIGBUS / portLoop fault. With this thread-local guard, the inner call
// passes straight through to orig, breaking the loop.
__thread int g_ci_inMGHook = 0;

static CFTypeRef hooked_MGCopyAnswer(CFStringRef property) {
    // Guard MUST be set BEFORE any code that can trigger another MG read.
    // fakeLayer() / getConfigBool() / reloadConfigFromDisk() all call
    // through CFString routines (stringByAppendingString → CFString
    // allocation → internal MG queries for "ProductVersion" etc).
    // Without setting the guard first, that nested MG read sees guard=0
    // and re-enters our hook, calling fakeLayer again — infinite
    // recursion → stack overflow → SIGSEGV at STACK GUARD page (root
    // cause of the post-register crash chain).
    if (g_ci_inMGHook) return orig_MGCopyAnswer(property);
    g_ci_inMGHook = 1;

    CFTypeRef result = NULL;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded || !property) {
        result = orig_MGCopyAnswer(property);
        g_ci_inMGHook = 0;
        return result;
    }
    if (!fakeLayer(@"hardware") || getConfigBool(@"_ci_skip_mg")) {
        result = orig_MGCopyAnswer(property);
        g_ci_inMGHook = 0;
        return result;
    }
    initMGKeyMap();

    NSString *key = (__bridge NSString *)property;
    if ([key isEqualToString:@"ProductVersion"] || [key isEqualToString:@"BuildVersion"]) {
        if (!fakeLayer(@"sysosversion")) return orig_MGCopyAnswer(property);
    }

    NSString *configKey = mgKeyMap[key];
    CFTypeRef result = NULL;

    if (configKey) {
        NSString *spoofedVal = getConfigStr(configKey);
        if (spoofedVal) {
            if ([key isEqualToString:@"BatteryIsCharging"] || [key isEqualToString:@"AirplaneMode"]) {
                if (getConfig(configKey)) {
                    result = (__bridge_retained CFTypeRef)@(getConfigBool(configKey));
                }
            } else {
                NSSet *mgIntKeys = [NSSet setWithObjects:
                    @"TotalDiskCapacity", @"TotalSystemAvailable", @"DiskUsage",
                    @"BatteryCurrentCapacity", @"ChipID", @"BoardId", @"HardwarePlatform",
                    @"UniqueChipID", nil];
                if ([mgIntKeys containsObject:key]) {
                    int64_t v = configValueAsMGInteger(configKey);
                    result = (__bridge_retained CFTypeRef)@(v);
                } else {
                    result = (__bridge_retained CFTypeRef)spoofedVal;
                }
            }
        }
    }

    // Verbose-per-call logging was causing device-wide lag: MGCopyAnswer
    // is invoked thousands of times/sec across every process we inject.
    // Log each (key, path) the FIRST time only — enough to diagnose which
    // properties an app reads without flooding syslog.
    static NSMutableSet *loggedSpoof = nil;
    static NSMutableSet *loggedPass  = nil;
    static dispatch_once_t logOnce;
    dispatch_once(&logOnce, ^{
        loggedSpoof = [NSMutableSet new];
        loggedPass  = [NSMutableSet new];
    });

    if (result) {
        @synchronized (loggedSpoof) {
            if (![loggedSpoof containsObject:key]) {
                [loggedSpoof addObject:key];
                NSLog(@"[ChangeInfoIos] MGCopyAnswer[%@] SPOOFED (first)", key);
            }
        }
        g_ci_inMGHook = 0;
        return result;
    }

    CFTypeRef orig = orig_MGCopyAnswer(property);
    @synchronized (loggedPass) {
        if (![loggedPass containsObject:key]) {
            [loggedPass addObject:key];
            NSLog(@"[ChangeInfoIos] MGCopyAnswer[%@] passthrough (first)", key);
        }
    }
    g_ci_inMGHook = 0;
    return orig;
}

// ============================================================
// MGGetBoolAnswer hook - handles bool properties
// ============================================================
static BOOL hooked_MGGetBoolAnswer(CFStringRef property) {
    if (g_ci_inMGHook) return orig_MGGetBoolAnswer(property);
    g_ci_inMGHook = 1;  // Set BEFORE any fakeLayer/getConfig call (see CopyAnswer note)

    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded || !property) {
        BOOL r = orig_MGGetBoolAnswer(property);
        g_ci_inMGHook = 0;
        return r;
    }
    if (!fakeLayer(@"hardware") || getConfigBool(@"_ci_skip_mg")) {
        BOOL r = orig_MGGetBoolAnswer(property);
        g_ci_inMGHook = 0;
        return r;
    }
    NSString *key = (__bridge NSString *)property;
    NSString *configKey = mgKeyMap[key];

    if (configKey) {
        id val = getConfig(configKey);
        if (val) {
            if ([val isKindOfClass:[NSNumber class]]) {
                BOOL r = [val boolValue];
                g_ci_inMGHook = 0;
                return r;
            }
            if ([val isKindOfClass:[NSString class]]) {
                NSString *s = (NSString *)val;
                if ([s isEqualToString:@"true"] || [s isEqualToString:@"YES"] || [s isEqualToString:@"1"]) {
                    g_ci_inMGHook = 0; return YES;
                }
                if ([s isEqualToString:@"false"] || [s isEqualToString:@"NO"] || [s isEqualToString:@"0"]) {
                    g_ci_inMGHook = 0; return NO;
                }
            }
        }
    }

    g_ci_inMGHook = 0;
    return orig_MGGetBoolAnswer(property);
}

// ============================================================
// MGGetStringAnswer hook - handles string properties
// ============================================================
static CFTypeRef hooked_MGGetStringAnswer(CFStringRef property) {
    if (g_ci_inMGHook) return orig_MGGetStringAnswer(property);
    g_ci_inMGHook = 1;  // Set BEFORE any fakeLayer/getConfig call

    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded || !property) {
        CFTypeRef r = orig_MGGetStringAnswer(property);
        g_ci_inMGHook = 0;
        return r;
    }
    if (!fakeLayer(@"hardware") || getConfigBool(@"_ci_skip_mg")) {
        CFTypeRef r = orig_MGGetStringAnswer(property);
        g_ci_inMGHook = 0;
        return r;
    }
    initMGKeyMap();

    NSString *key = (__bridge NSString *)property;
    NSString *configKey = mgKeyMap[key];

    if (configKey) {
        NSString *val = getConfigStr(configKey);
        if (val) {
            g_ci_inMGHook = 0;
            return (__bridge_retained CFTypeRef)val;
        }
    }

    g_ci_inMGHook = 0;
    return orig_MGGetStringAnswer(property);
}

// ============================================================
// LAYER 3: IOKit Registry Hooks
// ============================================================
typedef CFTypeRef (*IORegCreateCFProp_t)(mach_port_t entry, CFStringRef key, CFAllocatorRef alloc, uint32_t options);
static IORegCreateCFProp_t orig_IORegistryEntryCreateCFProperty = NULL;

static NSDictionary *ioKeyMap = nil;

static void initIOKeyMap() {
    if (ioKeyMap) return;
    ioKeyMap = @{
        @"IOPlatformSerialNumber": @"IOPlatformSerialNumber",
        @"IOPlatformUUID":         @"IOPlatformUUID",
        @"board-id":               @"IOBoardId",
        @"product-name":           @"IOProductName",
        @"model":                  @"IOModel",
        @"serial-number":          @"IODeviceTreeSerial",
        @"mlb-serial-number":      @"IODeviceTreeMLBSerial",
    };
}

static CFTypeRef hooked_IORegistryEntryCreateCFProperty(mach_port_t entry, CFStringRef key, CFAllocatorRef alloc, uint32_t options) {
    if (!configLoaded) reloadConfigFromDisk();
    if (!fakeLayer(@"hardware")) return orig_IORegistryEntryCreateCFProperty(entry, key, alloc, options);
    if (configLoaded && key) {
        initIOKeyMap();
        NSString *keyStr = (__bridge NSString *)key;
        NSString *configKey = ioKeyMap[keyStr];
        if (configKey) {
            NSString *val = getConfigStr(configKey);
            if (val) {
                if ([keyStr isEqualToString:@"serial-number"] || [keyStr isEqualToString:@"mlb-serial-number"]) {
                    NSData *data = [val dataUsingEncoding:NSUTF8StringEncoding];
                    return (__bridge_retained CFTypeRef)data;
                }
                return (__bridge_retained CFTypeRef)val;
            }
        }
    }
    return orig_IORegistryEntryCreateCFProperty(entry, key, alloc, options);
}

// ============================================================
// LAYER 4: CoreTelephony Hooks
// ============================================================
%hook CTCarrier

- (NSString *)carrierName {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierName");
    return val ?: %orig;
}

- (NSString *)mobileCountryCode {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierMCC");
    return val ?: %orig;
}

- (NSString *)mobileNetworkCode {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierMNC");
    return val ?: %orig;
}

- (NSString *)isoCountryCode {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierISO");
    return val ?: %orig;
}

- (BOOL)allowsVOIP {
    if (!fakeLayer(@"network")) return %orig;
    id val = getConfig(@"carrierAllowsVOIP");
    if (val) return [val boolValue];
    return %orig;
}

%end

%hook CTTelephonyNetworkInfo

- (NSString *)currentRadioAccessTechnology {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierRadioAccess");
    return val ?: %orig;
}

%end

// DISABLED v2.3.23: CTSubscriber is private and its class symbol may not
// exist in every target process; Logos lookup triggered on %ctor can cause
// dylib load to be marked faulty. Restore once main inject path is green.
// %hook CTSubscriber
// - (NSString *)phoneNumber {
//     if (!fakeLayer(@"network")) return %orig;
//     NSString *val = getConfigStr(@"PhoneNumber");
//     return val.length > 0 ? val : %orig;
// }
// %end

// ============================================================
// LAYER 5: Network / SystemConfiguration
// ============================================================
%hookf(CFDictionaryRef, CNCopyCurrentNetworkInfo, CFStringRef interfaceName) {
    CFDictionaryRef orig = %orig;
    if (!fakeLayer(@"wifi")) return orig;

    NSString *ssid = getConfigStr(@"wifiSSID");
    NSString *bssid = getConfigStr(@"wifiBSSID");

    if (ssid || bssid) {
        NSMutableDictionary *dict = orig ? [(__bridge NSDictionary *)orig mutableCopy] : [NSMutableDictionary dictionary];
        if (ssid)  dict[(__bridge NSString *)kCNNetworkInfoKeySSID]  = ssid;
        if (bssid) dict[(__bridge NSString *)kCNNetworkInfoKeyBSSID] = bssid;
        return (__bridge_retained CFDictionaryRef)dict;
    }

    return orig;
}

// ============================================================
// LAYER 6: Advertising Hooks
// ============================================================
%hook ASIdentifierManager

- (NSUUID *)advertisingIdentifier {
    if (!fakeLayer(@"ads")) return %orig;
    NSString *val = getConfigStr(@"advertisingIdentifier");
    if (val) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:val];
        if (uuid) return uuid;
    }
    return %orig;
}

- (BOOL)isAdvertisingTrackingEnabled {
    if (!fakeLayer(@"ads")) return %orig;
    id val = getConfig(@"isAdvertisingTrackingEnabled");
    if (val) return [val boolValue];
    return %orig;
}

%end

// ============================================================
// LAYER 7: Screen / Display Hooks
// ============================================================
%hook UIScreen

// Screen geometry has to stay internally consistent — UIKit asserts that
// bounds × scale ≈ nativeBounds during scene setup; if they disagree it
// throws NSInternalInconsistencyException which is what was crashing AIDA64
// (and any other targeted app) at launch. Older builds gated nativeBounds /
// nativeScale on a separate `fake_realscreen` flag that defaulted OFF, so
// bounds returned the fake iPhone 13 size (390×844) while nativeBounds
// stayed at the real iPhone X native (1125×2436) — UIKit asserted, scene
// init aborted, SIGABRT. Drop the realscreen gate: if fake_screen is on
// we spoof the whole geometry as one consistent set.

- (CGRect)bounds {
    if (!fakeLayer(@"screen")) return %orig;
    id w = getConfig(@"screenWidth");
    id h = getConfig(@"screenHeight");
    if (w && h) {
        return CGRectMake(0, 0, [w floatValue], [h floatValue]);
    }
    return %orig;
}

- (CGRect)nativeBounds {
    if (!fakeLayer(@"screen")) return %orig;
    id w = getConfig(@"nativeScreenWidth");
    id h = getConfig(@"nativeScreenHeight");
    if (w && h) {
        return CGRectMake(0, 0, [w floatValue], [h floatValue]);
    }
    // Fallback: derive from bounds × scale so we never return real
    // nativeBounds when bounds is faked — that mismatch is what UIKit
    // asserts on. Using config-driven values is preferred (consistent
    // with the device preset) but if those keys somehow aren't set,
    // synthesise them on the fly.
    id bw = getConfig(@"screenWidth");
    id bh = getConfig(@"screenHeight");
    id sc = getConfig(@"screenScale");
    if (bw && bh && sc) {
        CGFloat s = [sc floatValue];
        return CGRectMake(0, 0, [bw floatValue] * s, [bh floatValue] * s);
    }
    return %orig;
}

- (CGFloat)scale {
    if (!fakeLayer(@"screen")) return %orig;
    id val = getConfig(@"screenScale");
    if (val) return [val floatValue];
    return %orig;
}

- (CGFloat)nativeScale {
    if (!fakeLayer(@"screen")) return %orig;
    id val = getConfig(@"nativeScale");
    if (val) return [val floatValue];
    // Fallback to scale so nativeScale never disagrees with scale.
    id sc = getConfig(@"screenScale");
    if (sc) return [sc floatValue];
    return %orig;
}

%end

// ============================================================
// LAYER 8: NSProcessInfo Hooks
// ============================================================
%hook NSProcessInfo

- (NSString *)hostName {
    if (!fakeLayer(@"processinfo")) return %orig;
    NSString *val = getConfigStr(@"processHostName");
    return val ?: %orig;
}

- (NSUInteger)processorCount {
    if (!fakeLayer(@"processinfo")) return %orig;
    id val = getConfig(@"processorCount");
    if (val) return ci_toUInteger(val);
    return %orig;
}

- (unsigned long long)physicalMemory {
    if (!fakeLayer(@"processinfo")) return %orig;
    id val = getConfig(@"physicalMemory");
    if (val) return ci_toULL(val);
    return %orig;
}

- (NSTimeInterval)systemUptime {
    if (!fakeLayer(@"processinfo")) return %orig;
    id val = getConfig(@"systemUptime");
    if (val) return [val doubleValue];
    return %orig;
}

- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion real = %orig;
    if (!fakeLayer(@"processinfo")) return real;
    NSString *ver = getConfigStr(@"systemVersion");
    if (!ver) return real;
    NSArray *parts = [ver componentsSeparatedByString:@"."];
    if (parts.count == 0) return real;
    NSInteger spoofedMajor = [parts[0] integerValue];
    // Only spoof when MAJOR version matches the real OS. UIKit and
    // FrontBoardServices on iOS 16 gate features behind
    // operatingSystemVersion.majorVersion >= 16 — if we lie about being iOS
    // 14 on a 16 device, those feature checks fail and scene init throws.
    // The user-visible iOS string is still spoofed via UIDevice.systemVersion.
    if (spoofedMajor != real.majorVersion) return real;
    NSOperatingSystemVersion v;
    v.majorVersion = spoofedMajor;
    v.minorVersion = parts.count > 1 ? [parts[1] integerValue] : 0;
    v.patchVersion = parts.count > 2 ? [parts[2] integerValue] : 0;
    return v;
}

%end

// ============================================================
// LAYER 9: GPS Location Hooks
// ============================================================
static CLLocation *buildFakeLocation(void) {
    id lat = getConfig(@"latitude");
    id lng = getConfig(@"longitude");
    id alt = getConfig(@"altitude");
    if (!lat || !lng) return nil;

    CLLocationCoordinate2D coord;
    coord.latitude = [lat doubleValue];
    coord.longitude = [lng doubleValue];
    double altitude = alt ? [alt doubleValue] : 10.0;

    // Micro-jitter (~5 cm) every read — mimics noisy GPS sensor; the large
    // resettable jitter is already baked into lat/lng by the host app on Reset.
    double jitterLat = ((double)(arc4random_uniform(100)) - 50.0) / 1000000.0;
    double jitterLng = ((double)(arc4random_uniform(100)) - 50.0) / 1000000.0;
    coord.latitude += jitterLat;
    coord.longitude += jitterLng;

    id acc    = getConfig(@"locationAccuracy");
    id spdV   = getConfig(@"locationSpeed");
    id crsV   = getConfig(@"locationCourse");
    double hAcc   = acc  ? [acc doubleValue]  : (5.0 + arc4random_uniform(30));
    double speed  = spdV ? [spdV doubleValue] : 0.0;
    double course = crsV ? [crsV doubleValue] : (double)(arc4random_uniform(360));

    CLLocation *loc = [[CLLocation alloc]
        initWithCoordinate:coord
        altitude:altitude
        horizontalAccuracy:hAcc
        verticalAccuracy:hAcc * 1.5
        course:course
        speed:speed
        timestamp:[NSDate date]];
    return loc;
}

%hook CLLocationManager

- (CLLocation *)location {
    if (!fakeLayer(@"location")) return %orig;
    if (!getConfigBool(@"locationEnabled")) return %orig;
    CLLocation *fake = buildFakeLocation();
    return fake ?: %orig;
}

- (void)startUpdatingLocation {
    %orig;
    if (fakeLayer(@"location") && getConfigBool(@"locationEnabled") && self.delegate) {
        CLLocation *fake = buildFakeLocation();
        if (fake && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.delegate locationManager:self didUpdateLocations:@[fake]];
            });
        }
    }
}

- (void)startMonitoringSignificantLocationChanges {
    %orig;
    if (fakeLayer(@"location") && getConfigBool(@"locationEnabled") && self.delegate) {
        CLLocation *fake = buildFakeLocation();
        if (fake && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.delegate locationManager:self didUpdateLocations:@[fake]];
            });
        }
    }
}

- (void)requestLocation {
    if (fakeLayer(@"location") && getConfigBool(@"locationEnabled") && self.delegate) {
        CLLocation *fake = buildFakeLocation();
        if (fake && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.delegate locationManager:self didUpdateLocations:@[fake]];
            });
            return;
        }
    }
    %orig;
}

%end

%hook CLGeocoder

- (void)reverseGeocodeLocation:(CLLocation *)location completionHandler:(void (^)(NSArray *placemarks, NSError *error))completionHandler {
    if (!fakeLayer(@"location") || !getConfigBool(@"locationEnabled")) {
        %orig;
        return;
    }
    CLLocation *fake = buildFakeLocation();
    if (fake) {
        %orig(fake, completionHandler);
    } else {
        %orig;
    }
}

%end

// ============================================================
// LAYER 10: Locale / Timezone Hooks
// ============================================================
%hook NSLocale

+ (NSLocale *)currentLocale {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *identifier = getConfigStr(@"localeIdentifier");
    if (identifier) {
        return [[NSLocale alloc] initWithLocaleIdentifier:identifier];
    }
    return %orig;
}

- (NSString *)countryCode {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeCountryCode");
    return val ?: %orig;
}

- (NSString *)languageCode {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeLanguageCode");
    return val ?: %orig;
}

- (NSString *)currencyCode {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeCurrencyCode");
    return val ?: %orig;
}

- (NSString *)collatorIdentifier {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeIdentifier");
    return val ?: %orig;
}

%end

%hook NSTimeZone

+ (NSTimeZone *)localTimeZone {
    if (!fakeLayer(@"datetime")) return %orig;
    NSString *tzName = getConfigStr(@"timezoneName");
    if (tzName) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzName];
        if (tz) return tz;
    }
    return %orig;
}

+ (NSTimeZone *)systemTimeZone {
    if (!fakeLayer(@"datetime")) return %orig;
    NSString *tzName = getConfigStr(@"timezoneName");
    if (tzName) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzName];
        if (tz) return tz;
    }
    return %orig;
}

%end

// ============================================================
// LAYER 11: Jailbreak Hide Hooks
// ============================================================
%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (!jbHideActive()) return %orig;

    NSArray *hiddenPaths = getConfig(@"hiddenPaths");
    if (hiddenPaths) {
        for (NSString *hidden in hiddenPaths) {
            if ([path hasPrefix:hidden] || [path isEqualToString:hidden]) {
                return NO;
            }
        }
    }

    NSArray *defaultPaths = @[
        @"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
        @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/usr/lib/TweakInject",
        @"/Library/MobileSubstrate", @"/var/mobile/Library/Caches/com.saurik.Cydia",
        @"/.installed_dopamine", @"/.installed_palera1n",
        @"/var/binpack", @"/private/preboot",
    ];

    for (NSString *jbPath in defaultPaths) {
        if ([path hasPrefix:jbPath] || [path isEqualToString:jbPath]) {
            return NO;
        }
    }

    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (!jbHideActive()) return %orig;

    NSArray *defaultPaths = @[
        @"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
        @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/.installed_dopamine",
        @"/.installed_palera1n", @"/var/binpack",
    ];

    for (NSString *jbPath in defaultPaths) {
        if ([path hasPrefix:jbPath]) return NO;
    }

    return %orig;
}

%end

// ============================================================
// APNS PUSH TOKEN SPOOF — break server-side device correlation.
// ============================================================
// iOS hands the app's UIApplicationDelegate a 32-byte device token via
// -application:didRegisterForRemoteNotificationsWithDeviceToken: . This
// token is keyed (Apple ID + bundle ID + hardware) at APNS server side
// and DOES NOT change across Reset Data, Reset Network Settings, app
// reinstall — only true device-erase or Apple ID change rotates it.
// Zalo's backend stores the token per-account; multiple accounts on the
// same physical device share the same token → trivial correlation →
// "abnormal behavior" flag → CCCD verification demanded.
//
// Strategy: when UIApplication's delegate is set, swizzle the delegate's
// didRegister method. The swizzled IMP swaps the incoming NSData for a
// 32-byte fake (kept in config under apnsTokenSpoof, regenerated every
// Reset Data) before forwarding to the original IMP. Zalo stores+sends
// the fake; Apple's APNS server is never queried with our spoof, so the
// real token still works for actual push delivery (which Zalo doesn't
// need at sign-up time anyway). Net effect: per-Reset, the server sees
// what looks like a brand-new device with no history.

static const char kCIApnsOrigKey = 0;

static NSData *ci_apnsSpoofTokenData(void) {
    NSString *hex = getConfigStr(@"apnsTokenSpoof");
    if (hex.length < 64) return nil;
    NSMutableData *out = [NSMutableData dataWithCapacity:32];
    for (NSUInteger i = 0; i + 2 <= hex.length && out.length < 32; i += 2) {
        unsigned int v = 0;
        const char *p = [[hex substringWithRange:NSMakeRange(i, 2)] UTF8String];
        if (sscanf(p, "%02x", &v) == 1) {
            uint8_t b = (uint8_t)v;
            [out appendBytes:&b length:1];
        }
    }
    return out.length == 32 ? out : nil;
}

static void ci_apnsHookedImpl(id self, SEL _cmd, UIApplication *app, NSData *originalToken) {
    NSData *fake = ci_apnsSpoofTokenData();
    NSData *use = (fake && fakeLayer(@"network")) ? fake : originalToken;
    NSValue *origPtr = objc_getAssociatedObject([self class], &kCIApnsOrigKey);
    if (origPtr) {
        void (*orig)(id, SEL, UIApplication *, NSData *) =
            (void (*)(id, SEL, UIApplication *, NSData *))[origPtr pointerValue];
        if (orig) orig(self, _cmd, app, use);
    }
    // If we added the method (no original), nothing else to do — caller
    // got our spoof, app delegate consumed it.
}

static void ci_swizzleApnsOnDelegate(Class cls) {
    if (!cls) return;
    if (objc_getAssociatedObject(cls, &kCIApnsOrigKey)) return; // already swizzled
    SEL sel = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        IMP orig = method_getImplementation(m);
        objc_setAssociatedObject(cls, &kCIApnsOrigKey,
                                 [NSValue valueWithPointer:(void *)orig],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        method_setImplementation(m, (IMP)ci_apnsHookedImpl);
        NSLog(@"[ChangeInfoIos] APNS delegate swizzled on %@", NSStringFromClass(cls));
    } else {
        // No existing impl — add ours so the spoof token still flows somewhere
        // (most app delegates DO implement; this branch is rare).
        class_addMethod(cls, sel, (IMP)ci_apnsHookedImpl, "v@:@@");
        // Mark with a sentinel so we don't double-add.
        objc_setAssociatedObject(cls, &kCIApnsOrigKey,
                                 [NSValue valueWithPointer:NULL],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (jbHideActive() && url) {
        NSString *scheme = [url scheme];
        NSArray *blocked = @[@"cydia", @"sileo", @"zbra", @"filza", @"undecimus",
                            @"activator", @"flex"];
        for (NSString *s in blocked) {
            if ([scheme isEqualToString:s]) return NO;
        }
    }
    return %orig;
}

- (void)setDelegate:(id<UIApplicationDelegate>)delegate {
    %orig(delegate);
    if (delegate) {
        ci_swizzleApnsOnDelegate([delegate class]);
    }
}

%end

// ============================================================
// APP STORE RECEIPT BLOCKER — Apple ID hash leak prevention.
// ============================================================
// `[NSBundle.mainBundle appStoreReceiptURL]` returns a URL to a binary
// receipt blob iOS provisions per (Apple ID + bundle). The blob contains
// hashed account identifiers; backend SDKs (AppsFlyer, Branch) sometimes
// upload it for "fraud verification". Two Zalo accounts on the same
// Apple ID upload the same hash → server correlates. Returning nil
// makes apps fall through to "no receipt" handling (App Store unsigned
// dev builds do this normally), no Apple ID hash leaves the device.
%hook NSBundle
- (NSURL *)appStoreReceiptURL {
    if (fakeLayer(@"keychain")) return nil;
    return %orig;
}
%end

// ============================================================
// WEBRTC ICE candidate filter — strip local IP from SDP.
// ============================================================
// WebRTC peer connections enumerate local network interfaces and emit
// "host" ICE candidates that include the device's real IPv4 (often
// 192.168.x.x / 10.x.x.x). Even when the actual TCP egress goes through
// a proxy/VPN, the candidate string is sent in the SDP offer/answer to
// the peer (and to TURN/STUN servers). Anti-fraud / TURN logs see the
// real client IP → correlate. Filter "host" + "srflx" candidates from
// SDP at setLocalDescription time.
@interface RTCSessionDescription : NSObject
- (NSString *)sdp;
- (instancetype)initWithType:(int)type sdp:(NSString *)sdp;
- (int)type;
@end

@interface RTCPeerConnection : NSObject
@end

static IMP orig_RTCPC_setLocalDesc = NULL;

static NSString *ci_filterSDP(NSString *sdp) {
    if (sdp.length == 0) return sdp;
    NSArray *lines = [sdp componentsSeparatedByString:@"\r\n"];
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSString *line in lines) {
        // Format: "a=candidate:... typ host ..." or "... typ srflx ..."
        if ([line containsString:@"a=candidate:"] &&
            ([line containsString:@" typ host"] || [line containsString:@" typ srflx"])) {
            continue; // drop — would leak local/server-reflexive IP
        }
        [kept addObject:line];
    }
    return [kept componentsJoinedByString:@"\r\n"];
}

// Build a new RTCSessionDescription with filtered SDP. Returns nil on
// failure — caller should fall back to original desc unchanged.
static id ci_rebuildRTCDesc(id origDesc, NSString *newSDP) {
    Class C = [origDesc class];
    NSMethodSignature *sig = [C instanceMethodSignatureForSelector:@selector(initWithType:sdp:)];
    if (!sig) return nil;
    NSMethodSignature *typeSig = [origDesc methodSignatureForSelector:@selector(type)];
    if (!typeSig) return nil;
    int t = 0;
    NSInvocation *typeInv = [NSInvocation invocationWithMethodSignature:typeSig];
    typeInv.target = origDesc; typeInv.selector = @selector(type);
    [typeInv invoke];
    [typeInv getReturnValue:&t];

    id alloc = [C alloc];
    NSInvocation *initInv = [NSInvocation invocationWithMethodSignature:sig];
    initInv.target = alloc; initInv.selector = @selector(initWithType:sdp:);
    [initInv setArgument:&t atIndex:2];
    [initInv setArgument:&newSDP atIndex:3];
    [initInv invoke];
    id result = nil;
    [initInv getReturnValue:&result];
    return result;
}

static void ci_RTCPC_setLocalDesc(id self, SEL _cmd, id desc, id completion) {
    id useDesc = desc;
    if (fakeLayer(@"network") && desc) {
        @try {
            NSString *sdp = nil;
            if ([desc respondsToSelector:@selector(sdp)]) {
                sdp = [desc performSelector:@selector(sdp)];
            }
            if (sdp.length > 0) {
                NSString *filtered = ci_filterSDP(sdp);
                if (![filtered isEqualToString:sdp]) {
                    id rebuilt = ci_rebuildRTCDesc(desc, filtered);
                    if (rebuilt) useDesc = rebuilt;
                }
            }
        } @catch (__unused id e) {}
    }
    if (orig_RTCPC_setLocalDesc) {
        void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))orig_RTCPC_setLocalDesc;
        orig(self, _cmd, useDesc, completion);
    }
}

static void ci_installWebRTCHooks(void) {
    @autoreleasepool {
        Class pc = objc_getClass("RTCPeerConnection");
        if (!pc) return;
        SEL sel = @selector(setLocalDescription:completionHandler:);
        Method m = class_getInstanceMethod(pc, sel);
        if (!m) return;
        orig_RTCPC_setLocalDesc = method_getImplementation(m);
        method_setImplementation(m, (IMP)ci_RTCPC_setLocalDesc);
        NSLog(@"[ChangeInfoIos] RTCPeerConnection.setLocalDescription hooked");
    }
}

// ============================================================
// LSApplicationWorkspace BLOCKER — hide the installed-app list.
// ============================================================
// Anti-fraud SDKs (TrustDecision et al) call -[LSApplicationWorkspace
// allInstalledApplications] / -applicationProxiesForIdentifiersOfType:
// to fingerprint a device by which apps the user has installed. Two
// users with the same set of 30+ apps share a fingerprint vector that's
// often enough to correlate, even across all the other spoofs we run.
// We're a private framework class; declare the method we need then hook.
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)applicationProxiesForIdentifiersOfType:(NSString *)type;
@end

%hook LSApplicationWorkspace
- (NSArray *)allInstalledApplications {
    NSArray *real = %orig;
    if (!fakeLayer(@"jbhide")) return real;
    // Filter to Apple's stock apps only — every user has these, so the
    // fingerprint vector collapses to a constant.
    NSMutableArray *filtered = [NSMutableArray array];
    for (id proxy in real) {
        NSString *bid = nil;
        @try { bid = [proxy performSelector:@selector(applicationIdentifier)]; }
        @catch (__unused id e) { continue; }
        if ([bid hasPrefix:@"com.apple."]) [filtered addObject:proxy];
    }
    return filtered;
}
- (NSArray *)applicationProxiesForIdentifiersOfType:(NSString *)type {
    NSArray *real = %orig;
    if (!fakeLayer(@"jbhide")) return real;
    NSMutableArray *filtered = [NSMutableArray array];
    for (id proxy in real) {
        NSString *bid = nil;
        @try { bid = [proxy performSelector:@selector(applicationIdentifier)]; }
        @catch (__unused id e) { continue; }
        if ([bid hasPrefix:@"com.apple."]) [filtered addObject:proxy];
    }
    return filtered;
}
%end

// ============================================================
// iCLOUD KEY-VALUE STORE BLOCKER — break iCloud-keyed correlation.
// ============================================================
// NSUbiquitousKeyValueStore is per-Apple-ID iCloud KVS. SDKs cache
// install IDs / install timestamps there so reinstall under same Apple
// ID resurrects the prior identity. Return empty/nil so the app sees
// a fresh KVS each Reset.
%hook NSUbiquitousKeyValueStore
- (id)objectForKey:(NSString *)key {
    if (fakeLayer(@"keychain")) return nil;
    return %orig;
}
- (NSString *)stringForKey:(NSString *)key {
    if (fakeLayer(@"keychain")) return nil;
    return %orig;
}
- (NSData *)dataForKey:(NSString *)key {
    if (fakeLayer(@"keychain")) return nil;
    return %orig;
}
- (NSDictionary *)dictionaryRepresentation {
    if (fakeLayer(@"keychain")) return @{};
    return %orig;
}
%end

%hook UIPasteboard

+ (UIPasteboard *)generalPasteboard {
    if (!jbHideActive() && !fakeLayer(@"tracking_pasteboard")) return %orig;
    return %orig;
}

- (NSArray<NSString *> *)strings {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return @[];
    }
    return %orig;
}

- (NSString *)string {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return nil;
    }
    return %orig;
}

- (BOOL)hasStrings {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return NO;
    }
    return %orig;
}

- (BOOL)hasURLs {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return NO;
    }
    return %orig;
}

- (NSArray<NSURL *> *)URLs {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return @[];
    }
    return %orig;
}

%end

// ============================================================
// BONUS: ZALO-SPECIFIC DEEP HOOKS
// ============================================================
// DISABLED v2.3.23: WKWebView hook pulls in WebKit classes
// (WKUserScript, WKUserContentController) that need full WebKit framework
// to be linked at dylib load time. Under rootless, WebKit may not be
// dyld-shared-cache visible from arbitrary tweak targets, so substrate
// silently rejects the whole dylib. Re-enable after confirming main
// inject path works, and move the WebKit code behind a dlopen()/objc_getClass
// runtime lookup so dylib load never touches WebKit symbols directly.
#if 0
%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    id wfGate = getConfig(@"web_fakeEnabled");
    BOOL allowInject = (wfGate == nil) || [wfGate boolValue];
    if (fakeLayer(@"browser") && allowInject) {
        WKUserContentController *ucc = configuration.userContentController;
        if (!ucc) {
            ucc = [[WKUserContentController alloc] init];
            configuration.userContentController = ucc;
        }

        NSString *vendor = getConfigStr(@"web_glVendor") ?: @"Apple Inc.";
        NSString *renderer = getConfigStr(@"web_glRenderer") ?: @"Apple GPU";
        NSString *canvasNoise = getConfigStr(@"web_canvasNoise") ?: @"zalo_spoof";

        NSString *coreJs = [NSString stringWithFormat:@"\
            const _getParam = WebGLRenderingContext.prototype.getParameter;\
            WebGLRenderingContext.prototype.getParameter = function(p) {\
                if (p === 37445) return '%@';\
                if (p === 37446) return '%@';\
                return _getParam.call(this, p);\
            };\
            const _getParam2 = WebGL2RenderingContext.prototype.getParameter;\
            WebGL2RenderingContext.prototype.getParameter = function(p) {\
                if (p === 37445) return '%@';\
                if (p === 37446) return '%@';\
                return _getParam2.call(this, p);\
            };\
            const _toDataURL = HTMLCanvasElement.prototype.toDataURL;\
            HTMLCanvasElement.prototype.toDataURL = function() {\
                var ctx = this.getContext('2d');\
                if (ctx) {\
                    ctx.fillStyle = 'rgba(255,255,255,0.01)';\
                    ctx.fillText('%@', 1, 1);\
                }\
                return _toDataURL.apply(this, arguments);\
            };\
        ", vendor, renderer, vendor, renderer, canvasNoise];

        NSString *rtcJs = @"";
        if (fakeLayer(@"webrtc")) {
            rtcJs = @"if(window.RTCPeerConnection){window.RTCPeerConnection=function(){return {};};}\
            if(navigator.mediaDevices&&navigator.mediaDevices.enumerateDevices){\
            const oldEnum=navigator.mediaDevices.enumerateDevices;\
            navigator.mediaDevices.enumerateDevices=async function(){\
            const devs=await oldEnum.call(this);\
            return devs.filter(function(d){return d.kind!=='audioinput'&&d.kind!=='videoinput';});};}";
        }

        NSString *js = [NSString stringWithFormat:@"try {%@%@} catch(e) {}", coreJs, rtcJs];
        WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
        [ucc addUserScript:script];
    }
    return %orig(frame, configuration);
}

- (NSString *)customUserAgent {
    if (!fakeLayer(@"browser")) return %orig;
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    return ua ?: %orig;
}

- (void)setCustomUserAgent:(NSString *)userAgent {
    if (!fakeLayer(@"browser")) {
        %orig(userAgent);
        return;
    }
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    if (ua) {
        %orig(ua);
    } else {
        %orig(userAgent);
    }
}

%end
#endif // WKWebView hook disabled

%hook CMMotionManager

- (BOOL)isAccelerometerAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

- (BOOL)isGyroAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

- (BOOL)isMagnetometerAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

- (BOOL)isDeviceMotionAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

%end

%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    if (!fakeLayer(@"trackingdefaults")) return %orig;
    if (getConfigBool(@"keychainReset")) {
        NSArray *trackingKeys = @[@"device_id", @"device_token", @"udid",
                                 @"DEVICE_UUID", @"kDeviceId", @"UniqueIdentifier",
                                 @"ADVERTISING_ID", @"installation_id",
                                 @"TWClientID", @"TWDeviceID", @"tw_device",
                                 @"twitter_device", @"client_device_id",
                                 @"persistentDeviceID", @"tw_inapp_install_id"];
        for (NSString *key in trackingKeys) {
            if ([defaultName.lowercaseString containsString:key.lowercaseString]) {
                return nil;
            }
        }
    }
    return %orig;
}

%end

// Build an NSURLSession proxy dict from the user's saved Proxy section.
// Same key set as the host app's ci_proxyConfigOrNil() so behaviour stays
// consistent on both sides. Returns nil if proxy is off / format invalid —
// caller should leave the config alone in that case.
static NSDictionary *ci_buildProxyDictForTweak(void) {
    if (!getConfigBool(@"proxyEnabled")) return nil;
    NSString *raw = getConfigStr(@"proxyString");
    if (raw.length == 0) return nil;
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *parts = [trimmed componentsSeparatedByString:@":"];
    if (parts.count < 2) return nil;
    NSString *host = parts[0];
    NSInteger port = [parts[1] integerValue];
    if (host.length == 0 || port < 1 || port > 65535) return nil;
    NSString *user = (parts.count >= 3 && [parts[2] length] > 0) ? parts[2] : nil;
    NSString *pass = (parts.count >= 4 && [parts[3] length] > 0) ? parts[3] : nil;
    BOOL socks = [getConfigStr(@"proxyType") isEqualToString:@"socks5"];

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (socks) {
        d[(NSString *)kCFStreamPropertySOCKSProxyHost] = host;
        d[(NSString *)kCFStreamPropertySOCKSProxyPort] = @(port);
        d[(NSString *)kCFStreamPropertySOCKSVersion]   = (NSString *)kCFStreamSocketSOCKSVersion5;
        if (user) d[(NSString *)kCFStreamPropertySOCKSUser]     = user;
        if (pass) d[(NSString *)kCFStreamPropertySOCKSPassword] = pass;
    } else {
        d[@"HTTPEnable"]  = @YES;
        d[@"HTTPProxy"]   = host;
        d[@"HTTPPort"]    = @(port);
        d[@"HTTPSEnable"] = @YES;
        d[@"HTTPSProxy"]  = host;
        d[@"HTTPSPort"]   = @(port);
        if (user) d[@"HTTPProxyUsername"]  = user;
        if (pass) d[@"HTTPProxyPassword"] = pass;
    }
    return d;
}

// LAYER 16: NSURLSessionConfiguration default headers — NSURLSession
// users set User-Agent via configuration.HTTPAdditionalHeaders BEFORE
// any request is made, so the per-request -setValue:forHTTPHeaderField:
// hook never sees them. Patch the property setter so the fake UA wins.
//
// Also: when the user has a Proxy enabled in HIOS, we inject the proxy
// dict into every session config the target app builds. Done at the
// class-method level (defaultSessionConfiguration / ephemeralSession
// Configuration) — those return a fresh config each call, so mutating
// the returned object before handing it back catches every NSURLSession
// the app creates without races. Background sessions are intentionally
// NOT proxied (they survive app death and can't be re-validated).
%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *cfg = %orig;
    NSDictionary *p = ci_buildProxyDictForTweak();
    if (cfg && p) cfg.connectionProxyDictionary = p;
    return cfg;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *cfg = %orig;
    NSDictionary *p = ci_buildProxyDictForTweak();
    if (cfg && p) cfg.connectionProxyDictionary = p;
    return cfg;
}

- (void)setHTTPAdditionalHeaders:(NSDictionary *)headers {
    if (!fakeLayer(@"browser") || !headers) { %orig(headers); return; }
    NSString *fakeUA = getConfigStr(@"zalo_fakeWebViewUA");
    if (!fakeUA.length) { %orig(headers); return; }
    NSMutableDictionary *patched = [headers mutableCopy];
    // Replace any case-variant of User-Agent with our fake.
    for (NSString *k in [headers allKeys]) {
        if ([k isKindOfClass:[NSString class]] &&
            [k.lowercaseString isEqualToString:@"user-agent"]) {
            [patched removeObjectForKey:k];
        }
    }
    patched[@"User-Agent"] = fakeUA;
    %orig([patched copy]);
}

%end

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (!fakeLayer(@"browser")) {
        %orig(value, field);
        return;
    }
    if ([field.lowercaseString isEqualToString:@"user-agent"] && value.length > 0) {
        NSString *fakeUA = getConfigStr(@"zalo_fakeWebViewUA");
        if (fakeUA) {
            %orig(fakeUA, field);
            return;
        }
        NSString *fakeModel = getConfigStr(@"ProductType");
        if (fakeModel) {
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"iPhone\\d+,\\d+"
                options:0 error:nil];
            NSString *patched = [regex stringByReplacingMatchesInString:value
                options:0
                range:NSMakeRange(0, value.length)
                withTemplate:fakeModel];
            %orig(patched, field);
            return;
        }
    }
    %orig(value, field);
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (!fakeLayer(@"browser")) {
        %orig(value, field);
        return;
    }
    if ([field.lowercaseString isEqualToString:@"user-agent"] && value.length > 0) {
        NSString *fakeUA = getConfigStr(@"zalo_fakeWebViewUA");
        if (fakeUA) {
            %orig(fakeUA, field);
            return;
        }
    }
    %orig(value, field);
}

%end

// DISABLED v2.3.23: %hook NSObject on -(NSString*)name installs globally.
// Even with the MTLDevice protocol guard, wrapping every NSObject.name call
// system-wide is a known cause of substrate silently skipping the dylib
// (dyld sees a root-class swizzle and fails validation). If GPU spoofing is
// needed later, hook MTLCreateSystemDefaultDevice or the concrete MTLDevice
// class instead of NSObject.
//
// %hook NSObject
// - (NSString *)name {
//     if (!fakeLayer(@"metal")) return %orig;
//     if ([self conformsToProtocol:@protocol(MTLDevice)]) {
//         NSString *fakeGPU = getConfigStr(@"zalo_metalGPU");
//         if (fakeGPU) return fakeGPU;
//     }
//     return %orig;
// }
// %end

%hook ATTrackingManager

+ (NSUInteger)trackingAuthorizationStatus {
    if (!fakeLayer(@"ads")) return %orig;
    return 2;
}

+ (void)requestTrackingAuthorizationWithCompletionHandler:(void (^)(NSUInteger))completion {
    if (!fakeLayer(@"ads")) {
        %orig;
        return;
    }
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(2);
        });
    }
}

%end

// ============================================================
// !!! REMOVED: %hook NSBundle infoDictionary !!!
// ============================================================
// AIDA64 (and others) crashed with EXC_CRASH/SIGABRT during scene
// lifecycle setup — stack showed __exceptionPreprocess →
// objc_exception_throw → ___forwarding___ → _CF_forwarding_prep_ →
// _UIScenePerformActionsWithLifecycleActionMask. The forwarding chain
// triggers when objc_msgSend is called on a method that doesn't
// exist on the receiver. Returning a mutable patched dict from
// infoDictionary apparently confused some private Apple code path
// expecting the original immutable backing.
//
// The iOS version + build are already covered at multiple safer
// layers — sysctlbyname(kern.osversion), MGCopyAnswer(ProductVersion,
// BuildVersion), UIDevice.systemVersion — so dropping infoDictionary
// loses nothing material.

// ============================================================
// LAYER 12: DeviceCheck & App Attest (anti-fraud — Zalo, banking)
// ============================================================
// DeviceCheck issues a per-(device, app) token that, when sent to Apple's
// servers, gives back 2 bits of state. Anti-fraud servers store the token
// hash and use it to recognise repeat installs from the same device. Apps
// that want strong device fingerprinting (Zalo, MoMo, banking apps) call
// generateTokenWithCompletionHandler at sign-up.
//
// We can't actually mint a valid Apple-signed token without their key, but
// we CAN return a fresh random blob each call so the anti-fraud server
// stores a different hash every reset → looks like a brand-new device.
// Returns synthetic 32-byte payload that's structurally valid (token is
// opaque to the calling app).
//
// %hook installs only if the framework class is present at runtime —
// guarded in %ctor below via objc_getClass / hookSelectorIfExists.
//
// App Attest is the iOS 14+ replacement: keypair stored in Secure Enclave,
// keyId returned to app, attestation generated against a clientDataHash.
// We return random keyIds and synthetic attestations — same idea.
// LAYER 12 / 13: DCDevice + DCAppAttestService + LAContext
// ----------------------------------------------------------
// Restored via runtime conditional install (commit bbddb1e disabled them
// for crashing). Two key differences from the first attempt:
//   1. NEVER use Logos `%hook DCDevice` — that registers a swizzle at
//      link time for every process the dylib loads into, including ones
//      where DeviceCheck.framework isn't mapped. Logos's late lookup of
//      a missing class trips an assertion deep in the FBSSerialQueue
//      callout, killing scene init. Instead, walk Class via
//      objc_getClass and patch methods only when the class exists.
//   2. Run completion SYNCHRONOUSLY. The original used
//      dispatch_async(dispatch_get_main_queue(), ...) which re-entered
//      Apple's completion delivery while FBS was mid-callout — same
//      std::terminate path. Apps treat the completion as "may run on
//      any thread"; firing inline is contractually valid.
//
// Targets:
//   DCDevice.isSupported                            → YES
//   DCDevice.generateTokenWithCompletionHandler:    → 32-byte random blob
//   DCAppAttestService.isSupported                  → YES
//   DCAppAttestService.generateKeyWithCompletion:   → fresh base64 keyId
//   DCAppAttestService.attestKey:clientDataHash:    → 1600B random blob
//   LAContext.canEvaluatePolicy:error:              → YES, error nil

typedef void (*ci_dcDevice_isSupported_t)(id, SEL);
typedef BOOL (*ci_imp_BOOL_t)(id, SEL);
typedef BOOL (*ci_imp_BOOL_NSIntegerErr_t)(id, SEL, NSInteger, NSError **);
typedef void (*ci_imp_void_completion_t)(id, SEL, id);
typedef void (*ci_imp_void_attestKey_t)(id, SEL, NSString *, NSData *, id);

static ci_imp_BOOL_t orig_DC_isSupported               = NULL;
static ci_imp_void_completion_t orig_DC_generateToken  = NULL;
static ci_imp_BOOL_t orig_DCA_isSupported              = NULL;
static ci_imp_void_completion_t orig_DCA_generateKey   = NULL;
static ci_imp_void_attestKey_t orig_DCA_attestKey      = NULL;
static ci_imp_void_attestKey_t orig_DCA_genAssertion   = NULL;
static ci_imp_BOOL_NSIntegerErr_t orig_LA_canEval      = NULL;

// State-machine cache for DCDevice + DCAppAttestService. Apple's real impl
// returns the SAME token / keyId across an entire device lifecycle (rotated
// only on user actions like erase-all). Random-per-call breaks server-side
// session continuity: Zalo stores token@signin, validates token@every-req,
// kicks user when t1 != t2.
//
// PERSISTENT cache: previously dispatch_once kept the token consistent only
// for the current process. iOS aggressively suspends + relaunches apps
// (memory pressure, BG → FG transition, app switcher), and each relaunch
// would re-roll the token via dispatch_once → server sees new token →
// session invalidated even though hardware ID is stable.
//
// Persist tokens at /var/jb/etc/changeinfoios/dc_state_<bid>.plist so
// the same process bundle returns the same token across restarts. Reset
// Data deletes these files (host app handles cleanup).
static NSData     *cachedDCToken      = nil;
static NSString   *cachedDCAKeyId     = nil;
static dispatch_once_t cachedDCTokenOnce;
static dispatch_once_t cachedDCAKeyOnce;

static NSString *ci_dcStatePath(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    // Sanitize bid for filename — replace / and . problematic chars.
    NSString *safe = [bid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [NSString stringWithFormat:@"/var/jb/etc/changeinfoios/dc_state_%@.plist", safe];
}

static NSDictionary *ci_loadDCState(void) {
    NSString *path = ci_dcStatePath();
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

static void ci_saveDCState(NSDictionary *state) {
    NSString *path = ci_dcStatePath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    [state writeToFile:path atomically:YES];
}

static BOOL ci_DC_isSupported(id self, SEL _cmd) {
    if (!fakeLayer(@"hardware")) return orig_DC_isSupported ? orig_DC_isSupported(self, _cmd) : YES;
    return YES;
}

static void ci_DC_generateToken(id self, SEL _cmd, void (^completion)(NSData *, NSError *)) {
    if (!fakeLayer(@"hardware")) {
        if (orig_DC_generateToken) orig_DC_generateToken(self, _cmd, (id)completion);
        return;
    }
    if (!completion) return;
    dispatch_once(&cachedDCTokenOnce, ^{
        // First try to load persisted token. iOS suspends + relaunches apps
        // aggressively; without persistence each relaunch re-rolls the
        // token and server-side validation fails.
        NSDictionary *saved = ci_loadDCState();
        NSData *persisted = saved[@"dcToken"];
        if ([persisted isKindOfClass:[NSData class]] && persisted.length == 32) {
            cachedDCToken = persisted;
            return;
        }
        uint8_t buf[32];
        arc4random_buf(buf, sizeof(buf));
        cachedDCToken = [NSData dataWithBytes:buf length:sizeof(buf)];
        // Merge with existing state so we don't clobber a sibling keyId.
        NSMutableDictionary *state = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
        state[@"dcToken"] = cachedDCToken;
        ci_saveDCState(state);
    });
    completion(cachedDCToken, nil);
}

static BOOL ci_DCA_isSupported(id self, SEL _cmd) {
    if (!fakeLayer(@"hardware")) return orig_DCA_isSupported ? orig_DCA_isSupported(self, _cmd) : YES;
    return YES;
}

static void ci_DCA_generateKey(id self, SEL _cmd, void (^completion)(NSString *, NSError *)) {
    if (!fakeLayer(@"hardware")) {
        if (orig_DCA_generateKey) orig_DCA_generateKey(self, _cmd, (id)completion);
        return;
    }
    if (!completion) return;
    dispatch_once(&cachedDCAKeyOnce, ^{
        NSDictionary *saved = ci_loadDCState();
        NSString *persisted = saved[@"dcaKeyId"];
        if ([persisted isKindOfClass:[NSString class]] && persisted.length > 0) {
            cachedDCAKeyId = persisted;
            return;
        }
        uint8_t buf[32];
        arc4random_buf(buf, sizeof(buf));
        cachedDCAKeyId = [[NSData dataWithBytes:buf length:sizeof(buf)] base64EncodedStringWithOptions:0];
        NSMutableDictionary *state = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
        state[@"dcaKeyId"] = cachedDCAKeyId;
        ci_saveDCState(state);
    });
    completion(cachedDCAKeyId, nil);
}

static void ci_DCA_attestKey(id self, SEL _cmd, NSString *keyId, NSData *hash, void (^completion)(NSData *, NSError *)) {
    if (!fakeLayer(@"hardware")) {
        if (orig_DCA_attestKey) orig_DCA_attestKey(self, _cmd, keyId, hash, (id)completion);
        return;
    }
    if (!completion) return;
    NSMutableData *fake = [NSMutableData dataWithLength:1600];
    arc4random_buf(fake.mutableBytes, fake.length);
    completion(fake, nil);
}

// generateAssertion is called for EVERY request after the initial reg.
// Apps using App Attest send (keyId, clientDataHash) → SE generates a
// signed assertion that the server validates against the stored attest.
// Without a hook, real SE call fails (we never created a real key) and
// the server kicks the session. Return random 96-byte blob so Zalo's
// path-of-least-resistance just stores whatever and proceeds.
//
// Real assertion size is variable (~70-120 bytes). 96 splits the middle.
static void ci_DCA_generateAssertion(id self, SEL _cmd, NSString *keyId, NSData *hash, void (^completion)(NSData *, NSError *)) {
    if (!fakeLayer(@"hardware")) {
        if (orig_DCA_genAssertion) orig_DCA_genAssertion(self, _cmd, keyId, hash, (id)completion);
        return;
    }
    if (!completion) return;
    NSMutableData *fake = [NSMutableData dataWithLength:96];
    arc4random_buf(fake.mutableBytes, fake.length);
    completion(fake, nil);
}

static BOOL ci_LA_canEval(id self, SEL _cmd, NSInteger policy, NSError **error) {
    if (!fakeLayer(@"hardware")) {
        return orig_LA_canEval ? orig_LA_canEval(self, _cmd, policy, error) : YES;
    }
    if (error) *error = nil;
    return YES;
}

// Installs an instance-method hook only when the class + selector exist
// at runtime. Safe in processes where the framework isn't mapped: simply
// no-ops without raising or registering a swizzle.
static void ci_swizzleInstance(const char *className, SEL sel, IMP newImp, IMP *origImpOut) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (origImpOut) *origImpOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

// LAYER 14: WKWebView fingerprint spoof
// ---------------------------------------
// Restored via runtime swizzle (was disabled because `%hook WKWebView`
// required linking WebKit — the dylib then failed to load in apps that
// don't link WebKit). objc_getClass + method_setImplementation lets us
// install only when WKWebView is already mapped into the host process.
//
// What we spoof:
//   - WKWebView.customUserAgent / setCustomUserAgent: → zalo_fakeWebViewUA
//   - initWithFrame:configuration: → injects a WKUserScript at document
//     start that monkey-patches the JS fingerprint surface BEFORE the
//     page's own scripts run:
//       * navigator.userAgent          → fake UA
//       * navigator.platform           → "iPhone"
//       * WebGL VENDOR / RENDERER      → web_glVendor / web_glRenderer
//       * HTMLCanvasElement.toDataURL  → adds a 1px noise pixel each call
//       * RTCPeerConnection            → returns a stub (blocks STUN leak)
//       * navigator.mediaDevices.enumerateDevices → strip audioinput/videoinput
//       * navigator.languages          → from localeLanguageCode
//
// Gated by fake_browser. JS is built once per cell of values; rebuilt only
// when config changes (cheap regen since strings are tiny).

static IMP orig_WK_init                = NULL;
static IMP orig_WK_getCustomUA         = NULL;
static IMP orig_WK_setCustomUA         = NULL;

// JS templates kept as single-line adjacent-literal concatenations rather
// than multi-line backslash continuations. Logos's preprocessor counts
// braces eagerly and gets confused by `\`-continued lines that contain
// JS object literals — it concludes %ctor is "inside a block" and refuses
// to compile the file. Adjacent @"..." @"..." literals compile to the
// same string but parse cleanly.
static NSString *ci_buildWebFingerprintJS(void) {
    NSString *fakeUA    = getConfigStr(@"zalo_fakeWebViewUA")    ?: @"";
    NSString *vendor    = getConfigStr(@"web_glVendor")          ?: @"Apple Inc.";
    NSString *renderer  = getConfigStr(@"web_glRenderer")        ?: @"Apple GPU";
    NSString *language  = getConfigStr(@"localeLanguageCode")    ?: @"en";
    BOOL    canvasNoise = getConfigBool(@"web_canvasNoise");
    BOOL    blockWebRTC = getConfigBool(@"fake_webrtc");

    NSMutableString *js = [NSMutableString stringWithString:@"(function(){"];

    if (fakeUA.length) {
        [js appendFormat:@"try{Object.defineProperty(navigator,'userAgent',{get:function(){return '%@';}});}catch(e){}", fakeUA];
    }

    [js appendFormat:@"try{Object.defineProperty(navigator,'platform',{get:function(){return 'iPhone';}});}catch(e){}"];
    [js appendFormat:@"try{Object.defineProperty(navigator,'languages',{get:function(){return ['%@','en-US','en'];}});}catch(e){}", language];
    [js appendFormat:@"try{Object.defineProperty(navigator,'language',{get:function(){return '%@';}});}catch(e){}", language];
    [js appendFormat:@"try{var _gp=WebGLRenderingContext.prototype.getParameter;WebGLRenderingContext.prototype.getParameter=function(p){if(p===37445)return '%@';if(p===37446)return '%@';return _gp.call(this,p);};}catch(e){}", vendor, renderer];
    [js appendFormat:@"try{var _gp2=WebGL2RenderingContext.prototype.getParameter;WebGL2RenderingContext.prototype.getParameter=function(p){if(p===37445)return '%@';if(p===37446)return '%@';return _gp2.call(this,p);};}catch(e){}", vendor, renderer];

    if (canvasNoise) {
        NSString *watermark = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
        [js appendFormat:@"try{var _tdu=HTMLCanvasElement.prototype.toDataURL;HTMLCanvasElement.prototype.toDataURL=function(){var ctx=this.getContext('2d');if(ctx){ctx.fillStyle='rgba(255,255,255,0.005)';ctx.fillText('%@',1,1);}return _tdu.apply(this,arguments);};}catch(e){}", watermark];
        [js appendFormat:@"try{var _gid=CanvasRenderingContext2D.prototype.getImageData;CanvasRenderingContext2D.prototype.getImageData=function(){var d=_gid.apply(this,arguments);if(d&&d.data&&d.data.length>4){d.data[0]^=1;d.data[1]^=1;}return d;};}catch(e){}"];
    }

    if (blockWebRTC) {
        [js appendString:@"try{if(window.RTCPeerConnection)window.RTCPeerConnection=function(){return {};};}catch(e){}"];
        [js appendString:@"try{if(navigator.mediaDevices&&navigator.mediaDevices.enumerateDevices){var _e=navigator.mediaDevices.enumerateDevices.bind(navigator.mediaDevices);navigator.mediaDevices.enumerateDevices=async function(){var d=await _e();return d.filter(function(x){return x.kind!=='audioinput'&&x.kind!=='videoinput';});};}}catch(e){}"];
    }

    [js appendString:@"})();"];
    return js;
}

// initWithFrame:configuration: ABI on ARM64:
//   x0=self, x1=_cmd, q0..q3=CGRect{x,y,w,h}, x2=configuration
// We just call the original via the same signature — the compiler handles
// the float-register passing for CGRect.
typedef id (*ci_wkInit_t)(id, SEL, CGRect, id);
static id ci_WK_init(id self, SEL _cmd, CGRect frame, id configuration) {
    if (fakeLayer(@"browser") && configuration) {
        @try {
            // Class lookups at runtime — calling [WKFoo alloc] directly would
            // emit `_OBJC_CLASS_$_WKFoo` undefined symbol at link, killing
            // the dylib in apps without WebKit. objc_getClass returns the
            // Class object for already-loaded classes, nil otherwise.
            Class kUCC     = objc_getClass("WKUserContentController");
            Class kUScript = objc_getClass("WKUserScript");
            if (kUCC && kUScript) {
                WKWebViewConfiguration *cfg = (WKWebViewConfiguration *)configuration;
                WKUserContentController *ucc = cfg.userContentController;
                if (!ucc) {
                    ucc = (WKUserContentController *)[(id)[kUCC alloc] init];
                    cfg.userContentController = ucc;
                }
                NSString *js = ci_buildWebFingerprintJS();
                // Typed cast lets the compiler emit the right objc_msgSend
                // signature for (NSString*, NSInteger, BOOL) without
                // requiring _OBJC_CLASS_$_WKUserScript at link time.
                WKUserScript *script = (WKUserScript *)[(id)[kUScript alloc]
                    initWithSource:js
                     injectionTime:0  /* WKUserScriptInjectionTimeAtDocumentStart */
                  forMainFrameOnly:NO];
                if (script) [ucc addUserScript:script];
            }
        } @catch (NSException *e) {
            NSLog(@"[ChangeInfoIos] WK init JS inject exception: %@", e);
        }
    }
    return ((ci_wkInit_t)orig_WK_init)(self, _cmd, frame, configuration);
}

typedef NSString *(*ci_wkUAget_t)(id, SEL);
static NSString *ci_WK_getCustomUA(id self, SEL _cmd) {
    if (!fakeLayer(@"browser")) {
        return ((ci_wkUAget_t)orig_WK_getCustomUA)(self, _cmd);
    }
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    if (ua.length) return ua;
    return ((ci_wkUAget_t)orig_WK_getCustomUA)(self, _cmd);
}

typedef void (*ci_wkUAset_t)(id, SEL, NSString *);
static void ci_WK_setCustomUA(id self, SEL _cmd, NSString *ua) {
    if (!fakeLayer(@"browser")) {
        ((ci_wkUAset_t)orig_WK_setCustomUA)(self, _cmd, ua);
        return;
    }
    NSString *fake = getConfigStr(@"zalo_fakeWebViewUA");
    ((ci_wkUAset_t)orig_WK_setCustomUA)(self, _cmd, fake.length ? fake : ua);
}

static void ci_installWKWebViewHooks(void) {
    @autoreleasepool {
        Class wk = objc_getClass("WKWebView");
        if (!wk) return; // app does not link WebKit; skip silently
        ci_swizzleInstance("WKWebView", @selector(initWithFrame:configuration:),
                           (IMP)ci_WK_init, &orig_WK_init);
        ci_swizzleInstance("WKWebView", @selector(customUserAgent),
                           (IMP)ci_WK_getCustomUA, &orig_WK_getCustomUA);
        ci_swizzleInstance("WKWebView", @selector(setCustomUserAgent:),
                           (IMP)ci_WK_setCustomUA, &orig_WK_setCustomUA);
        NSLog(@"[ChangeInfoIos] WKWebView hooked (UA + JS fingerprint inject)");
    }
}

// CTSubscriber.phoneNumber — re-enabled via runtime swizzle (Logos %hook
// disabled in v2.3.23 because the class symbol isn't always loaded and
// caused dylib load to fault). Same pattern as DCDevice.
typedef NSString *(*CTSubscriber_phoneNumber_t)(id self, SEL _cmd);
static CTSubscriber_phoneNumber_t orig_CTSubscriber_phoneNumber = NULL;
static NSString *ci_CTSubscriber_phoneNumber(id self, SEL _cmd) {
    if (!fakeLayer(@"network")) {
        return orig_CTSubscriber_phoneNumber ? orig_CTSubscriber_phoneNumber(self, _cmd) : nil;
    }
    NSString *spoof = getConfigStr(@"PhoneNumber");
    if (spoof.length > 0) return spoof;
    return orig_CTSubscriber_phoneNumber ? orig_CTSubscriber_phoneNumber(self, _cmd) : nil;
}

static void ci_installAttestHooks(void) {
    @autoreleasepool {
        // Only walk classes that already exist in the loaded image set.
        // dlopen here is conditional: if the framework path is mapped via
        // any other dylib, objc_getClass already returns it; otherwise we
        // skip silently (apps that don't link DeviceCheck won't have the
        // hooks install, which is the safe behavior).
        if (objc_getClass("CTSubscriber")) {
            ci_swizzleInstance("CTSubscriber", @selector(phoneNumber),
                               (IMP)ci_CTSubscriber_phoneNumber,
                               (IMP *)&orig_CTSubscriber_phoneNumber);
            NSLog(@"[ChangeInfoIos] CTSubscriber.phoneNumber hooked");
        }
        if (objc_getClass("DCDevice")) {
            ci_swizzleInstance("DCDevice", @selector(isSupported),
                               (IMP)ci_DC_isSupported, (IMP *)&orig_DC_isSupported);
            ci_swizzleInstance("DCDevice", @selector(generateTokenWithCompletionHandler:),
                               (IMP)ci_DC_generateToken, (IMP *)&orig_DC_generateToken);
            NSLog(@"[ChangeInfoIos] DCDevice hooked");
        }
        if (objc_getClass("DCAppAttestService")) {
            ci_swizzleInstance("DCAppAttestService", @selector(isSupported),
                               (IMP)ci_DCA_isSupported, (IMP *)&orig_DCA_isSupported);
            ci_swizzleInstance("DCAppAttestService", @selector(generateKeyWithCompletionHandler:),
                               (IMP)ci_DCA_generateKey, (IMP *)&orig_DCA_generateKey);
            ci_swizzleInstance("DCAppAttestService", @selector(attestKey:clientDataHash:completionHandler:),
                               (IMP)ci_DCA_attestKey, (IMP *)&orig_DCA_attestKey);
            ci_swizzleInstance("DCAppAttestService", @selector(generateAssertion:clientDataHash:completionHandler:),
                               (IMP)ci_DCA_generateAssertion, (IMP *)&orig_DCA_genAssertion);
            NSLog(@"[ChangeInfoIos] DCAppAttestService hooked (incl. assertion)");
        }
        if (objc_getClass("LAContext")) {
            ci_swizzleInstance("LAContext", @selector(canEvaluatePolicy:error:),
                               (IMP)ci_LA_canEval, (IMP *)&orig_LA_canEval);
            NSLog(@"[ChangeInfoIos] LAContext hooked");
        }
    }
}

// ============================================================
// C-LEVEL HOOKS - Implemented in Hooks.mm via MSHookFunction
// (initCLvlHooks forward-declared with extern "C" at top of file)
// ============================================================

// ============================================================
// CONSTRUCTOR - Initialize on load
// ============================================================
BOOL g_bundleTargeted = NO;

static BOOL computeBundleTargeted(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length == 0) return NO;
    // Config's targetBundles (optional) — if missing, fall back to filter plist
    // semantics: any process the loader inject us into is considered targeted.
    id targets = getConfig(@"targetBundles");
    if (![targets isKindOfClass:[NSArray class]] || ((NSArray *)targets).count == 0) {
        return YES;
    }
    for (id item in (NSArray *)targets) {
        if ([item isKindOfClass:[NSString class]] && [(NSString *)item isEqualToString:bid]) {
            return YES;
        }
    }
    return NO;
}

// ============================================================
// CAMERA SPOOF — replace AVCaptureVideoDataOutput frames with a video
// the user picked in HIOS app's Camera section.
// ============================================================
// Strategy: hook -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
// and wrap the app's real delegate with our proxy. When the session
// pushes a real frame, the proxy decodes the next frame from the user's
// video file (via AVAssetReaderTrackOutput configured to match the real
// frame's pixel format + dimensions) and rebuilds a CMSampleBuffer that
// keeps the real timing info — apps' encoders see consistent PTS so
// nothing detects "synthetic" timing. Audio mic stays untouched.
//
// Format-coercion correctness: AVAssetReaderTrackOutput accepts pixel-
// format + width + height in outputSettings, so the file's frames come
// out already in the session's expected format. No manual scaling /
// colorspace conversion needed.
//
// Reader is lazy-initialised on the first frame so we know the exact
// target dimensions before opening the file (different sessions ask for
// 720p vs 1080p, front vs back, etc.).

@interface CISpoofProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, copy) NSString *videoPath;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, assign) int initState; // 0 not yet, 1 ready, 2 failed
@property (nonatomic, assign) size_t targetW;
@property (nonatomic, assign) size_t targetH;
@property (nonatomic, assign) OSType targetPixelFormat;
@end

@implementation CISpoofProxyDelegate

- (BOOL)setupReader {
    @autoreleasepool {
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:self.videoPath]];
        if (!asset) return NO;
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) return NO;
        NSError *err = nil;
        AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
        if (!r) return NO;
        NSDictionary *outSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(self.targetPixelFormat),
            (NSString *)kCVPixelBufferWidthKey:  @(self.targetW),
            (NSString *)kCVPixelBufferHeightKey: @(self.targetH),
            (NSString *)kCVPixelBufferIOSurfacePropertiesKey: @{},
        };
        AVAssetReaderTrackOutput *to = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:tracks[0]
                             outputSettings:outSettings];
        if (!to) return NO;
        if (![r canAddOutput:to]) return NO;
        [r addOutput:to];
        if (![r startReading]) return NO;
        self.reader = r;
        self.trackOutput = to;
        return YES;
    }
}

// In-place pixel swap: copy spoof video's planes into the REAL CVPixelBuffer
// so all metadata (CMSampleBuffer attachments, format description extensions,
// CVBuffer color attachments, IOSurface backing, exposure/ISO/lens metadata
// dicts) stays exactly as the camera emitted it. Anti-spoof SDKs read those
// attachments to verify the buffer came from a real sensor — synthetic
// buffers built via CMSampleBufferCreate* lose them and look obviously fake.
//
// After the copy, we sprinkle ±3 luma units of uniform noise across the Y
// plane (or full plane for non-planar formats). Two reasons:
// 1. Defeats forensic frame-hash matching. Without noise, a looping spoof
//    video produces byte-identical frame N every cycle — Zalo's async
//    backend scan computes per-frame perceptual hashes, sees the same
//    hash repeating across the timeline → trivial replay-attack flag.
//    With ±3 luma noise per frame, no two frames are byte-equal even
//    when the underlying source frame is identical.
// 2. Mimics real-sensor photon shot noise. Real iPhone sensors emit
//    luma std-dev ~3-5 units depending on ISO; pre-encoded videos that
//    came from a different sensor get noise-suppressed during encode and
//    look "too clean". Adding back the noise stat matches what a real
//    sensor would emit, defeating simple noise-floor heuristics.
//
// Speed: ~1ms for 720p Y plane on A14 — well under the 33ms frame budget.
static inline uint8_t ci_addClampedNoise(uint8_t v, int n) {
    int r = (int)v + n;
    return (uint8_t)(r < 0 ? 0 : (r > 255 ? 255 : r));
}

static void ci_injectNoiseY(uint8_t *base, size_t w, size_t h, size_t bpr) {
    // arc4random is overkill cost-wise per pixel; use a lightweight LCG
    // seeded from arc4random once per frame. Statistical quality fine
    // for our purpose (defeating byte-equality, not crypto).
    uint32_t state = arc4random();
    for (size_t y = 0; y < h; y++) {
        uint8_t *row = base + y * bpr;
        for (size_t x = 0; x < w; x++) {
            state = state * 1664525u + 1013904223u;
            int n = ((int)(state >> 24) % 7) - 3; // [-3, +3]
            row[x] = ci_addClampedNoise(row[x], n);
        }
    }
}

static BOOL ci_copyPlanesIntoBuffer(CVPixelBufferRef src, CVPixelBufferRef dst) {
    if (!src || !dst) return NO;
    if (CVPixelBufferLockBaseAddress(dst, 0) != kCVReturnSuccess) return NO;
    if (CVPixelBufferLockBaseAddress(src, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(dst, 0);
        return NO;
    }
    BOOL ok = YES;
    size_t planes = CVPixelBufferGetPlaneCount(dst);
    if (planes == 0) {
        // Non-planar (BGRA etc.). One contiguous plane.
        void *sb = CVPixelBufferGetBaseAddress(src);
        void *db = CVPixelBufferGetBaseAddress(dst);
        size_t srb = CVPixelBufferGetBytesPerRow(src);
        size_t drb = CVPixelBufferGetBytesPerRow(dst);
        size_t w   = CVPixelBufferGetWidth(dst);
        size_t h   = CVPixelBufferGetHeight(dst);
        if (!sb || !db) { ok = NO; }
        else {
            size_t copy = MIN(srb, drb);
            for (size_t y = 0; y < h; y++) {
                memcpy((char *)db + y*drb, (char *)sb + y*srb, copy);
            }
            // Noise on the BGRA buffer: stride is 4*width, hit channel 0 (B)
            // for simplicity — single-channel noise still defeats byte hashing
            // and visually invisible at ±3.
            uint8_t *base = (uint8_t *)db;
            uint32_t state = arc4random();
            for (size_t y = 0; y < h; y++) {
                uint8_t *row = base + y * drb;
                for (size_t x = 0; x < w; x++) {
                    state = state * 1664525u + 1013904223u;
                    int n = ((int)(state >> 24) % 7) - 3;
                    row[x*4] = ci_addClampedNoise(row[x*4], n);
                }
            }
        }
    } else {
        size_t srcPlanes = CVPixelBufferGetPlaneCount(src);
        if (srcPlanes != planes) { ok = NO; }
        for (size_t p = 0; ok && p < planes; p++) {
            void *sb = CVPixelBufferGetBaseAddressOfPlane(src, p);
            void *db = CVPixelBufferGetBaseAddressOfPlane(dst, p);
            size_t srb = CVPixelBufferGetBytesPerRowOfPlane(src, p);
            size_t drb = CVPixelBufferGetBytesPerRowOfPlane(dst, p);
            size_t h   = CVPixelBufferGetHeightOfPlane(dst, p);
            if (!sb || !db) { ok = NO; break; }
            size_t copy = MIN(srb, drb);
            for (size_t y = 0; y < h; y++) {
                memcpy((char *)db + y*drb, (char *)sb + y*srb, copy);
            }
        }
        // Noise on the Y (luma) plane only — chroma is at half-resolution
        // in NV12 and flooding it with noise visibly tints the frame.
        if (ok) {
            uint8_t *yBase = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(dst, 0);
            size_t yW = CVPixelBufferGetWidthOfPlane(dst, 0);
            size_t yH = CVPixelBufferGetHeightOfPlane(dst, 0);
            size_t yBpr = CVPixelBufferGetBytesPerRowOfPlane(dst, 0);
            ci_injectNoiseY(yBase, yW, yH, yBpr);
        }
    }
    CVPixelBufferUnlockBaseAddress(src, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(dst, 0);
    return ok;
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)real
       fromConnection:(AVCaptureConnection *)conn {

    if (!getConfigBool(@"cameraSpoofEnabled") || self.videoPath.length == 0) {
        if (self.realDelegate) {
            [self.realDelegate captureOutput:output didOutputSampleBuffer:real fromConnection:conn];
        }
        return;
    }

    // Lazy init on first frame — peek format / size from the real buffer so
    // the AVAssetReader hands back frames in the EXACT format/dim the session
    // is using. Avoids any conversion path (no scaling, no colorspace
    // transform) and keeps the planes byte-compatible for the in-place copy.
    if (self.initState == 0) {
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(real);
        if (pb) {
            self.targetW = CVPixelBufferGetWidth(pb);
            self.targetH = CVPixelBufferGetHeight(pb);
            self.targetPixelFormat = CVPixelBufferGetPixelFormatType(pb);
            self.initState = [self setupReader] ? 1 : 2;
            if (self.initState == 1) {
                NSLog(@"[ChangeInfoIos] cam spoof reader ready (%lux%lu fmt=0x%08x video=%@)",
                      self.targetW, self.targetH, self.targetPixelFormat, self.videoPath);
            } else {
                NSLog(@"[ChangeInfoIos] cam spoof reader init FAILED — fall back to real frames");
            }
        }
    }

    if (self.initState != 1) {
        if (self.realDelegate) {
            [self.realDelegate captureOutput:output didOutputSampleBuffer:real fromConnection:conn];
        }
        return;
    }

    // Pull next decoded frame; loop video on EOF by re-init'ing the reader.
    CMSampleBufferRef spoof = [self.trackOutput copyNextSampleBuffer];
    if (!spoof) {
        [self.reader cancelReading];
        self.reader = nil;
        self.trackOutput = nil;
        if ([self setupReader]) {
            spoof = [self.trackOutput copyNextSampleBuffer];
        } else {
            self.initState = 2;
        }
    }
    if (!spoof) {
        if (self.realDelegate) {
            [self.realDelegate captureOutput:output didOutputSampleBuffer:real fromConnection:conn];
        }
        return;
    }

    // The big idea: don't build a new CMSampleBuffer. Take the REAL one
    // (which carries the sensor's full metadata) and copy our spoof pixel
    // data into its CVPixelBuffer, leaving everything else untouched. Anti-
    // spoof SDKs that grep CMSampleBufferGetSampleAttachmentsArray /
    // CVBufferGetAttachments / CMSampleBufferGetFormatDescription's
    // extensions for sensor-emitted keys still find them, because they
    // were never removed. The only thing changed is the YCbCr / BGRA bytes.
    CVImageBufferRef realPB  = CMSampleBufferGetImageBuffer(real);
    CVImageBufferRef spoofPB = CMSampleBufferGetImageBuffer(spoof);
    BOOL inPlaceOK = NO;
    if (realPB && spoofPB) {
        inPlaceOK = ci_copyPlanesIntoBuffer(spoofPB, realPB);
    }
    CFRelease(spoof);

    if (!inPlaceOK) {
        // Real buffer wasn't writable (read-only IOSurface from kernel?). Log
        // once + pass through real frame so the call doesn't break.
        static int s_warned = 0;
        if (!s_warned) {
            s_warned = 1;
            NSLog(@"[ChangeInfoIos] cam spoof: in-place copy failed (real PB read-only?) — frames stay real");
        }
        if (self.realDelegate) {
            [self.realDelegate captureOutput:output didOutputSampleBuffer:real fromConnection:conn];
        }
        return;
    }
    if (self.realDelegate) {
        [self.realDelegate captureOutput:output didOutputSampleBuffer:real fromConnection:conn];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sb
       fromConnection:(AVCaptureConnection *)conn {
    if ([self.realDelegate respondsToSelector:@selector(captureOutput:didDropSampleBuffer:fromConnection:)]) {
        [self.realDelegate captureOutput:output didDropSampleBuffer:sb fromConnection:conn];
    }
}

@end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!getConfigBool(@"cameraSpoofEnabled") || delegate == nil) {
        %orig(delegate, queue);
        return;
    }
    NSString *path = getConfigStr(@"cameraSpoofVideoPath");
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        %orig(delegate, queue);
        return;
    }
    // Don't double-wrap when app re-sets its own delegate (or sets nil mid-session).
    if ([delegate isKindOfClass:[CISpoofProxyDelegate class]]) {
        %orig(delegate, queue);
        return;
    }
    CISpoofProxyDelegate *proxy = [CISpoofProxyDelegate new];
    proxy.realDelegate = delegate;
    proxy.videoPath = path;
    objc_setAssociatedObject(self, "ci_spoofProxy", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[ChangeInfoIos] cam spoof installed (real=%@ path=%@)", NSStringFromClass([delegate class]), path);
    %orig(proxy, queue);
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";

        // SAFETY GUARD — broad UIKit filter inject puts us in every GUI app,
        // including system processes that brick the device when hooked
        // (v2.3.24 incident). Bail BEFORE writing the marker / loading config
        // for any process on this denylist. The list mirrors the system-app
        // bundles whose loop tightness or framework reach makes them unsafe
        // to wrap with hundreds of Logos hooks at once.
        static NSArray *kSystemDenyBundles = nil;
        kSystemDenyBundles = @[
            @"com.apple.springboard",
            @"com.apple.Preferences",
            @"com.apple.mobilesafari",
            @"com.apple.webapp",
            @"com.apple.mobilesms",
            @"com.apple.MobileSMS",
            @"com.apple.AppStore",
            @"com.apple.camera",
            @"com.apple.Maps",
            @"com.apple.mobilephone",
            @"com.apple.Spotlight",
            @"com.apple.PineBoard",
            @"com.apple.InCallService",
            @"com.apple.coreauthd",
            @"com.apple.HealthExtensions",
            @"com.apple.Health",
            @"com.apple.WebKit",
            @"com.apple.WebKit.Networking",
            @"com.apple.WebKit.WebContent",
        ];
        for (NSString *deny in kSystemDenyBundles) {
            if ([bid isEqualToString:deny]) {
                NSLog(@"[ChangeInfoIos] Skipping system bundle %@ — denylist match", bid);
                return;
            }
        }

        // Write injection marker FIRST (even when we're going to early-exit)
        // so the Debug screen can prove the dylib was loaded into this process.
        NSString *markerDir = @"/var/mobile/Library/Caches/ChangeInfoIos";
        [[NSFileManager defaultManager] createDirectoryAtPath:markerDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *marker = [markerDir stringByAppendingFormat:@"/injected_%@.txt", bid];
        NSString *stamp = [NSString stringWithFormat:@"%@|%ld", bid, (long)time(NULL)];
        [stamp writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        chmod([marker fileSystemRepresentation], 0644);

        // Sandbox-friendly markers — written to BOTH /var/jb/etc/* (works
        // for system processes) AND NSTemporaryDirectory() (works for
        // every sandboxed app, since the temp dir is inside the app's
        // own data container). The /var/jb path turned out to be
        // read-only from App Store app sandboxes — confirmed live
        // 2026-05-07 when sandboxed Zalo's loaded_*.txt write silently
        // failed even though ChangeInfoIos.dylib was confirmed loaded
        // (HelloInject's hios_hello.txt did appear in Zalo's tmp/, while
        // ChangeInfoIos's loaded_<bid>.txt under /var/jb did not).
        NSString *sbDir = @"/var/jb/etc/changeinfoios";
        NSString *sbMarker = [sbDir stringByAppendingFormat:@"/loaded_%@.txt", bid];
        [stamp writeToFile:sbMarker atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *tmpDir = NSTemporaryDirectory();
        if (tmpDir.length) {
            NSString *tmpMarker = [tmpDir stringByAppendingPathComponent:@"hios_changeinfo_loaded.txt"];
            [stamp writeToFile:tmpMarker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }

        loadConfig();
        g_bundleTargeted = computeBundleTargeted();

        // Early-exit when not targeted. Logos %hook directives were already
        // linked into the dylib (we can't skip them), but MSHookFunction and
        // Darwin notify + container wipe are skipped — saves ~80% of the
        // per-process work for non-target processes the loader drops us into.
        if (!g_bundleTargeted) {
            NSLog(@"[ChangeInfoIos] Loaded into non-target bundle %@ — skipping hook init", bid);
            return;
        }

        NSLog(@"[ChangeInfoIos] Tweak loading for %@...", bid);
        ci_wipeContainerIfScheduled();

        // Keychain restore: if host app dropped a restore flag (via RRS
        // restore), apply the snapshot BEFORE the host app reads any
        // keychain entries. Suppress the auto-dump 5s later so we don't
        // overwrite the just-restored data with… the same data. Otherwise
        // schedule a background dump to keep the snapshot fresh per launch.
        BOOL didRestore = ci_restoreKeychainIfFlagged();
        if (!didRestore) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                ci_dumpKeychain();
            });
        }
        // On-demand dump trigger from host app (sent via notify_post just
        // before tar). Listener stays installed for the lifetime of the
        // process so RRS backups always hit a current snapshot.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            ci_onDumpKeychainNotification,
            CFSTR("com.changeinfoios/dump_keychain"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onPrefsDarwinNotify, CFSTR("com.changeinfoios/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);

        // EMERGENCY KILL-SWITCH: MG install hardcoded OFF until we
        // diagnose the trampoline / libMobileGestalt iOS 16.7 interaction
        // that gave us the recursive ellekit.portLoop SIGBUS at
        // _UIDeviceNativeUserInterfaceIdiomIgnoringClassic during Zalo
        // scene init (3+ confirmed crashes today). The user's keychain
        // backup test re-hit the same crash because Reset Data overwrites
        // /var/jb/etc/changeinfoios/config.plist from in-memory _cfg, and
        // the SSH-set _ci_skip_mg flag wasn't persisted on the host-app
        // side — so on next reset the gate flipped back, MG hooks
        // installed, Zalo crashed again.
        // Until we have a real fix, force-skip via condition that's
        // always true: read both the SSH override (still wired so we can
        // re-test selectively) AND a hardcoded default-true. UIDevice /
        // IOReg / sysctl / DC / WK / location hooks remain active, so
        // spoof depth is good — only ProductType / HardwareModel /
        // UniqueChipID through MGCopyAnswer falls through to real values.
        // Re-enabled. Earlier crash was caused by NSLog inside the hook
        // recursing through ASL → MGCopyAnswer; fixed via __thread
        // g_ci_inMGHook re-entrancy guard at top of each MG hook.
        BOOL kSkipMG_HARDCODED = NO;
        if (!kSkipMG_HARDCODED && !getConfigBool(@"_ci_skip_mg")) {
            void *mgHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (mgHandle) {
                orig_MGCopyAnswer = (MGCopyAnswer_t)dlsym(mgHandle, "MGCopyAnswer");
                if (!orig_MGCopyAnswer)
                    orig_MGCopyAnswer = (MGCopyAnswer_t)dlsym(mgHandle, "MGCopyAnswer_internal");
                if (orig_MGCopyAnswer) {
                    MSHookFunction((void *)orig_MGCopyAnswer, (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
                    NSLog(@"[ChangeInfoIos] MGCopyAnswer hooked");
                } else {
                    NSLog(@"[ChangeInfoIos] MGCopyAnswer symbol not found");
                }

                orig_MGGetBoolAnswer = (MGGetBoolAnswer_t)dlsym(mgHandle, "MGGetBoolAnswer");
                if (orig_MGGetBoolAnswer) {
                    MSHookFunction((void *)orig_MGGetBoolAnswer, (void *)hooked_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer);
                    NSLog(@"[ChangeInfoIos] MGGetBoolAnswer hooked");
                }

                orig_MGGetStringAnswer = (MGGetStringAnswer_t)dlsym(mgHandle, "MGGetStringAnswer");
                if (orig_MGGetStringAnswer) {
                    MSHookFunction((void *)orig_MGGetStringAnswer, (void *)hooked_MGGetStringAnswer, (void **)&orig_MGGetStringAnswer);
                    NSLog(@"[ChangeInfoIos] MGGetStringAnswer hooked");
                }
            }
        } else {
            NSLog(@"[ChangeInfoIos] _ci_skip_mg=YES — skipping MG hook install entirely");
        }

        void *iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokitHandle) {
            orig_IORegistryEntryCreateCFProperty = (IORegCreateCFProp_t)dlsym(iokitHandle, "IORegistryEntryCreateCFProperty");
            if (orig_IORegistryEntryCreateCFProperty) {
                MSHookFunction((void *)orig_IORegistryEntryCreateCFProperty, (void *)hooked_IORegistryEntryCreateCFProperty, (void **)&orig_IORegistryEntryCreateCFProperty);
                NSLog(@"[ChangeInfoIos] IOKit hooked");
            }
        }

        // Initialize C-level hooks from Hooks.mm
        initCLvlHooks();

        // Conditional attest/biometric hooks via objc_getClass — only when
        // the framework is already mapped into the host process.
        ci_installAttestHooks();

        // WKWebView fingerprint spoof (UA + JS canvas/WebGL/WebRTC noise).
        // Same runtime-only swizzle pattern; skipped in apps without WebKit.
        ci_installWKWebViewHooks();

        // WebRTC ICE candidate filter — strips host/srflx candidates that
        // leak local IP. Only installs in processes that link WebRTC.
        ci_installWebRTCHooks();

        NSLog(@"[ChangeInfoIos] Tweak loaded successfully! Config: %@", configLoaded ? @"YES" : @"NO");
    }
}
