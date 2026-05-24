// ChangeInfoIosMG v3.0.0 — single mobilegestaltd hook
//
// Hosts: /usr/libexec/MobileGestaltHelper (the iOS daemon every app's
// libMobileGestalt.dylib XPCs to for uncached MG keys). By owning the
// daemon's MGCopyAnswer return path, we spoof device identity for every
// app that calls MGCopyAnswer / MGGetStringAnswer / MGGetBoolAnswer —
// without injecting a single byte into Zalo / Facebook / TikTok / etc.
//
// Per-call cost in target apps: ZERO (no dylib loaded there).
// Per-call cost inside MobileGestaltHelper: 1 dict lookup (~50 ns) +
// cached spoof string return. Daemon is lightly loaded so it absorbs
// this fine — apps see native-speed reads.
//
// Hot-reload: host app posts Darwin notify
// com.changeinfoios.v3/ReloadConfig → we re-read config.plist.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <substrate.h>
#import <string.h>
#import <time.h>

#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

// ============================================================
// Config — single binary plist shared with host app
// ============================================================
static NSDictionary *gCfg = nil;
static NSDictionary *gMGMap = nil;    // iOS-key → config-key
static NSSet      *gBoolKeys = nil;   // keys the host stores as NSNumber-bool
static dispatch_queue_t gCfgQ = NULL;

static void reloadCfg(void) {
    @autoreleasepool {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                           @"/var/jb/etc/changeinfoios/config.plist"];
        if (d) gCfg = [d copy];
        NSLog(@"[ChangeInfoIosMG] reloadCfg: %lu keys", (unsigned long)(gCfg ? gCfg.count : 0));
    }
}

static void onPrefsNotify(CFNotificationCenterRef c, void *o, CFStringRef n,
                          const void *obj, CFDictionaryRef ui) {
    if (gCfgQ) dispatch_async(gCfgQ, ^{ reloadCfg(); });
    else       reloadCfg();
}

// ============================================================
// iOS MG key → host config key mapping
//
// Trimmed v2.6.6 — drops every key that returns NSNumber / CFBoolean /
// CFArray / CFDate from MGCopyAnswer (those go via MGGetBoolAnswer or
// would need typed wrappers). Crash class fixed: returning wrong type
// breaks Apple Pay's CFURLRequestSetHTTPHeaderFieldValue in Settings.app.
// ============================================================
static void buildMaps(void) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        gMGMap = @{
            // Identity (Section 3.1 of PLAN.md)
            @"UniqueDeviceID":                          @"UniqueDeviceID",
            @"SerialNumber":                            @"SerialNumber",
            @"InternationalMobileEquipmentIdentity":    @"InternationalMobileEquipmentIdentity",
            @"InternationalMobileEquipmentIdentity2":   @"InternationalMobileEquipmentIdentity2",
            @"MobileEquipmentIdentifier":               @"MobileEquipmentIdentifier",
            @"IntegratedCircuitCardIdentity":           @"IntegratedCircuitCardIdentity",
            @"IntegratedCircuitCardIdentity2":          @"IntegratedCircuitCardIdentity2",
            @"PhoneNumber":                             @"PhoneNumber",
            // Model (Section 3.2)
            @"ProductType":                             @"ProductType",
            @"HardwareModel":                           @"HardwareModel",
            @"HWModelStr":                              @"HWModelStr",
            @"ModelNumber":                             @"ModelNumber",
            @"MarketingName":                           @"MarketingName",
            @"DeviceName":                              @"DeviceNameMG",
            @"UserAssignedDeviceName":                  @"UserAssignedDeviceName",
            @"DeviceClass":                             @"DeviceClass",
            // OS (Section 3.3)
            @"ProductVersion":                          @"ProductVersion",
            @"ProductVersionString":                    @"ProductVersion",
            @"BuildVersion":                            @"BuildVersion",
            @"ProductBuildVersion":                     @"BuildVersion",
            // Region (Section 3.5)
            @"RegionCode":                              @"RegionCode",
            @"RegionInfo":                              @"RegionInfo",
            @"MobileSubscriberCountryCode":             @"MobileSubscriberCountryCode",
            @"MobileSubscriberNetworkCode":             @"MobileSubscriberNetworkCode",
            @"SIMTrayStatus":                           @"SIMTrayStatus",
            // MAC (Section 3.6)
            @"WiFiAddress":                             @"WiFiAddress",
            @"BluetoothAddress":                        @"BluetoothAddress",
            @"EthernetAddress":                         @"EthernetAddress",
            // Colors
            @"DeviceColor":                             @"DeviceColor",
            @"DeviceEnclosureColor":                    @"DeviceEnclosureColor",
        };
        gBoolKeys = [NSSet setWithArray:@[
            // Hardware capability bools (Section 3.4) — returned by
            // MGGetBoolAnswer not MGCopyAnswer. Map kept separate so
            // MGCopyAnswer hook never wrongly returns NSNumber-bool to
            // a caller expecting NSString (Apple Pay forwarding crash).
            @"HasFaceID", @"HasTouchID", @"HasNFC", @"HasOLEDDisplay",
            @"HasHomeButton", @"HasCellularConnectivity", @"HasBaseband",
            @"HasMesa", @"Has5GUW",
        ]];
    });
}

// ============================================================
// Re-entrancy guard — MGCopyAnswer is reentrant from CFString /
// NSLog / CoreFoundation internals. Guard via __thread bool.
// ============================================================
static __thread int g_inMG = 0;

