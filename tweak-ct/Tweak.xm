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
#import <stdio.h>
#import <string.h>
#import <os/lock.h>
#import <CommonCrypto/CommonCrypto.h>

static NSString *const kConfigPath = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kReloadNote = @"com.changeinfoios.v3/ReloadConfig";
static NSString *const kLegacyNote = @"com.changeinfoios/ReloadConfig";
static NSString *const kAppNote    = @"com.changeinfoios/ReloadPrefs";

static NSDictionary *g_config = nil;
static int g_licOK = 0;
static int g_targetOK = 0;
static dispatch_once_t g_loadOnce;
// g_config is reassigned from the main-queue reload notifications while CT
// getters read it on arbitrary host-app threads. Under ARC the reassignment
// releases the previous dictionary, so a concurrent reader could retain an
// object whose dealloc has begun (UAF / torn pointer). Serialize both sides
// with a lock and hand readers a +1-retained snapshot taken under the lock.
static os_unfair_lock g_cfgLock = OS_UNFAIR_LOCK_INIT;

// ZCH-10 FIX: CT was reading raw config with NO license gate, while tweak-mg
// gates every spoof on a valid signed token. When a license expired, MG fell
// back to the REAL identity but CT kept returning a FAKE carrier — a self-
// contradiction (real device id + spoofed carrier) that reads as tampering.
// Mirror tweak-mg's computeLicOK exactly (HMAC(epoch) over the shared secret;
// device-binding was reverted there to avoid a MobileGestalt re-entry deadlock)
// so both dylibs fail-closed together.
static NSString *ct_licSecret(void) {
    static NSString *s = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        static const unsigned char kS[] = {
            0x5f, 0x71, 0x0e, 0x5c, 0x66, 0x05, 0x5a, 0x6d, 0x00, 0x41, 0x6f, 0x06,
            0x47, 0x65, 0x03, 0x59, 0x7b, 0x0f, 0x40, 0x75, 0x01, 0x54, 0x63, 0x04,
            0x4e, 0x73, 0x02, 0x44, 0x70, 0x07, 0x56, 0x7d, 0x52, 0x62, 0x05, 0x5e,
            0x78, 0x0e, 0x45, 0x7c, 0x03, 0x5b, 0x7a, 0x00, 0x59, 0x67, 0x06, 0x46,
            0x61, 0x0f, 0x4f, 0x6d, 0x04, 0x55, 0x79, 0x01,
        };
        char buf[sizeof(kS) + 1];
        for (size_t i = 0; i < sizeof(kS); i++) buf[i] = kS[i] ^ 0x37;
        buf[sizeof(kS)] = 0;
        s = [NSString stringWithUTF8String:buf];
    });
    return s;
}
static int ct_computeLicOK(NSDictionary *d) {
    id tv = d[@"_ci_lic_tok"];
    if (![tv isKindOfClass:[NSString class]]) return 0;
    NSString *tok = (NSString *)tv;
    NSRange bar = [tok rangeOfString:@"|"];
    if (bar.location == NSNotFound) return 0;
    NSString *es  = [tok substringToIndex:bar.location];
    NSString *sig = [tok substringFromIndex:bar.location + 1];
    if (!es.length || !sig.length) return 0;
    if ([es longLongValue] <= (long long)time(NULL)) return 0;     // expired
    const char *k = [ct_licSecret() UTF8String];
    const char *m = [es UTF8String];
    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, k, strlen(k), m, strlen(m), mac);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + i*2, 3, "%02x", mac[i]);
    return (strcmp(hex, [sig UTF8String]) == 0) ? 1 : 0;
}

static int ct_targetsCurrentProcess(NSDictionary *d) {
    id raw = d[@"targetBundles"];
    if (![raw isKindOfClass:[NSArray class]] || [(NSArray *)raw count] == 0) return 0;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid.length) return 0;
    for (id item in (NSArray *)raw) {
        if (![item isKindOfClass:[NSString class]] || ![(NSString *)item length]) continue;
        NSString *target = (NSString *)item;
        if ([bid isEqualToString:target] ||
            [bid hasPrefix:[target stringByAppendingString:@"."]]) return 1;
    }
    return 0;
}

static void reloadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath] ?: @{};
    int ok = ct_computeLicOK(d);
    int targetOK = ct_targetsCurrentProcess(d);
    os_unfair_lock_lock(&g_cfgLock);
    g_config = d;
    g_licOK = ok;
    g_targetOK = targetOK;
    os_unfair_lock_unlock(&g_cfgLock);
}

static inline NSDictionary *cfg(void) {
    dispatch_once(&g_loadOnce, ^{ reloadConfig(); });
    os_unfair_lock_lock(&g_cfgLock);
    // Fail-closed: unlicensed → empty config → every carrier getter returns
    // %orig (real), matching tweak-mg.
    NSDictionary *snapshot = (g_licOK && g_targetOK) ? g_config : @{};
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
        if (access("/var/jb/etc/changeinfoios/.debug", F_OK) == 0 &&
            access("/var/jb/etc/changeinfoios/.debug.off", F_OK) != 0) {
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
