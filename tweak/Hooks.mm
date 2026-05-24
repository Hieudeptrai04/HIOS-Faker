/**
 * ChangeInfoIos - C-Level Hooks via MSHookFunction
 * Separated from Tweak.xm to avoid Logos %hookf limitations
 * with C struct parameters (stat, sysctl, etc.)
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <netdb.h>
#import <sys/socket.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#include <sys/time.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <substrate.h>

// Config accessors (defined in Tweak.xm as plain C-linkage symbols).
// Must be extern "C" because this is Objective-C++ (.mm) and Tweak.xm
// is Objective-C (.m-equivalent) — without this the linker looks for
// C++-mangled names (_Z12getConfigStrP8NSString etc.) that don't exist.
extern "C" {
    NSString *getConfigStr(NSString *key);
    BOOL getConfigBool(NSString *key);
    id getConfig(NSString *key);
    BOOL fakeLayer(NSString *shortName);
    BOOL jbHideActive(void);
    void reloadConfigFromDisk(void);
    extern BOOL configLoaded;
    // Set by Tweak.xm during ci_dumpKeychain / ci_restoreKeychainIfFlagged.
    // Our own SecItem* hooks below check this and pass straight through to
    // %orig when non-zero so the dump/restore doesn't see filtered results
    // or have writes silently dropped.
    extern __thread int g_ci_skipKeychainHook;
}

// Type-safe unsigned coerce. NSString lacks `unsignedLongLongValue` —
// sending it to a string raises an unrecognized selector exception that
// blows up scene init through __forwarding__ (AIDA64 SIGABRT after Reset
// Data when legacy string-form numerics persist in the config plist).
static inline uint64_t ci_safeULL(id v) {
    if (!v) return 0;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v unsignedLongLongValue];
    if ([v isKindOfClass:[NSString class]]) return (uint64_t)[(NSString *)v longLongValue];
    return 0;
}

// ============================================================
// Process name guard - never hook in system critical processes
// ============================================================
static const char *cached_progname = NULL;

static const char *get_progname(void) {
    if (cached_progname) return cached_progname;
    cached_progname = getprogname();
    return cached_progname ? cached_progname : "";
}

static BOOL is_critical_process(void) {
    const char *name = get_progname();
    static const char *critical[] = {
        "Sileo", "apt", "apt-get", "dpkg", "apt-index",
        "SpringBoard", "installd", "lsd", "assertiond",
        "dasd", "mobile_installation_d", "UserEventAgent",
        "mediaserverd", "configd", "notifyd", "launchd"
    };
    for (size_t i = 0; i < sizeof(critical)/sizeof(critical[0]); i++) {
        if (strcmp(name, critical[i]) == 0) return YES;
    }
    return NO;
}

// ============================================================
// sysctlbyname hook
// ============================================================
static int (*orig_sysctlbyname)(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) = NULL;

static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    if (!name) return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);

    // Fast-path filter: sysctlbyname is called thousands of times/sec.
    // Only the prefixes below are spoofable; anything else bypasses every
    // allocation and dict lookup. Cuts per-call overhead from ~5µs to <100ns.
    if (name[0] != 'h' && name[0] != 'k') {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    if (strncmp(name, "hw.", 3) != 0 && strncmp(name, "kern.", 5) != 0) {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }

    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret != 0) return ret;
    if (!oldp || !oldlenp) return ret;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded) return ret;

    // C-string compare avoids NSString allocation on the hot path.
    const char *configKeyC = NULL;
    BOOL isOsVersion = NO;
    if      (strcmp(name, "hw.machine")     == 0) configKeyC = "hw_machine";
    else if (strcmp(name, "hw.model")       == 0) configKeyC = "hw_model";
    else if (strcmp(name, "kern.hostname")  == 0) configKeyC = "kern_hostname";
    else if (strcmp(name, "kern.osversion") == 0) { configKeyC = "kern_osversion"; isOsVersion = YES; }
    else if (strcmp(name, "kern.osrelease") == 0) configKeyC = "kern_osrelease";
    // v2.4.59: kern.osproductversion — THIS is what WebCore reads to build
    // the Safari User-Agent's "iPhone OS X_Y_Z" + "Version/X.Y" substring.
    // Different from kern.osversion (build number like 20H360); this is the
    // marketing dotted version like "16.7.11" or "17.5.1". Without spoofing
    // here, Safari's UA reflects the REAL iOS version on the wire even
    // though navigator.userAgent (JS) is spoofed.
    else if (strcmp(name, "kern.osproductversion") == 0 ||
             strcmp(name, "kern.osproductversionextra") == 0) { configKeyC = "systemVersion"; isOsVersion = YES; }

    // v2.4.60 DIAGNOSTIC — write a marker every time osproductversion is
    // queried. Lets us verify the hook is being entered. Remove after
    // confirming. Path is world-writable /var/jb/tmp which any process
    // can append to.
    if (strcmp(name, "kern.osproductversion") == 0) {
        FILE *mf = fopen("/var/jb/tmp/ci_osprod_hit.log", "a");
        if (mf) {
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
            fprintf(mf, "[%ld] %s configKeyC=%s configLoaded=%d\n",
                    (long)time(NULL), [bid UTF8String], configKeyC ?: "NULL", configLoaded);
            fclose(mf);
        }
    }

    if (configKeyC) {
        BOOL useStr = isOsVersion ? fakeLayer(@"sysosversion") : fakeLayer(@"sysctl");
        if (useStr) {
            NSString *configKey = [NSString stringWithUTF8String:configKeyC];
            NSString *val = getConfigStr(configKey);
            if (val) {
                const char *cval = [val UTF8String];
                size_t needed = strlen(cval) + 1;
                if (*oldlenp >= needed) {
                    memcpy(oldp, cval, needed);
                    *oldlenp = needed;
                    return 0;
                } else {
                    errno = ENOMEM;
                    *oldlenp = needed;
                    return -1;
                }
            }
        }
    }

    if (!fakeLayer(@"sysctl")) return ret;

    if (strcmp(name, "hw.memsize") == 0) {
        id val = getConfig(@"hw_memsize");
        if (val && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t memsize = ci_safeULL(val);
            memcpy(oldp, &memsize, sizeof(uint64_t));
            return 0;
        }
    }

    if (strcmp(name, "hw.physicalcpu") == 0 || strcmp(name, "hw.physicalcpu_max") == 0) {
        id val = getConfig(@"hw_physicalcpu");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int cores = [val intValue];
            memcpy(oldp, &cores, sizeof(int));
            return 0;
        }
    }

    if (strcmp(name, "hw.logicalcpu") == 0 || strcmp(name, "hw.logicalcpu_max") == 0) {
        id val = getConfig(@"hw_logicalcpu_max") ?: getConfig(@"hw_physicalcpu");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int cores = [val intValue];
            memcpy(oldp, &cores, sizeof(int));
            return 0;
        }
    }

    if (strcmp(name, "hw.cputype") == 0) {
        id val = getConfig(@"hw_cputype");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int ct = [val intValue];
            memcpy(oldp, &ct, sizeof(int));
            return 0;
        }
    }

    if (strcmp(name, "hw.cpusubtype") == 0) {
        id val = getConfig(@"hw_cpusubtype");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int cs = [val intValue];
            memcpy(oldp, &cs, sizeof(int));
            return 0;
        }
    }

    if (strcmp(name, "hw.cpufrequency") == 0 || strcmp(name, "hw.cpufrequency_max") == 0) {
        id val = getConfig(@"hw_cpufrequency");
        if (val && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t freq = ci_safeULL(val);
            memcpy(oldp, &freq, sizeof(uint64_t));
            return 0;
        }
    }

    // hw.cpufamily — chip family code. iOS apps fingerprinting performance
    // tier read this; an "Apple A12" cpufamily on a device claiming iPhone 6
    // is a red flag. Map well-known chip families per ProductType so the
    // value always matches the claimed model.
    if (strcmp(name, "hw.cpufamily") == 0 || strcmp(name, "hw.cpusubfamily") == 0) {
        id val = getConfig(@"hw_cpufamily");
        if (val && oldlenp && *oldlenp >= sizeof(uint32_t)) {
            uint32_t fam = (uint32_t)[val unsignedIntValue];
            memcpy(oldp, &fam, sizeof(uint32_t));
            return 0;
        }
    }

    // hw.tbfrequency — timer base frequency. Pinned per chip generation by
    // Apple. Used by some anti-cheat / device-trust frameworks to derive an
    // implicit chip ID. Spoofed value comes from config if app set it.
    if (strcmp(name, "hw.tbfrequency") == 0) {
        id val = getConfig(@"hw_tbfrequency");
        if (val && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t tb = ci_safeULL(val);
            memcpy(oldp, &tb, sizeof(uint64_t));
            return 0;
        }
    }

    // kern.boottime — when the device booted. struct timeval = {sec, usec}.
    // Read by app uptime calculations + anti-fraud freshness checks.
    // The fake_uptime layer also affects this: when set, return our spoofed
    // boottime so NSProcessInfo.systemUptime and direct sysctl agree.
    if (strcmp(name, "kern.boottime") == 0 && fakeLayer(@"uptime")) {
        id val = getConfig(@"kern_boottime");
        if (val && oldlenp && *oldlenp >= sizeof(struct timeval)) {
            struct timeval tv;
            tv.tv_sec = (time_t)[val longLongValue];
            tv.tv_usec = 0;
            memcpy(oldp, &tv, sizeof(struct timeval));
            *oldlenp = sizeof(struct timeval);
            return 0;
        }
    }

    // kern.osvariant_status — iOS 14+ encoding of build flavor (customer
    // release vs internal/debug). Apps use this to detect non-production
    // builds. "Customer release" canonical value below makes the kernel
    // claim a clean factory iOS build.
    // Bits encode: hasInternalContent, hasFactoryContent, isDebuggable,
    //              isRecovery, isReleaseType, ... (see osvariant.h)
    if (strcmp(name, "kern.osvariant_status") == 0) {
        if (oldlenp && *oldlenp >= sizeof(uint64_t)) {
            // 0x70000020D = customer release, no internal, no factory, no debug
            uint64_t v = 0x70000020DULL;
            memcpy(oldp, &v, sizeof(uint64_t));
            *oldlenp = sizeof(uint64_t);
            return 0;
        }
    }

    // kern.iossupportversion — iPad apps running on macOS via Catalyst read
    // this to detect host iOS version. Empty string = pure iOS device.
    if (strcmp(name, "kern.iossupportversion") == 0) {
        const char *empty = "";
        size_t needed = 1;
        if (oldlenp && *oldlenp >= needed) {
            memcpy(oldp, empty, needed);
            *oldlenp = needed;
            return 0;
        }
    }

    // hw.target — sibling of hw.machine. Some private API paths read both,
    // and a mismatch (e.g. machine=iPhone12,1 but target=iPhone10,2) is an
    // immediate red flag. Mirror our spoofed hw.machine value.
    if (strcmp(name, "hw.target") == 0) {
        NSString *val = getConfigStr(@"hw_machine");
        if (val) {
            const char *cval = [val UTF8String];
            size_t needed = strlen(cval) + 1;
            if (oldlenp && *oldlenp >= needed) {
                memcpy(oldp, cval, needed);
                *oldlenp = needed;
                return 0;
            }
        }
    }

    // kern.uuid — 36-char kernel UUID string. Persistent per device, used
    // by some fingerprint SDKs as a stable hardware identifier. Derived
    // deterministically from identifierForVendor so we get a stable per-
    // profile value without needing a separate config key.
    if (strcmp(name, "kern.uuid") == 0) {
        NSString *idfv = getConfigStr(@"identifierForVendor");
        if (idfv.length >= 32) {
            // Reformat as UUID string: XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
            NSString *hex = [[idfv stringByReplacingOccurrencesOfString:@"-" withString:@""]
                              uppercaseString];
            if (hex.length >= 32) {
                NSString *uuidStr = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                                     [hex substringWithRange:NSMakeRange(0, 8)],
                                     [hex substringWithRange:NSMakeRange(8, 4)],
                                     [hex substringWithRange:NSMakeRange(12, 4)],
                                     [hex substringWithRange:NSMakeRange(16, 4)],
                                     [hex substringWithRange:NSMakeRange(20, 12)]];
                const char *cval = [uuidStr UTF8String];
                size_t needed = strlen(cval) + 1;
                if (oldlenp && *oldlenp >= needed) {
                    memcpy(oldp, cval, needed);
                    *oldlenp = needed;
                    return 0;
                }
            }
        }
    }

    // kern.hostid — 32-bit integer host identifier. Derive deterministically
    // from identifierForVendor so it stays stable per profile.
    if (strcmp(name, "kern.hostid") == 0) {
        NSString *idfv = getConfigStr(@"identifierForVendor");
        if (idfv.length >= 8 && oldlenp && *oldlenp >= sizeof(int32_t)) {
            const char *u = [idfv UTF8String];
            int32_t h = 0;
            for (int i = 0; i < 8 && u[i]; i++) h = h * 31 + (uint8_t)u[i];
            memcpy(oldp, &h, sizeof(int32_t));
            *oldlenp = sizeof(int32_t);
            return 0;
        }
    }

    return ret;
}

// ============================================================
// CFHTTPMessageSetHeaderFieldValue hook (v2.4.58)
//
// Universal CFNetwork header setter — every HTTP request from
// URLSession, NSURLConnection, WebKit/Safari etc. calls this to
// assemble the request. We rewrite User-Agent to zalo_fakeWebViewUA
// so the bytes-on-wire UA matches the spoofed iOS version.
// ============================================================
#import <CFNetwork/CFHTTPMessage.h>
typedef Boolean (*CFHTTPMessageSetHeaderFieldValue_t)(CFHTTPMessageRef message, CFStringRef headerField, CFStringRef value);
CFHTTPMessageSetHeaderFieldValue_t orig_CFHTTPMessageSetHeaderFieldValue = NULL;

extern "C" Boolean hooked_CFHTTPMessageSetHeaderFieldValue(CFHTTPMessageRef message,
                                                            CFStringRef headerField,
                                                            CFStringRef value) {
    if (!fakeLayer(@"browser") || !headerField || !orig_CFHTTPMessageSetHeaderFieldValue) {
        return orig_CFHTTPMessageSetHeaderFieldValue(message, headerField, value);
    }
    NSString *field = (__bridge NSString *)headerField;
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        NSString *fakeUA = getConfigStr(@"zalo_fakeWebViewUA");
        if (fakeUA.length) {
            return orig_CFHTTPMessageSetHeaderFieldValue(message, headerField,
                                                          (__bridge CFStringRef)fakeUA);
        }
    }
    return orig_CFHTTPMessageSetHeaderFieldValue(message, headerField, value);
}

// ============================================================
// uname hook
// ============================================================
static int (*orig_uname)(struct utsname *name) = NULL;

static int hooked_uname(struct utsname *name) {
    int ret = orig_uname(name);
    if (ret != 0 || !name) return ret;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded) return ret;
    if (!fakeLayer(@"sysctl")) return ret;

    NSString *sysname  = getConfigStr(@"uname_sysname");
    NSString *nodename = getConfigStr(@"uname_nodename");
    NSString *release  = getConfigStr(@"uname_release");
    NSString *version  = getConfigStr(@"uname_version");
    NSString *machine  = getConfigStr(@"uname_machine");

    if (sysname)  strlcpy(name->sysname,  [sysname UTF8String],  sizeof(name->sysname));
    if (nodename) strlcpy(name->nodename, [nodename UTF8String], sizeof(name->nodename));
    if (release)  strlcpy(name->release,  [release UTF8String],  sizeof(name->release));
    if (version)  strlcpy(name->version,  [version UTF8String],  sizeof(name->version));
    if (machine)  strlcpy(name->machine,  [machine UTF8String],  sizeof(name->machine));

    return ret;
}

// ============================================================
// Shared JB path table — covers rootless (/var/jb/*), rootful, all major
// package managers, substrate hooks, apt/dpkg, JB binaries. Used by
// stat/lstat/access/fopen + NSFileManager so a check via any path API
// returns "not found".
//
// HOT PATH: stat()/access() can fire 10K+ times/sec during navigation
// (Zalo login flow alone hits ~5K stat calls in <1s). The previous NSArray
// + hasPrefix: implementation cost ~50µs/call → 250ms of pure hook
// overhead per login tap → 3s perceived delay across multiple checks.
//
// Pure-C strncmp implementation is ~50× faster: no Obj-C dispatch, no
// NSString allocation, no UTF-8↔UTF-16 conversion. Each prefix carries
// its precomputed length to avoid strlen() per call. A first-char gate
// filters out the >99% of paths that don't start with anything in our
// list (most stat targets are /System/, /usr/local/, app bundles, etc.).
// ============================================================
typedef struct { const char *prefix; size_t len; } ci_prefix_t;
#define CI_PREFIX(s) { (s), sizeof(s) - 1 }

static const ci_prefix_t kHiddenPrefixes[] = {
    // rootless roots
    CI_PREFIX("/var/jb"),
    CI_PREFIX("/private/var/jb"),
    // rootful + install markers
    CI_PREFIX("/var/binpack"),
    CI_PREFIX("/var/LIB"),
    CI_PREFIX("/var/ulb"),
    CI_PREFIX("/.installed_dopamine"),
    CI_PREFIX("/.installed_palera1n"),
    CI_PREFIX("/.bootstrapped"),
    CI_PREFIX("/.installed_unc0ver"),
    CI_PREFIX("/private/preboot"),
    // Package manager apps
    CI_PREFIX("/Applications/Cydia.app"),
    CI_PREFIX("/Applications/Sileo.app"),
    CI_PREFIX("/Applications/Zebra.app"),
    CI_PREFIX("/Applications/Installer.app"),
    CI_PREFIX("/Applications/Snoop-itConfig.app"),
    // Substrate / hook engines
    CI_PREFIX("/Library/MobileSubstrate"),
    CI_PREFIX("/usr/lib/TweakInject"),
    CI_PREFIX("/usr/lib/substrate"),
    CI_PREFIX("/usr/lib/libsubstrate.dylib"),
    CI_PREFIX("/usr/lib/libhooker.dylib"),
    CI_PREFIX("/usr/lib/libsubstitute.dylib"),
    CI_PREFIX("/usr/libexec/cydia"),
    CI_PREFIX("/usr/libexec/sftp-server"),
    // SSH
    CI_PREFIX("/usr/sbin/sshd"),
    CI_PREFIX("/usr/bin/ssh"),
    CI_PREFIX("/etc/ssh"),
    CI_PREFIX("/private/etc/ssh"),
    CI_PREFIX("/private/var/lib/cydia"),
    // apt / dpkg toolchain
    CI_PREFIX("/etc/apt"),
    CI_PREFIX("/private/etc/apt"),
    CI_PREFIX("/var/lib/apt"),
    CI_PREFIX("/var/lib/dpkg"),
    CI_PREFIX("/var/cache/apt"),
    CI_PREFIX("/usr/bin/dpkg"),
    CI_PREFIX("/usr/bin/apt"),
    // Cydia / Sileo / Zebra caches
    CI_PREFIX("/var/mobile/Library/Caches/com.saurik.Cydia"),
    CI_PREFIX("/var/mobile/Library/Caches/com.coolstar.Sileo"),
    CI_PREFIX("/var/mobile/Library/Caches/xyz.willy.Zebra"),
    // JB-shipped binaries
    CI_PREFIX("/bin/bash"),
    CI_PREFIX("/bin/sh"),
    CI_PREFIX("/usr/sbin/frida-server"),
};
static const size_t kHiddenPrefixCount = sizeof(kHiddenPrefixes) / sizeof(kHiddenPrefixes[0]);

extern "C" BOOL ci_isHiddenJBPath(const char *path) {
    if (!path || path[0] != '/') return NO;
    // Second-char gate — drops the vast majority of /System, /usr/local,
    // /private/var/mobile/Containers, etc. before the strncmp loop. Only
    // these initial chars appear at index 1 in our prefix table:
    //   '.' (dot-markers), 'A' (/Applications), 'L' (/Library),
    //   'b' (/bin), 'e' (/etc), 'p' (/private), 'u' (/usr), 'v' (/var).
    char c = path[1];
    if (c != '.' && c != 'A' && c != 'L' && c != 'b' && c != 'e'
        && c != 'p' && c != 'u' && c != 'v') return NO;
    for (size_t i = 0; i < kHiddenPrefixCount; i++) {
        const ci_prefix_t *p = &kHiddenPrefixes[i];
        if (p->prefix[1] != c) continue;  // cheap pre-filter
        if (strncmp(path, p->prefix, p->len) == 0) return YES;
    }
    return NO;
}

// ============================================================
// SystemVersion.plist redirect — defeats AIDA64 / device-info SDKs that
// bypass MGCopyAnswer and NSDictionary class hooks and read the file via
// NSPropertyListSerialization, CFPropertyList, or -initWithContentsOfURL:
// (any of which ultimately call open()).
//
// Strategy: pre-build a fake SystemVersion.plist in NSTemporaryDirectory()
// with our spoofed ProductVersion + ProductBuildVersion, then hook open()
// + openat() to redirect any read of /System/.../SystemVersion.plist to
// the tmp file. Result: every API path that ends up calling open() sees
// the fake content, no matter how high-level the caller.
// ============================================================
static char g_fakeSysVerTmpPath[256]  = {0};
static char g_lastSpoofedVer[64]      = {0};
static char g_lastSpoofedBuild[64]    = {0};

static void ci_writeFakeSysVerPlistIfNeeded(void) {
    @autoreleasepool {
        NSString *ver = getConfigStr(@"systemVersion");
        NSString *bld = getConfigStr(@"BuildVersion");
        if (ver.length == 0 || bld.length == 0) return;
        const char *vc = ver.UTF8String;
        const char *bc = bld.UTF8String;
        if (!vc || !bc) return;
        // Skip rewrite if config unchanged since last write.
        if (g_fakeSysVerTmpPath[0] != 0 &&
            strcmp(vc, g_lastSpoofedVer)   == 0 &&
            strcmp(bc, g_lastSpoofedBuild) == 0) {
            return;
        }
        NSDictionary *dict = @{
            @"BuildID":             [[NSUUID UUID] UUIDString],
            @"ProductBuildVersion": bld,
            @"ProductCopyright":    @"1983-2025 Apple Inc.",
            @"ProductName":         @"iPhone OS",
            @"ProductVersion":      ver,
            @"SystemImageID":       [[NSUUID UUID] UUIDString],
        };
        NSData *data = [NSPropertyListSerialization
            dataWithPropertyList:dict
                          format:NSPropertyListXMLFormat_v1_0
                         options:0 error:nil];
        if (!data) return;
        NSString *tmpPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"ci_fake_sysver.plist"];
        if ([data writeToFile:tmpPath atomically:YES]) {
            strncpy(g_fakeSysVerTmpPath, tmpPath.UTF8String, sizeof(g_fakeSysVerTmpPath)-1);
            g_fakeSysVerTmpPath[sizeof(g_fakeSysVerTmpPath)-1] = 0;
            strncpy(g_lastSpoofedVer, vc, sizeof(g_lastSpoofedVer)-1);
            g_lastSpoofedVer[sizeof(g_lastSpoofedVer)-1] = 0;
            strncpy(g_lastSpoofedBuild, bc, sizeof(g_lastSpoofedBuild)-1);
            g_lastSpoofedBuild[sizeof(g_lastSpoofedBuild)-1] = 0;
        }
    }
}

// Strict canonical path — only Apple's official SystemVersion.plist gets
// redirected. Previous strstr-based filter accidentally matched any path
// ending with "/SystemVersion.plist" (e.g., some framework's private
// resource bundle), causing those apps to receive our spoofed dict and
// fail to parse → crash. AIDA64 crashed on launch from this.
static const char kSystemVersionCanonicalPath[] =
    "/System/Library/CoreServices/SystemVersion.plist";

static inline BOOL ci_isSystemVersionPath(const char *path) {
    if (!path) return NO;
    // Skip our own tmp file (writeToFile opens it during plist write).
    if (g_fakeSysVerTmpPath[0] && strcmp(path, g_fakeSysVerTmpPath) == 0) return NO;
    return strcmp(path, kSystemVersionCanonicalPath) == 0;
}

// open()/openat() hooks deliberately do NOT call fakeLayer() — fakeLayer
// uses @synchronized + dispatch_once + plist load that can re-enter the
// open() path on first call, racing with the hook's own recursion guard.
// Use direct getConfigBool() (just an NSDict lookup, no I/O) and the
// is_critical_process() filter so we never disturb SpringBoard / installd /
// daemons that legitimately need the real SystemVersion.plist.
static BOOL ci_sysVerSpoofActive(void) {
    if (is_critical_process()) return NO;
    if (getConfigBool(@"_ci_skipall")) return NO;
    if (!getConfigBool(@"fake_sysosversion")) return NO;
    return YES;
}

static int (*orig_open)(const char *path, int flags, ...) = NULL;
static int hooked_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (path && ci_isSystemVersionPath(path) && ci_sysVerSpoofActive()) {
        ci_writeFakeSysVerPlistIfNeeded();
        if (g_fakeSysVerTmpPath[0]) {
            return orig_open(g_fakeSysVerTmpPath, flags, mode);
        }
    }
    return orig_open(path, flags, mode);
}

static int (*orig_openat)(int dirfd, const char *path, int flags, ...) = NULL;
static int hooked_openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap;
        va_start(ap, flags);
        mode = (mode_t)va_arg(ap, int);
        va_end(ap);
    }
    if (path && ci_isSystemVersionPath(path) && ci_sysVerSpoofActive()) {
        ci_writeFakeSysVerPlistIfNeeded();
        if (g_fakeSysVerTmpPath[0]) {
            return orig_openat(dirfd, g_fakeSysVerTmpPath, flags, mode);
        }
    }
    return orig_openat(dirfd, path, flags, mode);
}

// ============================================================
// stat hook
// ============================================================
static int (*orig_stat)(const char *path, struct stat *buf) = NULL;

static int hooked_stat(const char *path, struct stat *buf) {
    if (jbHideActive() && ci_isHiddenJBPath(path)) { errno = ENOENT; return -1; }
    return orig_stat(path, buf);
}

// ============================================================
// lstat hook
// ============================================================
static int (*orig_lstat)(const char *path, struct stat *buf) = NULL;

static int hooked_lstat(const char *path, struct stat *buf) {
    if (jbHideActive() && ci_isHiddenJBPath(path)) { errno = ENOENT; return -1; }
    return orig_lstat(path, buf);
}

// ============================================================
// access hook
// ============================================================
static int (*orig_access)(const char *path, int mode) = NULL;

static int hooked_access(const char *path, int mode) {
    if (jbHideActive() && ci_isHiddenJBPath(path)) { errno = ENOENT; return -1; }
    return orig_access(path, mode);
}

// ============================================================
// fopen hook
// ============================================================
static FILE *(*orig_fopen)(const char *path, const char *mode) = NULL;

static FILE *hooked_fopen(const char *path, const char *mode) {
    if (jbHideActive() && ci_isHiddenJBPath(path)) { errno = ENOENT; return NULL; }
    return orig_fopen(path, mode);
}

// ============================================================
// Substrate-dylib substring table — used by dlopen, dladdr,
// _dyld_get_image_name, _dyld_image_count.
//
// CRITICAL PERF NOTE: _dyld_image_count is called THOUSANDS of times
// during Zalo's login/register button tap (UIKit + framework lazy load,
// dlsym resolution, AVFoundation bring-up). The previous implementation
// iterated ~300 loaded dylibs per call, doing 1 NSString stringWithUTF8
// + 5 containsString: per dylib = ~1500 obj allocations + 1500 method
// dispatches per call. At 1000 calls during navigation that's 1.5M
// allocations → 3-4 seconds of pure hook overhead → the "4s lag before
// the login page appears" that previous bisect builds could not pin
// down (commits 42a6f58, 762f91b, 0a7ccf8).
//
// Fix: pure-C strstr against a NULL-terminated const char* table.
// strstr on short substrings is ~20× faster than NSString containsString
// and zero allocations. Same coverage; same fail-closed behaviour.
static const char *kSubstrateSubstrings[] = {
    "Substrate",        // CydiaSubstrate, SubstrateLoader, SubstrateInserter, SubstrateBootstrap
    "TweakInject",
    "ElleKit",
    "libhooker",
    "substitute",
    "pspawn_payload",
    "ChangeInfoIos",    // hide ourselves
    NULL,
};

static inline BOOL ci_pathHasSubstrateSubstring(const char *path) {
    if (!path) return NO;
    for (const char **s = kSubstrateSubstrings; *s; s++) {
        if (strstr(path, *s)) return YES;
    }
    return NO;
}

// ============================================================
// dlopen hook — block substrate dylib loads from anti-tweak probes.
// ============================================================
static void *(*orig_dlopen)(const char *path, int mode) = NULL;

static void *hooked_dlopen(const char *path, int mode) {
    if (is_critical_process()) return orig_dlopen(path, mode);
    if (jbHideActive() && ci_pathHasSubstrateSubstring(path)) return NULL;
    return orig_dlopen(path, mode);
}

// ============================================================
// gethostname hook
// ============================================================
static int (*orig_gethostname)(char *name, size_t namelen) = NULL;

static int hooked_gethostname(char *name, size_t namelen) {
    int ret = orig_gethostname(name, namelen);
    if (!fakeLayer(@"sysctl")) return ret;
    NSString *hostname = getConfigStr(@"kern_hostname");
    if (hostname && name && namelen > 0) {
        strlcpy(name, [hostname UTF8String], namelen);
    }
    return ret;
}

// ============================================================
// getifaddrs hook — spoof raw MAC at the BSD socket layer.
// ============================================================
// UIDevice / CTCarrier hooks cover the high-level Obj-C API. Apps that
// fingerprint via the C API (`getifaddrs()` then walk for AF_LINK and
// read sa_data bytes) bypass everything above and read the real MAC.
// Replace bytes 0..5 of every AF_LINK sockaddr_dl's sdl_data with our
// spoofed MAC from config (key WiFiAddress). Free path stays default
// — we don't dup the linked list, so freeifaddrs() still works.
//
// MAC parse: WiFiAddress is "AA:BB:CC:DD:EE:FF" — take 6 bytes.
typedef int (*getifaddrs_t)(struct ifaddrs **ifap);
typedef void (*freeifaddrs_t)(struct ifaddrs *ifa);
static getifaddrs_t   orig_getifaddrs = NULL;
static freeifaddrs_t  orig_freeifaddrs = NULL;

static BOOL ci_parseMAC(NSString *macStr, uint8_t out[6]) {
    if (![macStr isKindOfClass:[NSString class]]) return NO;
    NSArray *parts = [macStr componentsSeparatedByString:@":"];
    if (parts.count != 6) return NO;
    for (int i = 0; i < 6; i++) {
        unsigned int v = 0;
        if (sscanf([parts[i] UTF8String], "%02x", &v) != 1) return NO;
        out[i] = (uint8_t)v;
    }
    return YES;
}

static int hooked_getifaddrs(struct ifaddrs **ifap) {
    int ret = orig_getifaddrs ? orig_getifaddrs(ifap) : -1;
    if (ret != 0 || !ifap || !*ifap) return ret;
    if (!fakeLayer(@"network")) return ret;
    uint8_t fakeMAC[6];
    if (!ci_parseMAC(getConfigStr(@"WiFiAddress"), fakeMAC)) return ret;

    for (struct ifaddrs *p = *ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)p->ifa_addr;
        if (sdl->sdl_alen != 6) continue; // only spoof full 6-byte MAC
        // sdl_data layout: [name (sdl_nlen bytes)][addr (sdl_alen bytes)]
        unsigned char *macStart = (unsigned char *)LLADDR(sdl);
        memcpy(macStart, fakeMAC, 6);
    }
    return ret;
}

// ============================================================
// objc_getClassList — hide our tweak's classes from runtime enumeration.
// ============================================================
// Anti-tweak SDKs walk the loaded class list and grep for tweak-author
// signatures (Logos / substrate / known tweak class prefixes). When they
// see "CISpoofProxyDelegate" / "CIConfigManager" / "CISideMenuViewController"
// in the host process, they know the app is jailbroken and a tweak is
// active, then sometimes fail-closed or report telemetry. Filter our
// classes out of the buffer so list-walks see a clean app.
typedef int (*objc_getClassList_t)(Class *buffer, int bufferCount);
static objc_getClassList_t orig_objc_getClassList = NULL;

static BOOL ci_isOurClass(const char *name) {
    if (!name) return NO;
    // Exact-match allowlist. CRITICAL: CANNOT use a "CI" prefix filter —
    // CoreImage ships dozens of classes with that prefix (CIImage, CIFilter,
    // CIContext, CILinearKernel, CIVector, …) which Zalo and most messaging
    // apps use heavily for image processing. Hiding those from runtime walks
    // makes CoreImage code paths see a phantom-empty class list and the app
    // crashes when a CIFilter alloc returns nil. Only hide what we actually
    // ship.
    static const char *ours[] = {
        "CIConfigManager",
        "CIHomeViewController",
        "CIAppPickerViewController",
        "CIFakeSettingsViewController",
        "CIRRSManagerViewController",
        "CISideMenuViewController",
        "CIProxyViewController",
        "CIAppLister",
        "CIRRSStore",
        "CIRRSEntry",
        "CIAppInfo",
        "CITheme",
        "CIFakeReportRow",
        "CIFakeReportSection",
        "CIFakeInfoReportViewController",
        NULL
    };
    for (int i = 0; ours[i]; i++) {
        if (strcmp(name, ours[i]) == 0) return YES;
    }
    return NO;
}

static int hooked_objc_getClassList(Class *buffer, int bufferCount) {
    int real = orig_objc_getClassList ? orig_objc_getClassList(buffer, bufferCount) : 0;
    if (!buffer || real <= 0) return real;
    // PERFORMANCE: Apple's runtime calls objc_getClassList in tight loops
    // with small buffers (e.g. probing for a single class via runtime
    // KVO/serialization). Anti-tweak SDKs walk the FULL class list with
    // buffers >> 100 entries. Skip the filter for small probes — saves
    // millions of strcmp comparisons during normal app operation.
    if (real < 200) return real;
    if (!fakeLayer(@"jbhide")) return real;

    int n = real < bufferCount ? real : bufferCount;
    int w = 0;
    for (int r = 0; r < n; r++) {
        if (ci_isOurClass(class_getName(buffer[r]))) continue;
        if (w != r) buffer[w] = buffer[r];
        w++;
    }
    for (int i = w; i < n; i++) buffer[i] = Nil;
    return w;
}

// ============================================================
// statfs / statfs64 / statvfs — disk capacity coherence.
// ============================================================
// Apps that bypass MGCopyAnswer / NSFileManager for disk size go to
// statfs("/") directly — gets f_blocks * f_bsize = total disk bytes.
// We've spoofed TotalDiskCapacity in config; route the syscall return
// through that value so apps see the same number across all paths.
typedef int (*statfs_t)(const char *path, struct statfs *buf);
static statfs_t orig_statfs = NULL;

static int hooked_statfs(const char *path, struct statfs *buf) {
    int ret = orig_statfs ? orig_statfs(path, buf) : -1;
    if (ret != 0 || !buf || !path) return ret;
    // PERFORMANCE: cheap path filter FIRST before fakeLayer's
    // dispatch_once + dict lookup. Most statfs calls target sandbox
    // paths and exit immediately here; only root-volume queries hit
    // the heavier check.
    if (strcmp(path, "/") != 0 && strncmp(path, "/private/var", 12) != 0) return ret;
    if (!fakeLayer(@"hardware")) return ret;

    id totalObj = getConfig(@"TotalDiskCapacity");
    id usageObj = getConfig(@"DiskUsage");
    if (!totalObj) return ret;

    unsigned long long total = [totalObj unsignedLongLongValue];
    unsigned long long usage = usageObj ? [usageObj unsignedLongLongValue] : 0;
    if (total == 0) return ret;

    uint32_t bsize = buf->f_bsize > 0 ? buf->f_bsize : 4096;
    buf->f_bsize  = bsize;
    buf->f_blocks = total / bsize;
    buf->f_bfree  = (total - usage) / bsize;
    buf->f_bavail = buf->f_bfree;

    // v2.4.47: spoof APFS volume UUID via f_fsid. Same identifier readable
    // via statfs("/") survives container recreation otherwise → persistent
    // device fingerprint. Derive from identifierForVendor config so it's
    // stable per-fake-device but changes after Reset Data (host writes a
    // new vendor UUID in config on reset).
    NSString *vUUID = getConfigStr(@"identifierForVendor");
    if (vUUID.length >= 16) {
        const char *u = vUUID.UTF8String;
        uint32_t a = 0, b = 0;
        for (int i = 0; i < 8; i++)  a = a * 31 + (uint8_t)u[i];
        for (int i = 8; i < 16; i++) b = b * 31 + (uint8_t)u[i];
        buf->f_fsid.val[0] = (int32_t)a;
        buf->f_fsid.val[1] = (int32_t)b;
    }
    return ret;
}

// ============================================================
// getattrlist hook — spoof APFS volume UUID (Tier 9, v2.4.50)
//
// Apps bypass statfs.f_fsid by calling getattrlist() with
//   attrList.volattr = ATTR_VOL_INFO | ATTR_VOL_UUID
// which fills a uuid_t at &buf[sizeof(u_int32_t)]. Same identifier as
// /System diskutil shows. Without spoof, the full 16-byte volume UUID
// leaks through every other layer of our spoof.
//
// Buffer layout when volattr contains exactly INFO | UUID:
//   [u_int32_t length][uuid_t volume_uuid]   = 4 + 16 = 20 bytes
// Many SDKs combine UUID with other volattrs; rewriting at offset 4
// only is correct because ATTR_VOL_INFO is the size marker (consumes
// 0 data) and ATTR_VOL_UUID is the lowest-bit volattr Apple defines
// so it always appears first in the data section.
// ============================================================
#include <sys/attr.h>
typedef int (*getattrlist_t)(const char *path, struct attrlist *attrList, void *attrBuf, size_t attrBufSize, unsigned long options);
static getattrlist_t orig_getattrlist = NULL;

#ifndef ATTR_VOL_UUID
#define ATTR_VOL_UUID 0x00004000
#endif
#ifndef ATTR_VOL_INFO
#define ATTR_VOL_INFO 0x80000000
#endif

static int hooked_getattrlist(const char *path, struct attrlist *attrList,
                              void *attrBuf, size_t attrBufSize, unsigned long options) {
    int ret = orig_getattrlist ? orig_getattrlist(path, attrList, attrBuf, attrBufSize, options) : -1;
    if (ret != 0 || !attrList || !attrBuf) return ret;
    if (!fakeLayer(@"hardware")) return ret;
    // Only intercept volume UUID requests.
    if (!(attrList->volattr & ATTR_VOL_UUID)) return ret;
    // Buffer must hold length header (4) + uuid_t (16) — refuse smaller.
    if (attrBufSize < sizeof(u_int32_t) + sizeof(uuid_t)) return ret;
    NSString *vUUID = getConfigStr(@"identifierForVendor");
    if (vUUID.length < 16) return ret;
    // Derive 16 bytes from identifierForVendor (matches f_fsid derivation
    // so statfs.f_fsid and ATTR_VOL_UUID stay correlated per profile).
    NSString *hex = [[vUUID stringByReplacingOccurrencesOfString:@"-" withString:@""]
                      uppercaseString];
    if (hex.length < 32) return ret;
    uint8_t newUUID[16];
    for (int i = 0; i < 16; i++) {
        unsigned int v = 0;
        const char *h = [[hex substringWithRange:NSMakeRange(i*2, 2)] UTF8String];
        if (sscanf(h, "%02x", &v) == 1) newUUID[i] = (uint8_t)v;
        else newUUID[i] = 0;
    }
    // Set version bits to look like a valid UUIDv4 (Apple's real volume
    // UUIDs are RFC 4122 v4).
    newUUID[6] = (newUUID[6] & 0x0F) | 0x40;
    newUUID[8] = (newUUID[8] & 0x3F) | 0x80;
    // Overwrite in place at offset sizeof(u_int32_t).
    memcpy((uint8_t *)attrBuf + sizeof(u_int32_t), newUUID, sizeof(newUUID));
    return 0;
}

// ============================================================
// gethostuuid hook — return spoofed 16-byte hardware UUID.
// ============================================================
// `int gethostuuid(uuid_t spec, const struct timespec *wait)` — fills
// the 16-byte uuid_t with this device's hardware UUID. Some fingerprint
// libraries call this directly because it's a Darwin-private syscall
// (gethostuuid → syscall 142) that bypasses every Obj-C / sysctl hook.
// We synthesize from config UniqueDeviceID (40 hex chars = 20 bytes;
// take first 16) so the value is deterministic per Reset Data and
// matches the Obj-C side's identifier story.
typedef int (*gethostuuid_t)(uuid_t spec, const struct timespec *wait);
static gethostuuid_t orig_gethostuuid = NULL;

static int hooked_gethostuuid(uuid_t spec, const struct timespec *wait) {
    int ret = orig_gethostuuid ? orig_gethostuuid(spec, wait) : -1;
    if (ret != 0 || !spec) return ret;
    if (!fakeLayer(@"hardware")) return ret;
    NSString *udid = getConfigStr(@"UniqueDeviceID");
    if (udid.length < 32) return ret; // need ≥16 bytes worth of hex
    for (int i = 0; i < 16; i++) {
        unsigned int v = 0;
        const char *hex = [[udid substringWithRange:NSMakeRange(i*2, 2)] UTF8String];
        if (sscanf(hex, "%02x", &v) == 1) spec[i] = (uint8_t)v;
    }
    return 0;
}

// ============================================================
// gettimeofday + clock_gettime hooks — coherent with mach_absolute_time
// ============================================================
// Anti-fraud SDKs cross-check timing sources: mach_absolute_time vs
// CFAbsoluteTimeGetCurrent vs gettimeofday. If we offset one but not
// others, the inconsistency itself becomes a fingerprint. Default
// behaviour is passthrough (no offset); adding _ci_clock_offset_secs
// shifts wall-clock-based sources by N seconds for cases where you
// want to fake the device's perceived "now".
typedef int (*gettimeofday_t)(struct timeval *tv, void *tz);
typedef int (*clock_gettime_t)(clockid_t clk_id, struct timespec *tp);
static gettimeofday_t   orig_gettimeofday   = NULL;
static clock_gettime_t  orig_clock_gettime  = NULL;

// PERFORMANCE: gettimeofday + clock_gettime are called by EVERY UI tick
// timer / animation / NSDate / network handshake — Zalo fires ~10K+
// per second. Caching: read _ci_clock_offset_secs once at first call,
// store in atomic int64. After dispatch_once, every call is one
// ATOMIC LOAD + ADD — sub-nanosecond cost. fakeLayer / getConfig are
// not invoked at all in steady state.
static int64_t g_clock_offset_secs_cached = 0;
static dispatch_once_t g_clock_offset_once;
static inline void ci_loadClockOffset(void) {
    dispatch_once(&g_clock_offset_once, ^{
        if (fakeLayer(@"timing")) {
            id off = getConfig(@"_ci_clock_offset_secs");
            if (off) g_clock_offset_secs_cached = [off longLongValue];
        }
    });
}

static int hooked_gettimeofday(struct timeval *tv, void *tz) {
    int ret = orig_gettimeofday ? orig_gettimeofday(tv, tz) : -1;
    if (ret != 0 || !tv) return ret;
    ci_loadClockOffset();
    if (g_clock_offset_secs_cached) tv->tv_sec += (time_t)g_clock_offset_secs_cached;
    return ret;
}

static int hooked_clock_gettime(clockid_t clk_id, struct timespec *tp) {
    int ret = orig_clock_gettime ? orig_clock_gettime(clk_id, tp) : -1;
    if (ret != 0 || !tp) return ret;
    if (clk_id != CLOCK_REALTIME) return ret;
    ci_loadClockOffset();
    if (g_clock_offset_secs_cached) tp->tv_sec += (time_t)g_clock_offset_secs_cached;
    return ret;
}

// ============================================================
// mach_absolute_time hook
// ============================================================
static uint64_t (*orig_mach_absolute_time)(void) = NULL;

// PERFORMANCE: mach_absolute_time is the HOTTEST hook in the dylib.
// CADisplayLink, NSTimer, every dispatch_async timestamp, every animation
// frame — Zalo fires this MILLIONS of times per second. Pre-cache the
// offset once so steady-state cost is one atomic load + integer add.
static int64_t g_mach_offset_cached = 0;
static dispatch_once_t g_mach_offset_once;

static uint64_t hooked_mach_absolute_time(void) {
    uint64_t real = orig_mach_absolute_time();
    dispatch_once(&g_mach_offset_once, ^{
        if (fakeLayer(@"timing")) {
            id offset = getConfig(@"zalo_timingOffset");
            if (offset) g_mach_offset_cached = [offset longLongValue];
        }
    });
    return (uint64_t)((int64_t)real + g_mach_offset_cached);
}

// ============================================================
// CFAbsoluteTimeGetCurrent hook
// ============================================================
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void) = NULL;

// v2.4.64 PERF: cache the offset at first call. CFAbsoluteTimeGetCurrent
// is called by EVERY animation tick, CADisplayLink callback, dispatch_after
// timestamp — Zalo fires it thousands of times per second during scroll.
// Steady-state cost is now: 1 ATOMIC LOAD + 1 ADD. fakeLayer/getConfig
// are not invoked at all after the first call.
static double g_cfabs_offset_cached = 0.0;
static dispatch_once_t g_cfabs_offset_once;

static CFAbsoluteTime hooked_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real = orig_CFAbsoluteTimeGetCurrent();
    dispatch_once(&g_cfabs_offset_once, ^{
        if (fakeLayer(@"timing")) {
            id offset = getConfig(@"zalo_timingOffset");
            if (offset) g_cfabs_offset_cached = [offset doubleValue] / 1000000000.0;
        }
    });
    return real + g_cfabs_offset_cached;
}

// ============================================================
// dladdr hook — pure C strstr, no NSString allocation per call.
// ============================================================
static int (*orig_dladdr)(const void *addr, Dl_info *info) = NULL;

static int hooked_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (!jbHideActive() || ret == 0 || !info || !info->dli_fname) return ret;
    if (ci_pathHasSubstrateSubstring(info->dli_fname)) {
        info->dli_fname = "/System/Library/Frameworks/UIKit.framework/UIKit";
        info->dli_sname = "UIApplicationMain";
        info->dli_saddr = NULL;
    }
    return ret;
}

// ============================================================
// _dyld_get_image_name hook — pure C strstr.
// ============================================================
static const char *(*orig__dyld_get_image_name)(uint32_t image_index) = NULL;

static const char *hooked__dyld_get_image_name(uint32_t image_index) {
    const char *name = orig__dyld_get_image_name(image_index);
    if (!jbHideActive() || !name) return name;
    if (ci_pathHasSubstrateSubstring(name)) {
        return "/System/Library/Frameworks/UIKit.framework/UIKit";
    }
    return name;
}

// ============================================================
// _dyld_image_count hook — THIS WAS THE 4-SECOND LAG ROOT CAUSE.
//
// Apps call _dyld_image_count thousands of times during VC transitions
// (UIKit lazy load, framework dlopen chain, swizzle init). The previous
// build re-walked the full ~300-image dylib list on EVERY call, doing
// per-image NSString allocs + 5 containsString:s. At 1000 calls/sec
// that's 1.5M Obj-C allocations → user-perceived 4s freeze before the
// register/login VC appears.
//
// Fix: cache the substrate-hidden count, refreshed only when the real
// image count changes (which signals dlopen/dlclose has happened).
// Steady-state lookups become 2 atomic reads + a subtract — ~5ns.
// ============================================================
static uint32_t (*orig__dyld_image_count)(void) = NULL;

// Cache: last seen real count + computed hidden count. Both signed so
// "uninitialized" sentinels work even at zero.
static _Atomic int32_t s_lastRealCount   = -1;
static _Atomic int32_t s_lastHiddenCount = 0;

static uint32_t hooked__dyld_image_count(void) {
    uint32_t count = orig__dyld_image_count();
    if (!jbHideActive()) return count;
    int32_t prevReal = atomic_load_explicit(&s_lastRealCount, memory_order_relaxed);
    if ((int32_t)count != prevReal) {
        // dylib list changed — recount hidden entries via C strstr.
        uint32_t hidden = 0;
        for (uint32_t i = 0; i < count; i++) {
            const char *name = orig__dyld_get_image_name(i);
            if (name && ci_pathHasSubstrateSubstring(name)) hidden++;
        }
        atomic_store_explicit(&s_lastHiddenCount, (int32_t)hidden, memory_order_relaxed);
        atomic_store_explicit(&s_lastRealCount,   (int32_t)count,  memory_order_relaxed);
        return count - hidden;
    }
    // Cache hit — no walk, no allocations.
    int32_t cachedHidden = atomic_load_explicit(&s_lastHiddenCount, memory_order_relaxed);
    return count - (uint32_t)cachedHidden;
}

// ============================================================
// _dyld_get_shared_cache_uuid hook (Tier 6, v2.4.50)
//
// Returns the UUID of the on-device dyld_shared_cache file. Fingerprint
// libraries read this to derive exact iOS build identity — a value
// pinned to the real OS leaks through every other layer of our spoof.
//
// Derive deterministically from the spoofed kern_osversion string so the
// cache UUID matches the claimed OS build. Use a simple FNV-1a hash to
// fill 16 bytes from the version+build string.
// ============================================================
static int (*orig__dyld_get_shared_cache_uuid)(uuid_t uuid) = NULL;

static int hooked__dyld_get_shared_cache_uuid(uuid_t uuid) {
    int ret = orig__dyld_get_shared_cache_uuid ? orig__dyld_get_shared_cache_uuid(uuid) : -1;
    if (!uuid) return ret;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded) return ret;
    if (!fakeLayer(@"sysctl")) return ret;

    NSString *seed = getConfigStr(@"kern_osversion") ?: getConfigStr(@"systemVersion");
    if (!seed.length) return ret;

    const char *s = [seed UTF8String];
    // FNV-1a fills 2× 64-bit halves with different seeds for a 16-byte UUID.
    uint64_t h1 = 0xcbf29ce484222325ULL;
    uint64_t h2 = 0x84222325cbf29ce4ULL;
    for (size_t i = 0; s[i]; i++) {
        h1 ^= (uint8_t)s[i]; h1 *= 0x100000001b3ULL;
        h2 ^= (uint8_t)s[i] + (i & 0xFF); h2 *= 0x100000001b3ULL;
    }
    memcpy(uuid,     &h1, 8);
    memcpy(uuid + 8, &h2, 8);
    // Set version bits to look like a valid UUIDv4.
    uuid[6] = (uuid[6] & 0x0F) | 0x40;
    uuid[8] = (uuid[8] & 0x3F) | 0x80;
    return 0;
}

// ============================================================
// fork hook
// ============================================================
static pid_t (*orig_fork)(void) = NULL;

static pid_t hooked_fork(void) {
    if (is_critical_process()) return orig_fork();
    if (jbHideActive()) {
        errno = ENOSYS;
        return -1;
    }
    return orig_fork();
}

// ============================================================
// getenv hook
// ============================================================
static char *(*orig_getenv)(const char *name) = NULL;

static char *hooked_getenv(const char *name) {
    if (is_critical_process()) return orig_getenv(name);
    if (jbHideActive() && name) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
            strcmp(name, "MobileSubstratePath") == 0 ||
            strcmp(name, "_MSSafeMode") == 0 ||
            strcmp(name, "DYLD_FRAMEWORK_PATH") == 0 ||
            strcmp(name, "DYLD_LIBRARY_PATH") == 0) {
            return NULL;
        }
    }
    return orig_getenv(name);
}

// ============================================================
// SecItemCopyMatching hook (Keychain)
// ============================================================
#if __has_include(<Security/Security.h>)
#import <Security/Security.h>

typedef OSStatus (*SecItemCopyMatching_t)(CFDictionaryRef query, CFTypeRef *result);
static SecItemCopyMatching_t orig_SecItemCopyMatching = NULL;

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (g_ci_skipKeychainHook) return orig_SecItemCopyMatching(query, result);
    if (!fakeLayer(@"keychain")) return orig_SecItemCopyMatching(query, result);
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded || !getConfigBool(@"keychainReset")) return orig_SecItemCopyMatching(query, result);

    NSDictionary *queryDict = (__bridge NSDictionary *)query;
    NSString *service = queryDict[(__bridge NSString *)kSecAttrService];

    if (service) {
        if ([service containsString:@"com.vng.zalo"]) {
            if (result) *result = NULL;
            return errSecItemNotFound;
        }

        BOOL isTwitterService = [service containsString:@"com.atebits"] ||
                                [service containsString:@"com.twitter"] ||
                                [service containsString:@"TwitterKit"] ||
                                [service containsString:@"com.x.ios"];
        if (isTwitterService) {
            // v2.5.45: hoist the deviceKeys array out of the hot path —
            // SecItemCopyMatching is called every time an app reads keychain
            // (Zalo session check on every API call), and we were rebuilding
            // an 11-string NSArray + per-key lowercaseString on every match.
            static NSArray<NSString *> *kTwDeviceKeysLC = nil;
            static dispatch_once_t twKeysOnce;
            dispatch_once(&twKeysOnce, ^{
                kTwDeviceKeysLC = @[@"device_id", @"device_uuid", @"install_id",
                                    @"client_id", @"advertising_id", @"fingerprint",
                                    @"twclientid", @"twdeviceid", @"ktwdevice",
                                    @"persistent_id", @"hardware_id"];
            });
            NSString *account = queryDict[(__bridge NSString *)kSecAttrAccount];
            NSString *accLC = account.lowercaseString;
            NSString *svcLC = service.lowercaseString;
            for (NSString *dk in kTwDeviceKeysLC) {
                if ((accLC && [accLC containsString:dk]) ||
                    (svcLC && [svcLC containsString:dk])) {
                    if (result) *result = NULL;
                    return errSecItemNotFound;
                }
            }
        }
    }

    return orig_SecItemCopyMatching(query, result);
}

// ====== ROLLBACK START: Batch E — SecItemAdd / SecItemUpdate write blocker ======
// Added 2026-05-07. If this batch causes crashes, set
//    _ci_enable_secwrite=false via SSH (default OFF)
// or delete this block + the matching install call in initCLvlHooks.
// The existing -CopyMatching hook above is NOT affected.
//
// Why: -SecItemCopyMatching only blocks READS. Apps write device IDs via
// -SecItemAdd / -SecItemUpdate (e.g. Zalo's kZaloDeviceId, com.vng.zalo
// install_id) at sign-up. After Reset Data wipes the keychain, the app's
// next launch ADDS a fresh ID — but that ID is again unique per device,
// so Zalo's server records it as a new install of the SAME device. Server
// fingerprints across reg attempts and starts banning.
//
// Strategy: when the app tries to ADD or UPDATE an entry whose service
// or account string looks like a device identifier, return errSecSuccess
// without actually persisting. The app gets a "yes, stored" response; the
// next CopyMatching call returns errSecItemNotFound (because nothing was
// written), and the app generates a fresh ID for that session. Each
// session (process lifetime) gets a different ID — server sees a churn
// of "new devices", harder to fingerprint to a single hardware.

static BOOL ci_isDeviceIDKey(NSString *s) {
    if (s.length == 0) return NO;
    static NSArray *patterns = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        patterns = @[
            // Generic device IDs
            @"device_id", @"deviceid", @"device_uuid", @"deviceuuid",
            @"device_token", @"devicetoken",
            @"install_id", @"installid", @"installation_id",
            @"client_id", @"clientid", @"client_uuid",
            @"fingerprint", @"hardware_id", @"hardwareid",
            @"persistent_id", @"persistentid", @"persistent_device",
            @"udid", @"unique_device", @"uniqueid", @"unique_id",
            @"advertising_id", @"advertisingid", @"idfa", @"idfv",
            @"vendor_id", @"vendorid",

            // Push tokens (APNS / VoIP / PushKit)
            @"apns_token", @"apnstoken", @"apns",
            @"push_token", @"pushtoken",
            @"voip_token", @"voiptoken", @"pushkit_token", @"pushkit",

            // AppsFlyer (used by Zalo for attribution)
            @"appsflyer", @"af_uid", @"af_sdk", @"appsflyeruid", @"af_install",

            // Adjust SDK
            @"adjust_id", @"adjustid", @"adjust_uuid", @"adjustuuid",
            @"adjust_attribution", @"adid", @"adjust_install",

            // Branch SDK
            @"bnc_id", @"bnc_install", @"bnc_referrer", @"branch_id", @"branch_install",

            // Firebase / FCM / Google Mobile
            @"firebase_iid", @"firebaseinstallation", @"fcm_token", @"fcmtoken",
            @"fiam_install", @"gmp_app_id", @"gmpappid", @"google_install",

            // Crashlytics / Sentry / Bugsnag
            @"crashlytics_install", @"crashlytics_user", @"com.crashlytics",
            @"sentry_id", @"sentry_install", @"sentryinstall",
            @"bugsnag_install", @"bugsnag_id",

            // Analytics — Mixpanel / Amplitude / AppMetrica
            @"mp_distinct", @"mixpanel_id", @"mixpanelid",
            @"amplitude_device", @"amplitude_user", @"amplitudedevice",
            @"appmetrica", @"am_uuid",

            // Apple — iTunes / App Store account hashes
            @"apple_id_hash", @"itunes_account_hash", @"itunesaccount",
            @"apple_account",

            // Zalo specific
            @"kzalo", @"zl_device", @"zalo_device", @"zalodevice", @"vng_device",
            @"zalo_install",

            // Facebook
            @"fb_device", @"fbdevice", @"fbnsdevicetoken", @"fb_install",

            // TikTok / ByteDance
            @"tt_device", @"musicaly_device", @"aweme_device", @"bytedance_install",
        ];
    });
    NSString *low = s.lowercaseString;
    for (NSString *p in patterns) if ([low containsString:p]) return YES;
    return NO;
}

typedef OSStatus (*SecItemAdd_t)(CFDictionaryRef attributes, CFTypeRef *result);
typedef OSStatus (*SecItemUpdate_t)(CFDictionaryRef query, CFDictionaryRef attributes);
static SecItemAdd_t    orig_SecItemAdd    = NULL;
static SecItemUpdate_t orig_SecItemUpdate = NULL;

static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (g_ci_skipKeychainHook) return orig_SecItemAdd(attributes, result);
    if (!fakeLayer(@"keychain") || !attributes) return orig_SecItemAdd(attributes, result);
    if (!getConfigBool(@"keychainReset"))       return orig_SecItemAdd(attributes, result);
    NSDictionary *attr = (__bridge NSDictionary *)attributes;
    NSString *service = attr[(__bridge NSString *)kSecAttrService];
    NSString *account = attr[(__bridge NSString *)kSecAttrAccount];
    if (ci_isDeviceIDKey(service) || ci_isDeviceIDKey(account)) {
        // Pretend success without persisting. Caller proceeds normally.
        if (result) *result = NULL;
        return errSecSuccess;
    }
    return orig_SecItemAdd(attributes, result);
}

static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (g_ci_skipKeychainHook) return orig_SecItemUpdate(query, attributesToUpdate);
    if (!fakeLayer(@"keychain") || !query) return orig_SecItemUpdate(query, attributesToUpdate);
    if (!getConfigBool(@"keychainReset"))   return orig_SecItemUpdate(query, attributesToUpdate);
    NSDictionary *q = (__bridge NSDictionary *)query;
    NSString *service = q[(__bridge NSString *)kSecAttrService];
    NSString *account = q[(__bridge NSString *)kSecAttrAccount];
    if (ci_isDeviceIDKey(service) || ci_isDeviceIDKey(account)) {
        return errSecSuccess;
    }
    return orig_SecItemUpdate(query, attributesToUpdate);
}
// ====== ROLLBACK END: Batch E ======

#endif

// ============================================================
// !!! REVERTED: C-level hooks added in v2.4.0-bc23d78 / aa84601
// ============================================================
// getifaddrs / statfs / gettimeofday / getppid / task_for_pid /
// proc_listallpids / open / opendir / readlink. All caused
// EXC_BAD_ACCESS / SIGBUS in target apps because the variadic
// typedef (open) and direct kern API calls (task_for_pid) dont
// match the libsystem_kernel ABI — corrupted thread state when
// called by background queues. The fopen / stat / lstat / access
// / dlopen / dladdr / fork / getenv / sysctlbyname / uname hooks
// below already cover 99% of JB detection without ABI risk.

// NEW (post-revert): the four hooks below are SAFE — none variadic,
// all match libsystem_kernel ABI exactly, and they target the
// remaining detection vectors that the file-existence hooks miss:
//   1. dlsym(RTLD_DEFAULT, "MSHookFunction") — symbol-table probe
//   2. sysctl(KERN_PROC, ...) — kernel process listing
//   3. ptrace(PT_DENY_ATTACH, ...) — anti-debug probe
//   4. csops(pid, CS_OPS_STATUS, ...) — code-signing flags probe

// dlsym hook — substrate symbol mask
// ABI: void *dlsym(void *handle, const char *symbol) — 2 fixed args.
typedef void *(*dlsym_t)(void *handle, const char *symbol);
static dlsym_t orig_dlsym = NULL;
static void *hooked_dlsym(void *handle, const char *symbol) {
    if (is_critical_process()) return orig_dlsym(handle, symbol);
    if (jbHideActive() && symbol) {
        // Anyone probing for these symbols is doing JB detection. Apps
        // that legitimately use MSHook* won't run on a non-jailbroken
        // device anyway — they wouldn't reach our hook.
        static const char *kBlocked[] = {
            "MSHookFunction", "MSHookMessageEx", "MSGetImageByName",
            "_MSHookFunction", "_MSHookMessageEx", "_MSFindSymbol",
            "MSFindSymbol", "MSHookSymbol", "MSCloseImage",
            "ZzInitialize", "ZzBuildHook",
            "EKHookFunction", "EKHookMessageEx",
            "fishhook_rebind", "rebind_symbols",
            NULL
        };
        for (int i = 0; kBlocked[i]; i++) {
            if (strstr(symbol, kBlocked[i])) return NULL;
        }
    }
    return orig_dlsym(handle, symbol);
}

// sysctl hook — filter KERN_PROC list to hide tweak/JB processes
// ABI: int sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) — 6 fixed args.
typedef int (*sysctl_t)(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen);
static sysctl_t orig_sysctl = NULL;
static int hooked_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (ret != 0 || !jbHideActive() || !name || namelen < 3 || !oldp || !oldlenp) return ret;
    // KERN_PROC: name[0]=CTL_KERN(1), name[1]=KERN_PROC(14)
    if (name[0] != 1 || name[1] != 14) return ret;
    struct kinfo_proc *procs = (struct kinfo_proc *)oldp;
    size_t count = *oldlenp / sizeof(struct kinfo_proc);
    static const char *kSuspicious[] = {
        "Sileo", "Cydia", "MobileSubstrate", "substrate", "ElleKit",
        "TweakInject", "tweakloader", "ShimInjector", "SafeMode",
        "dopamine", "Choicy", "LiberTV", "PaleRain", "Taurine",
        "Frida", "frida-server", "frida-agent", "ssh", "sshd",
        NULL
    };
    size_t writeIdx = 0;
    for (size_t readIdx = 0; readIdx < count; readIdx++) {
        BOOL hide = NO;
        const char *comm = procs[readIdx].kp_proc.p_comm;
        for (int j = 0; kSuspicious[j]; j++) {
            if (strstr(comm, kSuspicious[j])) { hide = YES; break; }
        }
        if (!hide) {
            if (writeIdx != readIdx) procs[writeIdx] = procs[readIdx];
            writeIdx++;
        }
    }
    *oldlenp = writeIdx * sizeof(struct kinfo_proc);
    return 0;
}

// ptrace hook — silence PT_DENY_ATTACH so debuggers (and the runtime
// hook loader during boot) keep working. PT_DENY_ATTACH = 31.
// ABI: int ptrace(int request, pid_t pid, caddr_t addr, int data) — 4 fixed args.
typedef int (*ptrace_t)(int request, pid_t pid, caddr_t addr, int data);
static ptrace_t orig_ptrace = NULL;
static int hooked_ptrace(int request, pid_t pid, caddr_t addr, int data) {
    if (is_critical_process()) return orig_ptrace(request, pid, addr, data);
    if (jbHideActive() && request == 31 /* PT_DENY_ATTACH */) return 0;
    return orig_ptrace(request, pid, addr, data);
}

