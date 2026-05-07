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
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#include <sys/time.h>
#include <spawn.h>
#include <fcntl.h>
#include <unistd.h>
#include <dirent.h>
#include <stdarg.h>
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

    return ret;
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
// stat hook
// ============================================================
static int (*orig_stat)(const char *path, struct stat *buf) = NULL;

static int hooked_stat(const char *path, struct stat *buf) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
                           @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/.installed_dopamine",
                           @"/.installed_palera1n", @"/var/binpack"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return -1; }
        }
    }
    return orig_stat(path, buf);
}

// ============================================================
// lstat hook
// ============================================================
static int (*orig_lstat)(const char *path, struct stat *buf) = NULL;

static int hooked_lstat(const char *path, struct stat *buf) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
                           @"/usr/sbin/sshd", @"/.installed_dopamine", @"/.installed_palera1n"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return -1; }
        }
    }
    return orig_lstat(path, buf);
}

// ============================================================
// access hook
// ============================================================
static int (*orig_access)(const char *path, int mode) = NULL;

static int hooked_access(const char *path, int mode) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/usr/sbin/sshd",
                           @"/.installed_dopamine", @"/.installed_palera1n"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return -1; }
        }
    }
    return orig_access(path, mode);
}

// ============================================================
// fopen hook
// ============================================================
static FILE *(*orig_fopen)(const char *path, const char *mode) = NULL;

static FILE *hooked_fopen(const char *path, const char *mode) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/usr/sbin/sshd",
                           @"/.installed_dopamine", @"/.installed_palera1n",
                           @"/etc/apt/sources.list", @"/var/lib/dpkg"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return NULL; }
        }
    }
    return orig_fopen(path, mode);
}

// ============================================================
// dlopen hook
// ============================================================
static void *(*orig_dlopen)(const char *path, int mode) = NULL;

static void *hooked_dlopen(const char *path, int mode) {
    if (is_critical_process()) return orig_dlopen(path, mode);
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *blockedLibs = @[@"SubstrateLoader", @"SubstrateInserter", @"CydiaSubstrate",
                                @"TweakInject", @"substitute", @"ElleKit", @"libhooker",
                                @"pspawn_payload", @"SubstrateBootstrap"];
        for (NSString *lib in blockedLibs) {
            if ([pathStr containsString:lib]) {
                return NULL;
            }
        }
    }
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
// mach_absolute_time hook
// ============================================================
static uint64_t (*orig_mach_absolute_time)(void) = NULL;

static uint64_t hooked_mach_absolute_time(void) {
    uint64_t real = orig_mach_absolute_time();
    if (!fakeLayer(@"timing")) return real;
    id offset = getConfig(@"zalo_timingOffset");
    if (offset) {
        int64_t off = [offset longLongValue];
        return (uint64_t)((int64_t)real + off);
    }
    return real;
}

// ============================================================
// CFAbsoluteTimeGetCurrent hook
// ============================================================
static CFAbsoluteTime (*orig_CFAbsoluteTimeGetCurrent)(void) = NULL;

static CFAbsoluteTime hooked_CFAbsoluteTimeGetCurrent(void) {
    CFAbsoluteTime real = orig_CFAbsoluteTimeGetCurrent();
    if (!fakeLayer(@"timing")) return real;
    id offset = getConfig(@"zalo_timingOffset");
    if (offset) {
        return real + ([offset doubleValue] / 1000000000.0);
    }
    return real;
}

// ============================================================
// dladdr hook
// ============================================================
static int (*orig_dladdr)(const void *addr, Dl_info *info) = NULL;

