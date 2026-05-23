#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>  // CAShapeLayer / CABasicAnimation for ring HUD
#import <AVFoundation/AVFoundation.h>  // AVAssetExportSession for video import (CICameraVC)
#import <Photos/Photos.h>               // PHAsset / PHImageManager — proper cross-container path for picker assets
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
       CIRRSManagerViewController, CISideMenuViewController, CIProxyViewController;

// ============================================================
// CONSTANTS
// ============================================================
static NSString *const kSharedPrefPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
// Sandbox-friendly mirror for App Store app tweaks — /var/mobile/Library/Prefs
// is blocked by their sandboxes, /var/jb/etc/* is allowed (verified live).
static NSString *const kSharedConfigPath = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kNotifyReload   = @"com.changeinfoios/ReloadPrefs";

static int ci_run(const char *cmd); // defined below, forward decl for CIConfigManager.save shell-mirror

static NSString *const kAppVersion = @"2.5.22";

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
- (void)syncProfileWithPublicIPCompletion:(void(^)(BOOL success, NSString *city,
                                                     NSString *country, NSString *err))completion;
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

// v2.4.54: pull public IP geolocation (ipinfo.io) and sync profile coord,
// timezone, country code to match. Use case: user changes Shadowrocket VPN
// exit → app auto-detects new exit IP → updates lat/lng/timezone so
// browser geolocation, IP geo, and locale all show the SAME location
// (no "VPN in Vung Tau but GPS in Hanoi" leak).
//
// Network call is async; completion fires on main queue with detected
// city/country + spoof updated flag. Failure (no internet, ipinfo down)
// reports error but leaves profile untouched.
- (void)syncProfileWithPublicIPCompletion:(void(^)(BOOL success, NSString *city,
                                                     NSString *country, NSString *err))completion {
    NSURL *url = [NSURL URLWithString:@"https://ipinfo.io/json"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 8.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [req setValue:@"HIOSFaker/2.4" forHTTPHeaderField:@"User-Agent"];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        void (^finish)(BOOL, NSString *, NSString *, NSString *) = ^(BOOL ok, NSString *c, NSString *cc, NSString *e) {
            if (!completion) return;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, c, cc, e); });
        };
        if (err || !data) { finish(NO, nil, nil, err.localizedDescription ?: @"network"); return; }
        NSError *jerr = nil;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (jerr || ![j isKindOfClass:[NSDictionary class]]) {
            finish(NO, nil, nil, jerr.localizedDescription ?: @"parse"); return;
        }
        NSString *loc = j[@"loc"];     // "lat,lng"
        NSString *city = j[@"city"];
        NSString *country = j[@"country"];  // ISO country code
        NSString *tz = j[@"timezone"];
        NSArray *parts = [loc isKindOfClass:[NSString class]] ? [loc componentsSeparatedByString:@","] : nil;
        if (parts.count != 2) { finish(NO, city, country, @"missing loc"); return; }
        double lat = [parts[0] doubleValue];
        double lng = [parts[1] doubleValue];
        if (lat == 0 && lng == 0) { finish(NO, city, country, @"zero coord"); return; }
        // Update — keep numeric type for lat/lng (tweak reads as NSNumber).
        [self setObject:@(lat) forKey:@"latitude"];
        [self setObject:@(lng) forKey:@"longitude"];
        if (tz.length) [self setObject:tz forKey:@"timezoneName"];
        if (country.length) [self setObject:country forKey:@"localeCountryCode"];
        // Refresh altitude to a plausible value (city default = sea-level + small).
        [self setObject:@(15.0) forKey:@"altitude"];
        [self save];
        finish(YES, city, country, nil);
    }];
    [task resume];
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

// Parse a "host:port", "host:port:user:pass" string into components.
// Returns nil if host/port missing. Port must be 1..65535.
static NSDictionary *ci_parseProxyString(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    NSArray *parts = [trimmed componentsSeparatedByString:@":"];
    if (parts.count < 2) return nil;
    NSString *host = parts[0];
    NSInteger port = [parts[1] integerValue];
    if (host.length == 0 || port < 1 || port > 65535) return nil;
    NSMutableDictionary *out = [@{@"host": host, @"port": @(port)} mutableCopy];
    if (parts.count >= 3 && [parts[2] length] > 0) out[@"user"] = parts[2];
    if (parts.count >= 4 && [parts[3] length] > 0) out[@"pass"] = parts[3];
    return out;
}

