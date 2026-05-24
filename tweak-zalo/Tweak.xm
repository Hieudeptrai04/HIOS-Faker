// ChangeInfoIosZalo.dylib — v2.6.1
//
// Ultra-thin device-info sidecar. Originally Zalo-only (v2.6.0), now
// promoted to handle EVERY user-selected target app (Facebook, TikTok,
// banking, etc.) — same smooth performance, no C-level hooks, no app
// mutation. The "Zalo" name is kept as folder/dylib filename for build-
// chain continuity; the dylib itself is generic.
//
// Each %hook getter follows this pattern:
//
//     - (T)foo {
//         if (!LAYER("name")) return %orig;
//         static T cached;
//         static uint8_t valid = 0;
//         if (!valid) {
//             if (!gCfg) return %orig;            // config not yet loaded
//             cached = compute_spoof_value();      // uses gCfg
//             valid = 1;
//         }
//         return cached;
//     }
//
// IMPORTANT — why NOT dispatch_once:
//   Logos %hook IMPs are swapped during dyld initializer phase, BEFORE
//   our %ctor block runs (where gCfg is loaded). iOS's UIKit reads
//   UIDevice.name immediately at app launch during UIScene setup; if
//   that read fires our hook before gCfg loaded, dispatch_once would
//   capture the nil result and never re-evaluate. With the atomic
//   `valid` flag we just bail to %orig until gCfg is non-nil, then
//   cache on the first call AFTER load.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static NSDictionary *gCfg = nil;

static NSString *cs(NSString *k) {
    id v = gCfg[k];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static BOOL cb(NSString *k) {
    id v = gCfg[k];
    if (!v && [k hasPrefix:@"fake_"]) return YES;   // default-on for fake_*
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}
static id cg(NSString *k) { return gCfg[k]; }
static NSUInteger cu(NSString *k) {
    id v = gCfg[k];
    if ([v isKindOfClass:[NSNumber class]]) return [v unsignedIntegerValue];
    if ([v isKindOfClass:[NSString class]]) return (NSUInteger)[v longLongValue];
    return 0;
}
static unsigned long long cull(NSString *k) {
    id v = gCfg[k];
    if ([v isKindOfClass:[NSNumber class]]) return [v unsignedLongLongValue];
    if ([v isKindOfClass:[NSString class]]) return (unsigned long long)[v longLongValue];
    return 0;
}

#define LAYER(name)  cb(@"fake_" name)

// ============================================================
// UIDevice — top-level Obj-C device info
// ============================================================
%hook UIDevice

- (NSString *)name {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = [cs(@"deviceName") copy]; valid = 1; }
    return c ?: %orig;
}
- (NSString *)model {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = [cs(@"deviceModel") copy]; valid = 1; }
    return c ?: %orig;
}
- (NSString *)localizedModel {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = [cs(@"localizedModel") copy]; valid = 1; }
    return c ?: %orig;
}
- (NSString *)systemName {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = [cs(@"systemName") copy]; valid = 1; }
    return c ?: %orig;
}
- (NSString *)systemVersion {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = [cs(@"systemVersion") copy]; valid = 1; }
    return c ?: %orig;
}
- (NSUUID *)identifierForVendor {
    if (!LAYER("uiddevice")) return %orig;
    static NSUUID *c = nil; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        NSString *s = cs(@"identifierForVendor");
        if (s) c = [[NSUUID alloc] initWithUUIDString:s];
        valid = 1;
    }
    return c ?: %orig;
}

- (BOOL)isMultitaskingSupported { if (LAYER("uiddevice")) return YES; return %orig; }
- (UIUserInterfaceIdiom)userInterfaceIdiom {
    if (LAYER("uiddevice")) return UIUserInterfaceIdiomPhone;
    return %orig;
}
- (BOOL)proximityState               { if (LAYER("uiddevice")) return NO; return %orig; }
- (BOOL)isProximityMonitoringEnabled { if (LAYER("uiddevice")) return NO; return %orig; }

