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
#import <execinfo.h>
#import <notify.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdio.h>
#import <unistd.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <errno.h>
#import <ifaddrs.h>
#import <net/if_dl.h>
#import <net/if.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <WebKit/WKWebView.h>
#import <WebKit/WKWebViewConfiguration.h>
#import <WebKit/WKUserContentController.h>
#import <WebKit/WKUserScript.h>
#import <WebKit/WKWebsiteDataStore.h>
#import <PushKit/PKPushRegistry.h>
#import <AdSupport/ASIdentifierManager.h>
#import <Security/Security.h>
#import <DeviceCheck/DeviceCheck.h>
#import <AppTrackingTransparency/AppTrackingTransparency.h>
#import "fishhook.h"

// MSHookFunction — provided by ellekit/CydiaSubstrate. Used for IOKit
// framework functions which fishhook can't rebind (they're indirect
// symbol stubs / direct calls, not lazy-bound). Declared extern "C"
// to avoid C++ name mangling (Logos preprocesses .xm as .mm).
#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

// ============================================================
// dbglog — append-only file logger using plain C stdio. NEVER use
// NSLog / NSString / NSDate inside the IORegistry hook path: they
// allocate, which on first-touch can hit IOKit (NSLocale region
// lookup, memory tag metadata) → re-enters our hook. fopen/fwrite
// are pure syscalls and safe even when g_inIOReg is set.
// Capped at kMaxDbgLines so a runaway hook doesn't fill /var.
// ============================================================
static FILE *g_dbglog = NULL;
static pthread_mutex_t g_dbglog_mu = PTHREAD_MUTEX_INITIALIZER;
static long g_dbglog_count = 0;
static const long kMaxDbgLines = 4000;
static const char *kDbgPath = "/var/jb/etc/changeinfoios/v3_mg_debug.log";

// Per-app tmp path (always writable from inside the app sandbox).
// /var/jb/etc/ writes silently fail from sandboxed App Store apps —
// even with 0666 perms, sandbox profile denies writes outside container.
// Resolved on first dbglog call via NSTemporaryDirectory().
static char g_dbgTmpPath[256] = "";
static char g_dbgTmpResolved = 0;

__attribute__((format(printf, 1, 2)))
static void dbglog(const char *fmt, ...) {
    if (g_dbglog_count > kMaxDbgLines) return;
    pthread_mutex_lock(&g_dbglog_mu);
    if (g_dbglog_count > kMaxDbgLines) { pthread_mutex_unlock(&g_dbglog_mu); return; }

    // Lazy resolve per-app tmp on first call (NSTemporaryDirectory
    // requires Foundation initialized — safe in %ctor since Logos
    // runs after Foundation +load chain).
    if (!g_dbgTmpResolved) {
        g_dbgTmpResolved = 1;
        @autoreleasepool {
            NSString *tmp = NSTemporaryDirectory();
            if (tmp && tmp.length) {
                NSString *p = [tmp stringByAppendingPathComponent:@"v3_mg_debug.log"];
                strncpy(g_dbgTmpPath, [p UTF8String], sizeof(g_dbgTmpPath) - 1);
            }
        }
    }

    // Try both targets; sandboxed apps will only succeed on the tmp one,
    // SpringBoard/daemons on the /var/jb one. Either is enough.
    if (!g_dbglog) g_dbglog = fopen(kDbgPath, "a");
    FILE *tmpf = (g_dbgTmpPath[0]) ? fopen(g_dbgTmpPath, "a") : NULL;

    if (g_dbglog || tmpf) {
        char buf[1024];
        va_list ap; va_start(ap, fmt);
        int n = vsnprintf(buf, sizeof(buf), fmt, ap);
        va_end(ap);
        if (n < 0) n = 0;
        if ((size_t)n >= sizeof(buf)) n = sizeof(buf) - 1;
        if (g_dbglog) { fwrite(buf, 1, n, g_dbglog); fflush(g_dbglog); }
        if (tmpf)     { fwrite(buf, 1, n, tmpf);     fclose(tmpf); }
        g_dbglog_count++;
    }
    pthread_mutex_unlock(&g_dbglog_mu);
}

// Process-name cached once — getprogname() is async-signal-safe and
// doesn't allocate. Used in every dbglog line so we can tell which
// app produced each entry when many apps share the log file.
static const char *g_procname = "?";

// ============================================================
// Config — backed by /var/jb/etc/changeinfoios/config.plist.
// Reloaded on darwin notify "com.changeinfoios.v3/ReloadConfig".
// Atomic pointer swap so hot-path readers never lock.
// ============================================================
static NSString *const kConfigPath = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kReloadNote  = @"com.changeinfoios.v3/ReloadConfig";
static NSString *const kLegacyNote  = @"com.changeinfoios/ReloadConfig";
static NSString *const kAppNote     = @"com.changeinfoios/ReloadPrefs"; // app sends this

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

    // MSHookFunction patches the MG prologue globally, so UIKit's internal
    // _UIDeviceNativeUserInterfaceIdiomIgnoringClassic also arrives here.
    // That UIKit function reads ProductType to load device-specific config
    // plists — returning a fake type for which no plist exists makes
    // initWithContentsOfFile: throw → std::terminate → SIGABRT.
    // Fix: pass through calls from /System/Library/ and /usr/lib/; only
    // intercept calls from app bundles (AIDA64 dlopen/dlsym, Zalo/FB SDKs).
    Dl_info _di; _di.dli_fname = NULL;
    dladdr(__builtin_return_address(0), &_di);
    if (_di.dli_fname) {
        const char *_fn = _di.dli_fname;
        if (strncmp(_fn, "/System/Library/", 16) == 0 ||
            strncmp(_fn, "/usr/lib/", 9) == 0 ||
            strncmp(_fn, "/var/jb/usr/lib/", 16) == 0) {
            return orig_MGCopyAnswer(property);
        }
    }

    g_inMG = 1;

    NSString *key = (__bridge NSString *)property;
    NSString *configKey = g_mgKeyMap[key];
    if (!configKey) {
        // Log first time we see this unmapped key so we can extend
        // the map after observing what AIDA / Zalo / FB actually query.
        char kb[128]; kb[0] = 0;
        if (CFStringGetCString(property, kb, sizeof(kb), kCFStringEncodingUTF8) && kb[0]) {
            dbglog("MG.miss %s %s\n", g_procname, kb);
        }
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
            // Observed in AIDA64 IORegCreate logs but un-spoofed:
            @"product-id":@"ProductType",
            // Network controllers — AIDA Network tab pulls MAC from IOKit,
            // not from getifaddrs. IOEthernetController + IO80211Controller
            // both expose IOMACAddress as NSData (6 bytes).
            @"IOMACAddress":@"WiFiAddress",
            @"IO80211InterfaceMACAddress":@"WiFiAddress",
            @"IO80211HardwareAddress":@"WiFiAddress",
            @"IOEthernetMACAddress":@"EthernetAddress",
        };
    });
}

// hw.model returns a BOARD ID (e.g. "D22AP" for iPhone X, "D54pAP"
// for 12 Pro Max), NOT a product type string. AIDA's marketing-name
// lookup expects board ID format; feeding it "iPhone13,4" makes the
// table miss and fall back. This table maps ProductType to BoardID
// for the common iPhone models we ship presets for. Add entries as
// the host app's preset DB grows.
static NSString *productTypeToBoardId(NSString *pt) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"iPhone8,4":@"N69uAP",                               // SE 1
            @"iPhone8,1":@"N71AP",   @"iPhone8,2":@"N66AP",       // 6s / 6s Plus
            @"iPhone9,1":@"D10AP",   @"iPhone9,2":@"D11AP",       // 7 / 7 Plus (US)
            @"iPhone9,3":@"D101AP",  @"iPhone9,4":@"D111AP",      // 7 / 7 Plus (intl)
            @"iPhone10,1":@"D20AP",  @"iPhone10,2":@"D21AP",      // 8 / 8 Plus (US)
            @"iPhone10,4":@"D201AP", @"iPhone10,5":@"D211AP",     // 8 / 8 Plus (intl)
            @"iPhone10,3":@"D22AP",  @"iPhone10,6":@"D221AP",     // X
            @"iPhone11,2":@"D321AP",                              // XS
            @"iPhone11,4":@"D331AP", @"iPhone11,6":@"D331pAP",    // XS Max
            @"iPhone11,8":@"N841AP",                              // XR
            @"iPhone12,1":@"N104AP",                              // 11
            @"iPhone12,3":@"D421AP", @"iPhone12,5":@"D431AP",     // 11 Pro / Max
            @"iPhone12,8":@"D79AP",                               // SE 2
            @"iPhone13,1":@"D52gAP", @"iPhone13,2":@"D53gAP",     // 12 mini / 12
            @"iPhone13,3":@"D53pAP", @"iPhone13,4":@"D54pAP",     // 12 Pro / Pro Max
            @"iPhone14,2":@"D63AP",  @"iPhone14,3":@"D64AP",      // 13 Pro / Pro Max
            @"iPhone14,4":@"D16AP",  @"iPhone14,5":@"D17AP",      // 13 mini / 13
            @"iPhone14,6":@"D49AP",                               // SE 3
            @"iPhone14,7":@"D27AP",  @"iPhone14,8":@"D28AP",      // 14 / 14 Plus
            @"iPhone15,2":@"D73AP",  @"iPhone15,3":@"D74AP",      // 14 Pro / Pro Max
            @"iPhone15,4":@"D37AP",  @"iPhone15,5":@"D38AP",      // 15 / 15 Plus
            @"iPhone16,1":@"D83AP",  @"iPhone16,2":@"D84AP",      // 15 Pro / Pro Max
        };
    });
    return map[pt];
}

// Forward decl — defined down in the libc-hook section.
static BOOL parseMAC6(const char *s, uint8_t out[6]);

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
    // IOMACAddress / IO80211*MACAddress / IOEthernetMACAddress = 6 raw bytes.
    // IOKit stores them as NSData, not "aa:bb:..." string. AIDA reads via
    // bytes → format-prints as colon-separated. Wrong encoding = no spoof.
    if ([keyStr isEqualToString:@"IOMACAddress"] ||
        [keyStr isEqualToString:@"IO80211InterfaceMACAddress"] ||
        [keyStr isEqualToString:@"IO80211HardwareAddress"] ||
        [keyStr isEqualToString:@"IOEthernetMACAddress"]) {
        uint8_t b[6];
        if (parseMAC6([val UTF8String], b)) {
            return (__bridge_retained CFTypeRef)[NSData dataWithBytes:b length:6];
        }
        return NULL;
    }
    return (__bridge_retained CFTypeRef)val;
}

// Re-entry guard: NSData/NSString creation inside ci_ioLookup may call
// IORegistry under the hood (NSLocale region lookup, memory tagging
// metadata) → re-enters our hook → infinite recursion → AIDA64 burns
// 40s CPU → frontboard scene-update watchdog kills (0x8BADF00D).
__thread int g_inIOReg = 0;

static CFTypeRef hooked_IORegCreate(mach_port_t entry, CFStringRef key,
                                     CFAllocatorRef alloc, uint32_t options) {
    if (g_inIOReg || !key) return orig_IORegCreate(entry, key, alloc, options);
    g_inIOReg = 1;
    initIOKeyMap();
    char kb[128]; kb[0] = 0;
    CFStringGetCString(key, kb, sizeof(kb), kCFStringEncodingUTF8);
    CFTypeRef sp = ci_ioLookup((__bridge NSString *)key);
    dbglog("IORegCreate %s key=%s spoof=%c\n", g_procname, kb, sp ? 'Y' : 'N');
    g_inIOReg = 0;
    if (sp) return sp;
    return orig_IORegCreate(entry, key, alloc, options);
}