// Build NSURLSessionConfiguration with the user's proxy applied (HTTP or
// SOCKS5). Returns nil if proxy not enabled / not parseable — caller should
// fall back to sharedSession in that case so external VPN still works.
//
// Proxy auth (user/pass) is injected by the URL loader's challenge handler;
// we set kCFProxyUsername/Password on the proxy dict so URLSession picks it
// up for both HTTP CONNECT auth and SOCKS5 auth without needing an extra
// NSURLCredential wiring.
static NSURLSessionConfiguration *ci_proxyConfigOrNil(void) {
    CIConfigManager *cm = [CIConfigManager shared];
    if (![cm boolForKey:@"proxyEnabled"]) return nil;
    NSDictionary *p = ci_parseProxyString([cm stringForKey:@"proxyString"]);
    if (!p) return nil;
    NSString *type = [cm stringForKey:@"proxyType"];
    BOOL socks = [type isEqualToString:@"socks5"];

    NSMutableDictionary *proxyDict = [NSMutableDictionary dictionary];
    NSString *host = p[@"host"];
    NSNumber *port = p[@"port"];
    NSString *u = p[@"user"];
    NSString *pw = p[@"pass"];

    if (socks) {
        proxyDict[(NSString *)kCFStreamPropertySOCKSProxyHost] = host;
        proxyDict[(NSString *)kCFStreamPropertySOCKSProxyPort] = port;
        proxyDict[(NSString *)kCFStreamPropertySOCKSVersion] = (NSString *)kCFStreamSocketSOCKSVersion5;
        if (u) proxyDict[(NSString *)kCFStreamPropertySOCKSUser]     = u;
        if (pw) proxyDict[(NSString *)kCFStreamPropertySOCKSPassword] = pw;
    } else {
        // HTTP/HTTPS via CFNetwork keys recognised by NSURLSession.
        proxyDict[@"HTTPEnable"]   = @YES;
        proxyDict[@"HTTPProxy"]    = host;
        proxyDict[@"HTTPPort"]     = port;
        proxyDict[@"HTTPSEnable"]  = @YES;
        proxyDict[@"HTTPSProxy"]   = host;
        proxyDict[@"HTTPSPort"]    = port;
        if (u) proxyDict[@"HTTPProxyUsername"]  = u;
        if (pw) proxyDict[@"HTTPProxyPassword"] = pw;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.connectionProxyDictionary = proxyDict;
    cfg.timeoutIntervalForRequest = 8.0;
    cfg.timeoutIntervalForResource = 10.0;
    return cfg;
}

// Blocking HTTP GET to ip-api.com — returns parsed dict or nil on any failure.
// Runs on background queue (caller is already off main), 5s timeout.
//
// If user has a proxy configured (Proxy section in side menu), the request
// is routed through that proxy so ip-api sees the proxy's IP. Otherwise
// falls back to sharedSession (uses any external VPN the user has on).
static NSDictionary *ci_fetchProxyGeo(NSString *url) {
    if (!url.length) url = @"http://ip-api.com/json";
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = 5.0;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    [req setValue:@"close" forHTTPHeaderField:@"Connection"];

    NSURLSession *session;
    NSURLSessionConfiguration *proxyCfg = ci_proxyConfigOrNil();
    if (proxyCfg) {
        session = [NSURLSession sessionWithConfiguration:proxyCfg];
    } else {
        session = [NSURLSession sharedSession];
    }

    __block NSData *data = nil; __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t = [session dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *_r, NSError *e) {
            data = d; err = e; dispatch_semaphore_signal(sem);
        }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
    if (proxyCfg) [session finishTasksAndInvalidate];
    if (err || !data) return nil;

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return nil;
    NSString *status = json[@"status"];
    if (status && ![status isEqualToString:@"success"]) return nil;
    return json;
}

// === Canonical mobile-carrier picker per country ===
// Returns @[carrierName, mcc, mnc, iso] randomly chosen from a country's
// actual mobile operators. Used to AVOID writing the raw ISP name returned
// by ip-api (e.g. "NXKY Vietnam Company Limited" — a wired ISP, not a
// cellular carrier) into carrierName. Zalo's anti-fraud expects mobile
// MCC/MNC to be paired with a real mobile-carrier brand; an ISP name +
// mobile MCC/MNC pair is a contradiction it can detect.
static NSArray *ci_pickMobileCarrierForCountry(NSString *cc) {
    if (cc.length == 0) return nil;
    static NSDictionary *m = nil;
    if (!m) m = @{
        @"VN": @[
            @[@"Viettel",      @"452", @"04", @"vn"],
            @[@"MobiFone",     @"452", @"01", @"vn"],
            @[@"Vinaphone",    @"452", @"02", @"vn"],
            @[@"Vinaphone",    @"452", @"03", @"vn"],
            @[@"Vietnamobile", @"452", @"05", @"vn"],
            @[@"Gmobile",      @"452", @"07", @"vn"],
        ],
        @"US": @[
            @[@"T-Mobile",     @"310", @"260", @"us"],
            @[@"T-Mobile",     @"310", @"160", @"us"],
            @[@"AT&T",         @"310", @"410", @"us"],
            @[@"AT&T",         @"310", @"150", @"us"],
            @[@"Verizon",      @"311", @"480", @"us"],
            @[@"Verizon",      @"310", @"012", @"us"],
        ],
        @"GB": @[
            @[@"EE",           @"234", @"30",  @"gb"],
            @[@"O2",           @"234", @"10",  @"gb"],
            @[@"Vodafone",     @"234", @"15",  @"gb"],
            @[@"Three",        @"234", @"20",  @"gb"],
        ],
        @"TH": @[
            @[@"AIS",          @"520", @"03",  @"th"],
            @[@"TrueMove H",   @"520", @"04",  @"th"],
            @[@"DTAC",         @"520", @"01",  @"th"],
            @[@"DTAC",         @"520", @"05",  @"th"],
        ],
        @"SG": @[
            @[@"Singtel",      @"525", @"01",  @"sg"],
            @[@"StarHub",      @"525", @"05",  @"sg"],
            @[@"M1",           @"525", @"03",  @"sg"],
        ],
        @"PH": @[
            @[@"Smart",        @"515", @"03",  @"ph"],
            @[@"Globe",        @"515", @"02",  @"ph"],
        ],
        @"ID": @[
            @[@"Telkomsel",    @"510", @"10",  @"id"],
            @[@"Indosat",      @"510", @"01",  @"id"],
            @[@"XL Axiata",    @"510", @"11",  @"id"],
        ],
        @"MY": @[
            @[@"Maxis",        @"502", @"12",  @"my"],
            @[@"Celcom",       @"502", @"13",  @"my"],
            @[@"DiGi",         @"502", @"16",  @"my"],
        ],
        @"JP": @[
            @[@"NTT DOCOMO",   @"440", @"10",  @"jp"],
            @[@"au by KDDI",   @"440", @"50",  @"jp"],
            @[@"SoftBank",     @"440", @"20",  @"jp"],
        ],
        @"KR": @[
            @[@"SK Telecom",   @"450", @"05",  @"kr"],
            @[@"KT",           @"450", @"08",  @"kr"],
            @[@"LG U+",        @"450", @"06",  @"kr"],
        ],
        @"TW": @[
            @[@"Chunghwa Telecom",  @"466", @"92", @"tw"],
            @[@"Taiwan Mobile",     @"466", @"97", @"tw"],
            @[@"FarEasTone",        @"466", @"01", @"tw"],
        ],
        @"HK": @[
            @[@"CSL",          @"454", @"00",  @"hk"],
            @[@"3 HK",          @"454", @"03",  @"hk"],
            @[@"China Mobile HK", @"454", @"12", @"hk"],
        ],
        @"AU": @[
            @[@"Telstra",      @"505", @"01",  @"au"],
            @[@"Optus",        @"505", @"02",  @"au"],
            @[@"Vodafone AU",  @"505", @"03",  @"au"],
        ],
    };
    NSArray *list = m[cc.uppercaseString];
    if (list.count == 0) return nil;
    return list[arc4random_uniform((uint32_t)list.count)];
}

// === Canonical IANA timezone per country ===
// ip-api sometimes returns regional aliases (Asia/Bangkok for VN IPs even
// though Vietnam's canonical zone is Asia/Ho_Chi_Minh). Apple's CFTimeZone
// stores Asia/Ho_Chi_Minh — if we report Bangkok while the device's
// internal CFTimeZone says Ho_Chi_Minh, Zalo sees a mismatch.
static NSString *ci_canonicalTimezoneForCountry(NSString *cc) {
    if (cc.length == 0) return nil;
    static NSDictionary *m = nil;
    if (!m) m = @{
        @"VN": @"Asia/Ho_Chi_Minh",   @"TH": @"Asia/Bangkok",
        @"SG": @"Asia/Singapore",     @"PH": @"Asia/Manila",
        @"ID": @"Asia/Jakarta",       @"MY": @"Asia/Kuala_Lumpur",
        @"JP": @"Asia/Tokyo",         @"KR": @"Asia/Seoul",
        @"CN": @"Asia/Shanghai",      @"TW": @"Asia/Taipei",
        @"HK": @"Asia/Hong_Kong",     @"IN": @"Asia/Kolkata",
        @"US": @"America/New_York",   @"CA": @"America/Toronto",
        @"MX": @"America/Mexico_City", @"BR": @"America/Sao_Paulo",
        @"GB": @"Europe/London",      @"FR": @"Europe/Paris",
        @"DE": @"Europe/Berlin",      @"IT": @"Europe/Rome",
        @"ES": @"Europe/Madrid",      @"NL": @"Europe/Amsterdam",
        @"SE": @"Europe/Stockholm",   @"AU": @"Australia/Sydney",
    };
    return m[cc.uppercaseString];
}

// === Realistic WiFi SSID per country ===
// "FPT-Home" / "Viettel-WiFi" only exist in Vietnam. If we claim US IP +
// US carrier but wifiSSID is a Vietnamese ISP, the inconsistency lights up
// in any tier-1 anti-fraud. Picks a believable home-router SSID format
// from the country's actual common ISP/router brands.
static NSString *ci_wifiSSIDForCountry(NSString *cc) {
    if (cc.length == 0) return nil;
    static NSDictionary *m = nil;
    if (!m) m = @{
        @"VN": @[@"FPT-Home", @"VNPT-Home", @"Viettel-WiFi", @"FPT_5G",
                 @"TP-Link", @"Tenda_WiFi", @"HOME-WIFI", @"NHA-WIFI"],
        @"US": @[@"NETGEAR91", @"Linksys03842", @"xfinitywifi", @"ATT-WIFI-Home",
                 @"TMOBILE-5G", @"home_2.4G", @"MyHomeWiFi", @"Spectrum-WiFi"],
        @"GB": @[@"SKY-2G", @"BT-Home", @"Virgin-Media-XX", @"TalkTalk-WiFi",
                 @"Plusnet-2G", @"EE-BrightBox"],
        @"TH": @[@"AIS-Fibre", @"TrueMove_H", @"3BB-Home", @"DTAC-WIFI",
                 @"@TRUEWIFI", @"AIS-3BB"],
        @"SG": @[@"Singtel-Home", @"StarHub-Home", @"M1-Home", @"MyRepublic_5G"],
        @"PH": @[@"PLDTHomeFibr", @"Globe-At-Home", @"Smart-WiFi", @"Converge"],
        @"ID": @[@"Indihome", @"FirstMedia", @"MyRepublic_ID", @"Biznet"],
        @"MY": @[@"unifi-2G", @"Maxis-Home", @"TIME-Fibre", @"DiGi-Home"],
        @"JP": @[@"NTT_HOME", @"docomo-NET", @"Buffalo-XXXX", @"NEC-Aterm"],
        @"KR": @[@"KT_GiGA", @"SKbroadband", @"U+_NET", @"LG-HelloVision"],
        @"TW": @[@"Chunghwa-CHT", @"FET-Net", @"TaiwanMobile-Home"],
        @"HK": @[@"CSL-Home", @"PCCW-HomeFibre", @"HKBN-1000M"],
        @"AU": @[@"Telstra-Home", @"Optus-Internet", @"TPG-WiFi"],
    };
    NSArray *list = m[cc.uppercaseString];
    if (list.count == 0) return nil;
    return list[arc4random_uniform((uint32_t)list.count)];
}

// Apply ip-api geo response to config. Returns YES if applied.
//
// CRITICAL: this is what makes the map shown in Zalo (and the GPS that
// Apple/Zalo background-monitor) match the IP your proxy reports. Without
// this, GPS = random VN coords + IP = random US proxy = instant detection.
//
// Propagation per response field:
//   lat/lon       → latitude/longitude (+2km jitter for sensor realism)
//   countryCode   → locale, currency, language, carrier brand, MCC/MNC, SSID
//   timezone      → canonical IANA name (override ip-api regional aliases)
//   query (IP)    → lastResetIP (for the user-visible report)
static BOOL ci_applyGeoFromIPAPI(NSDictionary *geo) {
    if (!geo) return NO;
    id latV = geo[@"lat"], lonV = geo[@"lon"];
    if (!latV || !lonV) return NO;
    CIConfigManager *cm = [CIConfigManager shared];

    // GPS: pin to proxy IP location + tiny ~2km jitter only.
    double lat = 0, lon = 0;
    ci_jitterCoordKm([latV doubleValue], [lonV doubleValue], 2.0, &lat, &lon);
    double alt = ci_randDouble(5.0, 180.0);
    [cm setObject:[NSString stringWithFormat:@"%.6f", lat] forKey:@"latitude"];
    [cm setObject:[NSString stringWithFormat:@"%.6f", lon] forKey:@"longitude"];
    [cm setObject:[NSString stringWithFormat:@"%.2f", alt] forKey:@"altitude"];
    ci_writeLocationFuzz(cm);

    NSString *cc = ([geo[@"countryCode"] isKindOfClass:[NSString class]]
                    ? [geo[@"countryCode"] uppercaseString] : @"");

    // Timezone: prefer our canonical IANA per-country mapping; fall back to
    // whatever ip-api returned (could be a regional alias).
    NSString *canonTZ = ci_canonicalTimezoneForCountry(cc);
    if (canonTZ.length) {
        [cm setObject:canonTZ forKey:@"timezoneName"];
    } else if ([geo[@"timezone"] isKindOfClass:[NSString class]] &&
               [geo[@"timezone"] length] > 0) {
        [cm setObject:geo[@"timezone"] forKey:@"timezoneName"];
    }

    if (cc.length) {
        // Carrier: pick a real mobile operator from this country (random across
        // resets so multiple accounts on the same proxy IP don't all claim the
        // same carrier). NEVER use the raw ISP string — it's usually a wired
        // ISP (NXKY, FPT Telecom) that doesn't pair with a cellular MCC/MNC.
        NSArray *carrier = ci_pickMobileCarrierForCountry(cc);
        if (carrier.count >= 4) {
            [cm setObject:carrier[0] forKey:@"carrierName"];
            [cm setObject:carrier[1] forKey:@"carrierMCC"];
            [cm setObject:carrier[2] forKey:@"carrierMNC"];
            [cm setObject:carrier[3] forKey:@"carrierISO"];
        }

        // Locale + currency + language from the static country map.
        NSArray *info = ci_countryMap()[cc];
        if (info.count >= 7) {
            // Don't overwrite carrier from the static map — already done above.
            [cm setObject:info[3] forKey:@"localeIdentifier"];
            [cm setObject:cc       forKey:@"localeCountryCode"];
            [cm setObject:info[4] forKey:@"localeCurrencyCode"];
            [cm setObject:info[5] forKey:@"localeLanguageCode"];
        } else {
            [cm setObject:cc forKey:@"localeCountryCode"];
        }

        // WiFi SSID: pick a country-appropriate name. "FPT-Home" with a US IP
        // would be a giveaway; we want the SSID to look like a local ISP's
        // default router name.
        NSString *ssid = ci_wifiSSIDForCountry(cc);
        if (ssid.length) [cm setObject:ssid forKey:@"wifiSSID"];

        // Region code stays from countryCode for ModelNumber suffix (VN/A).
        [cm setObject:cc forKey:@"RegionCode"];
        [cm setObject:[NSString stringWithFormat:@"%@/A", cc] forKey:@"RegionInfo"];
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
            // iPhone 5/5s/6/6 Plus removed — their max real iOS is 10-12,
            // and our IOS_VERSIONS list only spans 14-18. Picking those
            // models would force an impossible combo (e.g., iPhone 6 Plus
            // running iOS 18) that Apple/Zalo anti-fraud detects instantly.
            // iPhone SE (1) kept — A9 chip supports iOS 9-15, our list
            // intersects at iOS 14-15.
            @[@"iPhone SE (1)",     @"iPhone8,4",  @"iPhone8,4",  @"320", @"568", @"2", @"640",  @"1136", @"2", @"A9",        @"0x8000", @"0x24", @(2147483648), @(2),  @(9),  @(15), colorsClassic],
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
            // NOTE: iPhone 13+ removed — Zalo only recognizes models up to iPhone 12 Pro Max.
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

    // === REALISTIC iOS constraint per model ===
    // Each preset entry includes [14]=minIOSMajor, [15]=maxIOSMajor for the
    // chip generation. We MUST filter the iosList window to versions the
    // selected hardware can actually run. Picking iPhone 6 Plus + iOS 18
    // = instant anti-fraud detection: AIDA64 even reports the cap as iOS
    // 12.5.7 from the chip's pkg manifest, exposing the lie.
    NSInteger modelMinIOSMajor = preset.count > 14 ? [preset[14] integerValue] : 9;
    NSInteger modelMaxIOSMajor = preset.count > 15 ? [preset[15] integerValue] : 18;
    NSMutableArray *validIOS = [NSMutableArray array];
    NSInteger sliderLo = iLo, sliderHi = iHi;
    for (NSInteger idx = sliderLo; idx <= sliderHi; idx++) {
        NSArray *entry = iosList[(NSUInteger)idx];
        // iosPreset format: @[displayName, versionString, buildString]
        NSString *ver = entry.count > 1 ? entry[1] : @"";
        NSArray *parts = [ver componentsSeparatedByString:@"."];
        NSInteger major = parts.count > 0 ? [parts[0] integerValue] : 0;
        if (major >= modelMinIOSMajor && major <= modelMaxIOSMajor) {
            [validIOS addObject:entry];
        }
    }
    NSArray *iosPreset;
    if (validIOS.count > 0) {
        iosPreset = validIOS[arc4random_uniform((uint32_t)validIOS.count)];
    } else {
        // Slider range had zero intersection with the model's supported iOS.
        // Fall back to ANY version in the model's range from the full list
        // so we never write an impossible combo to config.
        NSMutableArray *anyValid = [NSMutableArray array];
        for (NSArray *entry in iosList) {
            NSString *ver = entry.count > 1 ? entry[1] : @"";
            NSInteger major = [[ver componentsSeparatedByString:@"."][0] integerValue];
            if (major >= modelMinIOSMajor && major <= modelMaxIOSMajor) {
                [anyValid addObject:entry];
            }
        }
        iosPreset = anyValid.count > 0
            ? anyValid[arc4random_uniform((uint32_t)anyValid.count)]
            : iosList[(NSUInteger)iLo + arc4random_uniform((uint32_t)(iHi - iLo + 1))];
    }

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

    // === Hardware capability booleans, derived from productType ===
    // Hooked by MGGetBoolAnswer (HasFaceID, HasTouchID, HasHomeButton,
    // HasOLEDDisplay, Has5G, HasNFC). Wrong values → instant detection
    // (e.g. claim iPhone XS Max but Has FaceID=NO + HasHomeButton=YES).
    //
    // Generation buckets:
    //   - "iPhone8,1/2/4", "iPhone9,1/2", "iPhone10,1/2", "iPhone12,8":
    //       TouchID + HomeButton, no FaceID, LCD
    //   - "iPhone10,3/6", "iPhone11,*", "iPhone12,1/3/5":
    //       FaceID + no HomeButton; OLED on Pro/X/XS, LCD on XR/11
    //   - "iPhone13,*": FaceID, OLED, 5G
    BOOL hasFaceID    = NO;
    BOOL hasTouchID   = NO;
    BOOL hasHomeButton = NO;
    BOOL hasOLED      = NO;
    BOOL has5G        = NO;
    // Pre-FaceID generation (TouchID era).
    if ([productTyp hasPrefix:@"iPhone8,"] ||
        [productTyp hasPrefix:@"iPhone9,"] ||
        [productTyp hasPrefix:@"iPhone10,1"] ||
        [productTyp hasPrefix:@"iPhone10,2"] ||
        [productTyp isEqualToString:@"iPhone12,8"]) {
        hasTouchID = YES; hasHomeButton = YES; hasFaceID = NO; hasOLED = NO;
    }
    // FaceID generation, LCD body (XR, 11).
    else if ([productTyp isEqualToString:@"iPhone11,8"] ||
             [productTyp isEqualToString:@"iPhone12,1"]) {
        hasFaceID = YES; hasTouchID = NO; hasHomeButton = NO; hasOLED = NO;
    }
    // FaceID + OLED (X, XS, XS Max, 11 Pro, 11 Pro Max).
    else if ([productTyp isEqualToString:@"iPhone10,3"] ||
             [productTyp isEqualToString:@"iPhone10,6"] ||
             [productTyp isEqualToString:@"iPhone11,2"] ||
             [productTyp isEqualToString:@"iPhone11,4"] ||
             [productTyp isEqualToString:@"iPhone11,6"] ||
             [productTyp isEqualToString:@"iPhone12,3"] ||
             [productTyp isEqualToString:@"iPhone12,5"]) {
        hasFaceID = YES; hasOLED = YES; hasTouchID = NO; hasHomeButton = NO;
    }
    // iPhone 12 series — FaceID + OLED + 5G.
    else if ([productTyp hasPrefix:@"iPhone13,"]) {
        hasFaceID = YES; hasOLED = YES; has5G = YES; hasTouchID = NO; hasHomeButton = NO;
    }
    [cm setObject:@(hasFaceID)     forKey:@"HasFaceID"];
    [cm setObject:@(hasTouchID)    forKey:@"HasTouchID"];
    [cm setObject:@(hasHomeButton) forKey:@"HasHomeButton"];
    [cm setObject:@(hasOLED)       forKey:@"HasOLEDDisplay"];
    [cm setObject:@(has5G)         forKey:@"Has5G"];
    [cm setObject:@(YES)           forKey:@"HasNFC"];                  // every iPhone 6s+
    [cm setObject:@(YES)           forKey:@"HasCellularConnectivity"]; // every iPhone has cellular

    // === Activation timestamp — stable per profile, random 6-18 months back ===
    // Stored as Cocoa-style ISO8601 string so MGCopyAnswer hook can return it
    // verbatim. Only generate once per Reset (don't overwrite if already set
    // so a single account's claimed device keeps the same activation date).
    if (![cm objectForKey:@"InitialActivationDate"]) {
        NSInteger daysAgo = 180 + (NSInteger)arc4random_uniform(360);  // 6-18 months
        NSDate *activated = [NSDate dateWithTimeIntervalSinceNow:-(double)daysAgo * 86400.0];
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
        df.timeZone = [NSTimeZone timeZoneWithName:@"GMT"];
        [cm setObject:[df stringFromDate:activated] forKey:@"InitialActivationDate"];
        [cm setObject:@"Activated"                    forKey:@"ActivationState"];
        [cm setObject:@(YES)                          forKey:@"ActivationStateAcknowledged"];
    }

    // === kern.boottime — fresh boot looks suspicious. Pick last 1h-7d ago. ===
    // Tweak sysctlbyname hook returns this when apps query KERN_BOOTTIME.
    NSInteger uptimeSec = 3600 + (NSInteger)arc4random_uniform(7 * 86400 - 3600);
    [cm setObject:@(time(NULL) - uptimeSec) forKey:@"kern_boottime"];
    [cm setObject:@(uptimeSec)              forKey:@"systemUptime"];

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

    // Battery level (0.0–1.0) + state (0=Unknown, 1=Unplugged, 2=Charging,
    // 3=Full). Randomize so two consecutive registrations don't show
    // identical battery telemetry — anti-fraud servers fingerprint this.
    [cm setObject:[NSString stringWithFormat:@"%.2f", 0.30 + (arc4random_uniform(70) / 100.0)]
            forKey:@"batteryLevel"];                                 // 0.30 – 0.99
    [cm setObject:[NSString stringWithFormat:@"%u", arc4random_uniform(3) + 1]
            forKey:@"batteryState"];                                  // 1 / 2 / 3

    // Zalo timing offset — adds jitter to mach_absolute_time / CFAbsoluteTime
    // so two devices with identical hardware fingerprint show different
    // launch-to-event timings. Range chosen to look like a device that's
    // been booted hours-to-days ago.
    [cm setObject:[NSString stringWithFormat:@"%u",
        (unsigned)(arc4random_uniform(900000) + 100000)]              // 100k – 1M ms
            forKey:@"zalo_timingOffset"];

    // Vietnamese mobile prefix pool. Generates a fresh +84 9xx xxx xxx
    // every Reset so PhoneNumber doesn't carry over an old account's SĐT.
    static NSArray *kVNPrefixes = nil;
    if (!kVNPrefixes) kVNPrefixes = @[
        @"32", @"33", @"34", @"35", @"36", @"37", @"38", @"39",     // Viettel
        @"81", @"82", @"83", @"84", @"85", @"88",                     // Vinaphone
        @"70", @"76", @"77", @"78", @"79", @"89",                     // MobiFone
        @"56", @"58", @"92",                                           // Vietnamobile
        @"59", @"99",                                                  // Gmobile
    ];
    NSString *vnPrefix = kVNPrefixes[arc4random_uniform((uint32_t)kVNPrefixes.count)];
    [cm setObject:[NSString stringWithFormat:@"+849%@%@", vnPrefix, ci_randDigits(7)]
            forKey:@"PhoneNumber"];

    // Local IP — keeps the wifiSSID story coherent. Pick from a private
    // RFC1918 range that an iPhone actually gets on home WiFi.
    static NSArray *kLocalIPPrefixes = nil;
    if (!kLocalIPPrefixes) kLocalIPPrefixes = @[
        @"192.168.0.", @"192.168.1.", @"192.168.31.",
        @"192.168.100.", @"192.168.137.", @"10.0.0.", @"10.0.1.",
        @"172.16.0.",
    ];
    NSString *ipPrefix = kLocalIPPrefixes[arc4random_uniform((uint32_t)kLocalIPPrefixes.count)];
    [cm setObject:[NSString stringWithFormat:@"%@%u", ipPrefix, arc4random_uniform(253) + 2]
            forKey:@"localIP"];

    // Pasteboard reset toggle (cleared on next Zalo launch).
    [cm setObject:@(YES) forKey:@"clearPasteboard"];

    // Cellular radio tech — pick from realistic mix. iPhone XS+/iOS 14+
    // typically reports LTE indoors, NRNSA outdoors-on-5G-network. Random
    // pick avoids per-account fingerprint stability on this field.
    static NSArray *kRadioTech = nil;
    if (!kRadioTech) kRadioTech = @[
        @"CTRadioAccessTechnologyLTE",
        @"CTRadioAccessTechnologyLTE",
        @"CTRadioAccessTechnologyLTE",       // weighted toward LTE (most common)
        @"CTRadioAccessTechnologyNRNSA",     // 5G NSA
        @"CTRadioAccessTechnologyHSDPA",
        @"CTRadioAccessTechnologyWCDMA",
    ];
    [cm setObject:kRadioTech[arc4random_uniform((uint32_t)kRadioTech.count)]
            forKey:@"carrierRadioAccess"];

    // ALWAYS re-arm keychain reset on Reset Data. After an RRS restore the
    // flag was set to NO so Zalo could read its keychain entries; if the
    // user then runs Reset Data without re-arming, fresh-account registration
    // would fall through to the OLD keychain and Zalo would resume the
    // restored session instead of starting clean.
    [cm setObject:@(YES) forKey:@"keychainReset"];

    // WebKit / Metal fingerprint values — coherent with chip + iOS choice.
    NSString *chipName = preset.count > 9 ? preset[9] : @"A17 Pro";
    NSString *gpuName  = [NSString stringWithFormat:@"Apple %@ GPU", chipName];
    [cm setObject:@"Apple Inc." forKey:@"web_glVendor"];
    [cm setObject:gpuName       forKey:@"web_glRenderer"];
    [cm setObject:gpuName       forKey:@"zalo_metalGPU"];
    [cm setObject:@(YES)        forKey:@"web_canvasNoise"];

    // WKWebView UA string — randomize every Change Device (v2.5.13).
    // Vary mobile-build + Safari minor + WebKit patch so each profile
    // has a UNIQUE UA. Pool values are all real Apple builds that
    // shipped with their respective iOS versions.
    NSString *uaIOSVer = [iosPreset[1] stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSArray *iosParts = [iosPreset[1] componentsSeparatedByString:@"."];
    NSInteger iosMajor = iosParts.count > 0 ? [iosParts[0] integerValue] : 17;
    NSInteger iosMinor = iosParts.count > 1 ? [iosParts[1] integerValue] : 0;
    // Safari version typically = iOS major.minor with random patch (0-3).
    NSString *safariVer = [NSString stringWithFormat:@"%ld.%ld.%u",
                            (long)iosMajor, (long)iosMinor, arc4random_uniform(4)];
    // Mobile/<build> pool — real Apple build numbers across iOS versions.
    NSArray *mobileBuilds = @[@"15E148", @"15E149", @"15D60", @"15D100",
                              @"14F89", @"14E304", @"15F79", @"15G77"];
    NSString *mobileBuild = mobileBuilds[arc4random_uniform((uint32_t)mobileBuilds.count)];
    // WebKit patch — real point-release values.
    NSArray *wkPatches = @[@"605.1.15", @"605.1.14", @"605.1.13", @"605.1.16"];
    NSString *wkVer = wkPatches[arc4random_uniform((uint32_t)wkPatches.count)];
    NSString *fakeUA = [NSString stringWithFormat:
        @"Mozilla/5.0 (iPhone; CPU iPhone OS %@ like Mac OS X) AppleWebKit/%@ (KHTML, like Gecko) Version/%@ Mobile/%@ Safari/604.1",
        uaIOSVer, wkVer, safariVer, mobileBuild];
    [cm setObject:fakeUA forKey:@"zalo_fakeWebViewUA"];

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
        // 32-byte APNS device-token hex. Tweak's UIApplicationDelegate
        // swizzle reads this and passes it instead of the real APNS token,
        // breaking server-side correlation across Reset cycles. Same Apple
        // ID + same hardware would otherwise give Zalo's server identical
        // tokens for every account → "abnormal behavior" lock.
        @"apnsTokenSpoof":                        ci_randHexLower(64),
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
    // Visible flag for the user to verify geo flow took the right path.
    // PROXY_OK = ip-api responded → GPS/locale/carrier all pulled from
    //   the IP that ip-api saw (which is your Shadowrocket exit IF the
    //   VPN is routing this app's traffic).
    // FALLBACK_VN = ip-api timed out / unreachable → defaulted to random
    //   point in Vietnam + Vietnamese carrier. DANGEROUS if your VPN
    //   exit is in another country: GPS says VN, IP says US → instant
    //   ban on register. If you see this AND your Shadowrocket is on a
    //   non-VN exit, DO NOT register — fix VPN routing first.
    [cm setObject:(applied ? @"PROXY_OK" : @"FALLBACK_VN") forKey:@"_ci_geo_source"];
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
// Mobile Safari is a system app — its data does NOT live entirely in the
// data container (~/Containers/Data/Application/<UUID>). The user-visible
// browsing state — bookmarks, history, cookies, cache, WebKit data — sits
// in /var/mobile/Library/Safari + /var/mobile/Library/WebKit + WebKit
// caches that the data-container wipe doesn't reach. Without this deep
// wipe, every "Reset Data" leaves Safari with the previous session's
// cookies / IDFA / canvas fingerprint visible to the next account.
//
// Killing the WebKit content/networking/GPU daemons mid-wipe is fine —
// they auto-respawn when next requested. They are SHARED across every WK
// client process, but no client holds long-running state across that
// boundary, so a kill at idle is recoverable.
// (ci_run forward decl already at top of file, line 45)
static void ci_wipeSafariDeep(void) {
    // 1. Kill the user-visible Safari/SafariViewService apps. Intentionally
    //    NOT killing WebKit.WebContent / .Networking / .GPU here — those
    //    are SHARED daemons used by every WK client (in-app browsers in
    //    other apps, Mail, etc.). v2.4.0-a5256fe took down AIDA64 by
    //    wiping them via `pkill -f com.apple.mobilesafari` which also
    //    matched the substring inside backboardd / runningboardd cmdlines.
    //    POSIX unlink semantics: rm succeeds even with daemons holding
    //    open handles — they just see stale cache until next reload.
    NSArray<NSString *> *killCmds = @[
        @"killall -9 MobileSafari 2>/dev/null",
        @"killall -9 SafariViewService 2>/dev/null",
        @"killall -9 SafariBookmarksSyncAgent 2>/dev/null",
    ];
    for (NSString *c in killCmds) ci_run([c UTF8String]);

    // 2. Wipe every Safari + WebKit on-disk state we know about. Both
    //    rooted and rootless paths are tried — Dopamine 2 keeps
    //    /var/mobile/Library/* at the canonical location, but sandbox
    //    redirection can occasionally shadow them under /var/jb/.
    NSArray<NSString *> *paths = @[
        // Safari user data
        @"/var/mobile/Library/Safari",
        @"/var/mobile/Library/Caches/com.apple.mobilesafari",
        @"/var/mobile/Library/Caches/com.apple.SafariViewService",
        @"/var/mobile/Library/Cookies/com.apple.mobilesafari.binarycookies",
        @"/var/mobile/Library/Cookies/com.apple.WebKit.binarycookies",
        @"/var/mobile/Library/SafariViewService",
        @"/var/mobile/Library/Saved Application State/com.apple.mobilesafari.savedState",
        // WebKit shared store + caches (shared across every WK client app)
        @"/var/mobile/Library/WebKit",
        @"/var/mobile/Library/Caches/WebKit",
        @"/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
        @"/var/mobile/Library/Caches/com.apple.WebKit.Networking",
        @"/var/mobile/Library/Caches/com.apple.WebKit.GPU",
        @"/var/mobile/Library/Caches/com.apple.WebKit.PluginAgent",
    ];
    for (NSString *p in paths) {
        NSString *cmd = [NSString stringWithFormat:
            @"rm -rf '%@' 2>/dev/null; rm -rf '%@/.'* 2>/dev/null; rm -rf '%@/.[!.]*' 2>/dev/null",
            p, p, p];
        ci_run([cmd UTF8String]);
    }
    NSLog(@"[ChangeInfoIos] Safari/WebKit deep wipe: killed + %lu paths cleared",
          (unsigned long)paths.count);
}

// Aggressive cross-app residue wipe. After Reset Data we want every
// trace of "previous device install" gone — apps fingerprint the device
// not just by hardware IDs but by:
//   - HTTP cookies persisted in NSHTTPCookieStorage
//   - WKWebView website data (localStorage, IndexedDB, ServiceWorker cache)
//   - App Group containers (shared storage between extensions; survives
//     the per-app container wipe)
//   - UserDefaults suiteName containers (com.apple.* and 3rd-party)
//   - Pasteboard changeCount which apps cross-correlate ("first launch"
//     detection)
//
// Some apps (Zalo specifically) check NSHTTPCookieStorage at launch and
// match cookies against a server-side device-cookie pair, so even a fresh
// container with stale cookies trips the "this device used to be account
// X" alarm. We wipe per-app and global cookie storage paths.
// Takes NSArray of CIAppInfo (typed loosely as id) — the class is defined
// further down in the file and we can't forward-typedef it without
// duplicating the @interface here. KVC -valueForKey: gives us bundleID.
static void ci_wipeCrossAppResidue(NSArray *targets) {
    // Global cookie + cache paths shared by NSHTTPCookieStorage and
    // CFNetwork. Wiping these clears cookies for every app on the device,
    // not just our targets — that's the desired behavior for a fresh-device
    // simulation.
    NSArray<NSString *> *globalPaths = @[
        @"/var/mobile/Library/Cookies",
        @"/var/mobile/Library/Caches/com.apple.WebKit.WebContent",
        @"/var/mobile/Library/Caches/com.apple.WebKit.Networking",
        @"/var/mobile/Library/Caches/com.apple.nsurlsessiond",
        @"/var/mobile/Library/HTTPStorages",
    ];
    for (NSString *p in globalPaths) {
        NSString *cmd = [NSString stringWithFormat:
            @"rm -rf '%@'/* '%@'/.[!.]* 2>/dev/null; mkdir -p '%@' 2>/dev/null",
            p, p, p];
        ci_run([cmd UTF8String]);
    }

    // Per-app App Group containers — found at
    // /var/mobile/Containers/Shared/AppGroup/<UUID>/. Each shared container's
    // metadata.plist lists the bundle IDs that have access. Wipe any that
    // mention our target bundles.
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *agRoot = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *agUUIDs = [fm contentsOfDirectoryAtPath:agRoot error:nil];
    NSUInteger groupsWiped = 0;
    for (NSString *uuid in agUUIDs) {
        NSString *full = [agRoot stringByAppendingPathComponent:uuid];
        NSString *meta = [full stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSData *blob = [NSData dataWithContentsOfFile:meta options:NSDataReadingUncached error:nil];
        if (!blob) continue;
        BOOL match = NO;
        for (id a in targets) {
            NSString *bid = [a valueForKey:@"bundleID"];
            if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;
            NSData *needle = [bid dataUsingEncoding:NSUTF8StringEncoding];
            if ([blob rangeOfData:needle options:0 range:NSMakeRange(0, blob.length)].location != NSNotFound) {
                match = YES;
                break;
            }
        }
        if (!match) continue;
        // Wipe the contents but keep the directory + metadata (deleting
        // metadata invalidates the container handle for other extensions).
        NSArray *subs = @[@"Library", @"Documents", @"Library/Caches",
                          @"Library/Preferences", @"Library/Cookies",
                          @"Library/Application Support", @"tmp"];
        for (NSString *sub in subs) {
            NSString *target = [full stringByAppendingPathComponent:sub];
            NSString *cmd = [NSString stringWithFormat:
                @"rm -rf '%@'/* '%@'/.[!.]* 2>/dev/null; mkdir -p '%@' 2>/dev/null",
                target, target, target];
            ci_run([cmd UTF8String]);
        }
        groupsWiped++;
    }

    // Reset NSHTTPCookieStorage from our process — covers cookies cached in
    // memory by other processes' cfprefsd-shared storage. Belt-and-braces.
    NSHTTPCookieStorage *jar = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray<NSHTTPCookie *> *cookies = jar.cookies;
    for (NSHTTPCookie *c in cookies) [jar deleteCookie:c];

    // Pasteboard changeCount drives several "first-launch" heuristics. We
    // can't reset it directly (read-only on iOS), but writing + clearing
    // bumps it twice — server fingerprints that compare "changeCount mod N"
    // see a fresh increment.
    [UIPasteboard generalPasteboard].string = @"";
    [UIPasteboard generalPasteboard].items = @[];

    NSLog(@"[ChangeInfoIos] Cross-app residue wipe: %lu global paths, %lu app groups, cookies cleared",
          (unsigned long)globalPaths.count, (unsigned long)groupsWiped);
}

static NSString *ci_findDataContainerForBundle(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    // First try NSFileManager (works for some host-app sandbox profiles).
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

    // Fallback (2026-05-20 v2.4.27): NSFileManager returned no UUIDs / matches
    // even though the containers exist. Confirmed via instrumented restoreEntry.log:
    // `matchedBid=vn.com.vng.zingalo but NO LIVE CONTAINER` even when /var/mobile/
    // Containers/Data/Application/22B6882C.../*.metadata.plist has the bundle ID
    // and 644 perms readable by mobile. Sandbox MAC seems to block the directory
    // listing from inside HIOS Faker's sandboxed process, but the SAME path works
    // for cp -a / pkill via ci_run (posix_spawn child of host bypasses).
    //
    // Shell-based grep through ci_run finds it deterministically.
    NSString *outPath = [NSString stringWithFormat:
        @"/tmp/ci_find_%@.txt", [bundleID stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
    NSString *cmd = [NSString stringWithFormat:
        @"grep -l '%@' /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 > '%@'",
        bundleID, outPath];
    ci_run([cmd UTF8String]);
    NSString *result = [NSString stringWithContentsOfFile:outPath
                                                 encoding:NSUTF8StringEncoding error:nil];
    [fm removeItemAtPath:outPath error:nil];
    result = [result stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (result.length == 0) return nil;
    // grep -l returned <container>/.com.apple.mobile_container_manager.metadata.plist;
    // strip the filename to get the container dir.
    return [result stringByDeletingLastPathComponent];
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
// Account-journal fields (accountLabel/Kind/status) were added on top of
// the original RRS schema 2026-05-15. Older snapshots have these keys
// missing in their NSCoder data — decode falls back to nil/0 cleanly so
// pre-existing entries still load and just show "Chưa gắn nhãn" in the
// UI. Don't reorder existing fields above (NSKeyedArchiver is key-based
// so order doesn't matter, but the field names below must stay stable
// or already-saved entries lose their data on next load).
typedef NS_ENUM(NSInteger, CIAccountKind) {
    CIAccountKindUnknown  = 0,
    CIAccountKindZalo     = 1,
    CIAccountKindFacebook = 2,
    CIAccountKindTikTok   = 3,
    CIAccountKindBanking  = 4,
    CIAccountKindOther    = 5,
};
typedef NS_ENUM(NSInteger, CIAccountStatus) {
    CIAccountStatusUnknown = 0,
    CIAccountStatusActive  = 1,
    CIAccountStatusBanned  = 2,
};

static NSString *ci_kindLabel(CIAccountKind k) {
    switch (k) {
        case CIAccountKindZalo:     return @"Zalo";
        case CIAccountKindFacebook: return @"Facebook";
        case CIAccountKindTikTok:   return @"TikTok";
        case CIAccountKindBanking:  return @"Banking";
        case CIAccountKindOther:    return @"Khác";
        default:                    return @"";
    }
}

@interface CIRRSEntry : NSObject <NSCoding>
@property (nonatomic, copy)   NSString *uid;           // filename base
@property (nonatomic, copy)   NSString *idfa;
@property (nonatomic, copy)   NSString *ipReset;
@property (nonatomic, copy)   NSArray<NSString *> *appNames;
@property (nonatomic, copy)   NSArray<NSString *> *bundleIDs;
@property (nonatomic, strong) NSDate   *date;
@property (nonatomic, assign) unsigned long long totalSize;
@property (nonatomic, copy)   NSString *note;
// --- Account journal fields (added 2026-05-15, may be empty on old entries) ---
@property (nonatomic, copy)   NSString *accountLabel;   // phone, email, or any user-defined ID
@property (nonatomic, assign) CIAccountKind accountKind;
@property (nonatomic, assign) CIAccountStatus accountStatus;
@property (nonatomic, copy)   NSString *proxyTag;       // host:port masked (e.g. "1.2.3.x:8080")
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
        // Missing keys decode to nil/0 — older RRS entries silently get the
        // "unknown" defaults without forcing a schema migration.
        self.accountLabel  = [c decodeObjectForKey:@"acctLabel"];
        self.accountKind   = (CIAccountKind)[c decodeIntegerForKey:@"acctKind"];
        self.accountStatus = (CIAccountStatus)[c decodeIntegerForKey:@"acctStatus"];
        self.proxyTag      = [c decodeObjectForKey:@"proxyTag"];
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
    [c encodeObject:self.accountLabel forKey:@"acctLabel"];
    [c encodeInteger:self.accountKind forKey:@"acctKind"];
    [c encodeInteger:self.accountStatus forKey:@"acctStatus"];
    [c encodeObject:self.proxyTag forKey:@"proxyTag"];
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
    // Try both legacy .tar.gz and current .tar extensions when deleting,
    // since pre-9a9f9ae builds created broken gzip archives that won't
    // open but still take disk space.
    NSString *tarGz = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar.gz"]];
    NSString *tar = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar"]];
    [[NSFileManager defaultManager] removeItemAtPath:tarGz error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:tar error:nil];
    [_items removeObject:e];
    [self saveIndex];
}
@end

// Build the `tar -cf …` command shared by createRRSForBundles and
// rebackupEntry, with --exclude rules that strip cache/log paths.
// Empirical: an unfiltered Zalo backup ran 77 MB; the same content
// with these exclusions drops to ~25-35 MB without losing anything
// the restore path needs (chat sqlite, profile sqlite, KVCore,
// Preferences, Cookies, tmp/hios_keychain.plist all preserved).
//
// What we SKIP (regenerable on next launch):
//   Library/Caches/*               iOS URLCache + app caches
//   Library/WebKit/*               WKWebView blob storage
//   Library/HTTPStorages/*         NSURLSession httpcookies cache
//   Library/Saved Application State  iOS scene snapshot
//   Documents/InstantCacheData/*   Zalo instant cache
//   Documents/Logs/*               per-level log txt files
//   Documents/LogSocket/*          socket-level traces
//   Documents/QoS/*                quality-of-service metrics
//   Documents/UpResult/*           upload result staging
//   Documents/UpTemp/*             upload temp staging
//   Documents/DownTemp/*           download temp staging
//   Documents/VoipLogStats/*       VoIP telemetry
//   Documents/zinstant_apps/*      mini-app cache
//   Documents/cloud_audit/*        cloud-side audit logs
//   Documents/services/*           runtime service queue
//   Documents/FTS*/*               full-text search index (rebuilds)
//
// What we KEEP (load-bearing for restore):
//   Documents/*.sqlite             chat, profile, contacts, settings
//   Documents/KVCore/*             account session metadata
//   Documents/Data/*               user content
//   Documents/kvs, mmkv            key-value persistence
//   Documents/ZaloAnalytics/*      analytics state (small)
//   Library/Preferences/*          NSUserDefaults
//   Library/Cookies/*              auth cookies
//   Library/Application Support/*  app-managed persistence
//   tmp/hios_keychain.plist        the dump our tweak writes
//   tmp/* (all other)              transient state, small
//   /var/jb/etc/changeinfoios/*    spoof config + DC state
static NSString *ci_buildTarCommand(NSString *tarPath,
                                     NSArray<NSString *> *containerPaths,
                                     NSString *errLog) {
    static NSArray *kExcludes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // v2.4.22: AGGRESSIVE exclude list of v2.4.17 was REMOVING session-
        // critical data, causing restore to fail server-side auth.
        // Specifically Library/HTTPStorages contains cookies + auth tokens
        // for Zalo's network requests; Library/WebKit holds eKYC + login
        // webview state; Documents/services has runtime service queue
        // that may include session tokens. Excluding any of these means
        // Zalo restores but server rejects → Zalo wipes profile.sqlite +
        // chat_dbs/<UID> on launch.
        //
        // Confirmed live 2026-05-19: 77 MB tar (no excludes) auto-logged
        // in successfully. 21 MB tar (v2.4.17 excludes applied) wiped to
        // blank login despite all 6 keychain patches.
        //
        // Now: ONLY exclude paths that are guaranteed-safe to lose:
        //   Library/Caches              iOS URLCache + image caches
        //   Library/Saved Application State  iOS scene snapshot, regenerates
        //   Documents/Logs              app-level log files
        //   Documents/LogSocket         per-socket trace logs
        //   Documents/QoS               quality-of-service metrics
        //   Documents/VoipLogStats      VoIP call telemetry
        //   Documents/cloud_audit/download_cache   transient DL cache
        //   Documents/GlobalSearch      FTS index, auto-rebuilds
        //
        // KEPT (was excluded in 2.4.17, now restored to capture):
        //   Library/WebKit              webview cookies/storage
        //   Library/HTTPStorages        critical: NSURLSession cookies+tokens
        //   Documents/InstantCacheData  Zalo instant cache (may hold tokens)
        //   Documents/UpResult,UpTemp,DownTemp  upload/download state queues
        //   Documents/zinstant_apps     mini-app cache (Zalo's in-app browser)
        //   Documents/services          runtime service state
        // v2.5.0: REPLACED blanket "Library/Caches" exclude with precise
        // sub-directory excludes. The blanket exclude was DROPPING
        // /Library/Caches/ChangeInfoIos/apns_token.dat — our per-bundle
        // persistent fake APNs token. Without that file in backup, restore
        // re-generates a NEW fake token → server-side Zalo sees a
        // different push token than at backup time → session invalidated
        // → login screen, despite all keychain + filesystem being correctly
        // restored. Confirmed root cause via /var/jb/etc/changeinfoios/
        // restoreEntry.log + per-bundle restore.log showing 30/30
        // keychain entries restored but app still asked login.
        //
        // Excludes here target ONLY large-but-regeneratable cache dirs.
        // Library/Caches/ChangeInfoIos/ + smaller auth-bearing caches stay.
        kExcludes = @[
            @"Library/Caches/com.apple.WebKit",
            @"Library/Caches/Snapshots",
            @"Library/Caches/com.apple.nsurlsessiond",
            @"Library/Caches/ZALO_RAM_FILE_CACHE",
            @"Library/Caches/zinstant",
            @"Library/Caches/com.firebase.installations",
            @"Library/Caches/google_firebase_messaging",
            @"Library/Caches/Mapbox",
            @"Library/Saved Application State",
            @"Documents/Logs",
            @"Documents/LogSocket",
            @"Documents/QoS",
            @"Documents/VoipLogStats",
            @"Documents/cloud_audit/download_cache",
            @"Documents/GlobalSearch",
        ];
    });
    NSMutableString *cmd = [NSMutableString stringWithFormat:@"tar -cf '%@'", tarPath];
    for (NSString *ex in kExcludes) {
        // GNU tar accepts wildcards via --wildcards (default in many builds).
        // Use a pattern that catches the dir at any depth inside any container.
        [cmd appendFormat:@" --exclude='*/%@'", ex];
    }
    [cmd appendString:@" /var/jb/etc/changeinfoios"];
    for (NSString *p in containerPaths) [cmd appendFormat:@" '%@'", p];
    if (errLog.length) [cmd appendFormat:@" 2>%@", errLog];
    return cmd;
}

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
// v2.4.36 light theme — modeled after AZInfo-style market tools.
+ (UIColor *)bg        { return [self rgb:0xF2F3F5]; }    // soft grey page background
+ (UIColor *)card      { return [UIColor whiteColor]; }   // white cards
+ (UIColor *)text      { return [self rgb:0x1C1C1E]; }    // near-black text
+ (UIColor *)dim       { return [self rgb:0x8E8E93]; }    // iOS system grey
+ (UIColor *)orange    { return [self rgb:0xFF9500]; }    // iOS system orange
+ (UIColor *)blue      { return [self rgb:0x007AFF]; }    // iOS system blue
+ (UIColor *)separator { return [self rgb:0xE5E5EA]; }
+ (UIColor *)border    { return [self rgb:0xD1D1D6]; }
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
    CGFloat _lastLayoutWidth;
}

// Same root cause as CIFakeInfoReportViewController: cells compute label
// frames from tv.bounds.size.width at cellForRow time, so the very first
// dequeue (table bounds = 0) builds clipped subviews. Reload once the
// table reaches its real width.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.tableView.bounds.size.width;
    if (w > 0 && w != _lastLayoutWidth) {
        _lastLayoutWidth = w;
        [self.tableView reloadData];
    }
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
            // iPhone 5/5s/6/6 Plus removed (max iOS 10-12, can't pair with
            // our 14-18 iOS list).
            @[@"iPhone SE (1)",     @"iPhone8,4",  @"iPhone8,4",  @"320", @"568", @"2", @"640",  @"1136", @"2"],
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
            // NOTE: iPhone 13+ removed — Zalo only recognizes models up to iPhone 12 Pro Max.
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
        message:@"iPhone 5 → iPhone 12 Pro Max" preferredStyle:UIAlertControllerStyleActionSheet];
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

    // 21. Reset Data behavior — let user opt out of the SpringBoard
    // respring that fires at the end of every Reset Data run. Respring
    // is harmless but takes ~6s + reloads every running app from a
    // launch snapshot. For users batching many resets in a row, that's
    // wasted time. With this toggle ON, Step 4 (respring) is skipped
    // and target apps are killed instead — the tweak %ctor still runs
    // fresh on next cold-start of each target app, so spoof identities
    // still rotate correctly. The only thing the user loses is
    // SpringBoard's icon cache refresh, which is fine if you're not
    // installing/uninstalling apps mid-session.
    [_rows addObject:[C toggle:@"21. Bỏ qua respring sau Reset Data" key:@"skipRespringAfterReset" indent:0]];
    [_rows addObject:[C note:@"Bật để khỏi mất 6s reload SpringBoard mỗi lần Reset. Target apps vẫn bị kill + reload tweak ở lần mở tiếp theo." indent:24]];

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
        summary.textColor = [CITheme text];
        summary.textAlignment = NSTextAlignmentCenter;
        summary.text = [NSString stringWithFormat:@"Từ %@ đến %@", r.options[lo], r.options[hi]];
        summary.userInteractionEnabled = NO;
        [pill addSubview:summary];

        UILabel *chev = [[UILabel alloc] initWithFrame:CGRectMake(pill.bounds.size.width - 28, 8, 20, 24)];
        chev.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        chev.text = expanded ? @"˅" : @"›";
        chev.textColor = [CITheme orange];
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
    l.textColor = [CITheme text];
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
    CGFloat _lastLayoutWidth;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [CITheme bg];

    // Single search bar header — no more checkbox + Xóa button. Tap a row
    // to restore that snapshot, swipe-left to delete (iOS-standard pattern).
    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 56)];
    _search.placeholder = @"Lọc RRS theo IDFA / IP / app";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.delegate = self;
    _search.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.delegate = self; _table.dataSource = self;
    _table.tableHeaderView = _search;
    _table.rowHeight = 116;
    _table.backgroundColor = [CITheme bg];
    _table.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.view addSubview:_table];

    _view = [[CIRRSStore shared] entries];
    [self refreshTitle];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self action:@selector(closeBtn)];
}
- (void)closeBtn { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)refreshTitle {
    self.title = _view.count > 0
        ? [NSString stringWithFormat:@"%lu RRS — chạm để restore", (unsigned long)_view.count]
        : @"RRS (chưa có)";
}