// _deviceInfoForKey: — private UIKit hook into MGCopyAnswer. Hit ONCE
// per SDK init by Crashlytics / AppsFlyer / Firebase / Adjust to pull
// UDID / Serial / IMEI / HardwareModel / WiFi MAC. Pre-build a static
// {iOSKey: configKey} map once; per-call cost is dict lookup + cached
// gCfg fetch.
- (id)_deviceInfoForKey:(NSString *)key {
    if (!LAYER("hardware") || !key) return %orig;
    static NSDictionary *map = nil; static uint8_t mvalid = 0;
    if (!mvalid) {
        map = @{
            @"ProductType":                          @"ProductType",
            @"HardwareModel":                        @"HardwareModel",
            @"SerialNumber":                         @"SerialNumber",
            @"UniqueDeviceID":                       @"UniqueDeviceID",
            @"UniqueDeviceIDData":                   @"UniqueDeviceID",
            @"UniqueChipID":                         @"UniqueChipID",
            @"InternationalMobileEquipmentIdentity": @"InternationalMobileEquipmentIdentity",
            @"InternationalMobileEquipmentIdentity2":@"InternationalMobileEquipmentIdentity2",
            @"IntegratedCircuitCardIdentity":        @"IntegratedCircuitCardIdentity",
            @"WiFiAddress":                          @"WiFiAddress",
            @"BluetoothAddress":                     @"BluetoothAddress",
            @"EthernetMacAddress":                   @"EthernetAddress",
        };
        mvalid = 1;
    }
    NSString *configKey = map[key];
    if (configKey) {
        NSString *v = cs(configKey);
        if (v.length) return v;
    }
    return %orig;
}

%end

// ============================================================
// NSProcessInfo — OS version + host name + processor + memory
// ============================================================
%hook NSProcessInfo

- (NSString *)hostName {
    if (!LAYER("processinfo")) return %orig;
    static NSString *c = nil; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = [cs(@"processHostName") copy]; valid = 1; }
    return c ?: %orig;
}
- (NSUInteger)processorCount {
    if (!LAYER("processinfo")) return %orig;
    static NSUInteger c = 0; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = cu(@"processorCount"); valid = 1; }
    return c ?: %orig;
}
- (unsigned long long)physicalMemory {
    if (!LAYER("processinfo")) return %orig;
    static unsigned long long c = 0; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = cull(@"physicalMemory"); valid = 1; }
    return c ?: %orig;
}
- (NSOperatingSystemVersion)operatingSystemVersion {
    NSOperatingSystemVersion real = %orig;
    if (!LAYER("processinfo")) return real;
    NSString *ver = cs(@"systemVersion");
    if (!ver) return real;
    NSArray *parts = [ver componentsSeparatedByString:@"."];
    if (parts.count == 0) return real;
    NSInteger spoofedMajor = [parts[0] integerValue];
    // SAFETY: never lie about MAJOR version; UIKit gates iOS-16-only APIs
    // behind majorVersion>=16 and scene init throws if we claim iOS 14.
    if (spoofedMajor != real.majorVersion) return real;
    NSOperatingSystemVersion v;
    v.majorVersion = spoofedMajor;
    v.minorVersion = parts.count > 1 ? [parts[1] integerValue] : 0;
    v.patchVersion = parts.count > 2 ? [parts[2] integerValue] : 0;
    return v;
}
- (NSProcessInfoThermalState)thermalState {
    if (LAYER("processinfo")) return NSProcessInfoThermalStateNominal;
    return %orig;
}
- (BOOL)isLowPowerModeEnabled {
    if (LAYER("processinfo")) return NO;
    return %orig;
}

%end

