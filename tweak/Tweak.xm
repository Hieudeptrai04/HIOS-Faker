/**
 * ChangeInfoIos Tweak - iOS Device Parameter Spoofer
 * Rootless Jailbreak Compatible (Dopamine / palera1n)
 * iOS 15.0 - 16.7.x
 *
 * Build with Theos:
 *   THEOS_PACKAGE_SCHEME=rootless make package
 *
 * Config file: /var/mobile/Library/Preferences/com.changeinfoios.plist
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/types.h>
#import <sys/stat.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <arpa/inet.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#include <sys/time.h>
#import <spawn.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#if __has_include(<CoreTelephony/CTSubscriber.h>)
#import <CoreTelephony/CTSubscriber.h>
#else
@interface CTSubscriber : NSObject
- (NSString *)phoneNumber;
@end
#endif
#import <CoreLocation/CoreLocation.h>
#import <AdSupport/AdSupport.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <Metal/Metal.h>

// ATTrackingManager forward declaration (iOS 14+)
@interface ATTrackingManager : NSObject
+ (NSUInteger)trackingAuthorizationStatus;
+ (void)requestTrackingAuthorizationWithCompletionHandler:(void (^)(NSUInteger))completion;
@end

// ============================================================
// SHARED C LINKAGE FOR Tweak.xm <-> Hooks.mm
// ============================================================
// When any .mm sibling is in the same Theos target, Tweak.xm is
// preprocessed and compiled as Objective-C++. Without extern "C" on
// the cross-file symbols, C++ mangling breaks link (Tweak.xm defines
// _Z9fakeLayer..., Hooks.mm expects _fakeLayer, and vice versa for
// initCLvlHooks). Forward-declaring in extern "C" forces the matching
// definitions below to inherit C linkage.
#ifdef __cplusplus
extern "C" {
#endif
extern BOOL configLoaded;
id           getConfig(NSString *key);
NSString    *getConfigStr(NSString *key);
BOOL         getConfigBool(NSString *key);
BOOL         fakeLayer(NSString *shortName);
BOOL         jbHideActive(void);
void         reloadConfigFromDisk(void);
void         initCLvlHooks(void); // defined in Hooks.mm
#ifdef __cplusplus
}
#endif

// ============================================================
// CONFIG LOADING
// ============================================================
static NSString *const kConfigPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
static NSDictionary *spoofConfig = nil;
BOOL configLoaded = NO;

static BOOL isCurrentBundleTargeted(void) {
    id targets = getConfig(@"targetBundles");
    if (![targets isKindOfClass:[NSArray class]]) return YES;
    NSArray *arr = (NSArray *)targets;
    if (arr.count == 0) return YES;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isKindOfClass:[NSString class]] || bid.length == 0) return YES;
    for (id item in arr) {
        if ([item isKindOfClass:[NSString class]] && [(NSString *)item isEqualToString:bid]) {
            return YES;
        }
    }
    return NO;
}

void reloadConfigFromDisk(void) {
    @autoreleasepool {
        NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
        if (config) {
            spoofConfig = [config copy];
            configLoaded = YES;
        } else {
            spoofConfig = nil;
            configLoaded = NO;
        }
    }
}

static void loadConfig(void) {
    reloadConfigFromDisk();
    if (configLoaded) {
        NSLog(@"[ChangeInfoIos] Config loaded: %lu keys", (unsigned long)spoofConfig.count);
    } else {
        NSLog(@"[ChangeInfoIos] No config file at %@", kConfigPath);
    }
}

static void ci_wipeContainerIfScheduled(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid.length == 0) return;
        NSString *key = [@"wipe_counter_" stringByAppendingString:bid];
        id v = getConfig(key);
        long long counter = [v respondsToSelector:@selector(longLongValue)] ? [v longLongValue] : 0;
        if (counter <= 0) return;

        NSString *home = NSHomeDirectory();
        if (home.length == 0) return;
        NSString *marker = [home stringByAppendingPathComponent:@".ci_last_wipe"];
        long long last = 0;
        NSString *existing = [NSString stringWithContentsOfFile:marker encoding:NSUTF8StringEncoding error:nil];
        if (existing) last = [existing longLongValue];
        if (counter <= last) return;

        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *subdirs = @[@"Documents", @"Library/Caches", @"Library/Preferences",
                             @"Library/Cookies", @"Library/WebKit", @"Library/Application Support", @"tmp"];
        NSUInteger removed = 0;
        for (NSString *d in subdirs) {
            NSString *full = [home stringByAppendingPathComponent:d];
            NSArray *items = [fm contentsOfDirectoryAtPath:full error:nil];
            for (NSString *item in items) {
                if ([item isEqualToString:@".ci_last_wipe"]) continue;
                NSError *err = nil;
                if ([fm removeItemAtPath:[full stringByAppendingPathComponent:item] error:&err]) removed++;
            }
        }
        [[NSString stringWithFormat:@"%lld", counter] writeToFile:marker
            atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[ChangeInfoIos] Wiped %@ (counter=%lld, items=%lu)", bid, counter, (unsigned long)removed);
    }
}

static void onPrefsDarwinNotify(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadConfigFromDisk();
    NSLog(@"[ChangeInfoIos] Prefs reloaded (%lu keys)", (unsigned long)(spoofConfig ? spoofConfig.count : 0));
}

id getConfig(NSString *key) {
    if (!configLoaded) reloadConfigFromDisk();
    return spoofConfig[key];
}

NSString *getConfigStr(NSString *key) {
    id val = getConfig(key);
    if ([val isKindOfClass:[NSString class]]) return val;
    if (val) return [NSString stringWithFormat:@"%@", val];
    return nil;
}

BOOL getConfigBool(NSString *key) {
    id val = getConfig(key);
    if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
    return NO;
}

/* Plist booleans fake_<name> — missing key = OFF (opt-in). Short names: uiddevice, hardware, sysctl, ... */
BOOL fakeLayer(NSString *shortName) {
    if (!isCurrentBundleTargeted()) return NO;
    NSString *full = [NSString stringWithFormat:@"fake_%@", shortName];
    id v = getConfig(full);
    if (v == nil) return NO;
    return [v boolValue];
}

