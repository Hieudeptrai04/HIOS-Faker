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
#import <CFNetwork/CFNetwork.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <mach-o/loader.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

// MSHookFunction prototype (from libsubstrate)
#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

// v2.5.4 diagnostic helpers — write marker files to confirm load + hook fire.
// Writes to per-process tmp (NSTemporaryDirectory). v2.5.22 added a shared
// system-path write but the Safari/WebContent sandbox blocks it — removed
// in v2.5.24.
static void ci_safariMark(const char *tag) {
    @autoreleasepool {
        NSString *dir = NSTemporaryDirectory();
        if (!dir.length) return;
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        NSString *path = [dir stringByAppendingFormat:@"/ci_safari_%s.txt", tag];
        NSString *stamp = [NSString stringWithFormat:@"%@ bid=%@\n", [NSDate date], bid];
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

// v2.5.10: NSProcessInfo.operatingSystemVersionString swizzle.
// WebKit may use this as fallback when CFCopySystemVersionDictionary
// returns something it doesn't like.
typedef NSString *(*ci_orig_osverstr_t)(id, SEL);
static ci_orig_osverstr_t orig_osVersionString = NULL;

static NSString *hooked_osVersionString(id self, SEL _cmd) {
    ci_safariMark("nsprocinfo_osverstr_hit");
    NSString *fake = ci_safariConfigString(@"systemVersion");
    if (fake.length) {
        ci_safariMark("nsprocinfo_osverstr_fake");
        return [NSString stringWithFormat:@"Version %@ (Build %@)",
                fake,
                ci_safariConfigString(@"kern_osversion") ?: @"21A340"];
    }
    return orig_osVersionString ? orig_osVersionString(self, _cmd) : @"";
}

static void ci_swizzleProcessInfo(void) {
    Class cls = objc_getClass("NSProcessInfo");
    if (!cls) { ci_safariMark("nspi_class_missing"); return; }
    Method m = class_getInstanceMethod(cls, @selector(operatingSystemVersionString));
    if (!m) { ci_safariMark("nspi_method_missing"); return; }
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)hooked_osVersionString) { ci_safariMark("nspi_already_swizzled"); return; }
    orig_osVersionString = (ci_orig_osverstr_t)cur;
    method_setImplementation(m, (IMP)hooked_osVersionString);
    ci_safariMark("nspi_swizzled");
}

// v2.5.14: WKWebView UA-related private methods. Force every WKWebView in
// Safari to report our fake UA, regardless of Safari's own UA build logic.
typedef NSString *(*ci_imp_ua_t)(id, SEL);
static ci_imp_ua_t orig_wk_customUA   = NULL;
static ci_imp_ua_t orig_wk__userAgent = NULL;
static ci_imp_ua_t orig_wk__systemUA  = NULL;
static ci_imp_ua_t orig_NSURLReq_valueForHeader = NULL;

static NSString *ci_fakeFullUA(void) {
    return ci_safariConfigString(@"zalo_fakeWebViewUA");
}

static NSString *hooked_wk_customUA(id self, SEL _cmd) {
    NSString *fake = ci_fakeFullUA();
    if (fake.length) { ci_safariMark("wk_customua_fake"); return fake; }
    return orig_wk_customUA ? orig_wk_customUA(self, _cmd) : nil;
}

static NSString *hooked_wk__userAgent(id self, SEL _cmd) {
    NSString *fake = ci_fakeFullUA();
    if (fake.length) { ci_safariMark("wk__userAgent_fake"); return fake; }
    return orig_wk__userAgent ? orig_wk__userAgent(self, _cmd) : nil;
}

static NSString *hooked_wk__systemUA(id self, SEL _cmd) {
    NSString *fake = ci_fakeFullUA();
    if (fake.length) { ci_safariMark("wk__systemUA_fake"); return fake; }
    return orig_wk__systemUA ? orig_wk__systemUA(self, _cmd) : nil;
}

typedef NSString *(*ci_nsurlreq_valhdr_t)(id, SEL, NSString *);
static NSString *hooked_NSURLReq_valueForHeader(id self, SEL _cmd, NSString *field) {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        NSString *fake = ci_fakeFullUA();
        if (fake.length) { ci_safariMark("nsurlreq_ua_fake"); return fake; }
    }
    return orig_NSURLReq_valueForHeader ?
        ((ci_nsurlreq_valhdr_t)orig_NSURLReq_valueForHeader)(self, _cmd, field) : nil;
}

// v2.5.23: NSMutableURLRequest setValue:forHTTPHeaderField: SETTER hook.
// When WebKit Networking builds the outgoing HTTP request and sets UA,
// we rewrite the value with our fake. This is the LAST gate before the
// request goes out — works even if UA built by an unhooked code path.
typedef void (*ci_nsurlreq_setval_t)(id, SEL, NSString *, NSString *);
static ci_nsurlreq_setval_t orig_NSMutReq_setValueForHeader = NULL;
static ci_nsurlreq_setval_t orig_NSMutReq_addValueForHeader = NULL;