// ============================================================
// ASIdentifierManager — IDFA
// ============================================================
%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    if (!LAYER("ads")) return %orig;
    static NSUUID *c = nil; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        NSString *s = cs(@"advertisingIdentifier");
        if (s) c = [[NSUUID alloc] initWithUUIDString:s];
        valid = 1;
    }
    return c ?: %orig;
}
- (BOOL)isAdvertisingTrackingEnabled {
    if (!LAYER("ads")) return %orig;
    id v = cg(@"isAdvertisingTrackingEnabled");
    if (v) return [v boolValue];
    return %orig;
}
%end

// ============================================================
// ATTrackingManager — iOS 14+ tracking permission. Spoof Authorized
// so SDKs go through normal tracking path (IDFA non-zero).
// ============================================================
%hook ATTrackingManager
+ (ATTrackingManagerAuthorizationStatus)trackingAuthorizationStatus {
    if (!LAYER("ads")) return %orig;
    return ATTrackingManagerAuthorizationStatusAuthorized;
}
+ (void)requestTrackingAuthorizationWithCompletionHandler:(void(^)(ATTrackingManagerAuthorizationStatus))completion {
    if (!LAYER("ads")) { %orig; return; }
    if (completion) completion(ATTrackingManagerAuthorizationStatusAuthorized);
}
%end

// ============================================================
// UIScreen — HOTTEST path on scroll, cached at first call.
// ============================================================
%hook UIScreen

- (CGRect)bounds {
    if (!LAYER("screen")) return %orig;
    static CGRect c = {{0,0},{0,0}}; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        id w = cg(@"screenWidth"); id h = cg(@"screenHeight");
        if (w && h) c = CGRectMake(0, 0, [w floatValue], [h floatValue]);
        valid = 1;
    }
    if (c.size.width > 0) return c;
    return %orig;
}
- (CGRect)nativeBounds {
    if (!LAYER("screen")) return %orig;
    static CGRect c = {{0,0},{0,0}}; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        id w = cg(@"nativeScreenWidth"); id h = cg(@"nativeScreenHeight");
        if (w && h) {
            c = CGRectMake(0, 0, [w floatValue], [h floatValue]);
        } else {
            id bw = cg(@"screenWidth"); id bh = cg(@"screenHeight"); id sc = cg(@"screenScale");
            if (bw && bh && sc) {
                CGFloat s = [sc floatValue];
                c = CGRectMake(0, 0, [bw floatValue] * s, [bh floatValue] * s);
            }
        }
        valid = 1;
    }
    if (c.size.width > 0) return c;
    return %orig;
}
- (CGFloat)scale {
    if (!LAYER("screen")) return %orig;
    static CGFloat c = 0; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        id v = cg(@"screenScale"); if (v) c = [v floatValue];
        valid = 1;
    }
    if (c > 0) return c;
    return %orig;
}
- (CGFloat)nativeScale {
    if (!LAYER("screen")) return %orig;
    static CGFloat c = 0; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        id v = cg(@"nativeScale"); if (!v) v = cg(@"screenScale");
        if (v) c = [v floatValue];
        valid = 1;
    }
    if (c > 0) return c;
    return %orig;
}

%end

// ============================================================
// NSLocale / NSTimeZone
// ============================================================
%hook NSLocale
+ (NSLocale *)currentLocale {
    if (!LAYER("locale")) return %orig;
    static NSLocale *c = nil; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        NSString *s = cs(@"localeIdentifier");
        if (s) c = [[NSLocale alloc] initWithLocaleIdentifier:s];
        valid = 1;
    }
    return c ?: %orig;
}
%end

%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    if (!LAYER("locale2")) return %orig;
    static NSTimeZone *c = nil; static uint8_t valid = 0;
    if (!valid) {
        if (!gCfg) return %orig;
        NSString *s = cs(@"timeZoneName");
        if (s) c = [NSTimeZone timeZoneWithName:s];
        valid = 1;
    }
    return c ?: %orig;
}
+ (NSTimeZone *)defaultTimeZone {
    if (!LAYER("locale2")) return %orig;
    return [NSTimeZone systemTimeZone];
}
%end

