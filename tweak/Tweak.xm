/**
 * ChangeInfoIos Tweak - iOS Device Parameter Spoofer
 * Rootless Jailbreak Compatible (Dopamine / palera1n)
 * iOS 15.0 - 16.7.x
 *
 * 13 Layers of Hooks - 142 Parameters
 * Optimized for Zalo anti-detection bypass
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
// CONFIG LOADING
// ============================================================
static NSString *const kConfigPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
static NSDictionary *spoofConfig = nil;
static BOOL configLoaded = NO;
static id getConfig(NSString *key);

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

static void reloadConfigFromDisk(void) {
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

static void onPrefsDarwinNotify(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    reloadConfigFromDisk();
    NSLog(@"[ChangeInfoIos] Prefs reloaded (%lu keys)", (unsigned long)(spoofConfig ? spoofConfig.count : 0));
}

static id getConfig(NSString *key) {
    if (!configLoaded) reloadConfigFromDisk();
    return spoofConfig[key];
}

static NSString *getConfigStr(NSString *key) {
    id val = getConfig(key);
    if ([val isKindOfClass:[NSString class]]) return val;
    if (val) return [NSString stringWithFormat:@"%@", val];
    return nil;
}

static NSInteger getConfigInt(NSString *key) {
    id val = getConfig(key);
    if ([val respondsToSelector:@selector(integerValue)]) return [val integerValue];
    return 0;
}

static BOOL getConfigBool(NSString *key) {
    id val = getConfig(key);
    if ([val respondsToSelector:@selector(boolValue)]) return [val boolValue];
    return NO;
}

/* Plist booleans fake_<name> — thiếu key = bật (tương thích cũ). Tên ngắn: uiddevice, hardware, sysctl, ... */
static BOOL fakeLayer(NSString *shortName) {
    if (!isCurrentBundleTargeted()) return NO;
    NSString *full = [NSString stringWithFormat:@"fake_%@", shortName];
    id v = getConfig(full);
    if (v == nil) return YES;
    return [v boolValue];
}

static BOOL jbHideActive(void) {
    if (!fakeLayer(@"jbhide")) return NO;
    id h = getConfig(@"hideJailbreak");
    if (h == nil) return YES;
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

%end

// ============================================================
// LAYER 2: MGCopyAnswer / libMobileGestalt
// Hook MGCopyAnswer_internal for deep spoofing
// ============================================================
// Forward declaration
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef property);
static MGCopyAnswer_t orig_MGCopyAnswer = NULL;

// Map of keys to config keys for MGCopyAnswer
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

// MG expects CFNumber for some keys; plist may store "0x8015" strings — parse hex. Never treat Baseband* as integers.
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
                    // These are expected as CFData
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
// CNCopyCurrentNetworkInfo hook
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
// LAYER 7: Low-Level C Functions
// ============================================================

