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
#include "fishhook.h"
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
BOOL         ci_isHiddenJBPath(const char *path); // defined in Hooks.mm
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
        // FLAG + DUMP path strategy:
        //   PRIMARY: /var/jb/etc/changeinfoios/{restore_<bid>.flag, dump_<bid>.plist}
        //     Survives across app launches. iOS / Zalo clear the per-app
        //     tmp/ on every launch — confirmed live 2026-05-19: a flag +
        //     32 KB dump placed via SSH in tmp/ DISAPPEARED before tweak
        //     %ctor could read them, because Zalo's launch sequence wipes
        //     tmp/ first. /var/jb/etc/changeinfoios is owned by the
        //     tweak's host-app deb and never gets purged.
        //   LEGACY: <container>/tmp/{hios_keychain_restore.flag,
        //                            hios_keychain.plist}
        //     Kept as fallback for backward compat with any RRS user
        //     restored under v2.4.9 or earlier; new restores write to
        //     PRIMARY.
        //
        // CONSUMED-MARKER:
        //   Tweak can READ /var/jb/etc/changeinfoios/ but NOT WRITE there
        //   (sandbox MAC blocks writes outside the app's container). So
        //   we can't delete the flag after restore. Instead, write a
        //   "consumed_<flag-mtime>.marker" inside the app's own
        //   Library/Caches/ChangeInfoIos/ — that path IS sandbox-writable
        //   and DOES survive launches. Next %ctor: if marker matching
        //   flag's current mtime exists → skip restore (already done).
        //   If not → run restore + drop marker.
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return NO;

        void (^trace)(NSString *) = ^(NSString *msg) {
            NSString *line = [NSString stringWithFormat:@"%@ %@: %@\n",
                              [NSDate date], bid, msg];
            NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"trace_%@.log", bid]];
            if (!p.length) return;
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
            if (!fh) {
                [line writeToFile:p atomically:NO encoding:NSUTF8StringEncoding error:nil];
            } else {
                [fh seekToEndOfFile];
                [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        };

        trace(@"entered");
        NSString *sharedDir = @"/var/jb/etc/changeinfoios";
        NSString *primaryFlag = [sharedDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"restore_%@.flag", bid]];
        NSString *primaryDump = [sharedDir stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"dump_%@.plist", bid]];
        NSString *legacyFlag = ci_keychainRestoreFlag(bid);
        NSString *legacyDump = ci_keychainBackupPath(bid);

        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *flagPath = nil, *dumpPath = nil;
        if ([fm fileExistsAtPath:primaryFlag]) {
            flagPath = primaryFlag;
            dumpPath = primaryDump;
            trace(@"flag found at PRIMARY (/var/jb/etc)");
        } else if ([fm fileExistsAtPath:legacyFlag]) {
            flagPath = legacyFlag;
            dumpPath = legacyDump;
            trace(@"flag found at LEGACY (tmp/)");
        } else {
            trace(@"early-exit: NO FLAG (neither primary nor legacy)");
            return NO;
        }

        // Consumed-marker check: compare flag's mtime to the per-bid
        // marker written by the LAST successful restore.
        NSDictionary *flagAttrs = [fm attributesOfItemAtPath:flagPath error:nil];
        NSDate *flagMtime = flagAttrs[NSFileModificationDate];
        NSArray *libDirs = NSSearchPathForDirectoriesInDomains(
            NSCachesDirectory, NSUserDomainMask, YES);
        NSString *consumedDir = [libDirs.firstObject stringByAppendingPathComponent:@"ChangeInfoIos"];
        [fm createDirectoryAtPath:consumedDir withIntermediateDirectories:YES
                       attributes:nil error:nil];
        NSString *consumedPath = [consumedDir stringByAppendingPathComponent:@"last_restore.marker"];
        // Content-based consumed marker (v2.4.34): write the flag's epoch
        // (whole seconds) into the marker file as text, then compare on
        // next launch. Sidesteps the NSDate-vs-filesystem mtime precision
        // issue that broke v2.4.32 and v2.4.33 — strict NSDate compare
        // saw ~100ns skew between flagMtime and the round-tripped marker
        // mtime, and the tolerance-window check unexpectedly never
        // entered (consumedAttrs[NSFileModificationDate] came back nil
        // for reasons not yet root-caused), so tweak re-ran restore on
        // every launch and the user's swipe-killed Zalo always came back
        // to the login screen.
        NSString *flagEpochStr = nil;
        if (flagMtime) {
            flagEpochStr = [NSString stringWithFormat:@"%.0f",
                            [flagMtime timeIntervalSince1970]];
        }
        NSString *consumedContent = [NSString stringWithContentsOfFile:consumedPath
                                                              encoding:NSUTF8StringEncoding
                                                                 error:nil];
        consumedContent = [consumedContent stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        trace([NSString stringWithFormat:@"consumed-marker check: flag=%@ marker=%@",
                                          flagEpochStr ?: @"(nil)",
                                          consumedContent ?: @"(nil)"]);
        if (flagEpochStr && consumedContent.length > 0
            && [flagEpochStr isEqualToString:consumedContent]) {
            trace(@"early-exit: flag epoch matches consumed-marker");
            return NO;
        }

        NSDictionary *dumpAttrs = [fm attributesOfItemAtPath:dumpPath error:nil];
        trace([NSString stringWithFormat:@"dump path=%@ size=%llu",
               dumpPath, [dumpAttrs[NSFileSize] unsignedLongLongValue]]);
        NSArray *all = [NSArray arrayWithContentsOfFile:dumpPath];
        trace([NSString stringWithFormat:@"parsed: isArray=%d count=%lu",
               [all isKindOfClass:[NSArray class]],
               (unsigned long)([all isKindOfClass:[NSArray class]] ? all.count : 0)]);
        if (![all isKindOfClass:[NSArray class]]) {
            trace(@"early-exit: dump not an array");
            // DON'T remove flag from /var/jb/etc — tweak has no write
            // permission there. Only consume the legacy tmp/ flag.
            if ([flagPath isEqualToString:legacyFlag]) {
                [fm removeItemAtPath:legacyFlag error:nil];
            }
            return NO;
        }
        trace(@"proceeding to SecItem loop");

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

        // Two-pass strip lists. The first pass strips ONLY truly
        // system-managed read-only attrs that SecItemAdd always rejects
        // (creation/modification dates, persistent ref, sha1 row hash,
        // musr per-user multiuser tag). It DELIBERATELY KEEPS:
        //   - kSecAttrAccessGroup / "agrp": items in Zalo's shared
        //     keychain group "CVB6BX97VM.group.keychain.vn.com.vng.zalo"
        //     MUST be restored back into that group, otherwise Zalo's
        //     code reads from the shared group and finds nothing →
        //     session-token lookup misses → login screen even though we
        //     just restored a 32 KB dump. Verified live 2026-05-19:
        //     stripping agrp gave 11/N entries in the default per-app
        //     group, which doesn't match Zalo's reads. Host process (the
        //     target app itself) carries the entitlement for its own
        //     groups, so SecItemAdd accepts the agrp value.
        //   - kSecAttrAccessible / "pdmn": Apple's data-protection class
        //     (WhenUnlocked vs AfterFirstUnlock vs AlwaysThisDeviceOnly).
        //     Keep so items restore to the same protection class they
        //     came from — mismatched class breaks reads in some flows.
        //
        // If the first pass returns errSecMissingEntitlement (-34018)
        // or related access-group errors, the SECOND pass falls back to
        // also stripping agrp/pdmn → item lands in the default group
        // with default protection. Better than not restoring at all.
        NSArray *strictStrip = @[
            (__bridge NSString *)kSecAttrCreationDate,
            (__bridge NSString *)kSecAttrModificationDate,
            @"persistref", @"musr", @"sha1", @"cdat", @"mdat",
        ];
        NSArray *fallbackExtra = @[
            (__bridge NSString *)kSecAttrAccessGroup,
            (__bridge NSString *)kSecAttrAccessible,
            @"agrp", @"pdmn",
        ];

        NSUInteger added = 0, fallbackAdded = 0;
        NSMutableDictionary<NSString *, NSNumber *> *statusHist = [NSMutableDictionary dictionary];
        // Per-entry log written to /var/jb/etc/changeinfoios/restore_<bid>.log
        // for SSH-side diagnosis when NSLog output doesn't reach `log show`.
        // This is the only way to see WHICH entry failed with WHICH error
        // when the dump has 29 entries but only 11 survive — the histogram
        // alone doesn't tell us which keys.
        NSMutableString *restoreLog = [NSMutableString string];
        [restoreLog appendFormat:@"=== restore start: bid=%@ entries=%lu at=%@ ===\n",
                                  bid, (unsigned long)all.count, [NSDate date]];
        for (NSDictionary *enc in all) {
            if (![enc isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *e = ci_decodeKCEntry(enc);
            NSString *cls = e[@"__class"];
            if (!cls) continue;
            [e removeObjectForKey:@"__class"];
            for (NSString *k in strictStrip) [e removeObjectForKey:k];
            e[(__bridge NSString *)kSecClass] = cls;

            NSString *acct = e[@"acct"] ?: @"-";
            NSString *svce = e[@"svce"] ?: @"-";
            NSString *agrp = e[@"agrp"] ?: @"-";

            OSStatus s = SecItemAdd((__bridge CFDictionaryRef)e, NULL);
            if (s == errSecSuccess) {
                added++;
                [restoreLog appendFormat:@"  OK   acct=%@ svce=%@ agrp=%@\n", acct, svce, agrp];
            } else {
                // Track histogram for diag and decide whether to retry.
                NSString *key = [NSString stringWithFormat:@"%d", (int)s];
                statusHist[key] = @([statusHist[key] integerValue] + 1);
                [restoreLog appendFormat:@"  P1=%d acct=%@ svce=%@ agrp=%@", (int)s, acct, svce, agrp];

                // -34018 = errSecMissingEntitlement; -25243 = errSecNoAccessForItem.
                // For any error, retry with agrp/pdmn stripped — the cost is
                // landing in default group instead of failing entirely.
                NSMutableDictionary *fallback = [e mutableCopy];
                for (NSString *k in fallbackExtra) [fallback removeObjectForKey:k];
                OSStatus s2 = SecItemAdd((__bridge CFDictionaryRef)fallback, NULL);
                if (s2 == errSecSuccess) {
                    fallbackAdded++;
                    [restoreLog appendFormat:@" → P2=OK (default group)\n"];
                } else {
                    [restoreLog appendFormat:@" → P2=%d (LOST)\n", (int)s2];
                }
            }
        }

        g_ci_skipKeychainHook--;

        // v2.4.35: removed wipe-guard activation. The runtime guard hooks
        // (sqlite3 + NSFileManager) interfered with Zalo's legitimate
        // session-write ops and caused swipe-kill + reopen to revert to
        // login screen. User requested baseline restore behavior: copy
        // data + apply keychain dump, no further runtime interference.

        // Consume the flag.
        //   - Legacy tmp/ flag: tweak can delete (same sandbox).
        //   - Primary /var/jb/etc/ flag: tweak CAN'T delete (sandbox MAC).
        //     Write flag-mtime epoch (whole seconds) into a consumed
        //     marker file under Library/Caches/ChangeInfoIos/. Next launch
        //     reads the file content and compares the string to the
        //     current flag mtime epoch. Content-based avoids the NSDate
        //     vs filesystem mtime precision mismatch that defeated the
        //     v2.4.32/33 attempts. Library/Caches survives across launches.
        if ([flagPath isEqualToString:legacyFlag]) {
            [fm removeItemAtPath:legacyFlag error:nil];
        } else if (flagEpochStr) {
            [flagEpochStr writeToFile:consumedPath atomically:NO
                             encoding:NSUTF8StringEncoding error:nil];
        }

        [restoreLog appendFormat:@"=== summary: %lu primary + %lu fallback / %lu total (hist=%@) ===\n",
                                  (unsigned long)added, (unsigned long)fallbackAdded,
                                  (unsigned long)all.count, statusHist];
        // File-side log: SSH-readable forensic trace. Library/Caches/
        // survives across launches (unlike tmp/) so even after Zalo
        // wipes tmp/ on next launch, this log persists.
        NSString *libLog = [consumedDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"restore.log"]];
        [restoreLog writeToFile:libLog atomically:NO
                       encoding:NSUTF8StringEncoding error:nil];
        // Also write to tmp/ for convenience while debugging the current
        // launch (will be wiped on next launch, which is fine).
        NSString *tmpLog = [NSTemporaryDirectory() stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"restore_%@.log", bid]];
        [restoreLog writeToFile:tmpLog atomically:NO
                       encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[ChangeInfoIos] keychain restore: %lu primary + %lu fallback / %lu entries reapplied (hist=%@)",
              (unsigned long)added, (unsigned long)fallbackAdded,
              (unsigned long)all.count, statusHist);
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
        // v2.4.47: also wipe the bundle's keychain entries (generic +
        // internet password classes). Previously only wiped during restore
        // flow via ci_restoreKeychainIfFlagged. Pure Reset Data left the
        // old session keychain intact → next launch app saw old token →
        // partial-state account. Clearing here matches user expectation
        // of "fresh install equivalent".
        g_ci_skipKeychainHook++;
        for (NSString *cls in @[(__bridge NSString *)kSecClassGenericPassword,
                                (__bridge NSString *)kSecClassInternetPassword]) {
            NSDictionary *q = @{ (__bridge NSString *)kSecClass: cls };
            SecItemDelete((__bridge CFDictionaryRef)q);
        }
        g_ci_skipKeychainHook--;

        [[NSString stringWithFormat:@"%lld", counter] writeToFile:marker
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[ChangeInfoIos] Wiped %@ (counter=%lld, items=%lu, keychain cleared)",
              bid, counter, (unsigned long)removed);
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

// Wall-clock anchor set at dylib %ctor. Used by drift-style hooks
// (batteryLevel, systemUptime) so the host app sees a value that
// advances with real time instead of returning the same constant on
// every read — a real device's battery slowly discharges and uptime
// always grows. Two reads N seconds apart MUST differ by ~N or the
// host app's anti-bot timing checks flag the read as a replay.
static CFAbsoluteTime g_dylibLoadTime = 0.0;

// Cache for the "fake_<shortName>" key strings. fakeLayer is called from
// EVERY hooked method invocation; -[NSString stringWithFormat:] allocates
// a fresh NSString each call. With Phase 6+7+Batches we have ~30 hooks
// and Zalo can fire millions of UIDevice/sysctl/timing calls/sec — the
// allocation churn alone causes visible UI lag. Cache the formatted key
// per shortName so we only pay the format cost once per (shortName).
static NSMutableDictionary<NSString *, NSString *> *g_fakeKeyCache = nil;
static dispatch_once_t g_fakeKeyCacheOnce;

BOOL fakeLayer(NSString *shortName) {
    if (g_inFakeLayer) return NO;
    g_inFakeLayer++;
    BOOL out = NO;
    // Emergency runtime kill-switch — set _ci_skipall=YES via SSH to make
    // every %hook fall through to %orig without re-installing the dylib.
    if (!getConfigBool(@"_ci_skipall") && isCurrentBundleTargeted()) {
        dispatch_once(&g_fakeKeyCacheOnce, ^{
            g_fakeKeyCache = [NSMutableDictionary dictionaryWithCapacity:32];
        });
        NSString *full;
        @synchronized (g_fakeKeyCache) {
            full = g_fakeKeyCache[shortName];
            if (!full) {
                full = [@"fake_" stringByAppendingString:shortName];
                g_fakeKeyCache[shortName] = full;
            }
        }
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
    if (!val) return %orig;
    float base = [val floatValue];
    // Slow drift: ~1% per 20min. Two reads 1 minute apart differ ~0.0008 →
    // never crosses an int-percent boundary in a single registration flow,
    // so the host app still sees a stable "73%" UI, but a logger sampling
    // every second sees realistic noise. Discharge always (sign chosen to
    // match the most common batteryState=unplugged path).
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double minutesSinceLoad = (now - g_dylibLoadTime) / 60.0;
    if (minutesSinceLoad < 0) minutesSinceLoad = 0;
    float drift = (float)(minutesSinceLoad / 20.0 / 100.0);  // % → 0..1 scale
    float out = base - drift;
    if (out < 0.05f) out = 0.05f;  // never drain to zero mid-session
    if (out > 1.0f)  out = 1.0f;
    return out;
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

// RE-ENABLED 2026-05-09. The earlier 4-second register lag was wrongly
// blamed on this hook; bisect later traced it to the LSApplicationWork
// space recursion (c525ab7). _deviceInfoForKey: is safe to hook —
// fakeLayer is cached, map lookup is sub-microsecond.
//
// This is the canonical UIDevice-internal path that calls MGCopyAnswer.
// With our MG hook permanently disabled (substrate brk on iOS 16.7.11),
// most fingerprint SDKs (Crashlytics, AppsFlyer, Adjust, Firebase) read
// device info through this path. Without spoofing here, every
// registration leaks REAL UDID/Serial/IMEI to backend → 1-2h async
// correlation flags 4 of 5 accounts.
//
// Slim'd to 12 highest-impact keys (down from 30) to keep per-call
// cost minimal. Other keys fall through to %orig (real values) — but
// those aren't typically the ones SDKs fingerprint on.
- (id)_deviceInfoForKey:(NSString *)key {
    if (!fakeLayer(@"hardware") || !key) return %orig;
    if (getConfigBool(@"_ci_skip_mg")) return %orig;

    static NSDictionary *map = nil;
    if (!map) {
        map = @{
            @"ProductType":                          @"ProductType",
            @"HardwareModel":                        @"HardwareModel",
            @"SerialNumber":                         @"SerialNumber",
            @"UniqueDeviceID":                       @"UniqueDeviceID",
            @"UniqueDeviceIDData":                   @"UniqueDeviceID",
            @"UniqueChipID":                         @"UniqueChipID",
            @"InternationalMobileEquipmentIdentity": @"InternationalMobileEquipmentIdentity",
            @"InternationalMobileEquipmentIdentity2":@"InternationalMobileEquipmentIdentity2",
            @"IntegratedCircuitCardIdentity":        @"IntegratedCircuitCardIdentity",
            @"WiFiAddress":                          @"WiFiAddress",
            @"BluetoothAddress":                     @"BluetoothAddress",
            @"EthernetMacAddress":                   @"EthernetAddress",
        };
    }
    NSString *configKey = map[key];
    if (configKey) {
        NSString *val = getConfigStr(configKey);
        if (val.length > 0) return val;
    }
    return %orig;
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
        // Multiple MG keys all alias to the same iOS version / build version
        // values. AIDA64 / device-info SDKs read via ProductBuildVersion or
        // SoftwareBundleVersion (NOT just BuildVersion), so if we miss any
        // alias the unhooked path returns the device's REAL build number
        // (e.g., 20H360 = iOS 16.7.10) while our spoofed ProductVersion
        // says iOS 18.1 → server detects the mismatch and bans the account.
        @"BuildVersion":                  @"BuildVersion",
        @"ProductBuildVersion":           @"BuildVersion",
        @"OSBuildVersion":                @"BuildVersion",
        @"SoftwareBundleVersion":         @"BuildVersion",
        @"ProductVersion":                @"ProductVersion",
        @"ProductVersionString":          @"ProductVersion",
        // MaxSupportedOSVersion reveals the chip's real generation cap
        // (e.g., A8 → 12.5.7). If we don't override it, anti-fraud sees
        // "device claims iPhone 12 Pro Max + iOS 18 but max OS = 12.5.7"
        // → hardware giveaway. Map to spoofed ProductVersion so the
        // reported cap always >= the claimed running version.
        @"MaxSupportedOSVersion":         @"ProductVersion",
        @"SupportedOSVersions":           @"ProductVersion",
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
        // === Hardware capability booleans — MUST match the model we claim. ===
        // iPhone XS+ has FaceID, no TouchID, no HomeButton. iPhone 6s-iPhone 8
        // has TouchID + HomeButton, no FaceID. If we claim iPhone XS Max but
        // MGGetBoolAnswer("HasFaceID") returns NO (real older device), anti-
        // fraud sees inconsistency instantly.
        @"HasFaceID":            @"HasFaceID",
        @"HasTouchID":           @"HasTouchID",
        @"HasMesa":              @"HasTouchID",         // Mesa = Touch ID sensor
        @"HasHomeButton":        @"HasHomeButton",
        @"HasOLEDDisplay":       @"HasOLEDDisplay",
        @"Has5GUW":              @"Has5G",
        @"HasNFC":               @"HasNFC",
        @"HasCellularConnectivity": @"HasCellularConnectivity",
        @"HasBaseband":          @"HasCellularConnectivity",
        // === Activation / lifecycle timestamps ===
        // InitialActivationDate is when the device was first activated with
        // Apple's iTunes/Setup. Server-side anti-fraud cross-references this
        // against the phone number's registration window — a fresh device
        // (today) registering a 6-month-old number flags as anomalous.
        // Spoof to a random date 6-18 months ago.
        @"InitialActivationDate": @"InitialActivationDate",
        @"ActivationState":      @"ActivationState",
        @"ActivationStateAcknowledged": @"ActivationStateAcknowledged",
        // === Internal device strings used in fingerprinting libraries ===
        @"DeviceVariant":        @"DeviceVariant",
        @"DeviceVariantGUID":    @"DeviceVariantGUID",
        @"RegulatoryModelNumber": @"RegulatoryModelNumber",
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
        if (!fakeLayer(@"sysosversion")) {
            CFTypeRef r = orig_MGCopyAnswer(property);
            g_ci_inMGHook = 0;
            return r;
        }
    }

    NSString *configKey = mgKeyMap[key];
    // result already declared at function top

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

    // v2.4.47: stripped ALL NSLog + @synchronized + NSMutableSet from the
    // hot path. NSLog enters CFLog → ASL → libtrace which calls MG for
    // syslog prefix → re-enters our hook → thread-local guard catches but
    // each pass still does CFString work, multiplying cost. NSMutableSet
    // operations may allocate, allocations on some iOS versions trigger
    // metadata lookups that touch MG. Zero-alloc hot path = stable hook.
    if (result) {
        g_ci_inMGHook = 0;
        return result;
    }
    CFTypeRef orig = orig_MGCopyAnswer(property);
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
    if (!val) return %orig;
    // Base value is "how long the device has been up at dylib load"; from
    // here we MUST advance with wall clock — apps that read uptime twice
    // expect t2 > t1 by the elapsed delta. Returning the same constant
    // every call lets bot-detection flag the read as a replay.
    double base = [val doubleValue];
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double elapsed = now - g_dylibLoadTime;
    if (elapsed < 0) elapsed = 0;
    return base + elapsed;
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

// HOT PATH: Zalo / Facebook SDKs call fileExistsAtPath: hundreds of times
// during login navigation (resource loading, cache lookups, plist probes).
// Previous build iterated a 28-entry NSArray with hasPrefix: → ~50µs/call,
// total ~150ms across the login transition → user-visible "3s lag" on the
// register/login button. Pure-C ci_isHiddenJBPath defined in Hooks.mm uses
// a precomputed prefix table + second-char gate + strncmp; ~1µs/call.

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (!jbHideActive()) return %orig;
    // User-defined override list from config — only checked if non-empty.
    // Each call hits the C check ONCE (no NSString conversion in the loop).
    NSArray *hiddenPaths = getConfig(@"hiddenPaths");
    if (hiddenPaths.count > 0) {
        for (NSString *hidden in hiddenPaths) {
            if ([path hasPrefix:hidden]) return NO;
        }
    }
    // Default JB-path table — pure C strncmp via shared helper.
    const char *cpath = path.UTF8String;
    if (cpath && ci_isHiddenJBPath(cpath)) return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (!jbHideActive()) return %orig;
    const char *cpath = path.UTF8String;
    if (cpath && ci_isHiddenJBPath(cpath)) return NO;
    return %orig;
}

// v2.4.35: removed NSFileManager removeItemAtPath: / removeItemAtURL:
// hooks. Were interfering with Zalo's legitimate session-write paths.

%end

// RE-ADDED 2026-05-12 (perf-safe): SystemVersion.plist direct-read leak.
//
// AIDA64 + Apple Intelligence detection libs + many device-info SDKs
// bypass MGCopyAnswer and read /System/Library/CoreServices/SystemVersion
// .plist directly via -[NSDictionary dictionaryWithContentsOfFile:].
// They get ProductBuildVersion + ProductVersion straight from the OS
// image and ignore our MG hooks. Confirmed on iPhone where AIDA64
// reported the real Build 20H360 while our spoofed ProductVersion was
// 16.7.1 — anti-fraud sees the mismatch and bans.
//
// Previous removal (commit 42a6f58) was justified at the time: the old
// hook had no path filter and detoured EVERY plist read (Zalo's
// register flow loads HUNDREDS of plist resources for i18n/SDK config).
// This re-add applies a UTF-8 strstr filter as the FIRST line: if the
// path doesn't contain "SystemVersion" we %orig and return in ~50ns,
// well below the 1µs/call budget. Only SystemVersion plist reads pay
// the spoof cost — about 5-10 reads per app launch, total <1ms.

static inline BOOL ci_isSystemVersionPlistPath(NSString *path) {
    if (path.length < 20) return NO;
    const char *cpath = path.UTF8String;
    if (!cpath) return NO;
    // Two known canonical paths + the /var/jb mirror that rootless tools sometimes
    // proxy reads through.
    return strstr(cpath, "/SystemVersion.plist") != NULL ||
           strstr(cpath, "/CoreServices/SystemVersion") != NULL;
}

static NSDictionary *ci_spoofSystemVersionDict(NSDictionary *orig) {
    if (!orig || !fakeLayer(@"sysosversion")) return orig;
    NSString *fakeVer   = getConfigStr(@"systemVersion");
    NSString *fakeBuild = getConfigStr(@"BuildVersion");
    if (!fakeVer && !fakeBuild) return orig;
    NSMutableDictionary *m = [orig mutableCopy];
    if (fakeVer)   m[@"ProductVersion"]      = fakeVer;
    if (fakeBuild) m[@"ProductBuildVersion"] = fakeBuild;
    return [m copy];
}

%hook NSDictionary

+ (NSDictionary *)dictionaryWithContentsOfFile:(NSString *)path {
    if (!ci_isSystemVersionPlistPath(path)) return %orig;  // fast path 99.9% of calls
    return ci_spoofSystemVersionDict(%orig);
}

+ (NSDictionary *)dictionaryWithContentsOfURL:(NSURL *)url {
    if (!ci_isSystemVersionPlistPath(url.path)) return %orig;
    return ci_spoofSystemVersionDict(%orig);
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

// v2.4.47: per-bundle persistent APNs token. Auto-generate + cache so
// each target app gets a STABLE-but-unique 32-byte token across launches
// (matches Apple's real behavior — same device returns same APNs token
// to the same app until iOS re-issues on uninstall+reinstall, but
// different apps get different tokens). Single-config approach made
// every app on the device share one fake token, which lets servers
// correlate "Zalo and Facebook see the same APNs hash → same device."
//
//   Lookup order:
//     1) `apnsTokenSpoof` in config (manual override, hex 64-char)
//     2) /var/jb/etc/changeinfoios/apns_<bid>.dat (per-bundle cache)
//     3) Generate fresh random 32 bytes, persist to (2), return
//
//   On Reset Data the host deletes /var/jb/etc/changeinfoios/apns_*.dat
//   so next launch generates a brand-new fake token (= new device illusion).
static NSData *ci_apnsSpoofTokenData(void) {
    // 1) Explicit override via config (kept for backwards-compat)
    NSString *hex = getConfigStr(@"apnsTokenSpoof");
    if (hex.length >= 64) {
        NSMutableData *out = [NSMutableData dataWithCapacity:32];
        for (NSUInteger i = 0; i + 2 <= hex.length && out.length < 32; i += 2) {
            unsigned int v = 0;
            const char *p = [[hex substringWithRange:NSMakeRange(i, 2)] UTF8String];
            if (sscanf(p, "%02x", &v) == 1) {
                uint8_t b = (uint8_t)v;
                [out appendBytes:&b length:1];
            }
        }
        if (out.length == 32) return out;
    }

    // 2) Per-bundle persistent file in app's Library/Caches (sandbox-writable,
    //    survives launches, wiped by Clear Data + Kill Apps).
    NSArray *libDirs = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    NSString *cacheDir = [libDirs.firstObject
        stringByAppendingPathComponent:@"ChangeInfoIos"];
    if (cacheDir.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:cacheDir withIntermediateDirectories:YES
                   attributes:nil error:nil];
    NSString *path = [cacheDir stringByAppendingPathComponent:@"apns_token.dat"];
    NSData *cached = [NSData dataWithContentsOfFile:path];
    if (cached.length == 32) return cached;

    // 3) Generate fresh 32-byte token, persist
    NSMutableData *fresh = [NSMutableData dataWithLength:32];
    if (SecRandomCopyBytes(kSecRandomDefault, 32, fresh.mutableBytes) != errSecSuccess) {
        arc4random_buf(fresh.mutableBytes, 32);
    }
    [fresh writeToFile:path atomically:YES];
    return fresh;
}

static void ci_apnsHookedImpl(id self, SEL _cmd, UIApplication *app, NSData *originalToken) {
    NSData *fake = ci_apnsSpoofTokenData();
    NSData *use = (fake && fakeLayer(@"network")) ? fake : originalToken;
    // Walk class hierarchy to find the orig IMP we stored. We may have
    // swizzled on a SUPERCLASS (when a delegate class B inherits the
    // method from class A that we hooked first), so [self class] for B
    // won't have the association — but A will.
    Class current = [self class];
    NSValue *origPtr = nil;
    while (current && !origPtr) {
        origPtr = objc_getAssociatedObject(current, &kCIApnsOrigKey);
        if (origPtr) break;
        current = class_getSuperclass(current);
    }
    if (origPtr) {
        void (*orig)(id, SEL, UIApplication *, NSData *) =
            (void (*)(id, SEL, UIApplication *, NSData *))[origPtr pointerValue];
        // Defensive: if orig somehow points back to us (shouldn't happen
        // after the swizzle-guard fix but worth one more guard), bail.
        if (orig && orig != (void *)ci_apnsHookedImpl) {
            orig(self, _cmd, app, use);
        }
    }
}

static void ci_swizzleApnsOnDelegate(Class cls) {
    if (!cls) return;
    if (objc_getAssociatedObject(cls, &kCIApnsOrigKey)) return; // already swizzled on THIS class
    SEL sel = @selector(application:didRegisterForRemoteNotificationsWithDeviceToken:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {
        IMP orig = method_getImplementation(m);
        // CRITICAL: if the method was already swizzled by a previous
        // ci_swizzleApnsOnDelegate call (e.g., we hit class B which
        // inherits from class A that we already patched), method_get
        // Implementation returns ci_apnsHookedImpl. Storing THAT as
        // "orig" makes ci_apnsHookedImpl call itself → infinite
        // recursion → stack overflow → crash post-register (the bug
        // we've been chasing across 5+ builds).
        //
        // Skip the second swizzle entirely. The single A-level swizzle
        // already covers all subclasses via method inheritance. When
        // ci_apnsHookedImpl runs for a B-instance, [self class] gives B
        // but the orig is keyed on A — walk the class chain in the
        // hooked impl to find it.
        if (orig == (IMP)ci_apnsHookedImpl) return;

        objc_setAssociatedObject(cls, &kCIApnsOrigKey,
                                 [NSValue valueWithPointer:(void *)orig],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        method_setImplementation(m, (IMP)ci_apnsHookedImpl);
        NSLog(@"[ChangeInfoIos] APNS delegate swizzled on %@", NSStringFromClass(cls));
    } else {
        class_addMethod(cls, sel, (IMP)ci_apnsHookedImpl, "v@:@@");
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
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            Class pc = objc_getClass("RTCPeerConnection");
            if (!pc) return;
            SEL sel = @selector(setLocalDescription:completionHandler:);
            Method m = class_getInstanceMethod(pc, sel);
            if (!m) return;
            IMP cur = method_getImplementation(m);
            // Same recursion-trap guard as APNS: if our IMP is already
            // installed (e.g. from an earlier ctor invocation), don't
            // re-hook. Saving our own IMP as 'orig' would make our hook
            // call itself → stack overflow.
            if (cur == (IMP)ci_RTCPC_setLocalDesc) return;
            orig_RTCPC_setLocalDesc = cur;
            method_setImplementation(m, (IMP)ci_RTCPC_setLocalDesc);
            NSLog(@"[ChangeInfoIos] RTCPeerConnection.setLocalDescription hooked");
        }
    });
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

// Forward-declare the proxy method we read so we don't have to call it
// via performSelector: (which trips an ARC "may leak" warning because
// the compiler can't reason about the unknown selector's return type).
@interface LSApplicationProxy : NSObject
- (NSString *)applicationIdentifier;
@end

// RE-ENABLED 2026-05-15. The earlier crash (infinite recursion through
//   hook → [proxy applicationIdentifier] → LSAW internal → hook again)
// was caused by relying ONLY on fakeLayer's g_inFakeLayer guard, which
// breaks at level 2 but does nothing to prevent the hook body itself
// from re-entering on a fresh stack frame from the same thread.
//
// New strategy: dedicated __thread guard g_inLSAW guards each hook
// body's iteration block. On nested entry from LSApplicationProxy
// metadata-load callbacks, the guard makes us pass through to %orig
// immediately so the lazy metadata can resolve normally without our
// filter running again.
//
// Why this matters for reg-success: anti-fraud SDKs walk
// allInstalledApplications to fingerprint by which apps the user has
// installed. With 30+ apps on a real phone, the install-set vector is
// often 30+ bits — enough to correlate accounts across Reset Data even
// when every other ID is freshly spoofed. Filtering down to "host app
// + Apple system bundles only" gives every fresh-reset account the
// same install-set vector → no cross-account correlation through this
// path. Same outcome as a freshly factory-restored iPhone, which is
// the persona we're trying to project.
//
// Why not return @[]: zero installed apps is itself a flag. Real iOS
// always reports the host app + dozens of com.apple.* preinstalls.

static __thread int g_inLSAW = 0;

// Decide whether a given LSApplicationProxy should be visible to the
// host app. Allowlist: Apple system bundles (always present on every
// iPhone) + the host app itself. Everything else (Zalo, Facebook,
// other social apps, banking apps, the user's third-party installs)
// is hidden so the install-set vector becomes stable across accounts.
static BOOL ci_proxyVisibleToHost(LSApplicationProxy *proxy, NSString *hostBundleID) {
    @try {
        NSString *bid = [proxy applicationIdentifier];
        if (![bid isKindOfClass:[NSString class]]) return YES;  // unknown → keep
        if ([bid hasPrefix:@"com.apple."]) return YES;          // Apple preinstall
        if (hostBundleID && [bid isEqualToString:hostBundleID]) return YES;
        return NO;
    } @catch (__unused id e) {
        return YES;
    }
}

%hook LSApplicationWorkspace

- (NSArray *)allInstalledApplications {
    if (g_inLSAW) return %orig;     // nested re-entry from metadata-load callback
    // CRITICAL: skip filter when running inside HIOS Faker (the spoof
    // tool itself). HIOS Faker's CIAppLister uses LSAW to enumerate
    // installed apps so the user can pick targets to back up / wipe /
    // restore. If we filter the list to com.apple.* only, the user
    // sees ZERO third-party apps — Backup+Reset finds no Zalo, rebackup
    // can't locate Zalo's container, etc. Confirmed live 2026-05-19:
    // rebackup of a Zalo RRS produced a 12 MB tar (only /var/jb/etc/
    // changeinfoios, no Zalo Documents) because LSAW filter hid Zalo
    // from CIAppLister. The anti-fraud filter is ONLY useful inside
    // TARGET apps (Zalo, banking) where SDKs walk LSAW for fingerprint.
    if (!g_bundleTargeted) return %orig;
    if (!fakeLayer(@"keychain")) return %orig;
    g_inLSAW++;
    NSArray *original = %orig;
    NSArray *result = original;
    @try {
        NSString *hostBID = [[NSBundle mainBundle] bundleIdentifier];
        NSMutableArray *trimmed = [NSMutableArray arrayWithCapacity:original.count];
        for (id proxy in original) {
            if (ci_proxyVisibleToHost(proxy, hostBID)) {
                [trimmed addObject:proxy];
            }
        }
        result = trimmed;
    } @catch (__unused id e) {
        result = original;          // any iteration failure → fall back to real list
    }
    g_inLSAW--;
    return result;
}

- (NSArray *)applicationProxiesForIdentifiersOfType:(NSString *)type {
    if (g_inLSAW) return %orig;
    if (!g_bundleTargeted) return %orig;
    if (!fakeLayer(@"keychain")) return %orig;
    g_inLSAW++;
    NSArray *original = %orig;
    NSArray *result = original;
    @try {
        NSString *hostBID = [[NSBundle mainBundle] bundleIdentifier];
        NSMutableArray *trimmed = [NSMutableArray arrayWithCapacity:original.count];
        for (id proxy in original) {
            if (ci_proxyVisibleToHost(proxy, hostBID)) {
                [trimmed addObject:proxy];
            }
        }
        result = trimmed;
    } @catch (__unused id e) {
        result = original;
    }
    g_inLSAW--;
    return result;
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
// (WKWebView swizzle lives further down — ci_installWKWebViewHooks
// at line ~2918 already covers initWithFrame:configuration: + customUA
// getter/setter via runtime objc_getClass + ci_swizzleInstance, no
// compile-time WebKit linkage. Just need to make sure it's called
// from %ctor — see ci_installWKWebViewHooks call near the bottom.)


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
    // v2.4.47: optionally force TLS 1.2 only (partial JA3 spoof). When
    // _ci_force_tls12=YES, ClientHello signature shifts to match older
    // iOS pattern. Doesn't fully randomize JA3 (cipher order is hard-coded
    // in Security.framework) but partial match is enough to pass servers
    // that fingerprint by TLS version + extension set.
    if (cfg && getConfigBool(@"_ci_force_tls12")) {
        cfg.TLSMinimumSupportedProtocolVersion = tls_protocol_version_TLSv12;
        cfg.TLSMaximumSupportedProtocolVersion = tls_protocol_version_TLSv12;
    }
    return cfg;
}

+ (NSURLSessionConfiguration *)ephemeralSessionConfiguration {
    NSURLSessionConfiguration *cfg = %orig;
    NSDictionary *p = ci_buildProxyDictForTweak();
    if (cfg && p) cfg.connectionProxyDictionary = p;
    if (cfg && getConfigBool(@"_ci_force_tls12")) {
        cfg.TLSMinimumSupportedProtocolVersion = tls_protocol_version_TLSv12;
        cfg.TLSMaximumSupportedProtocolVersion = tls_protocol_version_TLSv12;
    }
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

// === DCDevice / DCAppAttest strategy: return "Unsupported" error ===
// Previously returned random fake bytes. Problem: Zalo POSTs those to its
// server, server validates with Apple, Apple rejects ("invalid signature
// for this anonymous device key"), Zalo server marks the device tampered
// → 39-second post-register account disable.
//
// New strategy: return DCErrorFeatureUnsupported (code 0 in
// com.apple.devicecheck.error). Mimics older iPhones (pre-A11 + iOS <11)
// that legitimately don't support App Attest. Zalo's anti-fraud doesn't
// flag this — it's the same response a real older device returns. Apple's
// server is NEVER contacted with our fake, so there's no audit trail.

static NSError *ci_dcUnsupportedError(void) {
    static NSError *err = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        err = [NSError errorWithDomain:@"com.apple.devicecheck.error"
                                  code:0
                              userInfo:@{NSLocalizedDescriptionKey:
                                  @"DeviceCheck feature is not supported on this device."}];
    });
    return err;
}

// v2.4.44: _ci_dc_passthrough config flag controls DCDevice/AppAttest
// behaviour. Default YES — let Apple's real Secure Enclave attestation
// chain through so server-side validators (Zalo 2024+, banking) accept
// the registration. Setting NO returns DCErrorFeatureUnsupported (old
// behavior — was breaking Zalo register with error -1005).
//
// Tradeoff:
//   passthrough YES (default) → registration works; AppAttest carries
//     real hardware-bound identifier → device can be correlated across
//     re-installs if server stores raw attestation.
//   passthrough NO → claim feature unsupported; server-side strict
//     apps reject; device less trackable via attestation.
//
// User can flip per-bundle via:
//   plutil -replace _ci_dc_passthrough -bool false /var/mobile/Library/Preferences/com.changeinfoios.plist
static inline BOOL ci_dcPassthrough(void) {
    id v = getConfig(@"_ci_dc_passthrough");
    if (v == nil) return YES;  // default ON
    return [v boolValue];
}

static BOOL ci_DC_isSupported(id self, SEL _cmd) {
    if (ci_dcPassthrough() && orig_DC_isSupported) return orig_DC_isSupported(self, _cmd);
    if (!fakeLayer(@"hardware")) return orig_DC_isSupported ? orig_DC_isSupported(self, _cmd) : YES;
    return NO;
}

static void ci_DC_generateToken(id self, SEL _cmd, void (^completion)(NSData *, NSError *)) {
    if (ci_dcPassthrough() && orig_DC_generateToken) {
        orig_DC_generateToken(self, _cmd, (id)completion);
        return;
    }
    if (!fakeLayer(@"hardware")) {
        if (orig_DC_generateToken) orig_DC_generateToken(self, _cmd, (id)completion);
        return;
    }
    if (completion) completion(nil, ci_dcUnsupportedError());
}

static BOOL ci_DCA_isSupported(id self, SEL _cmd) {
    if (ci_dcPassthrough() && orig_DCA_isSupported) return orig_DCA_isSupported(self, _cmd);
    if (!fakeLayer(@"hardware")) return orig_DCA_isSupported ? orig_DCA_isSupported(self, _cmd) : YES;
    return NO;
}

static void ci_DCA_generateKey(id self, SEL _cmd, void (^completion)(NSString *, NSError *)) {
    if (ci_dcPassthrough() && orig_DCA_generateKey) {
        orig_DCA_generateKey(self, _cmd, (id)completion);
        return;
    }
    if (!fakeLayer(@"hardware")) {
        if (orig_DCA_generateKey) orig_DCA_generateKey(self, _cmd, (id)completion);
        return;
    }
    if (completion) completion(nil, ci_dcUnsupportedError());
}

static void ci_DCA_attestKey(id self, SEL _cmd, NSString *keyId, NSData *hash, void (^completion)(NSData *, NSError *)) {
    if (ci_dcPassthrough() && orig_DCA_attestKey) {
        orig_DCA_attestKey(self, _cmd, keyId, hash, (id)completion);
        return;
    }
    if (!fakeLayer(@"hardware")) {
        if (orig_DCA_attestKey) orig_DCA_attestKey(self, _cmd, keyId, hash, (id)completion);
        return;
    }
    if (completion) completion(nil, ci_dcUnsupportedError());
}

// generateAssertion is called for EVERY request after the initial reg.
// Apps using App Attest send (keyId, clientDataHash) → SE generates a
// signed assertion that the server validates against the stored attest.
// We return DCErrorFeatureUnsupported so the app's non-attest fallback
// path runs — same logic as the other DCAppAttest methods above.
static void ci_DCA_generateAssertion(id self, SEL _cmd, NSString *keyId, NSData *hash, void (^completion)(NSData *, NSError *)) {
    if (ci_dcPassthrough() && orig_DCA_genAssertion) {
        orig_DCA_genAssertion(self, _cmd, keyId, hash, (id)completion);
        return;
    }
    if (!fakeLayer(@"hardware")) {
        if (orig_DCA_genAssertion) orig_DCA_genAssertion(self, _cmd, keyId, hash, (id)completion);
        return;
    }
    if (completion) completion(nil, ci_dcUnsupportedError());
    return;
    // Legacy random-blob path kept below in case the unsupported strategy
    // breaks Zalo flow on newer iOS — flip the early-return above to
    // re-enable.
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
    IMP cur = method_getImplementation(m);
    // CRITICAL: if newImp is already installed (e.g., %ctor ran twice,
    // or another swizzle path got here first), do NOT re-hook. Saving
    // newImp as 'orig' would make our hook call itself → stack overflow
    // → post-register crash. This is the bug we've been chasing across
    // 5+ builds.
    if (cur == newImp) return;
    if (origImpOut) *origImpOut = cur;
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

    // Coherent device specs derived from current preset (so navigator
    // values match UIDevice/sysctl story).
    id cpuN = getConfig(@"processorCount");
    id ramN = getConfig(@"physicalMemory");
    int hwConcurrency = cpuN ? [cpuN intValue] : 6;
    if (hwConcurrency < 2) hwConcurrency = 2;
    if (hwConcurrency > 16) hwConcurrency = 16;
    int deviceMemoryGB = 4;
    if (ramN) {
        unsigned long long ramBytes = [ramN unsignedLongLongValue];
        deviceMemoryGB = (int)(ramBytes / (1024ULL*1024*1024));
        // Web spec only allows {0.25, 0.5, 1, 2, 4, 8} — clamp + round.
        if (deviceMemoryGB <= 1) deviceMemoryGB = 1;
        else if (deviceMemoryGB <= 2) deviceMemoryGB = 2;
        else if (deviceMemoryGB <= 4) deviceMemoryGB = 4;
        else deviceMemoryGB = 8;
    }
    int screenW = [getConfigStr(@"screenWidth")  intValue]; if (screenW < 320) screenW = 390;
    int screenH = [getConfigStr(@"screenHeight") intValue]; if (screenH < 480) screenH = 844;
    NSString *country = getConfigStr(@"localeCountryCode") ?: @"VN";

    NSMutableString *js = [NSMutableString stringWithString:@"(function(){"];

    if (fakeUA.length) {
        [js appendFormat:@"try{Object.defineProperty(navigator,'userAgent',{get:function(){return '%@';}});}catch(e){}", fakeUA];
    }

    [js appendFormat:@"try{Object.defineProperty(navigator,'platform',{get:function(){return 'iPhone';}});}catch(e){}"];
    [js appendFormat:@"try{Object.defineProperty(navigator,'vendor',{get:function(){return 'Apple Computer, Inc.';}});}catch(e){}"];
    [js appendFormat:@"try{Object.defineProperty(navigator,'languages',{get:function(){return ['%@-%@','%@','en'];}});}catch(e){}", language, country, language];
    [js appendFormat:@"try{Object.defineProperty(navigator,'language',{get:function(){return '%@-%@';}});}catch(e){}", language, country];
    // Match UIDevice spoofs to JS-side navigator probes — anti-fraud SDKs
    // verify cross-layer consistency (navigator.hardwareConcurrency vs
    // sysctl hw.physicalcpu, navigator.deviceMemory vs hw_memsize).
    [js appendFormat:@"try{Object.defineProperty(navigator,'hardwareConcurrency',{get:function(){return %d;}});}catch(e){}", hwConcurrency];
    [js appendFormat:@"try{Object.defineProperty(navigator,'deviceMemory',{get:function(){return %d;}});}catch(e){}", deviceMemoryGB];
    [js appendFormat:@"try{Object.defineProperty(navigator,'maxTouchPoints',{get:function(){return 5;}});}catch(e){}"];
    [js appendFormat:@"try{Object.defineProperty(navigator,'productSub',{get:function(){return '20030107';}});}catch(e){}"];
    // Screen dims must match UIScreen spoof. devicePixelRatio always 3 on retina iPhone.
    [js appendFormat:@"try{Object.defineProperty(screen,'width',{get:function(){return %d;}});}catch(e){}", screenW];
    [js appendFormat:@"try{Object.defineProperty(screen,'height',{get:function(){return %d;}});}catch(e){}", screenH];
    [js appendFormat:@"try{Object.defineProperty(screen,'availWidth',{get:function(){return %d;}});}catch(e){}", screenW];
    [js appendFormat:@"try{Object.defineProperty(screen,'availHeight',{get:function(){return %d;}});}catch(e){}", screenH];
    [js appendFormat:@"try{Object.defineProperty(screen,'colorDepth',{get:function(){return 24;}});}catch(e){}"];
    [js appendFormat:@"try{Object.defineProperty(screen,'pixelDepth',{get:function(){return 24;}});}catch(e){}"];
    // Disable battery API exposure (iOS Safari already returns undefined,
    // but in-app webviews sometimes leak it). Random-flat values prevent
    // charge-cycle fingerprinting where SDKs measure mAh deltas.
    [js appendString:@"try{navigator.getBattery=function(){return Promise.resolve({charging:false,chargingTime:Infinity,dischargingTime:Infinity,level:0.85,addEventListener:function(){},removeEventListener:function(){}});};}catch(e){}"];
    // navigator.connection — block real network type readout
    [js appendString:@"try{Object.defineProperty(navigator,'connection',{get:function(){return {effectiveType:'4g',downlink:10,rtt:50,saveData:false,type:'cellular',addEventListener:function(){},removeEventListener:function(){}};}});}catch(e){}"];
    // Permissions API — canonicalize to 'prompt' so SDK can't fingerprint
    // by which permissions are granted.
    [js appendString:@"try{if(navigator.permissions){var _q=navigator.permissions.query.bind(navigator.permissions);navigator.permissions.query=function(p){return Promise.resolve({state:'prompt',addEventListener:function(){},removeEventListener:function(){}});};}}catch(e){}"];
    // AudioContext fingerprinting — SDKs render a sine wave, hash the
    // resulting frequency-domain bytes. Add ±1e-7 noise to baseLatency
    // so the hash differs across sessions.
    [js appendString:@"try{var _ac=window.AudioContext||window.webkitAudioContext;if(_ac){var _ob=_ac.prototype.createOscillator;_ac.prototype.createOscillator=function(){var o=_ob.call(this);try{var _f=o.frequency;Object.defineProperty(o,'frequency',{get:function(){return {value:_f.value+(Math.random()-0.5)*1e-7,setValueAtTime:_f.setValueAtTime.bind(_f)};}});}catch(e){}return o;};}}catch(e){}"];

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

    // v2.4.47: Intl.DateTimeFormat timezone — match fake timezoneName so
    // SDKs probing Intl.DateTimeFormat().resolvedOptions().timeZone see
    // the same value as Foundation NSTimeZone. Most JS fingerprint libs
    // use Intl as the cross-browser canonical timezone source.
    NSString *fakeTZ = getConfigStr(@"timezoneName") ?: @"Asia/Ho_Chi_Minh";
    [js appendFormat:@"try{var _Intl=window.Intl;if(_Intl&&_Intl.DateTimeFormat){var _DTF=_Intl.DateTimeFormat;var _wrap=function(){var i=new _DTF(arguments[0]||undefined,arguments[1]||undefined);var _ro=i.resolvedOptions.bind(i);i.resolvedOptions=function(){var r=_ro();r.timeZone='%@';return r;};return i;};_wrap.prototype=_DTF.prototype;_wrap.supportedLocalesOf=_DTF.supportedLocalesOf;window.Intl.DateTimeFormat=_wrap;}}catch(e){}", fakeTZ];

    // Override Date.prototype.getTimezoneOffset() so legacy code (pre-Intl
    // fingerprint libs) also reads our fake timezone. Compute offset from
    // tz name via a single lookup at JS load (-420 min for Asia/Ho_Chi_Minh,
    // -480 for Singapore, +300 for US Eastern, etc.). Negative because
    // JS convention is (UTC - local) so a +7 zone returns -420.
    NSInteger tzOffsetMin = -420;  // default VN
    if ([fakeTZ hasPrefix:@"America/New_York"] || [fakeTZ hasPrefix:@"America/Toronto"]) tzOffsetMin = 300;
    else if ([fakeTZ hasPrefix:@"America/Los_Angeles"] || [fakeTZ hasPrefix:@"America/Vancouver"]) tzOffsetMin = 480;
    else if ([fakeTZ hasPrefix:@"America/Chicago"]) tzOffsetMin = 360;
    else if ([fakeTZ hasPrefix:@"Europe/London"]) tzOffsetMin = 0;
    else if ([fakeTZ hasPrefix:@"Europe/Paris"] || [fakeTZ hasPrefix:@"Europe/Berlin"]) tzOffsetMin = -60;
    else if ([fakeTZ hasPrefix:@"Asia/Tokyo"] || [fakeTZ hasPrefix:@"Asia/Seoul"]) tzOffsetMin = -540;
    else if ([fakeTZ hasPrefix:@"Asia/Singapore"] || [fakeTZ hasPrefix:@"Asia/Shanghai"] || [fakeTZ hasPrefix:@"Asia/Hong_Kong"]) tzOffsetMin = -480;
    else if ([fakeTZ hasPrefix:@"Asia/Bangkok"] || [fakeTZ hasPrefix:@"Asia/Jakarta"] || [fakeTZ hasPrefix:@"Asia/Ho_Chi_Minh"]) tzOffsetMin = -420;
    else if ([fakeTZ hasPrefix:@"Australia/Sydney"]) tzOffsetMin = -600;
    [js appendFormat:@"try{Date.prototype.getTimezoneOffset=function(){return %ld;};}catch(e){}", (long)tzOffsetMin];

    // v2.4.47: document.fonts iterator — limit to safe iOS system fonts
    // so fingerprint libs can't enumerate jailbreak font installs (e.g.
    // user installed custom fonts via Filza) and can't probe for unusual
    // fonts that pin device identity. Return iOS 16 canonical list.
    [js appendString:@"try{if(document.fonts&&document.fonts.values){var _iosFonts=['.AppleSystemUIFont','.AppleSystemUIFontMonospaced','.AppleSystemUIFontRounded','.SFNS-Regular','Helvetica','Helvetica Neue','Arial','Times New Roman','Courier','Courier New','Verdana','Georgia','Trebuchet MS','Tahoma','Symbol','Zapfino','Marker Felt','Noteworthy','Snell Roundhand','Bradley Hand','Chalkduster','American Typewriter','Apple Color Emoji','Avenir','Avenir Next','Baskerville','Bodoni 72','Bodoni 72 Smallcaps','Cochin','Copperplate','Damascus','Didot','Euphemia UCAS','Futura','Geeza Pro','Georgia','Gill Sans','Heiti SC','Heiti TC','Hiragino Sans','Hiragino Sans GB','Hoefler Text','Iowan Old Style','Kailasa','Kefa','Khmer Sangam MN','Lao Sangam MN','Malayalam Sangam MN','Marion','Menlo','Optima','Palatino','Papyrus','Party LET','Savoye LET','Sinhala Sangam MN','Snell Roundhand','Tamil Sangam MN','Thonburi'];var _fakeIter=function*(){for(var i=0;i<_iosFonts.length;i++){yield {family:_iosFonts[i],style:'normal',weight:'400',stretch:'normal',unicodeRange:'U+0-10FFFF',variant:'normal',featureSettings:'normal'};}};Object.defineProperty(document.fonts,'size',{get:function(){return _iosFonts.length;}});document.fonts.values=function(){return _fakeIter();};document.fonts[Symbol.iterator]=function(){return _fakeIter();};document.fonts.forEach=function(cb){_iosFonts.forEach(function(f){cb({family:f,style:'normal',weight:'400'});});};}}catch(e){}"];

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

// CTSubscriber.uniqueIdentifier (ICCID/SIM serial) — persistent SIM card
// fingerprint. Even after Reset Data, real SIM has same ICCID → server
// correlates registrations to same hardware. Spoof from config
// IntegratedCircuitCardIdentity (already randomized per Reset Data).
static CTSubscriber_phoneNumber_t orig_CTSubscriber_uniqueIdentifier = NULL;
static NSString *ci_CTSubscriber_uniqueIdentifier(id self, SEL _cmd) {
    if (!fakeLayer(@"network")) {
        return orig_CTSubscriber_uniqueIdentifier ? orig_CTSubscriber_uniqueIdentifier(self, _cmd) : nil;
    }
    NSString *iccid = getConfigStr(@"IntegratedCircuitCardIdentity");
    if (iccid.length > 0) return iccid;
    return orig_CTSubscriber_uniqueIdentifier ? orig_CTSubscriber_uniqueIdentifier(self, _cmd) : nil;
}

// Additional CTSubscriber selectors that some apps probe via private API.
// Each guards against missing-class / missing-selector at install time
// (ci_swizzleInstance returns silently if not present on this iOS).
static CTSubscriber_phoneNumber_t orig_CTSubscriber_subscriberID = NULL;
static NSString *ci_CTSubscriber_subscriberID(id self, SEL _cmd) {
    if (!fakeLayer(@"network")) {
        return orig_CTSubscriber_subscriberID ? orig_CTSubscriber_subscriberID(self, _cmd) : nil;
    }
    // Reuse ICCID — distinct from real subscriberId would cause
    // anti-fraud cross-check fail; same fake value across both is fine
    // since real device returns same value too.
    NSString *iccid = getConfigStr(@"IntegratedCircuitCardIdentity");
    if (iccid.length > 0) return iccid;
    return orig_CTSubscriber_subscriberID ? orig_CTSubscriber_subscriberID(self, _cmd) : nil;
}

static CTSubscriber_phoneNumber_t orig_CTSubscriber_mobileCountryCode = NULL;
static NSString *ci_CTSubscriber_mobileCountryCode(id self, SEL _cmd) {
    if (!fakeLayer(@"network")) {
        return orig_CTSubscriber_mobileCountryCode ? orig_CTSubscriber_mobileCountryCode(self, _cmd) : nil;
    }
    NSString *mcc = getConfigStr(@"carrierMCC");
    if (mcc.length > 0) return mcc;
    return orig_CTSubscriber_mobileCountryCode ? orig_CTSubscriber_mobileCountryCode(self, _cmd) : nil;
}

static CTSubscriber_phoneNumber_t orig_CTSubscriber_mobileNetworkCode = NULL;
static NSString *ci_CTSubscriber_mobileNetworkCode(id self, SEL _cmd) {
    if (!fakeLayer(@"network")) {
        return orig_CTSubscriber_mobileNetworkCode ? orig_CTSubscriber_mobileNetworkCode(self, _cmd) : nil;
    }
    NSString *mnc = getConfigStr(@"carrierMNC");
    if (mnc.length > 0) return mnc;
    return orig_CTSubscriber_mobileNetworkCode ? orig_CTSubscriber_mobileNetworkCode(self, _cmd) : nil;
}

// PushKit VoIP token swizzle — `[PKPushRegistry pushTokenForType:]`
// returns a 32-byte token tied to (Apple ID + bundle + hardware), per
// VoIP type. Persistent across Reset Data. Zalo uses this for VoIP
// call delivery; multiple accounts share same VoIP token → server
// correlates. Synthesize from config apnsTokenSpoof XOR'd with type
// suffix so PushKit and APNS tokens differ but both rotate per Reset.
typedef NSData *(*PKPushRegistry_pushTokenForType_t)(id self, SEL _cmd, NSString *type);
static PKPushRegistry_pushTokenForType_t orig_PKPushRegistry_pushTokenForType = NULL;
static NSData *ci_PKPushRegistry_pushTokenForType(id self, SEL _cmd, NSString *type) {
    if (!fakeLayer(@"network")) {
        return orig_PKPushRegistry_pushTokenForType ? orig_PKPushRegistry_pushTokenForType(self, _cmd, type) : nil;
    }
    NSString *hex = getConfigStr(@"apnsTokenSpoof");
    if (hex.length < 64) {
        return orig_PKPushRegistry_pushTokenForType ? orig_PKPushRegistry_pushTokenForType(self, _cmd, type) : nil;
    }
    NSMutableData *out = [NSMutableData dataWithCapacity:32];
    for (NSUInteger i = 0; i + 2 <= hex.length && out.length < 32; i += 2) {
        unsigned int v = 0;
        const char *p = [[hex substringWithRange:NSMakeRange(i, 2)] UTF8String];
        if (sscanf(p, "%02x", &v) == 1) {
            uint8_t b = (uint8_t)v ^ 0xA5; // XOR with sentinel so VoIP token != APNS token
            [out appendBytes:&b length:1];
        }
    }
    return out.length == 32 ? out : nil;
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
            ci_swizzleInstance("CTSubscriber", @selector(uniqueIdentifier),
                               (IMP)ci_CTSubscriber_uniqueIdentifier,
                               (IMP *)&orig_CTSubscriber_uniqueIdentifier);
            // Best-effort additional selectors. ci_swizzleInstance no-ops
            // when method missing on this iOS, so safe to attempt.
            ci_swizzleInstance("CTSubscriber", @selector(subscriberID),
                               (IMP)ci_CTSubscriber_subscriberID,
                               (IMP *)&orig_CTSubscriber_subscriberID);
            ci_swizzleInstance("CTSubscriber", @selector(mobileCountryCode),
                               (IMP)ci_CTSubscriber_mobileCountryCode,
                               (IMP *)&orig_CTSubscriber_mobileCountryCode);
            ci_swizzleInstance("CTSubscriber", @selector(mobileNetworkCode),
                               (IMP)ci_CTSubscriber_mobileNetworkCode,
                               (IMP *)&orig_CTSubscriber_mobileNetworkCode);
            NSLog(@"[ChangeInfoIos] CTSubscriber.phoneNumber+uniqueIdentifier+subscriberID+MCC+MNC hooked");
        }
        if (objc_getClass("PKPushRegistry")) {
            ci_swizzleInstance("PKPushRegistry", @selector(pushTokenForType:),
                               (IMP)ci_PKPushRegistry_pushTokenForType,
                               (IMP *)&orig_PKPushRegistry_pushTokenForType);
            NSLog(@"[ChangeInfoIos] PKPushRegistry.pushTokenForType: hooked (VoIP)");
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
        // v2.4.43: ci_installWKWebViewHooks() is already invoked by the
        // main %ctor (line ~3683) — don't double-swizzle here.
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
// AVCaptureDevice fingerprint — spoof per-camera hardware identifiers.
// ============================================================
// Anti-fraud SDKs in eKYC flows (Zalo / banking apps) read AVCaptureDevice
// .uniqueID and .modelID during selfie/ID-card capture and ship them to the
// backend with the captured frames. Real values look like "0001:0001" /
// "back-camera-iPhone14,5" and are stable across Reset Data because the
// camera hardware never changes — so even with a fresh container + spoofed
// MGCopyAnswer + spoofed UDID, the camera ID gives the device away.
//
// Strategy: derive a deterministic-per-Reset uniqueID from the spoofed
// UDID config so it stays internally consistent within one profile cycle
// (every Reset → new UDID → new camera ID), and modelID from the spoofed
// ProductType so a "claim iPhone 12 + back camera" reads as a back camera
// from an iPhone 12, not the real device.
%hook AVCaptureDevice

- (NSString *)uniqueID {
    if (!fakeLayer(@"hardware")) return %orig;
    NSString *spoof = getConfigStr(@"AVCaptureDeviceUniqueID");
    if (spoof.length > 0) {
        // Optionally suffix per-position so front/back stay distinguishable
        // (apps that enumerate devices expect different IDs per position).
        // -position returns AVCaptureDevicePositionBack(1) / Front(2) / Unspecified(0).
        @try {
            NSInteger pos = (NSInteger)[self position];
            if (pos == 2 /* Front */) return [spoof stringByAppendingString:@":F"];
            if (pos == 1 /* Back */)  return [spoof stringByAppendingString:@":B"];
        } @catch (__unused id e) {}
        return spoof;
    }
    return %orig;
}

- (NSString *)modelID {
    if (!fakeLayer(@"hardware")) return %orig;
    NSString *productType = getConfigStr(@"ProductType");
    if (productType.length > 0) {
        @try {
            NSInteger pos = (NSInteger)[self position];
            const char *side = (pos == 2) ? "front" : "back";
            return [NSString stringWithFormat:@"com.apple.avfoundation.avcapturedevice.built-in_video:%s:%@",
                    side, productType];
        } @catch (__unused id e) {}
        return [NSString stringWithFormat:@"com.apple.avfoundation.avcapturedevice.built-in_video:%@", productType];
    }
    return %orig;
}

%end


%ctor {
    @autoreleasepool {
        // Anchor wall-clock at dylib load for drift-style hooks.
        // Set BEFORE any %hook bodies could read it.
        g_dylibLoadTime = CFAbsoluteTimeGetCurrent();

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

        // ORDER MATTERS: register the dump_keychain observer FIRST, before
        // any further ctor work, then run restore + initial dump. Earlier
        // build registered the observer AFTER restore + dispatch_after(5s)
        // chain — race window where the host app's notify_post fired during
        // the gap reached an unregistered Darwin notifyd entry and was lost
        // (Darwin notify does NOT queue for unregistered observers). Result:
        // backup tarred a stale 5s-old dump (or nothing for a fresh launch),
        // restore replayed empty/old keychain, Zalo asked login again.
        // Now the listener is live within microseconds of dylib load, so
        // every notify after %ctor enters our handler.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            ci_onDumpKeychainNotification,
            CFSTR("com.changeinfoios/dump_keychain"), NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onPrefsDarwinNotify, CFSTR("com.changeinfoios/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);

        // Keychain restore: if host app dropped a restore flag (via RRS
        // restore), apply the snapshot BEFORE the host app reads any
        // keychain entries. Suppress the auto-dump immediately after so we
        // don't overwrite the just-restored data with… the same data.
        // Otherwise dump synchronously now (was 5s dispatch_after — the
        // delay caused tar-time stale dumps when user backed up quickly
        // after launch). Cost is ~30ms on a typical Zalo keychain (<200
        // entries), well under the host watchdog budget.
        BOOL didRestore = ci_restoreKeychainIfFlagged();
        if (!didRestore) {
            ci_dumpKeychain();
        }

        // MG hook via fishhook GOT rebinding (v2.4.47+). Default ON;
        // opt-out with _ci_skip_mg=YES via plist if a specific app
        // crashes. The MSHookFunction install path (deleted in S1.4)
        // was prologue-patching MG into a `brk` trap under Dopamine
        // AMFI rules; fishhook only touches the __DATA __got slot so
        // the original instructions stay intact.
        if (!getConfigBool(@"_ci_skip_mg")) {
            void *mgHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
            if (mgHandle) {
                orig_MGCopyAnswer      = (MGCopyAnswer_t)dlsym(mgHandle, "MGCopyAnswer");
                orig_MGGetBoolAnswer   = (MGGetBoolAnswer_t)dlsym(mgHandle, "MGGetBoolAnswer");
                orig_MGGetStringAnswer = (MGGetStringAnswer_t)dlsym(mgHandle, "MGGetStringAnswer");
                if (orig_MGCopyAnswer) {
                    static struct rebinding mgRebindings[3];
                    int n = 0;
                    mgRebindings[n++] = (struct rebinding){
                        "MGCopyAnswer", (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer
                    };
                    if (orig_MGGetBoolAnswer) {
                        mgRebindings[n++] = (struct rebinding){
                            "MGGetBoolAnswer", (void *)hooked_MGGetBoolAnswer, (void **)&orig_MGGetBoolAnswer
                        };
                    }
                    if (orig_MGGetStringAnswer) {
                        mgRebindings[n++] = (struct rebinding){
                            "MGGetStringAnswer", (void *)hooked_MGGetStringAnswer, (void **)&orig_MGGetStringAnswer
                        };
                    }
                    int rc = rebind_symbols(mgRebindings, n);
                    NSLog(@"[ChangeInfoIos] MG fishhook installed (n=%d rc=%d)", n, rc);
                }
            }
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