static int hooked_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr(addr, info);
    if (!jbHideActive() || ret == 0 || !info || !info->dli_fname) return ret;

    NSString *path = [NSString stringWithUTF8String:info->dli_fname];
    if ([path containsString:@"ChangeInfoIos"] ||
        [path containsString:@"Substrate"] ||
        [path containsString:@"TweakInject"] ||
        [path containsString:@"ElleKit"] ||
        [path containsString:@"libhooker"] ||
        [path containsString:@"substitute"]) {
        info->dli_fname = "/System/Library/Frameworks/UIKit.framework/UIKit";
        info->dli_sname = "UIApplicationMain";
        info->dli_saddr = NULL;
    }
    return ret;
}

// ============================================================
// _dyld_get_image_name hook
// ============================================================
static const char *(*orig__dyld_get_image_name)(uint32_t image_index) = NULL;

static const char *hooked__dyld_get_image_name(uint32_t image_index) {
    const char *name = orig__dyld_get_image_name(image_index);
    if (!jbHideActive() || !name) return name;

    NSString *nameStr = [NSString stringWithUTF8String:name];
    if ([nameStr containsString:@"ChangeInfoIos"] ||
        [nameStr containsString:@"Substrate"] ||
        [nameStr containsString:@"TweakInject"] ||
        [nameStr containsString:@"ElleKit"] ||
        [nameStr containsString:@"libhooker"] ||
        [nameStr containsString:@"substitute"]) {
        return "/System/Library/Frameworks/UIKit.framework/UIKit";
    }
    return name;
}

// ============================================================
// _dyld_image_count hook
// ============================================================
static uint32_t (*orig__dyld_image_count)(void) = NULL;

static uint32_t hooked__dyld_image_count(void) {
    uint32_t count = orig__dyld_image_count();
    if (!jbHideActive()) return count;

    uint32_t hidden = 0;
    for (uint32_t i = 0; i < count; i++) {
        const char *name = orig__dyld_get_image_name(i);
        if (name) {
            NSString *nameStr = [NSString stringWithUTF8String:name];
            if ([nameStr containsString:@"Substrate"] ||
                [nameStr containsString:@"TweakInject"] ||
                [nameStr containsString:@"ElleKit"] ||
                [nameStr containsString:@"libhooker"] ||
                [nameStr containsString:@"substitute"]) {
                hidden++;
            }
        }
    }
    return count - hidden;
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
            NSString *account = queryDict[(__bridge NSString *)kSecAttrAccount];
            NSArray *deviceKeys = @[@"device_id", @"device_uuid", @"install_id",
                                    @"client_id", @"advertising_id", @"fingerprint",
                                    @"TWClientID", @"TWDeviceID", @"kTWDevice",
                                    @"persistent_id", @"hardware_id"];
            for (NSString *dk in deviceKeys) {
                if ([account.lowercaseString containsString:dk.lowercaseString] ||
                    [service.lowercaseString containsString:dk.lowercaseString]) {
                    if (result) *result = NULL;
                    return errSecItemNotFound;
                }
            }
        }
    }

    return orig_SecItemCopyMatching(query, result);
}
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

// connect hook — block outbound connects to localhost on Frida/Cycript
// debug ports. Apps probe these ports as a presence check; returning
// ECONNREFUSED simulates "no debugger listening".
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
    return orig_connect(s, name, namelen);
}