BOOL jbHideActive(void) {
    if (!fakeLayer(@"jbhide")) return NO;
    id h = getConfig(@"hideJailbreak");
    if (h == nil) return NO;
    return [h boolValue];
}

// ============================================================
// LAYER 1: UIDevice HOOKS  (fake_uiddevice)
// ============================================================
%hook UIDevice

- (NSString *)name {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"deviceName");
    return val ?: %orig;
}

- (NSString *)model {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"deviceModel");
    return val ?: %orig;
}

- (NSString *)localizedModel {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"localizedModel");
    return val ?: %orig;
}

- (NSString *)systemName {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"systemName");
    return val ?: %orig;
}

- (NSString *)systemVersion {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"systemVersion");
    return val ?: %orig;
}

- (NSUUID *)identifierForVendor {
    if (!fakeLayer(@"uiddevice")) return %orig;
    NSString *val = getConfigStr(@"identifierForVendor");
    if (val) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:val];
        if (uuid) return uuid;
    }
    return %orig;
}

- (float)batteryLevel {
    if (!fakeLayer(@"uiddevice")) return %orig;
    id val = getConfig(@"batteryLevel");
    if (val) return [val floatValue];
    return %orig;
}

- (UIDeviceBatteryState)batteryState {
    if (!fakeLayer(@"uiddevice")) return %orig;
    id val = getConfig(@"batteryState");
    if (val) return (UIDeviceBatteryState)[val integerValue];
    return %orig;
}

- (BOOL)isMultitaskingSupported {
    return YES;
}

- (UIUserInterfaceIdiom)userInterfaceIdiom {
    return UIUserInterfaceIdiomPhone;
}

%end

// ============================================================
// LAYER 2: MGCopyAnswer / libMobileGestalt
// Hook MGCopyAnswer_internal for deep spoofing
// ============================================================
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef property);
static MGCopyAnswer_t orig_MGCopyAnswer = NULL;

static NSDictionary *mgKeyMap = nil;