static CFTypeRef hooked_IORegSearch(mach_port_t entry, const char *plane,
                                     CFStringRef key, CFAllocatorRef alloc,
                                     uint32_t options) {
    if (g_inIOReg || !key) return orig_IORegSearch(entry, plane, key, alloc, options);
    g_inIOReg = 1;
    initIOKeyMap();
    char kb[128]; kb[0] = 0;
    CFStringGetCString(key, kb, sizeof(kb), kCFStringEncodingUTF8);
    CFTypeRef sp = ci_ioLookup((__bridge NSString *)key);
    dbglog("IORegSearch %s plane=%s key=%s spoof=%c\n",
           g_procname, plane ? plane : "?", kb, sp ? 'Y' : 'N');
    g_inIOReg = 0;
    if (sp) return sp;
    return orig_IORegSearch(entry, plane, key, alloc, options);
}

// ============================================================
// IORegistryEntryCreateCFProperties (plural) — returns the WHOLE
// property dict for an IOKit node. AIDA64's "Device" tab pulls
// IOPlatformExpertDevice via this call and iterates the dict locally,
// so the per-key hooks above NEVER fire. We must intercept the dict
// and replace any spoofable keys before returning.
//
// Signature differs from the Create singular variant:
//   kern_return_t (mach_port_t entry, CFMutableDictionaryRef *out,
//                  CFAllocatorRef alloc, uint32_t options)
// The returned dict is sometimes immutable despite the type tag —
// always make a mutable copy, mutate, and swap.
// ============================================================
typedef kern_return_t (*IORegCreateCFProps_t)(mach_port_t entry,
                                               CFMutableDictionaryRef *out,
                                               CFAllocatorRef alloc,
                                               uint32_t options);
static IORegCreateCFProps_t orig_IORegCreateProps = NULL;

static kern_return_t hooked_IORegCreateProps(mach_port_t entry,
                                              CFMutableDictionaryRef *out,
                                              CFAllocatorRef alloc,
                                              uint32_t options) {
    if (g_inIOReg || !out) return orig_IORegCreateProps(entry, out, alloc, options);
    g_inIOReg = 1;
    kern_return_t kr = orig_IORegCreateProps(entry, out, alloc, options);
    if (kr == 0 && *out) {
        initIOKeyMap();
        CFIndex total = CFDictionaryGetCount(*out);
        CFMutableDictionaryRef mut = CFDictionaryCreateMutableCopy(alloc, 0, *out);
        int replaced = 0;
        if (mut) {
            for (NSString *ioKey in g_ioKeyMap) {
                CFStringRef cfKey = (__bridge CFStringRef)ioKey;
                if (!CFDictionaryContainsKey(mut, cfKey)) continue;
                CFTypeRef sp = ci_ioLookup(ioKey);
                if (sp) {
                    CFDictionarySetValue(mut, cfKey, sp);
                    CFRelease(sp);
                    replaced++;
                }
            }
            if (replaced > 0) {
                CFRelease(*out);
                *out = mut;
            } else {
                CFRelease(mut);
            }
        }
        dbglog("IORegCreateProps %s keys=%ld replaced=%d\n",
               g_procname, (long)total, replaced);
    } else {
        dbglog("IORegCreateProps %s kr=%d out=%p\n",
               g_procname, (int)kr, (void *)(out ? *out : NULL));
    }
    g_inIOReg = 0;
    return kr;
}

// ============================================================
// LAYER 2b: libc syscalls. Device-info viewers like AIDA64 do NOT
// link libMobileGestalt or IOKit — verified by `otool -L AIDA64_c3`
// showing only Foundation/UIKit/CoreTelephony/SystemConfiguration.
// They read hardware identity directly via libc:
//   - sysctlbyname("hw.machine") / "hw.model" → model identifier
//   - getifaddrs() → MAC addresses on AF_LINK sockaddrs
//   - gethostname() → device name (sometimes)
// MGCopyAnswer + IORegistry hooks above are useless for AIDA but
// still needed for Zalo/FB/IG (which DO use libMobileGestalt via
// Firebase / analytics SDKs).
//
// All three are lazy-bound in apps → fishhook rebinds them.
// ============================================================
typedef int (*sysctlbyname_t)(const char *, void *, size_t *, void *, size_t);
typedef int (*sysctl_raw_t)(int *, u_int, void *, size_t *, void *, size_t);
typedef int (*getifaddrs_t)(struct ifaddrs **);
typedef int (*gethostname_t)(char *, size_t);
static sysctlbyname_t orig_sysctlbyname = NULL;
static sysctl_raw_t   orig_sysctl_raw   = NULL;
static getifaddrs_t   orig_getifaddrs   = NULL;
static gethostname_t  orig_gethostname  = NULL;

// Re-entry guard mirrors IOReg pattern. NSString/CFString allocation
// inside the hook can itself call sysctlbyname (Foundation queries
// hw.physicalcpu for thread pool sizing on first touch) → recursion.
// Shared by both sysctlbyname and raw sysctl hooks so the inner
// orig_sysctlbyname→sysctl() chain doesn't re-enter either hook.
__thread int g_inSysctl = 0;

// sysctl key → config key. AIDA strings confirmed only hw.model +
// hw.machine, but apps in the wild query the whole hw.* and kern.*
// tree, so spoof everything we have data for.
static NSDictionary *g_sysctlMap = nil;
static void initSysctlMap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_sysctlMap = @{
            @"hw.machine":     @"hw_machine",
            @"hw.model":       @"hw_model",
            @"hw.product":     @"hw_machine",
            @"hw.targettype":  @"hw_machine",
            @"hw.memsize":     @"hw_memsize",
            @"hw.physmem":     @"hw_memsize",
            @"hw.ncpu":        @"processorCount",
            @"hw.activecpu":   @"processorCount",
            @"hw.physicalcpu": @"hw_physicalcpu",
            @"hw.logicalcpu":  @"hw_logicalcpu_max",
            @"hw.logicalcpu_max":  @"hw_logicalcpu_max",
            @"hw.physicalcpu_max": @"hw_physicalcpu",
            @"kern.hostname":         @"deviceName",
            @"kern.osversion":        @"BuildVersion",
            @"kern.osrelease":        @"systemVersion",
            @"kern.osproductversion": @"systemVersion",
            @"kern.boottime":         @"kern_boottime",
            @"kern.uuid":             @"IOPlatformUUID",
        };
    });
}

// Return 0 = success on string copy. Honors oldp==NULL probe-for-size
// pattern (caller calls twice: once with NULL to learn size, once with buf).
static int writeStringSysctl(const char *s, void *oldp, size_t *oldlenp) {
    size_t need = strlen(s) + 1;
    if (!oldp) { if (oldlenp) *oldlenp = need; return 0; }
    if (!oldlenp) return -1;
    size_t avail = *oldlenp;
    if (avail < need) {
        memcpy(oldp, s, avail);          // truncate, still set size
        ((char*)oldp)[avail - 1] = 0;
        *oldlenp = need;
        return -1;                        // ENOMEM equivalent
    }
    memcpy(oldp, s, need);
    *oldlenp = need;
    return 0;
}

static int writeIntegerSysctl(int64_t v, void *oldp, size_t *oldlenp, size_t width) {
    if (!oldp) { if (oldlenp) *oldlenp = width; return 0; }
    if (!oldlenp || *oldlenp < width) return -1;
    if (width == 4) { uint32_t u = (uint32_t)v; memcpy(oldp, &u, 4); }
    else            { uint64_t u = (uint64_t)v; memcpy(oldp, &u, 8); }
    *oldlenp = width;
    return 0;
}