// --- sysctlbyname hook ---
%hookf(int, sysctlbyname, const char *name, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = %orig;
    if (ret != 0 || !name || !oldp) return ret;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded) return ret;

    NSDictionary *sysctlMap = @{
        @"hw.machine":       @"hw_machine",
        @"hw.model":         @"hw_model",
        @"kern.hostname":    @"kern_hostname",
        @"kern.osversion":   @"kern_osversion",
        @"kern.osrelease":   @"kern_osrelease",
    };

    NSString *nameStr = [NSString stringWithUTF8String:name];
    NSString *configKey = sysctlMap[nameStr];

    if (configKey) {
        BOOL useStr = [nameStr isEqualToString:@"kern.osversion"] ? fakeLayer(@"sysosversion") : fakeLayer(@"sysctl");
        if (useStr) {
            NSString *val = getConfigStr(configKey);
            if (val && oldlenp) {
                const char *cval = [val UTF8String];
                size_t len = strlen(cval) + 1;
                if (*oldlenp >= len) {
                    memcpy(oldp, cval, len);
                    *oldlenp = len;
                }
            }
        }
    }

    if (!fakeLayer(@"sysctl")) return ret;

    if (strcmp(name, "hw.memsize") == 0) {
        id val = getConfig(@"hw_memsize");
        if (val && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t memsize = [val unsignedLongLongValue];
            memcpy(oldp, &memsize, sizeof(uint64_t));
        }
    }

    if (strcmp(name, "hw.physicalcpu") == 0 || strcmp(name, "hw.physicalcpu_max") == 0) {
        id val = getConfig(@"hw_physicalcpu");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int cores = [val intValue];
            memcpy(oldp, &cores, sizeof(int));
        }
    }

    if (strcmp(name, "hw.logicalcpu") == 0 || strcmp(name, "hw.logicalcpu_max") == 0) {
        id val = getConfig(@"hw_logicalcpu_max") ?: getConfig(@"hw_physicalcpu");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int cores = [val intValue];
            memcpy(oldp, &cores, sizeof(int));
        }
    }

    if (strcmp(name, "hw.cputype") == 0) {
        id val = getConfig(@"hw_cputype");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int ct = [val intValue];
            memcpy(oldp, &ct, sizeof(int));
        }
    }

    if (strcmp(name, "hw.cpusubtype") == 0) {
        id val = getConfig(@"hw_cpusubtype");
        if (val && oldlenp && *oldlenp >= sizeof(int)) {
            int cs = [val intValue];
            memcpy(oldp, &cs, sizeof(int));
        }
    }

    if (strcmp(name, "hw.cpufrequency") == 0 || strcmp(name, "hw.cpufrequency_max") == 0) {
        id val = getConfig(@"hw_cpufrequency");
        if (val && oldlenp && *oldlenp >= sizeof(uint64_t)) {
            uint64_t freq = [val unsignedLongLongValue];
            memcpy(oldp, &freq, sizeof(uint64_t));
        }
    }

    // kern.boottime — fake as struct timeval (tv_sec, tv_usec)
    if (strcmp(name, "kern.boottime") == 0) {
        id val = getConfig(@"kern_boottime");
        if (val && oldlenp && *oldlenp >= sizeof(struct timeval)) {
            struct timeval tv;
            tv.tv_sec  = (time_t)[val longLongValue];
            tv.tv_usec = 0;
            memcpy(oldp, &tv, sizeof(struct timeval));
        }
    }

    return ret;
}

// --- uname hook ---
%hookf(int, uname, struct utsname *name) {
    int ret = %orig;
    if (ret != 0 || !name) return ret;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded) return ret;
    if (!fakeLayer(@"sysctl")) return ret;

    NSString *sysname  = getConfigStr(@"uname_sysname");
    NSString *nodename = getConfigStr(@"uname_nodename");
    NSString *release  = getConfigStr(@"uname_release");
    NSString *version  = getConfigStr(@"uname_version");
    NSString *machine  = getConfigStr(@"uname_machine");

    if (sysname)  strlcpy(name->sysname,  [sysname UTF8String],  sizeof(name->sysname));
    if (nodename) strlcpy(name->nodename, [nodename UTF8String], sizeof(name->nodename));
    if (release)  strlcpy(name->release,  [release UTF8String],  sizeof(name->release));
    if (version)  strlcpy(name->version,  [version UTF8String],  sizeof(name->version));
    if (machine)  strlcpy(name->machine,  [machine UTF8String],  sizeof(name->machine));

    return ret;
}

// --- gethostname hook ---
%hookf(int, gethostname, char *name, size_t namelen) {
    int ret = %orig;
    if (!fakeLayer(@"sysctl")) return ret;
    NSString *hostname = getConfigStr(@"kern_hostname");
    if (hostname && name && namelen > 0) {
        strlcpy(name, [hostname UTF8String], namelen);
    }
    return ret;
}