// csops hook — patch returned codesign flags so the process looks like
// a normal App Store binary (no CS_DEBUGGED, no CS_GET_TASK_ALLOW).
// ABI: int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) — 4 fixed args.
extern "C" int csops(pid_t, unsigned int, void *, size_t);
typedef int (*csops_t)(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
static csops_t orig_csops = NULL;
static int hooked_csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    int ret = orig_csops ? orig_csops(pid, ops, useraddr, usersize) : -1;
    if (!jbHideActive() || ret != 0 || !useraddr || usersize < sizeof(uint32_t)) return ret;
    // CS_OPS_STATUS = 0 → useraddr receives a uint32_t flag word.
    if (ops == 0) {
        uint32_t *flags = (uint32_t *)useraddr;
        *flags &= ~0x10000000u;  // CS_DEBUGGED   off
        *flags &= ~0x00000004u;  // CS_GET_TASK_ALLOW off
        *flags |=  0x04000000u;  // CS_PLATFORM_BINARY on
        *flags |=  0x00000001u;  // CS_VALID on
    }
    return ret;
}

// ============================================================
// PROXY ROUTING — VPN-style deep interception via connect() hook.
// ============================================================
// Why this exists: NSURLSession-level proxy injection (in Tweak.xm) only
// catches CFNetwork traffic. Apps like Zalo open raw BSD sockets for
// chat / realtime / their proprietary login protocol — those bypass any
// configuration set on session objects. To force ALL outgoing TCP through
// the user's proxy we rewrite the connect() syscall: divert to the proxy
// IP:port, perform SOCKS5 or HTTP-CONNECT handshake, hand the (now-tunneled)
// socket back to the app. App sees connect succeed and reads/writes the
// far end normally — same model that Shadowrocket / SUNNYNet use.