static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                                void *newp, size_t newlen) {
    if (g_inSysctl || !name || newp) {
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    g_inSysctl = 1;
    initSysctlMap();
    NSString *ns = [NSString stringWithUTF8String:name];
    NSString *cfgKey = g_sysctlMap[ns];
    if (!cfgKey) {
        // Log hw.* and kern.* misses so we can see what the app actually queries
        if (strncmp(name, "hw.", 3) == 0 || strncmp(name, "kern.", 5) == 0)
            dbglog("sysctl.miss %s name=%s\n", g_procname, name);
        g_inSysctl = 0;
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    id v = getConfig(cfgKey);
    if (!v) {
        dbglog("sysctl.nocfg %s name=%s cfgKey=%s\n", g_procname, name, [cfgKey UTF8String]);
        g_inSysctl = 0;
        return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }

    // Real iOS hw.model returns a BOARD ID ("D22AP"), not a ProductType
    // ("iPhone10,3"). If our config gives us a ProductType, translate.
    if ([(NSString *)ns isEqualToString:@"hw.model"] &&
        [v isKindOfClass:[NSString class]] &&
        [(NSString *)v hasPrefix:@"iPhone"]) {
        NSString *board = productTypeToBoardId((NSString *)v);
        if (board) v = board;
    }

    int rc;
    if ([v isKindOfClass:[NSString class]]) {
        const char *sp = [(NSString *)v UTF8String];
        rc = writeStringSysctl(sp, oldp, oldlenp);
        dbglog("sysctl %s name=%s -> '%s' rc=%d\n", g_procname, name, sp, rc);
    } else if ([v isKindOfClass:[NSNumber class]]) {
        // Probe orig to learn caller's expected width (int vs long).
        size_t origLen = 0;
        orig_sysctlbyname(name, NULL, &origLen, NULL, 0);
        size_t width = (origLen == 4) ? 4 : 8;
        rc = writeIntegerSysctl([(NSNumber *)v longLongValue], oldp, oldlenp, width);
        dbglog("sysctl %s name=%s -> %lld (w=%zu) rc=%d\n",
               g_procname, name, [(NSNumber *)v longLongValue], width, rc);
    } else {
        rc = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    }
    g_inSysctl = 0;
    return rc;
}

// Raw sysctl() hook — AIDA64 and similar apps bypass sysctlbyname() by
// calling sysctl({CTL_HW, HW_MACHINE}, ...) with numeric MIBs directly.
// sysctlbyname() itself calls sysctl() internally, so we share g_inSysctl
// to prevent re-entry: if the inner orig_sysctlbyname→sysctl() chain fires,
// g_inSysctl is already 1 and we pass through instantly.
static int hooked_sysctl_raw(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                               void *newp, size_t newlen) {
    if (g_inSysctl || !name || newp || namelen < 2) {
        return orig_sysctl_raw(name, namelen, oldp, oldlenp, newp, newlen);
    }
    g_inSysctl = 1;

    const char *spoofed = NULL;
    if (name[0] == CTL_HW) {
        if (name[1] == HW_MACHINE) {
            NSString *v = getConfigStr(@"hw_machine");
            if (v) spoofed = [v UTF8String];
        } else if (name[1] == HW_MODEL) {
            NSString *v = getConfigStr(@"hw_model");
            if (v) {
                if ([v hasPrefix:@"iPhone"] || [v hasPrefix:@"iPad"] ||
                    [v hasPrefix:@"iPod"]) {
                    NSString *board = productTypeToBoardId(v);
                    if (board) v = board;
                }
                spoofed = [v UTF8String];
            }
        }
    }

    if (spoofed) {
        int rc = writeStringSysctl(spoofed, oldp, oldlenp);
        dbglog("sysctl_raw %s mib=[%d,%d] -> '%s' rc=%d\n",
               g_procname, name[0], name[1], spoofed, rc);
        g_inSysctl = 0;
        return rc;
    }

    g_inSysctl = 0;
    return orig_sysctl_raw(name, namelen, oldp, oldlenp, newp, newlen);
}

// gethostname → spoof to deviceName if set.
__thread int g_inHostname = 0;
static int hooked_gethostname(char *buf, size_t len) {
    if (g_inHostname || !buf || len == 0) return orig_gethostname(buf, len);
    g_inHostname = 1;
    NSString *v = getConfigStr(@"deviceName");
    if (!v) { g_inHostname = 0; return orig_gethostname(buf, len); }
    const char *s = [v UTF8String];
    size_t need = strlen(s);
    size_t cap = len - 1;
    size_t cp = need < cap ? need : cap;
    memcpy(buf, s, cp);
    buf[cp] = 0;
    g_inHostname = 0;
    dbglog("gethostname %s -> %s\n", g_procname, buf);
    return 0;
}

// Parse "aa:bb:cc:dd:ee:ff" → 6 raw bytes. Returns YES on success.
static BOOL parseMAC6(const char *s, uint8_t out[6]) {
    if (!s) return NO;
    unsigned int b[6];
    if (sscanf(s, "%x:%x:%x:%x:%x:%x", &b[0],&b[1],&b[2],&b[3],&b[4],&b[5]) != 6) return NO;
    for (int i = 0; i < 6; i++) out[i] = (uint8_t)(b[i] & 0xff);
    return YES;
}

// getifaddrs → call orig, walk linked list, replace MAC bytes in
// every AF_LINK sockaddr_dl based on interface name. The struct is
// mutable from the caller's view (caller passes it to freeifaddrs);
// rewriting the 6 bytes of MAC in place is safe — same alloc, same
// length, just different content.
__thread int g_inIfaddrs = 0;
static int hooked_getifaddrs(struct ifaddrs **ifap) {
    int rc = orig_getifaddrs(ifap);
    if (rc != 0 || g_inIfaddrs || !ifap || !*ifap) return rc;
    g_inIfaddrs = 1;

    NSString *wifiStr = getConfigStr(@"WiFiAddress");
    NSString *btStr   = getConfigStr(@"BluetoothAddress");
    NSString *ethStr  = getConfigStr(@"EthernetAddress");
    uint8_t wifi[6], bt[6], eth[6];
    BOOL hasWifi = wifiStr && parseMAC6([wifiStr UTF8String], wifi);
    BOOL hasBT   = btStr   && parseMAC6([btStr   UTF8String], bt);
    BOOL hasEth  = ethStr  && parseMAC6([ethStr  UTF8String], eth);

    int replaced = 0;
    for (struct ifaddrs *p = *ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
        struct sockaddr_dl *sdl = (struct sockaddr_dl *)p->ifa_addr;
        if (sdl->sdl_alen != 6) continue;
        const char *nm = p->ifa_name ?: "";
        const uint8_t *src = NULL;
        // en0 = WiFi on iOS; en1 / en2 = USB-eth / hotspot; bridge0 = bridge.
        // awdl0 / llw0 = peer-to-peer WiFi → keep as WiFi MAC.
        if      (strncmp(nm, "en0",    3) == 0 && hasWifi) src = wifi;
        else if (strncmp(nm, "awdl",   4) == 0 && hasWifi) src = wifi;
        else if (strncmp(nm, "llw",    3) == 0 && hasWifi) src = wifi;
        else if (strncmp(nm, "en",     2) == 0 && hasEth)  src = eth;
        else if (strncmp(nm, "bridge", 6) == 0 && hasEth)  src = eth;
        else if (strncmp(nm, "bluetooth", 9) == 0 && hasBT) src = bt;
        if (!src) continue;
        memcpy(LLADDR(sdl), src, 6);
        replaced++;
    }
    dbglog("getifaddrs %s replaced=%d\n", g_procname, replaced);
    g_inIfaddrs = 0;
    return rc;
}

// ============================================================
// SystemConfiguration: SCDynamicStoreCopyComputerName returns the
// user-visible device name ("Hieu's iPhone") for apps that don't use
// UIDevice.name (e.g. AIDA64 — it links SystemConfiguration.framework).
// MSHookFunction patches the symbol directly via dlsym.
// ============================================================
typedef CFStringRef (*SCDSCopyComputerName_t)(void *store, void *nameEncoding);
static SCDSCopyComputerName_t orig_SCDSCopyComputerName = NULL;

__thread int g_inSCDSName = 0;
static CFStringRef hooked_SCDSCopyComputerName(void *store, void *nameEncoding) {
    if (g_inSCDSName) return orig_SCDSCopyComputerName(store, nameEncoding);
    g_inSCDSName = 1;
    NSString *v = getConfigStr(@"deviceName");
    if (v) {
        dbglog("SCDSCopyComputerName %s -> %s\n", g_procname, [v UTF8String]);
        if (nameEncoding) *((CFStringEncoding *)nameEncoding) = kCFStringEncodingUTF8;
        g_inSCDSName = 0;
        return (CFStringRef)CFBridgingRetain([v copy]);
    }
    CFStringRef r = orig_SCDSCopyComputerName(store, nameEncoding);
    g_inSCDSName = 0;
    return r;
}

// ============================================================
// CNCopyCurrentNetworkInfo — returns SSID / BSSID of connected WiFi.
// AIDA64 reads WiFi network name from here, not from getifaddrs.
// Located in NetworkExtension.framework (iOS 14+). Intercepted via
// MSHookFunction since it's a C function, not lazy-bound in most apps.
// ============================================================
typedef CFDictionaryRef (*CNCopyCurrentNetworkInfo_t)(CFStringRef ifName);
static CNCopyCurrentNetworkInfo_t orig_CNCopyCurrentNetworkInfo = NULL;

static CFDictionaryRef hooked_CNCopyCurrentNetworkInfo(CFStringRef ifName) {
    CFDictionaryRef orig = orig_CNCopyCurrentNetworkInfo(ifName);
    if (!orig) return orig; // not connected — don't fake connectivity
    NSString *ssid = getConfigStr(@"wifiSSID");
    if (!ssid) return orig;
    NSMutableDictionary *d = [(__bridge NSDictionary *)orig mutableCopy];
    CFRelease(orig);
    d[@"SSID"] = ssid;
    d[@"SSIDDATA"] = [ssid dataUsingEncoding:NSUTF8StringEncoding];
    NSString *bssid = getConfigStr(@"wifiBSSID");
    if (bssid) d[@"BSSID"] = bssid;
    dbglog("CNCopyCurrentNetworkInfo %s ssid=%s\n", g_procname, [ssid UTF8String]);
    return (CFDictionaryRef)CFBridgingRetain(d);
}

// ============================================================
// LAYER 11: Keychain device-fingerprint isolation — Zalo reg-ban fix.
//
// Zalo stores a persistent device ID in Keychain that survives app
// reinstalls. During registration this ID is sent to VNG servers and
// cross-checked against the ban list. If the device was previously
// used for a banned account → instant ban on every new registration.
//
// Exact account names discovered via Keychain dump of vn.com.vng.zingalo:
//   kZAIDForDevice      — 32-char hex, the primary device fingerprint
//   zda_device_udid     — UUID format device ID
//   kZAIDForAdvertisingKey — Advertising UUID stored by Zalo (not IDFA)
//   kSecurityIndentifierKey — Security fingerprint (VNG's internal misspelling)
//   deviceUUID / deviceModel — ZaloSDK cached identity (svce: ...zalosdk)
//   firstTimeInstallApp / installSource — controls fresh-install flow
//   Firebase FID        — Firebase Installation ID used for analytics tracking
//
// Hook: SecItemCopyMatching returns errSecItemNotFound for these keys when
// identity spoofing is active. Zalo generates fresh IDs → clean registration.
// SecItemAdd is NOT blocked (new IDs for this session are stored normally).
// ============================================================
#import <Security/Security.h>

// Exact account names to block — from live Keychain dump of Zalo 23.x
static const char * const kZaloFpAccounts[] = {
    "kZAIDForDevice",           // Primary device fingerprint (32-char hex)
    "kZAIDForAdvertisingKey",   // Zalo advertising UUID (different from IDFA)
    "zda_device_udid",          // Device UDID (UUID format)
    "kSecurityIndentifierKey",  // Security fingerprint (note VNG typo)
    "kThisDeviceOnlyKey",       // Device-only preference flag
    "_pfo",                     // Platform fingerprint object
    // ZaloSDK (svce: vn.com.vng.zingalo.zalosdk)
    "deviceUUID",               // SDK device UUID
    "deviceModel",              // SDK cached model — inconsistency with MG spoof
    "firstTimeInstallApp",      // First-install flow controller
    "installSource",            // Install source tag
    NULL
};

typedef OSStatus (*SecItemCopyMatching_t)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*SecItemDelete_t)(CFDictionaryRef);
static SecItemCopyMatching_t orig_SecItemCopyMatching = NULL;

static BOOL isZaloFingerprintQuery(CFDictionaryRef query) {
    if (!query) return NO;
    // Only active when device identity spoof is enabled
    if (!getConfigStr(@"UniqueDeviceID") && !getConfigStr(@"SerialNumber")) return NO;
    CFStringRef acc = (CFStringRef)CFDictionaryGetValue(query, kSecAttrAccount);
    if (!acc || CFGetTypeID(acc) != CFStringGetTypeID()) return NO;
    char ab[128]; ab[0] = 0;
    CFStringGetCString(acc, ab, sizeof(ab), kCFStringEncodingUTF8);
    for (int i = 0; kZaloFpAccounts[i]; i++) {
        if (strcmp(ab, kZaloFpAccounts[i]) == 0) return YES;
    }
    // Block Firebase Installation ID by service (prevents device-level tracking)
    CFStringRef svc = (CFStringRef)CFDictionaryGetValue(query, kSecAttrService);
    if (svc && CFGetTypeID(svc) == CFStringGetTypeID()) {
        char sb[128]; sb[0] = 0;
        CFStringGetCString(svc, sb, sizeof(sb), kCFStringEncodingUTF8);
        if (strstr(sb, "FIRInstallations") || strstr(sb, "firebase")) return YES;
    }
    return NO;
}

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (isZaloFingerprintQuery(query)) {
        CFStringRef acc = (CFStringRef)CFDictionaryGetValue(query, kSecAttrAccount);
        char ab[64]; ab[0] = 0;
        if (acc && CFGetTypeID(acc) == CFStringGetTypeID())
            CFStringGetCString(acc, ab, sizeof(ab), kCFStringEncodingUTF8);
        dbglog("Keychain.block %s acct=%s\n", g_procname, ab);
        return errSecItemNotFound;
    }
    return orig_SecItemCopyMatching(query, result);
}