// ============================================================
// LAYER 8: Keychain Hooks (Zalo Specific)
// ============================================================
%hookf(OSStatus, SecItemCopyMatching, CFDictionaryRef query, CFTypeRef *result) {
    // Check conditions BEFORE calling %orig to avoid real keychain access and CF memory leaks
    if (!fakeLayer(@"keychain")) return %orig;
    if (!configLoaded) reloadConfigFromDisk();
    if (!configLoaded || !getConfigBool(@"keychainReset")) return %orig;

    NSDictionary *queryDict = (__bridge NSDictionary *)query;
    NSString *service = queryDict[(__bridge NSString *)kSecAttrService];

    if (service) {
        // Block Zalo device identifiers
        if ([service containsString:@"com.vng.zalo"]) {
            if (result) *result = NULL;
            return errSecItemNotFound;
        }

        // Block Twitter/X device fingerprint keys (NOT session/auth tokens to avoid logout)
        BOOL isTwitterService = [service containsString:@"com.atebits"] ||
                                [service containsString:@"com.twitter"] ||
                                [service containsString:@"TwitterKit"] ||
                                [service containsString:@"com.x.ios"];
        if (isTwitterService) {
            NSString *account = queryDict[(__bridge NSString *)kSecAttrAccount];
            NSArray *deviceKeys = @[@"device_id", @"device_uuid", @"install_id",
                                    @"client_id", @"advertising_id", @"fingerprint",
                                    @"TWClientID", @"TWDeviceID", @"kTWDevice",
                                    @"persistent_id", @"hardware_id"];
            for (NSString *dk in deviceKeys) {
                if ([account.lowercaseString containsString:dk.lowercaseString] ||
                    [service.lowercaseString containsString:dk.lowercaseString]) {
                    if (result) *result = NULL;
                    return errSecItemNotFound;
                }
            }
        }
    }

    return %orig;
}

// ============================================================
// LAYER 9: Screen / Display Hooks
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
// LAYER 10: NSProcessInfo Hooks
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
// LAYER 11: GPS Location Hooks (DEEP - full location stack)
// ============================================================

// Helper to build a realistic fake CLLocation
static CLLocation *buildFakeLocation(void) {
    id lat = getConfig(@"latitude");
    id lng = getConfig(@"longitude");
    id alt = getConfig(@"altitude");
    if (!lat || !lng) return nil;

    CLLocationCoordinate2D coord;
    coord.latitude = [lat doubleValue];
    coord.longitude = [lng doubleValue];
    double altitude = alt ? [alt doubleValue] : 10.0;

    // Add slight random jitter so it looks like a real moving device (±0.00005°)
    double jitterLat = ((double)(arc4random_uniform(100)) - 50.0) / 1000000.0;
    double jitterLng = ((double)(arc4random_uniform(100)) - 50.0) / 1000000.0;
    coord.latitude += jitterLat;
    coord.longitude += jitterLng;

    id acc = getConfig(@"locationAccuracy");
    double hAcc = acc ? [acc doubleValue] : (5.0 + arc4random_uniform(30));

    // Use speed & course for realistic movement simulation
    CLLocation *loc = [[CLLocation alloc]
        initWithCoordinate:coord
        altitude:altitude
        horizontalAccuracy:hAcc
        verticalAccuracy:hAcc * 1.5
        course:(double)(arc4random_uniform(360))
        speed:0.0
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
    // After starting, immediately deliver a fake location
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

// CLGeocoder - fake reverse geocode results to match fake location
%hook CLGeocoder

- (void)reverseGeocodeLocation:(CLLocation *)location completionHandler:(void (^)(NSArray *placemarks, NSError *error))completionHandler {
    if (!fakeLayer(@"location") || !getConfigBool(@"locationEnabled")) {
        %orig;
        return;
    }
    // Let original geocode work but with our fake location
    CLLocation *fake = buildFakeLocation();
    if (fake) {
        %orig(fake, completionHandler);
    } else {
        %orig;
    }
}

%end

// ============================================================
// LAYER 12: Locale / Timezone Hooks
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
// LAYER 13: JAILBREAK HIDE (19 Vectors)
// ============================================================

// --- 13.1: NSFileManager ---
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

    // Default jailbreak paths
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

// --- 13.2: C-level file checks ---
%hookf(int, stat, const char *path, struct stat *buf) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
                           @"/usr/sbin/sshd", @"/usr/bin/ssh", @"/.installed_dopamine",
                           @"/.installed_palera1n", @"/var/binpack"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return -1; }
        }
    }
    return %orig;
}

