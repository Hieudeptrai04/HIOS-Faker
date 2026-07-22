// ChangeInfoIosCT v4.0.0 beta
//
// Carrier companion tweak. The old v3 CT target was a no-op stub filtered only
// to CommCenter, so apps that read CTCarrier directly could still see the real
// carrier. This hook returns the carrier fields from the shared HIOS config for
// app-side CoreTelephony reads, with daemon executables kept in the filter as a
// best-effort fallback.

#import <Foundation/Foundation.h>
#import <unistd.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <notify.h>
#import <time.h>
#import <os/lock.h>

static NSString *const kConfigPath = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kReloadNote = @"com.changeinfoios.v3/ReloadConfig";
static NSString *const kLegacyNote = @"com.changeinfoios/ReloadConfig";
static NSString *const kAppNote    = @"com.changeinfoios/ReloadPrefs";

static NSDictionary *g_config = nil;
static dispatch_once_t g_loadOnce;
// g_config is reassigned from the main-queue reload notifications while CT
// getters read it on arbitrary host-app threads. Under ARC the reassignment
// releases the previous dictionary, so a concurrent reader could retain an
// object whose dealloc has begun (UAF / torn pointer). Serialize both sides
// with a lock and hand readers a +1-retained snapshot taken under the lock.
static os_unfair_lock g_cfgLock = OS_UNFAIR_LOCK_INIT;

static void reloadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath] ?: @{};
    os_unfair_lock_lock(&g_cfgLock);
    g_config = d;
    os_unfair_lock_unlock(&g_cfgLock);
}

static inline NSDictionary *cfg(void) {
    dispatch_once(&g_loadOnce, ^{ reloadConfig(); });
    os_unfair_lock_lock(&g_cfgLock);
    NSDictionary *snapshot = g_config;   // ARC retains while we hold the lock
    os_unfair_lock_unlock(&g_cfgLock);
    return snapshot;                      // caller owns its own strong ref
}

static inline NSString *cfgStr(NSString *key) {
    id v = cfg()[key];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    return nil;
}

static inline NSString *firstCfgStr(NSArray<NSString *> *keys) {
    for (NSString *k in keys) {
        NSString *v = cfgStr(k);
        if (v.length) return v;
    }
    return nil;
}

static inline BOOL hasCarrierConfig(void) {
    return cfgStr(@"carrierName").length ||
           cfgStr(@"carrierMCC").length ||
           cfgStr(@"carrierMNC").length ||
           cfgStr(@"carrierISO").length;
}

static NSString *fakeRadioTech(void) {
    NSString *v = firstCfgStr(@[@"carrierRadioAccess", @"radioAccessTechnology"]);
    if (!v.length) return nil;
    if ([v hasPrefix:@"CTRadioAccessTechnology"]) return v;
    NSString *upper = [v uppercaseString];
    if ([upper isEqualToString:@"NR"] || [upper isEqualToString:@"5G"]) {
        return @"CTRadioAccessTechnologyNR";
    }
    if ([upper isEqualToString:@"NRNSA"] || [upper isEqualToString:@"5GNSA"]) {
        return @"CTRadioAccessTechnologyNRNSA";
    }
    if ([upper isEqualToString:@"LTE"] || [upper isEqualToString:@"4G"]) {
        return @"CTRadioAccessTechnologyLTE";
    }
    if ([upper isEqualToString:@"WCDMA"] || [upper isEqualToString:@"3G"]) {
        return @"CTRadioAccessTechnologyWCDMA";
    }
    return v;
}

%hook CTCarrier

- (NSString *)carrierName {
    return cfgStr(@"carrierName") ?: %orig;
}

- (NSString *)mobileCountryCode {
    return firstCfgStr(@[@"carrierMCC", @"MobileSubscriberCountryCode"]) ?: %orig;
}

- (NSString *)mobileNetworkCode {
    return firstCfgStr(@[@"carrierMNC", @"MobileSubscriberNetworkCode"]) ?: %orig;
}

- (NSString *)isoCountryCode {
    NSString *iso = firstCfgStr(@[@"carrierISO", @"RegionCode"]);
    return iso.length ? [iso lowercaseString] : %orig;
}

- (BOOL)allowsVOIP {
    return hasCarrierConfig() ? YES : %orig;
}

%end

%hook CTTelephonyNetworkInfo

- (NSString *)currentRadioAccessTechnology {
    return fakeRadioTech() ?: %orig;
}

- (NSDictionary *)serviceCurrentRadioAccessTechnology {
    NSString *v = fakeRadioTech();
    if (!v.length) return %orig;

    NSDictionary *orig = %orig;
    if ([orig isKindOfClass:[NSDictionary class]] && orig.count > 0) {
        NSMutableDictionary *d = [orig mutableCopy];
        for (NSString *k in orig) d[k] = v;
        return [d copy];
    }
    return @{@"0000000100000001": v};
}

- (NSString *)dataServiceIdentifier {
    NSString *orig = %orig;
    if (orig.length) return orig;
    return (hasCarrierConfig() || fakeRadioTech().length) ? @"0000000100000001" : orig;
}

%end

static void notify_cb(int token) {
    (void)token;
    reloadConfig();
}

%ctor {
    @autoreleasepool {
        reloadConfig();

        int t1 = 0, t2 = 0, t3 = 0;
        notify_register_dispatch([kReloadNote UTF8String], &t1,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });
        notify_register_dispatch([kLegacyNote UTF8String], &t2,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });
        notify_register_dispatch([kAppNote UTF8String], &t3,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });

        // Stealth (4.0.11): only drop the load-marker when debugging is enabled.
        if (access("/var/jb/etc/changeinfoios/.debug", F_OK) == 0) {
            NSString *exec = [[NSProcessInfo processInfo] processName] ?: @"?";
            NSString *body = [NSString stringWithFormat:@"%@ %ld carrier=%@/%@/%@\n",
                              exec, (long)time(NULL),
                              cfgStr(@"carrierName") ?: @"",
                              cfgStr(@"carrierMCC") ?: @"",
                              cfgStr(@"carrierMNC") ?: @""];
            [body writeToFile:@"/var/jb/etc/changeinfoios/v3_ct_loaded.txt"
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:nil];
        }
    }
}