// ============================================================
// MGCopyAnswer hook — string-typed answer set
// ============================================================
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef);
typedef CFTypeRef (*MGGetStringAnswer_t)(CFStringRef);
typedef BOOL      (*MGGetBoolAnswer_t)(CFStringRef);

static MGCopyAnswer_t      orig_MGCopyAnswer      = NULL;
static MGGetStringAnswer_t orig_MGGetStringAnswer = NULL;
static MGGetBoolAnswer_t   orig_MGGetBoolAnswer   = NULL;

static CFTypeRef hooked_MGCopyAnswer(CFStringRef property) {
    if (g_inMG || !orig_MGCopyAnswer) return orig_MGCopyAnswer ? orig_MGCopyAnswer(property) : NULL;
    if (!gCfg || !property)            return orig_MGCopyAnswer(property);

    g_inMG = 1;
    buildMaps();
    NSString *key = (__bridge NSString *)property;
    NSString *cfgKey = gMGMap[key];
    CFTypeRef result = NULL;
    if (cfgKey) {
        id v = gCfg[cfgKey];
        if (v) {
            NSString *s = [v isKindOfClass:[NSString class]] ? v : [NSString stringWithFormat:@"%@", v];
            if (s.length) result = (__bridge_retained CFTypeRef)s;
        }
    }
    g_inMG = 0;
    return result ?: orig_MGCopyAnswer(property);
}

static CFTypeRef hooked_MGGetStringAnswer(CFStringRef property) {
    if (g_inMG || !orig_MGGetStringAnswer) return orig_MGGetStringAnswer ? orig_MGGetStringAnswer(property) : NULL;
    if (!gCfg || !property)                return orig_MGGetStringAnswer(property);

    g_inMG = 1;
    buildMaps();
    NSString *key = (__bridge NSString *)property;
    NSString *cfgKey = gMGMap[key];
    CFTypeRef result = NULL;
    if (cfgKey) {
        id v = gCfg[cfgKey];
        if ([v isKindOfClass:[NSString class]] && [v length]) {
            result = (__bridge_retained CFTypeRef)v;
        }
    }
    g_inMG = 0;
    return result ?: orig_MGGetStringAnswer(property);
}

static BOOL hooked_MGGetBoolAnswer(CFStringRef property) {
    if (g_inMG || !orig_MGGetBoolAnswer) return orig_MGGetBoolAnswer ? orig_MGGetBoolAnswer(property) : NO;
    if (!gCfg || !property)              return orig_MGGetBoolAnswer(property);

    g_inMG = 1;
    buildMaps();
    NSString *key = (__bridge NSString *)property;
    BOOL out = NO; BOOL hit = NO;
    if ([gBoolKeys containsObject:key]) {
        id v = gCfg[key];
        if (v) {
            hit = YES;
            if ([v respondsToSelector:@selector(boolValue)]) out = [v boolValue];
        }
    }
    g_inMG = 0;
    return hit ? out : orig_MGGetBoolAnswer(property);
}

static void installHooks(void) {
    void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!h) {
        NSLog(@"[ChangeInfoIosMG] dlopen libMobileGestalt FAILED");
        return;
    }
    orig_MGCopyAnswer      = (MGCopyAnswer_t)      dlsym(h, "MGCopyAnswer");
    orig_MGGetStringAnswer = (MGGetStringAnswer_t) dlsym(h, "MGGetStringAnswer");
    orig_MGGetBoolAnswer   = (MGGetBoolAnswer_t)   dlsym(h, "MGGetBoolAnswer");

    if (orig_MGCopyAnswer)
        MSHookFunction((void *)orig_MGCopyAnswer,
                       (void *)hooked_MGCopyAnswer,
                       (void **)&orig_MGCopyAnswer);
    if (orig_MGGetStringAnswer)
        MSHookFunction((void *)orig_MGGetStringAnswer,
                       (void *)hooked_MGGetStringAnswer,
                       (void **)&orig_MGGetStringAnswer);
    if (orig_MGGetBoolAnswer)
        MSHookFunction((void *)orig_MGGetBoolAnswer,
                       (void *)hooked_MGGetBoolAnswer,
                       (void **)&orig_MGGetBoolAnswer);

    NSLog(@"[ChangeInfoIosMG] hooks installed (copy=%p getStr=%p getBool=%p)",
          orig_MGCopyAnswer, orig_MGGetStringAnswer, orig_MGGetBoolAnswer);
}

// ============================================================
// ctor — fires on dyld load into MobileGestaltHelper
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        NSString *exec = [[NSProcessInfo processInfo] processName] ?: @"unknown";
        NSLog(@"[ChangeInfoIosMG] %ctor in bid=%@ exec=%@", bid, exec);

        gCfgQ = dispatch_queue_create("com.changeinfoios.mg.cfg", DISPATCH_QUEUE_SERIAL);
        reloadCfg();
        installHooks();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, onPrefsNotify, CFSTR("com.changeinfoios.v3/ReloadConfig"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);

        // Marker so we can SSH-verify the dylib actually loaded
        NSString *marker = @"/var/jb/etc/changeinfoios/v3_mg_loaded.txt";
        NSString *body = [NSString stringWithFormat:@"%@\n%@\n%ld\n", bid, exec, (long)time(NULL)];
        [body writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
