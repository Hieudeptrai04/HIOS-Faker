// ChangeInfoIosZalo.dylib — v2.6.3
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
#import <dlfcn.h>
#import <substrate.h>

#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

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
// MGCopyAnswer / MGGetStringAnswer / MGGetBoolAnswer
//
// COLD-PATH C-level hook. libMobileGestalt is the canonical iOS path for
// model name / serial / IMEI / build version reads. UIDevice goes through
// it internally for some keys; many SDKs (Crashlytics / AppsFlyer /
// Firebase / Adjust / Zalo anti-fraud) ALSO call MGCopyAnswer directly
// to dodge our UIDevice swizzles. Without this hook the user's Settings
// app shows the REAL "Model Name" / "Model Number" because Settings reads
// via MGCopyAnswer("MarketingName") not UIDevice.model.
//
// Performance: MGCopyAnswer is called ~50-100 times per SDK init then
// SDKs cache the result. Steady-state during chat scroll: ~0 calls.
// Adding the MSHookFunction trampoline (~10 ns/call) on a non-hot
// function does not measurably affect smoothness — verified empirically
// by the Safari sidecar which has a sysctlbyname trampoline and remains
// jank-free during full WebKit page loads.
//
// Re-entrancy guard: getConfigStr → NSString allocation → CoreFoundation
// internals → MGCopyAnswer("ProductVersion") → re-enters our hook. The
// __thread int g_inMG bool breaks the recursion.
// ============================================================
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef);
typedef BOOL      (*MGGetBoolAnswer_t)(CFStringRef);
typedef CFTypeRef (*MGGetStringAnswer_t)(CFStringRef);

static MGCopyAnswer_t       orig_MGCopyAnswer       = NULL;
static MGGetBoolAnswer_t    orig_MGGetBoolAnswer    = NULL;
static MGGetStringAnswer_t  orig_MGGetStringAnswer  = NULL;

static __thread int g_inMG = 0;

static NSDictionary *gMGMap = nil;
static void buildMGMap(void) {
    static dispatch_once_t o;
    dispatch_once(&o, ^{
        gMGMap = @{
            // String identity keys (most common fingerprint targets)
            @"UniqueDeviceID":                          @"UniqueDeviceID",
            @"SerialNumber":                            @"SerialNumber",
            @"InternationalMobileEquipmentIdentity":    @"InternationalMobileEquipmentIdentity",
            @"InternationalMobileEquipmentIdentity2":   @"InternationalMobileEquipmentIdentity2",
            @"MobileEquipmentIdentifier":               @"MobileEquipmentIdentifier",
            @"IntegratedCircuitCardIdentity":           @"IntegratedCircuitCardIdentity",
            @"IntegratedCircuitCardIdentity2":          @"IntegratedCircuitCardIdentity2",
            @"PhoneNumber":                             @"PhoneNumber",
            // Model identity (THIS is what Settings → About reads)
            @"ProductType":                             @"ProductType",
            @"HardwareModel":                           @"HardwareModel",
            @"HWModelStr":                              @"HWModelStr",
            @"ModelNumber":                             @"ModelNumber",
            @"MarketingName":                           @"MarketingName",
            @"DeviceName":                              @"DeviceNameMG",
            @"UserAssignedDeviceName":                  @"UserAssignedDeviceName",
            // Region
            @"RegionCode":                              @"RegionCode",
            @"RegionInfo":                              @"RegionInfo",
            // Network HW MACs
            @"WiFiAddress":                             @"WiFiAddress",
            @"BluetoothAddress":                        @"BluetoothAddress",
            @"EthernetAddress":                         @"EthernetAddress",
            // OS / boot / chip
            @"BuildVersion":                            @"BuildVersion",
            @"ProductBuildVersion":                     @"BuildVersion",
            @"OSBuildVersion":                          @"BuildVersion",
            @"SoftwareBundleVersion":                   @"BuildVersion",
            @"ProductVersion":                          @"ProductVersion",
            @"ProductVersionString":                    @"ProductVersion",
            @"MaxSupportedOSVersion":                   @"ProductVersion",
            @"SupportedOSVersions":                     @"ProductVersion",
            @"FirmwareVersion":                         @"FirmwareVersion",
            @"BasebandVersion":                         @"BasebandVersion",
            @"BasebandSerialNumber":                    @"BasebandSerialNumber",
            @"UniqueChipID":                            @"UniqueChipID",
            @"BoardId":                                 @"BoardId",
            @"HardwarePlatform":                        @"BoardId",
            @"ChipID":                                  @"ChipID",
            @"BootNonce":                               @"BootNonce",
            // Colors / capability strings
            @"DeviceColor":                             @"DeviceColor",
            @"DeviceEnclosureColor":                    @"DeviceEnclosureColor",
            // Disk + battery
            @"DiskUsage":                               @"DiskUsage",
            @"TotalDiskCapacity":                       @"TotalDiskCapacity",
            @"TotalSystemAvailable":                    @"TotalSystemAvailable",
            @"BatteryCurrentCapacity":                  @"BatteryCurrentCapacity",
            @"BatteryIsCharging":                       @"BatteryIsCharging",
            @"BatterySerialNumber":                     @"BatterySerialNumber",
            @"AirplaneMode":                            @"AirplaneMode",
            @"MobileSubscriberCountryCode":             @"MobileSubscriberCountryCode",
            @"MobileSubscriberNetworkCode":             @"MobileSubscriberNetworkCode",
            @"SIMTrayStatus":                           @"SIMTrayStatus",
            // Hardware capability booleans — MUST match the claimed model
            @"HasFaceID":                               @"HasFaceID",
            @"HasTouchID":                              @"HasTouchID",
            @"HasMesa":                                 @"HasTouchID",
            @"HasHomeButton":                           @"HasHomeButton",
            @"HasOLEDDisplay":                          @"HasOLEDDisplay",
            @"Has5GUW":                                 @"Has5G",
            @"HasNFC":                                  @"HasNFC",
            @"HasCellularConnectivity":                 @"HasCellularConnectivity",
            @"HasBaseband":                             @"HasCellularConnectivity",
            // Activation lifecycle (anti-fraud cross-checks vs reg date)
            @"InitialActivationDate":                   @"InitialActivationDate",
            @"ActivationState":                         @"ActivationState",
            @"ActivationStateAcknowledged":             @"ActivationStateAcknowledged",
        };
    });
}