// ============================================================
// CTCarrier — carrier identity (Viettel / Vinaphone / Mobifone)
// ============================================================
%hook CTCarrier
- (NSString *)carrierName {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierName"); return v ?: %orig;
}
- (NSString *)mobileCountryCode {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierMCC"); return v ?: %orig;
}
- (NSString *)mobileNetworkCode {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierMNC"); return v ?: %orig;
}
- (NSString *)isoCountryCode {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierISO"); return v ?: %orig;
}
- (BOOL)allowsVOIP {
    if (LAYER("uiddevice")) return YES;
    return %orig;
}
%end

// ============================================================
// CTTelephonyNetworkInfo — radio access tech (LTE / 5G / WCDMA)
// ============================================================
%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static uint8_t valid = 0;
    if (!valid) { if (!gCfg) return %orig; c = [cs(@"carrierRadioAccess") copy]; valid = 1; }
    return c ?: %orig;
}
%end

// ============================================================
// AVCaptureDevice — camera ID (QR scan / selfie eKYC fingerprint)
// ============================================================
%hook AVCaptureDevice
- (NSString *)uniqueID {
    if (!LAYER("hardware")) return %orig;
    NSString *spoof = cs(@"AVCaptureDeviceUniqueID");
    if (!spoof.length) return %orig;
    @try {
        NSInteger pos = (NSInteger)[self position];
        if (pos == 2) return [spoof stringByAppendingString:@":F"];   // Front
        if (pos == 1) return [spoof stringByAppendingString:@":B"];   // Back
    } @catch (__unused id e) {}
    return spoof;
}
- (NSString *)modelID {
    if (!LAYER("hardware")) return %orig;
    NSString *pt = cs(@"ProductType");
    if (!pt.length) return %orig;
    @try {
        NSInteger pos = (NSInteger)[self position];
        const char *side = (pos == 2) ? "front" : "back";
        return [NSString stringWithFormat:
                @"com.apple.avfoundation.avcapturedevice.built-in_video:%s:%@", side, pt];
    } @catch (__unused id e) {}
    return [NSString stringWithFormat:
            @"com.apple.avfoundation.avcapturedevice.built-in_video:%@", pt];
}
%end

// ============================================================
// CTOR — load config + register reload observer.
// Logos %hook IMPs were already swapped before we get here; the hooks
// bail to %orig on nil gCfg and cache on the first call after gCfg is
// non-nil. Subsequent reload (Darwin notify from host) drops gCfg and
// invalidates static caches via gen counter? — actually we use a
// per-process atomic flag, simpler: ReloadPrefs just rewrites gCfg
// and apps cold-restart anyway after Change Device (host kills them).
// ============================================================
static void reloadCfg(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                       @"/var/jb/etc/changeinfoios/config.plist"];
    if (!d) {
        d = [NSDictionary dictionaryWithContentsOfFile:
             @"/var/mobile/Library/Preferences/com.changeinfoios.plist"];
    }
    if (d) gCfg = d;
}

static void onPrefsNotify(CFNotificationCenterRef c, void *o, CFStringRef n,
                          const void *obj, CFDictionaryRef ui) {
    reloadCfg();
    NSLog(@"[ChangeInfoIosZalo] config reloaded (%lu keys)",
          (unsigned long)(gCfg ? gCfg.count : 0));
}

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        // No hard-coded bundle allowlist anymore — the plist filter
        // (managed by the host app's ci_syncSidecarFilterForApps) is the
        // single source of truth for which apps we load into.
        reloadCfg();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, onPrefsNotify, CFSTR("com.changeinfoios/ReloadPrefs"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        NSLog(@"[ChangeInfoIosZalo] Loaded into %@, cfg keys=%lu",
              bid, (unsigned long)(gCfg ? gCfg.count : 0));
    }
}