extern "C" void initCLvlHooks(void) {
    // sysctlbyname
    void *sysctl_handle = dlopen(NULL, RTLD_NOLOAD);
    if (!sysctl_handle) sysctl_handle = RTLD_DEFAULT;
    void *sysctl_sym = dlsym(sysctl_handle, "sysctlbyname");
    if (sysctl_sym && !orig_sysctlbyname) {
        MSHookFunction(sysctl_sym, (void *)hooked_sysctlbyname, (void **)&orig_sysctlbyname);
        NSLog(@"[ChangeInfoIos] sysctlbyname hooked");
    }

    // uname
    void *uname_sym = dlsym(RTLD_DEFAULT, "uname");
    if (uname_sym && !orig_uname) {
        MSHookFunction(uname_sym, (void *)hooked_uname, (void **)&orig_uname);
        NSLog(@"[ChangeInfoIos] uname hooked");
    }

    // stat
    void *stat_sym = dlsym(RTLD_DEFAULT, "stat");
    if (stat_sym && !orig_stat) {
        MSHookFunction(stat_sym, (void *)hooked_stat, (void **)&orig_stat);
        NSLog(@"[ChangeInfoIos] stat hooked");
    }

    // lstat
    void *lstat_sym = dlsym(RTLD_DEFAULT, "lstat");
    if (lstat_sym && !orig_lstat) {
        MSHookFunction(lstat_sym, (void *)hooked_lstat, (void **)&orig_lstat);
        NSLog(@"[ChangeInfoIos] lstat hooked");
    }

    // access
    void *access_sym = dlsym(RTLD_DEFAULT, "access");
    if (access_sym && !orig_access) {
        MSHookFunction(access_sym, (void *)hooked_access, (void **)&orig_access);
        NSLog(@"[ChangeInfoIos] access hooked");
    }

    // fopen
    void *fopen_sym = dlsym(RTLD_DEFAULT, "fopen");
    if (fopen_sym && !orig_fopen) {
        MSHookFunction(fopen_sym, (void *)hooked_fopen, (void **)&orig_fopen);
        NSLog(@"[ChangeInfoIos] fopen hooked");
    }

    // dlopen
    void *dlopen_sym = dlsym(RTLD_DEFAULT, "dlopen");
    if (dlopen_sym && !orig_dlopen) {
        MSHookFunction(dlopen_sym, (void *)hooked_dlopen, (void **)&orig_dlopen);
        NSLog(@"[ChangeInfoIos] dlopen hooked");
    }

    // gethostname
    void *gethostname_sym = dlsym(RTLD_DEFAULT, "gethostname");
    if (gethostname_sym && !orig_gethostname) {
        MSHookFunction(gethostname_sym, (void *)hooked_gethostname, (void **)&orig_gethostname);
        NSLog(@"[ChangeInfoIos] gethostname hooked");
    }

    // mach_absolute_time
    void *mat_sym = dlsym(RTLD_DEFAULT, "mach_absolute_time");
    if (mat_sym && !orig_mach_absolute_time) {
        MSHookFunction(mat_sym, (void *)hooked_mach_absolute_time, (void **)&orig_mach_absolute_time);
        NSLog(@"[ChangeInfoIos] mach_absolute_time hooked");
    }

    // CFAbsoluteTimeGetCurrent
    void *cat_sym = dlsym(RTLD_DEFAULT, "CFAbsoluteTimeGetCurrent");
    if (cat_sym && !orig_CFAbsoluteTimeGetCurrent) {
        MSHookFunction(cat_sym, (void *)hooked_CFAbsoluteTimeGetCurrent, (void **)&orig_CFAbsoluteTimeGetCurrent);
        NSLog(@"[ChangeInfoIos] CFAbsoluteTimeGetCurrent hooked");
    }

    // dladdr
    void *dladdr_sym = dlsym(RTLD_DEFAULT, "dladdr");
    if (dladdr_sym && !orig_dladdr) {
        MSHookFunction(dladdr_sym, (void *)hooked_dladdr, (void **)&orig_dladdr);
        NSLog(@"[ChangeInfoIos] dladdr hooked");
    }

    // _dyld_image_count
    void *dyld_count_sym = dlsym(RTLD_DEFAULT, "_dyld_image_count");
    if (dyld_count_sym && !orig__dyld_image_count) {
        MSHookFunction(dyld_count_sym, (void *)hooked__dyld_image_count, (void **)&orig__dyld_image_count);
        NSLog(@"[ChangeInfoIos] _dyld_image_count hooked");
    }

    // _dyld_get_image_name
    void *dyld_name_sym = dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
    if (dyld_name_sym && !orig__dyld_get_image_name) {
        MSHookFunction(dyld_name_sym, (void *)hooked__dyld_get_image_name, (void **)&orig__dyld_get_image_name);
        NSLog(@"[ChangeInfoIos] _dyld_get_image_name hooked");
    }

    // fork
    void *fork_sym = dlsym(RTLD_DEFAULT, "fork");
    if (fork_sym && !orig_fork) {
        MSHookFunction(fork_sym, (void *)hooked_fork, (void **)&orig_fork);
        NSLog(@"[ChangeInfoIos] fork hooked");
    }

    // getenv
    void *getenv_sym = dlsym(RTLD_DEFAULT, "getenv");
    if (getenv_sym && !orig_getenv) {
        MSHookFunction(getenv_sym, (void *)hooked_getenv, (void **)&orig_getenv);
        NSLog(@"[ChangeInfoIos] getenv hooked");
    }

    // SecItemCopyMatching
#if __has_include(<Security/Security.h>)
    void *sec_sym = dlsym(RTLD_DEFAULT, "SecItemCopyMatching");
    if (sec_sym && !orig_SecItemCopyMatching) {
        MSHookFunction(sec_sym, (void *)hooked_SecItemCopyMatching, (void **)&orig_SecItemCopyMatching);
        NSLog(@"[ChangeInfoIos] SecItemCopyMatching hooked");
    }
#endif

    // sysctl (KERN_PROC filter) — hides tweak/JB processes from process listing.
    // dlsym name "sysctl" must come BEFORE we hook dlsym itself; otherwise we'd
    // need RTLD_NEXT semantics which substrate doesn't expose.
    void *sysctl2_sym = dlsym(RTLD_DEFAULT, "sysctl");
    if (sysctl2_sym && !orig_sysctl) {
        MSHookFunction(sysctl2_sym, (void *)hooked_sysctl, (void **)&orig_sysctl);
        NSLog(@"[ChangeInfoIos] sysctl hooked");
    }

    // ptrace — neutralizes PT_DENY_ATTACH (anti-debug); leaves all other
    // ptrace operations untouched so legitimate use (Xcode debugger, crashed
    // processes) still works.
    void *ptrace_sym = dlsym(RTLD_DEFAULT, "ptrace");
    if (ptrace_sym && !orig_ptrace) {
        MSHookFunction(ptrace_sym, (void *)hooked_ptrace, (void **)&orig_ptrace);
        NSLog(@"[ChangeInfoIos] ptrace hooked");
    }

    // csops — code-signing status probe. Apps inspect CS_DEBUGGED /
    // CS_GET_TASK_ALLOW to detect debugger / non-platform-binary state.
    void *csops_sym = dlsym(RTLD_DEFAULT, "csops");
    if (csops_sym && !orig_csops) {
        MSHookFunction(csops_sym, (void *)hooked_csops, (void **)&orig_csops);
        NSLog(@"[ChangeInfoIos] csops hooked");
    }

    // connect — block Frida / Cycript loopback probes (port 27042/27043/32498).
    void *connect_sym = dlsym(RTLD_DEFAULT, "connect");
    if (connect_sym && !orig_connect) {
        MSHookFunction(connect_sym, (void *)hooked_connect, (void **)&orig_connect);
        NSLog(@"[ChangeInfoIos] connect hooked");
    }

    // dlsym hook MUST be installed LAST. Hooking it earlier would route our
    // own subsequent dlsym lookups through the hook, possibly returning NULL
    // for legit substrate symbols and breaking the rest of init.
    void *dlsym_sym = dlsym(RTLD_DEFAULT, "dlsym");
    if (dlsym_sym && !orig_dlsym) {
        MSHookFunction(dlsym_sym, (void *)hooked_dlsym, (void **)&orig_dlsym);
        NSLog(@"[ChangeInfoIos] dlsym hooked");
    }

    NSLog(@"[ChangeInfoIos] All C-level hooks initialized");
}