// Keys MGCopyAnswer returns as NSNumber (int / long) instead of NSString.
// Reading these as strings would type-mismatch and Settings.app's About
// screen would render the wrong value (or crash on int-cast).
static BOOL isMGIntKey(NSString *k) {
    static NSSet *s = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        s = [NSSet setWithObjects:
             @"TotalDiskCapacity", @"TotalSystemAvailable", @"DiskUsage",
             @"BatteryCurrentCapacity", @"ChipID", @"BoardId",
             @"HardwarePlatform", @"UniqueChipID", nil];
    });
    return [s containsObject:k];
}

static CFTypeRef hooked_MGCopyAnswer(CFStringRef property) {
    if (g_inMG || !orig_MGCopyAnswer) return orig_MGCopyAnswer ? orig_MGCopyAnswer(property) : NULL;
    if (!gCfg || !property)            return orig_MGCopyAnswer(property);
    if (!LAYER("hardware"))            return orig_MGCopyAnswer(property);

    g_inMG = 1;
    buildMGMap();
    NSString *key = (__bridge NSString *)property;
    NSString *configKey = gMGMap[key];
    CFTypeRef result = NULL;

    if (configKey) {
        id raw = cg(configKey);
        if (raw) {
            if ([key isEqualToString:@"BatteryIsCharging"] || [key isEqualToString:@"AirplaneMode"]) {
                BOOL b = [raw respondsToSelector:@selector(boolValue)] ? [raw boolValue] : NO;
                result = (__bridge_retained CFTypeRef)@(b);
            } else if (isMGIntKey(key)) {
                long long v = 0;
                if ([raw isKindOfClass:[NSNumber class]]) v = [raw longLongValue];
                else if ([raw isKindOfClass:[NSString class]]) v = [(NSString *)raw longLongValue];
                result = (__bridge_retained CFTypeRef)@(v);
            } else {
                NSString *s = nil;
                if ([raw isKindOfClass:[NSString class]]) s = raw;
                else if (raw) s = [NSString stringWithFormat:@"%@", raw];
                if (s.length) result = (__bridge_retained CFTypeRef)s;
            }
        }
    }

    g_inMG = 0;
    if (result) return result;
    return orig_MGCopyAnswer(property);
}