// Wipe Zalo's stored device fingerprints from Keychain.
// Called when running inside Zalo's process on identity reload (ReloadConfig).
// From inside the target process we have Zalo's keychain-access-groups entitlement
// so SecItemDelete succeeds where it would fail from an outside process.
static void wipeZaloKeychainFingerprints(void) {
    NSString *const kAgrp = @"CVB6BX97VM.group.keychain.vn.com.vng.zalo";
    int deleted = 0;
    for (int i = 0; kZaloFpAccounts[i]; i++) {
        NSDictionary *q = @{
            (__bridge id)kSecClass:           (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount:     [NSString stringWithUTF8String:kZaloFpAccounts[i]],
            (__bridge id)kSecAttrAccessGroup: kAgrp,
        };
        if (SecItemDelete((__bridge CFDictionaryRef)q) == errSecSuccess) deleted++;
    }
    // Delete Firebase Installation record (matches by service, not account)
    NSDictionary *fbq = @{
        (__bridge id)kSecClass:           (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:     @"com.firebase.FIRInstallations.installations",
        (__bridge id)kSecAttrAccessGroup: kAgrp,
    };
    if (SecItemDelete((__bridge CFDictionaryRef)fbq) == errSecSuccess) deleted++;
    dbglog("wipeZaloKC %s deleted=%d\n", g_procname, deleted);
}

// LAYER 11 (cont): Block SecItemAdd/SecItemUpdate for device fingerprint keys.
// SecItemCopyMatching already returns not-found, making Zalo generate a fresh
// device UUID each launch. Without blocking Add/Update, that fresh UUID gets
// written to Keychain and persists until the next wipe — adding noise across
// multiple registrations on the same session. Returning errSecSuccess from Add
// (without actually storing) keeps Zalo happy without persisting anything.
typedef OSStatus (*SecItemAdd_t)(CFDictionaryRef, CFTypeRef *);
typedef OSStatus (*SecItemUpdate_t)(CFDictionaryRef, CFDictionaryRef);
static SecItemAdd_t    orig_SecItemAdd    = NULL;
static SecItemUpdate_t orig_SecItemUpdate = NULL;

static OSStatus hooked_SecItemAdd(CFDictionaryRef attrs, CFTypeRef *result) {
    if (isZaloFingerprintQuery(attrs)) {
        CFStringRef acc = (CFStringRef)CFDictionaryGetValue(attrs, kSecAttrAccount);
        char ab[64]; ab[0] = 0;
        if (acc && CFGetTypeID(acc) == CFStringGetTypeID())
            CFStringGetCString(acc, ab, sizeof(ab), kCFStringEncodingUTF8);
        dbglog("Keychain.blockAdd %s acct=%s\n", g_procname, ab);
        if (result) *result = NULL;
        return errSecSuccess; // lie to Zalo — it thinks the store succeeded
    }
    return orig_SecItemAdd(attrs, result);
}
static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
    if (isZaloFingerprintQuery(query)) {
        dbglog("Keychain.blockUpdate %s\n", g_procname);
        return errSecItemNotFound;
    }
    return orig_SecItemUpdate(query, attrs);
}

// ============================================================
// LAYER 3: UIDevice ObjC — UIDevice.model / .name / .systemName /
// .systemVersion / .identifierForVendor / .batteryLevel / .batteryState
// AIDA64 + most analytics SDKs query these directly.
// ============================================================
%hook UIDevice
- (NSInteger)userInterfaceIdiom {
    NSString *pt = getConfigStr(@"ProductType");
    if (!pt) return %orig;
    if ([pt hasPrefix:@"iPad"]) return 1; // UIUserInterfaceIdiomPad
    return 0; // UIUserInterfaceIdiomPhone
}
- (NSString *)name {
    NSString *v = getConfigStr(@"deviceName");
    dbglog("UIDevice.name %s spoof=%c orig?=%c\n", g_procname, v?'Y':'N', v?'.':'?');
    return v ?: %orig;
}
- (NSString *)model {
    NSString *v = getConfigStr(@"deviceModel");
    dbglog("UIDevice.model %s spoof=%c\n", g_procname, v?'Y':'N');
    return v ?: %orig;
}
- (NSString *)localizedModel {
    NSString *v = getConfigStr(@"localizedModel"); return v ?: %orig;
}
- (NSString *)systemName {
    NSString *v = getConfigStr(@"systemName"); return v ?: %orig;
}
- (NSString *)systemVersion {
    NSString *v = getConfigStr(@"systemVersion");
    dbglog("UIDevice.systemVersion %s spoof=%c\n", g_procname, v?'Y':'N');
    return v ?: %orig;
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
// LAYER 4: CLLocationManager — GPS spoof.
// lat/lon/altitude come from config keys set by ci_applyGeoFromIPAPI
// (proxy-IP path) or the VN-city fallback in ci_randomizeIdentities.
// Authorization silently granted → no permission dialog during reg.
// Fake CLLocation delivered to delegate 300ms after startUpdating.
// ============================================================
%hook CLLocationManager
+ (BOOL)locationServicesEnabled {
    if (getConfigStr(@"latitude")) return YES;
    return %orig;
}
+ (int)authorizationStatus {
    // kCLAuthorizationStatusAuthorizedAlways = 3
    if (getConfigStr(@"latitude")) return 3;
    return %orig;
}
- (int)authorizationStatus {
    if (getConfigStr(@"latitude")) return 3;
    return %orig;
}
- (void)requestWhenInUseAuthorization {
    if (!getConfigStr(@"latitude")) { %orig; return; }
    // Simulate "user tapped Allow" by firing the auth-change callback,
    // then immediately deliver a fake location fix.
    __weak id<CLLocationManagerDelegate> wdel = self.delegate;
    __weak CLLocationManager *wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        CLLocationManager *mgr = wself;
        id<CLLocationManagerDelegate> del = wdel;
        if (!mgr || !del) return;
        // iOS 14+ unified callback
        if ([del respondsToSelector:@selector(locationManagerDidChangeAuthorization:)])
            [del locationManagerDidChangeAuthorization:mgr];
        // Pre-iOS 14 callback (CLAuthorizationStatus = int)
        if ([del respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)])
            [del locationManager:mgr didChangeAuthorizationStatus:kCLAuthorizationStatusAuthorizedAlways];
        [mgr startUpdatingLocation];
    });
}
- (void)requestAlwaysAuthorization { [self requestWhenInUseAuthorization]; }
- (void)startUpdatingLocation {
    NSString *latS = getConfigStr(@"latitude");
    NSString *lonS = getConfigStr(@"longitude");
    if (!latS || !lonS) { %orig; return; }
    CLLocationCoordinate2D c = {latS.doubleValue, lonS.doubleValue};
    double alt = getConfigStr(@"altitude") ? [getConfigStr(@"altitude") doubleValue] : 15.0;
    CLLocation *fake = [[CLLocation alloc] initWithCoordinate:c
                altitude:alt horizontalAccuracy:10.0 verticalAccuracy:5.0
                timestamp:[NSDate date]];
    dbglog("CLLocation.start %s lat=%.4f lon=%.4f alt=%.0f\n",
           g_procname, c.latitude, c.longitude, alt);
    __weak id<CLLocationManagerDelegate> wdel = self.delegate;
    __weak CLLocationManager *wself = self;
    // 50ms — fast enough to beat locationd's first real-GPS callback,
    // but one runloop after startUpdatingLocation so delegate is ready.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        id<CLLocationManagerDelegate> del = wdel;
        CLLocationManager *mgr = wself;
        if (!del || !mgr) return;
        if ([del respondsToSelector:@selector(locationManager:didUpdateLocations:)])
            [del locationManager:mgr didUpdateLocations:@[fake]];
    });
}
- (void)requestLocation { [self startUpdatingLocation]; }
// Significant-location-change service (used by Maps background tracking):
// don't start real monitoring, just deliver one fake fix.
- (void)startMonitoringSignificantLocationChanges { [self startUpdatingLocation]; }
- (void)stopMonitoringSignificantLocationChanges  { /* no-op */ }
- (CLLocation *)location {
    NSString *latS = getConfigStr(@"latitude");
    NSString *lonS = getConfigStr(@"longitude");
    if (!latS || !lonS) return %orig;
    CLLocationCoordinate2D c = {latS.doubleValue, lonS.doubleValue};
    double alt = getConfigStr(@"altitude") ? [getConfigStr(@"altitude") doubleValue] : 15.0;
    return [[CLLocation alloc] initWithCoordinate:c altitude:alt
            horizontalAccuracy:5.0 verticalAccuracy:3.0 timestamp:[NSDate date]];
}
// speedFilter / distanceFilter don't matter since we own the delivery.
- (CLLocationDistance)distanceFilter { return kCLDistanceFilterNone; }
// pausesLocationUpdatesAutomatically = NO prevents iOS from stopping
// our fake delivery when the app "stops moving".
- (BOOL)pausesLocationUpdatesAutomatically { return NO; }
%end

// CLGeocoder: no hook needed. When Maps/Weather call
// [geocoder reverseGeocodeLocation:clm.location], clm.location
// already returns our fake coordinates (hook above). Apple's
// geocoding server receives the fake lat/lon and returns the
// correct fake city — real device location never leaves the device.

// ============================================================
// LAYER 5: NSLocale / NSTimeZone — language, region, timezone spoof.
// Config keys localeIdentifier/localeLanguageCode/localeCountryCode/
// localeCurrencyCode/timezoneName must match GPS city and carrier.
// ============================================================
%hook NSLocale
+ (instancetype)currentLocale {
    static __thread BOOL _inLocale = NO;
    if (_inLocale) return %orig;
    NSString *ident = getConfigStr(@"localeIdentifier");
    if (!ident) return %orig;
    _inLocale = YES;
    NSLocale *fake = [[NSLocale alloc] initWithLocaleIdentifier:ident];
    _inLocale = NO;
    return fake ?: %orig;
}
+ (instancetype)autoupdatingCurrentLocale {
    static __thread BOOL _inAuto = NO;
    if (_inAuto) return %orig;
    _inAuto = YES;
    id r = [self currentLocale];
    _inAuto = NO;
    return r;
}
+ (NSArray *)preferredLanguages {
    NSString *lang = getConfigStr(@"localeLanguageCode");
    NSString *rgn  = getConfigStr(@"localeCountryCode");
    if (!lang) return %orig;
    NSString *tag = rgn ? [NSString stringWithFormat:@"%@-%@", lang, rgn] : lang;
    return @[tag, @"en-US"]; // en-US fallback keeps system string formatting sane
}
%end

%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    static __thread BOOL _inTZ = NO;
    if (_inTZ) return %orig;
    NSString *name = getConfigStr(@"timezoneName");
    if (!name) return %orig;
    _inTZ = YES;
    NSTimeZone *tz = [NSTimeZone timeZoneWithName:name];
    _inTZ = NO;
    return tz ?: %orig;
}
+ (NSTimeZone *)localTimeZone   { return [self systemTimeZone]; }
+ (NSTimeZone *)defaultTimeZone { return [self systemTimeZone]; }
%end

// ============================================================
// LAYER 6: CTCarrier — carrier name / MCC / MNC spoof.
// Apps may call CTTelephonyNetworkInfo.serviceSubscriberCellularProviders
// (returning CTCarrier objects) instead of querying MGCopyAnswer,
// bypassing the MG hook. Hook the CTCarrier ObjC methods directly.
// ============================================================
%hook CTCarrier
- (NSString *)carrierName {
    NSString *v = getConfigStr(@"carrierName");
    dbglog("CTCarrier.carrierName %s -> %s\n", g_procname, v ? [v UTF8String] : "orig");
    return v ?: %orig;
}
- (NSString *)mobileCountryCode {
    return getConfigStr(@"carrierMCC") ?: getConfigStr(@"MobileSubscriberCountryCode") ?: %orig;
}
- (NSString *)mobileNetworkCode {
    return getConfigStr(@"carrierMNC") ?: getConfigStr(@"MobileSubscriberNetworkCode") ?: %orig;
}
- (NSString *)isoCountryCode {
    NSString *iso = getConfigStr(@"carrierISO");
    if (!iso) { iso = getConfigStr(@"RegionCode"); }
    return iso ? iso.lowercaseString : %orig;
}
- (BOOL)allowsVOIP { return YES; }
%end

// ============================================================
// LAYER 7: ASIdentifierManager — IDFA advertising identifier spoof.
// advertisingIdentifier UUID is set in config by ci_randomizeIdentities.
// isAdvertisingTrackingEnabled returns YES so apps don't fall back to
// alternative tracking (which could leak real device identity).
// ============================================================
%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    NSString *v = getConfigStr(@"advertisingIdentifier");
    if (v) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:v];
        if (u) {
            dbglog("IDFA %s -> %s\n", g_procname, [v UTF8String]);
            return u;
        }
    }
    return %orig;
}
- (BOOL)isAdvertisingTrackingEnabled { return YES; }
%end

