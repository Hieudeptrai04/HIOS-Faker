#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <spawn.h>
#import <notify.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#import <math.h>

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
    if (!data) return;
    [data writeToFile:CILocalConfigPath() atomically:YES];

    NSString *dir = [kSharedPrefPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL cocoaOK = [data writeToFile:kSharedPrefPath atomically:YES];
    chmod([kSharedPrefPath fileSystemRepresentation], 0644);

    // Fallback: if Cocoa writeToFile: fails (sandbox), shell-copy via posix_spawn
    // which inherits the app's platform entitlements and often bypasses the Cocoa
    // sandbox layer. Root cause of the "Change xong nhưng tweak vẫn thấy config
    // cũ" bug — see BUILD_NOTES §10.
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:kSharedPrefPath];
    unsigned long long sz = 0;
    if (exists) {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:kSharedPrefPath error:nil];
        sz = [attr[NSFileSize] unsignedLongLongValue];
    }
    if (!cocoaOK || !exists || sz < 256) {
        NSString *cmd = [NSString stringWithFormat:
            @"mkdir -p '%@' 2>/tmp/ci_save.err; cp '%@' '%@' 2>>/tmp/ci_save.err && chmod 0644 '%@' 2>>/tmp/ci_save.err",
            dir, CILocalConfigPath(), kSharedPrefPath, kSharedPrefPath];
        int rc = ci_run([cmd UTF8String]);
        NSLog(@"[ChangeInfoIos] shell-mirror rc=%d cocoaOK=%d existed=%d sz=%llu",
              rc, cocoaOK, exists, sz);
    } else {
        NSLog(@"[ChangeInfoIos] Config saved via Cocoa: shared=%@ sz=%llu keys=%lu",
              kSharedPrefPath, sz, (unsigned long)_cfg.count);
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
static NSArray *ci_randomPresets(void) {
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
            @[@"iPhone 7 Plus",    @"iPhone9,2",  @"iPhone9,2",  @"414", @"736", @"3", @"1242", @"2208", @"3"],
            @[@"iPhone 8",          @"iPhone10,1", @"iPhone10,1", @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 8 Plus",    @"iPhone10,2", @"iPhone10,2", @"414", @"736", @"3", @"1242", @"2208", @"3"],
            @[@"iPhone X",          @"iPhone10,3", @"iPhone10,3", @"375", @"812", @"3", @"1125", @"2436", @"3"],
            @[@"iPhone XR",         @"iPhone11,8", @"iPhone11,8", @"414", @"896", @"2", @"828",  @"1792", @"2"],
            @[@"iPhone XS",         @"iPhone11,2", @"iPhone11,2", @"375", @"812", @"3", @"1125", @"2436", @"3"],
            @[@"iPhone XS Max",     @"iPhone11,6", @"iPhone11,6", @"414", @"896", @"3", @"1242", @"2688", @"3"],
            @[@"iPhone SE (2)",     @"iPhone12,8", @"iPhone12,8", @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 11",         @"iPhone12,1", @"iPhone12,1", @"414", @"896", @"2", @"828",  @"1792", @"2"],
            @[@"iPhone 11 Pro",    @"iPhone12,3", @"iPhone12,3", @"375", @"812", @"3", @"1125", @"2436", @"3"],
            @[@"iPhone 11 Pro Max", @"iPhone12,5", @"iPhone12,5", @"414", @"896", @"3", @"1242", @"2688", @"3"],
            @[@"iPhone 12 mini",   @"iPhone13,1", @"iPhone13,1", @"375", @"812", @"3", @"1080", @"2340", @"3"],
            @[@"iPhone 12",         @"iPhone13,2", @"iPhone13,2", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 12 Pro",    @"iPhone13,3", @"iPhone13,3", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 12 Pro Max", @"iPhone13,4", @"iPhone13,4", @"428", @"926", @"3", @"1284", @"2778", @"3"],
            @[@"iPhone 13 mini",   @"iPhone14,4", @"iPhone14,4", @"375", @"812", @"3", @"1080", @"2340", @"3"],
            @[@"iPhone 13",         @"iPhone14,5", @"iPhone14,5", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 13 Pro",    @"iPhone14,2", @"iPhone14,2", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 13 Pro Max", @"iPhone14,3", @"iPhone14,3", @"428", @"926", @"3", @"1284", @"2778", @"3"],
            @[@"iPhone SE (3)",    @"iPhone14,6", @"iPhone14,6", @"375", @"667", @"2", @"750",  @"1334", @"2"],
            @[@"iPhone 14",         @"iPhone14,7", @"iPhone14,7", @"390", @"844", @"3", @"1170", @"2532", @"3"],
            @[@"iPhone 14 Plus",   @"iPhone14,8", @"iPhone14,8", @"428", @"926", @"3", @"1284", @"2778", @"3"],
            @[@"iPhone 14 Pro",    @"iPhone15,2", @"iPhone15,2", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 14 Pro Max", @"iPhone15,3", @"iPhone15,3", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 15",         @"iPhone15,4", @"iPhone15,4", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 15 Plus",    @"iPhone15,5", @"iPhone15,5", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 15 Pro",    @"iPhone16,1", @"iPhone16,1", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 15 Pro Max", @"iPhone16,2", @"iPhone16,2", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 16",         @"iPhone17,3", @"iPhone17,3", @"393", @"852", @"3", @"1179", @"2556", @"3"],
            @[@"iPhone 16 Plus",   @"iPhone17,4", @"iPhone17,4", @"430", @"932", @"3", @"1290", @"2796", @"3"],
            @[@"iPhone 16 Pro",    @"iPhone17,1", @"iPhone17,1", @"402", @"874", @"3", @"1206", @"2622", @"3"],
            @[@"iPhone 16 Pro Max", @"iPhone17,2", @"iPhone17,2", @"440", @"956", @"3", @"1320", @"2868", @"3"],
        ];
    }
    return presets;
}

static NSArray *ci_randomIOSPresets(void) {
    static NSArray *iosList = nil;
    if (!iosList) {
        iosList = @[
            @[@"iOS 15.0",      @"15.0", @"19A346"],
            @[@"iOS 15.1",      @"15.1", @"19B74"],
            @[@"iOS 15.2",      @"15.2", @"19C56"],
            @[@"iOS 15.3",      @"15.3", @"19D50"],
            @[@"iOS 15.4",      @"15.4", @"19E241"],
            @[@"iOS 15.5",      @"15.5", @"19F77"],
            @[@"iOS 15.6",      @"15.6", @"19G71"],
            @[@"iOS 15.7",      @"15.7", @"19H12"],
            @[@"iOS 16.0",      @"16.0", @"20A362"],
            @[@"iOS 16.1",      @"16.1", @"20B82"],
            @[@"iOS 16.2",      @"16.2", @"20C65"],
            @[@"iOS 16.3",      @"16.3", @"20D47"],
            @[@"iOS 16.4",      @"16.4", @"20E247"],
            @[@"iOS 16.5",      @"16.5", @"20F66"],
            @[@"iOS 16.6.1",   @"16.6.1", @"20G81"],
        ];
    }
    return iosList;
}

// Regenerate every rotating identity + geo profile on each Reset.
// Also picks a random model + iOS version so every reset = fresh device.
static NSUInteger ci_randomizeIdentities(void) {
    CIConfigManager *cm = [CIConfigManager shared];

    // === Random model (all fake layers auto-on) ===
    NSArray *presets = ci_randomPresets();
    NSArray *iosList = ci_randomIOSPresets();
    NSArray *preset = presets[arc4random_uniform((uint32_t)presets.count)];
    NSArray *iosPreset = iosList[arc4random_uniform((uint32_t)iosList.count)];

    // Apply model preset
    // deviceModel = full consumer name ("iPhone 15 Pro Max") so UIDevice.model hook
    // returns something meaningful instead of generic "iPhone"
    [cm setObject:preset[0] forKey:@"deviceModel"];
    [cm setObject:preset[0] forKey:@"localizedModel"];
    [cm setObject:@"iPhone" forKey:@"systemName"];
    [cm setObject:preset[1] forKey:@"ProductType"];
    [cm setObject:preset[2] forKey:@"hw_machine"];
    [cm setObject:preset[2] forKey:@"HardwareModel"];  // MGCopyAnswer "HWModelStr" reads this
    [cm setObject:preset[2] forKey:@"uname_machine"];
    [cm setObject:preset[3] forKey:@"screenWidth"];
    [cm setObject:preset[4] forKey:@"screenHeight"];
    [cm setObject:preset[5] forKey:@"screenScale"];
    [cm setObject:preset[6] forKey:@"nativeScreenWidth"];
    [cm setObject:preset[7] forKey:@"nativeScreenHeight"];
    [cm setObject:preset[8] forKey:@"nativeScale"];
    [cm setObject:preset[0] forKey:@"__presetModelName"];
    [cm setObject:@(YES) forKey:@"fake_uiddevice"];
    [cm setObject:@(YES) forKey:@"fake_screen"];

    // Apply iOS preset
    [cm setObject:iosPreset[1] forKey:@"systemVersion"];
    [cm setObject:iosPreset[2] forKey:@"BuildVersion"];
    [cm setObject:iosPreset[0] forKey:@"__presetIOSName"];
    [cm setObject:@(YES) forKey:@"fake_sysosversion"];

    // Additional keys for deep spoofing (AIDA64 reads these)
    [cm setObject:ci_randSerial() forKey:@"IOPlatformSerialNumber"];
    [cm setObject:ci_randHex(40) forKey:@"IOPlatformUUID"];
    [cm setObject:[NSString stringWithFormat:@"iBoot-%d.%d.%d", arc4random_uniform(100)+7000, arc4random_uniform(99)+1, arc4random_uniform(9)+1] forKey:@"FirmwareVersion"];
    [cm setObject:[NSString stringWithFormat:@"%d.%d.%d", arc4random_uniform(9)+1, arc4random_uniform(99)+10, arc4random_uniform(9)] forKey:@"BasebandVersion"];
    [cm setObject:@"16GB" forKey:@"ModelNumber"];
    [cm setObject:@"VN" forKey:@"RegionCode"];
    [cm setObject:@"VN/A" forKey:@"RegionInfo"];
    [cm setObject:preset[1] forKey:@"BoardId"];
    [cm setObject:[NSString stringWithFormat:@"0x81%02X", arc4random_uniform(256)] forKey:@"ChipID"];
    [cm setObject:[NSString stringWithFormat:@"%llu", (unsigned long long)(arc4random_uniform(400)+64) * 1073741824] forKey:@"TotalDiskCapacity"];
    [cm setObject:[NSString stringWithFormat:@"%llu", (unsigned long long)(arc4random_uniform(200)+10) * 1073741824] forKey:@"TotalSystemAvailable"];
    [cm setObject:[NSString stringWithFormat:@"%llu", (unsigned long long)(arc4random_uniform(100)+5) * 1073741824] forKey:@"DiskUsage"];
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", preset[0]] forKey:@"DeviceName"];
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", preset[0]] forKey:@"DeviceNameMG"];
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", preset[0]] forKey:@"UserAssignedDeviceName"];
    [cm setObject:[NSString stringWithFormat:@"iPhone %@", preset[0]] forKey:@"deviceName"];
    [cm setObject:preset[0] forKey:@"MarketingName"];
    [cm setObject:preset[1] forKey:@"DeviceColor"];
    [cm setObject:preset[1] forKey:@"DeviceEnclosureColor"];
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

    // Hardware IDs
    NSDictionary *ids = @{
        @"serialNumber":                          ci_randSerial(),
        @"SerialNumber":                          ci_randSerial(),
        @"advertisingIdentifier":                 ci_randUUID(),
        @"identifierForVendor":                   ci_randUUID(),
        @"UniqueDeviceID":                        ci_randHexLower(40),
        @"UniqueChipID":                          [NSString stringWithFormat:@"%llu",
                                                    ((unsigned long long)arc4random() << 32) | arc4random()],
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
    [ids enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *_) {
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

static int ci_run(const char *cmd) {
    pid_t pid;
    char *envp[] = { NULL };
    const char *argv[] = {"/bin/sh", "-c", cmd, NULL};
    int rc = posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, envp);
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
    NSArray<CIAppInfo *> *_all;
    NSArray<CIAppInfo *> *_view;
    NSMutableSet<NSString *> *_selected;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [CITheme bg];
    self.title = self.mode == CIAppPickerModeReset ? @"Chọn app cần xóa dữ liệu" : @"Chọn app lưu Retention";

    _selected = [NSMutableSet set];
    NSArray *saved = self.mode == CIAppPickerModeReset
        ? [[CIConfigManager shared] targetBundles]
        : [[CIConfigManager shared] rrsBundles];
    [_selected addObjectsFromArray:saved];

    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 54)];
    header.backgroundColor = [CITheme bg];

    UIButton *selAll = [UIButton buttonWithType:UIButtonTypeSystem];
    selAll.frame = CGRectMake(8, 12, 32, 32);
    selAll.layer.borderColor = [CITheme blue].CGColor;
    selAll.layer.borderWidth = 2;
    selAll.layer.cornerRadius = 4;
    [selAll addTarget:self action:@selector(toggleAll) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:selAll];

    _search = [[UISearchBar alloc] initWithFrame:CGRectMake(48, 8, self.view.bounds.size.width-48-80-16, 38)];
    _search.delegate = self;
    _search.placeholder = @"Tìm app...";
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _search.barStyle = UIBarStyleBlack;
    _search.tintColor = [CITheme orange];
    _search.searchTextField.textColor = [CITheme text];
    _search.searchTextField.backgroundColor = [CITheme card];
    [header addSubview:_search];

    UIButton *action = [UIButton buttonWithType:UIButtonTypeSystem];
    action.frame = CGRectMake(self.view.bounds.size.width-80-8, 8, 80, 38);
    action.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [action setTitle:(self.mode == CIAppPickerModeReset ? @"Uninstall" : @"OK") forState:UIControlStateNormal];
    [action setTitleColor:[CITheme orange] forState:UIControlStateNormal];
    action.titleLabel.font = [CITheme h2];
    action.layer.borderColor = [CITheme orange].CGColor;
    action.layer.borderWidth = 1.5;
    action.layer.cornerRadius = 4;
    [action addTarget:self action:@selector(actionTap) forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:action];

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.delegate = self;
    _table.dataSource = self;
    _table.tableHeaderView = header;
    _table.rowHeight = 64;
    _table.separatorColor = [CITheme separator];
    _table.backgroundColor = [CITheme bg];
    [self.view addSubview:_table];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];

    [self loadAppsAsync];
}