static void initMGKeyMap() {
    if (mgKeyMap) return;
    mgKeyMap = @{
        @"UniqueDeviceID":       @"UniqueDeviceID",
        @"SerialNumber":         @"SerialNumber",
        @"UniqueChipID":         @"UniqueChipID",
        @"InternationalMobileEquipmentIdentity":  @"InternationalMobileEquipmentIdentity",
        @"InternationalMobileEquipmentIdentity2": @"InternationalMobileEquipmentIdentity2",
        @"MobileEquipmentIdentifier":             @"MobileEquipmentIdentifier",
        @"IntegratedCircuitCardIdentity":          @"IntegratedCircuitCardIdentity",
        @"IntegratedCircuitCardIdentity2":         @"IntegratedCircuitCardIdentity2",
        @"PhoneNumber":          @"PhoneNumber",
        @"ProductType":          @"ProductType",
        @"HardwareModel":        @"HardwareModel",
        @"HWModelStr":           @"HWModelStr",
        @"ModelNumber":          @"ModelNumber",
        @"RegionCode":           @"RegionCode",
        @"RegionInfo":           @"RegionInfo",
        @"WiFiAddress":          @"WiFiAddress",
        @"BluetoothAddress":     @"BluetoothAddress",
        @"EthernetAddress":      @"EthernetAddress",
        @"BoardId":              @"BoardId",
        @"HardwarePlatform":     @"BoardId",
        @"ChipID":               @"ChipID",
        @"FirmwareVersion":      @"FirmwareVersion",
        @"BasebandVersion":      @"BasebandVersion",
        @"BasebandSerialNumber": @"BasebandSerialNumber",
        @"BasebandChipId":       @"BasebandChipId",
        @"BasebandCertId":       @"BasebandCertId",
        @"BuildVersion":         @"BuildVersion",
        @"ProductVersion":       @"ProductVersion",
        @"DeviceColor":          @"DeviceColor",
        @"DeviceEnclosureColor": @"DeviceEnclosureColor",
        @"DiskUsage":            @"DiskUsage",
        @"TotalDiskCapacity":    @"TotalDiskCapacity",
        @"TotalSystemAvailable": @"TotalSystemAvailable",
        @"BatteryCurrentCapacity": @"BatteryCurrentCapacity",
        @"BatteryIsCharging":    @"BatteryIsCharging",
        @"BatterySerialNumber":  @"BatterySerialNumber",
        @"BootNonce":            @"BootNonce",
        @"DeviceName":           @"DeviceNameMG",
        @"UserAssignedDeviceName": @"UserAssignedDeviceName",
        @"MarketingName":        @"MarketingName",
        @"AirplaneMode":         @"AirplaneMode",
        @"MobileSubscriberCountryCode": @"MobileSubscriberCountryCode",
        @"MobileSubscriberNetworkCode": @"MobileSubscriberNetworkCode",
        @"SIMTrayStatus":        @"SIMTrayStatus",
    };
}

static int64_t configValueAsMGInteger(NSString *configKey) {
    id val = getConfig(configKey);
    if (!val) return 0;
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val longLongValue];
    if ([val isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (s.length == 0) return 0;
        if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
            unsigned long long u = 0;
            NSScanner *sc = [NSScanner scannerWithString:s];
            if ([sc scanHexLongLong:&u]) return (int64_t)u;
        }
        return (int64_t)[s longLongValue];
    }
    return 0;
}

static CFTypeRef hooked_MGCopyAnswer(CFStringRef property) {
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded || !property) return orig_MGCopyAnswer(property);
    if (!fakeLayer(@"hardware")) return orig_MGCopyAnswer(property);

    initMGKeyMap();

    NSString *key = (__bridge NSString *)property;
    if ([key isEqualToString:@"ProductVersion"] || [key isEqualToString:@"BuildVersion"]) {
        if (!fakeLayer(@"sysosversion")) return orig_MGCopyAnswer(property);
    }

    NSString *configKey = mgKeyMap[key];

    if (configKey) {
        if ([key isEqualToString:@"BatteryIsCharging"] || [key isEqualToString:@"AirplaneMode"]) {
            if (getConfig(configKey))
                return (__bridge_retained CFTypeRef)@(getConfigBool(configKey));
        }
        NSSet *mgIntKeys = [NSSet setWithObjects:
            @"TotalDiskCapacity", @"TotalSystemAvailable", @"DiskUsage",
            @"BatteryCurrentCapacity", @"ChipID", @"BoardId", @"HardwarePlatform", nil];
        if ([mgIntKeys containsObject:key]) {
            int64_t v = configValueAsMGInteger(configKey);
            return (__bridge_retained CFTypeRef)@(v);
        }
        NSString *val = getConfigStr(configKey);
        if (val) return (__bridge_retained CFTypeRef)val;
    }

    return orig_MGCopyAnswer(property);
}

// ============================================================
// LAYER 3: IOKit Registry Hooks
// ============================================================
typedef CFTypeRef (*IORegCreateCFProp_t)(mach_port_t entry, CFStringRef key, CFAllocatorRef alloc, uint32_t options);
static IORegCreateCFProp_t orig_IORegistryEntryCreateCFProperty = NULL;

static NSDictionary *ioKeyMap = nil;

static void initIOKeyMap() {
    if (ioKeyMap) return;
    ioKeyMap = @{
        @"IOPlatformSerialNumber": @"IOPlatformSerialNumber",
        @"IOPlatformUUID":         @"IOPlatformUUID",
        @"board-id":               @"IOBoardId",
        @"product-name":           @"IOProductName",
        @"model":                  @"IOModel",
        @"serial-number":          @"IODeviceTreeSerial",
        @"mlb-serial-number":      @"IODeviceTreeMLBSerial",
    };
}