static BOOL ci_writeAll(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) { if (errno == EINTR) continue; return NO; }
        if (n == 0) return NO;
        p += n; len -= (size_t)n;
    }
    return YES;
}

static ssize_t ci_readAll(int fd, void *buf, size_t want) {
    char *p = (char *)buf;
    size_t got = 0;
    while (got < want) {
        ssize_t n = read(fd, p + got, want - got);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) break;
        got += (size_t)n;
    }
    return (ssize_t)got;
}

// SOCKS5 CONNECT handshake. fd is already connected to proxy. target is the
// destination the app originally asked for. user/pass may be nil.
static int ci_socks5Handshake(int fd, const struct sockaddr_in *target,
                              NSString *user, NSString *pass) {
    BOOL useAuth = user.length > 0;
    uint8_t greet[] = { 0x05, 0x01, (uint8_t)(useAuth ? 0x02 : 0x00) };
    if (!ci_writeAll(fd, greet, sizeof(greet))) return -1;

    uint8_t resp[2];
    if (ci_readAll(fd, resp, 2) != 2) return -1;
    if (resp[0] != 0x05) { errno = EPROTO; return -1; }
    if (resp[1] == 0xFF) { errno = EAUTH;  return -1; }

    if (resp[1] == 0x02) {
        const char *u = user.UTF8String ?: "";
        const char *p = pass.UTF8String ?: "";
        size_t ul = strlen(u), pl = strlen(p);
        if (ul > 255 || pl > 255) { errno = EINVAL; return -1; }
        uint8_t buf[3 + 255 + 255];
        size_t n = 0;
        buf[n++] = 0x01;
        buf[n++] = (uint8_t)ul; memcpy(&buf[n], u, ul); n += ul;
        buf[n++] = (uint8_t)pl; memcpy(&buf[n], p, pl); n += pl;
        if (!ci_writeAll(fd, buf, n)) return -1;
        if (ci_readAll(fd, resp, 2) != 2) return -1;
        if (resp[0] != 0x01 || resp[1] != 0x00) { errno = EAUTH; return -1; }
    }

    uint8_t cmd[10];
    cmd[0] = 0x05; cmd[1] = 0x01; cmd[2] = 0x00; cmd[3] = 0x01;
    memcpy(&cmd[4], &target->sin_addr.s_addr, 4);
    memcpy(&cmd[8], &target->sin_port, 2);
    if (!ci_writeAll(fd, cmd, sizeof(cmd))) return -1;

    uint8_t hdr[4];
    if (ci_readAll(fd, hdr, 4) != 4) return -1;
    if (hdr[0] != 0x05) { errno = EPROTO; return -1; }
    if (hdr[1] != 0x00) { errno = EHOSTUNREACH; return -1; }

    size_t skip = 2; // BND.PORT
    if      (hdr[3] == 0x01) skip += 4;
    else if (hdr[3] == 0x04) skip += 16;
    else if (hdr[3] == 0x03) {
        uint8_t dlen;
        if (ci_readAll(fd, &dlen, 1) != 1) return -1;
        skip += dlen;
    } else { errno = EPROTO; return -1; }
    uint8_t drain[260];
    while (skip > 0) {
        ssize_t n = ci_readAll(fd, drain, skip > sizeof(drain) ? sizeof(drain) : skip);
        if (n <= 0) return -1;
        skip -= (size_t)n;
    }
    return 0;
}