static void hooked_NSMutReq_setValueForHeader(id self, SEL _cmd, NSString *value, NSString *field) {
    if (field && [field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        NSString *fake = ci_fakeFullUA();
        if (fake.length) {
            ci_safariMark("nsmutreq_setua_fake");
            if (orig_NSMutReq_setValueForHeader)
                orig_NSMutReq_setValueForHeader(self, _cmd, fake, field);
            return;
        }
    }
    if (orig_NSMutReq_setValueForHeader)
        orig_NSMutReq_setValueForHeader(self, _cmd, value, field);
}

static void hooked_NSMutReq_addValueForHeader(id self, SEL _cmd, NSString *value, NSString *field) {
    if (field && [field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
        NSString *fake = ci_fakeFullUA();
        if (fake.length) {
            ci_safariMark("nsmutreq_addua_fake");
            if (orig_NSMutReq_addValueForHeader)
                orig_NSMutReq_addValueForHeader(self, _cmd, fake, field);
            return;
        }
    }
    if (orig_NSMutReq_addValueForHeader)
        orig_NSMutReq_addValueForHeader(self, _cmd, value, field);
}

static void ci_swizzleNSURLReqSetters(void) {
    Class mr = objc_getClass("NSMutableURLRequest");
    if (mr) {
        Method m = class_getInstanceMethod(mr, @selector(setValue:forHTTPHeaderField:));
        if (m) {
            orig_NSMutReq_setValueForHeader = (ci_nsurlreq_setval_t)method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_NSMutReq_setValueForHeader);
            ci_safariMark("nsmutreq_setval_swizzled");
        }
        Method m2 = class_getInstanceMethod(mr, @selector(addValue:forHTTPHeaderField:));
        if (m2) {
            orig_NSMutReq_addValueForHeader = (ci_nsurlreq_setval_t)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)hooked_NSMutReq_addValueForHeader);
            ci_safariMark("nsmutreq_addval_swizzled");
        }
    }
}

// v2.5.23: CFHTTPMessageSetHeaderFieldValue — CFNetwork low-level hook.
// CFHTTPMessage is what NSURLRequest is backed by; some code paths
// (notably WebKit's network process) bypass NSURLRequest and call
// CFHTTPMessageSetHeaderFieldValue directly.
typedef void (*CFHTTPMsgSetHdr_t)(CFHTTPMessageRef msg, CFStringRef field, CFStringRef value);
static CFHTTPMsgSetHdr_t orig_CFHTTPMessageSetHeaderFieldValue = NULL;

static void hooked_CFHTTPMessageSetHeaderFieldValue(CFHTTPMessageRef msg, CFStringRef field, CFStringRef value) {
    if (field) {
        NSString *f = (__bridge NSString *)field;
        if ([f caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame) {
            NSString *fake = ci_fakeFullUA();
            if (fake.length) {
                ci_safariMark("cfhttpmsg_setua_fake");
                if (orig_CFHTTPMessageSetHeaderFieldValue)
                    orig_CFHTTPMessageSetHeaderFieldValue(msg, field, (__bridge CFStringRef)fake);
                return;
            }
        }
    }
    if (orig_CFHTTPMessageSetHeaderFieldValue)
        orig_CFHTTPMessageSetHeaderFieldValue(msg, field, value);
}

// v2.5.18: NSBundle.objectForInfoDictionaryKey swizzle. WebKit may
// read Safari version from MobileSafari's Info.plist via this method.
typedef id (*ci_imp_infodict_t)(id, SEL, NSString *);
static ci_imp_infodict_t orig_objForInfoDict = NULL;

static id hooked_objForInfoDictKey(id self, SEL _cmd, NSString *key) {
    if ([key isEqualToString:@"CFBundleShortVersionString"] ||
        [key isEqualToString:@"CFBundleVersion"]) {
        // Only spoof when called on Safari's bundle
        NSString *bid = [(NSBundle *)self bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.mobilesafari"] ||
            [bid hasPrefix:@"com.apple.WebKit"]) {
            NSString *fakeUA = ci_safariConfigString(@"zalo_fakeWebViewUA");
            if (fakeUA.length) {
                NSRegularExpression *re = [NSRegularExpression
                    regularExpressionWithPattern:@"Version/(\\d+\\.\\d+\\.\\d+)" options:0 error:nil];
                NSTextCheckingResult *r = [re firstMatchInString:fakeUA options:0
                                                          range:NSMakeRange(0, fakeUA.length)];
                if (r && r.numberOfRanges >= 2) {
                    NSString *ver = [fakeUA substringWithRange:[r rangeAtIndex:1]];
                    ci_safariMark("nsbundle_safariver_fake");
                    return ver;
                }
            }
        }
    }
    return orig_objForInfoDict ? orig_objForInfoDict(self, _cmd, key) : nil;
}

static void ci_swizzleNSBundle(void) {
    Class cls = objc_getClass("NSBundle");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(objectForInfoDictionaryKey:));
    if (!m) return;
    orig_objForInfoDict = (ci_imp_infodict_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_objForInfoDictKey);
    ci_safariMark("nsbundle_swizzled");
}

// v2.5.22: CFBundleGetVersionNumber — returns UInt32 packed BCD (e.g. 0x16601 for 16.6.1).
// WebKit may use this instead of string lookup. Spoof by encoding our fake version
// as the same BCD format.
typedef UInt32 (*CFBundleGetVerNum_t)(CFBundleRef bundle);
static CFBundleGetVerNum_t orig_CFBundleGetVersionNumber = NULL;

static UInt32 ci_packBCDVersion(NSString *ver) {
    if (!ver.length) return 0;
    NSArray *parts = [ver componentsSeparatedByString:@"."];
    UInt32 major = parts.count > 0 ? (UInt32)[parts[0] integerValue] : 0;
    UInt32 minor = parts.count > 1 ? (UInt32)[parts[1] integerValue] : 0;
    UInt32 patch = parts.count > 2 ? (UInt32)[parts[2] integerValue] : 0;
    // Apple BCD format: 0xMMMNNPP0 where MMM=major, NN=minor, PP=patch (roughly)
    return (major << 24) | (minor << 16) | (patch << 8);
}

