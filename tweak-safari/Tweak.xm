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

    NSString *fakeVer = ci_safariConfigString(@"systemVersion");
    if (!fakeVer.length) return ret;
    const char *cval = [fakeVer UTF8String];
    if (!cval) return ret;
    size_t needed = strlen(cval) + 1;
    if (*oldlenp >= needed) {
        memcpy(oldp, cval, needed);
        *oldlenp = needed;
        return 0;
    }
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

        void *sym = dlsym(RTLD_DEFAULT, "sysctlbyname");
        if (sym && !orig_sysctlbyname) {
            MSHookFunction(sym, (void *)hooked_sysctlbyname,
                           (void **)&orig_sysctlbyname);
            NSLog(@"[ChangeInfoIosSafari] sysctlbyname hooked in %@", bid);
        }
    }
}
