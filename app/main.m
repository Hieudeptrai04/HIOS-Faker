#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>  // CAShapeLayer / CABasicAnimation for ring HUD
#import <objc/runtime.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <spawn.h>
#import <notify.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <math.h>
#import <fcntl.h>
#import <errno.h>

// ============================================================
// PRIVATE FRAMEWORK STUBS
// ============================================================
@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
@end

@interface LSApplicationProxy : NSObject
- (NSString *)localizedName;
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
- (id)bundleURL;
- (id)dataContainerURL;
- (NSString *)applicationType;
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@end

@class CIHomeViewController, CIAppPickerViewController, CIFakeSettingsViewController,
       CIRRSManagerViewController, CISideMenuViewController;

// ============================================================
// CONSTANTS
// ============================================================
static NSString *const kSharedPrefPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
// Sandbox-friendly mirror for App Store app tweaks — /var/mobile/Library/Prefs
// is blocked by their sandboxes, /var/jb/etc/* is allowed (verified live).
static NSString *const kSharedConfigPath = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kNotifyReload   = @"com.changeinfoios/ReloadPrefs";

static int ci_run(const char *cmd); // defined below, forward decl for CIConfigManager.save shell-mirror

static NSString *const kAppVersion = @"2.2.1-native";

static NSString *CILocalConfigPath(void) {
    static NSString *p = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        p = [dirs.firstObject stringByAppendingPathComponent:@"config.plist"];
    });
    return p;
}

static NSString *CIRRSDir(void) {
    static NSString *p = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        p = [dirs.firstObject stringByAppendingPathComponent:@"RRS"];
    });
    return p;
}
#define kRRSDir CIRRSDir()

// ============================================================
// CONFIG MANAGER
// ============================================================
@interface CIConfigManager : NSObject
+ (instancetype)shared;
- (NSMutableDictionary *)config;
- (id)objectForKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (NSInteger)integerForKey:(NSString *)key;
- (void)setObject:(id)value forKey:(NSString *)key;
- (void)save;
- (void)notifyReload;
- (NSArray<NSString *> *)targetBundles;
- (void)setTargetBundles:(NSArray *)arr;
- (NSArray<NSString *> *)rrsBundles;
- (void)setRrsBundles:(NSArray *)arr;
@end

@implementation CIConfigManager {
    NSMutableDictionary *_cfg;
}

+ (instancetype)shared {
    static CIConfigManager *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[CIConfigManager alloc] init]; [s load]; });
    return s;
}

- (void)load {
    _cfg = [[NSMutableDictionary dictionaryWithContentsOfFile:CILocalConfigPath()] mutableCopy];
    if (!_cfg) {
        _cfg = [[NSMutableDictionary dictionaryWithContentsOfFile:kSharedPrefPath] mutableCopy];
    }
    if (!_cfg) _cfg = [NSMutableDictionary dictionary];
    [self seedDefaultsIfNeeded];
}

// Default-ON for all fake layers. User can still turn individual layers off
// in settings — seedDefaults only fills values that are absent from config.
- (void)seedDefaultsIfNeeded {
    NSArray *allFakeLayers = @[
        @"fake_sysosversion", @"fake_uiddevice", @"fake_screen", @"fake_realscreen",
        @"fake_processinfo", @"fake_location", @"fake_datetime", @"fake_locale",
        @"fake_locale2", @"fake_network", @"fake_hardware", @"fake_sensor",
        @"fake_ads", @"fake_wifi", @"fake_tracking_pasteboard", @"fake_trackingdefaults",
        @"fake_uiddevice2", @"fake_sysctl", @"fake_battery", @"fake_browser",
        @"fake_metal", @"fake_webrtc", @"fake_timing", @"fake_keychain",
        @"fake_jbhide", @"fake_uptime",
    ];
    BOOL seeded = NO;
    for (NSString *k in allFakeLayers) {
        if (_cfg[k] == nil) { _cfg[k] = @(YES); seeded = YES; }
    }
    if (_cfg[@"hideJailbreak"]   == nil) { _cfg[@"hideJailbreak"]   = @(YES); seeded = YES; }
    if (_cfg[@"web_canvasNoise"] == nil) { _cfg[@"web_canvasNoise"] = @(YES); seeded = YES; }
    if (_cfg[@"keychainReset"]   == nil) { _cfg[@"keychainReset"]   = @(YES); seeded = YES; }
    if (_cfg[@"locationEnabled"] == nil) { _cfg[@"locationEnabled"] = @(YES); seeded = YES; }
    if (seeded) {
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:_cfg
                        format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
        if (data) [data writeToFile:CILocalConfigPath() atomically:YES];
    }
}

- (NSMutableDictionary *)config { return _cfg; }

- (id)objectForKey:(NSString *)key { return _cfg[key]; }
- (NSString *)stringForKey:(NSString *)key { id v = _cfg[key]; return [v isKindOfClass:[NSString class]] ? v : nil; }
- (BOOL)boolForKey:(NSString *)key { id v = _cfg[key]; return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO; }
- (NSInteger)integerForKey:(NSString *)key { id v = _cfg[key]; return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0; }

- (void)setObject:(id)value forKey:(NSString *)key {
    if (value == nil) [_cfg removeObjectForKey:key];
    else _cfg[key] = value;
}

- (void)save {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_cfg
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0 error:nil];
    if (!data) { NSLog(@"[ChangeInfoIos] save: plist serialization failed!"); return; }

    // Always write to app sandbox first (never fails)
    BOOL localOK = [data writeToFile:CILocalConfigPath() atomically:YES];
    NSLog(@"[ChangeInfoIos] save: local=%@ (%lu bytes, %lu keys)",
          localOK ? @"OK" : @"FAIL", (unsigned long)data.length, (unsigned long)_cfg.count);

    // Now try multiple strategies to write to shared prefs path
    NSString *dir = [kSharedPrefPath stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    // Strategy 1: Cocoa writeToFile: directly with NSData
    NSError *writeErr = nil;
    BOOL s1 = [data writeToFile:kSharedPrefPath options:NSDataWritingAtomic error:&writeErr];
    NSLog(@"[ChangeInfoIos] save S1 (Cocoa write): %@ err=%@", s1 ? @"OK" : @"FAIL", writeErr);
    if (s1) { chmod([kSharedPrefPath fileSystemRepresentation], 0644); }

    // Check if S1 worked
    BOOL exists = [fm fileExistsAtPath:kSharedPrefPath];
    unsigned long long sz = 0;
    if (exists) {
        NSDictionary *attr = [fm attributesOfItemAtPath:kSharedPrefPath error:nil];
        sz = [attr[NSFileSize] unsignedLongLongValue];
    }
    BOOL fileOK = exists && sz >= 256;

    // Strategy 2: NSFileManager copyItem (if S1 failed)
    if (!fileOK) {
        [fm removeItemAtPath:kSharedPrefPath error:nil];
        NSError *cpErr = nil;
        BOOL s2 = [fm copyItemAtPath:CILocalConfigPath() toPath:kSharedPrefPath error:&cpErr];
        NSLog(@"[ChangeInfoIos] save S2 (FM copy): %@ err=%@", s2 ? @"OK" : @"FAIL", cpErr);
        if (s2) {
            chmod([kSharedPrefPath fileSystemRepresentation], 0644);
            exists = [fm fileExistsAtPath:kSharedPrefPath];
            if (exists) {
                NSDictionary *attr = [fm attributesOfItemAtPath:kSharedPrefPath error:nil];
                sz = [attr[NSFileSize] unsignedLongLongValue];
            }
            fileOK = exists && sz >= 256;
        }
    }

    // Strategy 3: Low-level C write (if S1 & S2 both failed)
    if (!fileOK) {
        int fd = open([kSharedPrefPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            ssize_t w = write(fd, data.bytes, data.length);
            close(fd);
            BOOL s3 = (w == (ssize_t)data.length);
            NSLog(@"[ChangeInfoIos] save S3 (C write): %@ wrote=%zd/%lu fd=%d",
                  s3 ? @"OK" : @"FAIL", w, (unsigned long)data.length, fd);
            if (s3) {
                exists = [fm fileExistsAtPath:kSharedPrefPath];
                if (exists) {
                    NSDictionary *attr = [fm attributesOfItemAtPath:kSharedPrefPath error:nil];
                    sz = [attr[NSFileSize] unsignedLongLongValue];
                }
                fileOK = exists && sz >= 256;
            }
        } else {
            NSLog(@"[ChangeInfoIos] save S3 (C write): open failed errno=%d (%s)", errno, strerror(errno));
        }
    }

    // Strategy 4: Shell cp via posix_spawn (last resort)
    if (!fileOK) {
        NSString *cmd = [NSString stringWithFormat:
            @"cp '%@' '%@' 2>/tmp/ci_save.err && chmod 0644 '%@' 2>>/tmp/ci_save.err",
            CILocalConfigPath(), kSharedPrefPath, kSharedPrefPath];
        int rc = ci_run([cmd UTF8String]);
        NSLog(@"[ChangeInfoIos] save S4 (shell cp): rc=%d", rc);
        exists = [fm fileExistsAtPath:kSharedPrefPath];
        if (exists) {
            NSDictionary *attr = [fm attributesOfItemAtPath:kSharedPrefPath error:nil];
            sz = [attr[NSFileSize] unsignedLongLongValue];
        }
        fileOK = exists && sz >= 256;
    }

    NSLog(@"[ChangeInfoIos] save FINAL: fileOK=%d exists=%d sz=%llu path=%@",
          fileOK, exists, sz, kSharedPrefPath);

    // Strategy 5: also push every key through CFPreferences. The tweak running
    // inside an App Store app's sandbox can't read /var/mobile/Library/Prefs
    // directly, but it CAN read via CFPreferencesCopyValue (cfprefsd brokers
    // the access). Without this, hooks load but configLoaded stays NO and
    // every getter falls through %orig — i.e. "Change" never takes effect.
    CFStringRef appID = CFSTR("com.changeinfoios");
    for (NSString *k in _cfg) {
        id v = _cfg[k];
        if (v) CFPreferencesSetValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)v,
                                     appID, kCFPreferencesAnyUser, kCFPreferencesAnyHost);
    }
    CFPreferencesSynchronize(appID, kCFPreferencesAnyUser, kCFPreferencesAnyHost);

    // Strategy 6: write the same plist into /var/jb/etc/changeinfoios/config.plist.
    // Verified live via probe dylib: this path IS readable from App Store
    // app sandboxes, while /var/mobile/Library/Preferences/ is NOT. Tweak.xm
    // tries this path first in reloadConfigFromDisk(). Best-effort — if the
    // dir isn't writable, we still have the cfprefsd path above.
    @try {
        NSString *sharedDir = [kSharedConfigPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:sharedDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSData *data = [NSPropertyListSerialization
            dataWithPropertyList:_cfg
                          format:NSPropertyListBinaryFormat_v1_0
                         options:0 error:nil];
        if (data) {
            BOOL ok = [data writeToFile:kSharedConfigPath options:NSDataWritingAtomic error:nil];
            if (ok) chmod([kSharedConfigPath fileSystemRepresentation], 0644);
            NSLog(@"[ChangeInfoIos] save sandbox mirror: ok=%d path=%@", ok, kSharedConfigPath);
        }
    } @catch (NSException *e) {
        NSLog(@"[ChangeInfoIos] save sandbox mirror exception: %@", e);
    }

    [self notifyReload];
}

- (void)notifyReload {
    notify_post([kNotifyReload UTF8String]);
    CFStringRef name = (__bridge CFStringRef)kNotifyReload;
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         name, NULL, NULL, true);
}

- (NSArray<NSString *> *)targetBundles {
    id v = _cfg[@"targetBundles"];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
- (void)setTargetBundles:(NSArray *)arr { _cfg[@"targetBundles"] = arr ?: @[]; }

- (NSArray<NSString *> *)rrsBundles {
    id v = _cfg[@"rrsBundles"];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
- (void)setRrsBundles:(NSArray *)arr { _cfg[@"rrsBundles"] = arr ?: @[]; }
@end

// ============================================================
// SHELL RUNNER (best-effort; needs root for container operations)
// ============================================================
// ============================================================
// RANDOM HARDWARE IDENTIFIER GENERATORS
// Each call yields a fresh value — used on every Reset Data.
// GPS / locale / carrier are intentionally NOT randomized.
// ============================================================
static NSString *ci_randHex(NSUInteger n) {
    static const char *H = "0123456789ABCDEF";
    char *buf = (char *)malloc(n + 1); if (!buf) return @"";
    for (NSUInteger i = 0; i < n; i++) buf[i] = H[arc4random_uniform(16)];
    buf[n] = 0;
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf); return s;
}
static NSString *ci_randHexLower(NSUInteger n) {
    return [ci_randHex(n) lowercaseString];
}
static NSString *ci_randAlnum(NSUInteger n) {
    static const char *A = "ABCDEFGHJKLMNPQRSTUVWXYZ0123456789"; // no I,O
    char *buf = (char *)malloc(n + 1); if (!buf) return @"";
    for (NSUInteger i = 0; i < n; i++) buf[i] = A[arc4random_uniform(34)];
    buf[n] = 0;
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf); return s;
}
static NSString *ci_randDigits(NSUInteger n) {
    char *buf = (char *)malloc(n + 1); if (!buf) return @"";
    for (NSUInteger i = 0; i < n; i++) buf[i] = '0' + arc4random_uniform(10);
    buf[n] = 0;
    NSString *s = [NSString stringWithUTF8String:buf];
    free(buf); return s;
}
// Luhn-valid IMEI (15 digits): 14 random digits + checksum
static NSString *ci_randIMEI(void) {
    int d[15] = {0};
    // TAC prefix from a realistic iPhone range (353328 = iPhone 13 family; keep random within plausible)
    const int prefix[8] = {3,5,3,3,2,8,1,1};
    for (int i = 0; i < 8; i++) d[i] = prefix[i];
    for (int i = 8; i < 14; i++) d[i] = arc4random_uniform(10);
    int sum = 0;
    for (int i = 0; i < 14; i++) {
        int v = d[i];
        if (i % 2 == 1) { v *= 2; if (v > 9) v -= 9; }
        sum += v;
    }
    d[14] = (10 - (sum % 10)) % 10;
    NSMutableString *s = [NSMutableString stringWithCapacity:15];
    for (int i = 0; i < 15; i++) [s appendFormat:@"%d", d[i]];
    return s;
}
static NSString *ci_randMAC(void) {
    // Locally administered, unicast (second nibble = 2/6/A/E)
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 6; i++) {
        if (i) [s appendString:@":"];
        uint8_t b = arc4random_uniform(256);
        if (i == 0) b = (b & 0xFC) | 0x02;
        [s appendFormat:@"%02x", b];
    }
    return s;
}
static NSString *ci_randUUID(void) { return [[NSUUID UUID] UUIDString]; }
static NSString *ci_randSerial(void) {
    // Apple-ish format: 2 location + 3 date + 5 alnum = 10 chars
    return [NSString stringWithFormat:@"%@%@%@",
        ci_randAlnum(2), ci_randAlnum(3), ci_randAlnum(5)];
}

// Regional profile = coherent bundle of GPS + timezone + locale + carrier.
// Picking real city coords + matching carrier avoids "same location every reg"
// (accounts die) while staying plausible to fingerprinters.
static NSArray *ci_geoProfiles(void) {
    static NSArray *p = nil;
    if (!p) p = @[
        // lat, lon, tz, locale, countryCode, currency, lang, carrier, mcc, mnc, iso
        @[@34.0522, @-118.2437, @"America/Los_Angeles", @"en_US", @"US", @"USD", @"en", @"T-Mobile",   @"310", @"260", @"us"],
        @[@40.7128, @-74.0060,  @"America/New_York",    @"en_US", @"US", @"USD", @"en", @"Verizon",    @"311", @"480", @"us"],
        @[@41.8781, @-87.6298,  @"America/Chicago",     @"en_US", @"US", @"USD", @"en", @"AT&T",       @"310", @"410", @"us"],
        @[@25.7617, @-80.1918,  @"America/New_York",    @"en_US", @"US", @"USD", @"en", @"T-Mobile",   @"310", @"260", @"us"],
        @[@37.7749, @-122.4194, @"America/Los_Angeles", @"en_US", @"US", @"USD", @"en", @"AT&T",       @"310", @"410", @"us"],
        @[@29.7604, @-95.3698,  @"America/Chicago",     @"en_US", @"US", @"USD", @"en", @"Verizon",    @"311", @"480", @"us"],
        @[@33.4484, @-112.0740, @"America/Phoenix",     @"en_US", @"US", @"USD", @"en", @"T-Mobile",   @"310", @"260", @"us"],
        @[@47.6062, @-122.3321, @"America/Los_Angeles", @"en_US", @"US", @"USD", @"en", @"AT&T",       @"310", @"410", @"us"],
        @[@51.5074, @-0.1278,   @"Europe/London",       @"en_GB", @"GB", @"GBP", @"en", @"EE",         @"234", @"30",  @"gb"],
        @[@48.8566, @2.3522,    @"Europe/Paris",        @"fr_FR", @"FR", @"EUR", @"fr", @"Orange",     @"208", @"01",  @"fr"],
        @[@52.5200, @13.4050,   @"Europe/Berlin",       @"de_DE", @"DE", @"EUR", @"de", @"Telekom",    @"262", @"01",  @"de"],
        @[@41.9028, @12.4964,   @"Europe/Rome",         @"it_IT", @"IT", @"EUR", @"it", @"TIM",        @"222", @"01",  @"it"],
        @[@40.4168, @-3.7038,   @"Europe/Madrid",       @"es_ES", @"ES", @"EUR", @"es", @"Movistar",   @"214", @"07",  @"es"],
        @[@35.6762, @139.6503,  @"Asia/Tokyo",          @"ja_JP", @"JP", @"JPY", @"ja", @"NTT DOCOMO", @"440", @"10",  @"jp"],
        @[@37.5665, @126.9780,  @"Asia/Seoul",          @"ko_KR", @"KR", @"KRW", @"ko", @"SK Telecom", @"450", @"05",  @"kr"],
        @[@1.3521,  @103.8198,  @"Asia/Singapore",      @"en_SG", @"SG", @"SGD", @"en", @"Singtel",    @"525", @"01",  @"sg"],
        @[@-33.8688,@151.2093,  @"Australia/Sydney",    @"en_AU", @"AU", @"AUD", @"en", @"Telstra",    @"505", @"01",  @"au"],
        @[@43.6532, @-79.3832,  @"America/Toronto",     @"en_CA", @"CA", @"CAD", @"en", @"Rogers",     @"302", @"720", @"ca"],
    ];
    return p;
}

static double ci_randDouble(double lo, double hi) {
    return lo + ((double)arc4random() / (double)UINT32_MAX) * (hi - lo);
}

// Area-uniform jitter inside a disk of radius `radiusKm` around (lat0, lon0).
// Uses r = R * sqrt(U) so density is uniform across the disk — a flat
// ±degree offset would cluster samples in the corners and be easier to
// fingerprint as synthetic.
static void ci_jitterCoordKm(double lat0, double lon0, double radiusKm,
                             double *outLat, double *outLon) {
    const double kEarthR = 6371.0; // km
    double u1 = ci_randDouble(0.0, 1.0);
    double u2 = ci_randDouble(0.0, 1.0);
    double r  = radiusKm * sqrt(u1);
    double t  = 2.0 * M_PI * u2;

    // Offset in degrees (small-angle approximation — fine up to ~1000 km)
    double dLat = (r / kEarthR) * cos(t) * (180.0 / M_PI);
    double cosLat = cos(lat0 * M_PI / 180.0);
    if (cosLat < 0.001) cosLat = 0.001; // guard against poles
    double dLon = (r / kEarthR) * sin(t) * (180.0 / M_PI) / cosLat;

    double lat = lat0 + dLat;
    double lon = lon0 + dLon;
    // Clamp & wrap
    if (lat > 85.0) lat = 85.0; if (lat < -85.0) lat = -85.0;
    while (lon > 180.0)  lon -= 360.0;
    while (lon < -180.0) lon += 360.0;
    *outLat = lat; *outLon = lon;
}

// Realistic sensor fuzz: fresh GPS fix accuracy, plausible speed/course.
// Map apps flag speed=0 + accuracy=0 as synthetic; random but bounded values
// look like a phone that just finished a cold GPS fix.
static void ci_writeLocationFuzz(CIConfigManager *cm) {
    // 5–25m horizontal accuracy — typical outdoor fix
    [cm setObject:[NSString stringWithFormat:@"%.1f", ci_randDouble(5.0, 25.0)]
           forKey:@"locationAccuracy"];
    // 0–2 m/s: standing / slow walking
    [cm setObject:[NSString stringWithFormat:@"%.2f", ci_randDouble(0.0, 2.0)]
           forKey:@"locationSpeed"];
    [cm setObject:[NSString stringWithFormat:@"%.1f", ci_randDouble(0.0, 360.0)]
           forKey:@"locationCourse"];
}

// countryCode → MCC / MNC / carrierName / locale / currency / language
// Used to align carrier/locale with the proxy country returned by ip-api.
static NSDictionary *ci_countryMap(void) {
    static NSDictionary *m = nil;
    if (!m) m = @{
        @"US": @[@"310", @"260", @"T-Mobile",   @"en_US", @"USD", @"en", @"us"],
        @"GB": @[@"234", @"30",  @"EE",         @"en_GB", @"GBP", @"en", @"gb"],
        @"FR": @[@"208", @"01",  @"Orange",     @"fr_FR", @"EUR", @"fr", @"fr"],
        @"DE": @[@"262", @"01",  @"Telekom",    @"de_DE", @"EUR", @"de", @"de"],
        @"IT": @[@"222", @"01",  @"TIM",        @"it_IT", @"EUR", @"it", @"it"],
        @"ES": @[@"214", @"07",  @"Movistar",   @"es_ES", @"EUR", @"es", @"es"],
        @"JP": @[@"440", @"10",  @"NTT DOCOMO", @"ja_JP", @"JPY", @"ja", @"jp"],
        @"KR": @[@"450", @"05",  @"SK Telecom", @"ko_KR", @"KRW", @"ko", @"kr"],
        @"SG": @[@"525", @"01",  @"Singtel",    @"en_SG", @"SGD", @"en", @"sg"],
        @"AU": @[@"505", @"01",  @"Telstra",    @"en_AU", @"AUD", @"en", @"au"],
        @"CA": @[@"302", @"720", @"Rogers",     @"en_CA", @"CAD", @"en", @"ca"],
        @"NL": @[@"204", @"08",  @"KPN",        @"nl_NL", @"EUR", @"nl", @"nl"],
        @"SE": @[@"240", @"01",  @"Telia",      @"sv_SE", @"SEK", @"sv", @"se"],
        @"BR": @[@"724", @"06",  @"Vivo",       @"pt_BR", @"BRL", @"pt", @"br"],
        @"IN": @[@"405", @"840", @"Jio",        @"en_IN", @"INR", @"en", @"in"],
        @"VN": @[@"452", @"01",  @"Viettel",    @"vi_VN", @"VND", @"vi", @"vn"],
        @"TH": @[@"520", @"03",  @"AIS",        @"th_TH", @"THB", @"th", @"th"],
        @"PH": @[@"515", @"03",  @"Smart",      @"en_PH", @"PHP", @"en", @"ph"],
        @"ID": @[@"510", @"10",  @"Telkomsel",  @"id_ID", @"IDR", @"id", @"id"],
        @"MX": @[@"334", @"020", @"Telcel",     @"es_MX", @"MXN", @"es", @"mx"],
        @"HK": @[@"454", @"00",  @"CSL",        @"zh_HK", @"HKD", @"zh", @"hk"],
        @"TW": @[@"466", @"92",  @"Chunghwa",   @"zh_TW", @"TWD", @"zh", @"tw"],
        @"CN": @[@"460", @"00",  @"China Mobile", @"zh_CN", @"CNY", @"zh", @"cn"],
    };
    return m;
}

// Blocking HTTP GET to ip-api.com — returns parsed dict or nil on any failure.
// Runs on background queue (caller is already off main), 5s timeout.
static NSDictionary *ci_fetchProxyGeo(NSString *url) {
    if (!url.length) url = @"http://ip-api.com/json";
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 5.0;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    [req setValue:@"close" forHTTPHeaderField:@"Connection"];

    __block NSData *data = nil; __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *_r, NSError *e) {
            data = d; err = e; dispatch_semaphore_signal(sem);
        }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)));
    if (err || !data) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSString *status = json[@"status"];
    if (status && ![status isEqualToString:@"success"]) return nil;
    return json;
}

