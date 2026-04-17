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
#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <sys/time.h>
#include <spawn.h>
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
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret != 0 || !name || !oldp) return ret;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded) return ret;

    NSString *nameStr = [NSString stringWithUTF8String:name];

    // Map config keys
    NSDictionary *sysctlMap = @{
        @"hw.machine":       @"hw_machine",
        @"hw.model":         @"hw_model",
        @"kern.hostname":    @"kern_hostname",
        @"kern.osversion":   @"kern_osversion",
        @"kern.osrelease":   @"kern_osrelease",
    };

    NSString *configKey = sysctlMap[nameStr];
    if (configKey) {
        BOOL useStr = [nameStr isEqualToString:@"kern.osversion"] ? fakeLayer(@"sysosversion") : fakeLayer(@"sysctl");
        if (useStr) {
            NSString *val = getConfigStr(configKey);
            if (val && oldlenp) {
                const char *cval = [val UTF8String];
                size_t len = strlen(cval) + 1;
                if (*oldlenp >= len) {
                    memcpy(oldp, cval, len);
                    *oldlenp = len;
                    return 0;
                }
            }
        }
    }

    if (!fakeLayer(@"sysctl")) return ret;

    if (strcmp(name, "hw.memsize") == 0) {
        id val = getConfig(@"hw_memsize");
        if (val && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t memsize = [val unsignedLongLongValue];
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
            uint64_t freq = [val unsignedLongLongValue];
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
// Init all C-level hooks
// ============================================================
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

    NSLog(@"[ChangeInfoIos] All C-level hooks initialized");
}