static UInt32 hooked_CFBundleGetVersionNumber(CFBundleRef bundle) {
    if (bundle) {
        CFStringRef bidCF = CFBundleGetIdentifier(bundle);
        NSString *bid = bidCF ? (__bridge NSString *)bidCF : nil;
        if ([bid isEqualToString:@"com.apple.mobilesafari"] ||
            [bid hasPrefix:@"com.apple.WebKit"]) {
            NSString *fakeUA = ci_safariConfigString(@"zalo_fakeWebViewUA");
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:@"Version/(\\d+\\.\\d+\\.\\d+)" options:0 error:nil];
            NSTextCheckingResult *r = [re firstMatchInString:fakeUA options:0 range:NSMakeRange(0, fakeUA.length)];
            if (r && r.numberOfRanges >= 2) {
                NSString *ver = [fakeUA substringWithRange:[r rangeAtIndex:1]];
                ci_safariMark("cfbundle_getvernum_fake");
                return ci_packBCDVersion(ver);
            }
        }
    }
    return orig_CFBundleGetVersionNumber ? orig_CFBundleGetVersionNumber(bundle) : 0;
}

// v2.5.22: CFBundleCopyVersionString — another CF version API used by WebKit.
typedef CFStringRef (*CFBundleCopyVerStr_t)(CFBundleRef bundle);
static CFBundleCopyVerStr_t orig_CFBundleCopyVersionString = NULL;

static CFStringRef hooked_CFBundleCopyVersionString(CFBundleRef bundle) {
    if (bundle) {
        CFStringRef bidCF = CFBundleGetIdentifier(bundle);
        NSString *bid = bidCF ? (__bridge NSString *)bidCF : nil;
        if ([bid isEqualToString:@"com.apple.mobilesafari"] ||
            [bid hasPrefix:@"com.apple.WebKit"]) {
            NSString *fakeUA = ci_safariConfigString(@"zalo_fakeWebViewUA");
            NSRegularExpression *re = [NSRegularExpression
                regularExpressionWithPattern:@"Version/(\\d+\\.\\d+\\.\\d+)" options:0 error:nil];
            NSTextCheckingResult *r = [re firstMatchInString:fakeUA options:0 range:NSMakeRange(0, fakeUA.length)];
            if (r && r.numberOfRanges >= 2) {
                NSString *ver = [fakeUA substringWithRange:[r rangeAtIndex:1]];
                ci_safariMark("cfbundle_copyverstr_fake");
                return (CFStringRef)CFBridgingRetain([ver copy]);
            }
        }
    }
    return orig_CFBundleCopyVersionString ? orig_CFBundleCopyVersionString(bundle) : NULL;
}

// v2.5.19: CFBundleGetValueForInfoDictionaryKey — low-level CF API
// that WebKit may use to read Safari version directly, bypassing NSBundle.
typedef CFTypeRef (*CFBundleGetVal_t)(CFBundleRef bundle, CFStringRef key);
static CFBundleGetVal_t orig_CFBundleGetValueForInfoDictionaryKey = NULL;

static CFTypeRef hooked_CFBundleGetValueForInfoDictionaryKey(CFBundleRef bundle, CFStringRef key) {
    if (key && bundle) {
        NSString *k = (__bridge NSString *)key;
        if ([k isEqualToString:@"CFBundleShortVersionString"] ||
            [k isEqualToString:@"CFBundleVersion"]) {
            // Check if bundle is Safari/WebKit
            CFStringRef bidCF = CFBundleGetIdentifier(bundle);
            NSString *bid = bidCF ? (__bridge NSString *)bidCF : nil;
            if ([bid isEqualToString:@"com.apple.mobilesafari"] ||
                [bid hasPrefix:@"com.apple.WebKit"]) {
                NSString *fakeUA = ci_safariConfigString(@"zalo_fakeWebViewUA");
                if (fakeUA.length) {
                    NSRegularExpression *re = [NSRegularExpression
                        regularExpressionWithPattern:@"Version/(\\d+\\.\\d+\\.\\d+)" options:0 error:nil];
                    NSTextCheckingResult *r = [re firstMatchInString:fakeUA options:0 range:NSMakeRange(0, fakeUA.length)];
                    if (r && r.numberOfRanges >= 2) {
                        ci_safariMark("cfbundle_safariver_fake");
                        static NSString *cached = nil;
                        cached = [fakeUA substringWithRange:[r rangeAtIndex:1]];
                        return (__bridge CFTypeRef)cached;
                    }
                }
            }
        }
    }
    return orig_CFBundleGetValueForInfoDictionaryKey ?
        orig_CFBundleGetValueForInfoDictionaryKey(bundle, key) : NULL;
}

// v2.5.24: hook WKWebView init to FORCE-SET customUserAgent + inject
// a WKUserScript at document-start that overrides navigator.userAgent,
// navigator.appVersion, navigator.platform, navigator.vendor.
//
// Without this, JS-visible navigator.userAgent leaks the real Version/16.6.1
// (because WebKit caches the auto-built UA at process start, BEFORE our CF
// hooks fire — see v2.5.19-23 history). Setting customUserAgent on each
// WKWebView overrides at the WebKit-internal level too.
typedef id (*ci_wkwv_init_t)(id, SEL, CGRect, id);
static ci_wkwv_init_t orig_WKWV_initWithFrameCfg = NULL;