// Apply ip-api geo response to config. Returns YES if applied.
static BOOL ci_applyGeoFromIPAPI(NSDictionary *geo) {
    if (!geo) return NO;
    id latV = geo[@"lat"], lonV = geo[@"lon"];
    if (!latV || !lonV) return NO;
    CIConfigManager *cm = [CIConfigManager shared];

    // Match proxy IP location — small jitter (~2km) only for GPS sensor
    // realism so every reset isn't pixel-identical. Big jitter here would
    // create an IP/GPS mismatch and defeat the point of the proxy.
    double lat = 0, lon = 0;
    ci_jitterCoordKm([latV doubleValue], [lonV doubleValue], 2.0, &lat, &lon);
    double alt = ci_randDouble(5.0, 180.0);
    [cm setObject:[NSString stringWithFormat:@"%.6f", lat] forKey:@"latitude"];
    [cm setObject:[NSString stringWithFormat:@"%.6f", lon] forKey:@"longitude"];
    [cm setObject:[NSString stringWithFormat:@"%.2f", alt] forKey:@"altitude"];
    ci_writeLocationFuzz(cm);

    NSString *tz = geo[@"timezone"];
    if ([tz isKindOfClass:[NSString class]] && tz.length) [cm setObject:tz forKey:@"timezoneName"];

    NSString *cc = geo[@"countryCode"];
    if ([cc isKindOfClass:[NSString class]] && cc.length) {
        NSArray *info = ci_countryMap()[cc.uppercaseString];
        if (info.count >= 7) {
            [cm setObject:info[0] forKey:@"carrierMCC"];
            [cm setObject:info[1] forKey:@"carrierMNC"];
            [cm setObject:info[3] forKey:@"localeIdentifier"];
            [cm setObject:cc.uppercaseString forKey:@"localeCountryCode"];
            [cm setObject:info[4] forKey:@"localeCurrencyCode"];
            [cm setObject:info[5] forKey:@"localeLanguageCode"];
            [cm setObject:info[6] forKey:@"carrierISO"];
            // Prefer real ISP name from ip-api so carrier matches the proxy's ASN.
            NSString *isp = geo[@"isp"]; if (![isp isKindOfClass:[NSString class]]) isp = nil;
            [cm setObject:(isp.length ? isp : info[2]) forKey:@"carrierName"];
        } else {
            // Unknown country — at least set the country code so locale is broadly right.
            [cm setObject:cc.uppercaseString forKey:@"localeCountryCode"];
            NSString *isp = geo[@"isp"];
            if ([isp isKindOfClass:[NSString class]] && isp.length)
                [cm setObject:isp forKey:@"carrierName"];
        }
    }
    NSString *q = geo[@"query"];
    if ([q isKindOfClass:[NSString class]] && q.length) [cm setObject:q forKey:@"lastResetIP"];
    return YES;
}

// Random model + iOS presets (inline to avoid forward-decl issues)
// Per-device preset row: real iPhone specs that need to stay coherent so apps
// and the iOS frameworks reading them don't see contradictions (e.g. iPhone 12
// with an A16 chip ID would throw assertions in Apple's hardware probes).
// Index map (NSArray columns):
//   0  modelName              "iPhone 12"
//   1  productType             "iPhone13,2"
//   2  hwMachine               "iPhone13,2"
//   3  screenWidth             "390"
//   4  screenHeight            "844"
//   5  screenScale             "3"
//   6  nativeWidth             "1170"
//   7  nativeHeight            "2532"
//   8  nativeScale             "3"
//   9  chipName                "A14 Bionic"
//   10 chipIDHex               "0x8101"        — real ProductTypeIdentifier
//   11 boardIDHex              "0x18"          — real BoardId
//   12 ramBytesNumber          @(4294967296)   — NSNumber, 4 GB
//   13 cpuCoresNumber          @(6)            — NSNumber
//   14 minIOSMajor             @(14)
//   15 maxIOSMajor             @(18)
//   16 colorChoices            @[@"Black", @"White", ...]   — real launch colors
static NSArray *ci_randomPresets(void) {
    static NSArray *presets = nil;
    if (!presets) {
        NSArray *colorsClassic = @[@"Space Gray", @"Silver", @"Gold"];
        NSArray *colorsX       = @[@"Space Gray", @"Silver"];
        NSArray *colorsXR      = @[@"Black", @"White", @"Red", @"Yellow", @"Blue", @"Coral"];
        NSArray *colors11      = @[@"Black", @"White", @"Red", @"Yellow", @"Green", @"Purple"];
        NSArray *colors11Pro   = @[@"Space Gray", @"Silver", @"Gold", @"Midnight Green"];
        NSArray *colors12      = @[@"Black", @"White", @"Red", @"Green", @"Blue", @"Purple"];
        NSArray *colors12Pro   = @[@"Pacific Blue", @"Graphite", @"Silver", @"Gold"];
        NSArray *colors13      = @[@"Pink", @"Blue", @"Midnight", @"Starlight", @"Red", @"Green"];
        NSArray *colors13Pro   = @[@"Sierra Blue", @"Silver", @"Gold", @"Graphite", @"Alpine Green"];
        NSArray *colors14      = @[@"Midnight", @"Starlight", @"Blue", @"Purple", @"Red", @"Yellow"];
        NSArray *colors14Pro   = @[@"Space Black", @"Silver", @"Gold", @"Deep Purple"];
        NSArray *colors15      = @[@"Black", @"Blue", @"Green", @"Yellow", @"Pink"];
        NSArray *colors15Pro   = @[@"Black Titanium", @"White Titanium", @"Blue Titanium", @"Natural Titanium"];
        NSArray *colors16      = @[@"Black", @"White", @"Pink", @"Teal", @"Ultramarine"];
        NSArray *colors16Pro   = @[@"Black Titanium", @"White Titanium", @"Natural Titanium", @"Desert Titanium"];

        presets = @[
            @[@"iPhone 5",          @"iPhone5,2",  @"iPhone5,2",  @"320", @"568", @"2", @"640",  @"1136", @"2", @"A6",        @"0x8950", @"0x00", @(1073741824), @(2),  @(7),  @(10), colorsClassic],
            @[@"iPhone 5s",         @"iPhone6,1",  @"iPhone6,1",  @"320", @"568", @"2", @"640",  @"1136", @"2", @"A7",        @"0x8960", @"0x00", @(1073741824), @(2),  @(7),  @(12), colorsClassic],
            @[@"iPhone SE (1)",     @"iPhone8,4",  @"iPhone8,4",  @"320", @"568", @"2", @"640",  @"1136", @"2", @"A9",        @"0x8000", @"0x24", @(2147483648), @(2),  @(9),  @(15), colorsClassic],
            @[@"iPhone 6",          @"iPhone7,2",  @"iPhone7,2",  @"375", @"667", @"2", @"750",  @"1334", @"2", @"A8",        @"0x7000", @"0x10", @(1073741824), @(2),  @(8),  @(12), colorsClassic],
            @[@"iPhone 6 Plus",     @"iPhone7,1",  @"iPhone7,1",  @"414", @"736", @"3", @"1242", @"2208", @"3", @"A8",        @"0x7000", @"0x10", @(1073741824), @(2),  @(8),  @(12), colorsClassic],
            @[@"iPhone 6s",         @"iPhone8,1",  @"iPhone8,1",  @"375", @"667", @"2", @"750",  @"1334", @"2", @"A9",        @"0x8000", @"0x10", @(2147483648), @(2),  @(9),  @(15), colorsClassic],
            @[@"iPhone 6s Plus",    @"iPhone8,2",  @"iPhone8,2",  @"414", @"736", @"3", @"1242", @"2208", @"3", @"A9",        @"0x8000", @"0x10", @(2147483648), @(2),  @(9),  @(15), colorsClassic],
            @[@"iPhone 7",          @"iPhone9,1",  @"iPhone9,1",  @"375", @"667", @"2", @"750",  @"1334", @"2", @"A10 Fusion",@"0x8010", @"0x10", @(2147483648), @(4),  @(10), @(15), @[@"Black", @"Jet Black", @"Silver", @"Gold", @"Rose Gold", @"Red"]],
            @[@"iPhone 7 Plus",     @"iPhone9,2",  @"iPhone9,2",  @"414", @"736", @"3", @"1242", @"2208", @"3", @"A10 Fusion",@"0x8010", @"0x10", @(3221225472), @(4),  @(10), @(15), @[@"Black", @"Jet Black", @"Silver", @"Gold", @"Rose Gold", @"Red"]],
            @[@"iPhone 8",          @"iPhone10,1", @"iPhone10,1", @"375", @"667", @"2", @"750",  @"1334", @"2", @"A11 Bionic",@"0x8015", @"0x04", @(2147483648), @(6),  @(11), @(16), @[@"Space Gray", @"Silver", @"Gold", @"Red"]],
            @[@"iPhone 8 Plus",     @"iPhone10,2", @"iPhone10,2", @"414", @"736", @"3", @"1242", @"2208", @"3", @"A11 Bionic",@"0x8015", @"0x04", @(3221225472), @(6),  @(11), @(16), @[@"Space Gray", @"Silver", @"Gold", @"Red"]],
            @[@"iPhone X",          @"iPhone10,3", @"iPhone10,3", @"375", @"812", @"3", @"1125", @"2436", @"3", @"A11 Bionic",@"0x8015", @"0x04", @(3221225472), @(6),  @(11), @(16), colorsX],
            @[@"iPhone XR",         @"iPhone11,8", @"iPhone11,8", @"414", @"896", @"2", @"828",  @"1792", @"2", @"A12 Bionic",@"0x8020", @"0x0E", @(3221225472), @(6),  @(12), @(17), colorsXR],
            @[@"iPhone XS",         @"iPhone11,2", @"iPhone11,2", @"375", @"812", @"3", @"1125", @"2436", @"3", @"A12 Bionic",@"0x8020", @"0x0E", @(4294967296), @(6),  @(12), @(16), @[@"Space Gray", @"Silver", @"Gold"]],
            @[@"iPhone XS Max",     @"iPhone11,6", @"iPhone11,6", @"414", @"896", @"3", @"1242", @"2688", @"3", @"A12 Bionic",@"0x8020", @"0x0E", @(4294967296), @(6),  @(12), @(16), @[@"Space Gray", @"Silver", @"Gold"]],
            @[@"iPhone SE (2)",     @"iPhone12,8", @"iPhone12,8", @"375", @"667", @"2", @"750",  @"1334", @"2", @"A13 Bionic",@"0x8030", @"0x0E", @(3221225472), @(6),  @(13), @(18), @[@"Black", @"White", @"Red"]],
            @[@"iPhone 11",         @"iPhone12,1", @"iPhone12,1", @"414", @"896", @"2", @"828",  @"1792", @"2", @"A13 Bionic",@"0x8030", @"0x0E", @(4294967296), @(6),  @(13), @(18), colors11],
            @[@"iPhone 11 Pro",     @"iPhone12,3", @"iPhone12,3", @"375", @"812", @"3", @"1125", @"2436", @"3", @"A13 Bionic",@"0x8030", @"0x0E", @(4294967296), @(6),  @(13), @(17), colors11Pro],
            @[@"iPhone 11 Pro Max", @"iPhone12,5", @"iPhone12,5", @"414", @"896", @"3", @"1242", @"2688", @"3", @"A13 Bionic",@"0x8030", @"0x0E", @(4294967296), @(6),  @(13), @(17), colors11Pro],
            @[@"iPhone 12 mini",    @"iPhone13,1", @"iPhone13,1", @"375", @"812", @"3", @"1080", @"2340", @"3", @"A14 Bionic",@"0x8101", @"0x18", @(4294967296), @(6),  @(14), @(18), colors12],
            @[@"iPhone 12",         @"iPhone13,2", @"iPhone13,2", @"390", @"844", @"3", @"1170", @"2532", @"3", @"A14 Bionic",@"0x8101", @"0x18", @(4294967296), @(6),  @(14), @(18), colors12],
            @[@"iPhone 12 Pro",     @"iPhone13,3", @"iPhone13,3", @"390", @"844", @"3", @"1170", @"2532", @"3", @"A14 Bionic",@"0x8101", @"0x18", @(6442450944), @(6),  @(14), @(18), colors12Pro],
            @[@"iPhone 12 Pro Max", @"iPhone13,4", @"iPhone13,4", @"428", @"926", @"3", @"1284", @"2778", @"3", @"A14 Bionic",@"0x8101", @"0x18", @(6442450944), @(6),  @(14), @(18), colors12Pro],
            @[@"iPhone 13 mini",    @"iPhone14,4", @"iPhone14,4", @"375", @"812", @"3", @"1080", @"2340", @"3", @"A15 Bionic",@"0x8110", @"0x07", @(4294967296), @(6),  @(15), @(18), colors13],
            @[@"iPhone 13",         @"iPhone14,5", @"iPhone14,5", @"390", @"844", @"3", @"1170", @"2532", @"3", @"A15 Bionic",@"0x8110", @"0x07", @(4294967296), @(6),  @(15), @(18), colors13],
            @[@"iPhone 13 Pro",     @"iPhone14,2", @"iPhone14,2", @"390", @"844", @"3", @"1170", @"2532", @"3", @"A15 Bionic",@"0x8110", @"0x07", @(6442450944), @(6),  @(15), @(18), colors13Pro],
            @[@"iPhone 13 Pro Max", @"iPhone14,3", @"iPhone14,3", @"428", @"926", @"3", @"1284", @"2778", @"3", @"A15 Bionic",@"0x8110", @"0x07", @(6442450944), @(6),  @(15), @(18), colors13Pro],
            @[@"iPhone SE (3)",     @"iPhone14,6", @"iPhone14,6", @"375", @"667", @"2", @"750",  @"1334", @"2", @"A15 Bionic",@"0x8110", @"0x07", @(4294967296), @(6),  @(15), @(18), @[@"Midnight", @"Starlight", @"Red"]],
            @[@"iPhone 14",         @"iPhone14,7", @"iPhone14,7", @"390", @"844", @"3", @"1170", @"2532", @"3", @"A15 Bionic",@"0x8110", @"0x07", @(6442450944), @(6),  @(16), @(18), colors14],
            @[@"iPhone 14 Plus",    @"iPhone14,8", @"iPhone14,8", @"428", @"926", @"3", @"1284", @"2778", @"3", @"A15 Bionic",@"0x8110", @"0x07", @(6442450944), @(6),  @(16), @(18), colors14],
            @[@"iPhone 14 Pro",     @"iPhone15,2", @"iPhone15,2", @"393", @"852", @"3", @"1179", @"2556", @"3", @"A16 Bionic",@"0x8120", @"0x08", @(6442450944), @(6),  @(16), @(18), colors14Pro],
            @[@"iPhone 14 Pro Max", @"iPhone15,3", @"iPhone15,3", @"430", @"932", @"3", @"1290", @"2796", @"3", @"A16 Bionic",@"0x8120", @"0x08", @(6442450944), @(6),  @(16), @(18), colors14Pro],
            @[@"iPhone 15",         @"iPhone15,4", @"iPhone15,4", @"393", @"852", @"3", @"1179", @"2556", @"3", @"A16 Bionic",@"0x8120", @"0x08", @(6442450944), @(6),  @(17), @(18), colors15],
            @[@"iPhone 15 Plus",    @"iPhone15,5", @"iPhone15,5", @"430", @"932", @"3", @"1290", @"2796", @"3", @"A16 Bionic",@"0x8120", @"0x08", @(6442450944), @(6),  @(17), @(18), colors15],
            @[@"iPhone 15 Pro",     @"iPhone16,1", @"iPhone16,1", @"393", @"852", @"3", @"1179", @"2556", @"3", @"A17 Pro",   @"0x8130", @"0x0D", @(8589934592), @(6),  @(17), @(18), colors15Pro],
            @[@"iPhone 15 Pro Max", @"iPhone16,2", @"iPhone16,2", @"430", @"932", @"3", @"1290", @"2796", @"3", @"A17 Pro",   @"0x8130", @"0x0D", @(8589934592), @(6),  @(17), @(18), colors15Pro],
            @[@"iPhone 16",         @"iPhone17,3", @"iPhone17,3", @"393", @"852", @"3", @"1179", @"2556", @"3", @"A18",       @"0x8140", @"0x0E", @(8589934592), @(6),  @(18), @(18), colors16],
            @[@"iPhone 16 Plus",    @"iPhone17,4", @"iPhone17,4", @"430", @"932", @"3", @"1290", @"2796", @"3", @"A18",       @"0x8140", @"0x0E", @(8589934592), @(6),  @(18), @(18), colors16],
            @[@"iPhone 16 Pro",     @"iPhone17,1", @"iPhone17,1", @"402", @"874", @"3", @"1206", @"2622", @"3", @"A18 Pro",   @"0x8150", @"0x0F", @(8589934592), @(6),  @(18), @(18), colors16Pro],
            @[@"iPhone 16 Pro Max", @"iPhone17,2", @"iPhone17,2", @"440", @"956", @"3", @"1320", @"2868", @"3", @"A18 Pro",   @"0x8150", @"0x0F", @(8589934592), @(6),  @(18), @(18), colors16Pro],
        ];
    }
    return presets;
}

static NSArray *ci_randomIOSPresets(void) {
    static NSArray *iosList = nil;
    if (!iosList) {
        // Granular list — every shipping minor + most patch releases from
        // iOS 14 through 18. Matches the picker wheel resolution shown in
        // mainstream tools (multiple decimal versions per major).
        iosList = @[
            @[@"iOS 14.0",   @"14.0",   @"18A373"],
            @[@"iOS 14.1",   @"14.1",   @"18A8395"],
            @[@"iOS 14.2",   @"14.2",   @"18B92"],
            @[@"iOS 14.3",   @"14.3",   @"18C66"],
            @[@"iOS 14.4",   @"14.4",   @"18D52"],
            @[@"iOS 14.4.1", @"14.4.1", @"18D61"],
            @[@"iOS 14.4.2", @"14.4.2", @"18D70"],
            @[@"iOS 14.5",   @"14.5",   @"18E199"],
            @[@"iOS 14.5.1", @"14.5.1", @"18E212"],
            @[@"iOS 14.6",   @"14.6",   @"18F72"],
            @[@"iOS 14.7",   @"14.7",   @"18G69"],
            @[@"iOS 14.7.1", @"14.7.1", @"18G82"],
            @[@"iOS 14.8",   @"14.8",   @"18H17"],
            @[@"iOS 14.8.1", @"14.8.1", @"18H107"],
            @[@"iOS 15.0",   @"15.0",   @"19A346"],
            @[@"iOS 15.0.1", @"15.0.1", @"19A348"],
            @[@"iOS 15.0.2", @"15.0.2", @"19A404"],
            @[@"iOS 15.1",   @"15.1",   @"19B74"],
            @[@"iOS 15.1.1", @"15.1.1", @"19B81"],
            @[@"iOS 15.2",   @"15.2",   @"19C56"],
            @[@"iOS 15.2.1", @"15.2.1", @"19C63"],
            @[@"iOS 15.3",   @"15.3",   @"19D50"],
            @[@"iOS 15.3.1", @"15.3.1", @"19D52"],
            @[@"iOS 15.4",   @"15.4",   @"19E241"],
            @[@"iOS 15.4.1", @"15.4.1", @"19E258"],
            @[@"iOS 15.5",   @"15.5",   @"19F77"],
            @[@"iOS 15.6",   @"15.6",   @"19G71"],
            @[@"iOS 15.6.1", @"15.6.1", @"19G82"],
            @[@"iOS 15.7",   @"15.7",   @"19H12"],
            @[@"iOS 16.0",   @"16.0",   @"20A362"],
            @[@"iOS 16.0.1", @"16.0.1", @"20A371"],
            @[@"iOS 16.0.2", @"16.0.2", @"20A380"],
            @[@"iOS 16.0.3", @"16.0.3", @"20A392"],
            @[@"iOS 16.1",   @"16.1",   @"20B82"],
            @[@"iOS 16.1.1", @"16.1.1", @"20B101"],
            @[@"iOS 16.1.2", @"16.1.2", @"20B110"],
            @[@"iOS 16.2",   @"16.2",   @"20C65"],
            @[@"iOS 16.3",   @"16.3",   @"20D47"],
            @[@"iOS 16.3.1", @"16.3.1", @"20D67"],
            @[@"iOS 16.4",   @"16.4",   @"20E247"],
            @[@"iOS 16.4.1", @"16.4.1", @"20E252"],
            @[@"iOS 16.5",   @"16.5",   @"20F66"],
            @[@"iOS 16.5.1", @"16.5.1", @"20F75"],
            @[@"iOS 16.6",   @"16.6",   @"20G75"],
            @[@"iOS 16.6.1", @"16.6.1", @"20G81"],
            @[@"iOS 16.7",   @"16.7",   @"20H19"],
            @[@"iOS 16.7.1", @"16.7.1", @"20H30"],
            @[@"iOS 17.0",   @"17.0",   @"21A329"],
            @[@"iOS 17.0.1", @"17.0.1", @"21A340"],
            @[@"iOS 17.0.2", @"17.0.2", @"21A350"],
            @[@"iOS 17.0.3", @"17.0.3", @"21A360"],
            @[@"iOS 17.1",   @"17.1",   @"21B74"],
            @[@"iOS 17.1.1", @"17.1.1", @"21B91"],
            @[@"iOS 17.1.2", @"17.1.2", @"21B101"],
            @[@"iOS 17.2",   @"17.2",   @"21C62"],
            @[@"iOS 17.2.1", @"17.2.1", @"21C66"],
            @[@"iOS 17.3",   @"17.3",   @"21D50"],
            @[@"iOS 17.3.1", @"17.3.1", @"21D61"],
            @[@"iOS 17.4",   @"17.4",   @"21E219"],
            @[@"iOS 17.4.1", @"17.4.1", @"21E236"],
            @[@"iOS 17.5",   @"17.5",   @"21F79"],
            @[@"iOS 17.5.1", @"17.5.1", @"21F90"],
            @[@"iOS 17.6",   @"17.6",   @"21G80"],
            @[@"iOS 17.6.1", @"17.6.1", @"21G93"],
            @[@"iOS 17.7",   @"17.7",   @"21H16"],
            @[@"iOS 17.7.1", @"17.7.1", @"21H216"],
            @[@"iOS 17.7.2", @"17.7.2", @"21H221"],
            @[@"iOS 18.0",   @"18.0",   @"22A3354"],
            @[@"iOS 18.0.1", @"18.0.1", @"22A3370"],
            @[@"iOS 18.1",   @"18.1",   @"22B83"],
            @[@"iOS 18.1.1", @"18.1.1", @"22B91"],
            @[@"iOS 18.2",   @"18.2",   @"22C152"],
            @[@"iOS 18.2.1", @"18.2.1", @"22C161"],
            @[@"iOS 18.3",   @"18.3",   @"22D63"],
            @[@"iOS 18.3.1", @"18.3.1", @"22D72"],
            @[@"iOS 18.3.2", @"18.3.2", @"22D82"],
        ];
    }
    return iosList;
}

