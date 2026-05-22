// ChangeInfoIosSafari — minimal sidecar dylib for Safari UA spoof.
//
// Designed to be SAFE for Safari's specialized process model. Contains:
//   - NO Logos %hook directives (those bind at load time and can crash
//     Safari's WebContent / WebKit XPC services)
//   - NO Obj-C runtime swizzling
//   - NO fishhook GOT rebinding
// Only:
//   - One MSHookFunction on sysctlbyname()
//   - One config-file read (PRIMARY: /var/jb/etc/changeinfoios/config.plist)
//
// Why this works for Safari UA: WebCore::systemMarketingVersionForUserAgent
// String() reads kern.osproductversion via sysctlbyname(). If we lie about
// that value at the system-call layer, WebCore composes the User-Agent
// string with the spoofed iOS version automatically. No need to touch
// WKWebView, customUserAgent, NSURLRequest, or any HTTP-layer plumbing.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

// MSHookFunction prototype (from libsubstrate)
#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

// v2.5.4 diagnostic helpers — write marker files to confirm load + hook fire.
static void ci_safariMark(const char *tag) {
    @autoreleasepool {
        NSString *dir = NSTemporaryDirectory();
        if (!dir.length) return;
        NSString *path = [dir stringByAppendingFormat:@"/ci_safari_%s.txt", tag];
        NSString *stamp = [NSString stringWithFormat:@"%@ bid=%@\n",
                            [NSDate date],
                            [[NSBundle mainBundle] bundleIdentifier] ?: @"?"];
        FILE *f = fopen([path UTF8String], "a");
        if (f) { fputs([stamp UTF8String], f); fclose(f); }
    }
}

static NSDictionary *g_safariConfig = nil;
static dispatch_once_t g_configOnce;

static NSString *ci_safariConfigString(NSString *key) {
    dispatch_once(&g_configOnce, ^{
        @autoreleasepool {
            // Read tweak's shared config plist. Path is world-readable
            // (chmod 0666 from postinst). NSDictionary handles both XML
            // and binary plist formats automatically.
            g_safariConfig = [NSDictionary dictionaryWithContentsOfFile:
                              @"/var/jb/etc/changeinfoios/config.plist"];
        }
    });
    id val = g_safariConfig ? g_safariConfig[key] : nil;
    if ([val isKindOfClass:[NSString class]]) return val;
    if (val) return [NSString stringWithFormat:@"%@", val];
    return nil;
}

// v2.5.5: MGCopyAnswer hook. WebKit on iOS calls MGCopyAnswer("ProductVersion")
// to get iOS marketing version for the UA string — NOT sysctlbyname (despite
// what WebKit source code shows; iOS-specific override uses MG).
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef property);
static MGCopyAnswer_t orig_MGCopyAnswer = NULL;

static CFTypeRef hooked_MGCopyAnswer(CFStringRef property) {
    if (!property) return orig_MGCopyAnswer(property);
    NSString *key = (__bridge NSString *)property;
    // Only spoof iOS-version-related keys; everything else passthrough.
    if ([key isEqualToString:@"ProductVersion"] ||
        [key isEqualToString:@"BuildVersion"] ||
        [key isEqualToString:@"ProductBuildVersion"] ||
        [key isEqualToString:@"SoftwareBundleVersion"]) {
        NSString *fake = ci_safariConfigString(@"systemVersion");
        if (fake.length) {
            ci_safariMark("mg_productversion_hit");
            return (__bridge_retained CFTypeRef)fake;
        }
    }
    return orig_MGCopyAnswer(property);
}

// v2.5.6: UIDevice.systemVersion swizzle. WebKit on iOS calls
// `[[UIDevice currentDevice] systemVersion]` to build UA's "iPhone OS X_Y_Z"
// substring. UIDevice underneath reads via CFCopyServerVersionDictionary
// (private CF). Easier to swizzle UIDevice at Obj-C runtime than to hook
// the private CF function.
typedef NSString *(*ci_orig_systemVersion_t)(id, SEL);
static ci_orig_systemVersion_t orig_systemVersion = NULL;