// ============================================================
// LAYER 8: WKWebView — user-agent + LAYER 14: JavaScript fingerprint spoof.
//
// LAYER 8: UA string — zalo_fakeWebViewUA set by ci_randomizeIdentities.
// LAYER 14: Inject WKUserScript at document start to override:
//   navigator.language/languages/platform/maxTouchPoints/hardwareConcurrency
//   screen.width/height/availWidth/availHeight/colorDepth/pixelDepth
//   window.devicePixelRatio
//   HTMLCanvasElement.toDataURL (1-pixel LSB noise per call → unique canvas hash)
//   WebGLRenderingContext.getParameter (UNMASKED_VENDOR/RENDERER → "Apple Inc."/"Apple GPU")
//
// Why: Vietnamese apps (Zalo, Shopee, Facebook) fingerprint the embedded WebView
// JS environment. navigator.language/platform/screen dimensions must match the
// spoofed ProductType + localeIdentifier or the server detects inconsistency.
// ============================================================

// Screen dimensions (CSS logical pixels, not physical) + DPR per ProductType.
// iOS reports screen.width in points (1 pt = DPR physical pixels).
static void screenDimsForProductType(NSString *pt, int *sw, int *sh, double *dpr, int *hc) {
    *sw = 390; *sh = 844; *dpr = 3.0; *hc = 6; // default: iPhone 13/14
    if (!pt || !pt.length) return;
    // SE 2nd/3rd gen (4.7" Retina)
    if ([pt hasPrefix:@"iPhone12,8"] || [pt hasPrefix:@"iPhone14,6"]) {
        *sw = 375; *sh = 667; *dpr = 2.0; *hc = 6;
    // XR / 11 (6.1" LCD, 2x)
    } else if ([pt hasPrefix:@"iPhone11,8"] || [pt hasPrefix:@"iPhone12,1"]) {
        *sw = 414; *sh = 896; *dpr = 2.0; *hc = 6;
    // Xs Max / 11 Pro Max (6.5" OLED, 3x)
    } else if ([pt hasPrefix:@"iPhone12,3"] || [pt hasPrefix:@"iPhone12,5"]) {
        *sw = 414; *sh = 896; *dpr = 3.0; *hc = 6;
    // 12 mini / 13 mini
    } else if ([pt hasPrefix:@"iPhone13,1"] || [pt hasPrefix:@"iPhone14,4"]) {
        *sw = 375; *sh = 812; *dpr = 3.0; *hc = 6;
    // 12 / 13 / 14 / 12 Pro / 13 Pro / 14 Pro (390×844)
    } else if ([pt hasPrefix:@"iPhone13,2"] || [pt hasPrefix:@"iPhone13,3"] ||
               [pt hasPrefix:@"iPhone14,2"] || [pt hasPrefix:@"iPhone14,5"]) {
        *sw = 390; *sh = 844; *dpr = 3.0; *hc = 6;
    // 12 Pro Max / 13 Pro Max / 14 Plus (428×926)
    } else if ([pt hasPrefix:@"iPhone13,4"] || [pt hasPrefix:@"iPhone14,3"]) {
        *sw = 428; *sh = 926; *dpr = 3.0; *hc = 6;
    // 14 Pro / 15 / 15 Pro (393×852)
    } else if ([pt hasPrefix:@"iPhone15,2"] || [pt hasPrefix:@"iPhone15,4"] ||
               [pt hasPrefix:@"iPhone16,1"]) {
        *sw = 393; *sh = 852; *dpr = 3.0; *hc = ([pt hasPrefix:@"iPhone16"] ? 8 : 6);
    // 14 Pro Max / 15 Plus / 15 Pro Max (430×932)
    } else if ([pt hasPrefix:@"iPhone15,3"] || [pt hasPrefix:@"iPhone15,5"] ||
               [pt hasPrefix:@"iPhone16,2"]) {
        *sw = 430; *sh = 932; *dpr = 3.0; *hc = ([pt hasPrefix:@"iPhone16"] ? 8 : 6);
    }
}

static NSString *buildWKJSSpoof(void) {
    NSString *lang = getConfigStr(@"localeLanguageCode") ?: @"vi";
    NSString *rgn  = getConfigStr(@"localeCountryCode")  ?: @"VN";
    NSString *tag  = [NSString stringWithFormat:@"%@-%@", lang, rgn];
    int sw, sh, hc; double dpr;
    screenDimsForProductType(getConfigStr(@"ProductType"), &sw, &sh, &dpr, &hc);
    return [NSString stringWithFormat:
        @"(function(){"
         "var l='%@',ls=['%@','en-US'],sw=%d,sh=%d,dpr=%.1f,hc=%d;"
         "function d(o,k,v){"
         "try{Object.defineProperty(o,k,{get:function(){return v;},configurable:true});}catch(e){}}"
         "d(navigator,'language',l);"
         "d(navigator,'languages',Object.freeze(ls));"
         "d(navigator,'platform','iPhone');"
         "d(navigator,'maxTouchPoints',5);"
         "d(navigator,'hardwareConcurrency',hc);"
         "d(screen,'width',sw);d(screen,'height',sh);"
         "d(screen,'availWidth',sw);d(screen,'availHeight',sh-44);"
         "d(screen,'colorDepth',24);d(screen,'pixelDepth',24);"
         "d(window,'devicePixelRatio',dpr);"
         // Canvas 1-pixel LSB noise so hash differs each page load
         "var _ot=HTMLCanvasElement.prototype.toDataURL;"
         "HTMLCanvasElement.prototype.toDataURL=function(){"
         "var c=this.getContext&&this.getContext('2d');"
         "if(c&&this.width>0&&this.height>0){"
         "try{var id=c.getImageData(0,0,1,1);"
         "id.data[0]=(id.data[0]+1)&255;"
         "c.putImageData(id,0,0);}catch(e){}}"
         "return _ot.apply(this,arguments);};"
         // WebGL renderer → Apple GPU (consistent with all real iPhones)
         "function pg(G){"
         "if(!G)return;"
         "var op=G.prototype.getParameter;"
         "G.prototype.getParameter=function(p){"
         "if(p===0x9245)return'Apple Inc.';"
         "if(p===0x9246)return'Apple GPU';"
         "return op.apply(this,arguments);};}"
         "pg(window.WebGLRenderingContext);"
         "if(window.WebGL2RenderingContext)pg(window.WebGL2RenderingContext);"
         "})();",
        tag, tag, sw, sh, dpr, hc];
}

%hook WKWebView
- (NSString *)customUserAgent {
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    return ua ?: %orig;
}
- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration *)cfg {
    WKWebView *v = %orig;
    if (!v) return v;
    NSString *ua = getConfigStr(@"zalo_fakeWebViewUA");
    if (ua) [v setCustomUserAgent:ua];
    NSString *js = buildWKJSSpoof();
    if (js) {
        WKUserScript *script = [[WKUserScript alloc]
            initWithSource:js
            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
            forMainFrameOnly:NO];
        [v.configuration.userContentController addUserScript:script];
        dbglog("WKWebView.init %s ua+js injected sw=%d\n", g_procname,
               (int)[UIScreen mainScreen].bounds.size.width);
    }
    return v;
}
%end

// ============================================================
// LAYER 9: Jailbreak hiding — block common JB detection vectors.
// Hooks: stat, lstat, access (C), NSFileManager (ObjC),
//        UIApplication -canOpenURL: (URL scheme check).
// Exempts our own config dir so config reads keep working.
// Does NOT hide loaded dylib list — use Shadow/KernBypass for TikTok.
// ============================================================

static BOOL isJBPath(const char *path) {
    if (!path) return NO;
    // Never hide our own config directory — reloadConfig must still work
    static const char kCfgDir[] = "/var/jb/etc/changeinfoios/";
    if (strncmp(path, kCfgDir, sizeof(kCfgDir)-1) == 0) return NO;
    static const char * const kHide[] = {
        "/var/jb", "/private/var/jb",
        "/var/lib/apt", "/private/var/lib/apt",
        "/var/lib/cydia", "/var/cache/apt",
        "/Applications/Cydia.app", "/Applications/Sileo.app",
        "/Applications/Zebra.app", "/Applications/filza.app",
        "/Library/MobileSubstrate", "/var/MobileSubstrate",
        "/usr/lib/libsubstrate.dylib", "/usr/lib/substrate",
        "/var/checkra1n.dmg", "/.bootstraprc", "/bootstraprc",
        "/private/etc/apt", "/etc/apt",
        NULL
    };
    for (int i = 0; kHide[i]; i++) {
        if (strncmp(path, kHide[i], strlen(kHide[i])) == 0) return YES;
    }
    return NO;
}

typedef int (*stat_fn_t)(const char *, struct stat *);
typedef int (*access_fn_t)(const char *, int);
static stat_fn_t   orig_stat_fn   = NULL;
static stat_fn_t   orig_lstat_fn  = NULL;
static access_fn_t orig_access_fn = NULL;

// Return YES if the given dylib path belongs to a jailbreak tweak
// (lives under /var/jb/Library/ or /var/jb/usr/lib/). Our own dylib
// also lives there, so our internal accesses pass through too.
static inline BOOL fnameIsJBTweak(const char *f) {
    if (!f) return NO;
    return (strncmp(f, "/var/jb/Library/", 16) == 0 ||
            strncmp(f, "/var/jb/usr/lib/", 16) == 0 ||
            strncmp(f, "/private/var/jb/Library/", 24) == 0 ||
            strncmp(f, "/private/var/jb/usr/lib/", 24) == 0);
}

// Path of OUR OWN dylib (ChangeInfoIosMG.dylib), resolved once. Our hook
// and helper functions live under /var/jb/Library/ too, so we must skip
// our own frames when walking the stack — otherwise every call would
// "look like" a JB-tweak caller and the hiding would never apply.
static const char *g_selfImage = NULL;
static void initSelfImage(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Dl_info di; di.dli_fname = NULL;
        if (dladdr((void *)&initSelfImage, &di) && di.dli_fname)
            g_selfImage = strdup(di.dli_fname);
    });
}

// Walk several stack frames; YES if any frame belongs to a JB tweak dylib
// OTHER than ourselves (e.g. VCam).
//
// The old check only looked at __builtin_return_address(1) — the single
// immediate caller. That missed tweaks (e.g. VCam) that reach a hooked
// function through one or two Foundation/libsystem wrapper frames
// (VCam -> [NSFileManager fileExistsAtPath:] -> stat), so their own
// /var/jb/ access got blocked. Walking up to 16 frames catches the tweak
// wherever it sits in the proximate call chain.
//
// Safe against false-positives: anti-fraud JB scans run from app/SDK code
// (no tweak frames in their stack), and tweaks like VCam only appear in
// the stack while the app is actively using the camera/photos — a
// different code path than the login-time JB detection. Only called after
// isJBPath()/dyld match, so it stays off the hot path for normal files.
static BOOL callerStackHasJBTweak(void) {
    initSelfImage();
    void *frames[16];
    int n = backtrace(frames, 16);
    for (int i = 2; i < n; i++) {            // skip backtrace + this fn
        Dl_info di; di.dli_fname = NULL;
        if (!dladdr(frames[i], &di) || !di.dli_fname) continue;
        if (g_selfImage && strcmp(di.dli_fname, g_selfImage) == 0) continue; // skip self
        if (fnameIsJBTweak(di.dli_fname)) return YES;
    }
    return NO;
}

// Pass-through for callers originating from JB tweak dylibs so they can
// access their own files under /var/jb/ (e.g. VCam reading its resources).
static BOOL statCallerIsJBTweak(void) {
    return callerStackHasJBTweak();
}

// DEBUG: log a blocked JB-path access + the proximate caller images, so we
// can see exactly what a tweak (e.g. VCam) needed but we denied. Volume is
// bounded — only fires on isJBPath() hits, which are rare in normal apps.
static void dbgLogJBBlock(const char *tag, const char *path) {
    void *fr[16];
    int n = backtrace(fr, 16);
    char callers[220]; int off = 0; callers[0] = 0;
    for (int i = 2; i < n && off < 180; i++) {
        Dl_info di; di.dli_fname = NULL;
        if (!dladdr(fr[i], &di) || !di.dli_fname) continue;
        if (g_selfImage && strcmp(di.dli_fname, g_selfImage) == 0) continue;
        const char *b = strrchr(di.dli_fname, '/');
        b = b ? b + 1 : di.dli_fname;
        int w = snprintf(callers + off, sizeof(callers) - off, "%s ", b);
        if (w > 0) off += w;
        if (i >= 7) break;
    }
    dbglog("JBblk.%s %s path=%s callers=[%s]\n", tag, g_procname, path ? path : "(null)", callers);
}