// Regenerate every rotating identity + geo profile on each Reset.
// Also picks a random model + iOS version so every reset = fresh device.
static NSUInteger ci_randomizeIdentities(void) {
    CIConfigManager *cm = [CIConfigManager shared];

    // === Random model (all fake layers auto-on) ===
    // Both ci_randomPresets()/ci_randomIOSPresets() and the Fake Settings VC
    // pull from the same arrays (the VC's class methods delegate to these
    // C functions), so the slider's index window aligns with the picks here.
    NSArray *presets = ci_randomPresets();
    NSArray *iosList = ci_randomIOSPresets();

    NSUInteger devN = presets.count;
    NSUInteger iosN = iosList.count;
    NSInteger devMaxI = devN > 0 ? (NSInteger)devN - 1 : 0;
    NSInteger iosMaxI = iosN > 0 ? (NSInteger)iosN - 1 : 0;
    id devMinObj = [cm objectForKey:@"__deviceMinIdx"];
    id devMaxObj = [cm objectForKey:@"__deviceMaxIdx"];
    id iosMinObj = [cm objectForKey:@"__iosMinIdx"];
    id iosMaxObj = [cm objectForKey:@"__iosMaxIdx"];
    NSInteger dLo = devMinObj ? [devMinObj integerValue] : 0;
    NSInteger dHi = devMaxObj ? [devMaxObj integerValue] : devMaxI;
    NSInteger iLo = iosMinObj ? [iosMinObj integerValue] : 0;
    NSInteger iHi = iosMaxObj ? [iosMaxObj integerValue] : iosMaxI;
    dLo = MAX(0, MIN(devMaxI, dLo)); dHi = MAX(0, MIN(devMaxI, dHi)); if (dLo > dHi) { NSInteger t = dLo; dLo = dHi; dHi = t; }
    iLo = MAX(0, MIN(iosMaxI, iLo)); iHi = MAX(0, MIN(iosMaxI, iHi)); if (iLo > iHi) { NSInteger t = iLo; iLo = iHi; iHi = t; }

    NSArray *preset = presets[(NSUInteger)dLo + arc4random_uniform((uint32_t)(dHi - dLo + 1))];
    NSArray *iosPreset = iosList[(NSUInteger)iLo + arc4random_uniform((uint32_t)(iHi - iLo + 1))];

    // Coherent column extraction — fields beyond index 8 are NEW (chip, board,
    // RAM, CPU cores, supported iOS range, color list). All numeric fields
    // are stored as NSNumber so hooks can call -unsigned*Value safely.
    NSString *modelName  = preset[0];
    NSString *productTyp = preset[1];
    NSString *hwMachine  = preset[2];
    NSString *chipIDHex  = preset.count > 10 ? preset[10] : @"0x8101";
    NSString *boardIDHex = preset.count > 11 ? preset[11] : @"0x18";
    NSNumber *ramBytes   = preset.count > 12 ? preset[12] : @(4294967296);
    NSNumber *cpuCores   = preset.count > 13 ? preset[13] : @(6);
    NSArray  *colors     = preset.count > 16 ? preset[16] : @[@"Black"];

    // Apply model preset
    // deviceModel = full consumer name ("iPhone 15 Pro Max") so UIDevice.model hook
    // returns something meaningful instead of generic "iPhone"
    [cm setObject:modelName  forKey:@"deviceModel"];
    [cm setObject:modelName  forKey:@"localizedModel"];
    [cm setObject:@"iPhone"  forKey:@"systemName"];
    [cm setObject:productTyp forKey:@"ProductType"];
    [cm setObject:hwMachine  forKey:@"hw_machine"];
    [cm setObject:hwMachine  forKey:@"HardwareModel"];
    [cm setObject:hwMachine  forKey:@"HWModelStr"];     // align legacy alias to current preset
    [cm setObject:hwMachine  forKey:@"hw_model"];       // align legacy alias to current preset
    [cm setObject:hwMachine  forKey:@"uname_machine"];
    [cm setObject:preset[3]  forKey:@"screenWidth"];
    [cm setObject:preset[4]  forKey:@"screenHeight"];
    [cm setObject:preset[5]  forKey:@"screenScale"];
    [cm setObject:preset[6]  forKey:@"nativeScreenWidth"];
    [cm setObject:preset[7]  forKey:@"nativeScreenHeight"];
    [cm setObject:preset[8]  forKey:@"nativeScale"];
    [cm setObject:modelName  forKey:@"__presetModelName"];
    [cm setObject:@(YES)     forKey:@"fake_uiddevice"];
    [cm setObject:@(YES)     forKey:@"fake_screen"];

    // Apply iOS preset
    [cm setObject:iosPreset[1] forKey:@"systemVersion"];
    [cm setObject:iosPreset[2] forKey:@"BuildVersion"];
    [cm setObject:iosPreset[0] forKey:@"__presetIOSName"];
    [cm setObject:@(YES) forKey:@"fake_sysosversion"];

    // WebView User-Agent removed — was added in ac4ec0e along with the
    // 14 extras and triggered the same crash chain. Restore once we
    // identify the actual trigger.

    // Additional keys for deep spoofing (AIDA64 reads these)
    [cm setObject:ci_randSerial() forKey:@"IOPlatformSerialNumber"];
    // Real iOS uses canonical UUID format (8-4-4-4-12 with dashes). Apps
    // calling [NSUUID UUID initWithUUIDString:] on a 40-char hex blob
    // get nil back and may then crash when dereferencing.
    [cm setObject:[[NSUUID UUID] UUIDString] forKey:@"IOPlatformUUID"];
    [cm setObject:[NSString stringWithFormat:@"iBoot-%d.%d.%d", arc4random_uniform(100)+7000, arc4random_uniform(99)+1, arc4random_uniform(9)+1] forKey:@"FirmwareVersion"];
    [cm setObject:[NSString stringWithFormat:@"%d.%d.%d", arc4random_uniform(9)+1, arc4random_uniform(99)+10, arc4random_uniform(9)] forKey:@"BasebandVersion"];
    static NSArray *kModelNumbers = nil;
    if (!kModelNumbers) kModelNumbers = @[@"MTGM2VC/A", @"MQ8L3VN/A", @"MN9P3VN/A", @"MQ7N3VN/A", @"MTU13VN/A", @"MGAH3VN/A"];
    [cm setObject:kModelNumbers[arc4random_uniform((uint32_t)kModelNumbers.count)] forKey:@"ModelNumber"];
    [cm setObject:@"VN" forKey:@"RegionCode"];
    [cm setObject:@"VN/A" forKey:@"RegionInfo"];
    [cm setObject:boardIDHex forKey:@"BoardId"];
    [cm setObject:chipIDHex  forKey:@"ChipID"];
    // Numeric MG/sysctl values stored as NSNumber so hook -unsigned*Value
    // converters never see a string.
    [cm setObject:ramBytes  forKey:@"physicalMemory"];
    [cm setObject:ramBytes  forKey:@"hw_memsize"];
    [cm setObject:cpuCores  forKey:@"processorCount"];
    [cm setObject:cpuCores  forKey:@"hw_physicalcpu"];
    [cm setObject:cpuCores  forKey:@"hw_logicalcpu_max"];
    unsigned long long capacity64 = (unsigned long long)(arc4random_uniform(4) + 1) * 64ULL * 1073741824ULL; // 64/128/192/256 GB
    [cm setObject:@(capacity64) forKey:@"TotalDiskCapacity"];
    [cm setObject:@(capacity64 - (unsigned long long)(arc4random_uniform(20)+5) * 1073741824ULL) forKey:@"TotalSystemAvailable"];
    [cm setObject:@((unsigned long long)(arc4random_uniform(20)+5) * 1073741824ULL) forKey:@"DiskUsage"];
    // No more "iPhone iPhone XS" — single-prefix consumer name.
    [cm setObject:modelName forKey:@"DeviceName"];
    [cm setObject:modelName forKey:@"DeviceNameMG"];
    [cm setObject:modelName forKey:@"UserAssignedDeviceName"];
    [cm setObject:modelName forKey:@"deviceName"];
    [cm setObject:modelName forKey:@"MarketingName"];
    NSString *colorPick = colors[arc4random_uniform((uint32_t)colors.count)];
    [cm setObject:colorPick forKey:@"DeviceColor"];
    [cm setObject:colorPick forKey:@"DeviceEnclosureColor"];
    [cm setObject:@"kCTSIMSupportSIMStatusReady" forKey:@"SIMTrayStatus"];
    [cm setObject:@(NO) forKey:@"AirplaneMode"];
    [cm setObject:@(arc4random_uniform(80)+20) forKey:@"BatteryCurrentCapacity"];
    [cm setObject:@(NO) forKey:@"BatteryIsCharging"];
    [cm setObject:ci_randAlnum(12) forKey:@"BatterySerialNumber"];
    [cm setObject:[NSString stringWithFormat:@"0x%@", ci_randHex(16)] forKey:@"BootNonce"];

    // Ensure all fake layers on
    NSArray *allFakeLayers = @[
        @"fake_sysosversion", @"fake_uiddevice", @"fake_screen", @"fake_realscreen",
        @"fake_processinfo", @"fake_location", @"fake_datetime", @"fake_locale",
        @"fake_locale2", @"fake_network", @"fake_hardware", @"fake_sensor",
        @"fake_ads", @"fake_wifi", @"fake_tracking_pasteboard", @"fake_trackingdefaults",
        @"fake_uiddevice2", @"fake_sysctl", @"fake_battery", @"fake_browser",
        @"fake_metal", @"fake_webrtc", @"fake_timing", @"fake_keychain",
        @"fake_jbhide", @"fake_uptime",
    ];
    for (NSString *k in allFakeLayers) {
        [cm setObject:@(YES) forKey:k];
    }

    // Hardware IDs — REVERTED to the v2.4.0-9e19459 baseline (16 keys).
    // The 14 extras added in ac4ec0e (PhoneNumber, localIP, carrierRadio
    // Access, web_glVendor/Renderer/canvasNoise, zalo_metalGPU/timingOffset,
    // clearPasteboard, zalo_fakeWebViewUA, batteryLevel/State,
    // BatteryCurrentCapacity/IsCharging, BootNonce) caused EVERY targeted
    // app to crash at launch — first with EXC_CRASH/SIGABRT in scene
    // forwarding, then with std::terminate() on FrontBoardServices serial
    // queue. User confirmed that BEFORE ac4ec0e, AIDA64 opened cleanly
    // and showed the spoofed model — same hooks, just without the new
    // config values. So one (or more) of the new values feeds a hook a
    // value Apple's frameworks reject mid-launch.
    //
    // Going back to the 16 originals to restore the working state. We can
    // add the missing-from-report fields back individually once we know
    // which one is the trigger.
    NSDictionary *ids = @{
        @"serialNumber":                          ci_randSerial(),
        @"SerialNumber":                          ci_randSerial(),
        @"advertisingIdentifier":                 ci_randUUID(),
        @"identifierForVendor":                   ci_randUUID(),
        @"UniqueDeviceID":                        ci_randHexLower(40),
        @"UniqueChipID":                          @(((unsigned long long)arc4random() << 32) | arc4random()),
        @"InternationalMobileEquipmentIdentity":  ci_randIMEI(),
        @"InternationalMobileEquipmentIdentity2": ci_randIMEI(),
        @"MobileEquipmentIdentifier":             ci_randHex(14),
        @"IntegratedCircuitCardIdentity":         [@"8901" stringByAppendingString:ci_randDigits(16)],
        @"IntegratedCircuitCardIdentity2":        [@"8901" stringByAppendingString:ci_randDigits(16)],
        @"WiFiAddress":                           ci_randMAC(),
        @"BluetoothAddress":                      ci_randMAC(),
        @"EthernetAddress":                       ci_randMAC(),
        @"wifiBSSID":                             ci_randMAC(),
        @"wifiSSID":                              [NSString stringWithFormat:@"WiFi-%@", ci_randAlnum(4)],
    };
    [ids enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *_) {
        [cm setObject:v forKey:k];
    }];

    // Geo strategy:
    //   • Proxy ON  → ip-api sees proxy's country → GPS pinned to proxy IP
    //     (tiny ~2km jitter) so IP and GPS stay coherent.
    //   • Proxy OFF / no internet → fetch fails → random point inside Vietnam
    //     within `vn_radiusKm` (default 999km from central VN), VN carrier bundle.
    NSString *apiURL = [cm stringForKey:@"ip_api_url"];
    NSDictionary *geo = ci_fetchProxyGeo(apiURL);
    BOOL applied = ci_applyGeoFromIPAPI(geo);
    if (!applied) {
        // Central Vietnam anchor (near Da Nang) so 999km disk covers all of VN.
        const double kVNLat = 16.0, kVNLon = 107.0;
        double radius = 999.0;
        id rv = [cm objectForKey:@"vn_radiusKm"];
        if ([rv respondsToSelector:@selector(doubleValue)]) {
            double r = [rv doubleValue];
            if (r > 0) radius = r;
        }
        double lat = 0, lon = 0;
        ci_jitterCoordKm(kVNLat, kVNLon, radius, &lat, &lon);
        double alt = ci_randDouble(5.0, 180.0);
        [cm setObject:[NSString stringWithFormat:@"%.6f", lat] forKey:@"latitude"];
        [cm setObject:[NSString stringWithFormat:@"%.6f", lon] forKey:@"longitude"];
        [cm setObject:[NSString stringWithFormat:@"%.2f", alt] forKey:@"altitude"];
        ci_writeLocationFuzz(cm);

        // VN locale/TZ + rotate between major VN telcos
        NSArray *vnCarriers = @[
            @[@"Viettel",      @"452", @"01"],
            @[@"Viettel",      @"452", @"04"],
            @[@"MobiFone",     @"452", @"02"],
            @[@"Vinaphone",    @"452", @"03"],
            @[@"Vinaphone",    @"452", @"07"],
            @[@"Vietnamobile", @"452", @"05"],
        ];
        NSArray *car = vnCarriers[arc4random_uniform((uint32_t)vnCarriers.count)];
        [cm setObject:@"Asia/Ho_Chi_Minh" forKey:@"timezoneName"];
        [cm setObject:@"vi_VN" forKey:@"localeIdentifier"];
        [cm setObject:@"VN"    forKey:@"localeCountryCode"];
        [cm setObject:@"VND"   forKey:@"localeCurrencyCode"];
        [cm setObject:@"vi"    forKey:@"localeLanguageCode"];
        [cm setObject:car[0]   forKey:@"carrierName"];
        [cm setObject:car[1]   forKey:@"carrierMCC"];
        [cm setObject:car[2]   forKey:@"carrierMNC"];
        [cm setObject:@"vn"    forKey:@"carrierISO"];
    }

    [cm save];
    return ids.count + 12;
}

// Resolve the on-disk Containers/Data path for a given bundle ID by
// scanning every app data container's metadata.plist. Used to wipe system
// apps (Safari, etc.) that CIAppLister doesn't enumerate because they live
// under /Applications/ rather than /var/containers/Bundle/Application/. The
// metadata.plist is binary plist; the bundle ID appears as a UTF-8 string
// inside it, so a simple grep is enough to identify the right container
// without depending on PlistBuddy or any rootless-only CLI.
static NSString *ci_findDataContainerForBundle(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
    NSData *needle = [bundleID dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *uuid in uuids) {
        NSString *full = [root stringByAppendingPathComponent:uuid];
        NSString *meta = [full stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSData *blob = [NSData dataWithContentsOfFile:meta options:NSDataReadingUncached error:nil];
        if (!blob) continue;
        if ([blob rangeOfData:needle options:0 range:NSMakeRange(0, blob.length)].location != NSNotFound) {
            return full;
        }
    }
    return nil;
}

static int ci_run(const char *cmd) {
    pid_t pid;
    // CRITICAL FIX: empty envp caused ALL shell commands to fail (cp, rm, mkdir,
    // killall etc.) because $PATH was empty → binaries not found.
    // See BUILD_NOTES §10.5 Hướng A.
    char *envp[] = {
        (char *)"PATH=/usr/bin:/usr/sbin:/bin:/sbin:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/usr/libexec:/usr/libexec",
        (char *)"HOME=/var/mobile",
        (char *)"TERM=xterm",
        NULL
    };
    // Rootless jailbreak: prefer /var/jb/usr/bin/sh
    const char *shell = "/var/jb/usr/bin/sh";
    if (access(shell, X_OK) != 0) shell = "/bin/sh";
    const char *argv[] = {shell, "-c", cmd, NULL};
    int rc = posix_spawn(&pid, shell, NULL, NULL, (char *const *)argv, envp);
    if (rc != 0) return -1;
    int status = 0; waitpid(pid, &status, 0);
    return WEXITSTATUS(status);
}

// ============================================================
// APP INFO + LIST
// ============================================================
@interface CIAppInfo : NSObject
@property (nonatomic, copy)   NSString *bundleID;
@property (nonatomic, copy)   NSString *name;
@property (nonatomic, copy)   NSString *bundlePath;
@property (nonatomic, copy)   NSString *containerPath;
@property (nonatomic, assign) unsigned long long containerSize;
@property (nonatomic, strong) UIImage  *icon;
@property (nonatomic, assign) BOOL     isSystem;
@end
@implementation CIAppInfo @end

@interface CIAppLister : NSObject
+ (NSArray<CIAppInfo *> *)allApps;
+ (UIImage *)iconForBundle:(NSString *)bid size:(CGFloat)size;
+ (unsigned long long)sizeOfPath:(NSString *)path;
@end

static NSString *CITweakFilterPath(void) {
    return @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.plist";
}

static void ci_syncTweakFilterForApps(NSArray<CIAppInfo *> *apps) {
    NSMutableOrderedSet<NSString *> *bundles = [NSMutableOrderedSet orderedSetWithArray:@[
        @"com.apple.springboard",
        @"com.apple.Preferences",
    ]];
    NSMutableOrderedSet<NSString *> *executables = [NSMutableOrderedSet orderedSet];

    for (CIAppInfo *app in apps) {
        if (app.bundleID.length) [bundles addObject:app.bundleID];
        if (!app.bundlePath.length) continue;
        NSBundle *bundle = [NSBundle bundleWithPath:app.bundlePath];
        NSString *exec = [[bundle executablePath] lastPathComponent];
        if (!exec.length) exec = [bundle objectForInfoDictionaryKey:@"CFBundleExecutable"];
        if (exec.length) [executables addObject:exec];
    }

    NSDictionary *filter = @{
        @"Filter": @{
            @"Bundles": bundles.array,
            @"Executables": executables.array,
            @"Mode": @"Any",
        }
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:filter
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (!data) {
        NSLog(@"[ChangeInfoIos] filter sync: plist serialization failed");
        return;
    }

    NSString *path = CITweakFilterPath();
    BOOL ok = [data writeToFile:path atomically:YES];
    if (ok) chmod([path fileSystemRepresentation], 0644);
    NSLog(@"[ChangeInfoIos] filter sync: %@ (%lu bundles, %lu execs)",
          ok ? @"OK" : @"FAIL",
          (unsigned long)bundles.count,
          (unsigned long)executables.count);
}

@implementation CIAppLister

+ (unsigned long long)sizeOfPath:(NSString *)path {
    if (!path) return 0;
    unsigned long long total = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL dir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&dir]) return 0;
    if (!dir) {
        NSDictionary *a = [fm attributesOfItemAtPath:path error:nil];
        return [a[NSFileSize] unsignedLongLongValue];
    }
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:path];
    for (NSString *sub in e) { (void)sub;
        NSDictionary *a = [e fileAttributes];
        if ([a[NSFileType] isEqualToString:NSFileTypeRegular])
            total += [a[NSFileSize] unsignedLongLongValue];
    }
    return total;
}

+ (UIImage *)iconForBundle:(NSString *)bid size:(CGFloat)size {
    if (!bid) return nil;
    @try {
        Class UIImageCls = NSClassFromString(@"UIImage");
        SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
        if (![UIImageCls respondsToSelector:sel]) return nil;
        NSMethodSignature *sig = [UIImageCls methodSignatureForSelector:sel];
        if (!sig) return nil;
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = UIImageCls; inv.selector = sel;
        NSInteger format = 2;
        CGFloat scale = [UIScreen mainScreen].scale;
        [inv setArgument:&bid atIndex:2];
        [inv setArgument:&format atIndex:3];
        [inv setArgument:&scale atIndex:4];
        [inv invoke];
        UIImage *__unsafe_unretained img = nil;
        [inv getReturnValue:&img];
        return img;
    } @catch (NSException *e) {
        return nil;
    }
}

+ (NSArray<CIAppInfo *> *)allApps {
    static NSArray *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *result = [NSMutableArray array];
        @try {
            Class LSAWCls = NSClassFromString(@"LSApplicationWorkspace");
            if (!LSAWCls) { cache = @[]; return; }
            id ws = [LSAWCls performSelector:@selector(defaultWorkspace)];
            NSArray *apps = [ws performSelector:@selector(allInstalledApplications)];
            for (id proxy in apps) {
                @autoreleasepool {
                    @try {
                        NSString *bid = nil;
                        if ([proxy respondsToSelector:@selector(bundleIdentifier)])
                            bid = [proxy performSelector:@selector(bundleIdentifier)];
                        if (!bid && [proxy respondsToSelector:@selector(applicationIdentifier)])
                            bid = [proxy performSelector:@selector(applicationIdentifier)];
                        if (!bid) continue;
                        NSString *type = @"";
                        if ([proxy respondsToSelector:@selector(applicationType)])
                            type = [proxy performSelector:@selector(applicationType)] ?: @"";
                        if (![type isEqualToString:@"User"]) continue;
                        if ([bid hasPrefix:@"com.apple."]) continue;
                        if ([bid isEqualToString:@"com.changeinfoios.app"]) continue;
                        CIAppInfo *info = [[CIAppInfo alloc] init];
                        info.bundleID = bid;
                        NSString *nm = nil;
                        if ([proxy respondsToSelector:@selector(localizedName)])
                            nm = [proxy performSelector:@selector(localizedName)];
                        info.name = nm.length ? nm : bid;
                        if ([proxy respondsToSelector:@selector(bundleURL)]) {
                            id burl = [proxy performSelector:@selector(bundleURL)];
                            info.bundlePath = [burl respondsToSelector:@selector(path)] ? [burl performSelector:@selector(path)] : nil;
                        }
                        if ([proxy respondsToSelector:@selector(dataContainerURL)]) {
                            id durl = [proxy performSelector:@selector(dataContainerURL)];
                            info.containerPath = [durl respondsToSelector:@selector(path)] ? [durl performSelector:@selector(path)] : nil;
                        }
                        info.isSystem = NO;
                        info.icon = nil;          // lazy-load per cell
                        info.containerSize = 0;   // lazy
                        [result addObject:info];
                    } @catch (NSException *ie) { /* skip bad proxy */ }
                }
            }
        } @catch (NSException *e) { /* fall through to empty list */ }
        [result sortUsingComparator:^NSComparisonResult(CIAppInfo *a, CIAppInfo *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
        cache = [result copy];
    });
    return cache;
}
@end

// ============================================================
// RRS STORE (retention snapshot)
// ============================================================
@interface CIRRSEntry : NSObject <NSCoding>
@property (nonatomic, copy)   NSString *uid;           // filename base
@property (nonatomic, copy)   NSString *idfa;
@property (nonatomic, copy)   NSString *ipReset;
@property (nonatomic, copy)   NSArray<NSString *> *appNames;
@property (nonatomic, copy)   NSArray<NSString *> *bundleIDs;
@property (nonatomic, strong) NSDate   *date;
@property (nonatomic, assign) unsigned long long totalSize;
@property (nonatomic, copy)   NSString *note;
@end
@implementation CIRRSEntry
- (instancetype)init {
    if ((self = [super init])) { self.date = [NSDate date]; }
    return self;
}
- (instancetype)initWithCoder:(NSCoder *)c {
    if ((self = [super init])) {
        self.uid = [c decodeObjectForKey:@"uid"];
        self.idfa = [c decodeObjectForKey:@"idfa"];
        self.ipReset = [c decodeObjectForKey:@"ip"];
        self.appNames = [c decodeObjectForKey:@"names"];
        self.bundleIDs = [c decodeObjectForKey:@"bids"];
        self.date = [c decodeObjectForKey:@"date"];
        self.totalSize = [[c decodeObjectForKey:@"size"] unsignedLongLongValue];
        self.note = [c decodeObjectForKey:@"note"];
    }
    return self;
}
- (void)encodeWithCoder:(NSCoder *)c {
    [c encodeObject:self.uid forKey:@"uid"];
    [c encodeObject:self.idfa forKey:@"idfa"];
    [c encodeObject:self.ipReset forKey:@"ip"];
    [c encodeObject:self.appNames forKey:@"names"];
    [c encodeObject:self.bundleIDs forKey:@"bids"];
    [c encodeObject:self.date forKey:@"date"];
    [c encodeObject:@(self.totalSize) forKey:@"size"];
    [c encodeObject:self.note forKey:@"note"];
}
@end

@interface CIRRSStore : NSObject
+ (instancetype)shared;
- (NSMutableArray<CIRRSEntry *> *)entries;
- (void)reload;
- (void)addEntry:(CIRRSEntry *)e;
- (void)deleteEntry:(CIRRSEntry *)e;
- (void)saveIndex;
@end

@implementation CIRRSStore {
    NSMutableArray<CIRRSEntry *> *_items;
}
+ (instancetype)shared { static CIRRSStore *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [[CIRRSStore alloc] init]; [s reload]; }); return s; }