// HTTP CONNECT method handshake.
static int ci_httpConnectHandshake(int fd, const struct sockaddr_in *target,
                                   NSString *user, NSString *pass) {
    char ipStr[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &target->sin_addr.s_addr, ipStr, sizeof(ipStr));
    uint16_t port = ntohs(target->sin_port);

    NSMutableString *req = [NSMutableString stringWithFormat:
        @"CONNECT %s:%u HTTP/1.1\r\nHost: %s:%u\r\n", ipStr, port, ipStr, port];
    if (user.length) {
        NSString *creds = [NSString stringWithFormat:@"%@:%@", user, pass ?: @""];
        NSString *b64 = [[creds dataUsingEncoding:NSUTF8StringEncoding]
                         base64EncodedStringWithOptions:0];
        [req appendFormat:@"Proxy-Authorization: Basic %@\r\n", b64];
    }
    [req appendString:@"\r\n"];
    NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];
    if (!ci_writeAll(fd, reqData.bytes, reqData.length)) return -1;

    char buf[1024];
    size_t got = 0;
    while (got < sizeof(buf) - 1) {
        ssize_t n = read(fd, buf + got, sizeof(buf) - 1 - got);
        if (n < 0) { if (errno == EINTR) continue; return -1; }
        if (n == 0) break;
        got += (size_t)n;
        buf[got] = 0;
        if (strstr(buf, "\r\n\r\n")) break;
    }
    if (got < 12 || strncmp(buf, "HTTP/", 5) != 0) { errno = EPROTO; return -1; }
    char *sp = strchr(buf, ' ');
    if (!sp) { errno = EPROTO; return -1; }
    int status = atoi(sp + 1);
    if (status != 200) { errno = EHOSTUNREACH; return -1; }
    return 0;
}

