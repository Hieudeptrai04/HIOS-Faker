// ChangeInfoIosMG v3.0.0 — single-dylib MG spoof.
//
// Loads into target apps (Zalo / FB / TikTok / IG / AIDA64 / Shopee).
// Hooks one symbol: MGCopyAnswer (via fishhook lazy-binding rebind).
// Reads spoof config from /var/jb/etc/changeinfoios/config.plist.
// Hot-path is zero-alloc + zero-NSLog to keep target apps smooth.
//
// Why single dylib (not v2.x per-app tweaks):
//   - 1 dylib mmap'd N times vs N dylibs = less RAM
//   - 1 fishhook trampoline vs N = less perf overhead per call
//   - All target apps share same key map / config reload notify

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <notify.h>
#import "fishhook.h"

// MSHookFunction — provided by ellekit/CydiaSubstrate. Used for IOKit
// framework functions which fishhook can't rebind (they're indirect
// symbol stubs / direct calls, not lazy-bound). Declared extern to
// avoid pulling in <substrate.h> (Theos auto-links libellekit).
extern void MSHookFunction(void *symbol, void *replace, void **result);

// ============================================================
// Config — backed by /var/jb/etc/changeinfoios/config.plist.
// Reloaded on darwin notify "com.changeinfoios.v3/ReloadConfig".
// Atomic pointer swap so hot-path readers never lock.
// ============================================================
static NSString *const kConfigPath = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kReloadNote = @"com.changeinfoios.v3/ReloadConfig";
static NSString *const kLegacyNote = @"com.changeinfoios/ReloadConfig";

// Plain strong ARC pointer + dispatch_once init. NSDictionary is
// immutable; multi-threaded reads are safe. The 8-byte aligned pointer
// store is atomic on arm64, so a concurrent reload can never tear the
// pointer — worst case a thread reads the previous dict for a few ns.
// Avoid _Atomic + ARC; their interaction releases too eagerly and the
// dylib crashes inside objc_retain when Firebase reads systemVersion
// from a background queue (observed in AIDA64 crash log 2026-05-25).
static NSDictionary *g_config = nil;
static dispatch_once_t g_loadOnce;

static void reloadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kConfigPath];
    g_config = d ?: @{};
}

static inline NSDictionary *cfg(void) {
    dispatch_once(&g_loadOnce, ^{ reloadConfig(); });
    return g_config;
}

static inline id getConfig(NSString *k) { return cfg()[k]; }
static inline NSString *getConfigStr(NSString *k) {
    id v = cfg()[k];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
    return nil;
}
static inline BOOL getConfigBool(NSString *k) {
    id v = cfg()[k];
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        return [s isEqualToString:@"1"] || [s isEqualToString:@"true"] || [s isEqualToString:@"yes"];
    }
    return NO;
}

static int64_t configValueAsMGInteger(NSString *configKey) {
    id val = getConfig(configKey);
    if (!val) return 0;
    if ([val isKindOfClass:[NSNumber class]]) return [(NSNumber *)val longLongValue];
    if ([val isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)val stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!s.length) return 0;
        if ([s hasPrefix:@"0x"] || [s hasPrefix:@"0X"]) {
            unsigned long long u = 0;
            NSScanner *sc = [NSScanner scannerWithString:s];
            if ([sc scanHexLongLong:&u]) return (int64_t)u;
        }
        return (int64_t)[s longLongValue];
    }
    return 0;
}