// isJBPath() first (cheap strncmp) so the stack-walk caller check only
// runs for the rare JB-sensitive path — keeps the hot path zero-overhead.
static int hook_stat_fn(const char *path, struct stat *buf) {
    if (isJBPath(path) && !statCallerIsJBTweak()) { dbgLogJBBlock("stat", path); errno = ENOENT; return -1; }
    return orig_stat_fn(path, buf);
}
static int hook_lstat_fn(const char *path, struct stat *buf) {
    if (isJBPath(path) && !statCallerIsJBTweak()) { dbgLogJBBlock("lstat", path); errno = ENOENT; return -1; }
    return orig_lstat_fn(path, buf);
}
static int hook_access_fn(const char *path, int mode) {
    if (isJBPath(path) && !statCallerIsJBTweak()) { dbgLogJBBlock("access", path); errno = ENOENT; return -1; }
    return orig_access_fn(path, mode);
}

%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) { dbgLogJBBlock("fm.exists", path.UTF8String); return NO; }
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDir {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) { dbgLogJBBlock("fm.existsDir", path.UTF8String); return NO; }
    return %orig;
}
- (NSData *)contentsAtPath:(NSString *)path {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) { dbgLogJBBlock("fm.contents", path.UTF8String); return nil; }
    return %orig;
}
- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)err {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) {
        dbgLogJBBlock("fm.attrs", path.UTF8String);
        if (err) *err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        return nil;
    }
    return %orig;
}
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)err {
    if (path && isJBPath(path.UTF8String) && !statCallerIsJBTweak()) {
        if (err) *err = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        return nil;
    }
    NSArray *orig = %orig;
    if (!orig || orig.count == 0) return orig;
    if (statCallerIsJBTweak()) return orig;
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:orig.count];
    for (NSString *item in orig) {
        NSString *full = [path stringByAppendingPathComponent:item];
        if (!isJBPath([full UTF8String])) [out addObject:item];
    }
    return out;
}
%end

%hook UIApplication
- (BOOL)canOpenURL:(NSURL *)url {
    NSString *s = url.scheme.lowercaseString;
    if ([s isEqualToString:@"cydia"]     || [s isEqualToString:@"sileo"] ||
        [s isEqualToString:@"zbra"]      || [s isEqualToString:@"filza"] ||
        [s isEqualToString:@"santander"] || [s isEqualToString:@"undecimus"]) {
        return NO;
    }
    return %orig;
}
%end

// ============================================================
// LAYER 10: dyld image list hiding + open() JB path blocking.
//
// Anti-fraud SDKs (Zalo / TikTok) call _dyld_image_count() then
// iterate _dyld_get_image_name(i) looking for:
//   "substrate", "ellekit", "ChangeInfoIos", "/var/jb/" paths.
// We present a filtered view that skips all JB-related images.
//
// open() hook: complements stat/lstat/access — some SDKs call
// open(path, O_RDONLY) to check JB file existence.
// ============================================================

static const char * const kDyldHide[] = {
    "ChangeInfoIosMG", "ChangeInfoIos",
    "ellekit", "CydiaSubstrate", "libsubstrate", "substitute",
    "MobileSubstrate", "TweakInject", "Dopamine", "palera1n",
    "libhooker", "libblackjack", "pspawn", "ChOma",
    NULL
};

static inline BOOL isDyldNameHidden(const char *name) {
    if (!name) return NO;
    for (int i = 0; kDyldHide[i]; i++) {
        if (strstr(name, kDyldHide[i])) return YES;
    }
    if (strstr(name, "/var/jb/") || strstr(name, "/private/var/jb/")) return YES;
    return NO;
}

typedef uint32_t    (*dyld_image_count_fn_t)(void);
typedef const char *(*dyld_image_name_fn_t)(uint32_t);
static dyld_image_count_fn_t  orig_dyld_image_count_fn    = NULL;
static dyld_image_name_fn_t   orig_dyld_get_image_name_fn = NULL;

// If the caller of _dyld_image_count / _dyld_get_image_name is itself
// a JB tweak (its code lives in /var/jb/Library/ or /var/jb/usr/lib/),
// pass through the real list — that tweak needs to locate itself or its
// peers (e.g. VCam finding vcamrootless.dylib to locate its video file).
// Only filter the view for app-bundle callers (the anti-fraud SDK path).
static BOOL dyldCallerIsJBTweak(void) {
    // Multi-frame walk: VCam may reach _dyld_* through a wrapper frame
    // when locating its own dylib / video source. Single-frame check
    // missed those. App-side anti-fraud scans have no tweak frame.
    return callerStackHasJBTweak();
}

static uint32_t hooked_dyld_image_count(void) {
    if (!orig_dyld_image_count_fn) return 0;
    if (dyldCallerIsJBTweak()) {
        static int loggedTweak = 0;
        if (!loggedTweak) { loggedTweak = 1; dbgLogJBBlock("dyld.count.PASS", "tweak-caller"); }
        return orig_dyld_image_count_fn();
    }
    static int loggedApp = 0;
    if (!loggedApp) { loggedApp = 1; dbgLogJBBlock("dyld.count.FILTER", "app-caller"); }
    uint32_t total = orig_dyld_image_count_fn();
    uint32_t hidden = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *name = orig_dyld_get_image_name_fn ? orig_dyld_get_image_name_fn(i) : NULL;
        if (isDyldNameHidden(name)) hidden++;
    }
    return total - hidden;
}

static const char *hooked_dyld_get_image_name(uint32_t index) {
    if (!orig_dyld_get_image_name_fn || !orig_dyld_image_count_fn) return NULL;
    if (dyldCallerIsJBTweak()) return orig_dyld_get_image_name_fn(index);
    uint32_t total = orig_dyld_image_count_fn();
    uint32_t visible = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *name = orig_dyld_get_image_name_fn(i);
        if (isDyldNameHidden(name)) continue;
        if (visible == index) return name;
        visible++;
    }
    return NULL;
}

// open()/openat() hooks removed: variadic signature + Foundation's
// _NSOpenFileDescriptor_Protected calling open() from multiple threads
// simultaneously caused strncmp to receive an invalid kHide[i] pointer
// (0x209) → EXC_BAD_ACCESS. stat/lstat/access hooks cover the same
// JB-path detection paths without the multi-thread re-entry risk.

// ============================================================
// LAYER 12: DeviceCheck — block token generation.
//
// Apple's DeviceCheck API creates a server-side cryptographic token that
// permanently identifies the device even across factory resets. Zalo sends
// this token to VNG servers during registration for hardware-level binding.
// We return DCErrorFeatureUnsupported so Zalo skips DeviceCheck and falls
// back to software fingerprints (which we're already spoofing via LAYER 11).
// ============================================================
%hook DCDevice
- (void)generateTokenWithCompletionHandler:(void(^)(NSData *, NSError *))completion {
    if (completion) {
        NSError *e = [NSError errorWithDomain:DCErrorDomain
                                         code:DCErrorFeatureUnsupported
                                     userInfo:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            dbglog("DeviceCheck.block %s\n", g_procname);
            completion(nil, e);
        });
    }
}
%end

// ============================================================
// LAYER 13: AppTrackingTransparency — return Authorized.
//
// When ATT status is not Authorized, apps use IDFV-based fingerprinting
// fallbacks that correlate across identity changes (IDFV is per vendor,
// survives reinstalls within the same vendor group). Returning Authorized
// makes apps trust the spoofed IDFA instead of using those fallbacks.
// ============================================================
%hook ATTrackingManager
+ (NSUInteger)trackingAuthorizationStatus {
    return 3; // ATTrackingManagerAuthorizationStatusAuthorized
}
%end

// ============================================================
// NSProcessInfo — iOS version must match UIDevice.systemVersion.
// Anti-fraud SDKs compare operatingSystemVersion struct against the
// UIDevice string value; mismatch is flagged as instrumentation.
// ============================================================
%hook NSProcessInfo
- (NSOperatingSystemVersion)operatingSystemVersion {
    NSString *v = getConfigStr(@"systemVersion");
    if (!v) return %orig;
    NSArray<NSString *> *p = [v componentsSeparatedByString:@"."];
    NSOperatingSystemVersion osv = {0, 0, 0};
    if (p.count > 0) osv.majorVersion = [p[0] integerValue];
    if (p.count > 1) osv.minorVersion = [p[1] integerValue];
    if (p.count > 2) osv.patchVersion = [p[2] integerValue];
    return osv;
}
- (BOOL)isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion)v {
    NSOperatingSystemVersion ours = [self operatingSystemVersion];
    if (ours.majorVersion != v.majorVersion) return ours.majorVersion > v.majorVersion;
    if (ours.minorVersion != v.minorVersion) return ours.minorVersion > v.minorVersion;
    return ours.patchVersion >= v.patchVersion;
}
- (NSString *)operatingSystemVersionString {
    NSString *v = getConfigStr(@"systemVersion");
    NSString *b = getConfigStr(@"BuildVersion");
    if (!v) return %orig;
    return b ? [NSString stringWithFormat:@"Version %@ (Build %@)", v, b]
             : [NSString stringWithFormat:@"Version %@", v];
}
- (NSUInteger)processorCount {
    id v = getConfig(@"processorCount");
    return v ? (NSUInteger)[v integerValue] : %orig;
}
- (NSUInteger)activeProcessorCount { return [self processorCount]; }
// NSProcessInfo.environment NOT hooked — hooking it caused app-wide hangs
// because WebContent (spawned by every WKWebView app) also receives this dylib
// and the hook fired during early process init before ObjC runtime was stable.
%end

// ============================================================
// LAYER 15: UIScreen — DPR + native pixel dimensions must match
// the spoofed ProductType. Do NOT hook bounds — breaks app layout.
// Fingerprinters read scale/nativeScale/nativeBounds separately.
// ============================================================
%hook UIScreen
- (BOOL)isCaptured { return NO; } // block screen-recording JB detection
- (CGFloat)scale {
    NSString *pt = getConfigStr(@"ProductType");
    if (!pt) return %orig;
    int sw, sh, hc; double dpr;
    screenDimsForProductType(pt, &sw, &sh, &dpr, &hc);
    return (CGFloat)dpr;
}
- (CGFloat)nativeScale { return [self scale]; }
- (CGRect)nativeBounds {
    NSString *pt = getConfigStr(@"ProductType");
    if (!pt) return %orig;
    int sw, sh, hc; double dpr;
    screenDimsForProductType(pt, &sw, &sh, &dpr, &hc);
    return CGRectMake(0, 0, (CGFloat)(sw * dpr), (CGFloat)(sh * dpr));
}
%end