static CFTypeRef hooked_IORegistryEntryCreateCFProperty(mach_port_t entry, CFStringRef key, CFAllocatorRef alloc, uint32_t options) {
    if (!configLoaded) reloadConfigFromDisk();
    if (!fakeLayer(@"hardware")) return orig_IORegistryEntryCreateCFProperty(entry, key, alloc, options);
    if (configLoaded && key) {
        initIOKeyMap();
        NSString *keyStr = (__bridge NSString *)key;
        NSString *configKey = ioKeyMap[keyStr];
        if (configKey) {
            NSString *val = getConfigStr(configKey);
            if (val) {
                if ([keyStr isEqualToString:@"serial-number"] || [keyStr isEqualToString:@"mlb-serial-number"]) {
                    NSData *data = [val dataUsingEncoding:NSUTF8StringEncoding];
                    return (__bridge_retained CFTypeRef)data;
                }
                return (__bridge_retained CFTypeRef)val;
            }
        }
    }
    return orig_IORegistryEntryCreateCFProperty(entry, key, alloc, options);
}

// ============================================================
// LAYER 4: CoreTelephony Hooks
// ============================================================
%hook CTCarrier

- (NSString *)carrierName {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierName");
    return val ?: %orig;
}

- (NSString *)mobileCountryCode {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierMCC");
    return val ?: %orig;
}

- (NSString *)mobileNetworkCode {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierMNC");
    return val ?: %orig;
}

- (NSString *)isoCountryCode {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierISO");
    return val ?: %orig;
}

- (BOOL)allowsVOIP {
    if (!fakeLayer(@"network")) return %orig;
    id val = getConfig(@"carrierAllowsVOIP");
    if (val) return [val boolValue];
    return %orig;
}

%end

%hook CTTelephonyNetworkInfo

- (NSString *)currentRadioAccessTechnology {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"carrierRadioAccess");
    return val ?: %orig;
}

%end

%hook CTSubscriber

- (NSString *)phoneNumber {
    if (!fakeLayer(@"network")) return %orig;
    NSString *val = getConfigStr(@"PhoneNumber");
    return val.length > 0 ? val : %orig;
}

%end

// ============================================================
// LAYER 5: Network / SystemConfiguration
// ============================================================
%hookf(CFDictionaryRef, CNCopyCurrentNetworkInfo, CFStringRef interfaceName) {
    CFDictionaryRef orig = %orig;
    if (!fakeLayer(@"wifi")) return orig;

    NSString *ssid = getConfigStr(@"wifiSSID");
    NSString *bssid = getConfigStr(@"wifiBSSID");

    if (ssid || bssid) {
        NSMutableDictionary *dict = orig ? [(__bridge NSDictionary *)orig mutableCopy] : [NSMutableDictionary dictionary];
        if (ssid)  dict[(__bridge NSString *)kCNNetworkInfoKeySSID]  = ssid;
        if (bssid) dict[(__bridge NSString *)kCNNetworkInfoKeyBSSID] = bssid;
        return (__bridge_retained CFDictionaryRef)dict;
    }

    return orig;
}

// ============================================================
// LAYER 6: Advertising Hooks
// ============================================================
%hook ASIdentifierManager

- (NSUUID *)advertisingIdentifier {
    if (!fakeLayer(@"ads")) return %orig;
    NSString *val = getConfigStr(@"advertisingIdentifier");
    if (val) {
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:val];
        if (uuid) return uuid;
    }
    return %orig;
}

- (BOOL)isAdvertisingTrackingEnabled {
    if (!fakeLayer(@"ads")) return %orig;
    id val = getConfig(@"isAdvertisingTrackingEnabled");
    if (val) return [val boolValue];
    return %orig;
}

%end

// ============================================================
// LAYER 7: Screen / Display Hooks
// ============================================================
%hook UIScreen

- (CGRect)bounds {
    if (!fakeLayer(@"screen")) return %orig;
    id w = getConfig(@"screenWidth");
    id h = getConfig(@"screenHeight");
    if (w && h) {
        return CGRectMake(0, 0, [w floatValue], [h floatValue]);
    }
    return %orig;
}

- (CGRect)nativeBounds {
    if (!fakeLayer(@"screen") || !fakeLayer(@"realscreen")) return %orig;
    id w = getConfig(@"nativeScreenWidth");
    id h = getConfig(@"nativeScreenHeight");
    if (w && h) {
        return CGRectMake(0, 0, [w floatValue], [h floatValue]);
    }
    return %orig;
}