// ============================================================
// MG key → config key mapping. Copied verbatim from v2 Tweak.xm
// (extracted lines 1097-1207). Order: identity > radio > hardware
// caps > version > misc. If a target SDK reads a key not in this
// map, the unhooked call returns the real value — add the alias
// here if you observe a fingerprint mismatch.
// ============================================================
static NSDictionary *g_mgKeyMap = nil;
static void initMGKeyMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_mgKeyMap = @{
            @"UniqueDeviceID":@"UniqueDeviceID", @"SerialNumber":@"SerialNumber",
            @"UniqueChipID":@"UniqueChipID",
            @"InternationalMobileEquipmentIdentity":@"InternationalMobileEquipmentIdentity",
            @"InternationalMobileEquipmentIdentity2":@"InternationalMobileEquipmentIdentity2",
            @"MobileEquipmentIdentifier":@"MobileEquipmentIdentifier",
            @"IntegratedCircuitCardIdentity":@"IntegratedCircuitCardIdentity",
            @"IntegratedCircuitCardIdentity2":@"IntegratedCircuitCardIdentity2",
            @"PhoneNumber":@"PhoneNumber",
            @"ProductType":@"ProductType", @"HardwareModel":@"HardwareModel",
            @"HWModelStr":@"HWModelStr", @"ModelNumber":@"ModelNumber",
            @"RegionCode":@"RegionCode", @"RegionInfo":@"RegionInfo",
            @"WiFiAddress":@"WiFiAddress", @"BluetoothAddress":@"BluetoothAddress",
            @"EthernetAddress":@"EthernetAddress",
            @"BoardId":@"BoardId", @"HardwarePlatform":@"BoardId",
            @"ChipID":@"ChipID", @"FirmwareVersion":@"FirmwareVersion",
            @"BasebandVersion":@"BasebandVersion",
            @"BasebandSerialNumber":@"BasebandSerialNumber",
            @"BasebandChipId":@"BasebandChipId", @"BasebandCertId":@"BasebandCertId",
            @"BuildVersion":@"BuildVersion",
            @"ProductBuildVersion":@"BuildVersion",
            @"OSBuildVersion":@"BuildVersion",
            @"SoftwareBundleVersion":@"BuildVersion",
            @"ProductVersion":@"ProductVersion",
            @"ProductVersionString":@"ProductVersion",
            @"MaxSupportedOSVersion":@"ProductVersion",
            @"SupportedOSVersions":@"ProductVersion",
            @"DeviceColor":@"DeviceColor",
            @"DeviceEnclosureColor":@"DeviceEnclosureColor",
            @"DiskUsage":@"DiskUsage", @"TotalDiskCapacity":@"TotalDiskCapacity",
            @"TotalSystemAvailable":@"TotalSystemAvailable",
            @"BatteryCurrentCapacity":@"BatteryCurrentCapacity",
            @"BatteryIsCharging":@"BatteryIsCharging",
            @"BatterySerialNumber":@"BatterySerialNumber",
            @"BootNonce":@"BootNonce",
            @"DeviceName":@"DeviceNameMG",
            @"UserAssignedDeviceName":@"UserAssignedDeviceName",
            @"MarketingName":@"MarketingName",
            @"AirplaneMode":@"AirplaneMode",
            @"MobileSubscriberCountryCode":@"MobileSubscriberCountryCode",
            @"MobileSubscriberNetworkCode":@"MobileSubscriberNetworkCode",
            @"SIMTrayStatus":@"SIMTrayStatus",
            @"HasFaceID":@"HasFaceID", @"HasTouchID":@"HasTouchID",
            @"HasMesa":@"HasTouchID", @"HasHomeButton":@"HasHomeButton",
            @"HasOLEDDisplay":@"HasOLEDDisplay",
            @"Has5GUW":@"Has5G", @"HasNFC":@"HasNFC",
            @"HasCellularConnectivity":@"HasCellularConnectivity",
            @"HasBaseband":@"HasCellularConnectivity",
            @"InitialActivationDate":@"InitialActivationDate",
            @"ActivationState":@"ActivationState",
            @"ActivationStateAcknowledged":@"ActivationStateAcknowledged",
            @"DeviceVariant":@"DeviceVariant", @"DeviceVariantGUID":@"DeviceVariantGUID",
            @"RegulatoryModelNumber":@"RegulatoryModelNumber",
            @"MLBSerialNumber":@"SerialNumber",
            @"AirTelephonyCapability":@"HasCellularConnectivity",
            @"ApNonce":@"identifierForVendor", @"SEPNonce":@"identifierForVendor",
            @"BoardSerialNumber":@"SerialNumber",
            @"PartitionType":@"PartitionType",
            @"ProductHash":@"ProductType",
            @"DeviceClassNumber":@"ChipID",
            @"DeviceClass":@"DeviceClass",
        };
    });
}

// Keys whose iOS API returns an NSNumber (integer). Returning an
// NSString here would crash the caller via CFNumberGetValue.
static NSSet *g_intKeys = nil;
static void initIntKeys(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_intKeys = [NSSet setWithObjects:
            @"TotalDiskCapacity", @"TotalSystemAvailable", @"DiskUsage",
            @"BatteryCurrentCapacity", @"ChipID", @"BoardId",
            @"HardwarePlatform", @"UniqueChipID", nil];
    });
}