%hookf(int, lstat, const char *path, struct stat *buf) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/Applications/Sileo.app",
                           @"/usr/sbin/sshd", @"/.installed_dopamine", @"/.installed_palera1n"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return -1; }
        }
    }
    return %orig;
}

%hookf(int, access, const char *path, int mode) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/usr/sbin/sshd",
                           @"/.installed_dopamine", @"/.installed_palera1n"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return -1; }
        }
    }
    return %orig;
}

// --- 13.3: fopen ---
%hookf(FILE *, fopen, const char *path, const char *mode) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *hidden = @[@"/var/jb", @"/Applications/Cydia.app", @"/usr/sbin/sshd",
                           @"/.installed_dopamine", @"/.installed_palera1n",
                           @"/etc/apt/sources.list", @"/var/lib/dpkg"];
        for (NSString *h in hidden) {
            if ([pathStr hasPrefix:h]) { errno = ENOENT; return NULL; }
        }
    }
    return %orig;
}

// --- 13.4: dlopen / dladdr ---
%hookf(void *, dlopen, const char *path, int mode) {
    if (jbHideActive() && path) {
        NSString *pathStr = [NSString stringWithUTF8String:path];
        NSArray *blockedLibs = @[@"SubstrateLoader", @"SubstrateInserter", @"CydiaSubstrate",
                                @"TweakInject", @"substitute", @"ElleKit", @"libhooker",
                                @"pspawn_payload", @"SubstrateBootstrap"];
        for (NSString *lib in blockedLibs) {
            if ([pathStr containsString:lib]) {
                return NULL;
            }
        }
    }
    return %orig;
}

// --- 13.5: dyld image hiding ---
%hookf(uint32_t, _dyld_image_count) {
    if (!jbHideActive()) return %orig;

    uint32_t count = %orig;
    uint32_t hidden = 0;

    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name) {
            NSString *nameStr = [NSString stringWithUTF8String:name];
            if ([nameStr containsString:@"Substrate"] ||
                [nameStr containsString:@"TweakInject"] ||
                [nameStr containsString:@"ElleKit"] ||
                [nameStr containsString:@"libhooker"] ||
                [nameStr containsString:@"substitute"]) {
                hidden++;
            }
        }
    }

    return count - hidden;
}

// --- 13.6: fork detection ---
%hookf(pid_t, fork) {
    if (jbHideActive()) {
        errno = ENOSYS;
        return -1;
    }
    return %orig;
}

// --- 13.7: getenv ---
%hookf(char *, getenv, const char *name) {
    if (jbHideActive() && name) {
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
            strcmp(name, "MobileSubstratePath") == 0 ||
            strcmp(name, "_MSSafeMode") == 0 ||
            strcmp(name, "DYLD_FRAMEWORK_PATH") == 0 ||
            strcmp(name, "DYLD_LIBRARY_PATH") == 0) {
            return NULL;
        }
    }
    return %orig;
}

// --- 13.8: URL Scheme check ---
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

// --- 13.9: Clipboard (anti cross-app tracking) - DEEP ---
%hook UIPasteboard