- (void)loadAppsAsync {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *a = [CIAppLister allApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_all = a;
            self->_view = a;
            [self->_table reloadData];
        });
    });
}

- (void)toggleAll {
    if (_selected.count == _view.count) [_selected removeAllObjects];
    else { [_selected removeAllObjects]; for (CIAppInfo *a in _view) [_selected addObject:a.bundleID]; }
    [_table reloadData];
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
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _view.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"app";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    CIAppInfo *a = _view[ip.row];
    c.textLabel.text = a.name;
    c.textLabel.textColor = [CITheme text];
    c.textLabel.font = [UIFont systemFontOfSize:16];
    if (a.containerSize > 1) {
        c.detailTextLabel.text = [NSString stringWithFormat:@"%@  •  %@", CIBytesString(a.containerSize), a.bundleID];
    } else {
        c.detailTextLabel.text = a.bundleID;
    }
    c.detailTextLabel.textColor = [CITheme dim];
    c.detailTextLabel.font = [CITheme small];
    c.backgroundColor = [CITheme card];
    c.tintColor = [CITheme orange];
    c.imageView.image = a.icon;
    c.imageView.layer.cornerRadius = 10;
    c.imageView.layer.masksToBounds = YES;
    c.accessoryType = [_selected containsObject:a.bundleID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    CIAppInfo *a = _view[ip.row];
    if ([_selected containsObject:a.bundleID]) [_selected removeObject:a.bundleID];
    else [_selected addObject:a.bundleID];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
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
};

@interface CIRow : NSObject
@property (nonatomic, assign) CIRowKind kind;
@property (nonatomic, copy)   NSString *title;
@property (nonatomic, copy)   NSString *key;        // config key
@property (nonatomic, copy)   NSArray  *options;    // for choose/picker
@property (nonatomic, copy)   NSString *placeholder;
@property (nonatomic, assign) CGFloat  leftPad;     // indentation level (sub-rows)
@end
@implementation CIRow @end

@interface CIFakeSettingsViewController : UITableViewController <UITextFieldDelegate>
@end

@implementation CIFakeSettingsViewController {
    NSMutableArray<CIRow *> *_rows;
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

// Shared preset data (iPhone 5 → 16 Pro Max)
// Columns: name, productType, machine, width, height, scale, nativeW, nativeH, nativeScale
+ (NSArray *)devicePresets {
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
+ (NSArray *)iosPresets {
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

    // Quick picker shortcuts at the top
    [_rows addObject:[C header:@"Chọn nhanh"]];
    [_rows addObject:[C choose:@"📱  Chọn Model iPhone" key:@"__presetModelName" indent:0]];
    [_rows addObject:[C choose:@"🍎  Chọn iOS Version" key:@"__presetIOSName" indent:0]];
    [_rows addObject:[C note:@"Model: iPhone 5 → iPhone 16 Pro Max. iOS: 12 → 18." indent:8]];

    // 1. Fake iOS Version
    [_rows addObject:[C toggle:@"1. Fake iOS Version" key:@"fake_sysosversion" indent:0]];
    [_rows addObject:[C text:@"Version (vd: 17.5.1)" key:@"systemVersion" placeholder:@"17.5.1" indent:24]];
    [_rows addObject:[C text:@"Build version" key:@"BuildVersion" placeholder:@"21F90" indent:24]];

    // 2. Fake Model
    [_rows addObject:[C toggle:@"2. Fake Model" key:@"fake_uiddevice" indent:0]];
    [_rows addObject:[C text:@"deviceModel" key:@"deviceModel" placeholder:@"iPhone" indent:24]];
    [_rows addObject:[C text:@"localizedModel" key:@"localizedModel" placeholder:@"iPhone" indent:24]];
    [_rows addObject:[C text:@"ProductType (vd: iPhone16,2)" key:@"ProductType" placeholder:@"iPhone16,2" indent:24]];
    [_rows addObject:[C text:@"uname_machine" key:@"uname_machine" placeholder:@"iPhone16,2" indent:24]];
    [_rows addObject:[C toggle:@"2.1 Fake Screen Size" key:@"fake_screen" indent:24]];
    [_rows addObject:[C text:@"screenWidth"  key:@"screenWidth"  placeholder:@"430" indent:48]];
    [_rows addObject:[C text:@"screenHeight" key:@"screenHeight" placeholder:@"932" indent:48]];
    [_rows addObject:[C text:@"screenScale"  key:@"screenScale"  placeholder:@"3" indent:48]];
    [_rows addObject:[C toggle:@"2.2 Fake Full Screen (native)" key:@"fake_realscreen" indent:24]];
    [_rows addObject:[C text:@"nativeScreenWidth"  key:@"nativeScreenWidth"  placeholder:@"1290" indent:48]];
    [_rows addObject:[C text:@"nativeScreenHeight" key:@"nativeScreenHeight" placeholder:@"2796" indent:48]];
    [_rows addObject:[C text:@"nativeScale"        key:@"nativeScale"        placeholder:@"3" indent:48]];

    // 3. Fake Name
    [_rows addObject:[C toggle:@"3. Fake Name" key:@"fake_processinfo" indent:0]];
    [_rows addObject:[C text:@"deviceName"     key:@"deviceName"     placeholder:@"iPhone" indent:24]];
    [_rows addObject:[C text:@"processHostName" key:@"processHostName" placeholder:@"iPhone" indent:24]];
    [_rows addObject:[C text:@"kern_hostname"  key:@"kern_hostname"  placeholder:@"iPhone" indent:24]];
    [_rows addObject:[C text:@"uname_nodename" key:@"uname_nodename" placeholder:@"iPhone" indent:24]];

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
    return c;
}

- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    CIRow *r = _rows[ip.row];
    if (r.kind == CIRowHeader) return 44;
    if (r.kind == CIRowNote)   return 44;
    if (r.kind == CIRowToggle) return 50;
    if (r.kind == CIRowChoose) return 62;
    return 70;
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
    [dbg setTitle:@"🔍 Debug Inject Check" forState:UIControlStateNormal];
    [dbg setTitleColor:[CITheme blue] forState:UIControlStateNormal];
    dbg.titleLabel.font = [CITheme h2];
    dbg.backgroundColor = [CITheme card];
    dbg.layer.cornerRadius = 10;
    dbg.layer.borderWidth = 1;
    dbg.layer.borderColor = [CITheme border].CGColor;
    [dbg addTarget:self action:@selector(debugCheckInject) forControlEvents:UIControlEventTouchUpInside];
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

- (UIView *)showHUDWithTitle:(NSString *)title {
    UIView *root = self.view.window ?: self.view;
    UIView *dim = [[UIView alloc] initWithFrame:root.bounds];
    dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.tag = 0xC1DCD;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 220, 120)];
    card.center = CGPointMake(root.bounds.size.width/2, root.bounds.size.height/2);
    card.backgroundColor = [CITheme card];
    card.layer.cornerRadius = 14;
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                          | UIViewAutoresizingFlexibleTopMargin  | UIViewAutoresizingFlexibleBottomMargin;
    [dim addSubview:card];

    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.color = [CITheme orange];
    spin.frame = CGRectMake((220-44)/2, 16, 44, 44);
    [spin startAnimating];
    [card addSubview:spin];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(10, 70, 200, 40)];
    l.text = title; l.textAlignment = NSTextAlignmentCenter;
    l.textColor = [CITheme text]; l.font = [CITheme body];
    l.numberOfLines = 2;
    l.tag = 0xC1DCE;
    [card addSubview:l];

    [root addSubview:dim];
    return dim;
}