// ============================================================
// LAYER 16: NSUserDefaults — Zalo caches device fingerprints in
// UserDefaults as a fast read path before falling back to Keychain.
// Block known device-ID keys so every session starts cold and hits
// the Keychain path (which our SecItemCopyMatching hook blocks).
// Conservative exact-match list to avoid breaking unrelated prefs.
// ============================================================
static NSString * const kZaloUDKeys[] = {
    @"kZAIDForDevice", @"kZAIDForAdvertisingKey", @"zda_device_udid",
    @"kSecurityIndentifierKey", @"deviceUUID", @"deviceModel",
    @"firstTimeInstallApp", @"installSource", @"kThisDeviceOnlyKey",
    @"ZADeviceID", @"zalo_device_id", @"za_device_fingerprint",
    @"FIRInstallationsID", @"firebase_iid", @"GoogleAppID",
    nil
};
static BOOL isZaloUDKey(NSString *k) {
    if (!k) return NO;
    if (!getConfigStr(@"UniqueDeviceID") && !getConfigStr(@"SerialNumber")) return NO;
    for (int i = 0; kZaloUDKeys[i]; i++)
        if ([k isEqualToString:kZaloUDKeys[i]]) return YES;
    return NO;
}
%hook NSUserDefaults
- (id)objectForKey:(NSString *)k {
    if (isZaloUDKey(k)) {
        dbglog("UDef.block %s key=%s\n", g_procname, [k UTF8String]);
        return nil;
    }
    return %orig;
}
- (NSString *)stringForKey:(NSString *)k  { return isZaloUDKey(k) ? nil : %orig; }
- (NSData   *)dataForKey:(NSString *)k    { return isZaloUDKey(k) ? nil : %orig; }
- (BOOL)boolForKey:(NSString *)k          { return isZaloUDKey(k) ? NO  : %orig; }
%end

// ============================================================
// LAYER 17: CTTelephonyNetworkInfo — radio access technology
// string (CTRadioAccessTechnologyLTE / NR etc.) must be consistent
// with the spoofed carrier and device capabilities.
// ============================================================
%hook CTTelephonyNetworkInfo
- (NSString *)currentRadioAccessTechnology {
    NSString *v = getConfigStr(@"radioAccessTechnology");
    return v ?: %orig;
}
- (NSDictionary *)serviceCurrentRadioAccessTechnology {
    NSString *v = getConfigStr(@"radioAccessTechnology");
    if (!v) return %orig;
    NSDictionary *o = %orig;
    if (!o || o.count == 0) return o;
    NSMutableDictionary *d = [o mutableCopy];
    for (NSString *k in o) d[k] = v;
    return [d copy];
}
%end

// ============================================================
// LAYER 18: NSMutableURLRequest — patch User-Agent header.
//
// iOS NSURLSession automatically sends a UA like:
//   "AppName/x.y (iPhone; CPU iPhone OS 17_7 like Mac OS X)"
// containing the REAL iOS version. We replace the real version
// segment with the spoofed one so HTTP traffic is consistent.
// Only fires when the real and spoofed versions differ AND the
// UA actually contains the real version string.
// ============================================================
// Cached UA patch strings — built once per process, reused on every request.
// Calling [[UIDevice currentDevice] systemVersion] on every HTTP request
// triggered our UIDevice hook chain repeatedly → severe startup lag.
static NSString *g_uaRealDot  = nil; // "17_7" (real iOS)
static NSString *g_uaSpoofDot = nil; // "16_7" (spoofed iOS)
static void initUAPatch(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *spoof = getConfigStr(@"systemVersion");
        if (!spoof) return;
        // Read real iOS version directly from sysctl to avoid ObjC hook chain
        char buf[32] = {0};
        size_t sz = sizeof(buf);
        sysctlbyname("kern.osproductversion", buf, &sz, NULL, 0);
        NSString *real = buf[0] ? [NSString stringWithUTF8String:buf] : nil;
        if (!real || [real isEqualToString:spoof]) return;
        g_uaRealDot  = [real  stringByReplacingOccurrencesOfString:@"." withString:@"_"];
        g_uaSpoofDot = [spoof stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    });
}
static NSString *patchUA(NSString *value) {
    initUAPatch();
    if (!g_uaRealDot || !value) return value;
    if (![value containsString:g_uaRealDot]) return value;
    return [value stringByReplacingOccurrencesOfString:g_uaRealDot withString:g_uaSpoofDot];
}

%hook NSMutableURLRequest
- (void)setValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
        value = patchUA(value);
    %orig(value, field);
}
- (void)addValue:(NSString *)value forHTTPHeaderField:(NSString *)field {
    if ([field caseInsensitiveCompare:@"User-Agent"] == NSOrderedSame)
        value = patchUA(value);
    %orig(value, field);
}
%end

// LAYER 19: fork — block process-spawn JB detection.
// popen/system NOT hooked: if app calls popen() and we return NULL,
// the app may fread/fclose(NULL) → crash. fork() is safe to block
// since it returns EPERM on stock iOS too; no app reads its FILE*.
typedef int (*fork_fn_t)(void);
static fork_fn_t orig_fork_fn = NULL;
static int hooked_fork(void) { errno = EPERM; return -1; }

// ============================================================
// LAYER 20: PKPushRegistry — VoIP push token device fingerprint.
//
// The VoIP push token is device-unique and survives app reinstalls.
// It's often used alongside APNS token for device identity.
// We return the XOR-scrambled apnsTokenSpoof value (same derivation
// the app uses for voipTokenPreview) so it looks legitimate but
// changes every Change Device session.
// ============================================================
%hook PKPushRegistry
- (NSData *)pushTokenForType:(NSString *)type {
    NSString *hex = getConfigStr(@"apnsTokenSpoof");
    if (!hex || hex.length < 64) return %orig;
    NSMutableData *d = [NSMutableData dataWithCapacity:hex.length / 2];
    for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
        unsigned int b = 0;
        NSScanner *sc = [NSScanner scannerWithString:[hex substringWithRange:NSMakeRange(i, 2)]];
        [sc scanHexInt:&b];
        uint8_t byte = (uint8_t)(b ^ 0xA5);
        [d appendBytes:&byte length:1];
    }
    dbglog("PKPushToken.spoof %s type=%s\n", g_procname, [type UTF8String]);
    return [d copy];
}
%end

// ============================================================
// ctor: install hook + register reload notify.
// ============================================================
static void notify_cb(int t) {
    (void)t;
    reloadConfig();
    // On identity change: wipe all Zalo persistent fingerprints so the next
    // registration sees a completely clean device.
    if (getConfigStr(@"UniqueDeviceID") || getConfigStr(@"SerialNumber")) {
        const char *pn = getprogname();
        if (pn && (strstr(pn, "Zalo") || strstr(pn, "zalo") ||
                   strstr(pn, "zingalo") || strstr(pn, "imess"))) {
            wipeZaloKeychainFingerprints();
            // Clear WKWebView persistent storage (cookies, localStorage, IndexedDB,
            // service worker caches) — Zalo's embedded WebView stores session tokens
            // and device fingerprints in localStorage that survive app reinstalls.
            dispatch_async(dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    WKWebsiteDataStore *store = [WKWebsiteDataStore defaultDataStore];
                    NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
                    [store removeDataOfTypes:types
                              modifiedSince:[NSDate distantPast]
                          completionHandler:^{
                        dbglog("WKDataStore.cleared %s\n", g_procname);
                    }];
                    // Clear general pasteboard — Zalo may write device token to
                    // pasteboard for cross-app/reinstall persistence.
                    [[UIPasteboard generalPasteboard] setItems:@[]];
                    dbglog("Pasteboard.cleared %s\n", g_procname);
                }
            });
        }
    }
}