- (NSString *)indexPath { return [kRRSDir stringByAppendingPathComponent:@"index.plist"]; }

- (void)reload {
    _items = [NSMutableArray array];
    [[NSFileManager defaultManager] createDirectoryAtPath:kRRSDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSData dataWithContentsOfFile:[self indexPath]];
    if (!d) return;
    @try {
        NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:d error:nil];
        u.requiresSecureCoding = NO;
        NSArray *arr = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        if ([arr isKindOfClass:[NSArray class]]) _items = [arr mutableCopy];
    } @catch (__unused NSException *e) {}
}

- (NSMutableArray<CIRRSEntry *> *)entries { return _items; }

- (void)saveIndex {
    NSKeyedArchiver *a = [[NSKeyedArchiver alloc] initRequiringSecureCoding:NO];
    [a encodeObject:_items forKey:NSKeyedArchiveRootObjectKey];
    [a.encodedData writeToFile:[self indexPath] atomically:YES];
}

- (void)addEntry:(CIRRSEntry *)e { [_items insertObject:e atIndex:0]; [self saveIndex]; }
- (void)deleteEntry:(CIRRSEntry *)e {
    NSString *tar = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar.gz"]];
    [[NSFileManager defaultManager] removeItemAtPath:tar error:nil];
    [_items removeObject:e];
    [self saveIndex];
}
@end

// ============================================================
// THEME (matches "Xoa Info" light style)
// ============================================================
@interface CITheme : NSObject
+ (UIColor *)bg;
+ (UIColor *)card;
+ (UIColor *)text;
+ (UIColor *)dim;
+ (UIColor *)orange;
+ (UIColor *)blue;
+ (UIColor *)separator;
+ (UIColor *)border;
+ (UIColor *)green;
+ (UIColor *)red;
+ (UIFont  *)h1;
+ (UIFont  *)h2;
+ (UIFont  *)body;
+ (UIFont  *)small;
@end

@implementation CITheme
+ (UIColor *)rgb:(NSUInteger)h { return [UIColor colorWithRed:((h>>16)&0xFF)/255.0 green:((h>>8)&0xFF)/255.0 blue:(h&0xFF)/255.0 alpha:1.0]; }
+ (UIColor *)bg        { return [self rgb:0x0F1624]; }    // deep navy
+ (UIColor *)card      { return [self rgb:0x1B2438]; }    // card navy
+ (UIColor *)text      { return [UIColor whiteColor]; }
+ (UIColor *)dim       { return [self rgb:0x9AA4B8]; }
+ (UIColor *)orange    { return [self rgb:0xFF9F1A]; }    // accent
+ (UIColor *)blue      { return [self rgb:0x4FA8FF]; }
+ (UIColor *)separator { return [self rgb:0x2A344D]; }
+ (UIColor *)border    { return [self rgb:0xFF9F1A]; }
+ (UIColor *)green     { return [self rgb:0x34C759]; }    // iOS system green
+ (UIColor *)red       { return [self rgb:0xFF3B30]; }    // iOS system red
+ (UIFont  *)h1        { return [UIFont boldSystemFontOfSize:22]; }
+ (UIFont  *)h2        { return [UIFont boldSystemFontOfSize:17]; }
+ (UIFont  *)body      { return [UIFont systemFontOfSize:15]; }
+ (UIFont  *)small     { return [UIFont systemFontOfSize:12]; }
@end

// ============================================================
// UTIL: build a bordered box button
// ============================================================
static UIButton *CIBoxButton(NSString *title, UIColor *textColor, UIColor *borderColor) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    b.titleLabel.numberOfLines = 0;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.layer.cornerRadius = 14;
    b.contentEdgeInsets = UIEdgeInsetsMake(14, 10, 14, 10);
    b.backgroundColor = borderColor; // filled primary
    b.layer.shadowColor = borderColor.CGColor;
    b.layer.shadowOffset = CGSizeMake(0, 6);
    b.layer.shadowOpacity = 0.35;
    b.layer.shadowRadius = 10;
    (void)textColor;
    return b;
}

// ============================================================
// FORMATTERS
// ============================================================
static NSString *CIBytesString(unsigned long long n) {
    if (n < 1024ULL) return [NSString stringWithFormat:@"%llu bytes", n];
    if (n < 1024ULL*1024) return [NSString stringWithFormat:@"%.0f KB", n/1024.0];
    if (n < 1024ULL*1024*1024) return [NSString stringWithFormat:@"%.1f MB", n/1024.0/1024.0];
    return [NSString stringWithFormat:@"%.2f GB", n/1024.0/1024.0/1024.0];
}
static NSString *CIDeviceBanner(void) {
    struct utsname u; uname(&u);
    NSString *ver = [UIDevice currentDevice].systemVersion;
    NSString *model = [NSString stringWithUTF8String:u.machine];
    return [NSString stringWithFormat:@"%@ (rootless, %@, %@)", kAppVersion, ver, model];
}

// ============================================================
// APP PICKER VIEW CONTROLLER
// ============================================================
typedef NS_ENUM(NSInteger, CIAppPickerMode) {
    CIAppPickerModeReset = 0,  // chọn app cần xóa dữ liệu
    CIAppPickerModeRRS   = 1,  // chọn app lưu RRS
};

@interface CIAppPickerViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, assign) CIAppPickerMode mode;
@end

@implementation CIAppPickerViewController {
    UITableView  *_table;
    UISearchBar  *_search;
    UILabel      *_summaryLbl;
    UIView       *_bottomBar;
    NSArray<CIAppInfo *> *_all;
    NSArray<CIAppInfo *> *_view;
    NSMutableSet<NSString *> *_selected;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [CITheme bg];
    self.title = self.mode == CIAppPickerModeReset ? @"Chọn app reset" : @"Chọn app lưu RRS";

    _selected = [NSMutableSet set];
    NSArray *saved = self.mode == CIAppPickerModeReset
        ? [[CIConfigManager shared] targetBundles]
        : [[CIConfigManager shared] rrsBundles];
    [_selected addObjectsFromArray:saved];

    CGFloat W = self.view.bounds.size.width;

    // ── Top search bar (sticky, full-width with rounded fill) ─────────
    UIView *searchWrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 56)];
    searchWrap.backgroundColor = [CITheme bg];
    searchWrap.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *searchBg = [[UIView alloc] initWithFrame:CGRectMake(16, 10, W - 32, 38)];
    searchBg.backgroundColor = [CITheme card];
    searchBg.layer.cornerRadius = 12;
    searchBg.layer.borderWidth = 1;
    searchBg.layer.borderColor = [[CITheme orange] colorWithAlphaComponent:0.25].CGColor;
    searchBg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [searchWrap addSubview:searchBg];

    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, searchBg.bounds.size.width, 38)];
    _search.delegate = self;
    _search.placeholder = @"Tìm app theo tên hoặc bundle ID…";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _search.tintColor = [CITheme orange];
    _search.backgroundImage = [UIImage new];
    if (@available(iOS 13.0, *)) {
        _search.searchTextField.textColor = [CITheme text];
        _search.searchTextField.backgroundColor = [UIColor clearColor];
        _search.searchTextField.attributedPlaceholder =
            [[NSAttributedString alloc] initWithString:_search.placeholder
                attributes:@{NSForegroundColorAttributeName: [CITheme dim]}];
    }
    [searchBg addSubview:_search];

    // ── Selection summary line ────────────────────────────────────────
    _summaryLbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, W, 26)];
    _summaryLbl.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _summaryLbl.textColor = [CITheme dim];
    _summaryLbl.textAlignment = NSTextAlignmentCenter;
    _summaryLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 80)];
    header.backgroundColor = [CITheme bg];
    [header addSubview:searchWrap];
    _summaryLbl.frame = CGRectMake(0, 56, W, 22);
    [header addSubview:_summaryLbl];

    // ── Bottom sticky action bar ──────────────────────────────────────
    UIView *bottom = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 78)];
    bottom.backgroundColor = [CITheme card];
    bottom.layer.shadowColor = [UIColor blackColor].CGColor;
    bottom.layer.shadowOffset = CGSizeMake(0, -3);
    bottom.layer.shadowOpacity = 0.25;
    bottom.layer.shadowRadius = 8;
    bottom.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;

    UIButton *selAll = [UIButton buttonWithType:UIButtonTypeSystem];
    selAll.frame = CGRectMake(16, 14, 110, 44);
    [selAll setTitle:@"Chọn tất cả" forState:UIControlStateNormal];
    [selAll setTitleColor:[CITheme blue] forState:UIControlStateNormal];
    selAll.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    selAll.backgroundColor = [[CITheme blue] colorWithAlphaComponent:0.12];
    selAll.layer.cornerRadius = 12;
    selAll.layer.borderWidth = 1;
    selAll.layer.borderColor = [[CITheme blue] colorWithAlphaComponent:0.4].CGColor;
    [selAll addTarget:self action:@selector(toggleAll) forControlEvents:UIControlEventTouchUpInside];
    [bottom addSubview:selAll];

    UIButton *action = [UIButton buttonWithType:UIButtonTypeSystem];
    action.frame = CGRectMake(W - 16 - 160, 14, 160, 44);
    action.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [action setTitle:(self.mode == CIAppPickerModeReset ? @"Xác nhận reset" : @"Xác nhận RRS") forState:UIControlStateNormal];
    [action setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    action.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    action.backgroundColor = [CITheme orange];
    action.layer.cornerRadius = 12;
    action.layer.shadowColor = [CITheme orange].CGColor;
    action.layer.shadowOffset = CGSizeMake(0, 4);
    action.layer.shadowOpacity = 0.4;
    action.layer.shadowRadius = 8;
    [action addTarget:self action:@selector(actionTap) forControlEvents:UIControlEventTouchUpInside];
    [bottom addSubview:action];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.delegate = self;
    _table.dataSource = self;
    _table.tableHeaderView = header;
    _table.rowHeight = 76;
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    _table.backgroundColor = [CITheme bg];
    UIEdgeInsets ci = UIEdgeInsetsMake(0, 0, 90, 0);
    _table.contentInset = ci;
    _table.scrollIndicatorInsets = ci;
    [self.view addSubview:_table];

    // bottom bar pinned to safe area
    bottom.frame = CGRectMake(0, self.view.bounds.size.height - 78 - self.view.safeAreaInsets.bottom,
                              W, 78 + self.view.safeAreaInsets.bottom);
    [self.view addSubview:bottom];
    _bottomBar = bottom;

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];

    [self updateSummary];
    [self loadAppsAsync];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (_bottomBar) {
        CGFloat sb = self.view.safeAreaInsets.bottom;
        _bottomBar.frame = CGRectMake(0, self.view.bounds.size.height - 78 - sb,
                                      self.view.bounds.size.width, 78 + sb);
    }
}

- (void)updateSummary {
    NSUInteger n = _selected.count;
    NSUInteger total = _view.count;
    NSString *icon = self.mode == CIAppPickerModeReset ? @"🧹" : @"💾";
    if (total == 0) {
        _summaryLbl.text = [NSString stringWithFormat:@"%@  Đang tải danh sách app…", icon];
    } else {
        _summaryLbl.text = [NSString stringWithFormat:@"%@  Đã chọn %lu / %lu app",
                            icon, (unsigned long)n, (unsigned long)total];
    }
}

- (void)loadAppsAsync {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *a = [CIAppLister allApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_all = a;
            self->_view = a;
            [self->_table reloadData];
            [self updateSummary];
        });
    });
}

- (void)toggleAll {
    if (_selected.count == _view.count) [_selected removeAllObjects];
    else { [_selected removeAllObjects]; for (CIAppInfo *a in _view) [_selected addObject:a.bundleID]; }
    [_table reloadData];
    [self updateSummary];
}

- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)actionTap {
    NSArray *arr = [_selected allObjects];
    if (self.mode == CIAppPickerModeReset) {
        [[CIConfigManager shared] setTargetBundles:arr];
    } else {
        [[CIConfigManager shared] setRrsBundles:arr];
    }
    [[CIConfigManager shared] save];
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if (text.length == 0) { _view = _all; }
    else {
        NSMutableArray *m = [NSMutableArray array];
        for (CIAppInfo *a in _all) {
            if ([a.name localizedCaseInsensitiveContainsString:text] ||
                [a.bundleID localizedCaseInsensitiveContainsString:text]) [m addObject:a];
        }
        _view = m;
    }
    [_table reloadData];
    [self updateSummary];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _view.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    // Card-style row: a rounded inner panel that hugs the screen edges with
    // 12pt margin so successive cells look like stacked cards. Layout:
    //   ┌───────────────────────────────────────────┐
    //   │ [icon]  Name (bold)              [○ / ●] │   ○ = empty, ● = orange
    //   │         bundle.id  •  size MB             │
    //   └───────────────────────────────────────────┘
    static NSString *cid = @"appCard";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.backgroundColor = [UIColor clearColor];
        c.contentView.backgroundColor = [UIColor clearColor];
    }
    for (UIView *v in c.contentView.subviews) [v removeFromSuperview];

    CIAppInfo *a = _view[ip.row];
    BOOL selected = [_selected containsObject:a.bundleID];

    CGFloat W = tv.bounds.size.width;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(12, 4, W - 24, 68)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.backgroundColor = [CITheme card];
    card.layer.cornerRadius = 12;
    card.layer.borderWidth = 1;
    card.layer.borderColor = (selected ? [CITheme orange]
                                        : [[UIColor whiteColor] colorWithAlphaComponent:0.06]).CGColor;
    [c.contentView addSubview:card];

    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(10, 10, 48, 48)];
    iv.image = a.icon;
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.layer.cornerRadius = 12;
    iv.layer.masksToBounds = YES;
    iv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    [card addSubview:iv];

    UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(70, 12, card.bounds.size.width - 70 - 50, 22)];
    name.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    name.text = a.name;
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    name.textColor = [CITheme text];
    [card addSubview:name];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(70, 36, card.bounds.size.width - 70 - 50, 18)];
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    if (a.containerSize > 1) {
        sub.text = [NSString stringWithFormat:@"%@  •  %@", a.bundleID, CIBytesString(a.containerSize)];
    } else {
        sub.text = a.bundleID;
    }
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [CITheme dim];
    sub.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [card addSubview:sub];

    // Custom check pill — empty circle when off, filled orange ring with
    // ✓ when on. Stays right-aligned via FlexibleLeftMargin.
    UIView *check = [[UIView alloc] initWithFrame:CGRectMake(card.bounds.size.width - 38, 22, 24, 24)];
    check.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    check.layer.cornerRadius = 12;
    check.layer.borderWidth = selected ? 0 : 1.5;
    check.layer.borderColor = [CITheme dim].CGColor;
    check.backgroundColor = selected ? [CITheme orange] : [UIColor clearColor];
    [card addSubview:check];

    if (selected) {
        UILabel *tick = [[UILabel alloc] initWithFrame:check.bounds];
        tick.text = @"✓";
        tick.textColor = [UIColor whiteColor];
        tick.textAlignment = NSTextAlignmentCenter;
        tick.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
        [check addSubview:tick];
    }

    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:NO];
    CIAppInfo *a = _view[ip.row];
    if ([_selected containsObject:a.bundleID]) [_selected removeObject:a.bundleID];
    else [_selected addObject:a.bundleID];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [self updateSummary];
}

- (void)tableView:(UITableView *)tv willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.row >= (NSInteger)_view.count) return;
    CIAppInfo *a = _view[ip.row];
    __weak typeof(self) weakSelf = self;

    // Lazy icon
    if (!a.icon) {
        NSString *bid = a.bundleID;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIImage *img = [CIAppLister iconForBundle:bid size:60];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!img) return;
                a.icon = img;
                __strong typeof(weakSelf) strong = weakSelf;
                if (!strong) return;
                NSInteger idx = [strong->_view indexOfObject:a];
                if (idx == NSNotFound) return;
                NSIndexPath *cur = [NSIndexPath indexPathForRow:idx inSection:0];
                if ([[strong->_table indexPathsForVisibleRows] containsObject:cur])
                    [strong->_table reloadRowsAtIndexPaths:@[cur] withRowAnimation:UITableViewRowAnimationNone];
            });
        });
    }

    // Lazy size
    if (a.containerSize == 0 && a.containerPath.length > 0) {
        a.containerSize = 1; // in-flight sentinel
        NSString *path = a.containerPath;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            unsigned long long s = [CIAppLister sizeOfPath:path];
            dispatch_async(dispatch_get_main_queue(), ^{
                a.containerSize = (s > 1 ? s : 1);
                __strong typeof(weakSelf) strong = weakSelf;
                if (!strong) return;
                NSInteger idx = [strong->_view indexOfObject:a];
                if (idx == NSNotFound) return;
                NSIndexPath *cur = [NSIndexPath indexPathForRow:idx inSection:0];
                if ([[strong->_table indexPathsForVisibleRows] containsObject:cur])
                    [strong->_table reloadRowsAtIndexPaths:@[cur] withRowAnimation:UITableViewRowAnimationNone];
            });
        });
    }
}
@end

// ============================================================
// FAKE SETTINGS (all 22 layers + key fields)
// ============================================================

typedef NS_ENUM(NSInteger, CIRowKind) {
    CIRowHeader = 0,     // big header text only
    CIRowToggle,         // toggle bound to layer (fake_<layer>) or bool key
    CIRowText,           // text field bound to string key
    CIRowChoose,         // disclosure button with dropdown list
    CIRowPicker,         // radio group (options in list)
    CIRowNote,           // italic note text
    CIRowRange,          // dual-slider; randomize picks within [minIdx, maxIdx]
};

@interface CIRow : NSObject
@property (nonatomic, assign) CIRowKind kind;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *key;        // config key
@property (nonatomic, copy)   NSArray  *options;    // for choose/picker
@property (nonatomic, copy)   NSString *placeholder;
@property (nonatomic, assign) CGFloat  leftPad;     // indentation level (sub-rows)
// CIRowRange — `options` holds the ordered list of display labels;
// `key` is the config storage key (we store @{minIdx,maxIdx} as a 2-int array).
@property (nonatomic, copy)   NSString *minStorageKey;
@property (nonatomic, copy)   NSString *maxStorageKey;
@end
@implementation CIRow @end

@interface CIFakeSettingsViewController : UITableViewController <UITextFieldDelegate, UIPickerViewDataSource, UIPickerViewDelegate>
@end

@implementation CIFakeSettingsViewController {
    NSMutableArray<CIRow *> *_rows;
    NSMutableSet<NSString *> *_expandedRangeKeys;
}

+ (CIRow *)toggle:(NSString *)title key:(NSString *)key indent:(CGFloat)pad {
    CIRow *r = [CIRow new]; r.kind = CIRowToggle; r.title = title; r.key = key; r.leftPad = pad; return r;
}
+ (CIRow *)text:(NSString *)title key:(NSString *)key placeholder:(NSString *)ph indent:(CGFloat)pad {
    CIRow *r = [CIRow new]; r.kind = CIRowText; r.title = title; r.key = key; r.placeholder = ph; r.leftPad = pad; return r;
}
+ (CIRow *)header:(NSString *)title {
    CIRow *r = [CIRow new]; r.kind = CIRowHeader; r.title = title; return r;
}
+ (CIRow *)note:(NSString *)text indent:(CGFloat)pad {
    CIRow *r = [CIRow new]; r.kind = CIRowNote; r.title = text; r.leftPad = pad; return r;
}
+ (CIRow *)choose:(NSString *)title key:(NSString *)key indent:(CGFloat)pad {
    CIRow *r = [CIRow new]; r.kind = CIRowChoose; r.title = title; r.key = key; r.leftPad = pad; return r;
}
// labels[] is the ordered list of items the user can sweep across. minKey/maxKey
// store the chosen indices in CIConfigManager. Randomize functions read those
// keys at fire time and pick uniformly in [minIdx, maxIdx].
+ (CIRow *)range:(NSString *)title labels:(NSArray<NSString *> *)labels minKey:(NSString *)minKey maxKey:(NSString *)maxKey {
    CIRow *r = [CIRow new]; r.kind = CIRowRange; r.title = title;
    r.options = labels; r.minStorageKey = minKey; r.maxStorageKey = maxKey;
    return r;
}

// Shared preset data — the table-of-truth lives in the static C function
// ci_randomPresets() (defined earlier in this file). The class method here
// just proxies, so the range slider's labels and the Reset randomizer pick
// from the exact same array — keeping indices aligned.
+ (NSArray *)devicePresets { return ci_randomPresets(); }
+ (NSArray *)iosPresets { return ci_randomIOSPresets(); }