- (void)updateHUDTitle:(UIView *)hud title:(NSString *)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *card = hud.subviews.firstObject;
        UILabel *l = [card viewWithTag:0xC1DCE];
        if (l && [l isKindOfClass:[UILabel class]]) {
            l.text = title;
        }
    });
}

- (void)dismissHUD:(UIView *)hud completion:(void(^)(void))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.15 animations:^{ hud.alpha = 0; }
            completion:^(BOOL _) { [hud removeFromSuperview]; if (completion) completion(); }];
    });
}

- (void)debugCheckInject {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableString *out = [NSMutableString string];

    // 1. Shared prefs
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
    NSString *sharedIcon = (sharedExists && sharedSize > 1024) ? @"✅" : @"❌";
    [out appendFormat:@"%@ Shared prefs: %@\n  size=%llu bytes, keys=%lu\n\n",
        sharedIcon, sharedExists ? @"OK" : @"MISSING", sharedSize, (unsigned long)sharedKeys];

    // 2. Dylib
    NSString *dylibPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.dylib";
    BOOL dylibExists = [fm fileExistsAtPath:dylibPath];
    unsigned long long dylibSize = 0;
    if (dylibExists) {
        NSDictionary *attr = [fm attributesOfItemAtPath:dylibPath error:nil];
        dylibSize = [attr[NSFileSize] unsignedLongLongValue];
    }
    NSString *dylibIcon = (dylibExists && dylibSize > 50000) ? @"✅" : @"❌";
    [out appendFormat:@"%@ Dylib: %@\n  size=%llu bytes\n\n",
        dylibIcon, dylibExists ? @"OK" : @"MISSING", dylibSize];

    // 3. Filter plist
    NSString *filterPath = @"/var/jb/Library/MobileSubstrate/DynamicLibraries/ChangeInfoIos.plist";
    BOOL filterExists = [fm fileExistsAtPath:filterPath];
    NSDictionary *filter = [NSDictionary dictionaryWithContentsOfFile:filterPath];
    NSDictionary *filt = filter[@"Filter"];
    NSArray *bundles = [filt[@"Bundles"] isKindOfClass:[NSArray class]] ? filt[@"Bundles"] : @[];
    NSArray *execs = [filt[@"Executables"] isKindOfClass:[NSArray class]] ? filt[@"Executables"] : @[];
    NSString *mode = filt[@"Mode"] ?: @"?";
    BOOL hasAidaBid = [bundles containsObject:@"com.finalwire.aida64"];
    BOOL hasAidaExec = [execs containsObject:@"AIDA64_c3"];
    NSString *filterIcon = (filterExists && hasAidaBid && hasAidaExec) ? @"✅" : @"❌";
    [out appendFormat:@"%@ Filter plist: %@\n  Mode=%@ Bundles=%lu Execs=%lu\n  com.finalwire.aida64: %@\n  AIDA64_c3 exec: %@\n\n",
        filterIcon, filterExists ? @"OK" : @"MISSING", mode,
        (unsigned long)bundles.count, (unsigned long)execs.count,
        hasAidaBid ? @"YES" : @"NO",
        hasAidaExec ? @"YES" : @"NO"];

    // 4. Markers — which apps actually loaded the tweak
    NSString *markerDir = @"/var/mobile/Library/Caches/ChangeInfoIos";
    NSArray *items = [fm contentsOfDirectoryAtPath:markerDir error:nil];
    NSMutableArray *markers = [NSMutableArray array];
    for (NSString *f in items) {
        if ([f hasPrefix:@"injected_"] && [f hasSuffix:@".txt"]) {
            NSString *bid = [[f stringByReplacingOccurrencesOfString:@"injected_" withString:@""]
                             stringByReplacingOccurrencesOfString:@".txt" withString:@""];
            [markers addObject:bid];
        }
    }
    NSString *markerIcon = markers.count > 0 ? @"✅" : @"❌";
    [out appendFormat:@"%@ Injection markers: %lu app(s)\n", markerIcon, (unsigned long)markers.count];
    if (markers.count == 0) {
        [out appendString:@"  (KHÔNG app nào load được tweak)\n"];
    } else {
        for (NSString *bid in markers) [out appendFormat:@"  • %@\n", bid];
    }
    BOOL aidaInjected = [markers containsObject:@"com.finalwire.aida64"];
    BOOL safariInjected = [markers containsObject:@"com.apple.mobilesafari"];
    [out appendFormat:@"\n  AIDA64 inject: %@\n  Safari inject: %@\n",
        aidaInjected ? @"✅ YES" : @"❌ NO",
        safariInjected ? @"✅ YES" : @"❌ NO"];

    // 5. Ellekit / Substrate presence
    NSArray *ekPaths = @[@"/var/jb/usr/lib/libellekit.dylib",
                         @"/var/jb/usr/lib/TweakInject.dylib",
                         @"/var/jb/usr/lib/libsubstrate.dylib",
                         @"/var/jb/Library/LaunchDaemons/com.ellekit.ellekitd.plist"];
    NSMutableArray *ekFound = [NSMutableArray array];
    for (NSString *p in ekPaths) {
        if ([fm fileExistsAtPath:p]) [ekFound addObject:[p lastPathComponent]];
    }
    NSString *ekIcon = ekFound.count > 0 ? @"✅" : @"❌";
    [out appendFormat:@"\n%@ Injection framework: %lu file(s)\n",
        ekIcon, (unsigned long)ekFound.count];
    for (NSString *f in ekFound) [out appendFormat:@"  • %@\n", f];
    if (ekFound.count == 0) [out appendString:@"  (không thấy ellekit/substrate ở /var/jb/usr/lib)\n"];

    // 6. Other tweaks in DynamicLibraries folder (để xem máy có load tweak khác không)
    NSString *dylibDir = @"/var/jb/Library/MobileSubstrate/DynamicLibraries";
    NSArray *dylibItems = [fm contentsOfDirectoryAtPath:dylibDir error:nil];
    NSUInteger dylibCount = 0;
    for (NSString *f in dylibItems) if ([f hasSuffix:@".dylib"]) dylibCount++;
    [out appendFormat:@"\n📦 Tweaks cài đặt: %lu dylib trong %@\n",
        (unsigned long)dylibCount, dylibDir];

    // 7. Read Mach-O header để verify arch (không dlopen vì sẽ crash app —
    // dylib link với substrate's MSHookFunction, undefined khi chưa inject).
    [out appendString:@"\n🔬 Dylib arch:\n"];
    BOOL archOK = NO;
    FILE *fp = fopen([dylibPath fileSystemRepresentation], "rb");
    if (fp) {
        uint32_t magic = 0;
        fread(&magic, 4, 1, fp);
        if (magic == 0xCAFEBABE || magic == 0xBEBAFECA) {
            uint32_t nfatArch_be = 0;
            fread(&nfatArch_be, 4, 1, fp);
            uint32_t n = (nfatArch_be >> 24) | ((nfatArch_be >> 8) & 0xFF00)
                       | ((nfatArch_be << 8) & 0xFF0000) | (nfatArch_be << 24);
            [out appendFormat:@"  FAT binary, %u slice(s)\n", n];
            BOOL arm64 = NO, arm64e = NO;
            for (uint32_t i = 0; i < n && i < 8; i++) {
                uint32_t cputype_be = 0, cpusubtype_be = 0;
                fread(&cputype_be, 4, 1, fp);
                fread(&cpusubtype_be, 4, 1, fp);
                fseek(fp, 12, SEEK_CUR);
                uint32_t ct = (cputype_be >> 24) | ((cputype_be >> 8) & 0xFF00)
                            | ((cputype_be << 8) & 0xFF0000) | (cputype_be << 24);
                uint32_t cs = (cpusubtype_be >> 24) | ((cpusubtype_be >> 8) & 0xFF00)
                            | ((cpusubtype_be << 8) & 0xFF0000) | (cpusubtype_be << 24);
                if (ct == 0x0100000C) {
                    if ((cs & 0xFF) == 2) { arm64e = YES; [out appendString:@"  • arm64e\n"]; }
                    else { arm64 = YES; [out appendString:@"  • arm64\n"]; }
                }
            }
            archOK = arm64 && arm64e;
        } else if (magic == 0xFEEDFACF || magic == 0xCFFAEDFE) {
            [out appendString:@"  Thin binary (single slice)\n"];
            archOK = YES;
        } else {
            [out appendFormat:@"  ❌ Magic lạ: 0x%08X (có thể file hỏng)\n", magic];
        }
        fclose(fp);
    } else {
        [out appendString:@"  ❌ Không mở được dylib để đọc header\n"];
    }

    // 8. Diagnosis
    [out appendString:@"\n=== CHẨN ĐOÁN ===\n"];
    if (!sharedExists || sharedSize < 1024) {
        [out appendString:@"⚠ Shared prefs chưa ghi → bấm Change trước.\n"];
    } else if (!dylibExists) {
        [out appendString:@"⚠ Dylib thiếu → cài lại .deb.\n"];
    } else if (!filterExists || !hasAidaBid || !hasAidaExec) {
        [out appendString:@"⚠ Filter plist sai → cài .deb mới nhất (commit 20dad2d+).\n"];
    } else if (!archOK && dylibSize > 0) {
        [out appendString:@"⚠ Dylib thiếu arch arm64e (hoặc file hỏng).\n"
                          @"  iPhone X cần arm64e — check CI build.\n"];
    } else if (ekFound.count == 0) {
        [out appendString:@"⚠ KHÔNG thấy ellekit/substrate ở /var/jb/usr/lib.\n"
                          @"  → Mở Sileo cài lại ellekit hoặc libsubstrate.\n"];
    } else if (markers.count == 0 && dylibCount > 1) {
        [out appendString:@"⚠ Dylib load được (dlopen OK) + có tweak khác cài,\n"
                          @"  NHƯNG không app nào load tweak mình.\n"
                          @"  → Reboot máy (rejailbreak) để substrate re-scan filter.\n"
                          @"  → Hoặc respring: Sileo → Check updates → Respring.\n"];
    } else if (markers.count == 0) {
        [out appendString:@"⚠ Tweak KHÔNG load vào app nào → ellekit/substrate có vấn đề.\n"
                          @"  → Reboot (rejailbreak) rồi test lại.\n"];
    } else if (safariInjected && !aidaInjected) {
        [out appendString:@"⚠ Safari OK nhưng AIDA64 không → AIDA64 có anti-debug.\n  Thử đổi tên dylib hoặc test với app khác.\n"];
    } else if (aidaInjected) {
        [out appendString:@"✅ AIDA64 đã inject. Nếu vẫn thấy máy gốc → config key chưa đủ / chưa random.\n"];
    } else {
        [out appendString:@"⚠ Mở AIDA64 / Safari trước khi check (app phải chạy lần nữa sau respring).\n"];
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

    // Build full target list: user-selected apps + AIDA64 + Lirum + DeviceDesign
    NSArray *aidaBids = @[
        @"com.finalwire.aida64",
        @"com.finalwire.aida64-ios",
        @"com.blacksmith.lirum",
        @"com.umang.devicedesign",
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

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Step-by-step with visible progress. Each step takes ~1-2s minimum
        // so the user can read what's happening on screen.

        // Step 1: Generate new fake identities and persist to plist
        [self updateHUDTitle:hud title:@"[1/5] Tạo thông tin giả mới..."];
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
            NSString *bidSafe  = [a.bundleID   stringByReplacingOccurrencesOfString:@"'" withString:@""] ?: @"";
            NSString *execSafe = [exec         stringByReplacingOccurrencesOfString:@"'" withString:@""] ?: @"";
            NSString *pathSafe = [a.bundlePath stringByReplacingOccurrencesOfString:@"'" withString:@""] ?: @"";
            NSMutableString *kcmd = [NSMutableString string];
            if (execSafe.length) [kcmd appendFormat:@"killall -9 '%@' 2>/dev/null; ", execSafe];
            if (bidSafe.length)  [kcmd appendFormat:@"pkill -9 -f '%@' 2>/dev/null; ", bidSafe];
            if (pathSafe.length) [kcmd appendFormat:@"pkill -9 -f '%@' 2>/dev/null; ", pathSafe];
            if (kcmd.length) ci_run([kcmd UTF8String]);
        };

        for (CIAppInfo *a in fullTargets) {
            if (!a.containerPath.length) continue;
            NSString *stepTitle = [NSString stringWithFormat:@"[2/5] Kill + xóa %lu/%lu: %@...",
                (unsigned long)wiped + 1, (unsigned long)totalApps, a.name ?: a.bundleID];
            [self updateHUDTitle:hud title:stepTitle];
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
        [self updateHUDTitle:hud title:@"[3/5] Xóa cache phát hiện..."];
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
        for (NSString *bid in allBids) {
            [cm setObject:@(counter) forKey:[@"wipe_counter_" stringByAppendingString:bid]];
        }
        [cm save];
        NSLog(@"[ChangeInfoIos] Step 3 done: counters saved, config reloaded");

        // Step 4: Respring to reload tweak with new fake config.
        // As mobile user we can't killall SpringBoard (root-owned). Try
        // sbreload/launchctl first (rootless-jb friendly), then fall back
        // to killall SpringBoard which only works if elevated.
        [self updateHUDTitle:hud title:@"[4/5] Đang restart SpringBoard..."];
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
        [self updateHUDTitle:hud title:@"[5/5] Dọn lần cuối..."];
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