// Resolve user-supplied proxy host. Fast path: literal IPv4 → inet_pton.
// Hostname → getaddrinfo (one syscall, blocking). No cache: thread-safe
// shared state across connect() callers is not worth the complexity, and
// inet_pton is essentially free for IP-form strings (the common case
// since residential-proxy providers ship raw IPv4 addresses).
static BOOL ci_resolveProxyHost(NSString *host, struct in_addr *out) {
    if (host.length == 0) return NO;
    struct in_addr tmp;
    if (inet_pton(AF_INET, host.UTF8String, &tmp) == 1) {
        *out = tmp; return YES;
    }
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.UTF8String, NULL, &hints, &res) != 0 || !res) return NO;
    struct sockaddr_in *sin = (struct sockaddr_in *)res->ai_addr;
    tmp = sin->sin_addr;
    freeaddrinfo(res);
    *out = tmp;
    return YES;
}

// Reentrancy guard — our SOCKS5/getaddrinfo path itself calls connect()
// (proxy connection) and possibly socket(); we must let those hit %orig.
static __thread int g_ci_inProxyConnect = 0;

// connect hook — block outbound connects to localhost on Frida/Cycript
// debug ports. Apps probe these ports as a presence check; returning
// ECONNREFUSED simulates "no debugger listening".
//
// Also: when the user has Proxy enabled in HIOS, divert AF_INET TCP
// connections through the proxy via SOCKS5 / HTTP-CONNECT. localhost,
// link-local, and broadcast traffic stays unproxied so DNS resolvers,
// loopback IPC, and bonjour keep working.
// ABI: int connect(int s, const struct sockaddr *name, socklen_t namelen) — 3 fixed args.
typedef int (*connect_t)(int, const struct sockaddr *, socklen_t);
static connect_t orig_connect = NULL;
static int hooked_connect(int s, const struct sockaddr *name, socklen_t namelen) {
    if (is_critical_process()) return orig_connect(s, name, namelen);
    if (jbHideActive() && name && namelen >= (socklen_t)sizeof(struct sockaddr_in)) {
        if (name->sa_family == AF_INET) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)name;
            uint16_t port = ntohs(sin->sin_port);
            // Frida default 27042/27043, Cycript 32498. Match localhost only.
            if ((port == 27042 || port == 27043 || port == 32498) &&
                (ntohl(sin->sin_addr.s_addr) >> 24) == 127) {
                errno = ECONNREFUSED;
                return -1;
            }
        }
    }

    // -------- Proxy redirection --------
    if (g_ci_inProxyConnect) return orig_connect(s, name, namelen);
    if (!name) return orig_connect(s, name, namelen);

    // IPv6 leak prevention. iOS happy-eyeballs prefers AF_INET6 when the
    // carrier offers it; SOCKS5 / HTTP-CONNECT proxies are IPv4-only in
    // practice, so an unguarded v6 connect() goes direct and exposes the
    // device's real IPv6. Server-side anti-fraud sees: HTTPS request from
    // proxy IPv4 + raw socket from device IPv6 → flag/lock. Force v6 to
    // fail with EHOSTUNREACH so the app's getaddrinfo loop falls back to
    // IPv4 (which we proxy).
    if (name->sa_family == AF_INET6) {
        @autoreleasepool {
            if (getConfigBool(@"proxyEnabled")) {
                static int s_ipv6BlockCount = 0;
                if (++s_ipv6BlockCount <= 20 || (s_ipv6BlockCount & 0xFF) == 0) {
                    NSLog(@"[ChangeInfoIos] proxy block IPv6 (#%d) — forcing v4 fallback", s_ipv6BlockCount);
                }
                errno = EHOSTUNREACH;
                return -1;
            }
        }
        return orig_connect(s, name, namelen);
    }

    if (name->sa_family != AF_INET) return orig_connect(s, name, namelen);
    if (namelen < (socklen_t)sizeof(struct sockaddr_in)) return orig_connect(s, name, namelen);

    const struct sockaddr_in *target = (const struct sockaddr_in *)name;
    uint32_t ip = ntohl(target->sin_addr.s_addr);
    uint8_t a = (ip >> 24) & 0xFF;
    uint8_t b = (ip >> 16) & 0xFF;
    if (a == 127) return orig_connect(s, name, namelen);              // 127.0.0.0/8
    if (a == 169 && b == 254) return orig_connect(s, name, namelen);  // link-local
    if (a == 0) return orig_connect(s, name, namelen);                // 0.0.0.0/8
    if (a >= 224) return orig_connect(s, name, namelen);              // multicast/reserved

    @autoreleasepool {
        if (!getConfigBool(@"proxyEnabled")) return orig_connect(s, name, namelen);
        NSString *raw = getConfigStr(@"proxyString");
        if (raw.length == 0) return orig_connect(s, name, namelen);
        NSArray *parts = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@":"];
        if (parts.count < 2) return orig_connect(s, name, namelen);
        NSString *pHost = parts[0];
        int pPort = [parts[1] intValue];
        if (pHost.length == 0 || pPort < 1 || pPort > 65535) return orig_connect(s, name, namelen);
        NSString *pUser = (parts.count >= 3 && [parts[2] length] > 0) ? parts[2] : nil;
        NSString *pPass = (parts.count >= 4 && [parts[3] length] > 0) ? parts[3] : nil;
        BOOL socks = [getConfigStr(@"proxyType") isEqualToString:@"socks5"];

        struct in_addr proxyIP;
        g_ci_inProxyConnect = 1;
        BOOL gotIP = ci_resolveProxyHost(pHost, &proxyIP);
        g_ci_inProxyConnect = 0;
        if (!gotIP) return orig_connect(s, name, namelen);

        // Don't proxy connections to the proxy itself (avoid loops if app
        // explicitly tries to talk to the proxy IP for some reason).
        if (target->sin_addr.s_addr == proxyIP.s_addr &&
            ntohs(target->sin_port) == pPort) {
            return orig_connect(s, name, namelen);
        }

        struct sockaddr_in proxySA;
        memset(&proxySA, 0, sizeof(proxySA));
        proxySA.sin_family = AF_INET;
        proxySA.sin_port = htons((uint16_t)pPort);
        proxySA.sin_addr = proxyIP;

        // Force socket into blocking mode for the handshake; restore after.
        int flags = fcntl(s, F_GETFL, 0);
        BOOL wasNonBlock = (flags >= 0) && ((flags & O_NONBLOCK) != 0);
        if (wasNonBlock) fcntl(s, F_SETFL, flags & ~O_NONBLOCK);

        // 8s recv/send timeout so a dead proxy doesn't wedge the app forever.
        struct timeval to = { .tv_sec = 8, .tv_usec = 0 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &to, sizeof(to));
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof(to));

        g_ci_inProxyConnect = 1;
        int rc = orig_connect(s, (struct sockaddr *)&proxySA, sizeof(proxySA));
        g_ci_inProxyConnect = 0;
        if (rc != 0) {
            if (wasNonBlock) fcntl(s, F_SETFL, flags);
            return rc;
        }
        int hr = socks
            ? ci_socks5Handshake(s, target, pUser, pPass)
            : ci_httpConnectHandshake(s, target, pUser, pPass);
        if (wasNonBlock) fcntl(s, F_SETFL, flags);

        // Diagnostic — only when proxy is actually applied. Tail syslog with
        // `[ChangeInfoIos] proxy` to see what target each connect() reached.
        char dstStr[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &target->sin_addr.s_addr, dstStr, sizeof(dstStr));
        NSLog(@"[ChangeInfoIos] proxy %@ → %s:%u %@",
              socks ? @"SOCKS5" : @"HTTP",
              dstStr, ntohs(target->sin_port),
              hr == 0 ? @"OK" : [NSString stringWithFormat:@"FAIL errno=%d", errno]);

        if (hr != 0) return -1;
        return 0;
    }
}