- (CGFloat)scale {
    if (!fakeLayer(@"screen")) return %orig;
    id val = getConfig(@"screenScale");
    if (val) return [val floatValue];
    return %orig;
}

- (CGFloat)nativeScale {
    if (!fakeLayer(@"screen") || !fakeLayer(@"realscreen")) return %orig;
    id val = getConfig(@"nativeScale");
    if (val) return [val floatValue];
    return %orig;
}

%end

// ============================================================
// LAYER 8: NSProcessInfo Hooks
// ============================================================
%hook NSProcessInfo

- (NSString *)hostName {
    if (!fakeLayer(@"processinfo")) return %orig;
    NSString *val = getConfigStr(@"processHostName");
    return val ?: %orig;
}

- (NSUInteger)processorCount {
    if (!fakeLayer(@"processinfo")) return %orig;
    id val = getConfig(@"processorCount");
    if (val) return [val unsignedIntegerValue];
    return %orig;
}

- (unsigned long long)physicalMemory {
    if (!fakeLayer(@"processinfo")) return %orig;
    id val = getConfig(@"physicalMemory");
    if (val) return [val unsignedLongLongValue];
    return %orig;
}

- (NSTimeInterval)systemUptime {
    if (!fakeLayer(@"processinfo")) return %orig;
    id val = getConfig(@"systemUptime");
    if (val) return [val doubleValue];
    return %orig;
}

- (NSOperatingSystemVersion)operatingSystemVersion {
    if (!fakeLayer(@"processinfo")) return %orig;
    NSString *ver = getConfigStr(@"systemVersion");
    if (ver) {
        NSArray *parts = [ver componentsSeparatedByString:@"."];
        NSOperatingSystemVersion v;
        v.majorVersion = parts.count > 0 ? [parts[0] integerValue] : 16;
        v.minorVersion = parts.count > 1 ? [parts[1] integerValue] : 0;
        v.patchVersion = parts.count > 2 ? [parts[2] integerValue] : 0;
        return v;
    }
    return %orig;
}

%end

// ============================================================
// LAYER 9: GPS Location Hooks
// ============================================================
static CLLocation *buildFakeLocation(void) {
    id lat = getConfig(@"latitude");
    id lng = getConfig(@"longitude");
    id alt = getConfig(@"altitude");
    if (!lat || !lng) return nil;

    CLLocationCoordinate2D coord;
    coord.latitude = [lat doubleValue];
    coord.longitude = [lng doubleValue];
    double altitude = alt ? [alt doubleValue] : 10.0;

    // Micro-jitter (~5 cm) every read — mimics noisy GPS sensor; the large
    // resettable jitter is already baked into lat/lng by the host app on Reset.
    double jitterLat = ((double)(arc4random_uniform(100)) - 50.0) / 1000000.0;
    double jitterLng = ((double)(arc4random_uniform(100)) - 50.0) / 1000000.0;
    coord.latitude += jitterLat;
    coord.longitude += jitterLng;

    id acc    = getConfig(@"locationAccuracy");
    id spdV   = getConfig(@"locationSpeed");
    id crsV   = getConfig(@"locationCourse");
    double hAcc   = acc  ? [acc doubleValue]  : (5.0 + arc4random_uniform(30));
    double speed  = spdV ? [spdV doubleValue] : 0.0;
    double course = crsV ? [crsV doubleValue] : (double)(arc4random_uniform(360));

    CLLocation *loc = [[CLLocation alloc]
        initWithCoordinate:coord
        altitude:altitude
        horizontalAccuracy:hAcc
        verticalAccuracy:hAcc * 1.5
        course:course
        speed:speed
        timestamp:[NSDate date]];
    return loc;
}

%hook CLLocationManager

- (CLLocation *)location {
    if (!fakeLayer(@"location")) return %orig;
    if (!getConfigBool(@"locationEnabled")) return %orig;
    CLLocation *fake = buildFakeLocation();
    return fake ?: %orig;
}

- (void)startUpdatingLocation {
    %orig;
    if (fakeLayer(@"location") && getConfigBool(@"locationEnabled") && self.delegate) {
        CLLocation *fake = buildFakeLocation();
        if (fake && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.delegate locationManager:self didUpdateLocations:@[fake]];
            });
        }
    }
}

- (void)startMonitoringSignificantLocationChanges {
    %orig;
    if (fakeLayer(@"location") && getConfigBool(@"locationEnabled") && self.delegate) {
        CLLocation *fake = buildFakeLocation();
        if (fake && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.delegate locationManager:self didUpdateLocations:@[fake]];
            });
        }
    }
}