+ (UIPasteboard *)generalPasteboard {
    if (!jbHideActive() && !fakeLayer(@"tracking_pasteboard")) return %orig;
    UIPasteboard *pb = %orig;
    return pb;
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

// WKWebView Fake & User-Agent
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

// CoreMotion: fake_sensor ON = ẩn accelerometer/gyro khỏi fingerprint (trả không khả dụng)
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

// NSUserDefaults interception for app-specific tracking IDs
%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    if (!fakeLayer(@"trackingdefaults")) return %orig;
    if (getConfigBool(@"keychainReset")) {
        NSArray *trackingKeys = @[@"device_id", @"device_token", @"udid",
                                 @"DEVICE_UUID", @"kDeviceId", @"UniqueIdentifier",
                                 @"ADVERTISING_ID", @"installation_id",
                                 // Twitter/X specific
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

// ============================================================
// LAYER 14: NSURLRequest User-Agent Hook (fake_browser)
// Intercepts native HTTP requests (NSURLSession/NSURLConnection)
// so Twitter/X and other apps don't leak real device model
// in the User-Agent header.
// ============================================================
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
        // Patch device model token in-place (e.g. "iPhone13,2" → faked model)
        NSString *fakeModel = getConfigStr(@"ProductType");
        if (fakeModel) {
            // Replace patterns like "iPhone\d+,\d+" in the UA string
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

// ============================================================
// LAYER 15: Metal GPU Fingerprint Spoofing (fake_metal)
// ============================================================
@interface MTLDeviceProxy : NSObject
@end

%hook NSObject

// MTLDevice is a protocol; we hook the concrete Apple internal class
// that conforms to it. The name property leaks GPU model info.
- (NSString *)name {
    if (!fakeLayer(@"metal")) return %orig;
    // Check if self conforms to MTLDevice protocol
    if ([self conformsToProtocol:@protocol(MTLDevice)]) {
        NSString *fakeGPU = getConfigStr(@"zalo_metalGPU");
        if (fakeGPU) return fakeGPU;
    }
    return %orig;
}

%end

// ============================================================
// LAYER 16: Timing Anti-Fingerprint (fake_timing)
// Prevents timing-based device fingerprinting
// ============================================================
%hookf(uint64_t, mach_absolute_time) {
    uint64_t real = %orig;
    if (!fakeLayer(@"timing")) return real;

    id offset = getConfig(@"zalo_timingOffset");
    if (offset) {
        int64_t off = [offset longLongValue];
        return (uint64_t)((int64_t)real + off);
    }
    return real;
}

// CFAbsoluteTimeGetCurrent — used by many fingerprinting SDKs
%hookf(CFAbsoluteTime, CFAbsoluteTimeGetCurrent) {
    CFAbsoluteTime real = %orig;
    if (!fakeLayer(@"timing")) return real;

    // Add a small deterministic offset so boot-relative calculations differ
    id offset = getConfig(@"zalo_timingOffset");
    if (offset) {
        return real + ([offset doubleValue] / 1000000000.0);
    }
    return real;
}

// ============================================================
// LAYER 17: dladdr Hook — Hide tweak dylib from address lookup
// ============================================================
%hookf(int, dladdr, const void *addr, Dl_info *info) {
    int ret = %orig;
    if (!jbHideActive() || ret == 0 || !info || !info->dli_fname) return ret;

    NSString *path = [NSString stringWithUTF8String:info->dli_fname];
    // Hide our own tweak and substrate/substitute libs
    if ([path containsString:@"ChangeInfoIos"] ||
        [path containsString:@"Substrate"] ||
        [path containsString:@"TweakInject"] ||
        [path containsString:@"ElleKit"] ||
        [path containsString:@"libhooker"] ||
        [path containsString:@"substitute"]) {
        // Return fake info pointing to UIKit
        info->dli_fname = "/System/Library/Frameworks/UIKit.framework/UIKit";
        info->dli_sname = "UIApplicationMain";
        info->dli_saddr = NULL;
    }
    return ret;
}

// Strengthen _dyld_get_image_name to hide our dylib name
%hookf(const char *, _dyld_get_image_name, uint32_t image_index) {
    const char *name = %orig;
    if (!jbHideActive() || !name) return name;

    NSString *nameStr = [NSString stringWithUTF8String:name];
    if ([nameStr containsString:@"ChangeInfoIos"] ||
        [nameStr containsString:@"Substrate"] ||
        [nameStr containsString:@"TweakInject"] ||
        [nameStr containsString:@"ElleKit"] ||
        [nameStr containsString:@"libhooker"] ||
        [nameStr containsString:@"substitute"]) {
        return "/System/Library/Frameworks/UIKit.framework/UIKit";
    }
    return name;
}

// ============================================================
// LAYER 18: sysctl Process List Hiding (hide JB processes)
// ============================================================
%hookf(int, sysctl, int *name, u_int namelen, void *oldp, size_t *oldlenp, void *newp, size_t newlen) {
    int ret = %orig;
    if (!jbHideActive()) return ret;

    // KERN_PROC lookups — used to detect jailbreak-related processes
    if (namelen >= 2 && name[0] == CTL_KERN && name[1] == KERN_PROC) {
        if (oldp && oldlenp && *oldlenp > 0) {
            size_t structSize = sizeof(struct kinfo_proc);
            size_t count = *oldlenp / structSize;
            struct kinfo_proc *procs = (struct kinfo_proc *)oldp;

            NSArray *hiddenProcs = @[@"sshd", @"dropbear", @"Cydia", @"Sileo",
                                     @"jailbreakd", @"amfid_payload", @"launchd_jb",
                                     @"substituted", @"substrated", @"ellekit",
                                     @"palera1nd", @"dopamine", @"frida",
                                     @"cycript", @"debugserver"];

            size_t newCount = 0;
            for (size_t i = 0; i < count; i++) {
                NSString *procName = [NSString stringWithUTF8String:procs[i].kp_proc.p_comm];
                BOOL hidden = NO;
                for (NSString *h in hiddenProcs) {
                    if ([procName.lowercaseString containsString:h.lowercaseString]) {
                        hidden = YES;
                        break;
                    }
                }
                if (!hidden) {
                    if (newCount != i) {
                        procs[newCount] = procs[i];
                    }
                    newCount++;
                }
            }
            *oldlenp = newCount * structSize;
        }
    }

    return ret;
}

// ============================================================
// LAYER 19: App Tracking Transparency (ATTrackingManager)
// Always return denied to prevent tracking
// ============================================================
%hook ATTrackingManager

+ (NSUInteger)trackingAuthorizationStatus {
    if (!fakeLayer(@"ads")) return %orig;
    return 2; // ATTrackingManagerAuthorizationStatusDenied
}

+ (void)requestTrackingAuthorizationWithCompletionHandler:(void (^)(NSUInteger))completion {
    if (!fakeLayer(@"ads")) {
        %orig;
        return;
    }
    // Immediately return denied
    if (completion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(2); // Denied
        });
    }
}

%end

// ============================================================
// LAYER 20: NSLocale Deep Hooks (additional locale fingerprint vectors)
// ============================================================
%hook NSLocale

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

// ============================================================
// LAYER 21: UIDevice Deep Extensions (fake_uiddevice)
// Extra UIDevice properties apps use for fingerprinting
// ============================================================
%hook UIDevice

- (BOOL)isMultitaskingSupported {
    return YES;
}

- (UIUserInterfaceIdiom)userInterfaceIdiom {
    return UIUserInterfaceIdiomPhone;
}

%end

// ============================================================
// LAYER 22: NSBundle Version Spoofing (fake_sysosversion)
// Some apps read OS version from NSBundle/info.plist
// ============================================================
%hook NSBundle

- (NSDictionary *)infoDictionary {
    NSDictionary *orig = %orig;
    if (!fakeLayer(@"sysosversion")) return orig;

    // Only spoof the MAIN bundle's info for system version reads
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
// CONSTRUCTOR - Initialize on load
// ============================================================
%ctor {
    @autoreleasepool {
        NSLog(@"[ChangeInfoIos] Tweak loading...");

        // Load config
        loadConfig();

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

        // Hook IORegistryEntryCreateCFProperty
        void *iokitHandle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokitHandle) {
            orig_IORegistryEntryCreateCFProperty = (IORegCreateCFProp_t)dlsym(iokitHandle, "IORegistryEntryCreateCFProperty");
            if (orig_IORegistryEntryCreateCFProperty) {
                MSHookFunction((void *)orig_IORegistryEntryCreateCFProperty, (void *)hooked_IORegistryEntryCreateCFProperty, (void **)&orig_IORegistryEntryCreateCFProperty);
                NSLog(@"[ChangeInfoIos] IOKit hooked");
            }
        }

        NSLog(@"[ChangeInfoIos] Tweak loaded successfully! Config: %@", configLoaded ? @"YES" : @"NO");
    }
}
