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
#import <sys/sysctl.h>
#import <dlfcn.h>
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

        // (2) MGCopyAnswer hook — for ProductVersion. v2.5.5: this is what
        // WebKit on iOS actually uses to build the UA string. dlopen MG
        // explicitly because Safari may not have it in dyld cache yet.
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

        NSLog(@"[ChangeInfoIosSafari] sysctl+MG hooked in %@", bid);
    }
}