- (void)requestLocation {
    if (fakeLayer(@"location") && getConfigBool(@"locationEnabled") && self.delegate) {
        CLLocation *fake = buildFakeLocation();
        if (fake && [self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.delegate locationManager:self didUpdateLocations:@[fake]];
            });
            return;
        }
    }
    %orig;
}

%end

%hook CLGeocoder

- (void)reverseGeocodeLocation:(CLLocation *)location completionHandler:(void (^)(NSArray *placemarks, NSError *error))completionHandler {
    if (!fakeLayer(@"location") || !getConfigBool(@"locationEnabled")) {
        %orig;
        return;
    }
    CLLocation *fake = buildFakeLocation();
    if (fake) {
        %orig(fake, completionHandler);
    } else {
        %orig;
    }
}

%end

// ============================================================
// LAYER 10: Locale / Timezone Hooks
// ============================================================
%hook NSLocale

+ (NSLocale *)currentLocale {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *identifier = getConfigStr(@"localeIdentifier");
    if (identifier) {
        return [[NSLocale alloc] initWithLocaleIdentifier:identifier];
    }
    return %orig;
}

- (NSString *)countryCode {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeCountryCode");
    return val ?: %orig;
}

- (NSString *)languageCode {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeLanguageCode");
    return val ?: %orig;
}

- (NSString *)currencyCode {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeCurrencyCode");
    return val ?: %orig;
}

- (NSString *)collatorIdentifier {
    if (!fakeLayer(@"locale")) return %orig;
    NSString *val = getConfigStr(@"localeIdentifier");
    return val ?: %orig;
}

%end

%hook NSTimeZone

+ (NSTimeZone *)localTimeZone {
    if (!fakeLayer(@"datetime")) return %orig;
    NSString *tzName = getConfigStr(@"timezoneName");
    if (tzName) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzName];
        if (tz) return tz;
    }
    return %orig;
}

+ (NSTimeZone *)systemTimeZone {
    if (!fakeLayer(@"datetime")) return %orig;
    NSString *tzName = getConfigStr(@"timezoneName");
    if (tzName) {
        NSTimeZone *tz = [NSTimeZone timeZoneWithName:tzName];
        if (tz) return tz;
    }
    return %orig;
}

%end

// ============================================================
// LAYER 11: Jailbreak Hide Hooks
// ============================================================
%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (!jbHideActive()) return %orig;

    NSArray *hiddenPaths = getConfig(@"hiddenPaths");
    if (hiddenPaths) {
        for (NSString *hidden in hiddenPaths) {
            if ([path hasPrefix:hidden] || [path isEqualToString:hidden]) {
                return NO;
            }
        }
    }

    NSArray *defaultPaths = @[
        @"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
        @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/usr/lib/TweakInject",
        @"/Library/MobileSubstrate", @"/var/mobile/Library/Caches/com.saurik.Cydia",
        @"/.installed_dopamine", @"/.installed_palera1n",
        @"/var/binpack", @"/private/preboot",
    ];

    for (NSString *jbPath in defaultPaths) {
        if ([path hasPrefix:jbPath] || [path isEqualToString:jbPath]) {
            return NO;
        }
    }

    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (!jbHideActive()) return %orig;

    NSArray *defaultPaths = @[
        @"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
        @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/.installed_dopamine",
        @"/.installed_palera1n", @"/var/binpack",
    ];

    for (NSString *jbPath in defaultPaths) {
        if ([path hasPrefix:jbPath]) return NO;
    }

    return %orig;
}

%end

%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (jbHideActive() && url) {
        NSString *scheme = [url scheme];
        NSArray *blocked = @[@"cydia", @"sileo", @"zbra", @"filza", @"undecimus",
                            @"activator", @"flex"];
        for (NSString *s in blocked) {
            if ([scheme isEqualToString:s]) return NO;
        }
    }
    return %orig;
}

%end

%hook UIPasteboard

+ (UIPasteboard *)generalPasteboard {
    if (!jbHideActive() && !fakeLayer(@"tracking_pasteboard")) return %orig;
    return %orig;
}

- (NSArray<NSString *> *)strings {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return @[];
    }
    return %orig;
}

- (NSString *)string {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return nil;
    }
    return %orig;
}

- (BOOL)hasStrings {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return NO;
    }
    return %orig;
}

- (BOOL)hasURLs {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return NO;
    }
    return %orig;
}

- (NSArray<NSURL *> *)URLs {
    if (fakeLayer(@"tracking_pasteboard") && getConfigBool(@"clearPasteboard")) {
        return @[];
    }
    return %orig;
}

%end