// ============================================================
// MGCopyAnswer hook. Hot path runs hundreds-of-thousands of times
// per session in chat / feed scrolling — every alloc costs.
// Re-entry guard: hook MAY recurse if CFLog/NSLog reach back into
// MG. Thread-local guard short-circuits the second pass.
// ============================================================
typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef property);
static MGCopyAnswer_t orig_MGCopyAnswer = NULL;
__thread int g_inMG = 0;

static CFTypeRef hooked_MGCopyAnswer(CFStringRef property) {
    if (g_inMG || !property) return orig_MGCopyAnswer(property);
    g_inMG = 1;

    NSString *key = (__bridge NSString *)property;
    NSString *configKey = g_mgKeyMap[key];
    if (!configKey) {
        CFTypeRef r = orig_MGCopyAnswer(property);
        g_inMG = 0;
        return r;
    }

    CFTypeRef result = NULL;

    if ([key isEqualToString:@"BatteryIsCharging"] ||
        [key isEqualToString:@"AirplaneMode"]) {
        if (getConfig(configKey)) {
            result = (__bridge_retained CFTypeRef)@(getConfigBool(configKey));
        }
    } else if ([g_intKeys containsObject:key]) {
        if (getConfig(configKey)) {
            int64_t v = configValueAsMGInteger(configKey);
            result = (__bridge_retained CFTypeRef)@(v);
        }
    } else {
        NSString *s = getConfigStr(configKey);
        if (s) result = (__bridge_retained CFTypeRef)s;
    }

    if (result) {
        g_inMG = 0;
        return result;
    }
    CFTypeRef orig = orig_MGCopyAnswer(property);
    g_inMG = 0;
    return orig;
}

// ============================================================
// LAYER 2: IORegistry — AIDA64-style apps read IOPlatformSerialNumber,
// IOPlatformUUID, board-id, model, serial-number, mlb-serial-number
// directly from IOKit registry (bypass MG). Hook both Create + Search.
// ============================================================
typedef CFTypeRef (*IORegCreateCFProp_t)(mach_port_t entry, CFStringRef key,
                                          CFAllocatorRef alloc, uint32_t options);
typedef CFTypeRef (*IORegSearchCFProp_t)(mach_port_t entry, const char *plane,
                                          CFStringRef key, CFAllocatorRef alloc,
                                          uint32_t options);
static IORegCreateCFProp_t orig_IORegCreate = NULL;
static IORegSearchCFProp_t orig_IORegSearch = NULL;

static NSDictionary *g_ioKeyMap = nil;
static void initIOKeyMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_ioKeyMap = @{
            @"IOPlatformSerialNumber":@"IOPlatformSerialNumber",
            @"IOPlatformUUID":@"IOPlatformUUID",
            @"board-id":@"IOBoardId",
            @"product-name":@"IOProductName",
            @"model":@"IOModel",
            @"serial-number":@"IODeviceTreeSerial",
            @"mlb-serial-number":@"IODeviceTreeMLBSerial",
            @"region-info":@"RegionInfo",
            @"region-code":@"RegionCode",
            @"model-number":@"ModelNumber",
            @"config-number":@"ModelNumber",
            @"device_type":@"IOProductName",
            @"target-type":@"IOProductName",
            @"chip-id":@"ChipID",
            @"board":@"IOBoardId",
            @"compatible":@"hw_machine",
            @"system-serial-number":@"IOPlatformSerialNumber",
        };
    });
}

static CFTypeRef ci_ioLookup(NSString *keyStr) {
    NSString *configKey = g_ioKeyMap[keyStr];
    if (!configKey) return NULL;
    NSString *val = getConfigStr(configKey);
    if (!val) return NULL;
    // Device-tree serial keys are stored as NSData (raw bytes) in IOKit.
    if ([keyStr isEqualToString:@"serial-number"] ||
        [keyStr isEqualToString:@"mlb-serial-number"] ||
        [keyStr isEqualToString:@"system-serial-number"]) {
        NSData *d = [val dataUsingEncoding:NSUTF8StringEncoding];
        return (__bridge_retained CFTypeRef)d;
    }
    return (__bridge_retained CFTypeRef)val;
}