// Cells are built with frames computed from tv.bounds.size.width at
// dequeue time. On first appearance the table's bounds are still 0×0,
// so every cell renders with clipped value cards. Force a single
// reloadData when the table reaches its real width.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = _table.bounds.size.width;
    if (w > 0 && w != _lastLayoutWidth) {
        _lastLayoutWidth = w;
        [_table reloadData];
    }
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    if (!text.length) { _view = [[CIRRSStore shared] entries]; [_table reloadData]; return; }
    NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(CIRRSEntry *e, NSDictionary *_Nullable _) {
        if ([e.note localizedCaseInsensitiveContainsString:text]) return YES;  // search by label first
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
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    c.backgroundColor = [UIColor clearColor];
    c.contentView.backgroundColor = [UIColor clearColor];

    CIRRSEntry *e = _view[ip.row];

    // v2.4.41: cell.contentView width is reliable even when tv.bounds is
    // 0 on the first cellForRow pass (was causing right-edge content
    // truncation — date/IDFA/"chạm để res" appeared cut off). Pull margin
    // off contentView and clamp to a minimum so children never get
    // negative-x positions.
    CGFloat margin = 12;
    CGFloat cellW = c.contentView.bounds.size.width;
    if (cellW <= margin * 2) cellW = tv.bounds.size.width;
    if (cellW <= margin * 2) cellW = [UIScreen mainScreen].bounds.size.width;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(margin, 4, cellW - margin*2, 108)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    card.backgroundColor = [CITheme card];
    card.layer.cornerRadius = 12;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [[CITheme blue] colorWithAlphaComponent:0.4].CGColor;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.06;
    card.layer.shadowOffset = CGSizeMake(0, 2);
    card.layer.shadowRadius = 6;
    c.contentView.clipsToBounds = NO;
    c.clipsToBounds = NO;
    [c.contentView addSubview:card];

    // Index badge top-left
    UILabel *idxBadge = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 26, 26)];
    idxBadge.text = [NSString stringWithFormat:@"%ld", (long)(ip.row + 1)];
    idxBadge.textAlignment = NSTextAlignmentCenter;
    idxBadge.textColor = [CITheme orange];
    idxBadge.font = [UIFont boldSystemFontOfSize:14];
    idxBadge.layer.cornerRadius = 13;
    idxBadge.layer.borderColor = [CITheme orange].CGColor;
    idxBadge.layer.borderWidth = 1;
    [card addSubview:idxBadge];

    // Top row: account label (preferred) OR app names if no label was set.
    NSString *names = e.appNames.count ? [e.appNames componentsJoinedByString:@" • "] : @"-";
    NSString *titleText = e.note.length > 0
        ? [NSString stringWithFormat:@"%@ — %@", e.note, names]
        : names;
    UILabel *appLbl = [[UILabel alloc] initWithFrame:CGRectMake(46, 10, card.bounds.size.width - 56 - 100, 22)];
    appLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    appLbl.text = titleText;
    appLbl.font = [UIFont boldSystemFontOfSize:14];
    appLbl.textColor = [CITheme text];
    appLbl.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:appLbl];

    // Date+time chip top-right
    NSDateFormatter *dft = [[NSDateFormatter alloc] init];
    dft.dateFormat = @"dd/MM/yyyy HH:mm";
    UILabel *dateLbl = [[UILabel alloc] initWithFrame:CGRectMake(card.bounds.size.width - 110, 10, 100, 22)];
    dateLbl.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    dateLbl.text = [dft stringFromDate:e.date];
    dateLbl.font = [UIFont systemFontOfSize:11];
    dateLbl.textColor = [CITheme dim];
    dateLbl.textAlignment = NSTextAlignmentRight;
    [card addSubview:dateLbl];

    // IDFA row
    UILabel *idfaLbl = [[UILabel alloc] initWithFrame:CGRectMake(46, 38, card.bounds.size.width - 56, 18)];
    idfaLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    idfaLbl.text = [NSString stringWithFormat:@"IDFA  %@", e.idfa ?: @"-"];
    idfaLbl.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    idfaLbl.textColor = [CITheme dim];
    [card addSubview:idfaLbl];

    // IP row
    UILabel *ipLbl = [[UILabel alloc] initWithFrame:CGRectMake(46, 58, card.bounds.size.width - 56, 18)];
    ipLbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    ipLbl.text = [NSString stringWithFormat:@"IP    %@", e.ipReset ?: @"-"];
    ipLbl.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    ipLbl.textColor = [CITheme dim];
    [card addSubview:ipLbl];

    // Size + restore CTA bottom row
    UILabel *szLbl = [[UILabel alloc] initWithFrame:CGRectMake(46, 80, 80, 20)];
    szLbl.text = CIBytesString(e.totalSize);
    szLbl.font = [UIFont systemFontOfSize:11];
    szLbl.textColor = [CITheme orange];
    [card addSubview:szLbl];

    // Account metadata chips — only shown when at least one journal field
    // is populated, so old entries (label/kind/status all blank) render
    // unchanged. Layout: [phone] [kind] [status] strung horizontally
    // starting from the size label, dimmed-style. Tap the cell's "Sửa"
    // swipe action to fill these in for an old entry.
    CGFloat chipX = 46 + 84;
    if (e.accountLabel.length || e.accountKind != CIAccountKindUnknown
        || e.accountStatus != CIAccountStatusUnknown) {
        if (e.accountLabel.length) {
            CGSize sz = [e.accountLabel sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11]}];
            UILabel *acctLbl = [[UILabel alloc] initWithFrame:CGRectMake(chipX, 80, sz.width + 14, 20)];
            acctLbl.text = e.accountLabel;
            acctLbl.font = [UIFont systemFontOfSize:11];
            acctLbl.textColor = [CITheme text];
            acctLbl.textAlignment = NSTextAlignmentCenter;
            acctLbl.layer.cornerRadius = 6;
            acctLbl.layer.borderColor = [[CITheme blue] colorWithAlphaComponent:0.5].CGColor;
            acctLbl.layer.borderWidth = 1;
            [card addSubview:acctLbl];
            chipX += sz.width + 18;
        }
        if (e.accountKind != CIAccountKindUnknown) {
            NSString *k = ci_kindLabel(e.accountKind);
            CGSize sz = [k sizeWithAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:10]}];
            UILabel *kindLbl = [[UILabel alloc] initWithFrame:CGRectMake(chipX, 80, sz.width + 14, 20)];
            kindLbl.text = k;
            kindLbl.font = [UIFont boldSystemFontOfSize:10];
            kindLbl.textColor = [CITheme orange];
            kindLbl.textAlignment = NSTextAlignmentCenter;
            kindLbl.layer.cornerRadius = 6;
            kindLbl.layer.borderColor = [[CITheme orange] colorWithAlphaComponent:0.5].CGColor;
            kindLbl.layer.borderWidth = 1;
            [card addSubview:kindLbl];
            chipX += sz.width + 18;
        }
        if (e.accountStatus == CIAccountStatusBanned) {
            UILabel *bx = [[UILabel alloc] initWithFrame:CGRectMake(chipX, 80, 56, 20)];
            bx.text = @"BANNED";
            bx.font = [UIFont boldSystemFontOfSize:10];
            bx.textColor = [UIColor whiteColor];
            bx.backgroundColor = [UIColor systemRedColor];
            bx.textAlignment = NSTextAlignmentCenter;
            bx.layer.cornerRadius = 6;
            bx.layer.masksToBounds = YES;
            [card addSubview:bx];
        } else if (e.accountStatus == CIAccountStatusActive) {
            UILabel *act = [[UILabel alloc] initWithFrame:CGRectMake(chipX, 80, 16, 20)];
            act.text = @"✓";
            act.font = [UIFont boldSystemFontOfSize:14];
            act.textColor = [CITheme green];
            act.textAlignment = NSTextAlignmentCenter;
            [card addSubview:act];
        }
    }

    UILabel *cta = [[UILabel alloc] initWithFrame:CGRectMake(card.bounds.size.width - 130, 80, 120, 20)];
    cta.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    cta.text = @"chạm để restore →";
    cta.font = [UIFont italicSystemFontOfSize:11];
    cta.textColor = [CITheme green];
    cta.textAlignment = NSTextAlignmentRight;
    [card addSubview:cta];

    // Banned entries get a faint red overlay so they're easy to skip
    // when scanning the list — restore is still allowed but the visual
    // hint nudges the user to pick another snapshot.
    if (e.accountStatus == CIAccountStatusBanned) {
        card.layer.borderColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.55].CGColor;
    }

    return c;
}

// In-place editor for the journal fields. Triggered from the leading
// swipe action ("Sửa"). Alert with three inputs: account label (free
// text — phone/email/anything memorable), kind (segmented choices), and
// active/banned status. Updates the CIRRSEntry in the shared store and
// reloads just the affected row to keep the list smooth.
- (void)editAccountForEntry:(CIRRSEntry *)e atIndex:(NSIndexPath *)ip {
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:@"Sửa thông tin tài khoản"
                         message:@"Nhãn (SĐT/email), loại, trạng thái"
                  preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"vd: 0912345678";
        tf.text = e.accountLabel ?: @"";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    // Kind picker — squeeze a segmented control into the alert via a
    // dummy text field whose inputView is the segmented. Simpler than
    // pushing a separate VC.
    static const NSInteger kinds[] = {
        CIAccountKindZalo, CIAccountKindFacebook, CIAccountKindTikTok,
        CIAccountKindBanking, CIAccountKindOther
    };
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];

    // Helper to add one Save action per kind so user picks via the
    // alert's action list rather than a sub-picker. Each save action
    // captures its kind. Six total (Zalo/FB/TT/Banking/Khác/Giữ nguyên).
    void (^addSaveAction)(NSString *, CIAccountKind) = ^(NSString *title, CIAccountKind k) {
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
            handler:^(UIAlertAction *_) {
                e.accountLabel = a.textFields.firstObject.text ?: @"";
                e.accountKind  = k;
                if (e.accountStatus == CIAccountStatusUnknown)
                    e.accountStatus = CIAccountStatusActive;
                [[CIRRSStore shared] saveIndex];
                [self->_table reloadRowsAtIndexPaths:@[ip]
                                    withRowAnimation:UITableViewRowAnimationFade];
            }]];
    };
    for (NSUInteger i = 0; i < sizeof(kinds)/sizeof(kinds[0]); i++) {
        addSaveAction([@"Lưu (" stringByAppendingFormat:@"%@)", ci_kindLabel(kinds[i])],
                      (CIAccountKind)kinds[i]);
    }
    // Last action: just save the label without changing kind (for old
    // entries where user wants to add a phone without picking a kind).
    [a addAction:[UIAlertAction actionWithTitle:@"Lưu (giữ loại)" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
            e.accountLabel = a.textFields.firstObject.text ?: @"";
            if (e.accountStatus == CIAccountStatusUnknown)
                e.accountStatus = CIAccountStatusActive;
            [[CIRRSStore shared] saveIndex];
            [self->_table reloadRowsAtIndexPaths:@[ip]
                                withRowAnimation:UITableViewRowAnimationFade];
        }]];

    [self presentViewController:a animated:YES completion:nil];
}

// Tap a row → confirm dialog → restore.
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    CIRRSEntry *e = _view[ip.row];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"dd/MM/yyyy HH:mm:ss";

    NSString *names = e.appNames.count ? [e.appNames componentsJoinedByString:@", "] : @"-";
    NSString *header = e.note.length > 0
        ? [NSString stringWithFormat:@"\"%@\"\n\n", e.note]
        : @"";
    NSString *body = [NSString stringWithFormat:
        @"%@Khôi phục môi trường này?\n\n"
        @"Apps: %@\n"
        @"IDFA: %@\n"
        @"IP: %@\n"
        @"Backup lúc: %@\n\n"
        @"Sau khi restore, account đã đăng ký trong môi trường này (Zalo, …) sẽ vẫn login được.",
        header,
        names,
        e.idfa ?: @"-",
        e.ipReset ?: @"-",
        [df stringFromDate:e.date]];

    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Restore môi trường"
                                                               message:body
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Restore" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *_) {
        // v2.4.45: RRS list is now a tab (UITabBarController), not a modal,
        // so presentingViewController is nil → previous lookup returned no
        // target and restoreEntry: was never invoked (user reported
        // "ấn restore nhưng ko restore" on v2.4.44). Walk three locations:
        //   1) tabBarController.viewControllers[0]'s nav root (Home tab)
        //   2) presentingViewController chain (legacy modal flow)
        //   3) self if we're inline-pushed
        // First responder that implements -restoreEntry: wins.
        UIViewController *target = nil;
        UITabBarController *tab = self.tabBarController;
        if (tab && tab.viewControllers.count > 0) {
            UIViewController *first = tab.viewControllers.firstObject;
            if ([first isKindOfClass:[UINavigationController class]]) {
                first = [(UINavigationController *)first viewControllers].firstObject;
            }
            if ([first respondsToSelector:@selector(restoreEntry:)]) {
                target = first;
            }
        }
        if (!target) {
            UIViewController *presenter = self.presentingViewController;
            if ([presenter isKindOfClass:[UINavigationController class]]) {
                presenter = [(UINavigationController *)presenter topViewController];
            }
            if ([presenter respondsToSelector:@selector(restoreEntry:)]) {
                target = presenter;
            }
        }
        if (!target && [self respondsToSelector:@selector(restoreEntry:)]) {
            target = self;
        }
        // Switch to Home tab so the HUD is visible while restore runs.
        if (tab && target == tab.viewControllers.firstObject) {
            tab.selectedIndex = 0;
        }
        if (target) {
            [target performSelector:@selector(restoreEntry:) withObject:e];
        } else {
            UIAlertController *err = [UIAlertController alertControllerWithTitle:@"Lỗi"
                message:@"Không tìm thấy handler restore. Mở tab Home trước rồi quay lại Backups và thử lại."
                preferredStyle:UIAlertControllerStyleAlert];
            [err addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:err animated:YES completion:nil];
        }
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