// Legacy in-class arrays, retained as a fallback if the C function returns
// nil for any reason (it shouldn't — both arrays are static dispatch_once'd).
// Columns: name, productType, machine, width, height, scale, nativeW, nativeH, nativeScale
+ (NSArray *)devicePresetsLegacy {
    static NSArray *presets = nil;
    if (!presets) {
        presets = @[
            @[@"iPhone 5",          @"iPhone5,2",  @"iPhone5,2",  @"320", @"568", @"2", @"640",  @"1136", @"2"],
            @[@"iPhone 5s",         @"iPhone6,1",  @"iPhone6,1",  @"320", @"568", @"2", @"640",  @"1136", @"2"],
            @[@"iPhone SE (1)",     @"iPhone8,4",  @"iPhone8,4",  @"320", @"568", @"2", @"640",  @"1136", @"2"],
            @[@"iPhone 6",          @"iPhone7,2",  @"iPhone7,2",  @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 6 Plus",     @"iPhone7,1",  @"iPhone7,1",  @"414", @"736", @"3", @"1242", @"2208", @"3"],
            @[@"iPhone 6s",         @"iPhone8,1",  @"iPhone8,1",  @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 6s Plus",    @"iPhone8,2",  @"iPhone8,2",  @"414", @"736", @"3", @"1242", @"2208", @"3"],
            @[@"iPhone 7",          @"iPhone9,1",  @"iPhone9,1",  @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 7 Plus",     @"iPhone9,2",  @"iPhone9,2",  @"414", @"736", @"3", @"1242", @"2208", @"3"],
            @[@"iPhone 8",          @"iPhone10,1", @"iPhone10,1", @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 8 Plus",     @"iPhone10,2", @"iPhone10,2", @"414", @"736", @"3", @"1242", @"2208", @"3"],
            @[@"iPhone X",          @"iPhone10,3", @"iPhone10,3", @"375", @"812", @"3", @"1125", @"2436", @"3"],
            @[@"iPhone XR",         @"iPhone11,8", @"iPhone11,8", @"414", @"896", @"2", @"828",  @"1792", @"2"],
            @[@"iPhone XS",         @"iPhone11,2", @"iPhone11,2", @"375", @"812", @"3", @"1125", @"2436", @"3"],
            @[@"iPhone XS Max",     @"iPhone11,6", @"iPhone11,6", @"414", @"896", @"3", @"1242", @"2688", @"3"],
            @[@"iPhone SE (2)",     @"iPhone12,8", @"iPhone12,8", @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 11",         @"iPhone12,1", @"iPhone12,1", @"414", @"896", @"2", @"828",  @"1792", @"2"],
            @[@"iPhone 11 Pro",     @"iPhone12,3", @"iPhone12,3", @"375", @"812", @"3", @"1125", @"2436", @"3"],
            @[@"iPhone 11 Pro Max", @"iPhone12,5", @"iPhone12,5", @"414", @"896", @"3", @"1242", @"2688", @"3"],
            @[@"iPhone 12 mini",    @"iPhone13,1", @"iPhone13,1", @"375", @"812", @"3", @"1080", @"2340", @"3"],
            @[@"iPhone 12",         @"iPhone13,2", @"iPhone13,2", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 12 Pro",     @"iPhone13,3", @"iPhone13,3", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 12 Pro Max", @"iPhone13,4", @"iPhone13,4", @"428", @"926", @"3", @"1284", @"2778", @"3"],
            @[@"iPhone 13 mini",    @"iPhone14,4", @"iPhone14,4", @"375", @"812", @"3", @"1080", @"2340", @"3"],
            @[@"iPhone 13",         @"iPhone14,5", @"iPhone14,5", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 13 Pro",     @"iPhone14,2", @"iPhone14,2", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 13 Pro Max", @"iPhone14,3", @"iPhone14,3", @"428", @"926", @"3", @"1284", @"2778", @"3"],
            @[@"iPhone SE (3)",     @"iPhone14,6", @"iPhone14,6", @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 14",         @"iPhone14,7", @"iPhone14,7", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 14 Plus",    @"iPhone14,8", @"iPhone14,8", @"428", @"926", @"3", @"1284", @"2778", @"3"],
            @[@"iPhone 14 Pro",     @"iPhone15,2", @"iPhone15,2", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 14 Pro Max", @"iPhone15,3", @"iPhone15,3", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 15",         @"iPhone15,4", @"iPhone15,4", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 15 Plus",    @"iPhone15,5", @"iPhone15,5", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 15 Pro",     @"iPhone16,1", @"iPhone16,1", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 15 Pro Max", @"iPhone16,2", @"iPhone16,2", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 16",         @"iPhone17,3", @"iPhone17,3", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 16 Plus",    @"iPhone17,4", @"iPhone17,4", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 16 Pro",     @"iPhone17,1", @"iPhone17,1", @"402", @"874", @"3", @"1206", @"2622", @"3"],
            @[@"iPhone 16 Pro Max", @"iPhone17,2", @"iPhone17,2", @"440", @"956", @"3", @"1320", @"2868", @"3"],
        ];
    }
    return presets;
}

// iOS version presets — name, systemVersion, BuildVersion
+ (NSArray *)iosPresetsLegacy {
    static NSArray *v = nil;
    if (!v) {
        v = @[
            @[@"iOS 12.5.7", @"12.5.7",  @"16H81"],
            @[@"iOS 13.7",   @"13.7",    @"17H35"],
            @[@"iOS 14.8.1", @"14.8.1",  @"18H107"],
            @[@"iOS 15.8.3", @"15.8.3",  @"19H390"],
            @[@"iOS 16.7.10",@"16.7.10", @"20H350"],
            @[@"iOS 17.4.1", @"17.4.1",  @"21E236"],
            @[@"iOS 17.5.1", @"17.5.1",  @"21F90"],
            @[@"iOS 17.6.1", @"17.6.1",  @"21G93"],
            @[@"iOS 17.7.2", @"17.7.2",  @"21H221"],
            @[@"iOS 18.0.1", @"18.0.1",  @"22A3370"],
            @[@"iOS 18.1.1", @"18.1.1",  @"22B91"],
            @[@"iOS 18.2",   @"18.2",    @"22C152"],
            @[@"iOS 18.3.2", @"18.3.2",  @"22D82"],
        ];
    }
    return v;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Fake Settings";
    self.view.backgroundColor = [CITheme bg];
    self.tableView.backgroundColor = [CITheme bg];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    _expandedRangeKeys = [NSMutableSet set];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self buildRows];
    // Single compact menu on the right — avoids overflow on narrow screens.
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(done)];
    UIBarButtonItem *menu = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] ?: nil
                style:UIBarButtonItemStylePlain target:self action:@selector(showMenu)];
    self.navigationItem.rightBarButtonItems = @[self.navigationItem.rightBarButtonItem, menu];
}

- (void)showMenu {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"Chọn Model iPhone" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) { [self showPresets]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Chọn iOS Version" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) { [self showIOSPresets]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Bật/tắt toàn bộ Fake" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) { [self toggleAllFakes]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)done { [[CIConfigManager shared] save]; [self.navigationController popViewControllerAnimated:YES]; }

- (void)toggleAllFakes {
    // Count current fake_* that are on
    NSMutableArray *fakeKeys = [NSMutableArray array];
    for (CIRow *r in _rows) {
        if (r.kind == CIRowToggle && [r.key hasPrefix:@"fake_"]) [fakeKeys addObject:r.key];
    }
    NSInteger onCount = 0;
    for (NSString *k in fakeKeys) if ([[CIConfigManager shared] boolForKey:k]) onCount++;
    BOOL turnOn = onCount < (NSInteger)fakeKeys.count; // toggle
    for (NSString *k in fakeKeys) [[CIConfigManager shared] setObject:@(turnOn) forKey:k];
    [[CIConfigManager shared] save];
    [self.tableView reloadData];
}

- (void)showPresets {
    NSArray *presets = [CIFakeSettingsViewController devicePresets];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Chọn Model iPhone"
        message:@"iPhone 5 → iPhone 16 Pro Max" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *p in presets) {
        [ac addAction:[UIAlertAction actionWithTitle:p[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [self applyPreset:p];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, 0, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)showIOSPresets {
    NSArray *presets = [CIFakeSettingsViewController iosPresets];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Chọn iOS Version"
        message:@"iOS 12 → iOS 18" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *p in presets) {
        [ac addAction:[UIAlertAction actionWithTitle:p[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
            [self applyIOSPreset:p];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    ac.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, 0, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)applyPreset:(NSArray *)p {
    // p = [name, productType, machine, w, h, scale, nativeW, nativeH, nativeScale]
    CIConfigManager *cm = [CIConfigManager shared];
    [cm setObject:p[0] forKey:@"deviceModel"];     // full consumer name e.g. "iPhone 15 Pro Max"
    [cm setObject:p[0] forKey:@"localizedModel"];  // same for UIDevice.localizedModel hook
    [cm setObject:p[1] forKey:@"ProductType"];     // internal identifier e.g. "iPhone15,2"
    [cm setObject:p[2] forKey:@"hw_machine"];
    [cm setObject:p[2] forKey:@"HardwareModel"];   // MGCopyAnswer HWModelStr reads this key
    [cm setObject:p[2] forKey:@"uname_machine"];
    [cm setObject:@"iPhone" forKey:@"systemName"];  // UIDevice.systemName hook
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", p[0]] forKey:@"deviceName"];
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", p[0]] forKey:@"DeviceName"];
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", p[0]] forKey:@"DeviceNameMG"];
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", p[0]] forKey:@"UserAssignedDeviceName"];
    [cm setObject:p[0] forKey:@"MarketingName"];
    [cm setObject:p[3] forKey:@"screenWidth"];
    [cm setObject:p[4] forKey:@"screenHeight"];
    [cm setObject:p[5] forKey:@"screenScale"];
    if (p.count >= 9) {
        [cm setObject:p[6] forKey:@"nativeScreenWidth"];
        [cm setObject:p[7] forKey:@"nativeScreenHeight"];
        [cm setObject:p[8] forKey:@"nativeScale"];
    }
    [cm setObject:p[0] forKey:@"__presetModelName"];
    [cm setObject:@(YES) forKey:@"fake_uiddevice"];
    [cm setObject:@(YES) forKey:@"fake_screen"];
    [cm save];
    [self.tableView reloadData];
}

- (void)applyIOSPreset:(NSArray *)p {
    // p = [name, systemVersion, BuildVersion]
    CIConfigManager *cm = [CIConfigManager shared];
    [cm setObject:p[1] forKey:@"systemVersion"];
    [cm setObject:p[2] forKey:@"BuildVersion"];
    [cm setObject:p[0] forKey:@"__presetIOSName"];
    [cm setObject:@(YES) forKey:@"fake_sysosversion"];
    [cm save];
    [self.tableView reloadData];
}

- (void)buildRows {
    Class C = [CIFakeSettingsViewController class];
    _rows = [NSMutableArray array];

    // === Random Range — picker wheels for device + iOS ===
    // Reset Data picks 1 device and 1 iOS uniformly at random from the [min,
    // max] window the user dialed in via the wheel.
    // Picker labels — devices show "<idx> <name>" (matches mainstream tools'
    // wheel format), iOS shows the bare version number ("14.5", "17.5.1").
    NSMutableArray *deviceLabels = [NSMutableArray array];
    NSArray *_devs = [CIFakeSettingsViewController devicePresets];
    for (NSUInteger i = 0; i < _devs.count; i++) {
        [deviceLabels addObject:[NSString stringWithFormat:@"%lu %@", (unsigned long)i, ((NSArray *)_devs[i])[0]]];
    }
    NSMutableArray *iosLabels = [NSMutableArray array];
    NSArray *_ioss = [CIFakeSettingsViewController iosPresets];
    for (NSArray *p in _ioss) [iosLabels addObject:p[1]];

    [_rows addObject:[C toggle:@"1. Fake iOS Version" key:@"fake_sysosversion" indent:0]];
    [_rows addObject:[C range:@"" labels:iosLabels minKey:@"__iosMinIdx" maxKey:@"__iosMaxIdx"]];

    [_rows addObject:[C toggle:@"2. Fake Model" key:@"fake_uiddevice" indent:0]];
    [_rows addObject:[C range:@"" labels:deviceLabels minKey:@"__deviceMinIdx" maxKey:@"__deviceMaxIdx"]];
    [_rows addObject:[C toggle:@"2.1 Fake Screen Size" key:@"fake_screen" indent:24]];
    [_rows addObject:[C toggle:@"2.2 Fake Full Screen" key:@"fake_realscreen" indent:24]];

    // 3. Fake Name — kept editable since the user often wants a custom one.
    [_rows addObject:[C toggle:@"3. Fake Name" key:@"fake_processinfo" indent:0]];
    [_rows addObject:[C text:@"deviceName" key:@"deviceName" placeholder:@"iPhone" indent:24]];

    // 4. Check IP + location
    [_rows addObject:[C header:@"4. Check IP Address"]];
    [_rows addObject:[C note:@"Chọn server: ip-api.com" indent:24]];
    [_rows addObject:[C toggle:@"4.1 Fake GPS Location" key:@"fake_location" indent:24]];
    [_rows addObject:[C text:@"Latitude"  key:@"latitude"  placeholder:@"(null)" indent:48]];
    [_rows addObject:[C text:@"Longitude" key:@"longitude" placeholder:@"(null)" indent:48]];
    [_rows addObject:[C text:@"Altitude"  key:@"altitude"  placeholder:@"0" indent:48]];
    [_rows addObject:[C toggle:@"4.2 Đổi TimeZone" key:@"fake_datetime" indent:24]];
    [_rows addObject:[C text:@"timezoneName" key:@"timezoneName" placeholder:@"America/Los_Angeles" indent:48]];
    [_rows addObject:[C toggle:@"4.3 Đổi Locale" key:@"fake_locale" indent:24]];
    [_rows addObject:[C text:@"localeIdentifier"    key:@"localeIdentifier"    placeholder:@"en_US" indent:48]];
    [_rows addObject:[C text:@"localeCountryCode"   key:@"localeCountryCode"   placeholder:@"US" indent:48]];
    [_rows addObject:[C text:@"localeCurrencyCode"  key:@"localeCurrencyCode"  placeholder:@"USD" indent:48]];
    [_rows addObject:[C toggle:@"4.4 Đổi Language" key:@"fake_locale2" indent:24]];
    [_rows addObject:[C text:@"localeLanguageCode"  key:@"localeLanguageCode"  placeholder:@"en" indent:48]];

    // 5. Fake Carrier
    [_rows addObject:[C toggle:@"5. Fake Carrier" key:@"fake_network" indent:0]];
    [_rows addObject:[C text:@"carrierName" key:@"carrierName" placeholder:@"T-Mobile" indent:24]];
    [_rows addObject:[C text:@"carrierMCC"  key:@"carrierMCC"  placeholder:@"310" indent:24]];
    [_rows addObject:[C text:@"carrierMNC"  key:@"carrierMNC"  placeholder:@"260" indent:24]];
    [_rows addObject:[C text:@"carrierISO"  key:@"carrierISO"  placeholder:@"us" indent:24]];
    [_rows addObject:[C text:@"carrierRadioAccess" key:@"carrierRadioAccess" placeholder:@"CTRadioAccessTechnologyLTE" indent:24]];
    [_rows addObject:[C text:@"Phone Number" key:@"PhoneNumber" placeholder:@"" indent:24]];

    // 6. Serial
    [_rows addObject:[C toggle:@"6. Fake & random serial" key:@"fake_hardware" indent:0]];
    [_rows addObject:[C note:@"Thay đổi Serial sẽ yêu cầu login lại App Store khi reset data." indent:24]];
    [_rows addObject:[C text:@"Serial (16 ký tự)" key:@"serialNumber" placeholder:@"F2LX...." indent:24]];

    // 7. Sensors
    [_rows addObject:[C toggle:@"7. Fake sensors (rung, gia tốc)" key:@"fake_sensor" indent:0]];

    // 8. Advertising
    [_rows addObject:[C toggle:@"8. Fake IDFA" key:@"fake_ads" indent:0]];
    [_rows addObject:[C text:@"IDFA" key:@"advertisingIdentifier" placeholder:@"00000000-0000-0000-0000-000000000000" indent:24]];

    // 9. WiFi
    [_rows addObject:[C toggle:@"9. Fake WiFi" key:@"fake_wifi" indent:0]];
    [_rows addObject:[C text:@"SSID"  key:@"wifiSSID"  placeholder:@"HomeWiFi" indent:24]];
    [_rows addObject:[C text:@"BSSID" key:@"wifiBSSID" placeholder:@"aa:bb:cc:dd:ee:ff" indent:24]];

    // 10. Tracking / pasteboard
    [_rows addObject:[C toggle:@"10. Clear pasteboard / tracking defaults" key:@"fake_tracking_pasteboard" indent:0]];
    [_rows addObject:[C toggle:@"    Also clear tracking defaults" key:@"fake_trackingdefaults" indent:24]];

    // 11. IdentifierForVendor
    [_rows addObject:[C toggle:@"11. Fake IDFV" key:@"fake_uiddevice2" indent:0]];
    [_rows addObject:[C text:@"identifierForVendor (UUID)" key:@"identifierForVendor" placeholder:@"UUID" indent:24]];

    // 12. Memory / CPU
    [_rows addObject:[C toggle:@"12. Fake hardware specs (cpu, mem)" key:@"fake_sysctl" indent:0]];
    [_rows addObject:[C text:@"physicalMemory (bytes)" key:@"physicalMemory" placeholder:@"8589934592" indent:24]];
    [_rows addObject:[C text:@"processorCount" key:@"processorCount" placeholder:@"6" indent:24]];
    [_rows addObject:[C text:@"hw.cputype" key:@"hw_cputype" placeholder:@"16777228" indent:24]];
    [_rows addObject:[C text:@"hw.cpusubtype" key:@"hw_cpusubtype" placeholder:@"2" indent:24]];
    [_rows addObject:[C text:@"hw.cpufrequency" key:@"hw_cpufrequency" placeholder:@"3480000000" indent:24]];
    [_rows addObject:[C text:@"hw.physicalcpu" key:@"hw_physicalcpu" placeholder:@"6" indent:24]];
    [_rows addObject:[C text:@"hw.logicalcpu_max" key:@"hw_logicalcpu_max" placeholder:@"6" indent:24]];

    // 13. Battery
    [_rows addObject:[C toggle:@"13. Fake battery" key:@"fake_battery" indent:0]];
    [_rows addObject:[C text:@"batteryLevel (0.0-1.0)" key:@"batteryLevel" placeholder:@"1.0" indent:24]];
    [_rows addObject:[C text:@"batteryState (0-3)" key:@"batteryState" placeholder:@"1" indent:24]];

    // 14. Browser / WebKit fingerprint
    [_rows addObject:[C toggle:@"14. Fake WebKit fingerprint" key:@"fake_browser" indent:0]];
    [_rows addObject:[C text:@"WebGL Vendor" key:@"web_glVendor" placeholder:@"Apple Inc." indent:24]];
    [_rows addObject:[C text:@"WebGL Renderer" key:@"web_glRenderer" placeholder:@"Apple GPU" indent:24]];
    [_rows addObject:[C toggle:@"    Canvas noise" key:@"web_canvasNoise" indent:24]];

    // 15. Metal
    [_rows addObject:[C toggle:@"15. Fake Metal GPU" key:@"fake_metal" indent:0]];
    [_rows addObject:[C text:@"GPU name" key:@"zalo_metalGPU" placeholder:@"Apple A17 Pro GPU" indent:24]];

    // 16. WebRTC
    [_rows addObject:[C toggle:@"16. Fake WebRTC (block local IP leak)" key:@"fake_webrtc" indent:0]];

    // 17. Timing
    [_rows addObject:[C toggle:@"17. Fake timing offset" key:@"fake_timing" indent:0]];
    [_rows addObject:[C text:@"Offset (seconds)" key:@"zalo_timingOffset" placeholder:@"0" indent:24]];

    // 18. Keychain
    [_rows addObject:[C toggle:@"18. Reset keychain on launch" key:@"fake_keychain" indent:0]];
    [_rows addObject:[C toggle:@"    Clear keychain every time" key:@"keychainReset" indent:24]];

    // 19. JB Hide
    [_rows addObject:[C toggle:@"19. Hide Jailbreak" key:@"fake_jbhide" indent:0]];
    [_rows addObject:[C toggle:@"    hideJailbreak runtime" key:@"hideJailbreak" indent:24]];

    // 20. Uptime
    [_rows addObject:[C toggle:@"20. Fake system uptime" key:@"fake_uptime" indent:0]];
    [_rows addObject:[C text:@"systemUptime (seconds)" key:@"systemUptime" placeholder:@"3600" indent:24]];

    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    CIRow *r = _rows[ip.row];
    static NSString *cid = @"row";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    for (UIView *v in c.contentView.subviews) [v removeFromSuperview];
    c.textLabel.text = nil;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.backgroundColor = [CITheme bg];

    CGFloat W = tv.bounds.size.width;
    UIEdgeInsets ins = tv.safeAreaInsets;
    CGFloat rightEdge = W - MAX(12.0, ins.right + 4.0);
    CGFloat pad = MAX(12 + r.leftPad, ins.left + 12);

    if (r.kind == CIRowHeader) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 12, rightEdge-pad, 28)];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        l.text = r.title; l.font = [CITheme h2]; l.textColor = [CITheme blue];
        [c.contentView addSubview:l];
        return c;
    }
    if (r.kind == CIRowNote) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 4, rightEdge-pad, 36)];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        l.text = r.title; l.font = [UIFont italicSystemFontOfSize:13]; l.textColor = [CITheme orange];
        l.numberOfLines = 0;
        [c.contentView addSubview:l];
        return c;
    }
    if (r.kind == CIRowToggle) {
        CGFloat swW = 51, swRight = 9;
        CGFloat swX = rightEdge - swW - swRight;
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 10, swX - pad - 8, 32)];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        l.text = r.title; l.font = [CITheme body]; l.textColor = [CITheme blue];
        l.numberOfLines = 0; l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.75;
        [c.contentView addSubview:l];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.frame = CGRectMake(swX, 8, swW, 31);
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        sw.onTintColor = [CITheme blue];
        NSString *cfgKey = [r.key hasPrefix:@"fake_"] ? [@"fake_" stringByAppendingString:[r.key substringFromIndex:5]] : r.key;
        sw.on = [[CIConfigManager shared] boolForKey:cfgKey];
        objc_setAssociatedObject(sw, @"ciKey", cfgKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        [c.contentView addSubview:sw];
        return c;
    }
    if (r.kind == CIRowChoose) {
        // Pill-style button row — title left, current value + chevron right
        UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(pad, 6, rightEdge - pad, 50)];
        pill.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        pill.backgroundColor = [CITheme card];
        pill.layer.cornerRadius = 12;
        pill.layer.borderColor = [[CITheme orange] colorWithAlphaComponent:0.6].CGColor;
        pill.layer.borderWidth = 1.2;
        [c.contentView addSubview:pill];

        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, pill.bounds.size.width - 24, 22)];
        t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        t.text = r.title; t.font = [CITheme body]; t.textColor = [CITheme orange];
        [pill addSubview:t];

        NSString *cur = [[CIConfigManager shared] stringForKey:r.key];
        UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(12, 24, pill.bounds.size.width - 44, 22)];
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        v.text = cur.length ? cur : @"— chạm để chọn —";
        v.font = [CITheme small]; v.textColor = cur.length ? [CITheme text] : [CITheme dim];
        [pill addSubview:v];

        UILabel *chev = [[UILabel alloc] initWithFrame:CGRectMake(pill.bounds.size.width - 28, 12, 20, 24)];
        chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        chev.text = @"›"; chev.textColor = [CITheme dim]; chev.textAlignment = NSTextAlignmentCenter;
        chev.font = [UIFont boldSystemFontOfSize:22];
        [pill addSubview:chev];

        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }
    if (r.kind == CIRowText) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 6, rightEdge-pad, 18)];
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        l.text = r.title; l.font = [CITheme small]; l.textColor = [CITheme dim];
        [c.contentView addSubview:l];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(pad, 26, rightEdge-pad, 34)];
        tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        tf.attributedPlaceholder = [[NSAttributedString alloc]
            initWithString:(r.placeholder ?: @"")
            attributes:@{NSForegroundColorAttributeName: [[CITheme dim] colorWithAlphaComponent:0.85]}];
        tf.font = [CITheme body]; tf.textColor = [CITheme text];
        tf.borderStyle = UITextBorderStyleNone;
        tf.backgroundColor = [CITheme card];
        tf.layer.cornerRadius = 8;
        tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0,0,8,0)];
        tf.leftViewMode = UITextFieldViewModeAlways;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.text = [[CIConfigManager shared] stringForKey:r.key];
        tf.delegate = self;
        objc_setAssociatedObject(tf, @"ciKey", r.key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [c.contentView addSubview:tf];
        return c;
    }
    if (r.kind == CIRowRange) {
        // Collapsed by default — pill shows "Từ X đến Y" summary; tapping the
        // pill expands a 2-component UIPickerView underneath. Tapping again
        // collapses. State lives in _expandedRangeKeys keyed by minStorageKey.
        NSInteger maxI = (NSInteger)r.options.count - 1;
        if (maxI < 0) return c;
        CIConfigManager *cm = [CIConfigManager shared];
        id loStored = [cm objectForKey:r.minStorageKey];
        id hiStored = [cm objectForKey:r.maxStorageKey];
        NSInteger lo = loStored ? [loStored integerValue] : 0;
        NSInteger hi = hiStored ? [hiStored integerValue] : maxI;
        lo = MAX(0, MIN(maxI, lo));
        hi = MAX(0, MIN(maxI, hi));
        if (lo > hi) { NSInteger t = lo; lo = hi; hi = t; }

        BOOL expanded = [_expandedRangeKeys containsObject:r.minStorageKey];

        CGFloat pillY = 8;
        if (r.title.length > 0) {
            UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(pad, 6, rightEdge-pad, 22)];
            title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            title.text = r.title; title.font = [CITheme body]; title.textColor = [CITheme blue];
            [c.contentView addSubview:title];
            pillY = 32;
        }

        // Tappable pill — UIControl so we can hook UIControlEventTouchUpInside
        // and animate the row expansion. A trailing chevron rotates when open.
        UIControl *pill = [[UIControl alloc] initWithFrame:CGRectMake(pad, pillY, rightEdge - pad, 40)];
        pill.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        pill.backgroundColor = [CITheme card];
        pill.layer.cornerRadius = 10;
        pill.layer.borderColor = [[CITheme orange] colorWithAlphaComponent:0.6].CGColor;
        pill.layer.borderWidth = 1.0;
        objc_setAssociatedObject(pill, @"ciRangeMinKey", r.minStorageKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [pill addTarget:self action:@selector(toggleRangePill:) forControlEvents:UIControlEventTouchUpInside];
        [c.contentView addSubview:pill];

        UILabel *summary = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, pill.bounds.size.width - 44, 40)];
        summary.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        summary.font = [CITheme body];
        summary.textColor = [UIColor whiteColor];
        summary.textAlignment = NSTextAlignmentCenter;
        summary.text = [NSString stringWithFormat:@"Từ %@ đến %@", r.options[lo], r.options[hi]];
        summary.userInteractionEnabled = NO;
        [pill addSubview:summary];

        UILabel *chev = [[UILabel alloc] initWithFrame:CGRectMake(pill.bounds.size.width - 28, 8, 20, 24)];
        chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        chev.text = expanded ? @"˅" : @"›";
        chev.textColor = [UIColor whiteColor];
        chev.textAlignment = NSTextAlignmentCenter;
        chev.font = [UIFont boldSystemFontOfSize:18];
        chev.userInteractionEnabled = NO;
        [pill addSubview:chev];

        if (expanded) {
            UIPickerView *pv = [[UIPickerView alloc] initWithFrame:CGRectMake(pad, pillY + 48, rightEdge - pad, 162)];
            pv.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            pv.dataSource = self;
            pv.delegate = self;
            objc_setAssociatedObject(pv, @"ciRangeMinKey", r.minStorageKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(pv, @"ciRangeMaxKey", r.maxStorageKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(pv, @"ciRangeOptions", r.options, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(pv, @"ciRangeSummary", summary, OBJC_ASSOCIATION_ASSIGN);
            [pv selectRow:lo inComponent:0 animated:NO];
            [pv selectRow:hi inComponent:1 animated:NO];
            [c.contentView addSubview:pv];
        }

        return c;
    }
    return c;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    CIRow *r = _rows[ip.row];
    if (r.kind == CIRowHeader) return 44;
    if (r.kind == CIRowNote)   return 44;
    if (r.kind == CIRowToggle) return 50;
    if (r.kind == CIRowChoose) return 62;
    if (r.kind == CIRowRange) {
        BOOL expanded = [_expandedRangeKeys containsObject:r.minStorageKey];
        CGFloat headerH = (r.title.length > 0) ? 32 : 0;
        // 8 top + 40 pill + (expanded ? 8 + 162 picker : 0) + 8 bottom
        return headerH + 8 + 40 + (expanded ? (8 + 162) : 0) + 8;
    }
    return 70;
}

// UIPickerView data source / delegate — services every CIRowRange picker.
// The picker carries its own associated objects (min/max storage keys, label
// list, summary label) so we can dispatch without a per-row delegate.
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView { return 2; }

- (NSInteger)pickerView:(UIPickerView *)pv numberOfRowsInComponent:(NSInteger)component {
    NSArray *opts = objc_getAssociatedObject(pv, @"ciRangeOptions");
    return opts ? (NSInteger)opts.count : 0;
}

- (NSString *)pickerView:(UIPickerView *)pv titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    NSArray *opts = objc_getAssociatedObject(pv, @"ciRangeOptions");
    if (row < 0 || (NSUInteger)row >= opts.count) return @"";
    return opts[row];
}