static NSString *hooked_systemVersion(id self, SEL _cmd) {
    ci_safariMark("uidevice_sysver_hit");
    NSString *fake = ci_safariConfigString(@"systemVersion");
    if (fake.length) {
        ci_safariMark("uidevice_sysver_fake");
        return fake;
    }
    return orig_systemVersion ? orig_systemVersion(self, _cmd) : @"17.0";
}

static void ci_swizzleSystemVersion(void) {
    Class cls = objc_getClass("UIDevice");
    if (!cls) { ci_safariMark("uidevice_class_missing"); return; }
    Method m = class_getInstanceMethod(cls, @selector(systemVersion));
    if (!m) { ci_safariMark("uidevice_method_missing"); return; }
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)hooked_systemVersion) { ci_safariMark("uidevice_already_swizzled"); return; }
    orig_systemVersion = (ci_orig_systemVersion_t)cur;
    method_setImplementation(m, (IMP)hooked_systemVersion);
    ci_safariMark("uidevice_swizzled");
}

// v2.5.7: SystemVersion.plist redirect.
//
// WebKit on iOS likely uses _CFCopySystemVersionDictionary which reads
// /System/Library/CoreServices/SystemVersion.plist via open(). We
// pre-build a fake plist with our spoofed ProductVersion + Build, then
// hook open() to redirect any read of the real path to our tmp file.
//
// This is the same trick the main dylib uses for AIDA64 spoof, ported
// here for sidecar's minimal scope.
static char g_safariFakeSysVerPath[256] = {0};
static const char *kRealSysVerPath = "/System/Library/CoreServices/SystemVersion.plist";

static void ci_safariBuildFakeSysVer(void) {
    @autoreleasepool {
        NSString *fakeProductVer = ci_safariConfigString(@"systemVersion");
        if (!fakeProductVer.length) return;
        NSString *fakeBuild = ci_safariConfigString(@"kern_osversion") ?: @"21A340";
        NSDictionary *dict = @{
            @"ProductBuildVersion": fakeBuild,
            @"ProductCopyright":    @"1983-2024 Apple Inc.",
            @"ProductName":         @"iPhone OS",
            @"ProductVersion":      fakeProductVer,
        };
        NSString *tmpDir = NSTemporaryDirectory();
        if (!tmpDir.length) return;
        NSString *tmpPath = [tmpDir stringByAppendingPathComponent:@"hios_safari_SystemVersion.plist"];
        NSError *err = nil;
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:dict
                        format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
        if (!data) { ci_safariMark("sysver_serialize_failed"); return; }
        if ([data writeToFile:tmpPath atomically:YES]) {
            strncpy(g_safariFakeSysVerPath, [tmpPath UTF8String], sizeof(g_safariFakeSysVerPath)-1);
            ci_safariMark("sysver_plist_built");
        } else {
            ci_safariMark("sysver_write_failed");
        }
    }
}

typedef int (*open_t)(const char *path, int flags, ...);
static open_t orig_open = NULL;
typedef int (*openat_t)(int dirfd, const char *path, int flags, ...);
static openat_t orig_openat = NULL;

static int hooked_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    if (path && g_safariFakeSysVerPath[0] && strcmp(path, kRealSysVerPath) == 0) {
        ci_safariMark("sysver_open_redirected");
        return orig_open(g_safariFakeSysVerPath, flags, mode);
    }
    return orig_open(path, flags, mode);
}

static int hooked_openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap);
    }
    if (path && g_safariFakeSysVerPath[0] && strcmp(path, kRealSysVerPath) == 0) {
        ci_safariMark("sysver_openat_redirected");
        return orig_openat(dirfd, g_safariFakeSysVerPath, flags, mode);
    }
    return orig_openat(dirfd, path, flags, mode);
}