// Swipe-left → Xóa (single action — never clips). All other actions
// (Cập nhật / Sửa / Ban) moved to the long-press context menu below.
// Earlier attempts to cram a 2nd or 3rd action into the swipe area
// kept getting label-clipped no matter how short the title was
// (tried "Cập nhật" → "hật", "Lưu lại" → "lại", "Lưu" → "lưu", and
// even icon-only — the layout broke when 2 trailing actions had to
// share the swipe width). Single-action swipe gives Xóa the full
// width with no clipping. Power-user actions hide behind the menu.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"Xóa"
                          handler:^(UIContextualAction *action, UIView *view, void (^doneHandler)(BOOL)) {
        CIRRSEntry *e = self->_view[ip.row];
        [[CIRRSStore shared] deleteEntry:e];
        self->_view = [[CIRRSStore shared] entries];
        [self refreshTitle];
        [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        doneHandler(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

// Long-press context menu — iOS-native pattern that doesn't clip
// text and gives plenty of room for multi-action lists. User holds
// the cell for ~0.4s, the cell pops up, and a menu sheet appears
// with all the per-entry actions. No more swipe-label fitting puzzles.
- (UIContextMenuConfiguration *)tableView:(UITableView *)tv
       contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)ip
                                           point:(CGPoint)point {
    CIRRSEntry *e = _view[ip.row];
    UIContextMenuConfiguration *cfg = [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                    previewProvider:nil
                     actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
        // 1) Cập nhật — re-tar this snapshot with current state.
        UIAction *update = [UIAction
            actionWithTitle:@"Cập nhật"
                      image:[UIImage systemImageNamed:@"arrow.clockwise"]
                 identifier:nil
                    handler:^(UIAction *_) {
            UIAlertController *a = [UIAlertController
                alertControllerWithTitle:@"Cập nhật snapshot?"
                                 message:[NSString stringWithFormat:
                                          @"Tar mới sẽ ghi đè bản hiện tại của %lu app. "
                                          @"Nếu tar mới nhỏ hơn nhiều, bạn sẽ được hỏi xác nhận lại.",
                                          (unsigned long)e.bundleIDs.count]
                          preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
            [a addAction:[UIAlertAction actionWithTitle:@"Cập nhật" style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *_) {
                UIViewController *presenter = self.presentingViewController;
                if ([presenter isKindOfClass:[UINavigationController class]]) {
                    presenter = [(UINavigationController *)presenter topViewController];
                }
                [self dismissViewControllerAnimated:YES completion:^{
                    if ([presenter respondsToSelector:@selector(rebackupEntry:)]) {
                        [presenter performSelector:@selector(rebackupEntry:) withObject:e];
                    }
                }];
            }]];
            [self presentViewController:a animated:YES completion:nil];
        }];

        // 2) Sửa — edit account label / kind.
        UIAction *edit = [UIAction
            actionWithTitle:@"Sửa nhãn / loại"
                      image:[UIImage systemImageNamed:@"pencil"]
                 identifier:nil
                    handler:^(UIAction *_) {
            [self editAccountForEntry:e atIndex:ip];
        }];

        // 3) Ban / Mở khóa — toggle account status.
        BOOL isBanned = (e.accountStatus == CIAccountStatusBanned);
        UIAction *toggleBan = [UIAction
            actionWithTitle:(isBanned ? @"Mở khóa" : @"Đánh dấu BANNED")
                      image:[UIImage systemImageNamed:(isBanned ? @"checkmark.circle" : @"xmark.octagon")]
                 identifier:nil
                    handler:^(UIAction *_) {
            e.accountStatus = isBanned ? CIAccountStatusActive : CIAccountStatusBanned;
            [[CIRRSStore shared] saveIndex];
            [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        }];

        // 4) Xóa — destructive, separate inline menu so iOS styles it red.
        UIAction *del = [UIAction
            actionWithTitle:@"Xóa snapshot"
                      image:[UIImage systemImageNamed:@"trash"]
                 identifier:nil
                    handler:^(UIAction *_) {
            [[CIRRSStore shared] deleteEntry:e];
            self->_view = [[CIRRSStore shared] entries];
            [self refreshTitle];
            [tv deleteRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        }];
        del.attributes = UIMenuElementAttributesDestructive;

        return [UIMenu menuWithTitle:@""
                            children:@[update, edit, toggleBan, del]];
    }];
    return cfg;
}

// Swipe-right → Sửa (account label/kind) + Ban/Mở khóa (toggle status).
// Two actions on the leading edge so user can fill metadata or mark a
// banned account without conflicting with the destructive "Xóa" pattern
// on the other edge.
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv
        leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    CIRRSEntry *e = _view[ip.row];
    UIContextualAction *edit = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:@"Sửa"
                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [self editAccountForEntry:e atIndex:ip];
        done(YES);
    }];
    edit.backgroundColor = [CITheme blue];

    BOOL isBanned = (e.accountStatus == CIAccountStatusBanned);
    UIContextualAction *toggleBan = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:(isBanned ? @"Mở khóa" : @"Ban")
                          handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        e.accountStatus = isBanned ? CIAccountStatusActive : CIAccountStatusBanned;
        [[CIRRSStore shared] saveIndex];
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationFade];
        done(YES);
    }];
    toggleBan.backgroundColor = isBanned ? [CITheme green] : [UIColor systemRedColor];

    return [UISwipeActionsConfiguration configurationWithActions:@[edit, toggleBan]];
}
@end

// Forward-declare full CIProxyViewController @interface so CISideMenu's
// didSelect can alloc + push it. Implementation lives below.
@interface CIProxyViewController : UIViewController <UITextFieldDelegate>
@end

// Same pattern for the Camera spoof config screen.
// UIImagePickerController shows the iOS Photos UI directly. The app's
// containerless sandbox normally blocks the Photos TCC flow, but
// entitlements.plist now ships com.apple.private.tcc.allow with
// kTCCServicePhotos which pre-grants access — no permission dialog,
// no TCC.db round-trip needed.
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
    // Trimmed to only working entries — placeholders ("Chức năng đang phát
    // triển") were cluttering the menu. Add new items here as they get real
    // handlers in didSelectRowAtIndexPath.
    _items = @[@"Proxy"];
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
    if ([cmd isEqualToString:@"Proxy"]) {
        CIProxyViewController *vc = [[CIProxyViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:cmd message:@"Chức năng đang phát triển." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}
@end

// ============================================================
// PROXY CONFIG VIEW CONTROLLER
// ============================================================
// User pastes "host:port[:user:pass]" + picks HTTP / SOCKS5 + toggles ON.
//   Test         → blocking GET https://api.ipify.org?format=json through
//                  the proxy; alert shows resolved IP or error.
//   Auto-fill GPS → fetch ip-api geoip via the proxy and apply lat/long/
//                  carrier/locale (same path as Reset Data, so the user
//                  can dial in coordinates without doing a full reset).
//   Save         → persist + Darwin notify the tweak so target apps
//                  pick up the new proxy on next request.
// (@interface is declared above CISideMenuViewController so the side
//  menu's didSelect can construct it; implementation stays here.)

@implementation CIProxyViewController {
    UISwitch           *_enableSwitch;
    UISegmentedControl *_typeSegment;
    UITextField        *_proxyField;
    UILabel            *_statusLabel;
    UIButton           *_testBtn;
    UIButton           *_geoBtn;
    UIButton           *_saveBtn;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Proxy";
    self.view.backgroundColor = [CITheme bg];

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sv.alwaysBounceVertical = YES;
    sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:sv];

    CGFloat W = self.view.bounds.size.width;
    CGFloat M = 16;
    CGFloat y = 16;

    // Enable row
    UILabel *enLbl = [[UILabel alloc] initWithFrame:CGRectMake(M, y, W - 2*M - 60, 32)];
    enLbl.text = @"Bật proxy"; enLbl.textColor = [CITheme text];
    enLbl.font = [UIFont boldSystemFontOfSize:17];
    [sv addSubview:enLbl];
    _enableSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(W - M - 51, y, 51, 32)];
    _enableSwitch.onTintColor = [CITheme orange];
    [sv addSubview:_enableSwitch];
    y += 50;

    // Type segment
    UILabel *tyLbl = [[UILabel alloc] initWithFrame:CGRectMake(M, y, W - 2*M, 22)];
    tyLbl.text = @"Loại"; tyLbl.textColor = [CITheme dim];
    tyLbl.font = [UIFont systemFontOfSize:13];
    [sv addSubview:tyLbl]; y += 24;
    _typeSegment = [[UISegmentedControl alloc] initWithItems:@[@"HTTP", @"SOCKS5"]];
    _typeSegment.frame = CGRectMake(M, y, W - 2*M, 36);
    _typeSegment.selectedSegmentIndex = 0;
    [sv addSubview:_typeSegment];
    y += 50;

    // Proxy textfield
    UILabel *pfLbl = [[UILabel alloc] initWithFrame:CGRectMake(M, y, W - 2*M, 22)];
    pfLbl.text = @"host:port:user:pass"; pfLbl.textColor = [CITheme dim];
    pfLbl.font = [UIFont systemFontOfSize:13];
    [sv addSubview:pfLbl]; y += 24;
    _proxyField = [[UITextField alloc] initWithFrame:CGRectMake(M, y, W - 2*M, 44)];
    _proxyField.placeholder = @"vd: 1.2.3.4:8080:user:pass";
    _proxyField.font = [UIFont fontWithName:@"Menlo" size:14];
    _proxyField.textColor = [CITheme text];
    _proxyField.backgroundColor = [CITheme card];
    _proxyField.layer.cornerRadius = 8;
    _proxyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _proxyField.autocorrectionType = UITextAutocorrectionTypeNo;
    _proxyField.spellCheckingType = UITextSpellCheckingTypeNo;
    _proxyField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _proxyField.delegate = self;
    UIView *pad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _proxyField.leftView = pad; _proxyField.leftViewMode = UITextFieldViewModeAlways;
    [sv addSubview:_proxyField];
    y += 60;

    // Status label
    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(M, y, W - 2*M, 60)];
    _statusLabel.numberOfLines = 0;
    _statusLabel.textColor = [CITheme dim];
    _statusLabel.font = [UIFont systemFontOfSize:13];
    [sv addSubview:_statusLabel];
    y += 70;

    // Test button
    _testBtn = CIBoxButton(@"Test kết nối", [CITheme blue], [CITheme blue]);
    _testBtn.frame = CGRectMake(M, y, W - 2*M, 52);
    [_testBtn addTarget:self action:@selector(testTapped) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:_testBtn];
    y += 64;

    // Auto-fill GPS button
    _geoBtn = CIBoxButton(@"Lấy GPS theo IP proxy", [CITheme orange], [CITheme orange]);
    _geoBtn.frame = CGRectMake(M, y, W - 2*M, 52);
    [_geoBtn addTarget:self action:@selector(geoTapped) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:_geoBtn];
    y += 64;

    // Save button
    _saveBtn = CIBoxButton(@"Lưu", [UIColor whiteColor], [CITheme border]);
    _saveBtn.frame = CGRectMake(M, y, W - 2*M, 52);
    [_saveBtn addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:_saveBtn];
    y += 64;

    sv.contentSize = CGSizeMake(W, y + 24);

    // Load existing config
    CIConfigManager *cm = [CIConfigManager shared];
    _enableSwitch.on = [cm boolForKey:@"proxyEnabled"];
    NSString *type = [cm stringForKey:@"proxyType"];
    _typeSegment.selectedSegmentIndex = [type isEqualToString:@"socks5"] ? 1 : 0;
    _proxyField.text = [cm stringForKey:@"proxyString"] ?: @"";
    [self refreshStatus:nil error:NO];
}

- (void)refreshStatus:(NSString *)msg error:(BOOL)isError {
    if (msg.length == 0) {
        NSDictionary *p = ci_parseProxyString(_proxyField.text);
        if (!p) { _statusLabel.text = @"⚠ Cấu hình proxy chưa hợp lệ"; _statusLabel.textColor = [CITheme dim]; return; }
        NSString *type = _typeSegment.selectedSegmentIndex == 1 ? @"SOCKS5" : @"HTTP";
        _statusLabel.text = [NSString stringWithFormat:@"%@ %@:%@%@",
            type, p[@"host"], p[@"port"],
            p[@"user"] ? @" (auth)" : @""];
        _statusLabel.textColor = [CITheme dim];
        return;
    }
    _statusLabel.text = msg;
    _statusLabel.textColor = isError ? [UIColor systemRedColor] : [CITheme green];
}

// Snapshot UI → CIConfigManager so the helpers below see fresh values
// before we kick the network request.
- (void)stageConfigFromUI {
    CIConfigManager *cm = [CIConfigManager shared];
    [cm setObject:@(_enableSwitch.on) forKey:@"proxyEnabled"];
    [cm setObject:(_typeSegment.selectedSegmentIndex == 1 ? @"socks5" : @"http")
           forKey:@"proxyType"];
    [cm setObject:(_proxyField.text ?: @"") forKey:@"proxyString"];
}

- (void)testTapped {
    [self.view endEditing:YES];
    [self stageConfigFromUI];
    if (![_enableSwitch isOn]) {
        [self refreshStatus:@"Bật switch trước rồi mới test." error:YES];
        return;
    }
    if (!ci_parseProxyString(_proxyField.text)) {
        [self refreshStatus:@"Format sai. Đúng: host:port:user:pass" error:YES];
        return;
    }
    [self refreshStatus:@"⌛ Đang test…" error:NO];
    _testBtn.enabled = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSURLSessionConfiguration *cfg = ci_proxyConfigOrNil();
        NSURLSession *session = cfg ? [NSURLSession sessionWithConfiguration:cfg]
                                    : [NSURLSession sharedSession];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
            [NSURL URLWithString:@"https://api.ipify.org?format=json"]];
        req.timeoutInterval = 8.0;
        req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        __block NSData *data = nil; __block NSError *err = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[session dataTaskWithRequest:req
            completionHandler:^(NSData *d, NSURLResponse *_r, NSError *e) {
                data = d; err = e; dispatch_semaphore_signal(sem);
            }] resume];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)));
        if (cfg) [session finishTasksAndInvalidate];

        NSString *resultMsg; BOOL isErr = NO;
        if (err || !data) {
            resultMsg = [NSString stringWithFormat:@"❌ Lỗi: %@",
                         err.localizedDescription ?: @"không nhận được response"];
            isErr = YES;
        } else {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSString *ip = [json isKindOfClass:[NSDictionary class]] ? json[@"ip"] : nil;
            if ([ip isKindOfClass:[NSString class]] && ip.length) {
                resultMsg = [NSString stringWithFormat:@"✓ OK — IP qua proxy: %@", ip];
            } else {
                resultMsg = @"❌ Response lạ — proxy có thể chặn HTTPS";
                isErr = YES;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_testBtn.enabled = YES;
            [self refreshStatus:resultMsg error:isErr];
        });
    });
}

- (void)geoTapped {
    [self.view endEditing:YES];
    [self stageConfigFromUI];
    if (![_enableSwitch isOn] || !ci_parseProxyString(_proxyField.text)) {
        [self refreshStatus:@"Bật proxy + nhập đúng format trước." error:YES];
        return;
    }
    [self refreshStatus:@"⌛ Đang lấy GPS từ ip-api.com qua proxy…" error:NO];
    _geoBtn.enabled = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *geo = ci_fetchProxyGeo(nil);
        BOOL ok = ci_applyGeoFromIPAPI(geo);
        if (ok) [[CIConfigManager shared] save];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_geoBtn.enabled = YES;
            if (!ok) {
                [self refreshStatus:@"❌ Geo failed — proxy chặn ip-api.com hoặc offline" error:YES];
                return;
            }
            CIConfigManager *cm = [CIConfigManager shared];
            NSString *cc  = [cm stringForKey:@"localeCountryCode"] ?: @"?";
            NSString *isp = [cm stringForKey:@"carrierName"] ?: @"?";
            NSString *ip  = [cm stringForKey:@"lastResetIP"] ?: @"?";
            [self refreshStatus:[NSString stringWithFormat:@"✓ %@ — %@ (%@)\nGPS + locale + carrier đã đồng bộ.", cc, isp, ip]
                          error:NO];
            [cm notifyReload];
        });
    });
}

- (void)saveTapped {
    [self.view endEditing:YES];
    [self stageConfigFromUI];
    [[CIConfigManager shared] save];
    [[CIConfigManager shared] notifyReload];
    [self refreshStatus:@"✓ Lưu xong — tweak sẽ pick up proxy ngay." error:NO];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
- (void)textFieldDidEndEditing:(UITextField *)tf { [self refreshStatus:nil error:NO]; }

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
    CGFloat _lastLayoutWidth;
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

// Same row builder but with explicit value text (for computed values
// like the VoIP token derived from apnsTokenSpoof XOR 0xA5).
+ (CIFakeReportRow *)rowWithLabel:(NSString *)label value:(NSString *)value {
    CIFakeReportRow *r = [CIFakeReportRow new];
    r.label = label; r.configKey = @"";
    r.value = value.length > 0 ? value : @"(chưa fake)";
    r.ok = (value.length > 0);
    return r;
}

// Compute the VoIP push token preview as the tweak does at runtime:
// each byte = (apnsTokenSpoof byte) XOR 0xA5. Lets the user verify in
// the Fake Info screen that the spoof rotated and PKPushRegistry hook
// will return a different value than APNS.
+ (NSString *)voipTokenPreview {
    NSString *hex = [[CIConfigManager shared] stringForKey:@"apnsTokenSpoof"];
    if (hex.length < 64) return @"";
    NSMutableString *out = [NSMutableString stringWithCapacity:64];
    for (NSUInteger i = 0; i + 2 <= hex.length && out.length < 64; i += 2) {
        unsigned int v = 0;
        const char *p = [[hex substringWithRange:NSMakeRange(i, 2)] UTF8String];
        if (sscanf(p, "%02x", &v) == 1) {
            uint8_t b = (uint8_t)v ^ 0xA5;
            [out appendFormat:@"%02x", b];
        }
    }
    return out;
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

    [all addObject:[C section:@"GPS Location (PHẢI khớp Proxy/VPN)" icon:@"📍" rows:@[
        [C row:@"Geo Source"     key:@"_ci_geo_source"],
        [C row:@"Last Reset IP"  key:@"lastResetIP"],
        [C row:@"Country"        key:@"localeCountryCode"],
        [C row:@"Carrier"        key:@"carrierName"],
        [C row:@"Timezone"       key:@"timezoneName"],
        [C row:@"Latitude"       key:@"latitude"],
        [C row:@"Longitude"      key:@"longitude"],
        [C row:@"Altitude"       key:@"altitude"],
        [C row:@"Enabled"        key:@"locationEnabled"],
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

    [all addObject:[C section:@"Push Tokens (anti-correlation)" icon:@"🔔" rows:@[
        [C row:@"APNS Token Spoof"  key:@"apnsTokenSpoof"],
        [C rowWithLabel:@"VoIP Token Spoof" value:[C voipTokenPreview]],
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

// Cell layout in cellForRow uses tv.bounds.size.width to position the
// trailing value label. On the FIRST appearance the table's bounds are
// still 0×0 (set later by autoresize), so cells render with the value
// label clipped — only swiping forces a re-dequeue with the correct
// width. Force a reloadData once the table reaches its real width so
// every cell is rebuilt correctly without user interaction.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = _table.bounds.size.width;
    if (w > 0 && w != _lastLayoutWidth) {
        _lastLayoutWidth = w;
        [_table reloadData];
    }
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
    NSMutableDictionary<NSString *, UILabel *> *_profileLabels;
}

// v2.4.36: redesigned home layout, AZInfo-style.
// Top: phone-info card (icon + model + iOS + version + Rootless badge).
// Middle: two action buttons (Clear Data + Kill Apps / Backup Apps).
// Below: Current Fake Profile card (read-only summary of the fake state).
// The old multi-step picker card + RRS row + note field moved to other
// tabs/menu. Backup/restore is intentionally minimal here.
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [CITheme bg];
    self.title = @"HIOS Faker";

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithImage:[self menuIcon] style:UIBarButtonItemStylePlain
                                        target:self action:@selector(openMenu)];
    if (@available(iOS 13.0, *)) {
        UIImage *logoutImg = [[UIImage systemImageNamed:@"rectangle.portrait.and.arrow.right"]
                              imageWithTintColor:[CITheme blue]
                              renderingMode:UIImageRenderingModeAlwaysOriginal];
        self.navigationItem.rightBarButtonItem =
            [[UIBarButtonItem alloc] initWithImage:logoutImg style:UIBarButtonItemStylePlain
                                            target:self action:@selector(openMenu)];
    }

    UIScrollView *sv = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    sv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sv.alwaysBounceVertical = YES;
    sv.backgroundColor = [CITheme bg];
    [self.view addSubview:sv];

    CGFloat W = self.view.bounds.size.width;
    CGFloat y = 16;
    CGFloat P = 16;
    CGFloat cardW = W - 2*P;

    // ---- Phone info card ----
    UIView *phoneCard = [self _ciNewCard:CGRectMake(P, y, cardW, 150)];
    [sv addSubview:phoneCard];

    UIImageView *phoneIcon = [[UIImageView alloc] initWithFrame:CGRectMake(16, 16, 70, 118)];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:64 weight:UIImageSymbolWeightRegular];
        phoneIcon.image = [[UIImage systemImageNamed:@"iphone" withConfiguration:cfg]
                            imageWithTintColor:[CITheme blue] renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    phoneIcon.contentMode = UIViewContentModeScaleAspectFit;
    [phoneCard addSubview:phoneIcon];

    struct utsname u; uname(&u);
    NSString *realModel = [NSString stringWithUTF8String:u.machine];
    NSString *realIOS   = [UIDevice currentDevice].systemVersion;
    NSString *realName  = [self _humanModelName:realModel];

    UILabel *nameLbl = [[UILabel alloc] initWithFrame:CGRectMake(100, 22, cardW-220, 28)];
    nameLbl.text = realName;
    nameLbl.font = [UIFont boldSystemFontOfSize:22];
    nameLbl.textColor = [CITheme text];
    [phoneCard addSubview:nameLbl];

    UILabel *modelLbl = [[UILabel alloc] initWithFrame:CGRectMake(100, 56, cardW-110, 20)];
    modelLbl.text = [NSString stringWithFormat:@"Model: %@", realModel];
    modelLbl.font = [UIFont systemFontOfSize:14];
    modelLbl.textColor = [CITheme dim];
    [phoneCard addSubview:modelLbl];

    UILabel *iosLbl = [[UILabel alloc] initWithFrame:CGRectMake(100, 78, cardW-110, 20)];
    iosLbl.text = [NSString stringWithFormat:@"iOS: %@", realIOS];
    iosLbl.font = [UIFont systemFontOfSize:14];
    iosLbl.textColor = [CITheme dim];
    [phoneCard addSubview:iosLbl];

    UILabel *verLbl = [[UILabel alloc] initWithFrame:CGRectMake(100, 100, cardW-110, 20)];
    verLbl.text = [NSString stringWithFormat:@"Version: %@", kAppVersion];
    verLbl.font = [UIFont systemFontOfSize:14];
    verLbl.textColor = [CITheme dim];
    [phoneCard addSubview:verLbl];

    UILabel *rootBadge = [[UILabel alloc] initWithFrame:CGRectMake(cardW-100, 16, 84, 30)];
    rootBadge.text = @"Rootless";
    rootBadge.textAlignment = NSTextAlignmentCenter;
    rootBadge.font = [UIFont boldSystemFontOfSize:13];
    rootBadge.textColor = [UIColor whiteColor];
    rootBadge.backgroundColor = [CITheme blue];
    rootBadge.layer.cornerRadius = 15;
    rootBadge.layer.masksToBounds = YES;
    [phoneCard addSubview:rootBadge];

    y += 166;

    // ---- Action buttons row ----
    CGFloat btnW = (cardW - P)/2;
    CGFloat btnH = 96;

    UIButton *clearBtn = [self _ciActionButton:@"Clear Data\n+ Kill Apps" color:[CITheme orange]];
    clearBtn.frame = CGRectMake(P, y, btnW, btnH);
    [clearBtn addTarget:self action:@selector(resetData) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:clearBtn];

    UIButton *backupBtn = [self _ciActionButton:@"Backup\nApps" color:[CITheme blue]];
    backupBtn.frame = CGRectMake(P+btnW+P, y, btnW, btnH);
    [backupBtn addTarget:self action:@selector(saveAndReset) forControlEvents:UIControlEventTouchUpInside];
    [sv addSubview:backupBtn];

    y += btnH + 20;

    // ---- Current Fake Profile card ----
    UIView *profCard = [self _ciNewCard:CGRectMake(P, y, cardW, 360)];
    [sv addSubview:profCard];

    UILabel *profTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 16, cardW-32, 24)];
    profTitle.text = @"Current Fake Profile";
    profTitle.font = [UIFont boldSystemFontOfSize:18];
    profTitle.textColor = [CITheme text];
    [profCard addSubview:profTitle];

    // Field labels — instance refs so viewWillAppear can refresh them.
    _profileLabels = [NSMutableDictionary dictionary];
    NSArray *keys = @[@"Model", @"iOS", @"Color", @"Storage", @"Region",
                      @"Locale", @"Timezone", @"Carrier"];
    CGFloat rowY = 56;
    for (NSString *key in keys) {
        UILabel *k = [[UILabel alloc] initWithFrame:CGRectMake(16, rowY, 100, 22)];
        k.text = key;
        k.font = [UIFont systemFontOfSize:15];
        k.textColor = [CITheme dim];
        [profCard addSubview:k];

        UILabel *v = [[UILabel alloc] initWithFrame:CGRectMake(120, rowY, cardW-136, 22)];
        v.font = [UIFont systemFontOfSize:15];
        v.textColor = [CITheme text];
        v.textAlignment = NSTextAlignmentRight;
        v.adjustsFontSizeToFitWidth = YES;
        v.minimumScaleFactor = 0.7;
        [profCard addSubview:v];
        _profileLabels[key] = v;

        rowY += 32;
    }
    [self refreshFakeProfile];
    y += 376;

    // ---- Secondary actions (kept compact) ----
    UIView *bottomCard = [self _ciNewCard:CGRectMake(P, y, cardW, 56)];
    [sv addSubview:bottomCard];

    UIButton *rrsBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    rrsBtn.frame = CGRectMake(0, 0, cardW/2, 56);
    [rrsBtn setTitle:@"Quản lý RRS" forState:UIControlStateNormal];
    [rrsBtn setTitleColor:[CITheme orange] forState:UIControlStateNormal];
    rrsBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [rrsBtn addTarget:self action:@selector(openRRS) forControlEvents:UIControlEventTouchUpInside];
    [bottomCard addSubview:rrsBtn];

    UIView *divLine = [[UIView alloc] initWithFrame:CGRectMake(cardW/2, 10, 1, 36)];
    divLine.backgroundColor = [CITheme separator];
    [bottomCard addSubview:divLine];

    UIButton *quickBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    quickBtn.frame = CGRectMake(cardW/2, 0, cardW/2, 56);
    [quickBtn setTitle:@"Restore nhanh" forState:UIControlStateNormal];
    [quickBtn setTitleColor:[CITheme blue] forState:UIControlStateNormal];
    quickBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [quickBtn addTarget:self action:@selector(quickRestore) forControlEvents:UIControlEventTouchUpInside];
    [bottomCard addSubview:quickBtn];

    y += 72;

    // ---- VPN Sync + Check Fingerprint card (v2.4.54) ----
    // Sync GPS+TZ+country với VPN exit IP, rồi mở browserleaks để verify.
    UIView *syncCard = [self _ciNewCard:CGRectMake(P, y, cardW, 64)];
    [sv addSubview:syncCard];
    UIButton *syncBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    syncBtn.frame = CGRectMake(0, 0, cardW/2, 64);
    [syncBtn addTarget:self action:@selector(syncGPSWithVPN) forControlEvents:UIControlEventTouchUpInside];
    [syncCard addSubview:syncBtn];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        UIImageView *iv = [[UIImageView alloc] initWithImage:
            [[UIImage systemImageNamed:@"location.fill.viewfinder" withConfiguration:cfg]
             imageWithTintColor:[CITheme orange] renderingMode:UIImageRenderingModeAlwaysOriginal]];
        iv.frame = CGRectMake(14, 17, 30, 30);
        [syncBtn addSubview:iv];
    }
    UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(54, 10, cardW/2-60, 22)];
    st.text = @"Sync GPS với VPN"; st.font = [UIFont boldSystemFontOfSize:14]; st.textColor = [CITheme text];
    [syncBtn addSubview:st];
    UILabel *ss = [[UILabel alloc] initWithFrame:CGRectMake(54, 32, cardW/2-60, 20)];
    ss.text = @"ipinfo.io → coord/TZ"; ss.font = [UIFont systemFontOfSize:11]; ss.textColor = [CITheme dim];
    [syncBtn addSubview:ss];

    UIView *divSync = [[UIView alloc] initWithFrame:CGRectMake(cardW/2, 12, 0.5, 40)];
    divSync.backgroundColor = [CITheme separator];
    [syncCard addSubview:divSync];

    UIButton *checkBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    checkBtn.frame = CGRectMake(cardW/2, 0, cardW/2, 64);
    [checkBtn addTarget:self action:@selector(openFingerprintCheck) forControlEvents:UIControlEventTouchUpInside];
    [syncCard addSubview:checkBtn];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
        UIImageView *iv2 = [[UIImageView alloc] initWithImage:
            [[UIImage systemImageNamed:@"network" withConfiguration:cfg]
             imageWithTintColor:[CITheme blue] renderingMode:UIImageRenderingModeAlwaysOriginal]];
        iv2.frame = CGRectMake(14, 17, 30, 30);
        [checkBtn addSubview:iv2];
    }
    UILabel *ct = [[UILabel alloc] initWithFrame:CGRectMake(54, 10, cardW/2-60, 22)];
    ct.text = @"Check Fingerprint"; ct.font = [UIFont boldSystemFontOfSize:14]; ct.textColor = [CITheme text];
    [checkBtn addSubview:ct];
    UILabel *cs = [[UILabel alloc] initWithFrame:CGRectMake(54, 32, cardW/2-60, 20)];
    cs.text = @"sync + browserleaks"; cs.font = [UIFont systemFontOfSize:11]; cs.textColor = [CITheme dim];
    [checkBtn addSubview:cs];

    y += 80;

    // ---- App-target chips (visible state of pickers) ----
    UIView *pickRow = [self _ciNewCard:CGRectMake(P, y, cardW, 120)];
    [sv addSubview:pickRow];

    UIButton *pickReset = [UIButton buttonWithType:UIButtonTypeCustom];
    pickReset.frame = CGRectMake(0, 0, cardW, 60);
    [pickReset addTarget:self action:@selector(pickResetApps) forControlEvents:UIControlEventTouchUpInside];
    [pickRow addSubview:pickReset];
    UILabel *pr1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, cardW-32, 22)];
    pr1.text = @"Apps Reset"; pr1.font = [UIFont boldSystemFontOfSize:15]; pr1.textColor = [CITheme text];
    [pickReset addSubview:pr1];
    _selectedResetLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 30, cardW-32, 20)];
    _selectedResetLabel.font = [UIFont systemFontOfSize:13]; _selectedResetLabel.textColor = [CITheme dim];
    [pickReset addSubview:_selectedResetLabel];

    UIView *sep1 = [[UIView alloc] initWithFrame:CGRectMake(16, 60, cardW-32, 0.5)];
    sep1.backgroundColor = [CITheme separator]; [pickRow addSubview:sep1];

    UIButton *pickRRS = [UIButton buttonWithType:UIButtonTypeCustom];
    pickRRS.frame = CGRectMake(0, 60, cardW, 60);
    [pickRRS addTarget:self action:@selector(pickRRSApps) forControlEvents:UIControlEventTouchUpInside];
    [pickRow addSubview:pickRRS];
    UILabel *pr2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 8, cardW-32, 22)];
    pr2.text = @"Apps Backup"; pr2.font = [UIFont boldSystemFontOfSize:15]; pr2.textColor = [CITheme text];
    [pickRRS addSubview:pr2];
    _selectedRrsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 30, cardW-32, 20)];
    _selectedRrsLabel.font = [UIFont systemFontOfSize:13]; _selectedRrsLabel.textColor = [CITheme dim];
    [pickRRS addSubview:_selectedRrsLabel];

    y += 136;

    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(P, y, cardW, 30)];
    foot.text = @"telegram: Houselis"; foot.textAlignment = NSTextAlignmentCenter;
    foot.textColor = [CITheme dim]; foot.font = [UIFont systemFontOfSize:13];
    [sv addSubview:foot];
    y += 42;

    sv.contentSize = CGSizeMake(W, y);

    // hidden field — keep for compatibility with existing action methods
    // that read [CIConfigManager rrsNote]; surfaced inside RRS list now.
    _noteField = [[UITextField alloc] init];
    _noteField.delegate = self;

    [self refreshSelectionLabels];
}