- (CGFloat)pickerView:(UIPickerView *)pv rowHeightForComponent:(NSInteger)component { return 32; }

// Override the default dim system color — UIPickerView default text color
// renders almost-black on our dark background. Returning a custom UILabel
// per row forces clean white text, large enough to read on the wheel.
- (UIView *)pickerView:(UIPickerView *)pv viewForRow:(NSInteger)row forComponent:(NSInteger)component reusingView:(UIView *)reusingView {
    UILabel *l = [reusingView isKindOfClass:[UILabel class]] ? (UILabel *)reusingView : [[UILabel alloc] init];
    NSArray *opts = objc_getAssociatedObject(pv, @"ciRangeOptions");
    l.text = (row >= 0 && (NSUInteger)row < opts.count) ? opts[row] : @"";
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    l.textAlignment = NSTextAlignmentCenter;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    return l;
}

- (void)toggleRangePill:(UIControl *)sender {
    NSString *key = objc_getAssociatedObject(sender, @"ciRangeMinKey");
    if (!key) return;
    if ([_expandedRangeKeys containsObject:key]) [_expandedRangeKeys removeObject:key];
    else [_expandedRangeKeys addObject:key];
    NSInteger rowIdx = -1;
    for (NSUInteger i = 0; i < _rows.count; i++) {
        if ([_rows[i].minStorageKey isEqualToString:key]) { rowIdx = (NSInteger)i; break; }
    }
    if (rowIdx < 0) { [self.tableView reloadData]; return; }
    [self.tableView beginUpdates];
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:rowIdx inSection:0]]
                         withRowAnimation:UITableViewRowAnimationFade];
    [self.tableView endUpdates];
}

- (void)pickerView:(UIPickerView *)pv didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    NSString *minKey = objc_getAssociatedObject(pv, @"ciRangeMinKey");
    NSString *maxKey = objc_getAssociatedObject(pv, @"ciRangeMaxKey");
    NSArray *opts = objc_getAssociatedObject(pv, @"ciRangeOptions");
    UILabel *summary = objc_getAssociatedObject(pv, @"ciRangeSummary");
    if (!minKey || !maxKey || !opts.count) return;

    NSInteger lo = [pv selectedRowInComponent:0];
    NSInteger hi = [pv selectedRowInComponent:1];
    // Clamp: if user pulls min past max (or vice-versa) we drag the other
    // wheel along to keep min ≤ max. The wheel that just moved is the source
    // of truth; the other one snaps to it.
    if (component == 0 && lo > hi) { hi = lo; [pv selectRow:hi inComponent:1 animated:YES]; }
    if (component == 1 && hi < lo) { lo = hi; [pv selectRow:lo inComponent:0 animated:YES]; }

    if (summary) summary.text = [NSString stringWithFormat:@"Từ %@ đến %@", opts[lo], opts[hi]];

    CIConfigManager *cm = [CIConfigManager shared];
    [cm setObject:@(lo) forKey:minKey];
    [cm setObject:@(hi) forKey:maxKey];
    [cm save];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    CIRow *r = _rows[ip.row];
    if (r.kind != CIRowChoose) return;
    if ([r.key isEqualToString:@"__presetModelName"]) [self showPresets];
    else if ([r.key isEqualToString:@"__presetIOSName"]) [self showIOSPresets];
}

- (void)toggleChanged:(UISwitch *)sw {
    NSString *k = objc_getAssociatedObject(sw, @"ciKey");
    if (!k) return;
    [[CIConfigManager shared] setObject:@(sw.on) forKey:k];
    [[CIConfigManager shared] save];
}

- (void)textFieldDidEndEditing:(UITextField *)tf {
    NSString *k = objc_getAssociatedObject(tf, @"ciKey");
    if (!k) return;
    [[CIConfigManager shared] setObject:(tf.text.length ? tf.text : nil) forKey:k];
    [[CIConfigManager shared] save];
}
@end

// ============================================================
// RRS MANAGER VIEW CONTROLLER
// ============================================================
@interface CIRRSManagerViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@end

@implementation CIRRSManagerViewController {
    UITableView *_table;
    UISearchBar *_search;
    NSArray<CIRRSEntry *> *_view;
    NSMutableSet *_selected;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [CITheme bg];
    _selected = [NSMutableSet set];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 54)];

    UIButton *selAll = [UIButton buttonWithType:UIButtonTypeSystem];
    selAll.frame = CGRectMake(8, 12, 32, 32);
    selAll.backgroundColor = [CITheme blue];
    [selAll addTarget:self action:@selector(toggleAll) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:selAll];

    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(48, 8, self.view.bounds.size.width-48-76-16, 38)];
    _search.placeholder = @"Lọc RRS";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.delegate = self;
    _search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [header addSubview:_search];

    UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
    del.frame = CGRectMake(self.view.bounds.size.width-76-8, 8, 76, 38);
    del.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [del setTitle:@"Xóa" forState:UIControlStateNormal];
    [del setTitleColor:[CITheme orange] forState:UIControlStateNormal];
    del.titleLabel.font = [CITheme h2];
    del.layer.borderColor = [CITheme orange].CGColor;
    del.layer.borderWidth = 1.5;
    del.layer.cornerRadius = 4;
    [del addTarget:self action:@selector(deleteSelected) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:del];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.delegate = self; _table.dataSource = self;
    _table.tableHeaderView = header;
    _table.rowHeight = 110;
    _table.backgroundColor = [CITheme bg];
    _table.separatorColor = [CITheme separator];
    [self.view addSubview:_table];

    _view = [[CIRRSStore shared] entries];
    self.title = [NSString stringWithFormat:@"%lu RRS", (unsigned long)_view.count];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self action:@selector(closeBtn)];
}
- (void)closeBtn { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)toggleAll {
    if (_selected.count == _view.count) [_selected removeAllObjects];
    else { [_selected removeAllObjects]; for (CIRRSEntry *e in _view) [_selected addObject:e.uid]; }
    [_table reloadData];
}

- (void)deleteSelected {
    if (_selected.count == 0) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Xoá?" message:[NSString stringWithFormat:@"Xoá %lu RRS?", (unsigned long)_selected.count] preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Xoá" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        NSArray *toDel = [_view filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(CIRRSEntry *e, NSDictionary *_Nullable _) { return [_selected containsObject:e.uid]; }]];
        for (CIRRSEntry *e in toDel) [[CIRRSStore shared] deleteEntry:e];
        [_selected removeAllObjects];
        _view = [[CIRRSStore shared] entries];
        self.title = [NSString stringWithFormat:@"%lu RRS", (unsigned long)_view.count];
        [_table reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if (!text.length) { _view = [[CIRRSStore shared] entries]; [_table reloadData]; return; }
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(CIRRSEntry *e, NSDictionary *_Nullable _) {
        if ([e.idfa localizedCaseInsensitiveContainsString:text]) return YES;
        if ([e.ipReset localizedCaseInsensitiveContainsString:text]) return YES;
        for (NSString *n in e.appNames) if ([n localizedCaseInsensitiveContainsString:text]) return YES;
        return NO;
    }];
    _view = [[[CIRRSStore shared] entries] filteredArrayUsingPredicate:p];
    [_table reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _view.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"rrs";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    for (UIView *v in c.contentView.subviews) [v removeFromSuperview];
    CIRRSEntry *e = _view[ip.row];
    CGFloat W = tv.bounds.size.width;

    UILabel *idx = [[UILabel alloc] initWithFrame:CGRectMake(4, 36, 36, 20)];
    idx.text = [NSString stringWithFormat:@"%ld", (long)(ip.row + 1)];
    idx.textAlignment = NSTextAlignmentCenter;
    [c.contentView addSubview:idx];

    UIView *box1 = [[UIView alloc] initWithFrame:CGRectMake(44, 8, W*0.55, 94)];
    box1.layer.borderColor = [CITheme blue].CGColor; box1.layer.borderWidth = 1; box1.layer.cornerRadius = 6;
    [c.contentView addSubview:box1];
    UILabel *info = [[UILabel alloc] initWithFrame:CGRectMake(6, 4, box1.bounds.size.width-12, 86)];
    info.numberOfLines = 0; info.font = [CITheme small];
    NSString *names = [e.appNames componentsJoinedByString:@"\n"] ?: @"";
    info.text = [NSString stringWithFormat:@"%@\nip reset: %@\n%@",
                 e.idfa ?: @"-", e.ipReset ?: @"-", names];
    [box1 addSubview:info];

    UIView *box2 = [[UIView alloc] initWithFrame:CGRectMake(W*0.60+4, 8, W*0.40-16, 94)];
    box2.layer.borderColor = [CITheme orange].CGColor; box2.layer.borderWidth = 1; box2.layer.cornerRadius = 6;
    box2.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [c.contentView addSubview:box2];
    UILabel *sz = [[UILabel alloc] initWithFrame:CGRectMake(4, 6, box2.bounds.size.width-8, 20)];
    sz.text = CIBytesString(e.totalSize); sz.textColor = [UIColor redColor]; sz.textAlignment = NSTextAlignmentCenter;
    [box2 addSubview:sz];
    UILabel *date = [[UILabel alloc] initWithFrame:CGRectMake(4, 30, box2.bounds.size.width-8, 20)];
    NSDateFormatter *df = [[NSDateFormatter alloc] init]; df.dateFormat = @"dd MMMM yyyy";
    date.text = [df stringFromDate:e.date]; date.textColor = [CITheme blue]; date.textAlignment = NSTextAlignmentCenter;
    [box2 addSubview:date];
    UILabel *tm = [[UILabel alloc] initWithFrame:CGRectMake(4, 54, box2.bounds.size.width-8, 20)];
    df.dateFormat = @"HH:mm:ss"; tm.text = [df stringFromDate:e.date];
    tm.textColor = [CITheme blue]; tm.textAlignment = NSTextAlignmentCenter;
    [box2 addSubview:tm];

    c.accessoryType = [_selected containsObject:e.uid] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    CIRRSEntry *e = _view[ip.row];
    if ([_selected containsObject:e.uid]) [_selected removeObject:e.uid];
    else [_selected addObject:e.uid];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
}
@end

// ============================================================
// SIDE MENU (hamburger)
// ============================================================
@interface CISideMenuViewController : UITableViewController
@end
@implementation CISideMenuViewController {
    NSArray *_items;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    _items = @[@"Login", @"Liên Hệ", @"Add On", @"Cài đặt",
               @"— Clear Temp", @"— ReApp", @"— Check IP",
               @"— Clear RRS", @"— Go Link IDFA", @"— Chỉ lưu RRS"];
    self.view.backgroundColor = [CITheme bg];
    self.tableView.rowHeight = 52;
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, 110)];
    UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(12, 14, 64, 64)];
    iv.image = [UIImage imageNamed:@"AppIcon60x60"];
    iv.layer.cornerRadius = 12; iv.layer.masksToBounds = YES;
    [h addSubview:iv];
    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(86, 22, 200, 30)];
    t.text = @"HIOS Faker"; t.font = [CITheme h1]; t.textColor = [CITheme orange];
    [h addSubview:t];
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(86, 54, 200, 20)];
    sub.text = @"by hieudeptrai04"; sub.font = [UIFont italicSystemFontOfSize:12]; sub.textColor = [CITheme blue];
    [h addSubview:sub];
    self.tableView.tableHeaderView = h;
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _items.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"m";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    c.textLabel.text = _items[ip.row];
    c.textLabel.font = [UIFont systemFontOfSize:17];
    c.textLabel.textColor = [CITheme text];
    c.backgroundColor = [CITheme bg];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *cmd = _items[ip.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:cmd message:@"Chức năng đang phát triển." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

// ============================================================
// FAKE INFO REPORT VIEW CONTROLLER
// ============================================================
// One screen showing every faked field grouped by hook layer with a
// green ✓ / red ✕ glyph and the current spoofed value next to it.
// Driven entirely by [CIConfigManager shared] reads — same source the
// tweak's getConfig() pulls from, so what the user sees here is
// exactly what target apps will see at runtime.
@interface CIFakeReportRow : NSObject
@property (nonatomic, copy)   NSString *label;     // "Serial", "WiFi MAC", …
@property (nonatomic, copy)   NSString *configKey; // key in CIConfigManager
@property (nonatomic, copy)   NSString *value;     // resolved at build time
@property (nonatomic, assign) BOOL      ok;        // green vs red
@end
@implementation CIFakeReportRow @end

@interface CIFakeReportSection : NSObject
@property (nonatomic, copy)  NSString *title;
@property (nonatomic, copy)  NSString *icon;       // emoji prefix
@property (nonatomic, copy)  NSArray<CIFakeReportRow *> *rows;
@end
@implementation CIFakeReportSection @end

@interface CIFakeInfoReportViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@end

@implementation CIFakeInfoReportViewController {
    UITableView *_table;
    NSArray<CIFakeReportSection *> *_sections;
    NSInteger _okCount;
    NSInteger _totalCount;
}

+ (CIFakeReportRow *)row:(NSString *)label key:(NSString *)key {
    CIFakeReportRow *r = [CIFakeReportRow new];
    r.label = label; r.configKey = key;
    NSString *v = [[CIConfigManager shared] stringForKey:key];
    if (v.length == 0) {
        id raw = [[CIConfigManager shared] objectForKey:key];
        if (raw && ![raw isKindOfClass:[NSNull class]]) {
            v = [NSString stringWithFormat:@"%@", raw];
        }
    }
    r.value = v ?: @"(chưa fake)";
    r.ok = (v.length > 0);
    return r;
}

+ (CIFakeReportSection *)section:(NSString *)title icon:(NSString *)icon rows:(NSArray<CIFakeReportRow *> *)rows {
    CIFakeReportSection *s = [CIFakeReportSection new];
    s.title = title; s.icon = icon; s.rows = rows;
    return s;
}

- (void)buildSections {
    Class C = [CIFakeInfoReportViewController class];
    NSMutableArray *all = [NSMutableArray array];

    [all addObject:[C section:@"UIDevice" icon:@"📱" rows:@[
        [C row:@"Marketing Name" key:@"MarketingName"],
        [C row:@"Device Name"    key:@"deviceName"],
        [C row:@"Model"          key:@"deviceModel"],
        [C row:@"Localized Model" key:@"localizedModel"],
        [C row:@"System Name"    key:@"systemName"],
        [C row:@"System Version" key:@"systemVersion"],
        [C row:@"IDFV"           key:@"identifierForVendor"],
    ]]];

    [all addObject:[C section:@"Hardware (MGCopyAnswer)" icon:@"🔩" rows:@[
        [C row:@"Product Type"   key:@"ProductType"],
        [C row:@"Hardware Model" key:@"HardwareModel"],
        [C row:@"Serial Number"  key:@"SerialNumber"],
        [C row:@"UDID"           key:@"UniqueDeviceID"],
        [C row:@"ECID"           key:@"UniqueChipID"],
        [C row:@"IMEI"           key:@"InternationalMobileEquipmentIdentity"],
        [C row:@"IMEI 2"         key:@"InternationalMobileEquipmentIdentity2"],
        [C row:@"ICCID"          key:@"IntegratedCircuitCardIdentity"],
        [C row:@"Region"         key:@"RegionCode"],
        [C row:@"Model Number"   key:@"ModelNumber"],
        [C row:@"Board ID"       key:@"BoardId"],
        [C row:@"Chip ID"        key:@"ChipID"],
        [C row:@"Boot Nonce"     key:@"BootNonce"],
        [C row:@"Firmware"       key:@"FirmwareVersion"],
        [C row:@"Baseband"       key:@"BasebandVersion"],
        [C row:@"Phone Number"   key:@"PhoneNumber"],
    ]]];

    [all addObject:[C section:@"Network MAC" icon:@"📡" rows:@[
        [C row:@"WiFi MAC"       key:@"WiFiAddress"],
        [C row:@"Bluetooth MAC"  key:@"BluetoothAddress"],
        [C row:@"Ethernet MAC"   key:@"EthernetAddress"],
    ]]];

    [all addObject:[C section:@"Carrier" icon:@"📶" rows:@[
        [C row:@"Carrier Name"   key:@"carrierName"],
        [C row:@"MCC"            key:@"carrierMCC"],
        [C row:@"MNC"            key:@"carrierMNC"],
        [C row:@"ISO"            key:@"carrierISO"],
        [C row:@"Radio Tech"     key:@"carrierRadioAccess"],
    ]]];

    [all addObject:[C section:@"WiFi Network" icon:@"🛜" rows:@[
        [C row:@"SSID"           key:@"wifiSSID"],
        [C row:@"BSSID"          key:@"wifiBSSID"],
        [C row:@"Local IP"       key:@"localIP"],
    ]]];

    [all addObject:[C section:@"Screen" icon:@"🖥️" rows:@[
        [C row:@"Width"          key:@"screenWidth"],
        [C row:@"Height"         key:@"screenHeight"],
        [C row:@"Scale"          key:@"screenScale"],
        [C row:@"Native Width"   key:@"nativeScreenWidth"],
        [C row:@"Native Height"  key:@"nativeScreenHeight"],
    ]]];

    [all addObject:[C section:@"Locale & Time" icon:@"🌏" rows:@[
        [C row:@"Locale ID"      key:@"localeIdentifier"],
        [C row:@"Country"        key:@"localeCountryCode"],
        [C row:@"Language"       key:@"localeLanguageCode"],
        [C row:@"Currency"       key:@"localeCurrencyCode"],
        [C row:@"Timezone"       key:@"timezoneName"],
    ]]];

    [all addObject:[C section:@"Disk & Memory" icon:@"💾" rows:@[
        [C row:@"Total Disk"     key:@"TotalDiskCapacity"],
        [C row:@"Free Disk"      key:@"TotalSystemAvailable"],
        [C row:@"RAM"            key:@"physicalMemory"],
        [C row:@"CPU Cores"      key:@"processorCount"],
        [C row:@"hw.machine"     key:@"hw_machine"],
    ]]];

    [all addObject:[C section:@"Advertising / Tracking" icon:@"📢" rows:@[
        [C row:@"IDFA"           key:@"advertisingIdentifier"],
        [C row:@"Tracking Auth"  key:@"trackingAuthorizationStatus"],
    ]]];

    [all addObject:[C section:@"GPS Location" icon:@"📍" rows:@[
        [C row:@"Enabled"        key:@"locationEnabled"],
        [C row:@"Latitude"       key:@"latitude"],
        [C row:@"Longitude"      key:@"longitude"],
        [C row:@"Altitude"       key:@"altitude"],
    ]]];

    [all addObject:[C section:@"Web / GPU Fingerprint" icon:@"🌐" rows:@[
        [C row:@"User-Agent"     key:@"zalo_fakeWebViewUA"],
        [C row:@"GL Vendor"      key:@"web_glVendor"],
        [C row:@"GL Renderer"    key:@"web_glRenderer"],
        [C row:@"Canvas Noise"   key:@"web_canvasNoise"],
        [C row:@"Metal GPU"      key:@"zalo_metalGPU"],
        [C row:@"Timing Offset"  key:@"zalo_timingOffset"],
    ]]];

    [all addObject:[C section:@"Battery" icon:@"🔋" rows:@[
        [C row:@"Battery Level"    key:@"batteryLevel"],
        [C row:@"Battery State"    key:@"batteryState"],
        [C row:@"Battery Capacity" key:@"BatteryCurrentCapacity"],
        [C row:@"Is Charging"      key:@"BatteryIsCharging"],
    ]]];

    [all addObject:[C section:@"Anti-Fraud Layers" icon:@"🛡️" rows:@[
        [C row:@"Hide Jailbreak" key:@"hideJailbreak"],
        [C row:@"Keychain Reset" key:@"keychainReset"],
        [C row:@"Clear Pasteboard" key:@"clearPasteboard"],
    ]]];

    _okCount = 0; _totalCount = 0;
    for (CIFakeReportSection *s in all) {
        for (CIFakeReportRow *r in s.rows) {
            _totalCount++;
            if (r.ok) _okCount++;
        }
    }
    _sections = all;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Thông tin máy fake";
    self.view.backgroundColor = [CITheme bg];

    [self buildSections];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(done)];
    UIBarButtonItem *copyBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"doc.on.doc"] ?: nil
                style:UIBarButtonItemStylePlain target:self action:@selector(copyAll)];
    self.navigationItem.rightBarButtonItem = copyBtn;

    // Summary header — green/red badge.
    CGFloat W = self.view.bounds.size.width;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 80)];
    header.backgroundColor = [CITheme bg];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 12, W - 32, 56)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.backgroundColor = [CITheme card];
    card.layer.cornerRadius = 14;
    card.layer.borderWidth = 1;
    BOOL allOk = (_okCount == _totalCount && _totalCount > 0);
    card.layer.borderColor = (allOk ? [CITheme green] : [CITheme orange]).CGColor;
    [header addSubview:card];

    UILabel *icon = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 36, 56)];
    icon.text = allOk ? @"✓" : @"⚠";
    icon.textColor = allOk ? [CITheme green] : [CITheme orange];
    icon.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    icon.textAlignment = NSTextAlignmentCenter;
    [card addSubview:icon];

    UILabel *line = [[UILabel alloc] initWithFrame:CGRectMake(56, 0, card.bounds.size.width - 64, 56)];
    line.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    line.text = [NSString stringWithFormat:@"Đã fake %ld / %ld trường",
                 (long)_okCount, (long)_totalCount];
    line.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    line.textColor = [CITheme text];
    [card addSubview:line];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.delegate = self;
    _table.dataSource = self;
    _table.tableHeaderView = header;
    _table.backgroundColor = [CITheme bg];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.view addSubview:_table];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)copyAll {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"=== Thông tin máy fake (%ld/%ld) ===\n\n",
        (long)_okCount, (long)_totalCount];
    for (CIFakeReportSection *s in _sections) {
        [out appendFormat:@"%@ %@\n", s.icon, s.title];
        for (CIFakeReportRow *r in s.rows) {
            [out appendFormat:@"  %@ %-22s %@\n", (r.ok ? @"✓" : @"✕"), r.label.UTF8String, r.value];
        }
        [out appendString:@"\n"];
    }
    [UIPasteboard generalPasteboard].string = out;
    UIAlertController *toast = [UIAlertController alertControllerWithTitle:nil message:@"Đã copy" preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:toast animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [toast dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _sections[s].rows.count; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip { return 52; }
- (CGFloat)tableView:(UITableView *)tv heightForHeaderInSection:(NSInteger)s { return 48; }
- (CGFloat)tableView:(UITableView *)tv heightForFooterInSection:(NSInteger)s { return s == (NSInteger)_sections.count - 1 ? 30 : 8; }

- (UIView *)tableView:(UITableView *)tv viewForHeaderInSection:(NSInteger)s {
    CIFakeReportSection *sec = _sections[s];
    UIView *v = [[UIView alloc] init];
    v.backgroundColor = [CITheme bg];
    NSInteger ok = 0, total = sec.rows.count;
    for (CIFakeReportRow *r in sec.rows) if (r.ok) ok++;
    UILabel *l = [[UILabel alloc] init];
    l.frame = CGRectMake(20, 16, tv.bounds.size.width - 40, 28);
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    l.text = [NSString stringWithFormat:@"%@  %@   %ld/%ld", sec.icon, sec.title, (long)ok, (long)total];
    l.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    l.textColor = (ok == total) ? [CITheme green] : (ok == 0 ? [CITheme red] : [CITheme orange]);
    [v addSubview:l];
    return v;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"frow";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) {
        c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.backgroundColor = [UIColor clearColor];
        c.contentView.backgroundColor = [UIColor clearColor];
    }
    for (UIView *v in c.contentView.subviews) [v removeFromSuperview];

    CIFakeReportRow *r = _sections[ip.section].rows[ip.row];
    CGFloat W = tv.bounds.size.width;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(16, 2, W - 32, 48)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.backgroundColor = [CITheme card];
    card.layer.cornerRadius = 10;
    card.layer.borderWidth = 1;
    UIColor *accent = r.ok ? [CITheme green] : [CITheme red];
    card.layer.borderColor = [accent colorWithAlphaComponent:0.35].CGColor;
    [c.contentView addSubview:card];

    UILabel *glyph = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, 24, 48)];
    glyph.text = r.ok ? @"✓" : @"✕";
    glyph.textColor = accent;
    glyph.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    glyph.textAlignment = NSTextAlignmentCenter;
    [card addSubview:glyph];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(40, 6, 130, 36)];
    lbl.text = r.label;
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    lbl.textColor = [CITheme text];
    [card addSubview:lbl];

    UILabel *val = [[UILabel alloc] initWithFrame:CGRectMake(174, 6, card.bounds.size.width - 184, 36)];
    val.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    val.text = r.value;
    val.font = [UIFont systemFontOfSize:12];
    val.textColor = r.ok ? [CITheme dim] : [[CITheme red] colorWithAlphaComponent:0.7];
    val.numberOfLines = 2;
    val.lineBreakMode = NSLineBreakByTruncatingMiddle;
    val.textAlignment = NSTextAlignmentRight;
    [card addSubview:val];

    return c;
}