// sysctlbyname hook — only intercepts kern.osproductversion.
typedef int (*sysctlbyname_t)(const char *name, void *oldp, size_t *oldlenp,
                              void *newp, size_t newlen);
static sysctlbyname_t orig_sysctlbyname = NULL;

static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                                void *newp, size_t newlen) {
    int ret = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (ret != 0 || !oldp || !oldlenp || !name) return ret;
    // Tight char gate — bail before any string compare for non-kern sysctls.
    if (name[0] != 'k') return ret;
    if (strcmp(name, "kern.osproductversion") != 0 &&
        strcmp(name, "kern.osproductversionextra") != 0) return ret;

    // v2.5.4 diag — confirm hook fires
    ci_safariMark("osprod_hit");

    NSString *fakeVer = ci_safariConfigString(@"systemVersion");
    if (!fakeVer.length) { ci_safariMark("config_empty"); return ret; }
    const char *cval = [fakeVer UTF8String];
    if (!cval) { ci_safariMark("utf8_nil"); return ret; }
    size_t needed = strlen(cval) + 1;
    if (*oldlenp >= needed) {
        memcpy(oldp, cval, needed);
        *oldlenp = needed;
        ci_safariMark("returned_fake");
        return 0;
    }
    ci_safariMark("buffer_too_small");
    return ret;
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        // Defensive: only fire in Safari + WebContent. Filter plist
        // already restricts this, but double-check at runtime.
        if (![bid isEqualToString:@"com.apple.mobilesafari"] &&
            ![bid hasPrefix:@"com.apple.WebKit"]) {
            return;
        }
        ci_safariMark("ctor_entered");

        // (1) sysctlbyname hook — for kern.osproductversion
        void *sym = dlsym(RTLD_DEFAULT, "sysctlbyname");
        if (sym && !orig_sysctlbyname) {
            MSHookFunction(sym, (void *)hooked_sysctlbyname,
                           (void **)&orig_sysctlbyname);
            if (orig_sysctlbyname) ci_safariMark("hook_installed");
            else                   ci_safariMark("hook_failed");
        }

        // (2) MGCopyAnswer hook — for ProductVersion (kept from v2.5.5; some
        // SDKs DO use MG even though WebKit's main UA build path doesn't).
        void *mgHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (mgHandle) {
            void *mgSym = dlsym(mgHandle, "MGCopyAnswer");
            if (mgSym && !orig_MGCopyAnswer) {
                MSHookFunction(mgSym, (void *)hooked_MGCopyAnswer,
                               (void **)&orig_MGCopyAnswer);
                if (orig_MGCopyAnswer) ci_safariMark("mg_installed");
                else                   ci_safariMark("mg_failed");
            }
        } else {
            ci_safariMark("mg_dlopen_failed");
        }

        // (3) v2.5.6: UIDevice.systemVersion swizzle.
        ci_swizzleSystemVersion();

        // (4) v2.5.7: pre-build fake SystemVersion.plist + hook open()
        // to redirect. WebKit may read this plist directly via
        // _CFCopySystemVersionDictionary to build UA.
        ci_safariBuildFakeSysVer();
        void *openSym = dlsym(RTLD_DEFAULT, "open");
        if (openSym && !orig_open) {
            MSHookFunction(openSym, (void *)hooked_open, (void **)&orig_open);
            if (orig_open) ci_safariMark("open_installed");
            else           ci_safariMark("open_failed");
        }
        void *openatSym = dlsym(RTLD_DEFAULT, "openat");
        if (openatSym && !orig_openat) {
            MSHookFunction(openatSym, (void *)hooked_openat, (void **)&orig_openat);
            if (orig_openat) ci_safariMark("openat_installed");
            else             ci_safariMark("openat_failed");
        }

        NSLog(@"[ChangeInfoIosSafari] sysctl + MG + UIDevice + open(SysVer) hooked in %@", bid);
    }
}