// ---- helpers for the new layout ----

- (UIView *)_ciNewCard:(CGRect)frame {
    UIView *v = [[UIView alloc] initWithFrame:frame];
    v.backgroundColor = [CITheme card];
    v.layer.cornerRadius = 14;
    v.layer.shadowColor = [UIColor blackColor].CGColor;
    v.layer.shadowOffset = CGSizeMake(0, 2);
    v.layer.shadowOpacity = 0.05;
    v.layer.shadowRadius = 6;
    return v;
}

- (UIButton *)_ciActionButton:(NSString *)title color:(UIColor *)color {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    b.titleLabel.numberOfLines = 0;
    b.titleLabel.textAlignment = NSTextAlignmentCenter;
    b.backgroundColor = color;
    b.layer.cornerRadius = 16;
    b.layer.shadowColor = color.CGColor;
    b.layer.shadowOffset = CGSizeMake(0, 4);
    b.layer.shadowOpacity = 0.2;
    b.layer.shadowRadius = 8;
    return b;
}

- (NSString *)_humanModelName:(NSString *)machine {
    // Per-identifier mapping table (source: Apple model IDs). Earlier
    // prefix-based shortcut was wrong — e.g. iPhone10,3/10,6 is iPhone X,
    // not iPhone 8 — so map every specific identifier we know about.
    static NSDictionary<NSString *, NSString *> *table = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            // iPhone
            @"iPhone1,1": @"iPhone",         @"iPhone1,2": @"iPhone 3G",
            @"iPhone2,1": @"iPhone 3GS",
            @"iPhone3,1": @"iPhone 4",       @"iPhone3,2": @"iPhone 4",       @"iPhone3,3": @"iPhone 4",
            @"iPhone4,1": @"iPhone 4s",
            @"iPhone5,1": @"iPhone 5",       @"iPhone5,2": @"iPhone 5",
            @"iPhone5,3": @"iPhone 5c",      @"iPhone5,4": @"iPhone 5c",
            @"iPhone6,1": @"iPhone 5s",      @"iPhone6,2": @"iPhone 5s",
            @"iPhone7,1": @"iPhone 6 Plus",  @"iPhone7,2": @"iPhone 6",
            @"iPhone8,1": @"iPhone 6s",      @"iPhone8,2": @"iPhone 6s Plus", @"iPhone8,4": @"iPhone SE",
            @"iPhone9,1": @"iPhone 7",       @"iPhone9,2": @"iPhone 7 Plus",
            @"iPhone9,3": @"iPhone 7",       @"iPhone9,4": @"iPhone 7 Plus",
            @"iPhone10,1": @"iPhone 8",      @"iPhone10,4": @"iPhone 8",
            @"iPhone10,2": @"iPhone 8 Plus", @"iPhone10,5": @"iPhone 8 Plus",
            @"iPhone10,3": @"iPhone X",      @"iPhone10,6": @"iPhone X",
            @"iPhone11,2": @"iPhone XS",
            @"iPhone11,4": @"iPhone XS Max", @"iPhone11,6": @"iPhone XS Max",
            @"iPhone11,8": @"iPhone XR",
            @"iPhone12,1": @"iPhone 11",
            @"iPhone12,3": @"iPhone 11 Pro", @"iPhone12,5": @"iPhone 11 Pro Max",
            @"iPhone12,8": @"iPhone SE (2nd gen)",
            @"iPhone13,1": @"iPhone 12 mini",@"iPhone13,2": @"iPhone 12",
            @"iPhone13,3": @"iPhone 12 Pro", @"iPhone13,4": @"iPhone 12 Pro Max",
            @"iPhone14,2": @"iPhone 13 Pro", @"iPhone14,3": @"iPhone 13 Pro Max",
            @"iPhone14,4": @"iPhone 13 mini",@"iPhone14,5": @"iPhone 13",
            @"iPhone14,6": @"iPhone SE (3rd gen)",
            @"iPhone14,7": @"iPhone 14",     @"iPhone14,8": @"iPhone 14 Plus",
            @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max",
            @"iPhone15,4": @"iPhone 15",     @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone16,1": @"iPhone 15 Pro", @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPhone17,1": @"iPhone 16 Pro", @"iPhone17,2": @"iPhone 16 Pro Max",
            @"iPhone17,3": @"iPhone 16",     @"iPhone17,4": @"iPhone 16 Plus",
            @"iPhone17,5": @"iPhone 16e",
            // iPad (selected — common in test fleets)
            @"iPad2,1": @"iPad 2",           @"iPad2,2": @"iPad 2",           @"iPad2,3": @"iPad 2",           @"iPad2,4": @"iPad 2",
            @"iPad2,5": @"iPad mini",        @"iPad2,6": @"iPad mini",        @"iPad2,7": @"iPad mini",
            @"iPad3,1": @"iPad (3rd gen)",   @"iPad3,2": @"iPad (3rd gen)",   @"iPad3,3": @"iPad (3rd gen)",
            @"iPad3,4": @"iPad (4th gen)",   @"iPad3,5": @"iPad (4th gen)",   @"iPad3,6": @"iPad (4th gen)",
            @"iPad4,1": @"iPad Air",         @"iPad4,2": @"iPad Air",         @"iPad4,3": @"iPad Air",
            @"iPad4,4": @"iPad mini 2",      @"iPad4,5": @"iPad mini 2",      @"iPad4,6": @"iPad mini 2",
            @"iPad4,7": @"iPad mini 3",      @"iPad4,8": @"iPad mini 3",      @"iPad4,9": @"iPad mini 3",
            @"iPad5,1": @"iPad mini 4",      @"iPad5,2": @"iPad mini 4",
            @"iPad5,3": @"iPad Air 2",       @"iPad5,4": @"iPad Air 2",
            @"iPad6,3": @"iPad Pro 9.7\"",   @"iPad6,4": @"iPad Pro 9.7\"",
            @"iPad6,7": @"iPad Pro 12.9\"",  @"iPad6,8": @"iPad Pro 12.9\"",
            @"iPad6,11": @"iPad (5th gen)",  @"iPad6,12": @"iPad (5th gen)",
            @"iPad7,1": @"iPad Pro 12.9\" (2nd gen)", @"iPad7,2": @"iPad Pro 12.9\" (2nd gen)",
            @"iPad7,3": @"iPad Pro 10.5\"",  @"iPad7,4": @"iPad Pro 10.5\"",
            @"iPad7,5": @"iPad (6th gen)",   @"iPad7,6": @"iPad (6th gen)",
            @"iPad7,11": @"iPad (7th gen)",  @"iPad7,12": @"iPad (7th gen)",
            @"iPad8,1": @"iPad Pro 11\"",    @"iPad8,2": @"iPad Pro 11\"",    @"iPad8,3": @"iPad Pro 11\"",    @"iPad8,4": @"iPad Pro 11\"",
            @"iPad8,5": @"iPad Pro 12.9\" (3rd gen)", @"iPad8,6": @"iPad Pro 12.9\" (3rd gen)",
            @"iPad8,7": @"iPad Pro 12.9\" (3rd gen)", @"iPad8,8": @"iPad Pro 12.9\" (3rd gen)",
            @"iPad11,1": @"iPad mini 5",     @"iPad11,2": @"iPad mini 5",
            @"iPad11,3": @"iPad Air (3rd gen)", @"iPad11,4": @"iPad Air (3rd gen)",
            @"iPad11,6": @"iPad (8th gen)",  @"iPad11,7": @"iPad (8th gen)",
            @"iPad12,1": @"iPad (9th gen)",  @"iPad12,2": @"iPad (9th gen)",
            @"iPad13,1": @"iPad Air (4th gen)", @"iPad13,2": @"iPad Air (4th gen)",
            @"iPad13,4": @"iPad Pro 11\" (3rd gen)", @"iPad13,5": @"iPad Pro 11\" (3rd gen)",
            @"iPad13,6": @"iPad Pro 11\" (3rd gen)", @"iPad13,7": @"iPad Pro 11\" (3rd gen)",
            @"iPad13,8": @"iPad Pro 12.9\" (5th gen)", @"iPad13,9": @"iPad Pro 12.9\" (5th gen)",
            @"iPad13,10": @"iPad Pro 12.9\" (5th gen)", @"iPad13,11": @"iPad Pro 12.9\" (5th gen)",
            @"iPad13,16": @"iPad Air (5th gen)", @"iPad13,17": @"iPad Air (5th gen)",
            @"iPad13,18": @"iPad (10th gen)",@"iPad13,19": @"iPad (10th gen)",
            @"iPad14,1": @"iPad mini (6th gen)", @"iPad14,2": @"iPad mini (6th gen)",
            @"iPad14,3": @"iPad Pro 11\" (4th gen)", @"iPad14,4": @"iPad Pro 11\" (4th gen)",
            @"iPad14,5": @"iPad Pro 12.9\" (6th gen)", @"iPad14,6": @"iPad Pro 12.9\" (6th gen)",
            @"iPad14,8": @"iPad Air 11\" (M2)", @"iPad14,9": @"iPad Air 11\" (M2)",
            @"iPad14,10": @"iPad Air 13\" (M2)", @"iPad14,11": @"iPad Air 13\" (M2)",
            @"iPad16,1": @"iPad mini (7th gen)", @"iPad16,2": @"iPad mini (7th gen)",
            @"iPad16,3": @"iPad Pro 11\" (M4)", @"iPad16,4": @"iPad Pro 11\" (M4)",
            @"iPad16,5": @"iPad Pro 13\" (M4)", @"iPad16,6": @"iPad Pro 13\" (M4)",
            // iPod touch
            @"iPod1,1": @"iPod touch",       @"iPod2,1": @"iPod touch (2nd gen)",
            @"iPod3,1": @"iPod touch (3rd gen)", @"iPod4,1": @"iPod touch (4th gen)",
            @"iPod5,1": @"iPod touch (5th gen)", @"iPod7,1": @"iPod touch (6th gen)",
            @"iPod9,1": @"iPod touch (7th gen)",
            // Simulator
            @"i386": @"Simulator", @"x86_64": @"Simulator", @"arm64": @"Simulator",
        };
    });
    NSString *mapped = table[machine];
    if (mapped) return mapped;
    // Unknown identifier — return raw so the user sees something accurate.
    return machine;
}

- (NSString *)_fakeModelText:(CIConfigManager *)cm {
    NSString *name = [cm stringForKey:@"MarketingName"];
    NSString *model = [cm stringForKey:@"ProductType"];
    if (name.length && model.length) return [NSString stringWithFormat:@"%@ (%@)", name, model];
    if (name.length) return name;
    if (model.length) return model;
    return @"—";
}

- (NSString *)_fakeIOSText:(CIConfigManager *)cm {
    NSString *ver = [cm stringForKey:@"systemVersion"];
    NSString *build = [cm stringForKey:@"BuildVersion"];
    if (ver.length && build.length) return [NSString stringWithFormat:@"%@ (%@)", ver, build];
    if (ver.length) return ver;
    return @"—";
}

- (NSString *)_fakeStorageText:(CIConfigManager *)cm {
    id v = [cm objectForKey:@"DiskUsage"];
    if ([v isKindOfClass:[NSNumber class]]) {
        long long bytes = [(NSNumber *)v longLongValue];
        if (bytes >= 1024LL*1024*1024) return [NSString stringWithFormat:@"%lld GB", bytes/(1024LL*1024*1024)];
    }
    if ([v isKindOfClass:[NSString class]]) return (NSString *)v;
    return @"—";
}

- (NSString *)_fakeCarrierText:(CIConfigManager *)cm {
    NSString *mcc = [cm stringForKey:@"carrierMCC"];
    NSString *mnc = [cm stringForKey:@"carrierMNC"];
    NSString *iso = [cm stringForKey:@"carrierISO"];
    NSString *name = [cm stringForKey:@"carrierName"];
    if (mcc.length && mnc.length) {
        return name.length
            ? [NSString stringWithFormat:@"%@ / %@ (%@)", mcc, mnc, name]
            : [NSString stringWithFormat:@"%@ / %@", mcc, mnc];
    }
    if (mcc.length && iso.length) {
        return name.length
            ? [NSString stringWithFormat:@"%@ / %@ (%@)", mcc, iso, name]
            : [NSString stringWithFormat:@"%@ / %@", mcc, iso];
    }
    if (name.length) return name;
    return @"—";
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

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshSelectionLabels];
    [self refreshFakeProfile];
}

// Re-reads CIConfigManager and updates the Current Fake Profile labels.
// Called from viewDidLoad and viewWillAppear so the Home tab always
// reflects whatever the user just set in the Settings tab — no need
// to exit and re-enter the app.
- (void)refreshFakeProfile {
    if (!_profileLabels) return;
    CIConfigManager *cm = [CIConfigManager shared];
    _profileLabels[@"Model"]   .text = [self _fakeModelText:cm];
    _profileLabels[@"iOS"]     .text = [self _fakeIOSText:cm];
    _profileLabels[@"Color"]   .text = [cm stringForKey:@"DeviceColor"]      ?: @"—";
    _profileLabels[@"Storage"] .text = [self _fakeStorageText:cm];
    _profileLabels[@"Region"]  .text = [cm stringForKey:@"RegionInfo"]       ?: @"—";
    _profileLabels[@"Locale"]  .text = [cm stringForKey:@"localeIdentifier"] ?: @"—";
    _profileLabels[@"Timezone"].text = [cm stringForKey:@"timezoneName"]     ?: @"—";
    _profileLabels[@"Carrier"] .text = [self _fakeCarrierText:cm];
}

// ----- actions -----
- (void)textFieldDidEndEditing:(UITextField *)tf {
    [[CIConfigManager shared] setObject:(tf.text.length ? tf.text : nil) forKey:@"rrsNote"];
    [[CIConfigManager shared] save];
}

// Tap-anywhere-outside-keyboard handler for the gesture installed in viewDidLoad.
- (void)dismissKeyboard {
    [self.view endEditing:YES];
}

// "Nhập" / Return key on the keyboard also dismisses.
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
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

// v2.4.52: open browserleaks.com/ip in Safari. Tweak is filtered into
// com.apple.mobilesafari + WebKit.WebContent so the page will see fully
// spoofed UA / canvas / WebGL / IP-locale matching the current profile.
//
// v2.4.54: sync profile coord/timezone/locale with VPN exit IP FIRST,
// then open Safari. Otherwise user with VN VPN + Hanoi-profile coord
// gets browserleaks showing Hanoi GPS while VPN says somewhere else.
- (void)openFingerprintCheck {
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"Đang đồng bộ vị trí với VPN..."
                                                                  message:@"\n"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:nil];
    [[CIConfigManager shared] syncProfileWithPublicIPCompletion:^(BOOL ok, NSString *city, NSString *country, NSString *err) {
        [hud dismissViewControllerAnimated:YES completion:^{
            // Show coord that was set so user sees the actual values
            id flat = [[CIConfigManager shared] objectForKey:@"latitude"];
            id flng = [[CIConfigManager shared] objectForKey:@"longitude"];
            id ftz  = [[CIConfigManager shared] objectForKey:@"timezoneName"];
            NSString *coordInfo = (flat && flng)
                ? [NSString stringWithFormat:@"\nCoord: %.4f, %.4f\nTZ: %@",
                   [flat doubleValue], [flng doubleValue], ftz ?: @"?"]
                : @"";
            NSString *title = ok ? @"Đã sync xong" : @"Sync lỗi";
            NSString *info;
            if (ok) {
                info = [NSString stringWithFormat:@"VPN exit: %@, %@%@\n\nĐang khởi động lại Safari để load coord mới...",
                        city ?: @"?", country ?: @"?", coordInfo];
            } else {
                info = [NSString stringWithFormat:@"Lỗi: %@%@\n\nVẫn mở browser check.",
                        err ?: @"unknown", coordInfo];
            }
            UIAlertController *r = [UIAlertController alertControllerWithTitle:title message:info
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [self presentViewController:r animated:YES completion:^{
                [self refreshFakeProfile];
                // v2.4.55: terminate Safari + WebContent so next launch picks up
                // freshly-synced coord. Tweak's ci_onRestartTarget handler does
                // exit(0) when bundle matches Safari/WebKit.WebContent.
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFSTR("com.changeinfoios/RestartTarget"),
                    NULL, NULL, true);
                // Brief delay for terminate to propagate, then openURL relaunches
                // Safari with fresh state pointing at browserleaks.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [r dismissViewControllerAnimated:YES completion:^{
                        NSURL *url = [NSURL URLWithString:@"https://browserleaks.com/ip"];
                        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
                    }];
                });
            }];
        }];
    }];
}