@end


// ============================================================
// HOME VIEW CONTROLLER (matches Xóa Info layout)
// ============================================================
@interface CIHomeViewController : UIViewController <UITextFieldDelegate>
@end

@implementation CIHomeViewController {
    UITextField *_noteField;
    UILabel     *_bannerLabel;
    UILabel     *_selectedResetLabel;
    UILabel     *_selectedRrsLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [CITheme bg];
    self.title = @"HIOS Faker";

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[self menuIcon] style:UIBarButtonItemStylePlain
                                        target:self action:@selector(openMenu)];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sv.alwaysBounceVertical = YES;
    [self.view addSubview:sv];

    CGFloat W = self.view.bounds.size.width;
    CGFloat y = 12;
    CGFloat P = 12;

    _bannerLabel = [[UILabel alloc] initWithFrame:CGRectMake(P, y, W-2*P, 22)];
    _bannerLabel.text = CIDeviceBanner();
    _bannerLabel.font = [UIFont systemFontOfSize:14];
    _bannerLabel.textColor = [CITheme text];
    [sv addSubview:_bannerLabel];
    y += 30;

    UIButton *b1 = CIBoxButton(@"Lưu RRS\n+\nReset Data", [CITheme orange], [CITheme border]);
    b1.frame = CGRectMake(P, y, (W-3*P)/2, 96);
    [b1 addTarget:self action:@selector(saveAndReset) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:b1];

    UIButton *b2 = CIBoxButton(@"Reset Data", [CITheme orange], [CITheme border]);
    b2.frame = CGRectMake((W-P)/2+P/2, y, (W-3*P)/2, 96);
    [b2 addTarget:self action:@selector(resetData) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:b2];
    y += 110;

    UIButton *dbg = [UIButton buttonWithType:UIButtonTypeSystem];
    dbg.frame = CGRectMake(P, y, W-2*P, 44);
    [dbg setTitle:@"📋 Xem thông tin máy fake" forState:UIControlStateNormal];
    [dbg setTitleColor:[CITheme blue] forState:UIControlStateNormal];
    dbg.titleLabel.font = [CITheme h2];
    dbg.backgroundColor = [CITheme card];
    dbg.layer.cornerRadius = 10;
    dbg.layer.borderWidth = 1;
    dbg.layer.borderColor = [CITheme border].CGColor;
    [dbg addTarget:self action:@selector(showFakeInfoReport) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:dbg];
    y += 56;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(P, y, W-2*P, 180)];
    card.backgroundColor = [CITheme card];
    card.layer.cornerRadius = 14;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOffset = CGSizeMake(0, 4);
    card.layer.shadowOpacity = 0.25;
    card.layer.shadowRadius = 8;
    [sv addSubview:card];

    [self addCardRow:@"1 Chọn App RESET!" detail:@"(chưa chọn)" y:0 parent:card action:@selector(pickResetApps) labelOut:&_selectedResetLabel];
    [self addCardRow:@"2 Chọn App lưu RRS" detail:@"" y:60 parent:card action:@selector(pickRRSApps) labelOut:&_selectedRrsLabel];
    [self addCardRow:@"3 Chọn Fake (version, model, name, carrier,...)" detail:@"" y:120 parent:card action:@selector(openFake) labelOut:NULL];
    y += 192;

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(P, y, W-2*P, 22)];
    hint.text = @"INFO FAKE";
    hint.textAlignment = NSTextAlignmentCenter;
    hint.font = [CITheme h2]; hint.textColor = [CITheme orange];
    [sv addSubview:hint];
    y += 30;

    UIView *bottomRow = [[UIView alloc] initWithFrame:CGRectMake(P, y, W-2*P, 60)];
    bottomRow.backgroundColor = [CITheme card];
    bottomRow.layer.cornerRadius = 14;
    bottomRow.layer.shadowColor = [UIColor blackColor].CGColor;
    bottomRow.layer.shadowOffset = CGSizeMake(0, 4);
    bottomRow.layer.shadowOpacity = 0.25;
    bottomRow.layer.shadowRadius = 8;
    [sv addSubview:bottomRow];
    UIButton *manage = [UIButton buttonWithType:UIButtonTypeSystem];
    manage.frame = CGRectMake(0, 0, (W-2*P)/2, 60);
    [manage setTitle:@"Quản lý RRS" forState:UIControlStateNormal];
    [manage setTitleColor:[CITheme orange] forState:UIControlStateNormal];
    manage.titleLabel.font = [CITheme h2];
    [manage addTarget:self action:@selector(openRRS) forControlEvents:UIControlEventTouchUpInside];
    [bottomRow addSubview:manage];
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake((W-2*P)/2, 10, 1, 40)];
    div.backgroundColor = [CITheme separator]; [bottomRow addSubview:div];
    UIButton *restore = [UIButton buttonWithType:UIButtonTypeSystem];
    restore.frame = CGRectMake((W-2*P)/2, 0, (W-2*P)/2, 60);
    [restore setTitle:@"Restore nhanh" forState:UIControlStateNormal];
    [restore setTitleColor:[CITheme blue] forState:UIControlStateNormal];
    restore.titleLabel.font = [CITheme h2];
    [restore addTarget:self action:@selector(quickRestore) forControlEvents:UIControlEventTouchUpInside];
    [bottomRow addSubview:restore];
    y += 72;

    _noteField = [[UITextField alloc] initWithFrame:CGRectMake(P, y, W-2*P, 48)];
    _noteField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Ghi chú khi lưu retention (RRS)"
        attributes:@{NSForegroundColorAttributeName: [CITheme dim]}];
    _noteField.borderStyle = UITextBorderStyleNone;
    _noteField.backgroundColor = [CITheme card];
    _noteField.textColor = [CITheme text];
    _noteField.layer.cornerRadius = 12;
    _noteField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 0)];
    _noteField.leftViewMode = UITextFieldViewModeAlways;
    _noteField.delegate = self;
    _noteField.text = [[CIConfigManager shared] stringForKey:@"rrsNote"];
    [sv addSubview:_noteField];
    y += 60;

    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(P, y, W-2*P, 30)];
    foot.text = @"telegram:Houselis"; foot.textAlignment = NSTextAlignmentCenter;
    foot.textColor = [CITheme blue]; foot.font = [CITheme h2];
    [sv addSubview:foot];
    y += 42;

    sv.contentSize = CGSizeMake(W, y);
    [self refreshSelectionLabels];
}

- (UIImage *)menuIcon {
    CGSize s = CGSizeMake(24, 20);
    UIGraphicsBeginImageContextWithOptions(s, NO, 0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(ctx, 3);
    CGContextSetStrokeColorWithColor(ctx, [CITheme blue].CGColor);
    for (int i=0; i<3; i++) {
        CGContextMoveToPoint(ctx, 0, 2+i*8);
        CGContextAddLineToPoint(ctx, 24, 2+i*8);
    }
    CGContextStrokePath(ctx);
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (void)addCardRow:(NSString *)title detail:(NSString *)detail y:(CGFloat)y parent:(UIView *)parent action:(SEL)sel labelOut:(UILabel *__strong *)out {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, y, parent.bounds.size.width, 60);
    btn.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [btn addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [parent addSubview:btn];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, parent.bounds.size.width-24, 52)];
    t.text = title; t.font = [CITheme body]; t.textColor = [CITheme orange];
    t.numberOfLines = 2;
    [btn addSubview:t];

    if (out) {
        UILabel *d = [[UILabel alloc] initWithFrame:CGRectMake(12, 28, parent.bounds.size.width-24, 24)];
        d.font = [CITheme small]; d.textColor = [CITheme dim];
        d.textAlignment = NSTextAlignmentRight;
        [btn addSubview:d];
        *out = d;
    }

    if (y < parent.bounds.size.height - 60) {
        UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, 60-0.5, parent.bounds.size.width, 0.5)];
        sep.backgroundColor = [CITheme separator];
        sep.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [btn addSubview:sep];
    }
}

- (void)refreshSelectionLabels {
    NSUInteger r = [[CIConfigManager shared] targetBundles].count;
    NSUInteger s = [[CIConfigManager shared] rrsBundles].count;
    _selectedResetLabel.text = r ? [NSString stringWithFormat:@"đã chọn %lu app", (unsigned long)r] : @"(chưa chọn)";
    _selectedRrsLabel.text   = s ? [NSString stringWithFormat:@"đã chọn %lu app", (unsigned long)s] : @"";
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self refreshSelectionLabels]; }

// ----- actions -----
- (void)textFieldDidEndEditing:(UITextField *)tf {
    [[CIConfigManager shared] setObject:(tf.text.length ? tf.text : nil) forKey:@"rrsNote"];
    [[CIConfigManager shared] save];
}

- (void)openMenu {
    CISideMenuViewController *vc = [[CISideMenuViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    vc.title = @"Menu";
    vc.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(dismissAny)];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)dismissAny { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)pickResetApps {
    CIAppPickerViewController *vc = [[CIAppPickerViewController alloc] init];
    vc.mode = CIAppPickerModeReset;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)pickRRSApps {
    CIAppPickerViewController *vc = [[CIAppPickerViewController alloc] init];
    vc.mode = CIAppPickerModeRRS;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)openFake {
    CIFakeSettingsViewController *vc = [[CIFakeSettingsViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}
- (void)openRRS {
    CIRRSManagerViewController *vc = [[CIRRSManagerViewController alloc] init];
    vc.title = [NSString stringWithFormat:@"%lu RRS", (unsigned long)[[CIRRSStore shared] entries].count];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    [self presentViewController:nav animated:YES completion:nil];
}

// View tags inside the progress HUD — fetched by updateHUD:step:title:subtitle:
// to mutate the right subview without traversing every time.
#define CI_HUD_DIM        0xC1DCD
#define CI_HUD_TITLE      0xC1DCE
#define CI_HUD_SUB        0xC1DCF
#define CI_HUD_STEP_LBL   0xC1DBD
#define CI_HUD_RING_HOST  0xC1DE0   // UIView holding the two CAShapeLayers
#define CI_HUD_CHECK      0xC1DD3
#define CI_HUD_CARD       0xC1DD4

// Keys for layers attached to the ring host so we can find them later.
static NSString *const kCIHudRingTrackKey = @"ciTrackLayer";
static NSString *const kCIHudRingFillKey  = @"ciFillLayer";
static NSString *const kCIHudRingSpinKey  = @"ciSpinLayer";

- (UIView *)showHUDWithTitle:(NSString *)title {
    // Circular-ring progress HUD. Layout (300×280):
    //   ┌────────────────────────────────┐
    //   │            ╭───╮                │
    //   │           ╱     ╲               │   outer track ring (faint)
    //   │          │  1/5  │              │   inner step counter
    //   │           ╲     ╱               │   orange fill ring grows w/step
    //   │            ╰───╯                │   rotating gradient ring overlay
    //   │                                │
    //   │      Title (semibold)           │
    //   │      Subtitle text              │
    //   └────────────────────────────────┘
    // Two CAShapeLayer rings:
    //   trackLayer — full-circle stroke (faint colour) showing the path
    //   fillLayer  — same circle, strokeEnd animates 0 → step/total
    // A third layer (spinLayer) is a thin rotating arc on top of the fill
    // for a constant "alive" indicator while the step is sleeping for I/O.
    UIView *root = self.view.window ?: self.view;
    UIView *dim = [[UIView alloc] initWithFrame:root.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.70];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.tag = CI_HUD_DIM;
    dim.alpha = 0;

    CGFloat cardW = MIN(300, root.bounds.size.width - 40);
    CGFloat cardH = 280;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, cardW, cardH)];
    card.center = CGPointMake(root.bounds.size.width/2, root.bounds.size.height/2);
    card.backgroundColor = [CITheme card];
    card.layer.cornerRadius = 22;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOffset = CGSizeMake(0, 12);
    card.layer.shadowOpacity = 0.45;
    card.layer.shadowRadius = 22;
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                          | UIViewAutoresizingFlexibleTopMargin  | UIViewAutoresizingFlexibleBottomMargin;
    card.tag = CI_HUD_CARD;
    [dim addSubview:card];

    // Ring host — a square view in the top half of the card. The ring layers
    // are sized to its bounds; we keep them on the host so layout/sizing is
    // self-contained and the rest of the card is regular UIKit.
    CGFloat ringSize = 130;
    UIView *ringHost = [[UIView alloc] initWithFrame:
        CGRectMake((cardW - ringSize)/2, 28, ringSize, ringSize)];
    ringHost.tag = CI_HUD_RING_HOST;
    ringHost.backgroundColor = [UIColor clearColor];
    [card addSubview:ringHost];

    CGFloat lineW = 8.0;
    CGFloat radius = (ringSize - lineW) / 2.0;
    CGPoint centerP = CGPointMake(ringSize / 2.0, ringSize / 2.0);
    UIBezierPath *circle = [UIBezierPath bezierPathWithArcCenter:centerP
                                                          radius:radius
                                                      startAngle:-M_PI_2
                                                        endAngle:(3 * M_PI_2)
                                                       clockwise:YES];

    CAShapeLayer *track = [CAShapeLayer layer];
    track.path = circle.CGPath;
    track.frame = ringHost.bounds;
    track.fillColor = [UIColor clearColor].CGColor;
    track.strokeColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    track.lineWidth = lineW;
    track.lineCap = kCALineCapRound;
    [ringHost.layer addSublayer:track];
    [ringHost.layer setValue:track forKey:kCIHudRingTrackKey];

    CAShapeLayer *fill = [CAShapeLayer layer];
    fill.path = circle.CGPath;
    fill.frame = ringHost.bounds;
    fill.fillColor = [UIColor clearColor].CGColor;
    fill.strokeColor = [CITheme orange].CGColor;
    fill.lineWidth = lineW;
    fill.lineCap = kCALineCapRound;
    fill.strokeStart = 0.0;
    fill.strokeEnd = 0.02;  // tiny initial dot so user sees orange right away
    [ringHost.layer addSublayer:fill];
    [ringHost.layer setValue:fill forKey:kCIHudRingFillKey];

    // Constant rotating arc — shorter stroke than `fill`, rides on top so
    // the user sees motion even when strokeEnd hasn't changed.
    CAShapeLayer *spin = [CAShapeLayer layer];
    spin.path = circle.CGPath;
    spin.frame = ringHost.bounds;
    spin.fillColor = [UIColor clearColor].CGColor;
    spin.strokeColor = [[CITheme orange] colorWithAlphaComponent:0.7].CGColor;
    spin.lineWidth = lineW;
    spin.lineCap = kCALineCapRound;
    spin.strokeStart = 0.0;
    spin.strokeEnd = 0.18; // 18% arc
    [ringHost.layer addSublayer:spin];
    [ringHost.layer setValue:spin forKey:kCIHudRingSpinKey];
    CABasicAnimation *rot = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rot.fromValue = @(0);
    rot.toValue = @(2 * M_PI);
    rot.duration = 1.4;
    rot.repeatCount = HUGE_VALF;
    [spin addAnimation:rot forKey:@"rot"];

    // Step counter sits dead-centre inside the ring.
    UILabel *stepLbl = [[UILabel alloc] initWithFrame:ringHost.bounds];
    stepLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    stepLbl.textAlignment = NSTextAlignmentCenter;
    stepLbl.textColor = [CITheme text];
    stepLbl.font = [UIFont systemFontOfSize:30 weight:UIFontWeightSemibold];
    stepLbl.text = @"…";
    stepLbl.tag = CI_HUD_STEP_LBL;
    [ringHost addSubview:stepLbl];

    // Title + subtitle — below the ring.
    UILabel *titleLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 178, cardW - 40, 26)];
    titleLbl.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleLbl.textColor = [CITheme text];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    titleLbl.text = title ?: @"Đang xử lý";
    titleLbl.numberOfLines = 1;
    titleLbl.adjustsFontSizeToFitWidth = YES;
    titleLbl.minimumScaleFactor = 0.8;
    titleLbl.tag = CI_HUD_TITLE;
    [card addSubview:titleLbl];

    UILabel *subLbl = [[UILabel alloc] initWithFrame:CGRectMake(20, 210, cardW - 40, 50)];
    subLbl.font = [UIFont systemFontOfSize:13];
    subLbl.textColor = [CITheme dim];
    subLbl.textAlignment = NSTextAlignmentCenter;
    subLbl.numberOfLines = 2;
    subLbl.text = @"Khởi tạo…";
    subLbl.tag = CI_HUD_SUB;
    [card addSubview:subLbl];

    [root addSubview:dim];
    [UIView animateWithDuration:0.22 animations:^{ dim.alpha = 1; }];
    return dim;
}

- (void)updateHUD:(UIView *)hud step:(NSInteger)step total:(NSInteger)total
            title:(NSString *)title subtitle:(NSString *)subtitle {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *card = [hud viewWithTag:CI_HUD_CARD];
        if (!card) return;
        UILabel *stepLbl  = (UILabel *)[[card viewWithTag:CI_HUD_RING_HOST] viewWithTag:CI_HUD_STEP_LBL];
        UILabel *titleLbl = (UILabel *)[card viewWithTag:CI_HUD_TITLE];
        UILabel *subLbl   = (UILabel *)[card viewWithTag:CI_HUD_SUB];
        UIView  *ringHost =            [card viewWithTag:CI_HUD_RING_HOST];

        if (stepLbl)  stepLbl.text  = [NSString stringWithFormat:@"%ld/%ld", (long)step, (long)total];
        if (titleLbl && title.length) titleLbl.text = title;
        if (subLbl)   subLbl.text   = subtitle ?: @"";

        CAShapeLayer *fillLayer = [ringHost.layer valueForKey:kCIHudRingFillKey];
        if (fillLayer && total > 0) {
            CGFloat target = MAX(0.02, MIN(1.0, (CGFloat)step / (CGFloat)total));
            // Animate strokeEnd so the orange arc sweeps to the new ratio.
            CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
            anim.fromValue = @(fillLayer.presentationLayer
                                ? ((CAShapeLayer *)fillLayer.presentationLayer).strokeEnd
                                : fillLayer.strokeEnd);
            anim.toValue = @(target);
            anim.duration = 0.35;
            anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            anim.fillMode = kCAFillModeForwards;
            fillLayer.strokeEnd = target;
            [fillLayer addAnimation:anim forKey:@"sweep"];
        }
    });
}

// Back-compat for callers that pass a single status string ("[2/5] Killing…").
// Parses the "[N/M] Title…" prefix when present so the new layout still works
// with old call sites; falls back to dropping the whole string into the title.
- (void)updateHUDTitle:(UIView *)hud title:(NSString *)title {
    if (title.length == 0) return;
    NSInteger step = 0, total = 0;
    NSString *clean = title;
    NSScanner *sc = [NSScanner scannerWithString:title];
    if ([sc scanString:@"[" intoString:NULL] && [sc scanInteger:&step]
        && [sc scanString:@"/" intoString:NULL] && [sc scanInteger:&total]
        && [sc scanString:@"]" intoString:NULL]) {
        clean = [[title substringFromIndex:sc.scanLocation]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    [self updateHUD:hud step:step total:total title:clean subtitle:clean];
}

- (void)finishHUD:(UIView *)hud success:(BOOL)success message:(NSString *)message {
    // Stop the rotation, fill the ring 100%, fade in a ✓/✕ glyph in the
    // centre. Caller still calls dismissHUD: separately ~0.7s later.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *card = [hud viewWithTag:CI_HUD_CARD];
        UIView *ringHost = [card viewWithTag:CI_HUD_RING_HOST];
        UILabel *stepLbl = (UILabel *)[ringHost viewWithTag:CI_HUD_STEP_LBL];
        UILabel *titleLbl = (UILabel *)[card viewWithTag:CI_HUD_TITLE];
        UILabel *subLbl = (UILabel *)[card viewWithTag:CI_HUD_SUB];

        CAShapeLayer *fillLayer = [ringHost.layer valueForKey:kCIHudRingFillKey];
        CAShapeLayer *spinLayer = [ringHost.layer valueForKey:kCIHudRingSpinKey];
        if (spinLayer) [spinLayer removeAllAnimations];
        if (spinLayer) spinLayer.opacity = 0.0;
        if (fillLayer) {
            fillLayer.strokeColor = (success ? [CITheme green] : [CITheme red]).CGColor;
            CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"strokeEnd"];
            anim.fromValue = @(fillLayer.strokeEnd);
            anim.toValue = @(1.0);
            anim.duration = 0.25;
            anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            anim.fillMode = kCAFillModeForwards;
            fillLayer.strokeEnd = 1.0;
            [fillLayer addAnimation:anim forKey:@"finish"];
        }
        if (stepLbl) {
            stepLbl.text = success ? @"✓" : @"✕";
            stepLbl.textColor = success ? [CITheme green] : [CITheme red];
            stepLbl.font = [UIFont systemFontOfSize:48 weight:UIFontWeightBold];
        }
        if (titleLbl) titleLbl.text = success ? @"Hoàn tất" : @"Có lỗi";
        if (subLbl)   subLbl.text   = message ?: @"";
    });
}

- (void)dismissHUD:(UIView *)hud completion:(void(^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.20 animations:^{ hud.alpha = 0; }
            completion:^(BOOL _) { [hud removeFromSuperview]; if (completion) completion(); }];
    });
}