static CFTypeRef hooked_IORegCreate(mach_port_t entry, CFStringRef key,
                                     CFAllocatorRef alloc, uint32_t options) {
    if (key) {
        initIOKeyMap();
        CFTypeRef sp = ci_ioLookup((__bridge NSString *)key);
        if (sp) return sp;
    }
    return orig_IORegCreate(entry, key, alloc, options);
}

static CFTypeRef hooked_IORegSearch(mach_port_t entry, const char *plane,
                                     CFStringRef key, CFAllocatorRef alloc,
                                     uint32_t options) {
    if (key) {
        initIOKeyMap();
        CFTypeRef sp = ci_ioLookup((__bridge NSString *)key);
        if (sp) return sp;
    }
    return orig_IORegSearch(entry, plane, key, alloc, options);
}

// ============================================================
// LAYER 3: UIDevice ObjC — UIDevice.model / .name / .systemName /
// .systemVersion / .identifierForVendor / .batteryLevel / .batteryState
// AIDA64 + most analytics SDKs query these directly.
// ============================================================
%hook UIDevice
- (NSString *)name {
    NSString *v = getConfigStr(@"deviceName"); return v ?: %orig;
}
- (NSString *)model {
    NSString *v = getConfigStr(@"deviceModel"); return v ?: %orig;
}
- (NSString *)localizedModel {
    NSString *v = getConfigStr(@"localizedModel"); return v ?: %orig;
}
- (NSString *)systemName {
    NSString *v = getConfigStr(@"systemName"); return v ?: %orig;
}
- (NSString *)systemVersion {
    NSString *v = getConfigStr(@"systemVersion"); return v ?: %orig;
}
- (NSUUID *)identifierForVendor {
    NSString *v = getConfigStr(@"identifierForVendor");
    if (v) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:v];
        if (u) return u;
    }
    return %orig;
}
- (float)batteryLevel {
    id v = getConfig(@"batteryLevel");
    return v ? [v floatValue] : %orig;
}
- (long)batteryState {
    id v = getConfig(@"batteryState");
    return v ? (long)[v integerValue] : %orig;
}
%end

// ============================================================
// ctor: install hook + register reload notify.
// ============================================================
static void notify_cb(int t) { (void)t; reloadConfig(); }

%ctor {
    @autoreleasepool {
        initMGKeyMap();
        initIntKeys();
        reloadConfig();

        // Resolve the original first so fishhook can chain to it.
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (h) orig_MGCopyAnswer = (MGCopyAnswer_t)dlsym(h, "MGCopyAnswer");
        if (!orig_MGCopyAnswer) return;

        // MGCopyAnswer: fishhook (works for lazy-bound MG calls).
        struct rebinding rebs[] = {
            { "MGCopyAnswer", (void *)hooked_MGCopyAnswer,
              (void **)&orig_MGCopyAnswer },
        };
        rebind_symbols(rebs, 1);

        // IORegistry: fishhook can't rebind IOKit framework calls (eager
        // bind / indirect stubs). Use MSHookFunction (ellekit) instead —
        // patches the function prologue with a branch to our trampoline.
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        if (iokit) {
            void *createSym = dlsym(iokit, "IORegistryEntryCreateCFProperty");
            if (createSym) MSHookFunction(createSym, (void *)hooked_IORegCreate,
                                          (void **)&orig_IORegCreate);
            void *searchSym = dlsym(iokit, "IORegistryEntrySearchCFProperty");
            if (searchSym) MSHookFunction(searchSym, (void *)hooked_IORegSearch,
                                          (void **)&orig_IORegSearch);
        }

        // Reload config on either notification (v3-native + legacy v2 app).
        int t1 = 0, t2 = 0;
        notify_register_dispatch([kReloadNote UTF8String], &t1,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });
        notify_register_dispatch([kLegacyNote UTF8String], &t2,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });

        NSString *marker = @"/var/jb/etc/changeinfoios/v3_mg_loaded.txt";
        NSString *exec = [[NSProcessInfo processInfo] processName] ?: @"?";
        NSString *body = [NSString stringWithFormat:@"%@ %@\n", exec, [NSDate date]];
        // Append (not overwrite) so multiple apps' loads are visible.
        FILE *f = fopen([marker UTF8String], "a");
        if (f) { fputs([body UTF8String], f); fclose(f); }
    }
}