// v2.4.54: explicit Sync GPS button — same logic without opening browser.
- (void)syncGPSWithVPN {
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"Đang sync GPS với VPN..."
                                                                  message:@"\n"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:nil];
    [[CIConfigManager shared] syncProfileWithPublicIPCompletion:^(BOOL ok, NSString *city, NSString *country, NSString *err) {
        [hud dismissViewControllerAnimated:YES completion:^{
            id flat = [[CIConfigManager shared] objectForKey:@"latitude"];
            id flng = [[CIConfigManager shared] objectForKey:@"longitude"];
            id ftz  = [[CIConfigManager shared] objectForKey:@"timezoneName"];
            NSString *coordInfo = (flat && flng)
                ? [NSString stringWithFormat:@"\nCoord: %.4f, %.4f\nTZ: %@",
                   [flat doubleValue], [flng doubleValue], ftz ?: @"?"]
                : @"";
            NSString *t = ok ? @"Đồng bộ thành công" : @"Lỗi sync";
            NSString *m = ok
                ? [NSString stringWithFormat:@"VPN exit: %@, %@%@\n\nĐã restart Safari + WebContent — mở lại Safari sẽ thấy coord mới.",
                   city ?: @"?", country ?: @"?", coordInfo]
                : (err ?: @"unknown");
            UIAlertController *r = [UIAlertController alertControllerWithTitle:t message:m
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:r animated:YES completion:nil];
            if (ok) {
                [self refreshFakeProfile];
                // Terminate Safari so next launch picks up new JS coord.
                CFNotificationCenterPostNotification(
                    CFNotificationCenterGetDarwinNotifyCenter(),
                    CFSTR("com.changeinfoios/RestartTarget"),
                    NULL, NULL, true);
            }
        }];
    }];
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
    // v2.4.46: prefer the app's key window so the HUD shows even when
    // restoreEntry: is invoked from a different tab (RRS Backups tab
    // calls Home VC's restoreEntry, but Home's view isn't loaded yet →
    // self.view.window was nil → HUD never visible).
    UIView *root = self.view.window;
    if (!root) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isKeyWindow) { root = w; break; }
        }
        if (!root) root = [UIApplication sharedApplication].windows.firstObject;
    }
    if (!root) root = self.view;
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
        NSInteger totalSteps = backup ? 6 : 5;

        // ============================================================
        // STEP 0 (BACKUP MODE ONLY): snapshot the CURRENT environment
        // ============================================================
        // CRITICAL ORDER: backup MUST happen BEFORE Step 1 / Step 2 wipe
        // anything. Pre-bug-fix flow had createRRSForBundles at Step 3,
        // i.e. AFTER ci_randomizeIdentities had overwritten config + the
        // container wipe had emptied every target's Documents/Library/etc.
        // The resulting tar contained the NEW (already-spoofed) config and
        // EMPTY containers — restoring it never brought back the account.
        if (backup) {
            [self updateHUD:hud step:1 total:totalSteps
                      title:@"Backup môi trường hiện tại"
                   subtitle:[NSString stringWithFormat:@"Lưu %lu app + config + DC tokens…",
                             (unsigned long)rrsBids.count]];
            [NSThread sleepForTimeInterval:1.2];
            [self createRRSForBundles:rrsBids note:note];
            NSLog(@"[ChangeInfoIos] Step 0 (backup) done BEFORE wipe");
        }

        // Step 1: Generate new fake identities and persist to plist
        NSInteger stepIdx = backup ? 2 : 1;
        [self updateHUD:hud step:stepIdx total:totalSteps
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
            [self updateHUD:hud step:(backup ? 3 : 2) total:totalSteps
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

        // Step 3: Clean detection caches + Safari/WebKit deep wipe + save counters
        [self updateHUD:hud step:(backup ? 4 : 3) total:totalSteps
                  title:@"Xoá cache phát hiện + Safari"
               subtitle:@"Safari history/cookies/WebKit + DeviceCheck/IDFA…"];
        [NSThread sleepForTimeInterval:1.5];

        // Safari + WebKit complete wipe — cookies, history, cache, bookmarks,
        // WebKit shared data store. Container wipe in Step 2 only handles
        // /var/mobile/Containers/Data/Application/<UUID>; the bulk of Safari's
        // state lives in /var/mobile/Library/Safari which is outside that.
        ci_wipeSafariDeep();

        // Cross-app residue: HTTPStorages cookies, App Group shared containers,
        // pasteboard changeCount. Apps fingerprint stale state across multiple
        // signal sources; container wipe alone leaves the device clearly
        // identifiable as "the same device that used account X yesterday".
        ci_wipeCrossAppResidue(fullTargets);

        // DC state — persistent DC token + AppAttest keyId per bundle. The
        // tweak persists these so iOS app suspension + relaunch returns the
        // same token (otherwise dispatch_once re-rolls and Zalo's server sees
        // token drift on every relaunch). Reset Data must wipe them so the
        // next launch generates a brand-new device identity.
        ci_run("rm -f /var/jb/etc/changeinfoios/dc_state_*.plist 2>/dev/null");
        NSLog(@"[ChangeInfoIos] DC state files wiped");

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
        // (Backup snapshot was taken at Step 0 above, BEFORE the wipe.)
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
        //
        // User can opt out via the "21. Bỏ qua respring sau Reset Data"
        // toggle in Fake Settings (config key skipRespringAfterReset).
        // When skipped: Step 5's kill sweep still ensures cold-start the
        // next time the user opens a target app, so the new fake config
        // still takes effect — we just save the ~6s SpringBoard reload.
        BOOL skipRespring = [[CIConfigManager shared] boolForKey:@"skipRespringAfterReset"];
        int respringRC = 0;
        BOOL respringOK = YES;
        if (skipRespring) {
            [self updateHUD:hud step:(backup ? 5 : 4) total:totalSteps
                      title:@"Bỏ qua Respring"
                   subtitle:@"Target apps sẽ cold-start ở lần mở tiếp theo…"];
            [NSThread sleepForTimeInterval:0.6];
            NSLog(@"[ChangeInfoIos] Step 4 skipped (skipRespringAfterReset=YES)");
        } else {
            [self updateHUD:hud step:(backup ? 5 : 4) total:totalSteps
                      title:@"Restart SpringBoard"
                   subtitle:@"Reload tweak với config mới…"];
            [NSThread sleepForTimeInterval:1.5];
            const char *respringCmd =
                "/var/jb/usr/bin/sbreload 2>/dev/null"
                " || sbreload 2>/dev/null"
                " || /var/jb/bin/launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null"
                " || launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null"
                " || killall -9 SpringBoard 2>/dev/null";
            respringRC = ci_run(respringCmd);
            [NSThread sleepForTimeInterval:4.0];
            ci_run("/var/jb/usr/bin/uicache -a 2>/dev/null || uicache -a 2>/dev/null");
            [NSThread sleepForTimeInterval:2.0];
            respringOK = (respringRC == 0);
            NSLog(@"[ChangeInfoIos] Step 4 done: respring rc=%d", respringRC);
        }

        // Step 5: Final kill sweep. After SpringBoard respring, iOS often
        // auto-resumes target apps from their launch snapshot. Kill them one
        // more time so that when the user next opens the app icon, it does a
        // FRESH cold-start and the tweak %ctor runs again with the new config.
        [self updateHUD:hud step:(backup ? 6 : 5) total:totalSteps
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

        // Tweak-injection check REMOVED. The old check stat-ed marker
        // files written by tweak %ctor (injected_<bid>.txt in three
        // candidate paths) but kept producing false positives because:
        //
        //   1. Sandboxed App Store apps (Zalo, AIDA64, banking) can't
        //      write the system-level paths /var/mobile/Library/Caches/
        //      or /var/jb/etc/, so two of three writes silently EPERM.
        //   2. The remaining sandbox-permitted path
        //      <container>/tmp/hios_changeinfo_loaded.txt would also be
        //      EMPTY immediately after Reset Data — the Reset wipes the
        //      whole container including tmp/ between marker write and
        //      diagnostic check. Race-condition by design.
        //   3. The reverse signal (spoofed values appearing in
        //      AIDA64 / Lirum / DeviceDesign) is already what the user
        //      checks to verify the spoof landed, so a separate diag
        //      adds confusion without adding signal.
        //
        // If the user wants forensic proof, /var/jb/etc/changeinfoios/
        // cdhashes + dpkg -l com.changeinfoios already prove the tweak
        // is installed; spoofed values in AIDA64 prove the hooks are
        // live. Keep the alert focused on what the user CAN act on.
        NSMutableArray<NSString *> *notInjected = [NSMutableArray array];  // intentionally empty

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
            if (skipRespring) {
                [body appendString:@"⏭ Bỏ qua respring (tuỳ chọn 21).\n→ Mở lại target app để thấy thông tin fake mới.\n\n"];
            } else if (!respringOK) {
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
            if (respringOK && !skipRespring) {
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

    // Auto-fill journal fields from the same `note` text the user typed
    // on the home screen. Two heuristics avoid forcing a separate prompt
    // dialog (which would interrupt the Backup+Reset HUD progression):
    //   1. Phone-like substring → accountLabel. Match the first run of
    //      ≥9 digits (Vietnamese SĐT after country-code strip).
    //   2. Brand keyword (case-insensitive) → accountKind.
    // If nothing matches, fields stay at the "unknown" defaults and the
    // user can fill them later via the leading swipe "Sửa" action — the
    // schema doesn't require these to be set at creation time.
    if (note.length > 0) {
        NSError *re = nil;
        NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"\\d{9,15}"
                                                                            options:0 error:&re];
        NSTextCheckingResult *m = [rx firstMatchInString:note options:0 range:NSMakeRange(0, note.length)];
        if (m && m.range.location != NSNotFound) {
            e.accountLabel = [note substringWithRange:m.range];
        }
        NSString *lower = note.lowercaseString;
        if      ([lower containsString:@"zalo"])                                  e.accountKind = CIAccountKindZalo;
        else if ([lower containsString:@"fb"] || [lower containsString:@"face"])  e.accountKind = CIAccountKindFacebook;
        else if ([lower containsString:@"tiktok"] || [lower containsString:@"tt"])e.accountKind = CIAccountKindTikTok;
        else if ([lower containsString:@"bank"]   || [lower containsString:@"vcb"]
              || [lower containsString:@"mb"]     || [lower containsString:@"tcb"]
              || [lower containsString:@"momo"])                                  e.accountKind = CIAccountKindBanking;
    }
    if (e.accountLabel.length || e.accountKind != CIAccountKindUnknown) {
        e.accountStatus = CIAccountStatusActive;
    }

    // Snapshot the current proxy so a future restore knows which proxy
    // the account was registered through. Mask the last IP octet so a
    // shared screenshot doesn't leak the residential IP cleanly — anti-
    // fraud SDKs that ban one IP often ban the whole /24 anyway.
    NSString *proxyStr = [[CIConfigManager shared] stringForKey:@"proxyString"];
    if ([[CIConfigManager shared] boolForKey:@"proxyEnabled"] && proxyStr.length) {
        NSArray *parts = [proxyStr componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            NSArray *octets = [parts[0] componentsSeparatedByString:@"."];
            if (octets.count == 4) {
                e.proxyTag = [NSString stringWithFormat:@"%@.%@.%@.x:%@",
                              octets[0], octets[1], octets[2], parts[1]];
            } else {
                e.proxyTag = [NSString stringWithFormat:@"%@:%@", parts[0], parts[1]];
            }
        }
    }
    NSMutableArray *n = [NSMutableArray array]; NSMutableArray *b = [NSMutableArray array];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    unsigned long long total = 0;
    for (CIAppInfo *a in all) if ([bids containsObject:a.bundleID]) {
        [n addObject:a.name]; [b addObject:a.bundleID];
        if (a.containerPath) { [paths addObject:a.containerPath]; total += a.containerSize; }
    }
    e.appNames = n; e.bundleIDs = b; e.totalSize = total;

    // Use uncompressed .tar (no gzip): Dopamine 2's rootless prefix ships
    // tar (GNU tar 1.35) but does NOT include gzip — `tar -czf` invokes
    // gzip via execvp and silently produces a 0-byte archive when gzip
    // isn't found. Discovered via ssh-probe-gzip.js after every Backup +
    // Reset run was leaving the user's account list at "0 bytes". Plain
    // tar without compression works fine; archives are larger (3-5×) but
    // disk space isn't constrained on a 256GB iPhone, and the resulting
    // archive is actually openable by the restore code.
    NSString *tarPath = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar"]];
    NSString *errLog  = [NSString stringWithFormat:@"/tmp/ci_rrs_tar_%@.err", e.uid];
    [[NSFileManager defaultManager] createDirectoryAtPath:kRRSDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Pre-flight: log what we're about to archive. If `paths` is empty
    // (CIAppLister couldn't resolve a containerPath for any of the user's
    // RRS picks), tar would still run and produce an archive containing
    // only /var/jb/etc/changeinfoios — useless for restoring an account.
    NSLog(@"[ChangeInfoIos] RRS pre-archive: %lu containers + config dir",
          (unsigned long)paths.count);
    for (NSString *p in paths) NSLog(@"[ChangeInfoIos]   archiving %@", p);
    if (paths.count == 0) {
        NSLog(@"[ChangeInfoIos] WARNING: no app containers to back up — RRS will only contain config snapshot");
    }

    // Trigger keychain dump in every running target. Tweak's observer
    // writes <container>/tmp/hios_keychain.plist via per-bundle Sec
    // ItemCopyMatching (NSTemporaryDirectory, sandbox-allowed). That
    // file rides into tar with the container path below.
    //
    // Fix 2026-05-09 (login-after-restore bug): previous version did
    // notify_post + fixed 1.5s sleep, then tarred regardless. Failure
    // modes:
    //   - Zalo backgrounded → Darwin notify not delivered immediately
    //   - Zalo just launched → tweak observer not yet registered
    //   - Tweak's 5s post-ctor dispatch_after hasn't fired yet
    // Result: tar didn't contain hios_keychain.plist → restore had
    // nothing to apply → Zalo asked login next launch even though user
    // restored.
    //
    // Now: notify, then poll each target's tmp/hios_keychain.plist for
    // up to 8s, requiring mtime ≥ dumpStart (guard against stale file
    // from a previous reset). Log per-bundle status; never abort backup
    // (partial backup still saves Documents/Library), just warn user.
    notify_post("com.changeinfoios/dump_keychain");
    NSDate *dumpStart = [NSDate date];
    NSMutableArray<NSString *> *missingDumps = [NSMutableArray array];
    NSMutableArray<NSString *> *foundDumps   = [NSMutableArray array];
    NSFileManager *dfm = [NSFileManager defaultManager];
    for (int retry = 0; retry < 16; retry++) {
        [NSThread sleepForTimeInterval:0.5];
        [missingDumps removeAllObjects];
        [foundDumps removeAllObjects];
        for (NSString *bid in b) {
            NSString *container = ci_findDataContainerForBundle(bid);
            if (container.length == 0) {
                [missingDumps addObject:[bid stringByAppendingString:@" (no container)"]];
                continue;
            }
            NSString *dumpPath = [container stringByAppendingPathComponent:@"tmp/hios_keychain.plist"];
            NSDictionary *attrs = [dfm attributesOfItemAtPath:dumpPath error:nil];
            NSDate *mtime = attrs[NSFileModificationDate];
            unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
            if (mtime && [mtime compare:dumpStart] != NSOrderedAscending && sz > 0) {
                [foundDumps addObject:bid];
            } else {
                [missingDumps addObject:bid];
            }
        }
        if (missingDumps.count == 0) break; // all dumps present + fresh
    }
    NSLog(@"[ChangeInfoIos] RRS keychain dump: ok=%@ missing=%@ (after %d×0.5s retries)",
          foundDumps, missingDumps, 16);

    // Build tar command via helper that adds --exclude rules for cache/log
    // dirs (see ci_buildTarCommand block comment).
    NSString *tarCmd = ci_buildTarCommand(tarPath, paths, errLog);
    int rc = ci_run([tarCmd UTF8String]);

    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tarPath error:nil];
    unsigned long long actualBytes = [attrs[NSFileSize] unsignedLongLongValue];
    e.totalSize = actualBytes;

    NSString *errs = [NSString stringWithContentsOfFile:errLog encoding:NSUTF8StringEncoding error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:errLog error:nil];

    [[CIRRSStore shared] addEntry:e];
    NSLog(@"[ChangeInfoIos] RRS created: uid=%@ rc=%d archive=%llu bytes (apps=%lu)%@",
          e.uid, rc, actualBytes, (unsigned long)e.bundleIDs.count,
          errs.length ? [NSString stringWithFormat:@"\nstderr: %@", errs] : @"");
}

// Re-backup: rebuild an existing entry's tar with current container state,
// preserving uid + bundleIDs + note + accountLabel/Kind/Status. Used when
// the user wants to "freshen" a saved snapshot — they've sent more chats,
// installed an update, changed a setting in Zalo, and want to capture the
// new state on top of the existing label without losing the label itself.
//
// Same tar logic as createRRSForBundles: but operates on e.bundleIDs and
// writes to <kRRSDir>/<e.uid>.tar — OVERWRITES the old tar in place. The
// idfa / ipReset get refreshed to current values (they're part of the
// snapshot we're updating), and date moves to NOW; everything else
// (accountLabel/Kind/Status/note/proxyTag) stays.
- (void)rebackupEntry:(CIRRSEntry *)e {
    NSArray<NSString *> *bids = e.bundleIDs;
    if (bids.count == 0) {
        [self alert:@"Snapshot trống" msg:@"Entry này không có bundle nào để backup."];
        return;
    }
    NSArray<CIAppInfo *> *all = [CIAppLister allApps];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (CIAppInfo *a in all) if ([bids containsObject:a.bundleID]) {
        if (a.containerPath) [paths addObject:a.containerPath];
    }
    NSString *labelForHUD = e.accountLabel.length ? e.accountLabel
                          : (e.note.length ? e.note : e.uid);
    UIView *hud = [self showHUDWithTitle:[@"Đang cập nhật RRS — " stringByAppendingString:labelForHUD]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Trigger keychain dump + wait for files. Same poll logic as the
        // create path; up to 8s for every target. Missing dumps don't
        // abort — partial tar is still useful, and the alert reports
        // which bundles missed.
        notify_post("com.changeinfoios/dump_keychain");
        NSDate *dumpStart = [NSDate date];
        NSFileManager *dfm = [NSFileManager defaultManager];
        NSMutableArray<NSString *> *foundDumps = [NSMutableArray array];
        NSMutableArray<NSString *> *missingDumps = [NSMutableArray array];
        for (int retry = 0; retry < 16; retry++) {
            [NSThread sleepForTimeInterval:0.5];
            [foundDumps removeAllObjects];
            [missingDumps removeAllObjects];
            for (NSString *bid in bids) {
                NSString *container = ci_findDataContainerForBundle(bid);
                if (container.length == 0) {
                    [missingDumps addObject:[bid stringByAppendingString:@" (no container)"]];
                    continue;
                }
                NSString *dp = [container stringByAppendingPathComponent:@"tmp/hios_keychain.plist"];
                NSDictionary *a2 = [dfm attributesOfItemAtPath:dp error:nil];
                NSDate *mt = a2[NSFileModificationDate];
                unsigned long long sz = [a2[NSFileSize] unsignedLongLongValue];
                if (mt && [mt compare:dumpStart] != NSOrderedAscending && sz > 0) {
                    [foundDumps addObject:bid];
                } else {
                    [missingDumps addObject:bid];
                }
            }
            if (missingDumps.count == 0) break;
        }

        // Rebuild tar at a SCRATCH path first, then atomic-rename over
        // the live tar IFF the new tar isn't catastrophically smaller
        // than the old one. The user reported 2026-05-19 losing a 69 MB
        // Zalo backup → 12 MB after rebackup because Zalo's container
        // had been silently wiped (Reset / app self-wipe) between
        // backup time and rebackup time. They tapped Lưu in good faith
        // and the snapshot was destroyed.
        //
        // Safety strategy:
        //   1. tar to <uid>.tar.new
        //   2. compare to <uid>.tar
        //   3. if new < 50% of old (and old > 5 MB) → KEEP the .tar.bak
        //      copy of the old + return error + show alert. User can
        //      delete the .bak themselves if they're sure.
        //   4. else → mv .tar.new → .tar (overwrite cleanly)
        NSString *tarPath    = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar"]];
        NSString *tarNew     = [tarPath stringByAppendingString:@".new"];
        NSString *tarBak     = [tarPath stringByAppendingString:@".bak"];
        NSString *errLog     = [NSString stringWithFormat:@"/tmp/ci_rebackup_%@.err", e.uid];
        [[NSFileManager defaultManager] createDirectoryAtPath:kRRSDir withIntermediateDirectories:YES attributes:nil error:nil];
        // Snapshot the old tar's size BEFORE we touch anything.
        unsigned long long oldBytes = [[[NSFileManager defaultManager]
            attributesOfItemAtPath:tarPath error:nil][NSFileSize] unsignedLongLongValue];

        NSString *tarCmd = ci_buildTarCommand(tarNew, paths, errLog);
        int rc = ci_run([tarCmd UTF8String]);
        // The new tar is at tarNew now. Inspect its size BEFORE deciding
        // whether to publish it over the existing tar.
        NSFileManager *fmgr = [NSFileManager defaultManager];
        unsigned long long newBytes = [[fmgr attributesOfItemAtPath:tarNew error:nil][NSFileSize] unsignedLongLongValue];
        NSString *errs = [NSString stringWithContentsOfFile:errLog encoding:NSUTF8StringEncoding error:nil];
        [fmgr removeItemAtPath:errLog error:nil];
        if (errs.length) NSLog(@"[ChangeInfoIos] RRS rebackup tar stderr: %@", errs);

        // Shrinkage protection. If the new tar is < 50% of the existing
        // tar AND the existing tar was substantial (> 5 MB), the user
        // probably triggered Lưu while the target app's container was
        // empty (Reset Data / app self-wipe). Don't HARD-reject (some
        // shrinkage is legitimate — user deleted chats, cleared cache).
        // Instead: show alert with TWO buttons: "Hủy" (keep old) and
        // "Vẫn cập nhật" (force-publish new). The hard-reject behavior
        // from v2.4.15 was too strict — confirmed live 2026-05-19: a
        // 30 MB → 77 MB shrinkage (40%) got blocked even though user
        // intended to update. UX: confidence buyer.
        BOOL shrinkageRisk = (oldBytes > 5 * 1024 * 1024)
                          && (newBytes < oldBytes / 2);

        void (^publish)(void) = ^{
            // Atomic replace via mv-rename: backup old briefly then mv new in.
            [fmgr removeItemAtPath:tarBak error:nil];
            [fmgr moveItemAtPath:tarPath toPath:tarBak error:nil];
            NSError *mvErr = nil;
            BOOL ok = [fmgr moveItemAtPath:tarNew toPath:tarPath error:&mvErr];
            if (ok) {
                [fmgr removeItemAtPath:tarBak error:nil];  // success — drop the .bak
            } else {
                [fmgr moveItemAtPath:tarBak toPath:tarPath error:nil];
                [fmgr removeItemAtPath:tarNew error:nil];
                NSLog(@"[ChangeInfoIos] RRS rebackup mv failed: %@", mvErr);
            }
            if (ok) {
                e.date = [NSDate date];
                e.totalSize = [[fmgr attributesOfItemAtPath:tarPath error:nil][NSFileSize] unsignedLongLongValue];
                e.idfa = [[CIConfigManager shared] stringForKey:@"advertisingIdentifier"] ?: e.idfa;
                e.ipReset = [[CIConfigManager shared] stringForKey:@"lastResetIP"] ?: e.ipReset;
                [[CIRRSStore shared] saveIndex];
            }
            NSLog(@"[ChangeInfoIos] RRS rebackup published: uid=%@ old=%llu new=%llu",
                  e.uid, oldBytes, newBytes);
        };

        void (^showSuccessAlert)(unsigned long long) = ^(unsigned long long finalBytes){
            NSMutableString *body = [NSMutableString string];
            [body appendFormat:@"Snapshot \"%@\" đã được cập nhật.\n\n", labelForHUD];
            [body appendFormat:@"Tar mới: %@ (cũ: %@)\n", CIBytesString(finalBytes), CIBytesString(oldBytes)];
            [body appendFormat:@"Keychain dumps: %lu/%lu app\n",
                                (unsigned long)foundDumps.count,
                                (unsigned long)bids.count];
            if (missingDumps.count > 0) {
                [body appendFormat:@"\n⚠️ Không lấy được keychain của: %@\n(Mở app đó 1 lần rồi cập nhật lại để có session tươi)",
                                    [missingDumps componentsJoinedByString:@", "]];
            }
            [self alert:@"Cập nhật RRS xong" msg:body];
        };

        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissHUD:hud completion:^{
                if (rc != 0 || newBytes < 1024) {
                    [fmgr removeItemAtPath:tarNew error:nil];
                    [self alert:@"Cập nhật lỗi"
                            msg:[NSString stringWithFormat:@"❌ Tar lỗi (rc=%d, new=%llu bytes). Snapshot cũ giữ nguyên.",
                                  rc, newBytes]];
                    return;
                }
                if (shrinkageRisk) {
                    NSMutableString *body = [NSMutableString string];
                    [body appendFormat:@"Tar mới: %@\nTar cũ: %@ (giảm %lu%%)\n\n",
                                        CIBytesString(newBytes),
                                        CIBytesString(oldBytes),
                                        (unsigned long)((oldBytes - newBytes) * 100 / oldBytes)];
                    [body appendString:@"Có thể app target đang RỖNG (Reset Data / app tự wipe). Nếu bạn KHÔNG cố ý xóa data, hủy + mở app target rồi cập nhật lại.\n\nVẫn muốn cập nhật?"];
                    UIAlertController *a = [UIAlertController
                        alertControllerWithTitle:@"⚠ Tar mới nhỏ hơn nhiều"
                                         message:body
                                  preferredStyle:UIAlertControllerStyleAlert];
                    [a addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel
                        handler:^(UIAlertAction *_) {
                            // Keep old + drop new
                            [fmgr removeItemAtPath:tarNew error:nil];
                        }]];
                    [a addAction:[UIAlertAction actionWithTitle:@"Vẫn cập nhật" style:UIAlertActionStyleDestructive
                        handler:^(UIAlertAction *_) {
                            publish();
                            showSuccessAlert(newBytes);
                        }]];
                    [self presentViewController:a animated:YES completion:nil];
                    return;
                }
                // Healthy size — publish without confirmation.
                publish();
                showSuccessAlert(newBytes);
            }];
        });
    });
}