static BOOL hooked_MGGetBoolAnswer(CFStringRef property) {
    if (g_inMG || !orig_MGGetBoolAnswer) return orig_MGGetBoolAnswer ? orig_MGGetBoolAnswer(property) : NO;
    if (!gCfg || !property)              return orig_MGGetBoolAnswer(property);
    if (!LAYER("hardware"))              return orig_MGGetBoolAnswer(property);

    g_inMG = 1;
    buildMGMap();
    NSString *key = (__bridge NSString *)property;
    NSString *configKey = gMGMap[key];
    BOOL out = NO; BOOL hit = NO;
    if (configKey) {
        id v = cg(configKey);
        if (v) {
            hit = YES;
            if ([v respondsToSelector:@selector(boolValue)]) out = [v boolValue];
        }
    }
    g_inMG = 0;
    return hit ? out : orig_MGGetBoolAnswer(property);
}

static CFTypeRef hooked_MGGetStringAnswer(CFStringRef property) {
    if (g_inMG || !orig_MGGetStringAnswer) return orig_MGGetStringAnswer ? orig_MGGetStringAnswer(property) : NULL;
    if (!gCfg || !property)                return orig_MGGetStringAnswer(property);
    if (!LAYER("hardware"))                return orig_MGGetStringAnswer(property);

    g_inMG = 1;
    buildMGMap();
    NSString *key = (__bridge NSString *)property;
    NSString *configKey = gMGMap[key];
    CFTypeRef result = NULL;
    if (configKey) {
        NSString *v = cs(configKey);
        if (v.length) result = (__bridge_retained CFTypeRef)v;
    }
    g_inMG = 0;
    if (result) return result;
    return orig_MGGetStringAnswer(property);
}

static void installMGHooks(void) {
    void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!h) return;
    orig_MGCopyAnswer       = (MGCopyAnswer_t)      dlsym(h, "MGCopyAnswer");
    orig_MGGetBoolAnswer    = (MGGetBoolAnswer_t)   dlsym(h, "MGGetBoolAnswer");
    orig_MGGetStringAnswer  = (MGGetStringAnswer_t) dlsym(h, "MGGetStringAnswer");
    if (orig_MGCopyAnswer)
        MSHookFunction((void *)orig_MGCopyAnswer,
                       (void *)hooked_MGCopyAnswer,
                       (void **)&orig_MGCopyAnswer);
    if (orig_MGGetBoolAnswer)
        MSHookFunction((void *)orig_MGGetBoolAnswer,
                       (void *)hooked_MGGetBoolAnswer,
                       (void **)&orig_MGGetBoolAnswer);
    if (orig_MGGetStringAnswer)
        MSHookFunction((void *)orig_MGGetStringAnswer,
                       (void *)hooked_MGGetStringAnswer,
                       (void **)&orig_MGGetStringAnswer);
    NSLog(@"[ChangeInfoIosZalo] MG hooks installed (copy=%p bool=%p str=%p)",
          orig_MGCopyAnswer, orig_MGGetBoolAnswer, orig_MGGetStringAnswer);
}

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

        // v2.6.3 SAFETY: HARD bail on SpringBoard. The v2.6.2 sidecar
        // crashed SpringBoard into SafeMode because BBoard / lock-screen /
        // status-bar daemons read MGCopyAnswer dozens of times during boot
        // BEFORE gCfg loaded from disk, and our hook's early-bail path
        // through orig_MGCopyAnswer (still NULL at that microsecond) hit
        // a NULL-deref. SpringBoard is also too sensitive in general —
        // it must NEVER carry our hooks. Belt-and-braces in case a stale
        // plist filter still includes springboard.
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            NSLog(@"[ChangeInfoIosZalo] SAFETY: skipping load into SpringBoard");
            return;
        }

        reloadCfg();
        installMGHooks();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            NULL, onPrefsNotify, CFSTR("com.changeinfoios/ReloadPrefs"), NULL,
            CFNotificationSuspensionBehaviorCoalesce);
        NSLog(@"[ChangeInfoIosZalo] Loaded into %@, cfg keys=%lu",
              bid, (unsigned long)(gCfg ? gCfg.count : 0));
    }
}