// ============================================================
// BONUS: ZALO-SPECIFIC DEEP HOOKS
// ============================================================
%hook WKWebView

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)configuration {
    id wfGate = getConfig(@"web_fakeEnabled");
    BOOL allowInject = (wfGate == nil) || [wfGate boolValue];
    if (fakeLayer(@"browser") && allowInject) {
        WKUserContentController *ucc = configuration.userContentController;
        if (!ucc) {
            ucc = [[WKUserContentController alloc] init];
            configuration.userContentController = ucc;
        }

        NSString *vendor = getConfigStr(@"web_glVendor") ?: @"Apple Inc.";
        NSString *renderer = getConfigStr(@"web_glRenderer") ?: @"Apple GPU";
        NSString *canvasNoise = getConfigStr(@"web_canvasNoise") ?: @"zalo_spoof";

        NSString *coreJs = [NSString stringWithFormat:@"\
            const _getParam = WebGLRenderingContext.prototype.getParameter;\
            WebGLRenderingContext.prototype.getParameter = function(p) {\
                if (p === 37445) return '%@';\
                if (p === 37446) return '%@';\
                return _getParam.call(this, p);\
            };\
            const _getParam2 = WebGL2RenderingContext.prototype.getParameter;\
            WebGL2RenderingContext.prototype.getParameter = function(p) {\
                if (p === 37445) return '%@';\
                if (p === 37446) return '%@';\
                return _getParam2.call(this, p);\
            };\
            const _toDataURL = HTMLCanvasElement.prototype.toDataURL;\
            HTMLCanvasElement.prototype.toDataURL = function() {\
                var ctx = this.getContext('2d');\
                if (ctx) {\
                    ctx.fillStyle = 'rgba(255,255,255,0.01)';\
                    ctx.fillText('%@', 1, 1);\
                }\
                return _toDataURL.apply(this, arguments);\
            };\
        ", vendor, renderer, vendor, renderer, canvasNoise];

        NSString *rtcJs = @"";
        if (fakeLayer(@"webrtc")) {
            rtcJs = @"if(window.RTCPeerConnection){window.RTCPeerConnection=function(){return {};};}\
            if(navigator.mediaDevices&&navigator.mediaDevices.enumerateDevices){\
            const oldEnum=navigator.mediaDevices.enumerateDevices;\
            navigator.mediaDevices.enumerateDevices=async function(){\
            const devs=await oldEnum.call(this);\
            return devs.filter(function(d){return d.kind!=='audioinput'&&d.kind!=='videoinput';});};}";
        }

        NSString *js = [NSString stringWithFormat:@"try {%@%@} catch(e) {}", coreJs, rtcJs];
        WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO];
        [ucc addUserScript:script];
    }
    return %orig(frame, configuration);
}

- (NSString *)customUserAgent {
    if (!fakeLayer(@"browser")) return %orig;
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    return ua ?: %orig;
}

- (void)setCustomUserAgent:(NSString *)userAgent {
    if (!fakeLayer(@"browser")) {
        %orig(userAgent);
        return;
    }
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    if (ua) {
        %orig(ua);
    } else {
        %orig(userAgent);
    }
}

%end

%hook CMMotionManager

- (BOOL)isAccelerometerAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

- (BOOL)isGyroAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

- (BOOL)isMagnetometerAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

- (BOOL)isDeviceMotionAvailable {
    if (fakeLayer(@"sensor")) return NO;
    return %orig;
}

%end

%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    if (!fakeLayer(@"trackingdefaults")) return %orig;
    if (getConfigBool(@"keychainReset")) {
        NSArray *trackingKeys = @[@"device_id", @"device_token", @"udid",
                                 @"DEVICE_UUID", @"kDeviceId", @"UniqueIdentifier",
                                 @"ADVERTISING_ID", @"installation_id",
                                 @"TWClientID", @"TWDeviceID", @"tw_device",
                                 @"twitter_device", @"client_device_id",
                                 @"persistentDeviceID", @"tw_inapp_install_id"];
        for (NSString *key in trackingKeys) {
            if ([defaultName.lowercaseString containsString:key.lowercaseString]) {
                return nil;
            }
        }
    }
    return %orig;
}

%end

%hook NSMutableURLRequest

- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (!fakeLayer(@"browser")) {
        %orig(value, field);
        return;
    }
    if ([field.lowercaseString isEqualToString:@"user-agent"] && value.length > 0) {
        NSString *fakeUA = getConfigStr(@"zalo_fakeWebViewUA");
        if (fakeUA) {
            %orig(fakeUA, field);
            return;
        }
        NSString *fakeModel = getConfigStr(@"ProductType");
        if (fakeModel) {
            NSRegularExpression *regex = [NSRegularExpression
                regularExpressionWithPattern:@"iPhone\\d+,\\d+"
                options:0 error:nil];
            NSString *patched = [regex stringByReplacingMatchesInString:value
                options:0
                range:NSMakeRange(0, value.length)
                withTemplate:fakeModel];
            %orig(patched, field);
            return;
        }
    }
    %orig(value, field);
}

- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if (!fakeLayer(@"browser")) {
        %orig(value, field);
        return;
    }
    if ([field.lowercaseString isEqualToString:@"user-agent"] && value.length > 0) {
        NSString *fakeUA = getConfigStr(@"zalo_fakeWebViewUA");
        if (fakeUA) {
            %orig(fakeUA, field);
            return;
        }
    }
    %orig(value, field);
}

%end

%hook NSObject

- (NSString *)name {
    if (!fakeLayer(@"metal")) return %orig;
    if ([self conformsToProtocol:@protocol(MTLDevice)]) {
        NSString *fakeGPU = getConfigStr(@"zalo_metalGPU");
        if (fakeGPU) return fakeGPU;
    }
    return %orig;
}

%end

%hook ATTrackingManager

+ (NSUInteger)trackingAuthorizationStatus {
    if (!fakeLayer(@"ads")) return %orig;
    return 2;
}

+ (void)requestTrackingAuthorizationWithCompletionHandler:(void (^)(NSUInteger))completion {
    if (!fakeLayer(@"ads")) {
        %orig;
        return;
    }
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(2);
        });
    }
}

%end

%hook NSBundle

- (NSDictionary *)infoDictionary {
    NSDictionary *orig = %orig;
    if (!fakeLayer(@"sysosversion")) return orig;

    if (self != [NSBundle mainBundle]) return orig;

    NSString *fakeVersion = getConfigStr(@"systemVersion");
    NSString *fakeBuild = getConfigStr(@"BuildVersion");
    if (!fakeVersion && !fakeBuild) return orig;

    NSMutableDictionary *patched = [orig mutableCopy];
    if (fakeVersion) {
        patched[@"DTPlatformVersion"] = fakeVersion;
        patched[@"DTSDKName"] = [NSString stringWithFormat:@"iphoneos%@", fakeVersion];
    }
    if (fakeBuild) {
        patched[@"DTXcodeBuild"] = fakeBuild;
    }
    return patched;
}

%end

// ============================================================
// C-LEVEL HOOKS - Implemented in Hooks.mm via MSHookFunction
// (initCLvlHooks forward-declared with extern "C" at top of file)
// ============================================================

// ============================================================
// CONSTRUCTOR - Initialize on load
// ============================================================
%ctor {
    @autoreleasepool {
        NSLog(@"[ChangeInfoIos] Tweak loading...");

        loadConfig();
        ci_wipeContainerIfScheduled();

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, onPrefsDarwinNotify, CFSTR("com.changeinfoios/ReloadPrefs"), NULL, CFNotificationSuspensionBehaviorCoalesce);

        void *mgHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (mgHandle) {
            orig_MGCopyAnswer = (MGCopyAnswer_t)dlsym(mgHandle, "MGCopyAnswer");
            if (!orig_MGCopyAnswer)
                orig_MGCopyAnswer = (MGCopyAnswer_t)dlsym(mgHandle, "MGCopyAnswer_internal");
            if (orig_MGCopyAnswer) {
                MSHookFunction((void *)orig_MGCopyAnswer, (void *)hooked_MGCopyAnswer, (void **)&orig_MGCopyAnswer);
                NSLog(@"[ChangeInfoIos] MGCopyAnswer hooked");
            } else {
                NSLog(@"[ChangeInfoIos] MGCopyAnswer symbol not found");
            }
        }

        void *iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokitHandle) {
            orig_IORegistryEntryCreateCFProperty = (IORegCreateCFProp_t)dlsym(iokitHandle, "IORegistryEntryCreateCFProperty");
            if (orig_IORegistryEntryCreateCFProperty) {
                MSHookFunction((void *)orig_IORegistryEntryCreateCFProperty, (void *)hooked_IORegistryEntryCreateCFProperty, (void **)&orig_IORegistryEntryCreateCFProperty);
                NSLog(@"[ChangeInfoIos] IOKit hooked");
            }
        }

        // Initialize C-level hooks from Hooks.mm
        initCLvlHooks();

        NSLog(@"[ChangeInfoIos] Tweak loaded successfully! Config: %@", configLoaded ? @"YES" : @"NO");
    }
}