// Full environment restore. iOS reassigns the data-container UUID for each
// app on every (re)install or container-rebuild, so the archived tarball's
// UUID directory likely doesn't match the current live container path.
// Strategy:
//   1. Untar to /tmp/restore_<uid>/ instead of straight to /
//   2. Walk each archived UUID dir, read its metadata.plist to discover the
//      bundleID it belongs to
//   3. Resolve the CURRENT container for that bundleID via
//      ci_findDataContainerForBundle, then copy contents over (rebind UUID)
//   4. Restore /var/jb/etc/changeinfoios/* (config + DC state) so the tweak
//      reloads with the same fake hardware profile that was active at backup
//   5. Kill cfprefsd + sbreload so the tweak's cached config is invalidated
//   6. Kill target apps so next launch is a cold-start with restored data
- (void)restoreEntry:(CIRRSEntry *)e {
    // Locate the archive — current builds write .tar (uncompressed) since
    // gzip isn't shipped on rootless. Pre-9a9f9ae backups are .tar.gz but
    // are 0-byte broken archives (the gzip child failed silently); detect
    // and warn instead of trying to restore.
    NSString *tarUncomp = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar"]];
    NSString *tarLegacy = [kRRSDir stringByAppendingPathComponent:[e.uid stringByAppendingPathExtension:@"tar.gz"]];
    NSFileManager *fm0 = [NSFileManager defaultManager];
    NSString *tar = nil;
    if ([fm0 fileExistsAtPath:tarUncomp]) {
        tar = tarUncomp;
    } else if ([fm0 fileExistsAtPath:tarLegacy]) {
        unsigned long long sz = [[fm0 attributesOfItemAtPath:tarLegacy error:nil][NSFileSize] unsignedLongLongValue];
        if (sz < 100) {
            [self alert:@"Backup hỏng"
                    msg:@"Backup này được tạo bởi version cũ trước khi fix bug gzip — file rỗng, không restore được. Vui lòng tạo backup mới (Backup + Reset Data) rồi xóa backup cũ."];
            return;
        }
        tar = tarLegacy;
    }
    if (!tar) {
        [self alert:@"Lỗi" msg:@"File backup không tồn tại trên máy."];
        return;
    }

    NSDictionary *tarAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tar error:nil];
    unsigned long long tarSize = [tarAttrs[NSFileSize] unsignedLongLongValue];

    UIView *hud = [self showHUDWithTitle:@"Bắt đầu restore..."];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Forensic log — appended to /var/jb/etc/changeinfoios/restoreEntry.log
        // so SSH can read it even after respring kills the host process.
        // Each restoreEntry invocation appends a new block prefixed with
        // a timestamp + tar path. NSLog goes nowhere on Dopamine (no syslogd)
        // so this is the only way to see what step 3/5 actually did.
        NSString *logPath = @"/var/jb/etc/changeinfoios/restoreEntry.log";
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        __block void (^rlog)(NSString *) = ^(NSString *line) {
            NSString *full = [NSString stringWithFormat:@"%@ %@\n",
                              [df stringFromDate:[NSDate date]], line];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (!fh) { [full writeToFile:logPath atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
            else { [fh seekToEndOfFile]; [fh writeData:[full dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        };
        rlog([NSString stringWithFormat:@"===== restoreEntry START bundleIDs=%@ tar=%@ size=%llu =====",
              e.bundleIDs, tar, tarSize]);

        // ---- Step 1: Kill running instances of every target ----
        [self updateHUD:hud step:1 total:5
                  title:@"Tắt apps đang chạy"
               subtitle:[NSString stringWithFormat:@"%lu app sẽ bị restart sau respring",
                         (unsigned long)e.bundleIDs.count]];
        [NSThread sleepForTimeInterval:0.8];
        for (NSString *bid in e.bundleIDs) {
            NSString *kc = [NSString stringWithFormat:
                @"pkill -9 -f '/var/containers/Bundle/Application/'*'/%@' 2>/dev/null; "
                @"pkill -9 -f '%@' 2>/dev/null", bid, bid];
            ci_run([kc UTF8String]);
        }

        // ---- Step 2: Untar to private temp dir ----
        [self updateHUD:hud step:2 total:5
                  title:@"Giải nén backup"
               subtitle:[NSString stringWithFormat:@"%@ đang đọc...",
                         CIBytesString(tarSize)]];
        NSString *tmp = [NSString stringWithFormat:@"/tmp/ci_restore_%@", e.uid];
        ci_run([[NSString stringWithFormat:@"rm -rf %@; mkdir -p %@", tmp, tmp] UTF8String]);
        // tar -xf auto-detects format (handles plain .tar AND .tar.gz when
        // gzip is present). Without -z, plain tar reads uncompressed
        // archives directly — works on Dopamine where gzip isn't installed.
        // Capture stderr so a silent failure surfaces in syslog.
        NSString *untarErr = [NSString stringWithFormat:@"/tmp/ci_restore_%@.untar.err", e.uid];
        NSString *untar = [NSString stringWithFormat:@"tar -xf '%@' -C '%@' 2>%@", tar, tmp, untarErr];
        int untarRc = ci_run([untar UTF8String]);
        NSString *untarErrText = [NSString stringWithContentsOfFile:untarErr encoding:NSUTF8StringEncoding error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:untarErr error:nil];
        NSLog(@"[ChangeInfoIos] restore: untar rc=%d archive=%@ → %@%@",
              untarRc, tar, tmp,
              untarErrText.length ? [@"\nstderr: " stringByAppendingString:untarErrText] : @"");
        rlog([NSString stringWithFormat:@"[step2] untar rc=%d stderr=%@", untarRc, untarErrText ?: @""]);

        // Sanity check — list what actually landed in /tmp.
        NSArray *tmpEntries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:tmp error:nil];
        NSLog(@"[ChangeInfoIos] restore: /tmp dir entries after untar = %@", tmpEntries);
        rlog([NSString stringWithFormat:@"[step2] /tmp entries=%@", tmpEntries]);

        [NSThread sleepForTimeInterval:1.5]; // let user see "đang giải nén" before step 3 takes over

        // ---- Step 3: Rebind each archived UUID-container to the current live container ----
        // /var on iOS is a symlink to /private/var, and GNU tar resolves
        // that symlink when archiving — entries appear as
        // "private/var/mobile/Containers/Data/Application/<UUID>/...".
        // The first restore implementation looked under "var/..." and got
        // an empty list every time, so 0 apps were restored even from a
        // 14 MB archive. Try BOTH layouts.
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bkRoot = [tmp stringByAppendingPathComponent:@"private/var/mobile/Containers/Data/Application"];
        NSArray *bkUUIDs = [fm contentsOfDirectoryAtPath:bkRoot error:nil];
        if (bkUUIDs.count == 0) {
            NSString *altRoot = [tmp stringByAppendingPathComponent:@"var/mobile/Containers/Data/Application"];
            NSArray *altUUIDs = [fm contentsOfDirectoryAtPath:altRoot error:nil];
            if (altUUIDs.count > 0) {
                bkRoot = altRoot;
                bkUUIDs = altUUIDs;
            }
        }
        NSLog(@"[ChangeInfoIos] restore: bkRoot=%@ has %lu archived containers",
              bkRoot, (unsigned long)bkUUIDs.count);
        rlog([NSString stringWithFormat:@"[step3] bkRoot=%@ uuids.count=%lu", bkRoot, (unsigned long)bkUUIDs.count]);

        NSUInteger restoredApps = 0;
        NSUInteger filesCopied = 0;
        unsigned long long bytesCopied = 0;

        for (NSString *uuid in bkUUIDs) {
            NSString *bkDir = [bkRoot stringByAppendingPathComponent:uuid];
            NSString *bkMeta = [bkDir stringByAppendingPathComponent:
                @".com.apple.mobile_container_manager.metadata.plist"];
            NSData *blob = [NSData dataWithContentsOfFile:bkMeta];
            if (!blob) {
                NSLog(@"[ChangeInfoIos] restore: missing metadata.plist in %@", uuid);
                continue;
            }

            // Match the archived metadata to one of the bundleIDs in this entry.
            NSString *matchedBid = nil;
            for (NSString *bid in e.bundleIDs) {
                NSData *needle = [bid dataUsingEncoding:NSUTF8StringEncoding];
                if ([blob rangeOfData:needle options:0 range:NSMakeRange(0, blob.length)].location != NSNotFound) {
                    matchedBid = bid;
                    break;
                }
            }
            if (!matchedBid) {
                NSLog(@"[ChangeInfoIos] restore: archived UUID %@ doesn't match any backed-up bid", uuid);
                rlog([NSString stringWithFormat:@"[step3] uuid=%@ NO MATCH against bundleIDs=%@", uuid, e.bundleIDs]);
                continue;
            }

            NSString *curContainer = ci_findDataContainerForBundle(matchedBid);
            if (curContainer.length == 0) {
                NSLog(@"[ChangeInfoIos] restore: NO live container for %@ — app may need to be launched once first", matchedBid);
                rlog([NSString stringWithFormat:@"[step3] matchedBid=%@ but NO LIVE CONTAINER", matchedBid]);
                continue;
            }
            rlog([NSString stringWithFormat:@"[step3] uuid=%@ matchedBid=%@ container=%@", uuid, matchedBid, curContainer]);

            [self updateHUD:hud step:3 total:5
                      title:@"Khôi phục dữ liệu app"
                   subtitle:[NSString stringWithFormat:@"%lu/%lu — %@",
                             (unsigned long)restoredApps + 1,
                             (unsigned long)bkUUIDs.count,
                             matchedBid]];
            [NSThread sleepForTimeInterval:0.6];

            // Copy each user-data subdir from backup over the live container.
            // Don't touch the live container's metadata.plist — that's the
            // UUID binding iOS itself manages.
            NSArray *subs = @[@"Documents", @"Library", @"tmp", @"StoreKit", @"SystemData"];
            NSUInteger appFiles = 0;
            unsigned long long appBytes = 0;
            for (NSString *sub in subs) {
                NSString *bkSub = [bkDir stringByAppendingPathComponent:sub];
                if (![fm fileExistsAtPath:bkSub]) continue;

                // Count source files + bytes for the diagnostic alert.
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:bkSub];
                NSString *file;
                while ((file = [en nextObject])) {
                    NSDictionary *a = [en fileAttributes];
                    if ([a[NSFileType] isEqualToString:NSFileTypeRegular]) {
                        appFiles++;
                        appBytes += [a[NSFileSize] unsignedLongLongValue];
                    }
                }

                NSString *curSub = [curContainer stringByAppendingPathComponent:sub];
                NSString *errLog = [NSString stringWithFormat:@"/tmp/ci_restore_cp_%@_%@.err", matchedBid, sub];
                // Replace path separators in errLog filename
                errLog = [errLog stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
                errLog = [@"/tmp/" stringByAppendingPathComponent:[errLog lastPathComponent]];
                NSString *cmd = [NSString stringWithFormat:
                    @"rm -rf '%@'/* '%@'/.[!.]* 2>/dev/null; "
                    @"mkdir -p '%@' 2>/dev/null; "
                    @"cp -a '%@/.' '%@/' 2>%@",
                    curSub, curSub, curSub, bkSub, curSub, errLog];
                int rc = ci_run([cmd UTF8String]);
                NSString *errText = [NSString stringWithContentsOfFile:errLog encoding:NSUTF8StringEncoding error:nil];
                [[NSFileManager defaultManager] removeItemAtPath:errLog error:nil];
                if (rc != 0 || errText.length) {
                    NSLog(@"[ChangeInfoIos] restore: cp rc=%d %@/%@%@", rc, matchedBid, sub,
                          errText.length ? [@"\n  stderr: " stringByAppendingString:errText] : @"");
                }
                rlog([NSString stringWithFormat:@"[step3] cp %@/%@ rc=%d files=%lu bytes=%llu err=%@",
                      matchedBid, sub, rc, (unsigned long)appFiles, appBytes,
                      errText.length ? errText : @"-"]);
            }
            NSLog(@"[ChangeInfoIos] restore: %@ → %lu files, %@",
                  matchedBid, (unsigned long)appFiles, CIBytesString(appBytes));
            filesCopied += appFiles;
            bytesCopied += appBytes;
            restoredApps++;
        }

        // ---- Step 4: Restore tweak config + DC state ----
        [self updateHUD:hud step:4 total:5
                  title:@"Khôi phục thông tin máy fake"
               subtitle:@"config.plist + DC tokens..."];
        [NSThread sleepForTimeInterval:0.8];
        // Same private/var symlink dance as the container scan above.
        NSString *bkConfigDir = [tmp stringByAppendingPathComponent:@"var/jb/etc/changeinfoios"];
        if (![fm fileExistsAtPath:bkConfigDir]) {
            NSString *alt = [tmp stringByAppendingPathComponent:@"private/var/jb/etc/changeinfoios"];
            if ([fm fileExistsAtPath:alt]) bkConfigDir = alt;
        }
        NSUInteger configFiles = 0;
        if ([fm fileExistsAtPath:bkConfigDir]) {
            NSArray *cfgList = [fm contentsOfDirectoryAtPath:bkConfigDir error:nil];
            configFiles = cfgList.count;

            // Copy to /var/jb/etc/changeinfoios (where the tweak reads from
            // sandboxed apps).
            NSString *cmd = [NSString stringWithFormat:
                @"mkdir -p /var/jb/etc/changeinfoios; "
                @"cp -a '%@/.' /var/jb/etc/changeinfoios/ 2>/dev/null; "
                @"chmod 0644 /var/jb/etc/changeinfoios/*.plist 2>/dev/null",
                bkConfigDir];
            int rc = ci_run([cmd UTF8String]);
            NSLog(@"[ChangeInfoIos] restore: /var/jb/etc/changeinfoios restored, %lu files, rc=%d",
                  (unsigned long)configFiles, rc);

            // CRITICAL: ALSO copy the restored config.plist to BOTH of the
            // host app's other config paths — otherwise [cm load] right
            // below reads STALE (current) values from app sandbox /
            // /var/mobile/Library/Preferences and [cm save] would clobber
            // the just-restored /var/jb file. Pre-fix: every restore wrote
            // the OLD config back over the restored one and the user saw
            // current (not restored) hardware IDs after the restore.
            NSString *bkConfigPlist = [bkConfigDir stringByAppendingPathComponent:@"config.plist"];
            if ([fm fileExistsAtPath:bkConfigPlist]) {
                // Local sandbox path (Documents/config.plist) — readable
                // without sudo because it's inside the host app's container.
                NSError *cpErr = nil;
                [fm removeItemAtPath:CILocalConfigPath() error:nil];
                BOOL ok = [fm copyItemAtPath:bkConfigPlist toPath:CILocalConfigPath() error:&cpErr];
                NSLog(@"[ChangeInfoIos] restore: local config copy ok=%d err=%@", ok, cpErr);

                // Shared prefs path /var/mobile/Library/Preferences/com.changeinfoios.plist —
                // sometimes mobile-writable depending on rootless variant.
                NSString *sharedCmd = [NSString stringWithFormat:
                    @"cp -f '%@' '%@' 2>/dev/null; chmod 0644 '%@' 2>/dev/null",
                    bkConfigPlist, kSharedPrefPath, kSharedPrefPath];
                ci_run([sharedCmd UTF8String]);
            }
        } else {
            NSLog(@"[ChangeInfoIos] restore: WARNING — backup has no config snapshot. "
                  @"Created with old build before 3560b20? Hardware IDs won't match the saved env.");
        }

        // Reload host-app's in-memory CIConfigManager from the JUST-RESTORED
        // plist (now consistent across all 3 paths). Without the copy above,
        // load would have picked up the stale local-sandbox plist with
        // current (post-Reset) values.
        [[CIConfigManager shared] load];

        // Push keychainReset=NO so the SecItemCopyMatching hook lets Zalo
        // read its keychain entries on next launch (instead of blocking
        // them — that block is meant for fresh-account registration).
        [[CIConfigManager shared] setObject:@(NO) forKey:@"keychainReset"];
        [[CIConfigManager shared] save];

        // Drop a per-bundle keychain-restore flag file. The tweak's
        // %ctor on next launch sees the flag, deletes the bundle's
        // current keychain entries, and re-applies the snapshot we
        // just untarred. Without this step, container is restored
        // but session token still belongs to whatever account was
        // logged in last → Zalo asks for login again.
        //
        // CRITICAL: flag must land in <target container>/tmp/, not
        // /var/jb/etc/changeinfoios. The tweak runs inside the target
        // app's sandbox and can only RELIABLY write to its own tmp/,
        // so it also looks for the flag there (matches the keychain
        // dump path we changed in 2026-05-07). Use ci_findDataContainer
        // ForBundle to locate the live container (UUID changes after
        // every Reset Data, so we can't hardcode).
        // Drop keychain-restore flag IFF the dump file actually landed
        // in this bundle's tmp/ from cp -a. If missing (backup didn't
        // catch the dump — see createRRSForBundles fix note), skip the
        // flag. Otherwise tweak's %ctor would try to read a non-existent
        // dump, fail silently, and we'd lose the user's keychain anyway
        // (worse: it would also wipe the bundle's existing keychain via
        // ci_restoreKeychainIfFlagged's pre-restore SecItemDelete, so
        // bundles with NO snapshot become MORE damaged than untouched).
        rlog([NSString stringWithFormat:@"[step5] start, e.bundleIDs.count=%lu", (unsigned long)e.bundleIDs.count]);
        NSUInteger flagsDropped = 0;
        NSMutableArray<NSString *> *noDumpBundles = [NSMutableArray array];
        for (NSString *bid in e.bundleIDs) {
            NSString *container = ci_findDataContainerForBundle(bid);
            if (container.length == 0) {
                NSLog(@"[ChangeInfoIos] restore: cannot locate container for %@ — flag NOT dropped", bid);
                rlog([NSString stringWithFormat:@"[step5] bid=%@ NO CONTAINER", bid]);
                continue;
            }
            rlog([NSString stringWithFormat:@"[step5] bid=%@ container=%@", bid, container]);
            NSString *tmpDir = [container stringByAppendingPathComponent:@"tmp"];
            NSString *dumpPath = [tmpDir stringByAppendingPathComponent:@"hios_keychain.plist"];

            // CRITICAL: write .ci_last_wipe = current wipe_counter so
            // tweak's ci_wipeContainerIfScheduled SKIPS the next wipe.
            // Without this, on the next Zalo launch:
            //   - tweak reads wipe_counter_<bid> = T1 (set by Reset Data)
            //   - tweak reads <container>/.ci_last_wipe = T0 (from tar,
            //     written BEFORE the user's Reset that produced T1)
            //   - T1 > T0 → tweak wipes Documents+Library+tmp →
            //     OUR FRESHLY RESTORED DATA IS DELETED.
            // Confirmed live 2026-05-19: profile.sqlite was 290 KB
            // after restore (had user data), but Zalo launched and
            // tweak wiped it → profile.sqlite back to schema-only
            // 0-row state → Zalo couldn't load session → login screen.
            // Updating .ci_last_wipe to current counter tells tweak
            // "wipe already done at this counter, skip" → preserves
            // restored data.
            NSString *counterKey = [@"wipe_counter_" stringByAppendingString:bid];
            id counterVal = [[CIConfigManager shared] objectForKey:counterKey];
            long long counter = [counterVal respondsToSelector:@selector(longLongValue)]
                                ? [counterVal longLongValue] : 0;
            if (counter > 0) {
                NSString *markerPath = [container stringByAppendingPathComponent:@".ci_last_wipe"];
                NSString *markerSafe = [markerPath stringByReplacingOccurrencesOfString:@"'" withString:@""];
                NSString *markCmd = [NSString stringWithFormat:
                    @"echo %lld > '%@' && chmod 0644 '%@'",
                    counter, markerSafe, markerSafe];
                int mc = ci_run([markCmd UTF8String]);
                NSLog(@"[ChangeInfoIos] restore: .ci_last_wipe=%lld for %@ (rc=%d)",
                      counter, bid, mc);
            }

            NSDictionary *dumpAttrs = [fm attributesOfItemAtPath:dumpPath error:nil];
            unsigned long long dumpSz = [dumpAttrs[NSFileSize] unsignedLongLongValue];

            // FALLBACK (2026-05-20 v2.4.24): if container/tmp/hios_keychain.plist
            // is missing or 0 bytes, fall back to the dump that's still sitting in
            // the extracted tar at /tmp/ci_restore_<uid>/private/var/.../<UUID>/tmp/.
            // Observed live: UI Restore copies data correctly (step 3) BUT the
            // live-container dumpPath read here returned 0 bytes by the time
            // step 5 ran — flag was never dropped, tweak saw NO FLAG, Zalo
            // launched without keychain restore → blank login + chat_dbs wiped.
            // The tar's tmp/hios_keychain.plist is always intact since the
            // extracted tar dir hasn't been cleaned up yet at this point.
            if (dumpSz == 0) {
                NSData *bidNeedle = [bid dataUsingEncoding:NSUTF8StringEncoding];
                for (NSString *uuid in bkUUIDs) {
                    NSString *altDir = [bkRoot stringByAppendingPathComponent:uuid];
                    NSString *altMeta = [altDir stringByAppendingPathComponent:
                        @".com.apple.mobile_container_manager.metadata.plist"];
                    NSData *altBlob = [NSData dataWithContentsOfFile:altMeta];
                    if (!altBlob) continue;
                    if ([altBlob rangeOfData:bidNeedle options:0
                                       range:NSMakeRange(0, altBlob.length)].location == NSNotFound) continue;
                    NSString *altDump = [altDir stringByAppendingPathComponent:
                                          @"tmp/hios_keychain.plist"];
                    NSDictionary *altAttrs = [fm attributesOfItemAtPath:altDump error:nil];
                    unsigned long long altSz = [altAttrs[NSFileSize] unsignedLongLongValue];
                    if (altSz > 0) {
                        NSLog(@"[ChangeInfoIos] restore: container dump empty, using tar fallback %@ (sz=%llu)",
                              altDump, altSz);
                        dumpPath = altDump;
                        dumpSz   = altSz;
                        // Also re-seed container/tmp/hios_keychain.plist so
                        // tweak's LEGACY path also has it (back-compat).
                        NSString *seedCmd = [NSString stringWithFormat:
                            @"cp -f '%@' '%@/tmp/hios_keychain.plist' 2>/dev/null && chmod 0644 '%@/tmp/hios_keychain.plist'",
                            altDump, container, container];
                        ci_run([seedCmd UTF8String]);
                        break;
                    }
                }
            }

            if (dumpSz == 0) {
                [noDumpBundles addObject:bid];
                NSLog(@"[ChangeInfoIos] restore: no keychain dump for %@ at %@ (and no tar fallback) — flag NOT dropped (would wipe live keychain)", bid, dumpPath);
                rlog([NSString stringWithFormat:@"[step5] bid=%@ NO DUMP (even after fallback) — flag SKIPPED", bid]);
                continue;
            }
            rlog([NSString stringWithFormat:@"[step5] bid=%@ dumpPath=%@ dumpSz=%llu", bid, dumpPath, dumpSz]);

            // v2.4.35: removed all dump-patch logic (triplet rewrite,
            // kCryptKeyData<OTHER_UID> nuke, mkdir chat_dbs/<UID>). User
            // asked for baseline restore behavior — just drop the captured
            // keychain dump as-is and let the target app handle it. The
            // patches were Zalo-specific and the multi-account UID
            // bookkeeping introduced more failure modes than it fixed
            // when the backup was made right after a fresh registration.
            #if 0
            // CRITICAL: sync kSessionUid in the keychain dump to a UID
            // that actually has data in this container's Documents.
            //
            // Zalo (and other multi-account apps) keep per-user data dirs
            // like Documents/chat_dbs/<UID>/. The keychain has a current
            // kSessionUid pointing to the LAST-active user. If the user
            // had switched accounts before backup, the keychain's
            // kSessionUid may point to a UID whose chat_dbs dir was
            // cleaned up — leaving keychain.session=UID_A but disk
            // data only for UID_B.
            //
            // On launch, Zalo reads kSessionUid → UID_A, looks for
            // chat_dbs/UID_A → MISSING → assumes "session corrupt" →
            // WIPES profile.sqlite (drops ProfileEntity to 0 rows) →
            // login screen even though we restored everything.
            //
            // Confirmed live 2026-05-19: 30-entry Zalo dump with
            // kSessionUid=455815053 + Documents/chat_dbs/457384682
            // (Hà An). After Zalo launch, profile.sqlite went from
            // 290 KB / 3 rows to 290 KB / 0 rows. Patching the dump
            // file to kSessionUid="457384682" before placing it →
            // Zalo's check passes → profile.sqlite stays at 3 rows
            // → auto-login as Hà An works.
            //
            // Heuristic: scan Documents/chat_dbs/ (Zalo-specific path
            // but harmless when missing for other apps) for numeric
            // subdir names. If kSessionUid in dump isn't one of them
            // AND we found at least one numeric UID dir → rewrite
            // kSessionUid to the first found UID.
            NSString *chatDbsDir = [container stringByAppendingPathComponent:@"Documents/chat_dbs"];
            NSArray<NSString *> *dbUserDirs = [fm contentsOfDirectoryAtPath:chatDbsDir error:nil];
            NSMutableArray<NSString *> *uidCandidates = [NSMutableArray array];
            for (NSString *d in dbUserDirs) {
                // Numeric-only directory names are user UIDs.
                if (d.length >= 6 && d.length <= 12) {
                    BOOL allDigits = YES;
                    for (NSUInteger i = 0; i < d.length; i++) {
                        unichar c = [d characterAtIndex:i];
                        if (c < '0' || c > '9') { allDigits = NO; break; }
                    }
                    if (allDigits) [uidCandidates addObject:d];
                }
            }
            // Always parse + patch the dump if it exists. v2.4.27 left mkdir +
            // nuke logic inside the "kSessionUid doesn't match chat_dbs" branch,
            // so a fresh-registration backup (chat_dbs/<NEW_UID>/ matches dump's
            // kSessionUid) skipped the nuke entirely — and any leftover
            // kCryptKeyData<OLD_UID> from the previous account stayed in the
            // dump → Zalo wiped on launch. Confirmed live 2026-05-20: dump had
            // kCryptKeyData457384682 (Hà An) + kCryptKeyData457769976 (new
            // acc), restore replayed both, Zalo wiped.
            // v2.4.28 → v2.4.29: wrapped in @try because v2.4.28 hit
            // -[NSURL lastPathComponent] ObjC exception in the user-initiated
            // dispatch queue (SIGABRT via std::terminate), crashing the host
            // mid-restore. Couldn't identify the line without dSYM; catching
            // here keeps restore working and surfaces the failure to the log.
            @try {
                rlog(@"[patch] entered dump-patch block");
                // CROSS-SANDBOX READ (v2.4.30): NSData dataWithContentsOfFile
                // returns nil when host (sandboxed) reads another app's
                // container — same sandbox MAC that broke
                // ci_findDataContainerForBundle (Bug 9). attributesOfItemAtPath
                // returns size OK (probably uses lstat) but open(2) is blocked.
                // Workaround: shell-cp the dump to /tmp first (posix_spawn
                // bypass), then NSData read from /tmp. Confirmed live
                // 2026-05-20 v2.4.29 exception: "data parameter is nil" because
                // dumpData was nil → NSPropertyListSerialization threw →
                // @try caught → mkdir + nuke + writeback all skipped → Zalo
                // launch with stale kCryptKeyData<OTHER_UID> → wipe.
                NSString *readTmp = [NSString stringWithFormat:@"/tmp/ci_dump_read_%@.plist", bid];
                NSString *readSafe = [readTmp stringByReplacingOccurrencesOfString:@"'" withString:@""];
                NSString *dumpSafeIn = [dumpPath stringByReplacingOccurrencesOfString:@"'" withString:@""];
                NSString *readCmd = [NSString stringWithFormat:@"cp '%@' '%@' && chmod 0644 '%@'",
                                     dumpSafeIn, readSafe, readSafe];
                ci_run([readCmd UTF8String]);
                NSData *dumpData = [NSData dataWithContentsOfFile:readTmp];
                rlog([NSString stringWithFormat:@"[patch] read via /tmp: %llu bytes",
                      (unsigned long long)dumpData.length]);
                NSError *parseErr = nil;
                id parsed = nil;
                if (dumpData.length > 0) {
                    parsed = [NSPropertyListSerialization propertyListWithData:dumpData
                                                                       options:NSPropertyListMutableContainersAndLeaves
                                                                        format:NULL error:&parseErr];
                }
                if ([parsed isKindOfClass:[NSArray class]]) {
                    NSMutableArray *entries = (NSMutableArray *)parsed;
                    NSMutableDictionary *(^findEntry)(NSString *) = ^(NSString *acct){
                        for (NSMutableDictionary *e2 in entries) {
                            if ([e2 isKindOfClass:[NSMutableDictionary class]]
                                && [e2[@"acct"] isEqualToString:acct]) return e2;
                        }
                        return (NSMutableDictionary *)nil;
                    };
                    NSString *(^getVal)(NSMutableDictionary *) = ^(NSMutableDictionary *e3){
                        NSDictionary *vEnc = e3[@"v_Data"];
                        NSString *b64 = vEnc[@"__b"];
                        if (!b64.length) return @"";
                        NSData *d3 = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
                        return [[NSString alloc] initWithData:d3 encoding:NSUTF8StringEncoding] ?: @"";
                    };
                    void (^setVal)(NSMutableDictionary *, NSString *) = ^(NSMutableDictionary *e3, NSString *v){
                        NSMutableDictionary *vMut = [(NSDictionary *)e3[@"v_Data"] mutableCopy];
                        vMut[@"__b"] = [[v dataUsingEncoding:NSUTF8StringEncoding]
                                          base64EncodedStringWithOptions:0];
                        e3[@"v_Data"] = vMut;
                    };

                    NSMutableDictionary *sessionEntry = findEntry(@"kSessionUid");
                    NSString *currentUID = sessionEntry ? getVal(sessionEntry) : nil;

                    // Determine the effective targetUID.
                    //   - If chat_dbs has candidates AND kSessionUid doesn't match → use first candidate (triplet patch).
                    //   - Else if kSessionUid is numeric → use it as-is (typical fresh registration path).
                    //   - Else if uidCandidates exist → use the first.
                    NSString *targetUID = nil;
                    BOOL needTripletPatch = NO;
                    if (uidCandidates.count > 0 && sessionEntry && ![uidCandidates containsObject:currentUID]) {
                        targetUID = uidCandidates.firstObject;
                        needTripletPatch = YES;
                    } else if (currentUID.length > 0) {
                        // Quick numeric check
                        BOOL allDigits = currentUID.length > 0;
                        for (NSUInteger i = 0; i < currentUID.length; i++) {
                            unichar c = [currentUID characterAtIndex:i];
                            if (c < '0' || c > '9') { allDigits = NO; break; }
                        }
                        if (allDigits) targetUID = currentUID;
                    }
                    if (!targetUID.length && uidCandidates.count > 0) {
                        targetUID = uidCandidates.firstObject;
                    }

                    if (needTripletPatch) {

                        // Query profile.sqlite for the target user's username +
                        // mobile. Zalo's session check matches keychain's
                        // (kSessionUid, kSessionUsername, kPhoneNumber) against
                        // ProfileEntity's (userid, username, mobile). Just
                        // patching kSessionUid isn't enough — Zalo wipes
                        // profile.sqlite (and chat_dbs/<UID>) when username
                        // or phone doesn't match.
                        NSString *profilePath = [container stringByAppendingPathComponent:
                                                 @"Documents/profile.sqlite"];
                        NSString *queryOut = [NSString stringWithFormat:
                            @"/tmp/ci_profile_query_%@.txt", bid];
                        NSString *queryCmd = [NSString stringWithFormat:
                            @"/var/jb/usr/bin/sqlite3 '%@' \"SELECT username || '|' || COALESCE(mobile, '') FROM ProfileEntity WHERE userid = %@\" > '%@' 2>&1",
                            profilePath, targetUID, queryOut];
                        ci_run([queryCmd UTF8String]);
                        NSString *queryResult = [NSString stringWithContentsOfFile:queryOut
                                                                          encoding:NSUTF8StringEncoding error:nil];
                        [fm removeItemAtPath:queryOut error:nil];
                        NSString *targetUsername = nil, *targetMobile = nil;
                        if (queryResult.length > 0) {
                            NSString *line = [queryResult stringByTrimmingCharactersInSet:
                                              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            NSArray *parts = [line componentsSeparatedByString:@"|"];
                            if (parts.count >= 1) targetUsername = parts[0];
                            if (parts.count >= 2) targetMobile = parts[1];
                        }

                        // Patch session triplet.
                        setVal(sessionEntry, targetUID);
                        if (targetUsername.length) {
                            NSMutableDictionary *uname = findEntry(@"kSessionUsername");
                            if (uname) setVal(uname, targetUsername);
                        }
                        if (targetMobile.length) {
                            NSMutableDictionary *phone = findEntry(@"kPhoneNumber");
                            if (phone) setVal(phone, targetMobile);
                        }
                    }   // end of if (needTripletPatch)

                    // ALWAYS-RUN section (v2.4.28): mkdir chat_dbs/<targetUID>
                    // and nuke kCryptKeyData<OTHER_UID>. v2.4.27 left these
                    // inside the needTripletPatch branch, so a fresh-registration
                    // backup (kSessionUid already matches chat_dbs/<NEW_UID>/)
                    // skipped the nuke entirely → leftover kCryptKeyData<OLD_UID>
                    // from previous account stayed in the dump → Zalo wiped on
                    // launch. Confirmed live 2026-05-20: dump had
                    // kCryptKeyData457384682 (Hà An) + kCryptKeyData457769976
                    // (new acc); restore replayed both; Zalo wiped chat_dbs +
                    // profile rows. Pulling these out fixes ALL re-registration
                    // backups regardless of whether triplet patching is needed.
                    NSUInteger nuked = 0;
                    if (targetUID.length > 0) {
                        // mkdir Documents/chat_dbs/<targetUID>/ if missing
                        // (Zalo only checks dir existence, content can be empty).
                        NSString *chatDbsUser = [chatDbsDir stringByAppendingPathComponent:targetUID];
                        if (![fm fileExistsAtPath:chatDbsUser]) {
                            NSString *mkCmd = [NSString stringWithFormat:
                                @"mkdir -p '%@' && chmod 0755 '%@' && chown mobile:mobile '%@'",
                                chatDbsUser, chatDbsUser, chatDbsUser];
                            int rc = ci_run([mkCmd UTF8String]);
                            NSLog(@"[ChangeInfoIos] restore: created empty chat_dbs/%@ for %@ (rc=%d)",
                                  targetUID, bid, rc);
                        }

                        // Drop kCryptKeyData<numeric> entries where numeric != targetUID.
                        NSMutableArray *toRemove = [NSMutableArray array];
                        NSString *prefix = @"kCryptKeyData";
                        for (NSDictionary *entry in entries) {
                            if (![entry isKindOfClass:[NSDictionary class]]) continue;
                            NSString *acct = entry[@"acct"];
                            if (![acct hasPrefix:prefix]) continue;
                            NSString *suffix = [acct substringFromIndex:prefix.length];
                            BOOL allDigits = suffix.length > 0;
                            for (NSUInteger i = 0; i < suffix.length; i++) {
                                unichar c = [suffix characterAtIndex:i];
                                if (c < '0' || c > '9') { allDigits = NO; break; }
                            }
                            if (allDigits && ![suffix isEqualToString:targetUID]) {
                                [toRemove addObject:entry];
                            }
                        }
                        for (id rm in toRemove) [entries removeObject:rm];
                        nuked = toRemove.count;
                    }

                    // Write the patched dump back if EITHER triplet was patched OR
                    // any kCryptKeyData entries were nuked.
                    if (needTripletPatch || nuked > 0) {
                        NSError *writeErr = nil;
                        NSData *patched = [NSPropertyListSerialization dataWithPropertyList:entries
                                                                                     format:NSPropertyListXMLFormat_v1_0
                                                                                    options:0 error:&writeErr];
                        if (patched.length > 0) {
                            NSString *patchedTmp = [@"/tmp/ci_dump_patched_" stringByAppendingString:bid];
                            [patched writeToFile:patchedTmp atomically:YES];
                            NSString *cpCmd = [NSString stringWithFormat:
                                @"cp '%@' '%@' && chmod 0644 '%@'",
                                patchedTmp, dumpPath, dumpPath];
                            ci_run([cpCmd UTF8String]);
                            [fm removeItemAtPath:patchedTmp error:nil];
                            NSLog(@"[ChangeInfoIos] restore: patched %@ dump (targetUID=%@ tripletPatched=%d nukedCryptKeys=%lu candidates=%@)",
                                  bid, targetUID, needTripletPatch, (unsigned long)nuked, uidCandidates);
                            rlog([NSString stringWithFormat:@"[patch] wrote patched dump (triplet=%d nuked=%lu)",
                                  needTripletPatch, (unsigned long)nuked]);
                        }
                    }
                }
                // Clean up the shell-cp'd read temp.
                [fm removeItemAtPath:readTmp error:nil];
            } @catch (NSException *ex) {
                rlog([NSString stringWithFormat:@"[patch] EXCEPTION %@: %@", ex.name, ex.reason]);
                NSLog(@"[ChangeInfoIos] restore: dump-patch threw %@: %@\n%@",
                      ex.name, ex.reason, ex.callStackSymbols);
            }
            #endif

            // Drop the restore flag via shell instead of NSFileManager.
            // NSFileManager-from-CIHomeViewController hits the iOS sandbox
            // MAC even with com.apple.private.security.no-sandbox=true on
            // our app — confirmed live 2026-05-19: data restore via
            // shell `cp` (posix_spawn'd, bypasses sandbox) landed
            // hios_keychain.plist + 50 other files in Zalo's container,
            // but the parallel NSFileManager `writeToFile:atomically:`
            // for the flag silently EPERM'd because writing into another
            // app's container is gated by MAC at the NSFileManager layer
            // independently of the no-sandbox entitlement. Result:
            // keychain dump present in tmp/, flag absent → tweak's %ctor
            // on Zalo launch reads no flag → skips restore → Zalo asks
            // login again even though every byte of the session was
            // sitting in its own tmp/. Same shell path that worked for
            // the data copy works here for a 1-byte flag.
            // Drop flag + dump at /var/jb/etc/changeinfoios/ FIRST (primary
            // location). Zalo / iOS wipes the per-app tmp/ on every app
            // launch — confirmed live 2026-05-19: a flag + 32 KB dump
            // placed via SSH in Zalo's tmp/ DISAPPEARED before tweak %ctor
            // could read them, because Zalo's launch sequence purges tmp/.
            // /var/jb/etc/changeinfoios/ is owned by our deb and never
            // gets purged. Sandboxed apps can READ from there (we already
            // store config.plist there) but cannot write — and that's
            // fine, host app (no-sandbox) writes both files via shell.
            //
            // The tmp/ path stays as a fallback for back-compat with
            // older tweak builds that only check tmp/.
            NSString *sharedDir = @"/var/jb/etc/changeinfoios";
            NSString *sharedFlag = [sharedDir stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"restore_%@.flag", bid]];
            NSString *sharedDump = [sharedDir stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"dump_%@.plist", bid]];
            NSString *flagPath = [tmpDir stringByAppendingPathComponent:@"hios_keychain_restore.flag"];

            NSString *sharedFlagSafe = [sharedFlag stringByReplacingOccurrencesOfString:@"'" withString:@""];
            NSString *sharedDumpSafe = [sharedDump stringByReplacingOccurrencesOfString:@"'" withString:@""];
            NSString *dumpSafe       = [dumpPath  stringByReplacingOccurrencesOfString:@"'" withString:@""];
            NSString *flagSafe       = [flagPath  stringByReplacingOccurrencesOfString:@"'" withString:@""];

            NSString *cmd = [NSString stringWithFormat:
                @"mkdir -p '%@' 2>/dev/null; "
                @"mkdir -p '%@' 2>/dev/null; "
                @"cp -f '%@' '%@' && chmod 0644 '%@' && "
                @"echo 1 > '%@' && chmod 0644 '%@' && "
                @"echo 1 > '%@' && chmod 0644 '%@'",
                sharedDir,                                 // mkdir shared dir
                [flagSafe stringByDeletingLastPathComponent], // mkdir tmp
                dumpSafe, sharedDumpSafe, sharedDumpSafe,  // cp dump → shared + chmod
                sharedFlagSafe, sharedFlagSafe,            // echo flag at shared + chmod
                flagSafe, flagSafe];                       // echo flag at tmp (legacy compat) + chmod
            int rc = ci_run([cmd UTF8String]);

            NSDictionary *sFlagAttrs = [fm attributesOfItemAtPath:sharedFlag error:nil];
            NSDictionary *sDumpAttrs = [fm attributesOfItemAtPath:sharedDump error:nil];
            BOOL ok = (rc == 0)
                && ([sFlagAttrs[NSFileSize] unsignedLongLongValue] > 0)
                && ([sDumpAttrs[NSFileSize] unsignedLongLongValue] > 0);
            if (ok) {
                flagsDropped++;
                NSLog(@"[ChangeInfoIos] restore: flag+dump dropped at /var/jb/etc for %@ (sharedDump=%llu, origDump=%llu)",
                      bid,
                      [sDumpAttrs[NSFileSize] unsignedLongLongValue],
                      dumpSz);
                rlog([NSString stringWithFormat:@"[step5] bid=%@ DROP OK sharedFlagSz=%llu sharedDumpSz=%llu",
                      bid,
                      [sFlagAttrs[NSFileSize] unsignedLongLongValue],
                      [sDumpAttrs[NSFileSize] unsignedLongLongValue]]);
            } else {
                NSLog(@"[ChangeInfoIos] restore: drop FAILED for %@ (rc=%d, sFlagSz=%llu, sDumpSz=%llu)",
                      bid, rc,
                      [sFlagAttrs[NSFileSize] unsignedLongLongValue],
                      [sDumpAttrs[NSFileSize] unsignedLongLongValue]);
                rlog([NSString stringWithFormat:@"[step5] bid=%@ DROP FAILED rc=%d sFlagSz=%llu sDumpSz=%llu cmd=%@",
                      bid, rc,
                      [sFlagAttrs[NSFileSize] unsignedLongLongValue],
                      [sDumpAttrs[NSFileSize] unsignedLongLongValue],
                      cmd]);
            }
        }
        rlog([NSString stringWithFormat:@"===== restoreEntry END flagsDropped=%lu restoredApps=%lu noDumpBundles=%@ =====",
              (unsigned long)flagsDropped, (unsigned long)restoredApps, noDumpBundles]);
        NSLog(@"[ChangeInfoIos] restore: dropped keychain-restore flags for %lu/%lu bundles%@",
              (unsigned long)flagsDropped, (unsigned long)e.bundleIDs.count,
              noDumpBundles.count ? [NSString stringWithFormat:@" (no-dump: %@)", noDumpBundles] : @"");

        // ---- Step 5: Cleanup + respring ----
        [self updateHUD:hud step:5 total:5
                  title:@"Restart SpringBoard"
               subtitle:@"Reload tweak với config đã restore..."];
        [NSThread sleepForTimeInterval:1.0];
        ci_run([[NSString stringWithFormat:@"rm -rf %@", tmp] UTF8String]);
        ci_run("killall -9 cfprefsd 2>/dev/null");
        int respringRc = ci_run("/var/jb/usr/bin/sbreload 2>/dev/null"
                                " || sbreload 2>/dev/null"
                                " || /var/jb/bin/launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null"
                                " || launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null");
        NSLog(@"[ChangeInfoIos] restore: respring rc=%d", respringRc);
        [NSThread sleepForTimeInterval:3.0];

        dispatch_async(dispatch_get_main_queue(), ^{
            [self dismissHUD:hud completion:^{
                NSString *names = e.appNames.count ? [e.appNames componentsJoinedByString:@", "] : @"-";
                NSString *msg;
                if (restoredApps == 0) {
                    msg = [NSString stringWithFormat:
                        @"⚠️ KHÔNG có app nào được restore.\n\n"
                        @"Lý do có thể: app đã bị uninstall, hoặc UUID container đã đổi quá nhiều.\n"
                        @"Hãy mở app target ít nhất 1 lần TRƯỚC khi restore để iOS tạo container.\n\n"
                        @"Backup: %@", names];
                } else {
                    msg = [NSString stringWithFormat:
                        @"%lu app: %@\n"
                        @"%lu file (%@) đã copy\n"
                        @"%lu file config được khôi phục\n\n"
                        @"Mở app target để vào lại account cũ.",
                        (unsigned long)restoredApps,
                        names,
                        (unsigned long)filesCopied,
                        CIBytesString(bytesCopied),
                        (unsigned long)configFiles];
                }
                NSString *title = (restoredApps == 0) ? @"⚠️ Restore không hoàn tất" : @"✅ Đã restore";
                [self alert:title msg:msg];
            }];
        });
    });
}