%ctor {
    @autoreleasepool {
        initMGKeyMap();
        initIntKeys();
        reloadConfig();

        const char *pn = getprogname();
        if (pn && pn[0]) g_procname = pn;
        dbglog("ctor pid=%d %s start cfg_keys=%lu\n",
               getpid(), g_procname, (unsigned long)g_config.count);

        // Resolve originals first so the hook can chain to them even
        // if fishhook fails to rebind a particular symbol (e.g. when
        // it's eagerly bound or pre-resolved via __DATA __got).
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
        if (h) orig_MGCopyAnswer = (MGCopyAnswer_t)dlsym(h, "MGCopyAnswer");
        orig_sysctlbyname = (sysctlbyname_t)dlsym(RTLD_DEFAULT, "sysctlbyname");
        orig_getifaddrs   = (getifaddrs_t)  dlsym(RTLD_DEFAULT, "getifaddrs");
        orig_gethostname  = (gethostname_t) dlsym(RTLD_DEFAULT, "gethostname");
        dbglog("ctor %s libMG=%p MG=%p sysctl=%p getif=%p ghn=%p\n",
               g_procname, h, (void *)orig_MGCopyAnswer, (void *)orig_sysctlbyname,
               (void *)orig_getifaddrs, (void *)orig_gethostname);
        // libc orig pointers are always resolvable; MG only present on
        // apps that link libMobileGestalt — don't abort if missing,
        // libc hooks are still useful (this is exactly the AIDA case).
        if (!orig_MGCopyAnswer) {
            dbglog("ctor %s WARN: no MGCopyAnswer (app doesn't link libMG) — libc hooks only\n", g_procname);
        }

        // fishhook for lazy-bound libc / MG symbols. AIDA64 doesn't
        // link libMobileGestalt, so MGCopyAnswer hook is a no-op there;
        // sysctlbyname / getifaddrs / gethostname are how AIDA actually
        // reads model + MAC + hostname.
        struct rebinding rebs[] = {
            { "MGCopyAnswer",  (void *)hooked_MGCopyAnswer,
              (void **)&orig_MGCopyAnswer },
            { "sysctlbyname", (void *)hooked_sysctlbyname,
              (void **)&orig_sysctlbyname },
            { "getifaddrs",   (void *)hooked_getifaddrs,
              (void **)&orig_getifaddrs },
            { "gethostname",  (void *)hooked_gethostname,
              (void **)&orig_gethostname },
        };
        int fh = rebind_symbols(rebs, sizeof(rebs)/sizeof(rebs[0]));
        dbglog("ctor %s fishhook MG+libc rc=%d orig: sysctl=%p getif=%p ghn=%p\n",
               g_procname, fh, (void *)orig_sysctlbyname,
               (void *)orig_getifaddrs, (void *)orig_gethostname);

        // Belt-and-suspenders: MSHookFunction patches the function prologue
        // directly, so it intercepts callers regardless of how they're
        // bound (lazy, eager, __got, __TEXT-encrypted). fishhook misses
        // App Store apps that pre-resolve libc into immediate addresses;
        // MSHookFunction catches everyone since libsystem_c is shared.
        // Pre-resolved orig_* gets overwritten by MSHookFunction with a
        // pointer to the saved prologue trampoline — safe in either case.
        if (orig_sysctlbyname) {
            MSHookFunction((void *)orig_sysctlbyname, (void *)hooked_sysctlbyname,
                           (void **)&orig_sysctlbyname);
        }
        // Raw sysctl() — AIDA64 calls sysctl({CTL_HW, HW_MACHINE}, ...) with
        // numeric MIBs directly, bypassing sysctlbyname entirely. Patch the
        // function prologue in libsystem_c so all callers are intercepted.
        // g_inSysctl is shared with hooked_sysctlbyname to break the inner
        // orig_sysctlbyname → sysctl() chain (prevents double-hook re-entry).
        orig_sysctl_raw = (sysctl_raw_t)dlsym(RTLD_DEFAULT, "sysctl");
        if (orig_sysctl_raw) {
            MSHookFunction((void *)orig_sysctl_raw, (void *)hooked_sysctl_raw,
                           (void **)&orig_sysctl_raw);
        }
        if (orig_getifaddrs) {
            MSHookFunction((void *)orig_getifaddrs, (void *)hooked_getifaddrs,
                           (void **)&orig_getifaddrs);
        }
        if (orig_gethostname) {
            MSHookFunction((void *)orig_gethostname, (void *)hooked_gethostname,
                           (void **)&orig_gethostname);
        }
        // MSHookFunction on MGCopyAnswer — now safe because hooked_MGCopyAnswer
        // uses dladdr(__builtin_return_address(0)) to detect the caller image.
        // Calls from /System/Library/ (UIKit, etc.) pass through to real MG.
        // Calls from app bundles (AIDA64 dlopen/dlsym, analytics SDKs) get faked.
        // This fixes AIDA64 serial/IMEI/UDID — AIDA64 loads MG via dlopen+dlsym,
        // which bypasses fishhook's GOT rebind but IS caught by prologue patching.
        if (orig_MGCopyAnswer) {
            MSHookFunction((void *)orig_MGCopyAnswer, (void *)hooked_MGCopyAnswer,
                           (void **)&orig_MGCopyAnswer);
            dbglog("ctor %s MSHook MGCopyAnswer orig=%p\n",
                   g_procname, (void *)orig_MGCopyAnswer);
        }
        dbglog("ctor %s after MSHook libc orig: sysctl=%p sysctl_raw=%p getif=%p ghn=%p\n",
               g_procname, (void *)orig_sysctlbyname, (void *)orig_sysctl_raw,
               (void *)orig_getifaddrs, (void *)orig_gethostname);

        // SCDynamicStoreCopyComputerName — SystemConfiguration framework,
        // used by apps that bypass UIDevice.name for device name.
        void *sc = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_NOW);
        if (sc) {
            void *scdsName = dlsym(sc, "SCDynamicStoreCopyComputerName");
            if (scdsName) {
                orig_SCDSCopyComputerName = (SCDSCopyComputerName_t)scdsName;
                MSHookFunction(scdsName, (void *)hooked_SCDSCopyComputerName,
                               (void **)&orig_SCDSCopyComputerName);
            }
            dbglog("ctor %s SC=%p SCDSCopyName=%p orig=%p\n",
                   g_procname, sc, scdsName, (void *)orig_SCDSCopyComputerName);
        }

        // CNCopyCurrentNetworkInfo — SSID / BSSID of connected WiFi.
        // Used by AIDA64 and other apps to display WiFi network name.
        // Located in NetworkExtension.framework (iOS 14+).
        void *ne = dlopen("/System/Library/Frameworks/NetworkExtension.framework/NetworkExtension", RTLD_NOW);
        if (ne) {
            void *cnSym = dlsym(ne, "CNCopyCurrentNetworkInfo");
            if (cnSym) {
                orig_CNCopyCurrentNetworkInfo = (CNCopyCurrentNetworkInfo_t)cnSym;
                MSHookFunction(cnSym, (void *)hooked_CNCopyCurrentNetworkInfo,
                               (void **)&orig_CNCopyCurrentNetworkInfo);
            }
            dbglog("ctor %s CNCopyCurrentNetworkInfo=%p orig=%p\n",
                   g_procname, ne ? dlsym(ne,"CNCopyCurrentNetworkInfo") : NULL,
                   (void *)orig_CNCopyCurrentNetworkInfo);
        }

        // IORegistry: fishhook can't rebind IOKit framework calls (eager
        // bind / indirect stubs). Use MSHookFunction (ellekit) instead —
        // patches the function prologue with a branch to our trampoline.
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
        dbglog("ctor %s IOKit=%p\n", g_procname, iokit);
        if (iokit) {
            void *createSym = dlsym(iokit, "IORegistryEntryCreateCFProperty");
            void *searchSym = dlsym(iokit, "IORegistryEntrySearchCFProperty");
            void *propsSym  = dlsym(iokit, "IORegistryEntryCreateCFProperties");
            dbglog("ctor %s IOReg syms create=%p search=%p props=%p\n",
                   g_procname, createSym, searchSym, propsSym);

            if (createSym) {
                MSHookFunction(createSym, (void *)hooked_IORegCreate,
                               (void **)&orig_IORegCreate);
                dbglog("ctor %s MSHook IORegCreate orig=%p\n",
                       g_procname, (void *)orig_IORegCreate);
            }
            if (searchSym) {
                MSHookFunction(searchSym, (void *)hooked_IORegSearch,
                               (void **)&orig_IORegSearch);
                dbglog("ctor %s MSHook IORegSearch orig=%p\n",
                       g_procname, (void *)orig_IORegSearch);
            }
            if (propsSym) {
                MSHookFunction(propsSym, (void *)hooked_IORegCreateProps,
                               (void **)&orig_IORegCreateProps);
                dbglog("ctor %s MSHook IORegCreateProps orig=%p\n",
                       g_procname, (void *)orig_IORegCreateProps);
            }
        }

        // LAYER 9: JB hiding — stat / lstat / access
        orig_stat_fn   = (stat_fn_t)  dlsym(RTLD_DEFAULT, "stat");
        orig_lstat_fn  = (stat_fn_t)  dlsym(RTLD_DEFAULT, "lstat");
        orig_access_fn = (access_fn_t)dlsym(RTLD_DEFAULT, "access");
        if (orig_stat_fn)
            MSHookFunction((void*)orig_stat_fn,   (void*)hook_stat_fn,   (void**)&orig_stat_fn);
        if (orig_lstat_fn)
            MSHookFunction((void*)orig_lstat_fn,  (void*)hook_lstat_fn,  (void**)&orig_lstat_fn);
        if (orig_access_fn)
            MSHookFunction((void*)orig_access_fn, (void*)hook_access_fn, (void**)&orig_access_fn);
        dbglog("ctor %s JBhide stat=%p lstat=%p access=%p\n",
               g_procname, (void*)orig_stat_fn, (void*)orig_lstat_fn, (void*)orig_access_fn);

        // LAYER 10: dyld image list hiding
        orig_dyld_image_count_fn    = (dyld_image_count_fn_t)   dlsym(RTLD_DEFAULT, "_dyld_image_count");
        orig_dyld_get_image_name_fn = (dyld_image_name_fn_t)    dlsym(RTLD_DEFAULT, "_dyld_get_image_name");
        if (orig_dyld_image_count_fn && orig_dyld_get_image_name_fn) {
            MSHookFunction((void*)orig_dyld_image_count_fn,    (void*)hooked_dyld_image_count,
                           (void**)&orig_dyld_image_count_fn);
            MSHookFunction((void*)orig_dyld_get_image_name_fn, (void*)hooked_dyld_get_image_name,
                           (void**)&orig_dyld_get_image_name_fn);
        }
        dbglog("ctor %s dyldHide cnt=%p name=%p\n",
               g_procname, (void*)orig_dyld_image_count_fn, (void*)orig_dyld_get_image_name_fn);

        // LAYER 19: block fork() only — popen/system omitted (crash risk).
        orig_fork_fn = (fork_fn_t)dlsym(RTLD_DEFAULT, "fork");
        if (orig_fork_fn)
            MSHookFunction((void*)orig_fork_fn, (void*)hooked_fork, (void**)&orig_fork_fn);
        dbglog("ctor %s fork blocked=%p\n", g_procname, (void*)orig_fork_fn);

        // open()/openat() hooks intentionally not installed — see comment above.

        // LAYER 11: Keychain device-fingerprint isolation
        // MSHookFunction patches the Security.framework prologue so ALL callers
        // (including those with pre-bound symbols via dyld shared cache) are intercepted.
        void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW);
        if (sec) {
            void *sicm = dlsym(sec, "SecItemCopyMatching");
            if (sicm) {
                orig_SecItemCopyMatching = (SecItemCopyMatching_t)sicm;
                MSHookFunction(sicm, (void *)hooked_SecItemCopyMatching,
                               (void **)&orig_SecItemCopyMatching);
            }
            void *siAdd = dlsym(sec, "SecItemAdd");
            if (siAdd) {
                orig_SecItemAdd = (SecItemAdd_t)siAdd;
                MSHookFunction(siAdd, (void *)hooked_SecItemAdd,
                               (void **)&orig_SecItemAdd);
            }
            void *siUpd = dlsym(sec, "SecItemUpdate");
            if (siUpd) {
                orig_SecItemUpdate = (SecItemUpdate_t)siUpd;
                MSHookFunction(siUpd, (void *)hooked_SecItemUpdate,
                               (void **)&orig_SecItemUpdate);
            }
            dbglog("ctor %s Keychain CopyMatch=%p Add=%p Upd=%p\n",
                   g_procname,
                   (void *)orig_SecItemCopyMatching,
                   (void *)orig_SecItemAdd,
                   (void *)orig_SecItemUpdate);
        }

        // Reload config on any of the 3 notification names:
        //   kReloadNote  = com.changeinfoios.v3/ReloadConfig  (v3 native)
        //   kLegacyNote  = com.changeinfoios/ReloadConfig     (v2 legacy)
        //   kAppNote     = com.changeinfoios/ReloadPrefs      (what app actually sends)
        int t1 = 0, t2 = 0, t3 = 0;
        notify_register_dispatch([kReloadNote UTF8String], &t1,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });
        notify_register_dispatch([kLegacyNote UTF8String], &t2,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });
        notify_register_dispatch([kAppNote UTF8String], &t3,
            dispatch_get_main_queue(), ^(int x){ notify_cb(x); });

        // RestartTarget: app sends this after GPS sync-with-proxy to flush Safari's
        // cached location. Safari / WebContent calls exit(0) so next launch reads
        // the freshly-written coordinates. Other processes ignore it.
        {
            const char *pn = getprogname();
            BOOL isSafari = (pn && (strcmp(pn, "MobileSafari") == 0 ||
                                    strcmp(pn, "SafariViewService") == 0 ||
                                    strcmp(pn, "com.apple.WebKit.WebContent") == 0 ||
                                    strstr(pn, "WebContent") != NULL));
            if (isSafari) {
                int t3 = 0;
                notify_register_dispatch("com.changeinfoios/RestartTarget", &t3,
                    dispatch_get_main_queue(), ^(int __unused x) {
                        dbglog("RestartTarget %s → exit(0)\n", g_procname);
                        exit(0);
                    });
                dbglog("ctor %s registered RestartTarget handler\n", g_procname);
            }
        }

        NSString *marker = @"/var/jb/etc/changeinfoios/v3_mg_loaded.txt";
        NSString *exec = [[NSProcessInfo processInfo] processName] ?: @"?";
        NSString *body = [NSString stringWithFormat:@"%@ %@\n", exec, [NSDate date]];
        // Append (not overwrite) so multiple apps' loads are visible.
        FILE *f = fopen([marker UTF8String], "a");
        if (f) { fputs([body UTF8String], f); fclose(f); }

        // Auto-clear Zalo persistent fingerprints on every launch when spoof is active.
        // This runs without any user action — just kill Zalo and reopen.
        // We dispatch after a 1.5s delay so Foundation/UIKit are fully initialized.
        if (getConfigStr(@"UniqueDeviceID") || getConfigStr(@"SerialNumber")) {
            const char *pn2 = getprogname();
            if (pn2 && (strstr(pn2, "Zalo") || strstr(pn2, "zalo") ||
                        strstr(pn2, "zingalo") || strstr(pn2, "imess"))) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1500 * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    @autoreleasepool {
                        wipeZaloKeychainFingerprints();
                        WKWebsiteDataStore *store = [WKWebsiteDataStore defaultDataStore];
                        NSSet *types = [WKWebsiteDataStore allWebsiteDataTypes];
                        [store removeDataOfTypes:types
                                  modifiedSince:[NSDate distantPast]
                              completionHandler:^{
                            dbglog("ctor.autoWipe WKDataStore cleared %s\n", g_procname);
                        }];
                        // Wipe NSUserDefaults device fingerprint cache
                        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                        for (int i = 0; kZaloUDKeys[i]; i++)
                            [ud removeObjectForKey:kZaloUDKeys[i]];
                        [ud synchronize];
                        // Pasteboard NOT cleared here — VCam stores its video path
                        // in the general pasteboard; clearing it breaks VCam.
                        // Pasteboard is only cleared in notify_cb (user-triggered).
                        dbglog("ctor.autoWipe KC+WebStore+UD cleared %s\n", g_procname);
                    }
                });
                dbglog("ctor %s scheduled autoWipe in 1.5s\n", g_procname);
            }
        }

        dbglog("ctor %s done\n", g_procname);
    }
}