extern "C" void initCLvlHooks(void) {
    // v2.5.46: conditional install based on fake_* layer config.
    // Each MSHookFunction trampoline adds ~10-15ns overhead per call
    // (function indirection + return). For HOT-path syscalls like
    // mach_absolute_time (millions/sec) + stat (100K+/sec), even
    // empty hook bodies cost 20-30ms/sec — exceeds the 16ms frame
    // budget and visibly lags chat scroll. Skip installs that have no
    // useful work to do for the current config.
    BOOL wantJbHide    = fakeLayer(@"jbhide");      // POSIX file hooks
    BOOL wantTiming    = fakeLayer(@"timing");      // mach_absolute_time, CF*, clock_*
    BOOL wantHardware  = fakeLayer(@"hardware");    // sysctl, uname, hostuuid, getattrlist
    BOOL wantNetwork   = fakeLayer(@"network");     // getifaddrs, gethostname
    BOOL wantSysctl    = fakeLayer(@"sysctl");      // sysctl path specifically
    NSLog(@"[ChangeInfoIos] CLvl hook gates: jbhide=%d timing=%d hw=%d net=%d sysctl=%d",
          wantJbHide, wantTiming, wantHardware, wantNetwork, wantSysctl);

    // sysctlbyname — needed for hardware spoof (hw.machine, kern.osversion).
    // v2.5.49: kept install gate (wantSysctl OR wantHardware) but caller can
    // disable via _ci_disable_sysctl_byname=YES if they observe lag from
    // libsystem's internal sysctl probes (Crashlytics calls hw.cpufamily +
    // hw.ncpu on every Crashlytics report submit).
    if ((wantSysctl || wantHardware) && !getConfigBool(@"_ci_disable_sysctl_byname")) {
        void *sysctl_handle = dlopen(NULL, RTLD_NOLOAD);
        if (!sysctl_handle) sysctl_handle = RTLD_DEFAULT;
        void *sysctl_sym = dlsym(sysctl_handle, "sysctlbyname");
        if (sysctl_sym && !orig_sysctlbyname) {
            MSHookFunction(sysctl_sym, (void *)hooked_sysctlbyname, (void **)&orig_sysctlbyname);
            NSLog(@"[ChangeInfoIos] sysctlbyname hooked");
        }
    }

    // v2.5.49 uname GATED on explicit opt-in. uname(2) hits libc on every
    // crash report dispatch + system version log; UIDevice.systemName / model
    // ObjC hooks already cover the high-level API surface that Zalo / Firebase
    // analytics actually reads.
    if (getConfigBool(@"_ci_enable_uname_hook")) {
        void *uname_sym = dlsym(RTLD_DEFAULT, "uname");
        if (uname_sym && !orig_uname) {
            MSHookFunction(uname_sym, (void *)hooked_uname, (void **)&orig_uname);
            NSLog(@"[ChangeInfoIos] uname hooked");
        }
    }

    // v2.5.49 stat/lstat KEPT for JB hide; access/fopen MOVED to opt-in.
    // NSFileManager.fileExistsAtPath in Foundation calls stat under the
    // hood — covering it lets us deny JB paths to apps using the modern
    // ObjC API without hooking the lower-level functions. access/fopen
    // are hit by file-cache image decode (Zalo image preview, sticker
    // load) → ~50K calls/sec. Re-enable with _ci_enable_access_fopen=YES
    // if a future fingerprint SDK probes paths via access(2) directly.
    if (wantJbHide) {
        void *stat_sym = dlsym(RTLD_DEFAULT, "stat");
        if (stat_sym && !orig_stat) {
            MSHookFunction(stat_sym, (void *)hooked_stat, (void **)&orig_stat);
            NSLog(@"[ChangeInfoIos] stat hooked");
        }
        void *lstat_sym = dlsym(RTLD_DEFAULT, "lstat");
        if (lstat_sym && !orig_lstat) {
            MSHookFunction(lstat_sym, (void *)hooked_lstat, (void **)&orig_lstat);
            NSLog(@"[ChangeInfoIos] lstat hooked");
        }
    }
    if (getConfigBool(@"_ci_enable_access_fopen")) {
        void *access_sym = dlsym(RTLD_DEFAULT, "access");
        if (access_sym && !orig_access) {
            MSHookFunction(access_sym, (void *)hooked_access, (void **)&orig_access);
            NSLog(@"[ChangeInfoIos] access hooked");
        }
        void *fopen_sym = dlsym(RTLD_DEFAULT, "fopen");
        if (fopen_sym && !orig_fopen) {
            MSHookFunction(fopen_sym, (void *)hooked_fopen, (void **)&orig_fopen);
            NSLog(@"[ChangeInfoIos] fopen hooked");
        }
    }

    // open()/openat() hooks DISABLED — caused AIDA64 / other apps to crash
    // on launch even with strict canonical-path filter. The crash root cause
    // is not yet pinned down (possibly a re-entrance from Foundation's own
    // writeToFile during fake-plist generation in the open() hot path, but
    // unconfirmed). Leaving the hook definitions compiled-in for future
    // re-enablement once the crash is reproduced + traced.
    //
    // Coverage loss: apps reading SystemVersion.plist via NSData /
    // NSPropertyListSerialization / CFPropertyList still see the real
    // device's ProductBuildVersion. The MGCopyAnswer hook keymap catches
    // the API path most anti-fraud SDKs use (BuildVersion, OSBuildVersion,
    // ProductBuildVersion via MGCopyAnswer + MGGetStringAnswer), but not
    // direct file reads. AIDA64 specifically uses direct file read.

    // v2.5.49 ALL gated behind explicit opt-in. dlopen / getifaddrs /
    // statfs / getattrlist / gethostuuid / objc_getClassList were
    // installed unconditionally when their layer toggle was on — but
    // Zalo's reg flow never reads any of them directly. They are
    // anti-fingerprint scaffolding for paranoid SDKs (AIDA64, advanced
    // banking probes) that Zalo doesn't use. Trampoline cost on Crashlytics
    // dlopen + UIKit's internal interface enumerations adds up.
    if (getConfigBool(@"_ci_enable_dlopen_hook")) {
        void *dlopen_sym = dlsym(RTLD_DEFAULT, "dlopen");
        if (dlopen_sym && !orig_dlopen) {
            MSHookFunction(dlopen_sym, (void *)hooked_dlopen, (void **)&orig_dlopen);
            NSLog(@"[ChangeInfoIos] dlopen hooked");
        }
    }
    if (getConfigBool(@"_ci_enable_net_hook")) {
        void *getifaddrs_sym = dlsym(RTLD_DEFAULT, "getifaddrs");
        if (getifaddrs_sym && !orig_getifaddrs) {
            MSHookFunction(getifaddrs_sym, (void *)hooked_getifaddrs, (void **)&orig_getifaddrs);
            NSLog(@"[ChangeInfoIos] getifaddrs hooked");
        }
    }
    if (getConfigBool(@"_ci_enable_hw_hook")) {
        void *statfs_sym = dlsym(RTLD_DEFAULT, "statfs");
        if (statfs_sym && !orig_statfs) {
            MSHookFunction(statfs_sym, (void *)hooked_statfs, (void **)&orig_statfs);
            NSLog(@"[ChangeInfoIos] statfs hooked");
        }
        void *gal_sym = dlsym(RTLD_DEFAULT, "getattrlist");
        if (gal_sym && !orig_getattrlist) {
            MSHookFunction(gal_sym, (void *)hooked_getattrlist, (void **)&orig_getattrlist);
            NSLog(@"[ChangeInfoIos] getattrlist hooked");
        }
        void *guuid_sym = dlsym(RTLD_DEFAULT, "gethostuuid");
        if (guuid_sym && !orig_gethostuuid) {
            MSHookFunction(guuid_sym, (void *)hooked_gethostuuid, (void **)&orig_gethostuuid);
            NSLog(@"[ChangeInfoIos] gethostuuid hooked");
        }
    }
    if (getConfigBool(@"_ci_enable_objc_class_hide")) {
        void *gcl_sym = dlsym(RTLD_DEFAULT, "objc_getClassList");
        if (gcl_sym && !orig_objc_getClassList) {
            MSHookFunction(gcl_sym, (void *)hooked_objc_getClassList, (void **)&orig_objc_getClassList);
            NSLog(@"[ChangeInfoIos] objc_getClassList hooked");
        }
    }

    // v2.5.48 STRICTER GATE — timing hooks now require an EXPLICIT offset
    // config value, ignoring the wantTiming UI toggle. The UI fake_timing
    // checkbox previously installed gettimeofday/clock_gettime even with
    // zero offset, producing pure-passthrough trampolines that still cost
    // 10-15ns per call on the hottest VDSO function in iOS. Zalo's chat
    // scroll hits gettimeofday on every message-timestamp NSDateFormatter
    // pass + every CADisplayLink frame → measured 30+ ms/sec overhead even
    // with no behavioral change. Now: no offset = no install = no overhead.
    BOOL hasClockOffset  = (getConfig(@"_ci_clock_offset_secs") != nil);
    BOOL hasMachOffset   = (getConfig(@"zalo_timingOffset") != nil);
    if (hasClockOffset) {
        void *gtod_sym = dlsym(RTLD_DEFAULT, "gettimeofday");
        if (gtod_sym && !orig_gettimeofday) {
            MSHookFunction(gtod_sym, (void *)hooked_gettimeofday, (void **)&orig_gettimeofday);
            NSLog(@"[ChangeInfoIos] gettimeofday hooked");
        }
        void *cgt_sym = dlsym(RTLD_DEFAULT, "clock_gettime");
        if (cgt_sym && !orig_clock_gettime) {
            MSHookFunction(cgt_sym, (void *)hooked_clock_gettime, (void **)&orig_clock_gettime);
            NSLog(@"[ChangeInfoIos] clock_gettime hooked");
        }
    }
    if (hasMachOffset) {
        void *mat_sym = dlsym(RTLD_DEFAULT, "mach_absolute_time");
        if (mat_sym && !orig_mach_absolute_time) {
            MSHookFunction(mat_sym, (void *)hooked_mach_absolute_time, (void **)&orig_mach_absolute_time);
            NSLog(@"[ChangeInfoIos] mach_absolute_time hooked");
        }
        void *cat_sym = dlsym(RTLD_DEFAULT, "CFAbsoluteTimeGetCurrent");
        if (cat_sym && !orig_CFAbsoluteTimeGetCurrent) {
            MSHookFunction(cat_sym, (void *)hooked_CFAbsoluteTimeGetCurrent, (void **)&orig_CFAbsoluteTimeGetCurrent);
            NSLog(@"[ChangeInfoIos] CFAbsoluteTimeGetCurrent hooked");
        }
    }

    // v2.5.49 gethostname GATED on explicit opt-in. NSProcessInfo.hostName
    // ObjC hook already covers the high-level path; the C function is
    // rarely needed and adds a trampoline for nothing in Zalo.
    if (getConfigBool(@"_ci_enable_gethostname_hook")) {
        void *gethostname_sym = dlsym(RTLD_DEFAULT, "gethostname");
        if (gethostname_sym && !orig_gethostname) {
            MSHookFunction(gethostname_sym, (void *)hooked_gethostname, (void **)&orig_gethostname);
            NSLog(@"[ChangeInfoIos] gethostname hooked");
        }
    }

    // v2.5.48 REMOVED installs: dladdr / _dyld_image_count /
    // _dyld_get_image_name / _dyld_get_shared_cache_uuid / fork.
    // These were JB-hide paranoia hooks intended for advanced fingerprint
    // tools (AIDA64-style image walks, fork-based debugger probes). Zalo
    // does not call any of them during reg or chat. Install was costing a
    // trampoline per call on dladdr (used by every Crashlytics symbol
    // resolution → ~5K calls/sec at launch). The hooked_* implementations
    // remain compiled (unused) so re-enable is a one-line MSHookFunction
    // edit if a future target ever needs them. Opt-in via per-symbol
    // _ci_enable_<name> gates is a follow-up if any user demands it.

    // v2.5.49 getenv GATED on explicit opt-in. Was installed unconditionally,
    // adding a trampoline on every libc / Foundation env var probe during app
    // startup (~3K calls at Zalo launch). Spoof value covered by zero apps
    // in user's target set during reg flow.
    if (getConfigBool(@"_ci_enable_getenv_hook")) {
        void *getenv_sym = dlsym(RTLD_DEFAULT, "getenv");
        if (getenv_sym && !orig_getenv) {
            MSHookFunction(getenv_sym, (void *)hooked_getenv, (void **)&orig_getenv);
            NSLog(@"[ChangeInfoIos] getenv hooked");
        }
    }

    // SecItemCopyMatching
#if __has_include(<Security/Security.h>)
    void *sec_sym = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    if (sec_sym && !orig_SecItemCopyMatching) {
        MSHookFunction(sec_sym, (void *)hooked_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching);
        NSLog(@"[ChangeInfoIos] SecItemCopyMatching hooked");
    }

    // ====== ROLLBACK START: Batch E install ======
    // SecItemAdd / SecItemUpdate write blockers — gated OFF by default.
    // Enable per device via:  node ssh-set-key.js _ci_enable_secwrite true
    if (getConfigBool(@"_ci_enable_secwrite")) {
        void *secAdd_sym = dlsym(RTLD_DEFAULT, "SecItemAdd");
        if (secAdd_sym && !orig_SecItemAdd) {
            MSHookFunction(secAdd_sym, (void *)hooked_SecItemAdd, (void **)&orig_SecItemAdd);
            NSLog(@"[ChangeInfoIos] SecItemAdd hooked");
        }
        void *secUpd_sym = dlsym(RTLD_DEFAULT, "SecItemUpdate");
        if (secUpd_sym && !orig_SecItemUpdate) {
            MSHookFunction(secUpd_sym, (void *)hooked_SecItemUpdate, (void **)&orig_SecItemUpdate);
            NSLog(@"[ChangeInfoIos] SecItemUpdate hooked");
        }
    }
    // ====== ROLLBACK END: Batch E install ======
#endif

    // ============================================================
    // The 5 hooks below (sysctl, ptrace, csops, connect, dlsym) are
    // OFF BY DEFAULT — first deployment crashed AIDA + Zalo at launch.
    // Each install is gated behind its own _ci_enable_<name> config
    // flag so we can re-enable them one at a time via SSH and bisect
    // the bad ABI without rebuilding the dylib.
    //
    // To turn one on for testing:
    //   node ssh-set-key.js _ci_enable_sysctl true
    // Then respring + open target app. If app opens → that hook is OK.
    // If app crashes → that hook has bad ABI on this device's libsystem.
    // ============================================================
    if (getConfigBool(@"_ci_enable_sysctl")) {
        void *sysctl2_sym = dlsym(RTLD_DEFAULT, "sysctl");
        if (sysctl2_sym && !orig_sysctl) {
            MSHookFunction(sysctl2_sym, (void *)hooked_sysctl, (void **)&orig_sysctl);
            NSLog(@"[ChangeInfoIos] sysctl hooked");
        }
    }
    if (getConfigBool(@"_ci_enable_ptrace")) {
        void *ptrace_sym = dlsym(RTLD_DEFAULT, "ptrace");
        if (ptrace_sym && !orig_ptrace) {
            MSHookFunction(ptrace_sym, (void *)hooked_ptrace, (void **)&orig_ptrace);
            NSLog(@"[ChangeInfoIos] ptrace hooked");
        }
    }
    if (getConfigBool(@"_ci_enable_csops")) {
        void *csops_sym = dlsym(RTLD_DEFAULT, "csops");
        if (csops_sym && !orig_csops) {
            MSHookFunction(csops_sym, (void *)hooked_csops, (void **)&orig_csops);
            NSLog(@"[ChangeInfoIos] csops hooked");
        }
    }
    // connect() is hooked when EITHER the legacy Frida-block flag is on
    // OR the user has Proxy enabled in HIOS — proxy routing requires the
    // hook regardless of the jbHide debug-port block. Without this, raw
    // sockets in apps like Zalo skip our proxy entirely.
    if (getConfigBool(@"_ci_enable_connect") || getConfigBool(@"proxyEnabled")) {
        void *connect_sym = dlsym(RTLD_DEFAULT, "connect");
        if (connect_sym && !orig_connect) {
            MSHookFunction(connect_sym, (void *)hooked_connect, (void **)&orig_connect);
            NSLog(@"[ChangeInfoIos] connect hooked (proxy=%@ frida-block=%@)",
                  getConfigBool(@"proxyEnabled") ? @"on" : @"off",
                  getConfigBool(@"_ci_enable_connect") ? @"on" : @"off");
        }
    }
    if (getConfigBool(@"_ci_enable_dlsym")) {
        void *dlsym_sym = dlsym(RTLD_DEFAULT, "dlsym");
        if (dlsym_sym && !orig_dlsym) {
            MSHookFunction(dlsym_sym, (void *)hooked_dlsym, (void **)&orig_dlsym);
            NSLog(@"[ChangeInfoIos] dlsym hooked");
        }
    }

    // v2.4.63 REMOVED CFHTTPMessageSetHeaderFieldValue install — this hook
    // fired on every header set during every HTTP request in target apps,
    // causing visible lag in Zalo (chat / scroll / send). The user's
    // philosophy: spoof at device/OS read layer, do NOT touch app's
    // outgoing requests. Zalo's own UA "Zalo/X.Y.Z" is what it sends,
    // not iOS Safari UA — server-side device check uses the device info
    // Zalo collects via UIDevice/MG/sysctl (which ARE spoofed) not the
    // HTTP UA header. Network-layer interference was unnecessary.

    NSLog(@"[ChangeInfoIos] All C-level hooks initialized");
}