static NSString *ci_jsEscape(NSString *s) {
    if (!s) return @"";
    return [[[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
                stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]
                stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

static NSString *ci_buildNavigatorOverrideJS(NSString *fakeUA) {
    NSString *esc = ci_jsEscape(fakeUA);
    NSString *appVer = [esc hasPrefix:@"Mozilla/"] ? [esc substringFromIndex:8] : esc;
    // v2.5.25: also spoof WebGL VENDOR/RENDERER + UNMASKED variants from
    // config (web_glVendor / web_glRenderer), canvas noise via toDataURL,
    // hardwareConcurrency, and screen dims.
    NSString *glVendor   = ci_jsEscape(ci_safariConfigString(@"web_glVendor")   ?: @"Apple Inc.");
    NSString *glRenderer = ci_jsEscape(ci_safariConfigString(@"web_glRenderer") ?: @"Apple GPU");
    NSString *canvasOn   = ci_safariConfigString(@"web_canvasNoise") ? @"1" : @"0";
    // v2.5.33: also spoof navigator.geolocation. browserleaks proved
    // that even with CL hooks in Maps/Weather the JS API returned real
    // coords after a few seconds (WebKit's geolocation pipeline pulls
    // from the UI process's CL which isn't on the location-sidecar's
    // bundle filter). Easiest fix is to lie at the JS layer directly.
    NSString *latS = ci_safariConfigString(@"latitude")  ?: @"21.028511";
    NSString *lngS = ci_safariConfigString(@"longitude") ?: @"105.804817";
    NSString *altS = ci_safariConfigString(@"altitude")  ?: @"15";
    // v2.5.26: stealth-mode JS injection. Defines properties on the
    // PROTOTYPE (Navigator.prototype) instead of the instance — that's
    // where the native properties live, so a fingerprint script doing
    // `Object.getOwnPropertyNames(navigator).includes('userAgent')` would
    // see `false` (matches native Safari) instead of `true` (which would
    // out us as a tweak). Same trick: each overridden function exposes a
    // `toString` returning the native-looking string.
    return [NSString stringWithFormat:
        @"(function(){try{"
         "var dp=function(proto,key,val){try{"
         "  var g=function(){return val;};"
         "  try{Object.defineProperty(g,'toString',{value:function(){return 'function '+key+'() { [native code] }';},configurable:true});}catch(e){}"
         "  Object.defineProperty(proto,key,{get:g,configurable:true});"
         "}catch(e){}};"
         "dp(Navigator.prototype,'userAgent','%@');"
         "dp(Navigator.prototype,'appVersion','%@');"
         "dp(Navigator.prototype,'platform','iPhone');"
         "dp(Navigator.prototype,'vendor','Apple Computer, Inc.');"
         "dp(Navigator.prototype,'hardwareConcurrency', 4 + ((Math.random()*3)|0)*2);"
         // WebGL: override prototype's getParameter, preserve native toString.
         "['WebGLRenderingContext','WebGL2RenderingContext'].forEach(function(n){"
         "  if (!window[n]) return;"
         "  var p=window[n].prototype;"
         "  var orig=p.getParameter;"
         "  var f=function(pname){"
         "    if (pname===0x1F00 || pname===0x9245) return '%@';"
         "    if (pname===0x1F01 || pname===0x9246) return '%@';"
         "    return orig.call(this,pname);"
         "  };"
         "  try{Object.defineProperty(f,'toString',{value:function(){return 'function getParameter() { [native code] }';},configurable:true});}catch(e){}"
         "  p.getParameter=f;"
         "});"
         // Canvas noise — only if enabled in config.
         "if (%@) {"
         "  var seed=(Math.random()*0xFFFFFFFF)|0;"
         "  var noise=function(c){try{"
         "    var ctx=c.getContext('2d'); if(!ctx) return;"
         "    var w=c.width|0, h=c.height|0; if(!w||!h) return;"
         "    var img=ctx.getImageData(0,0,w,h);"
         "    var data=img.data;"
         "    for (var i=0; i<data.length; i+=4){"
         "      data[i]  =(data[i]  ^ (seed&0x7)) & 0xFF;"
         "      data[i+1]=(data[i+1]^ ((seed>>3)&0x7)) & 0xFF;"
         "      data[i+2]=(data[i+2]^ ((seed>>6)&0x7)) & 0xFF;"
         "    }"
         "    ctx.putImageData(img,0,0);"
         "  }catch(e){}};"
         "  var origToDataURL=HTMLCanvasElement.prototype.toDataURL;"
         "  var f2=function(){noise(this); return origToDataURL.apply(this, arguments);};"
         "  try{Object.defineProperty(f2,'toString',{value:function(){return 'function toDataURL() { [native code] }';},configurable:true});}catch(e){}"
         "  HTMLCanvasElement.prototype.toDataURL=f2;"
         "}"
         // v2.5.33: navigator.geolocation override — getCurrentPosition /
         // watchPosition / clearWatch. Returns the spoofed lat/lng from
         // config every call. Bypasses WebKit's UI-process CL pipeline.
         "if (navigator.geolocation) {"
         "  var fakeCoords = function(){return {"
         "    coords: { latitude: %@, longitude: %@,"
         "              accuracy: 10 + Math.random()*30,"
         "              altitude: %@, altitudeAccuracy: 5,"
         "              heading: null, speed: null },"
         "    timestamp: Date.now()"
         "  };};"
         "  var gcp = function(s,e,o){ setTimeout(function(){ if(s) try{ s(fakeCoords()); }catch(_){} }, 30); };"
         "  var wp  = function(s,e,o){ setTimeout(function(){ if(s) try{ s(fakeCoords()); }catch(_){} }, 30); return (Math.random()*1e6)|0; };"
         "  var cw  = function(id){};"
         "  try{Object.defineProperty(gcp,'toString',{value:function(){return 'function getCurrentPosition() { [native code] }';},configurable:true});}catch(e){}"
         "  try{Object.defineProperty(wp,'toString',{value:function(){return 'function watchPosition() { [native code] }';},configurable:true});}catch(e){}"
         "  try{Object.defineProperty(cw,'toString',{value:function(){return 'function clearWatch() { [native code] }';},configurable:true});}catch(e){}"
         "  try{"
         "    var GP = Object.getPrototypeOf(navigator.geolocation);"
         "    Object.defineProperty(GP, 'getCurrentPosition', { value: gcp, configurable: true });"
         "    Object.defineProperty(GP, 'watchPosition',      { value: wp,  configurable: true });"
         "    Object.defineProperty(GP, 'clearWatch',         { value: cw,  configurable: true });"
         "  } catch(e) {"
         "    navigator.geolocation.getCurrentPosition = gcp;"
         "    navigator.geolocation.watchPosition      = wp;"
         "    navigator.geolocation.clearWatch         = cw;"
         "  }"
         "}"
         "}catch(e){}})();",
        esc, appVer, glVendor, glRenderer, canvasOn, latS, lngS, altS];
}

static void ci_injectUserScript(id configuration, NSString *fakeUA) {
    if (!configuration || !fakeUA.length) return;
    @try {
        SEL selUCC = @selector(userContentController);
        if (![configuration respondsToSelector:selUCC]) return;
        id ucc = ((id(*)(id, SEL))objc_msgSend)(configuration, selUCC);
        if (!ucc) return;
        Class scriptCls = objc_getClass("WKUserScript");
        if (!scriptCls) return;
        NSString *js = ci_buildNavigatorOverrideJS(fakeUA);
        // WKUserScriptInjectionTimeAtDocumentStart = 0 (NSInteger enum)
        id raw = [scriptCls alloc];
        id script = ((id(*)(id, SEL, NSString *, NSInteger, BOOL))objc_msgSend)(
            raw,
            @selector(initWithSource:injectionTime:forMainFrameOnly:),
            js, (NSInteger)0, NO);
        if (script) {
            ((void(*)(id, SEL, id))objc_msgSend)(ucc, @selector(addUserScript:), script);
            ci_safariMark("wkucc_userscript_added");
        }
    } @catch (NSException *ex) {
        ci_safariMark("userscript_inject_exception");
    }
}

static id hooked_WKWV_initWithFrameCfg(id self, SEL _cmd, CGRect frame, id configuration) {
    // Inject user script BEFORE init so it's in the config before first navigation.
    NSString *fake = ci_fakeFullUA();
    if (fake.length && configuration) {
        ci_injectUserScript(configuration, fake);
    }
    id result = orig_WKWV_initWithFrameCfg ?
        orig_WKWV_initWithFrameCfg(self, _cmd, frame, configuration) : self;
    if (result && fake.length && [result respondsToSelector:@selector(setCustomUserAgent:)]) {
        ((void(*)(id, SEL, NSString *))objc_msgSend)(result, @selector(setCustomUserAgent:), fake);
        ci_safariMark("wkwv_init_setCustomUA");
    }
    return result;
}

static void ci_swizzleAllUAGetters(void) {
    Class wk = objc_getClass("WKWebView");
    if (wk) {
        // v2.5.24: hook initWithFrame:configuration: to force-set customUA
        Method mInit = class_getInstanceMethod(wk, @selector(initWithFrame:configuration:));
        if (mInit) {
            orig_WKWV_initWithFrameCfg = (ci_wkwv_init_t)method_getImplementation(mInit);
            method_setImplementation(mInit, (IMP)hooked_WKWV_initWithFrameCfg);
            ci_safariMark("wkwv_init_swizzled");
        }
        // public customUserAgent getter — override to ALWAYS return fake
        Method m1 = class_getInstanceMethod(wk, @selector(customUserAgent));
        if (m1) {
            orig_wk_customUA = (ci_imp_ua_t)method_getImplementation(m1);
            method_setImplementation(m1, (IMP)hooked_wk_customUA);
            ci_safariMark("wk_customua_swizzled");
        }
        // private _userAgent getter
        SEL selUA = NSSelectorFromString(@"_userAgent");
        Method m2 = class_getInstanceMethod(wk, selUA);
        if (m2) {
            orig_wk__userAgent = (ci_imp_ua_t)method_getImplementation(m2);
            method_setImplementation(m2, (IMP)hooked_wk__userAgent);
            ci_safariMark("wk__userAgent_swizzled");
        }
        // private +_systemUserAgent class method
        SEL selSysUA = NSSelectorFromString(@"_systemUserAgent");
        Method m3 = class_getClassMethod(wk, selSysUA);
        if (m3) {
            orig_wk__systemUA = (ci_imp_ua_t)method_getImplementation(m3);
            method_setImplementation(m3, (IMP)hooked_wk__systemUA);
            ci_safariMark("wk__systemUA_swizzled");
        }
    }
    // NSURLRequest valueForHTTPHeaderField — return fake when asked for UA
    Class req = objc_getClass("NSURLRequest");
    if (req) {
        Method m4 = class_getInstanceMethod(req, @selector(valueForHTTPHeaderField:));
        if (m4) {
            orig_NSURLReq_valueForHeader = (ci_imp_ua_t)method_getImplementation(m4);
            method_setImplementation(m4, (IMP)hooked_NSURLReq_valueForHeader);
            ci_safariMark("nsurlreq_swizzled");
        }
    }
}

// v2.5.9 ROLLBACK open()/openat() hooks — caused Safari to crash. Each
// global syscall hook fires on every file open in Safari (thousands/sec)
// and even tiny ABI mismatches in variadic forwarding break the process.
//
// Alternative approach: hook _CFCopySystemVersionDictionary directly.
// This is a higher-level CF API that returns the cached dict. Hooking
// it returns our fake dict on first call → dispatch_once caches it.

typedef CFDictionaryRef (*CFCopySysVerDict_t)(void);
static CFCopySysVerDict_t orig__CFCopySystemVersionDictionary = NULL;
static CFCopySysVerDict_t orig__CFCopyServerVersionDictionary = NULL;

static CFDictionaryRef ci_buildFakeSysVerDict(void) {
    NSString *fakeProductVer = ci_safariConfigString(@"systemVersion");
    if (!fakeProductVer.length) return NULL;
    NSString *fakeBuild = ci_safariConfigString(@"kern_osversion") ?: @"21A340";
    // v2.5.10: extend with ALL keys real iOS SystemVersion.plist has.
    // WebKit may read ProductUserVisibleVersion instead of ProductVersion.
    NSDictionary *d = @{
        @"ProductName":                @"iPhone OS",
        @"ProductVersion":             fakeProductVer,
        @"ProductUserVisibleVersion":  fakeProductVer,
        @"ProductBuildVersion":        fakeBuild,
        @"BuildID":                    @"00000000-0000-0000-0000-000000000000",
        @"ProductCopyright":           @"1983-2024 Apple Inc.",
        @"iOSSupportVersion":          fakeProductVer,
        @"ReleaseType":                @"User",
    };
    return (CFDictionaryRef)CFBridgingRetain([d copy]);
}

// v2.5.11: read-modify-return. Preserves all keys + types Apple's WebKit
// might validate against. Only changes the version-related entries.
static CFDictionaryRef ci_patchSysVerDict(CFDictionaryRef real) {
    if (!real) return ci_buildFakeSysVerDict();
    NSString *fakeProductVer = ci_safariConfigString(@"systemVersion");
    if (!fakeProductVer.length) return real;
    NSMutableDictionary *m = [((__bridge NSDictionary *)real) mutableCopy];
    CFRelease(real);
    m[@"ProductVersion"]            = fakeProductVer;
    m[@"ProductUserVisibleVersion"] = fakeProductVer;
    m[@"iOSSupportVersion"]         = fakeProductVer;
    NSString *fakeBuild = ci_safariConfigString(@"kern_osversion");
    if (fakeBuild.length) m[@"ProductBuildVersion"] = fakeBuild;
    return (CFDictionaryRef)CFBridgingRetain([m copy]);
}

static CFDictionaryRef hooked__CFCopySystemVersionDictionary(void) {
    ci_safariMark("cf_sysver_hit");
    CFDictionaryRef real = orig__CFCopySystemVersionDictionary ? orig__CFCopySystemVersionDictionary() : NULL;
    CFDictionaryRef patched = ci_patchSysVerDict(real);
    if (patched && patched != real) ci_safariMark("cf_sysver_patched");
    return patched;
}

static CFDictionaryRef hooked__CFCopyServerVersionDictionary(void) {
    ci_safariMark("cf_servver_hit");
    CFDictionaryRef real = orig__CFCopyServerVersionDictionary ? orig__CFCopyServerVersionDictionary() : NULL;
    CFDictionaryRef patched = ci_patchSysVerDict(real);
    if (patched && patched != real) ci_safariMark("cf_servver_patched");
    return patched;
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

// v2.5.12: priority 101 to ensure we load BEFORE WebKit framework's
// static initializers run. WebKit caches iOS version at framework init;
// to spoof, our hook must be installed BEFORE that cache fills.
// v2.5.15: runtime memory patch of WebKit's compile-time UA template
// strings. Same trick market tools use, but in-memory (no on-disk patch
// = no trustcache update needed).
//
// Walks every loaded image's __TEXT __cstring section, looks for known
// fixed UA substrings ("Mobile/15E148", "Version/16.6.1",
// "AppleWebKit/605.1.15"), and overwrites them with our random values
// of EXACTLY the same length so neighboring relocations stay correct.

static void ci_patchStringInRange(const uint8_t *base, size_t size,
                                   const char *needle, const char *replacement) {
    size_t nlen = strlen(needle);
    size_t rlen = strlen(replacement);
    if (nlen != rlen) return; // must be same length
    if (nlen == 0 || nlen > size) return;
    for (size_t i = 0; i + nlen <= size; i++) {
        if (memcmp(base + i, needle, nlen) == 0) {
            uintptr_t addr = (uintptr_t)(base + i);
            uintptr_t page = addr & ~((uintptr_t)0xFFF);
            kern_return_t kr = vm_protect(mach_task_self(),
                                           page, 0x1000, FALSE,
                                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
            if (kr == KERN_SUCCESS) {
                memcpy((void *)addr, replacement, rlen);
                vm_protect(mach_task_self(), page, 0x1000, FALSE,
                           VM_PROT_READ | VM_PROT_EXECUTE);
                ci_safariMark("ua_string_patched");
            }
        }
    }
}

static void ci_patchUAStringsInAllImages(void) {
    NSString *fakeUA = ci_safariConfigString(@"zalo_fakeWebViewUA");
    if (!fakeUA.length) return;

    NSRegularExpression *reWK = [NSRegularExpression
        regularExpressionWithPattern:@"AppleWebKit/(\\d+\\.\\d+\\.\\d+)" options:0 error:nil];
    NSRegularExpression *reVer = [NSRegularExpression
        regularExpressionWithPattern:@"Version/(\\d+\\.\\d+\\.\\d+)" options:0 error:nil];
    NSRegularExpression *reMob = [NSRegularExpression
        regularExpressionWithPattern:@"Mobile/([0-9A-Z]{6})" options:0 error:nil];

    NSString *fakeWK  = nil, *fakeVer = nil, *fakeMob = nil;
    NSTextCheckingResult *r;
    r = [reWK firstMatchInString:fakeUA options:0 range:NSMakeRange(0, fakeUA.length)];
    if (r && r.numberOfRanges >= 2) fakeWK = [fakeUA substringWithRange:[r rangeAtIndex:1]];
    r = [reVer firstMatchInString:fakeUA options:0 range:NSMakeRange(0, fakeUA.length)];
    if (r && r.numberOfRanges >= 2) fakeVer = [fakeUA substringWithRange:[r rangeAtIndex:1]];
    r = [reMob firstMatchInString:fakeUA options:0 range:NSMakeRange(0, fakeUA.length)];
    if (r && r.numberOfRanges >= 2) fakeMob = [fakeUA substringWithRange:[r rangeAtIndex:1]];

    char repWK[32]   = {0};
    char repVer[32]  = {0};
    char repVerBare[32] = {0};
    char repMob[32]  = {0};
    char repSafariWK[32] = {0};  // v2.5.19: "Safari/604.1" patch
    BOOL haveWK = NO, haveVer = NO, haveMob = NO, haveSafariWK = NO;
    if (fakeWK && fakeWK.length == 8) {
        snprintf(repWK, sizeof(repWK), "AppleWebKit/%s", [fakeWK UTF8String]);
        haveWK = (strlen(repWK) == strlen("AppleWebKit/605.1.15"));
    }
    if (fakeVer && fakeVer.length == 6) {
        snprintf(repVer, sizeof(repVer), "Version/%s", [fakeVer UTF8String]);
        snprintf(repVerBare, sizeof(repVerBare), "%s", [fakeVer UTF8String]);
        haveVer = (strlen(repVer) == strlen("Version/16.6.1"));
    }
    if (fakeMob && fakeMob.length == 6) {
        snprintf(repMob, sizeof(repMob), "Mobile/%s", [fakeMob UTF8String]);
        haveMob = (strlen(repMob) == strlen("Mobile/15E148"));
    }
    // v2.5.19: Safari/604.1 patch — randomize last digit each profile
    int safariBuildMinor = arc4random_uniform(3);  // 0/1/2
    snprintf(repSafariWK, sizeof(repSafariWK), "Safari/604.%d", safariBuildMinor);
    haveSafariWK = (strlen(repSafariWK) == strlen("Safari/604.1"));

    if (!haveWK && !haveVer && !haveMob && !haveSafariWK) {
        ci_safariMark("ua_no_matching_lengths");
        return;
    }

    // v2.5.17: scan BOTH __cstring (string literals) AND __const (const data
    // with embedded strings). Also try bare "16.6.1" pattern in case
    // Version/ literal is split from version number in binary layout.
    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        if (!header || !name) continue;
        // v2.5.21 ROLLBACK: scan only WebKit + MobileSafari + SafariShared.
        // v2.5.20 scanned ALL system frameworks → caused device hang
        // (each Logos-injected dylib's ctor patched system framework
        // strings, racing each other + breaking unrelated apps).
        if (!strstr(name, "WebKit") && !strstr(name, "WebCore") &&
            !strstr(name, "MobileSafari") && !strstr(name, "SafariShared")) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
        const struct load_command *lc = (const struct load_command *)cur;
        uint32_t ncmds = header->ncmds;
        for (uint32_t j = 0; j < ncmds; j++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                BOOL isText = strcmp(seg->segname, "__TEXT") == 0;
                BOOL isDataConst = strcmp(seg->segname, "__DATA_CONST") == 0;
                if (isText || isDataConst) {
                    const struct section_64 *sect = (const struct section_64 *)((uintptr_t)seg + sizeof(struct segment_command_64));
                    for (uint32_t k = 0; k < seg->nsects; k++) {
                        const char *sn = sect[k].sectname;
                        // Scan all string-bearing sections
                        if (strcmp(sn, "__cstring") == 0 ||
                            strcmp(sn, "__const") == 0 ||
                            strcmp(sn, "__objc_methname") == 0 ||
                            strcmp(sn, "__objc_classname") == 0 ||
                            strcmp(sn, "__os_log") == 0) {
                            const uint8_t *base = (const uint8_t *)(sect[k].addr + slide);
                            size_t size = sect[k].size;
                            if (haveWK)  ci_patchStringInRange(base, size, "AppleWebKit/605.1.15", repWK);
                            if (haveVer) {
                                ci_patchStringInRange(base, size, "Version/16.6.1", repVer);
                                ci_patchStringInRange(base, size, "16.6.1", repVerBare);
                            }
                            if (haveMob)       ci_patchStringInRange(base, size, "Mobile/15E148", repMob);
                            if (haveSafariWK)  ci_patchStringInRange(base, size, "Safari/604.1", repSafariWK);
                        }
                    }
                }
            }
            lc = (const struct load_command *)((uintptr_t)lc + lc->cmdsize);
        }
    }
    ci_safariMark("ua_patch_pass_done");
}

__attribute__((constructor(101)))
static void ci_safari_early_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        if (![bid isEqualToString:@"com.apple.mobilesafari"] &&
            ![bid hasPrefix:@"com.apple.WebKit"]) {
            return;
        }
        ci_safariMark("early_ctor_entered");

        // Install only the critical CF hook EARLY (before WebKit cache)
        void *sysVerSym = dlsym(RTLD_DEFAULT, "_CFCopySystemVersionDictionary");
        if (sysVerSym && !orig__CFCopySystemVersionDictionary) {
            MSHookFunction(sysVerSym, (void *)hooked__CFCopySystemVersionDictionary,
                           (void **)&orig__CFCopySystemVersionDictionary);
            if (orig__CFCopySystemVersionDictionary) ci_safariMark("early_cf_sysver_installed");
        }
        void *servVerSym = dlsym(RTLD_DEFAULT, "_CFCopyServerVersionDictionary");
        if (servVerSym && !orig__CFCopyServerVersionDictionary) {
            MSHookFunction(servVerSym, (void *)hooked__CFCopyServerVersionDictionary,
                           (void **)&orig__CFCopyServerVersionDictionary);
            if (orig__CFCopyServerVersionDictionary) ci_safariMark("early_cf_servver_installed");
        }
        // Pre-load config so hook returns valid value on FIRST call
        (void)ci_safariConfigString(@"systemVersion");

        // v2.5.15: scan + patch UA string literals in WebKit memory.
        // This is what market tools do but in-memory (no disk patch +
        // trustcache hassle).
        ci_patchUAStringsInAllImages();
    }
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
        // v2.5.10: NSProcessInfo.operatingSystemVersionString swizzle.
        ci_swizzleProcessInfo();
        // v2.5.14: WKWebView UA-getters + NSURLRequest header readback.
        ci_swizzleAllUAGetters();
        // v2.5.18: NSBundle.objectForInfoDictionaryKey for Safari version
        ci_swizzleNSBundle();
        // v2.5.19: CFBundleGetValueForInfoDictionaryKey low-level CF hook
        void *cfbSym = dlsym(RTLD_DEFAULT, "CFBundleGetValueForInfoDictionaryKey");
        if (cfbSym && !orig_CFBundleGetValueForInfoDictionaryKey) {
            MSHookFunction(cfbSym, (void *)hooked_CFBundleGetValueForInfoDictionaryKey,
                           (void **)&orig_CFBundleGetValueForInfoDictionaryKey);
            if (orig_CFBundleGetValueForInfoDictionaryKey) ci_safariMark("cfbundle_get_installed");
        }
        // v2.5.22: CFBundleGetVersionNumber (BCD UInt32)
        void *vnSym = dlsym(RTLD_DEFAULT, "CFBundleGetVersionNumber");
        if (vnSym && !orig_CFBundleGetVersionNumber) {
            MSHookFunction(vnSym, (void *)hooked_CFBundleGetVersionNumber,
                           (void **)&orig_CFBundleGetVersionNumber);
            if (orig_CFBundleGetVersionNumber) ci_safariMark("cfbundle_vernum_installed");
        }
        // v2.5.22: CFBundleCopyVersionString (CFStringRef)
        void *vsSym = dlsym(RTLD_DEFAULT, "CFBundleCopyVersionString");
        if (vsSym && !orig_CFBundleCopyVersionString) {
            MSHookFunction(vsSym, (void *)hooked_CFBundleCopyVersionString,
                           (void **)&orig_CFBundleCopyVersionString);
            if (orig_CFBundleCopyVersionString) ci_safariMark("cfbundle_copyverstr_installed");
        }

        // v2.5.23: NSMutableURLRequest setValue/addValue SETTER hooks +
        // CFHTTPMessageSetHeaderFieldValue (CFNetwork layer). Rewrites
        // the User-Agent header at the LAST gate before the request
        // goes out — works even if WebKit built UA via an unhooked path.
        ci_swizzleNSURLReqSetters();
        void *cfMsgSym = dlsym(RTLD_DEFAULT, "CFHTTPMessageSetHeaderFieldValue");
        if (cfMsgSym && !orig_CFHTTPMessageSetHeaderFieldValue) {
            MSHookFunction(cfMsgSym, (void *)hooked_CFHTTPMessageSetHeaderFieldValue,
                           (void **)&orig_CFHTTPMessageSetHeaderFieldValue);
            if (orig_CFHTTPMessageSetHeaderFieldValue) ci_safariMark("cfhttpmsg_set_installed");
        }

        // (4) v2.5.7: pre-build fake SystemVersion.plist + hook open()
        // to redirect. WebKit may read this plist directly via
        // _CFCopySystemVersionDictionary to build UA.
        // v2.5.9: hook CF version-dict APIs directly (safer than open()).
        void *sysVerSym = dlsym(RTLD_DEFAULT, "_CFCopySystemVersionDictionary");
        if (sysVerSym && !orig__CFCopySystemVersionDictionary) {
            MSHookFunction(sysVerSym, (void *)hooked__CFCopySystemVersionDictionary,
                           (void **)&orig__CFCopySystemVersionDictionary);
            if (orig__CFCopySystemVersionDictionary) ci_safariMark("cf_sysver_installed");
            else                                     ci_safariMark("cf_sysver_failed");
        } else {
            ci_safariMark("cf_sysver_symbol_missing");
        }

        void *servVerSym = dlsym(RTLD_DEFAULT, "_CFCopyServerVersionDictionary");
        if (servVerSym && !orig__CFCopyServerVersionDictionary) {
            MSHookFunction(servVerSym, (void *)hooked__CFCopyServerVersionDictionary,
                           (void **)&orig__CFCopyServerVersionDictionary);
            if (orig__CFCopyServerVersionDictionary) ci_safariMark("cf_servver_installed");
            else                                     ci_safariMark("cf_servver_failed");
        } else {
            ci_safariMark("cf_servver_symbol_missing");
        }

        NSLog(@"[ChangeInfoIosSafari] sysctl + MG + UIDevice + open(SysVer) hooked in %@", bid);
    }
}