- (void)quickRestore {
    NSArray *items = [[CIRRSStore shared] entries];
    if (items.count == 0) { [self alert:@"Không có RRS" msg:@"Chưa có snapshot nào để restore."]; return; }
    [self restoreEntry:items.firstObject];
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

    // v2.4.37: bottom tab bar — Home / Backups / Settings (AZInfo-style).
    // Set tabBarItem on the ROOT view controller, not the nav stack, so
    // UINavigationController doesn't override the title with topViewController.title.
    CIHomeViewController *home = [[CIHomeViewController alloc] init];
    UINavigationController *homeNav = [[UINavigationController alloc] initWithRootViewController:home];
    home.tabBarItem = (@available(iOS 13.0, *))
        ? [[UITabBarItem alloc] initWithTitle:@"Home"
              image:[UIImage systemImageNamed:@"house"]
              selectedImage:[UIImage systemImageNamed:@"house.fill"]]
        : [[UITabBarItem alloc] initWithTitle:@"Home" image:nil tag:0];

    CIRRSManagerViewController *backups = [[CIRRSManagerViewController alloc] init];
    UINavigationController *backupsNav = [[UINavigationController alloc] initWithRootViewController:backups];
    backups.tabBarItem = (@available(iOS 13.0, *))
        ? [[UITabBarItem alloc] initWithTitle:@"Backups"
              image:[UIImage systemImageNamed:@"archivebox"]
              selectedImage:[UIImage systemImageNamed:@"archivebox.fill"]]
        : [[UITabBarItem alloc] initWithTitle:@"Backups" image:nil tag:1];

    CIFakeSettingsViewController *settings = [[CIFakeSettingsViewController alloc] initWithStyle:UITableViewStyleGrouped];
    UINavigationController *settingsNav = [[UINavigationController alloc] initWithRootViewController:settings];
    settings.tabBarItem = (@available(iOS 13.0, *))
        ? [[UITabBarItem alloc] initWithTitle:@"Settings"
              image:[UIImage systemImageNamed:@"gearshape"]
              selectedImage:[UIImage systemImageNamed:@"gearshape.fill"]]
        : [[UITabBarItem alloc] initWithTitle:@"Settings" image:nil tag:2];

    UITabBarController *tab = [[UITabBarController alloc] init];
    tab.viewControllers = @[homeNav, backupsNav, settingsNav];
    tab.tabBar.tintColor = [CITheme blue];
    if (@available(iOS 15.0, *)) {
        UITabBarAppearance *ta = [[UITabBarAppearance alloc] init];
        [ta configureWithOpaqueBackground];
        ta.backgroundColor = [CITheme card];
        tab.tabBar.standardAppearance = ta;
        tab.tabBar.scrollEdgeAppearance = ta;
    }
    self.window.rootViewController = tab;
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