- (void)debugCheckInject {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableString *out = [NSMutableString string];

    // 1. Shared prefs (app → tweak handoff file)
    NSString *sharedPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
    BOOL sharedExists = [fm fileExistsAtPath:sharedPath];
    unsigned long long sharedSize = 0;
    NSUInteger sharedKeys = 0;
    if (sharedExists) {
        NSDictionary *attr = [fm attributesOfItemAtPath:sharedPath error:nil];
        sharedSize = [attr[NSFileSize] unsignedLongLongValue];
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:sharedPath];
        sharedKeys = d.count;
    }
    [out appendFormat:@"%@ Shared prefs: %llu bytes, %lu keys\n",
        (sharedExists && sharedSize > 1024) ? @"✅" : @"❌",
        sharedSize, (unsigned long)sharedKeys];

    // 2. Dylib + filter plist in the substrate dir
    NSString *dylibPath  = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.dylib";
    NSString *filterPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.plist";
    BOOL dylibExists = [fm fileExistsAtPath:dylibPath];
    unsigned long long dylibSize = 0;
    if (dylibExists) {
        dylibSize = [[fm attributesOfItemAtPath:dylibPath error:nil][NSFileSize] unsignedLongLongValue];
    }
    [out appendFormat:@"%@ Dylib: %llu bytes\n",
        (dylibExists && dylibSize > 50000) ? @"✅" : @"❌", dylibSize];

    BOOL filterExists = [fm fileExistsAtPath:filterPath];
    NSDictionary *filter = [NSDictionary dictionaryWithContentsOfFile:filterPath];
    NSArray *bundles = [filter[@"Filter"][@"Bundles"]     isKindOfClass:[NSArray class]] ? filter[@"Filter"][@"Bundles"]     : @[];
    NSArray *execs   = [filter[@"Filter"][@"Executables"] isKindOfClass:[NSArray class]] ? filter[@"Filter"][@"Executables"] : @[];
    BOOL hasAida = [bundles containsObject:@"com.finalwire.aida64"];
    [out appendFormat:@"%@ Filter plist: %lu bundles, %lu execs, aida64=%@\n",
        (filterExists && hasAida) ? @"✅" : @"❌",
        (unsigned long)bundles.count, (unsigned long)execs.count,
        hasAida ? @"YES" : @"NO"];

    // 3. Injection markers — the actual proof substrate loaded our dylib
    NSString *markerDir = @"/var/mobile/Library/Caches/ChangeInfoIos";
    NSArray *items = [fm contentsOfDirectoryAtPath:markerDir error:nil];
    NSMutableArray *markers = [NSMutableArray array];
    NSMutableArray *helloMarkers = [NSMutableArray array];
    for (NSString *f in items) {
        if ([f hasPrefix:@"injected_"] && [f hasSuffix:@".txt"]) {
            NSString *bid = [[f substringFromIndex:9] stringByReplacingOccurrencesOfString:@".txt" withString:@""];
            // Skip the self-inject false positive written by an earlier debug build.
            if ([bid isEqualToString:@"com.changeinfoios.app"]) {
                [fm removeItemAtPath:[markerDir stringByAppendingPathComponent:f] error:nil];
                continue;
            }
            [markers addObject:bid];
        } else if ([f hasPrefix:@"hello_"] && [f hasSuffix:@".txt"] && ![f isEqualToString:@"hello_all.log"]) {
            NSString *bid = [[f substringFromIndex:6] stringByReplacingOccurrencesOfString:@".txt" withString:@""];
            [helloMarkers addObject:bid];
        }
    }
    BOOL aidaInjected = [markers containsObject:@"com.finalwire.aida64"];
    [out appendFormat:@"\n%@ Main tweak inject: %lu app(s)\n",
        markers.count > 0 ? @"✅" : @"❌", (unsigned long)markers.count];
    for (NSString *bid in markers) [out appendFormat:@"  • %@\n", bid];
    [out appendFormat:@"%@ HelloInject probe: %lu app(s)\n",
        helloMarkers.count > 0 ? @"✅" : @"❌", (unsigned long)helloMarkers.count];
    for (NSString *bid in helloMarkers) [out appendFormat:@"  • %@\n", bid];

    // 4. Loader presence — confirms ellekit/substrate is even installed
    NSArray *loaderPaths = @[@"/var/jb/usr/lib/libellekit.dylib",
                             @"/var/jb/usr/lib/TweakInject.dylib",
                             @"/var/jb/usr/lib/libsubstrate.dylib"];
    NSMutableArray *loaderFound = [NSMutableArray array];
    for (NSString *p in loaderPaths) {
        if ([fm fileExistsAtPath:p]) [loaderFound addObject:[p lastPathComponent]];
    }
    [out appendFormat:@"\n%@ Loader: %@\n",
        loaderFound.count > 0 ? @"✅" : @"❌",
        loaderFound.count > 0 ? [loaderFound componentsJoinedByString:@", "] : @"(none found)"];

    // 5. Diagnosis — pick the single most actionable step
    [out appendString:@"\n=== CHẨN ĐOÁN ===\n"];
    if (!sharedExists || sharedSize < 1024) {
        [out appendString:@"⚠ Shared prefs chưa ghi — bấm CHANGE trước rồi test lại.\n"];
    } else if (!dylibExists || !filterExists) {
        [out appendString:@"⚠ Thiếu dylib hoặc filter plist — cài lại .deb mới nhất.\n"];
    } else if (!hasAida) {
        [out appendString:@"⚠ Filter plist không có com.finalwire.aida64 — .deb cũ, cài bản mới.\n"];
    } else if (loaderFound.count == 0) {
        [out appendString:@"⚠ KHÔNG tìm thấy ellekit/substrate — mở Sileo cài lại loader.\n"];
    } else if (markers.count == 0 && helloMarkers.count == 0) {
        [out appendString:@"⚠ Loader có mặt nhưng không inject bất kỳ app nào.\n"
                          @"  → Mở Safari rồi test lại; nếu vẫn trống → reboot máy.\n"
                          @"  → Vẫn trống sau reboot → ellekit daemon lỗi, reinstall Dopamine.\n"];
    } else if (markers.count == 0 && helloMarkers.count > 0) {
        [out appendString:@"⚠ HelloInject load được nhưng ChangeInfoIos thì không.\n"
                          @"  → Framework link của tweak chính có vấn đề, xem CI log.\n"];
    } else if (!aidaInjected) {
        [out appendString:@"⚠ Tweak inject được app khác nhưng chưa vào AIDA64.\n"
                          @"  → Mở AIDA64 (cold start, không qua App Switcher) rồi check lại.\n"];
    } else {
        [out appendString:@"✅ AIDA64 đã inject. Nếu vẫn thấy máy gốc → key config chưa khớp.\n"];
    }

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Debug Inject Check"
                                                                message:out
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        [UIPasteboard generalPasteboard].string = out;
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// ============================================================
// "Xem thông tin máy fake" — full hook status report
// ============================================================
// Replaces the old text-dump Debug Inject Check button. Presents a
// modal table with every faked field grouped by hook layer; rows are
// green when the config has a non-empty value (hook will return that
// value to target apps) and red when the field is missing (hook
// installed but will fall through to %orig). Helps the user verify
// at a glance which fields actually got rolled fresh after Reset.
- (void)showFakeInfoReport {
    CIFakeInfoReportViewController *vc = [[CIFakeInfoReportViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)saveAndReset {
    [self performRRSBackup:YES];
}
- (void)resetData {
    [self performRRSBackup:NO];
}
- (void)performRRSBackup:(BOOL)backup {
    NSArray<NSString *> *resetBids = [[CIConfigManager shared] targetBundles];
    if (resetBids.count == 0) {
        [self alert:@"Chưa chọn app" msg:@"Vào mục 1 để chọn app cần reset dữ liệu."]; return;
    }
    NSArray<NSString *> *rrsBids = backup ? [[CIConfigManager shared] rrsBundles] : nil;
    if (backup && rrsBids.count == 0) {
        [self alert:@"Chưa chọn app lưu RRS" msg:@"Vào mục 2 để chọn app cần lưu retention."]; return;
    }

    NSArray<CIAppInfo *> *all = [CIAppLister allApps];
    NSMutableArray<CIAppInfo *> *targets = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (CIAppInfo *a in all) {
        if ([resetBids containsObject:a.bundleID]) {
            [targets addObject:a];
            [names addObject:a.name ?: a.bundleID];
        }
    }

    NSString *note = _noteField.text ?: @"";
    NSString *title = backup ? @"Đang lưu RRS + Change dữ liệu..." : @"Bắt đầu change dữ liệu...";
    UIView *hud = [self showHUDWithTitle:title];

    // Build full target list: user-selected apps + auto-include the device
    // verifiers (AIDA / Lirum / DeviceDesign) so the user can immediately
    // open one to confirm the spoof landed, plus Mobile Safari so all the
    // browser-side cookie / IDFA / WebKit cache is wiped each reset (iOS
    // shares the WebKit data store across every app that uses SFSafari /
    // WKWebView, so leaving Safari behind leaks fingerprint state).
    NSArray *aidaBids = @[
        @"com.finalwire.aida64",
        @"com.finalwire.aida64-ios",
        @"com.blacksmith.lirum",
        @"com.umang.devicedesign",
        @"com.apple.mobilesafari",
    ];
    NSMutableArray<CIAppInfo *> *fullTargets = [targets mutableCopy];
    NSMutableSet<NSString *> *addedBids = [NSMutableSet setWithArray:[targets valueForKey:@"bundleID"]];
    for (CIAppInfo *a in all) {
        if ([aidaBids containsObject:a.bundleID] && ![addedBids containsObject:a.bundleID]) {
            [fullTargets addObject:a];
            [addedBids addObject:a.bundleID];
            [names addObject:a.name ?: a.bundleID];
        }
    }

    // CIAppLister only enumerates 3rd-party apps under
    // /var/containers/Bundle/Application — system apps like Mobile Safari
    // live in /Applications/ and never appear in the list. For the
    // auto-included BIDs, fall back to scanning /var/mobile/Containers/
    // Data/Application for the matching data container so we can still
    // wipe their cache / cookies / WebKit data.
    for (NSString *bid in aidaBids) {
        if ([addedBids containsObject:bid]) continue;
        NSString *dataPath = ci_findDataContainerForBundle(bid);
        if (dataPath.length == 0) continue;
        CIAppInfo *synthetic = [CIAppInfo new];
        synthetic.bundleID = bid;
        synthetic.containerPath = dataPath;
        // Fixed display name for system bundles we know about — falls back
        // to the bundleID itself if it's a less common id.
        if ([bid isEqualToString:@"com.apple.mobilesafari"]) synthetic.name = @"Safari";
        else                                                  synthetic.name = bid;
        [fullTargets addObject:synthetic];
        [addedBids addObject:bid];
        [names addObject:synthetic.name];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Step-by-step with visible progress. Each step takes ~1-2s minimum
        // so the user can read what's happening on screen.

        // Step 1: Generate new fake identities and persist to plist
        [self updateHUD:hud step:1 total:5
                  title:@"Tạo thông tin giả mới"
               subtitle:@"Sinh Serial, UDID, IMEI, IDFA, MAC mới…"];
        [NSThread sleepForTimeInterval:1.5];
        ci_randomizeIdentities();
        NSLog(@"[ChangeInfoIos] Step 1 done: fake identities generated");

        // Step 2: Kill + wipe target app sandboxes.
        // Kill FIRST so file handles release and the app can't re-create files
        // mid-wipe. Do it via 3 mechanisms per app for maximum coverage:
        //   1) killall -9 '<ExecName>' — the canonical path
        //   2) pkill -9 -f '<bundleID>' — matches cmdline (catches ext processes)
        //   3) pkill -9 -f '<bundle-path>' — in case exec name was spoofed
        NSArray *subs = @[@"Documents", @"Library/Caches", @"Library/Preferences",
                          @"Library/Cookies", @"Library/WebKit",
                          @"Library/Application Support", @"tmp"];
        NSUInteger wiped = 0;
        long long counter = (long long)[[NSDate date] timeIntervalSince1970];
        NSUInteger totalApps = fullTargets.count;

        void (^killApp)(CIAppInfo *) = ^(CIAppInfo *a) {
            NSString *exec = nil;
            if (a.bundlePath.length) {
                NSBundle *b = [NSBundle bundleWithPath:a.bundlePath];
                exec = [[b executablePath] lastPathComponent];
                if (!exec.length) exec = [b objectForInfoDictionaryKey:@"CFBundleExecutable"];
            }
            // IMPORTANT: do NOT pkill -f <bundleID>. That string appears in
            // the cmdline of system services (backboardd, runningboardd,
            // installd, containermanagerd, …) which all carry per-app state
            // strings. Killing those caused the v2.4.0-a5256fe regression
            // where wiping com.apple.mobilesafari took down WebKit-related
            // daemons and AIDA64 wouldn't relaunch. Only the executable
            // name (killall -9 <ExecName>) and the FULL bundle path
            // (pkill -f <bundle-path>) are specific enough to be safe.
            NSString *execSafe = [exec         stringByReplacingOccurrencesOfString:@"'" withString:@""] ?: @"";
            NSString *pathSafe = [a.bundlePath stringByReplacingOccurrencesOfString:@"'" withString:@""] ?: @"";
            NSMutableString *kcmd = [NSMutableString string];
            if (execSafe.length) [kcmd appendFormat:@"killall -9 '%@' 2>/dev/null; ", execSafe];
            if (pathSafe.length) [kcmd appendFormat:@"pkill -9 -f '%@' 2>/dev/null; ", pathSafe];
            if (kcmd.length) ci_run([kcmd UTF8String]);
        };

        for (CIAppInfo *a in fullTargets) {
            if (!a.containerPath.length) continue;
            NSString *sub = [NSString stringWithFormat:@"%lu/%lu — %@",
                (unsigned long)wiped + 1, (unsigned long)totalApps, a.name ?: a.bundleID];
            [self updateHUD:hud step:2 total:5
                      title:@"Xoá dữ liệu app target"
                   subtitle:sub];
            [NSThread sleepForTimeInterval:0.8];
            killApp(a);
            [NSThread sleepForTimeInterval:0.5];
            for (NSString *sub in subs) {
                NSString *full = [a.containerPath stringByAppendingPathComponent:sub];
                NSString *cmd = [NSString stringWithFormat:
                    @"rm -rf '%@'/* '%@'/.[!.]* 2>/dev/null; mkdir -p '%@' 2>/dev/null",
                    full, full, full];
                ci_run([cmd UTF8String]);
            }
            NSString *marker = [a.containerPath stringByAppendingPathComponent:@".ci_last_wipe"];
            [[NSString stringWithFormat:@"%lld", counter] writeToFile:marker
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
            wiped++;
        }
        NSLog(@"[ChangeInfoIos] Step 2 done: killed + wiped %lu apps", (unsigned long)wiped);

        // Step 3: Clean detection caches + save counters
        [self updateHUD:hud step:3 total:5
                  title:@"Xoá cache phát hiện"
               subtitle:@"DeviceCheck, APNS, IDFA, AIDA cache, keychain…"];
        [NSThread sleepForTimeInterval:1.5];
        NSArray *detectPaths = @[
            @"/var/mobile/Library/Caches/com.finalwire.aida64",
            @"/var/mobile/Library/Caches/com.finalwire.aida64-ios",
            @"/var/mobile/Library/Preferences/com.finalwire.aida64.plist",
            @"/var/mobile/Library/Preferences/com.finalwire.aida64-ios.plist",
        ];
        for (NSString *p in detectPaths) {
            NSString *cmd = [NSString stringWithFormat:
                @"rm -rf '%@' 2>/dev/null; rm -rf '%@/.'* 2>/dev/null; rm -rf '%@/.[!.]*' 2>/dev/null",
                p, p, p];
            ci_run([cmd UTF8String]);
        }
        if (backup) [self createRRSForBundles:rrsBids note:note];
        CIConfigManager *cm = [CIConfigManager shared];
        NSArray *allBids = [fullTargets valueForKey:@"bundleID"];
        [cm setTargetBundles:allBids];
        ci_syncTweakFilterForApps(fullTargets);
        for (NSString *bid in allBids) {
            [cm setObject:@(counter) forKey:[@"wipe_counter_" stringByAppendingString:bid]];
        }
        [cm save];
        NSLog(@"[ChangeInfoIos] Step 3 done: counters saved, config reloaded (%lu target bundles)", (unsigned long)allBids.count);

        // Step 4: Respring to reload tweak with new fake config.
        // As mobile user we can't killall SpringBoard (root-owned). Try
        // sbreload/launchctl first (rootless-jb friendly), then fall back
        // to killall SpringBoard which only works if elevated.
        [self updateHUD:hud step:4 total:5
                  title:@"Restart SpringBoard"
               subtitle:@"Reload tweak với config mới…"];
        [NSThread sleepForTimeInterval:1.5];
        const char *respringCmd =
            "/var/jb/usr/bin/sbreload 2>/dev/null"
            " || sbreload 2>/dev/null"
            " || /var/jb/bin/launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null"
            " || launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null"
            " || killall -9 SpringBoard 2>/dev/null";
        int respringRC = ci_run(respringCmd);
        [NSThread sleepForTimeInterval:4.0];
        ci_run("/var/jb/usr/bin/uicache -a 2>/dev/null || uicache -a 2>/dev/null");
        [NSThread sleepForTimeInterval:2.0];
        BOOL respringOK = (respringRC == 0);
        NSLog(@"[ChangeInfoIos] Step 4 done: respring rc=%d", respringRC);

        // Step 5: Final kill sweep. After SpringBoard respring, iOS often
        // auto-resumes target apps from their launch snapshot. Kill them one
        // more time so that when the user next opens the app icon, it does a
        // FRESH cold-start and the tweak %ctor runs again with the new config.
        [self updateHUD:hud step:5 total:5
                  title:@"Dọn lần cuối"
               subtitle:@"Đảm bảo lần mở tới là cold-start mới…"];
        [NSThread sleepForTimeInterval:1.0];
        for (CIAppInfo *a in fullTargets) { killApp(a); }
        NSLog(@"[ChangeInfoIos] Step 5 done: post-respring kill sweep");

        // Collect fake IDs to show in summary so user can verify they changed.
        NSString *model  = [cm stringForKey:@"__presetModelName"] ?: @"—";
        NSString *ios    = [cm stringForKey:@"__presetIOSName"] ?: @"—";
        NSString *serial = [cm stringForKey:@"SerialNumber"] ?: @"—";
        NSString *idfa   = [cm stringForKey:@"advertisingIdentifier"] ?: @"—";
        NSString *udid   = [cm stringForKey:@"UniqueDeviceID"] ?: @"—";
        NSString *imei   = [cm stringForKey:@"InternationalMobileEquipmentIdentity"] ?: @"—";
        NSString *shortSerial = [serial length] > 12 ? [serial substringToIndex:12] : serial;
        NSString *shortUDID   = [udid length]   > 16 ? [[udid substringToIndex:16] stringByAppendingString:@"…"] : udid;

        // Diagnostic: verify shared prefs actually hit disk (see BUILD_NOTES §10).
        NSFileManager *fm2 = [NSFileManager defaultManager];
        BOOL sharedExists = [fm2 fileExistsAtPath:kSharedPrefPath];
        unsigned long long sharedSize = 0;
        if (sharedExists) {
            NSDictionary *at = [fm2 attributesOfItemAtPath:kSharedPrefPath error:nil];
            sharedSize = [at[NSFileSize] unsignedLongLongValue];
        }
        BOOL prefsOK = sharedExists && sharedSize >= 256;

        // Check tweak injection markers. Each target's tweak %ctor writes
        // /var/mobile/Library/Caches/ChangeInfoIos/injected_<bid>.txt on load.
        // If a bundle was opened since install but no marker → tweak didn't
        // inject there. See BUILD_NOTES §10.
        NSString *markerDir = @"/var/mobile/Library/Caches/ChangeInfoIos";
        NSMutableArray<NSString *> *notInjected = [NSMutableArray array];
        for (CIAppInfo *a in fullTargets) {
            if (!a.bundleID.length) continue;
            NSString *m = [markerDir stringByAppendingFormat:@"/injected_%@.txt", a.bundleID];
            if (![fm2 fileExistsAtPath:m]) {
                [notInjected addObject:a.name ?: a.bundleID];
            }
        }

        [self dismissHUD:hud completion:^{
            NSString *listMsg = names.count ? [names componentsJoinedByString:@", "] : @"(đã chọn)";
            NSString *t = backup ? @"Đã lưu RRS + Change thành công" : @"Change thành công";

            NSMutableString *body = [NSMutableString string];
            if (!prefsOK) {
                [body appendString:@"🚨 Shared prefs KHÔNG ghi được — tweak sẽ đọc config cũ.\nXem BUILD_NOTES §10.\n\n"];
            }
            if (notInjected.count > 0) {
                [body appendFormat:@"🚨 Tweak CHƯA inject vào: %@\n(Mở app đó 1 lần rồi thử lại.)\n\n",
                    [notInjected componentsJoinedByString:@", "]];
            }
            if (!respringOK) {
                [body appendFormat:@"⚠️ Respring fail (rc=%d).\n→ Hãy **force-quit** target app (vuốt lên) rồi mở lại.\n\n", respringRC];
            }
            [body appendFormat:@"Đã xoá dữ liệu %lu app:\n%@\n\n", (unsigned long)wiped, listMsg];
            [body appendFormat:@"Model: %@\niOS: %@\nSerial: %@\nIDFA: %@\nUDID: %@\nIMEI: %@\n\n",
                model, ios, shortSerial, idfa, shortUDID, imei];
            if (prefsOK) {
                [body appendFormat:@"✅ Shared prefs OK (%llu bytes)\n", sharedSize];
            }
            if (notInjected.count == 0 && fullTargets.count > 0) {
                [body appendFormat:@"✅ Tweak inject OK vào %lu app\n", (unsigned long)fullTargets.count];
            }
            if (respringOK) {
                [body appendString:@"✅ Đã restart SpringBoard.\n"];
            }
            [body appendString:@"\n👉 Mở lại app target để thấy thông tin fake mới."];
            [self alert:t msg:body];
        }];
    });
}

- (void)createRRSForBundles:(NSArray<NSString *> *)bids note:(NSString *)note {
    NSArray<CIAppInfo *> *all = [CIAppLister allApps];
    CIRRSEntry *e = [[CIRRSEntry alloc] init];
    e.uid = [[NSUUID UUID] UUIDString];
    e.idfa = [[CIConfigManager shared] stringForKey:@"advertisingIdentifier"] ?: @"-";
    e.ipReset = [[CIConfigManager shared] stringForKey:@"lastResetIP"] ?: @"-";
    e.note = note ?: @"";
    NSMutableArray *n = [NSMutableArray array]; NSMutableArray *b = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    unsigned long long total = 0;
    for (CIAppInfo *a in all) if ([bids containsObject:a.bundleID]) {
        [n addObject:a.name]; [b addObject:a.bundleID];
        if (a.containerPath) { [paths addObject:a.containerPath]; total += a.containerSize; }
    }
    e.appNames = n; e.bundleIDs = b; e.totalSize = total;

    NSString *tarPath = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar.gz"]];
    [[NSFileManager defaultManager] createDirectoryAtPath:kRRSDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableString *tarCmd = [NSMutableString stringWithFormat:@"tar -czf %@", tarPath];
    for (NSString *p in paths) [tarCmd appendFormat:@" %@", p];
    ci_run([tarCmd UTF8String]);
    [[CIRRSStore shared] addEntry:e];
}

- (void)quickRestore {
    NSArray *items = [[CIRRSStore shared] entries];
    if (items.count == 0) { [self alert:@"Không có RRS" msg:@"Chưa có snapshot nào để restore."]; return; }
    CIRRSEntry *e = items.firstObject;
    NSString *tar = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar.gz"]];
    UIView *hud = [self showHUDWithTitle:@"Đang Restore RRS..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *cmd = [NSString stringWithFormat:@"tar -xzf %@ -C /", tar];
        int rc = ci_run([cmd UTF8String]);
        [self dismissHUD:hud completion:^{
            [self alert:(rc == 0 ? @"Đã restore" : @"Restore fail") msg:[NSString stringWithFormat:@"rc=%d", rc]];
        }];
    });
}

- (void)alert:(NSString *)t msg:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

// ============================================================
// APP DELEGATE
// ============================================================
@interface CIAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation CIAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    [[CIConfigManager shared] config]; // warm

    // Global nav bar appearance — match dark theme
    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *a = [[UINavigationBarAppearance alloc] init];
        [a configureWithOpaqueBackground];
        a.backgroundColor = [CITheme bg];
        a.titleTextAttributes = @{NSForegroundColorAttributeName: [CITheme text]};
        a.largeTitleTextAttributes = @{NSForegroundColorAttributeName: [CITheme text]};
        UINavigationBar.appearance.standardAppearance = a;
        UINavigationBar.appearance.scrollEdgeAppearance = a;
        UINavigationBar.appearance.tintColor = [CITheme orange];
    }

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    CIHomeViewController *home = [[CIHomeViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:home];
    nav.navigationBar.prefersLargeTitles = NO;
    self.window.rootViewController = nav;
    self.window.backgroundColor = [CITheme bg];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"CIAppDelegate");
    }
}
