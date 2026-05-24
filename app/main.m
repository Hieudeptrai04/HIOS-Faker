// HIOS Faker v3.0.0 — host app
//
// Clean rewrite for v3 architecture: all device-fake happens centrally
// in MobileGestaltHelper via tweak-mg. This app's only job is:
//   1. App picker — let user tick which apps to spoof for
//   2. Device preset library — let user pick what device to claim
//   3. Change Device button — write config + container-reset ticked apps
//   4. RRS Backup / Restore — tar snapshot of app containers (TODO Phase 5)
//   5. Live Verify — show what MGCopyAnswer currently returns
//
// No spoof logic here — config write + shell helpers + UI only.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <notify.h>
#import <Security/Security.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>

extern char **environ;

// Forward @interface declarations — full @implementation lives further
// down. @class alone isn't enough because MainVC calls +[AppPickerVC new].

@interface CIAppInfo : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *containerPath;
@property (nonatomic, copy) NSString *bundlePath;
@end

@interface AppPickerVC : UITableViewController
@end

@interface VerifyVC : UITableViewController
@end

// ============================================================
// Constants
// ============================================================
static NSString *const kAppVersion          = @"3.0.0";
static NSString *const kConfigPath          = @"/var/jb/etc/changeinfoios/config.plist";
static NSString *const kReloadNotification  = @"com.changeinfoios.v3/ReloadConfig";

// ============================================================
// Device preset library
//
// Each preset is a self-consistent set of MG values for a specific
// iPhone model. Hardware capability bools MUST match the model
// (FaceID/TouchID/HomeButton/NFC/OLED) or anti-fraud SDKs flag.
// ============================================================
static NSArray<NSDictionary *> *kDevicePresets(void) {
    static NSArray *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = @[
            @{
                @"MarketingName":      @"iPhone XS Max",
                @"ProductType":        @"iPhone11,6",
                @"HardwareModel":      @"D331pAP",
                @"HWModelStr":         @"D331pAP",
                @"ModelNumber":        @"MT522VN/A",
                @"DeviceClass":        @"iPhone",
                @"DeviceColor":        @"1",
                @"DeviceEnclosureColor": @"1",
                @"HasFaceID":          @YES,
                @"HasTouchID":         @NO,
                @"HasNFC":             @YES,
                @"HasOLEDDisplay":     @YES,
                @"HasHomeButton":      @NO,
                @"HasCellularConnectivity": @YES,
                @"HasBaseband":        @YES,
            },
            @{
                @"MarketingName":      @"iPhone 12 Pro",
                @"ProductType":        @"iPhone13,3",
                @"HardwareModel":      @"D53gAP",
                @"HWModelStr":         @"D53gAP",
                @"ModelNumber":        @"MGLN3VN/A",
                @"DeviceClass":        @"iPhone",
                @"DeviceColor":        @"1",
                @"DeviceEnclosureColor": @"1",
                @"HasFaceID":          @YES,
                @"HasTouchID":         @NO,
                @"HasNFC":             @YES,
                @"HasOLEDDisplay":     @YES,
                @"HasHomeButton":      @NO,
                @"HasCellularConnectivity": @YES,
                @"HasBaseband":        @YES,
            },
            @{
                @"MarketingName":      @"iPhone 13",
                @"ProductType":        @"iPhone14,5",
                @"HardwareModel":      @"D17AP",
                @"HWModelStr":         @"D17AP",
                @"ModelNumber":        @"MLNQ3VN/A",
                @"DeviceClass":        @"iPhone",
                @"DeviceColor":        @"1",
                @"DeviceEnclosureColor": @"1",
                @"HasFaceID":          @YES,
                @"HasTouchID":         @NO,
                @"HasNFC":             @YES,
                @"HasOLEDDisplay":     @YES,
                @"HasHomeButton":      @NO,
                @"HasCellularConnectivity": @YES,
                @"HasBaseband":        @YES,
            },
            @{
                @"MarketingName":      @"iPhone 14",
                @"ProductType":        @"iPhone14,7",
                @"HardwareModel":      @"D27AP",
                @"HWModelStr":         @"D27AP",
                @"ModelNumber":        @"MPVN3VN/A",
                @"DeviceClass":        @"iPhone",
                @"DeviceColor":        @"1",
                @"DeviceEnclosureColor": @"1",
                @"HasFaceID":          @YES,
                @"HasTouchID":         @NO,
                @"HasNFC":             @YES,
                @"HasOLEDDisplay":     @YES,
                @"HasHomeButton":      @NO,
                @"HasCellularConnectivity": @YES,
                @"HasBaseband":        @YES,
            },
            @{
                @"MarketingName":      @"iPhone 15 Pro Max",
                @"ProductType":        @"iPhone16,2",
                @"HardwareModel":      @"D84AP",
                @"HWModelStr":         @"D84AP",
                @"ModelNumber":        @"MU713VN/A",
                @"DeviceClass":        @"iPhone",
                @"DeviceColor":        @"1",
                @"DeviceEnclosureColor": @"1",
                @"HasFaceID":          @YES,
                @"HasTouchID":         @NO,
                @"HasNFC":             @YES,
                @"HasOLEDDisplay":     @YES,
                @"HasHomeButton":      @NO,
                @"HasCellularConnectivity": @YES,
                @"HasBaseband":        @YES,
            },
        ];
    });
    return p;
}

// ============================================================
// Random VN identity generators
// ============================================================
static NSString *ciRandomHex(NSUInteger nBytes) {
    NSMutableData *d = [NSMutableData dataWithLength:nBytes];
    if (SecRandomCopyBytes(kSecRandomDefault, nBytes, d.mutableBytes) != errSecSuccess) {
        arc4random_buf(d.mutableBytes, nBytes);
    }
    NSMutableString *s = [NSMutableString stringWithCapacity:nBytes * 2];
    const uint8_t *b = d.bytes;
    for (NSUInteger i = 0; i < nBytes; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}
static NSString *ciRandomDecimal(NSUInteger nDigits) {
    NSMutableString *s = [NSMutableString stringWithCapacity:nDigits];
    for (NSUInteger i = 0; i < nDigits; i++) [s appendFormat:@"%u", arc4random_uniform(10)];
    return s;
}
static NSString *ciRandomIMEI(void) {
    // Apple TAC prefix range for iPhone
    NSArray *tacs = @[@"35330810", @"35325211", @"35730009", @"35326911"];
    NSString *tac = tacs[arc4random_uniform((uint32_t)tacs.count)];
    NSString *serial = ciRandomDecimal(6);
    NSString *partial = [tac stringByAppendingString:serial];
    // Luhn checksum
    NSInteger sum = 0;
    for (NSInteger i = (NSInteger)partial.length - 1, alt = 1; i >= 0; i--, alt = !alt) {
        NSInteger d = [partial substringWithRange:NSMakeRange(i, 1)].integerValue;
        if (alt) { d *= 2; if (d > 9) d -= 9; }
        sum += d;
    }
    NSInteger check = (10 - sum % 10) % 10;
    return [NSString stringWithFormat:@"%@%ld", partial, (long)check];
}
static NSString *ciRandomMAC(void) {
    NSMutableString *s = [NSMutableString string];
    for (int i = 0; i < 6; i++) {
        if (i) [s appendString:@":"];
        [s appendFormat:@"%02x", arc4random_uniform(256)];
    }
    return s;
}
static NSString *ciRandomUDID40(void) {
    return ciRandomHex(20);   // 20 bytes = 40 hex chars
}
static NSString *ciRandomUUID(void) {
    return [[NSUUID UUID] UUIDString];
}
static NSString *ciRandomViettelPhone(void) {
    NSArray *prefixes = @[@"32", @"33", @"34", @"35", @"36", @"37", @"38", @"39",
                          @"96", @"97", @"98"];
    NSString *p = prefixes[arc4random_uniform((uint32_t)prefixes.count)];
    return [NSString stringWithFormat:@"+849%@%@", p, ciRandomDecimal(7)];
}

// ============================================================
// Config manager
// ============================================================
@interface CIConfig : NSObject
+ (instancetype)shared;
@property (nonatomic, strong) NSMutableDictionary *dict;
- (void)save;
- (void)applyDevicePreset:(NSDictionary *)preset;
- (void)randomizeIdentity;
- (NSArray<NSString *> *)targetBundles;
- (void)setTargetBundles:(NSArray<NSString *> *)b;
@end
@implementation CIConfig
+ (instancetype)shared {
    static CIConfig *s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [CIConfig new]; [s load]; });
    return s;
}
- (void)load {
    _dict = [[NSMutableDictionary dictionaryWithContentsOfFile:kConfigPath] mutableCopy];
    if (!_dict) _dict = [NSMutableDictionary dictionary];
    // Defaults: pick first preset if no MarketingName set
    if (!_dict[@"MarketingName"]) {
        [self applyDevicePreset:kDevicePresets().firstObject];
    }
    if (!_dict[@"RegionCode"])               _dict[@"RegionCode"] = @"VN";
    if (!_dict[@"RegionInfo"])               _dict[@"RegionInfo"] = @"VN/A";
    if (!_dict[@"ProductVersion"])           _dict[@"ProductVersion"] = @"17.1.1";
    if (!_dict[@"BuildVersion"])             _dict[@"BuildVersion"]   = @"21B91";
    if (!_dict[@"MobileSubscriberCountryCode"]) _dict[@"MobileSubscriberCountryCode"] = @"452";
    if (!_dict[@"MobileSubscriberNetworkCode"]) _dict[@"MobileSubscriberNetworkCode"] = @"04";
    if (!_dict[@"SIMTrayStatus"])            _dict[@"SIMTrayStatus"]  = @"kCTSIMSupportSIMStatusReady";
    if (!_dict[@"DeviceNameMG"])             _dict[@"DeviceNameMG"]   = _dict[@"MarketingName"] ?: @"iPhone";
    if (!_dict[@"UserAssignedDeviceName"])   _dict[@"UserAssignedDeviceName"] = _dict[@"DeviceNameMG"];
    if (!_dict[@"UniqueDeviceID"])           [self randomizeIdentity];
}
- (void)save {
    NSString *dir = [kConfigPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:_dict
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0 error:&err];
    if (!data) { NSLog(@"[v3] save serialize fail: %@", err); return; }
    BOOL ok = [data writeToFile:kConfigPath atomically:YES];
    NSLog(@"[v3] save %@ → %d (%lu keys)", kConfigPath, ok, (unsigned long)_dict.count);
    if (ok) chmod([kConfigPath fileSystemRepresentation], 0644);
    notify_post([kReloadNotification UTF8String]);
}
- (void)applyDevicePreset:(NSDictionary *)preset {
    for (NSString *k in preset) _dict[k] = preset[k];
    _dict[@"DeviceNameMG"] = preset[@"MarketingName"] ?: @"iPhone";
    _dict[@"UserAssignedDeviceName"] = _dict[@"DeviceNameMG"];
}
- (void)randomizeIdentity {
    _dict[@"UniqueDeviceID"]                          = ciRandomUDID40();
    _dict[@"SerialNumber"]                            = [ciRandomHex(5) uppercaseString];
    _dict[@"InternationalMobileEquipmentIdentity"]    = ciRandomIMEI();
    _dict[@"InternationalMobileEquipmentIdentity2"]   = ciRandomIMEI();
    _dict[@"MobileEquipmentIdentifier"]               = [ciRandomHex(7) uppercaseString];
    _dict[@"IntegratedCircuitCardIdentity"]           = [@"8984040" stringByAppendingString:ciRandomDecimal(13)];
    _dict[@"IntegratedCircuitCardIdentity2"]          = [@"8984040" stringByAppendingString:ciRandomDecimal(13)];
    _dict[@"UniqueChipID"]                            = @((long long)arc4random() * (long long)arc4random());
    _dict[@"WiFiAddress"]                             = ciRandomMAC();
    _dict[@"BluetoothAddress"]                        = ciRandomMAC();
    _dict[@"EthernetAddress"]                         = ciRandomMAC();
    _dict[@"PhoneNumber"]                             = ciRandomViettelPhone();
    _dict[@"identifierForVendor"]                     = ciRandomUUID();
    _dict[@"advertisingIdentifier"]                   = ciRandomUUID();
}
- (NSArray<NSString *> *)targetBundles {
    id v = _dict[@"targetBundles"];
    return [v isKindOfClass:[NSArray class]] ? v : @[];
}
- (void)setTargetBundles:(NSArray<NSString *> *)b { _dict[@"targetBundles"] = b ?: @[]; }
@end

// ============================================================
// App lister
// ============================================================
@implementation CIAppInfo
@end

@interface CIAppLister : NSObject
+ (NSArray<CIAppInfo *> *)allApps;
@end
@implementation CIAppLister
+ (NSArray<CIAppInfo *> *)allApps {
    static NSArray *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *result = [NSMutableArray array];
        @try {
            Class LSAW = NSClassFromString(@"LSApplicationWorkspace");
            id ws = [LSAW performSelector:@selector(defaultWorkspace)];
            NSArray *apps = [ws performSelector:@selector(allInstalledApplications)];
            for (id proxy in apps) {
                @autoreleasepool {
                    @try {
                        NSString *bid = [proxy performSelector:@selector(bundleIdentifier)];
                        if (!bid) continue;
                        NSString *type = @"";
                        if ([proxy respondsToSelector:@selector(applicationType)])
                            type = [proxy performSelector:@selector(applicationType)];
                        if (![type isEqualToString:@"User"]) continue;
                        if ([bid hasPrefix:@"com.apple."]) continue;
                        if ([bid isEqualToString:@"com.changeinfoios.v3.app"]) continue;
                        CIAppInfo *info = [CIAppInfo new];
                        info.bundleID = bid;
                        NSString *nm = [proxy performSelector:@selector(localizedName)];
                        info.name = nm.length ? nm : bid;
                        if ([proxy respondsToSelector:@selector(bundleURL)]) {
                            id u = [proxy performSelector:@selector(bundleURL)];
                            info.bundlePath = [u performSelector:@selector(path)];
                        }
                        if ([proxy respondsToSelector:@selector(dataContainerURL)]) {
                            id u = [proxy performSelector:@selector(dataContainerURL)];
                            info.containerPath = [u performSelector:@selector(path)];
                        }
                        [result addObject:info];
                    } @catch (__unused id e) {}
                }
            }
        } @catch (__unused id e) {}
        [result sortUsingComparator:^NSComparisonResult(CIAppInfo *a, CIAppInfo *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
        cache = [result copy];
    });
    return cache;
}
@end

// ============================================================
// Container reset — shell helpers
// ============================================================
static int ciRunShell(NSString *cmd) {
    if (!cmd.length) return -1;
    // Spawn /bin/sh -c "<cmd>" — pass cmd as a SINGLE arg so shell-level
    // quoting + spaces survive intact. Pre-fix used componentsSeparatedByString
    // which split on every space and mangled commands like `rm -rf "a b"`.
    const char *argv[] = {
        "/bin/sh",
        "-c",
        [cmd UTF8String],
        NULL,
    };
    pid_t pid;
    if (posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, environ) != 0) return -1;
    int status = 0;
    waitpid(pid, &status, 0);
    return WEXITSTATUS(status);
}

static void ciResetContainer(CIAppInfo *app) {
    if (!app.containerPath.length) return;
    NSArray<NSString *> *subdirs = @[
        @"Documents", @"Library/Caches", @"Library/Preferences",
        @"Library/Cookies", @"Library/WebKit", @"Library/Application Support",
        @"Library/SystemData", @"tmp",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *sub in subdirs) {
        NSString *path = [app.containerPath stringByAppendingPathComponent:sub];
        NSArray *items = [fm contentsOfDirectoryAtPath:path error:nil];
        for (NSString *item in items) {
            [fm removeItemAtPath:[path stringByAppendingPathComponent:item] error:nil];
        }
    }
    NSLog(@"[v3] wiped container for %@", app.bundleID);

    // Keychain wipe — generic + internet + cert + key + identity classes
    NSArray *secClasses = @[
        (__bridge NSString *)kSecClassGenericPassword,
        (__bridge NSString *)kSecClassInternetPassword,
        (__bridge NSString *)kSecClassCertificate,
        (__bridge NSString *)kSecClassKey,
        (__bridge NSString *)kSecClassIdentity,
    ];
    for (NSString *cls in secClasses) {
        NSDictionary *q = @{ (__bridge NSString *)kSecClass: cls };
        SecItemDelete((__bridge CFDictionaryRef)q);
    }
}

// ============================================================
// Main controller — single-screen UI
// ============================================================
@interface MainVC : UIViewController
@property (nonatomic, strong) UILabel *currentDeviceLbl;
@property (nonatomic, strong) UIButton *presetBtn;
@property (nonatomic, strong) UIButton *changeBtn;
@property (nonatomic, strong) UIButton *pickerBtn;
@property (nonatomic, strong) UIButton *verifyBtn;
@end
@implementation MainVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = [NSString stringWithFormat:@"HIOS Faker v%@", kAppVersion];

    // Current device label (card)
    UIView *card = [UIView new];
    card.backgroundColor = [UIColor secondarySystemBackgroundColor];
    card.layer.cornerRadius = 14;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:card];

    _currentDeviceLbl = [UILabel new];
    _currentDeviceLbl.numberOfLines = 0;
    _currentDeviceLbl.translatesAutoresizingMaskIntoConstraints = NO;
    _currentDeviceLbl.font = [UIFont systemFontOfSize:15];
    [card addSubview:_currentDeviceLbl];

    // Buttons
    _presetBtn = [self _orangeButton:@"📱  Đổi preset thiết bị" action:@selector(onPickPreset)];
    _changeBtn = [self _orangeButton:@"🔄  CHANGE DEVICE NGAY" action:@selector(onChange)];
    _pickerBtn = [self _blueButton:@"☑️  Chọn app fake" action:@selector(onPickApps)];
    _verifyBtn = [self _blueButton:@"🔍  Verify spoof" action:@selector(onVerify)];
    _changeBtn.backgroundColor = [UIColor systemOrangeColor];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _presetBtn, _pickerBtn, _changeBtn, _verifyBtn
    ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor          constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [card.leadingAnchor      constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [card.trailingAnchor     constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_currentDeviceLbl.topAnchor      constraintEqualToAnchor:card.topAnchor constant:14],
        [_currentDeviceLbl.leadingAnchor  constraintEqualToAnchor:card.leadingAnchor constant:14],
        [_currentDeviceLbl.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [_currentDeviceLbl.bottomAnchor   constraintEqualToAnchor:card.bottomAnchor constant:-14],

        [stack.topAnchor      constraintEqualToAnchor:card.bottomAnchor constant:16],
        [stack.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];

    [self refresh];
}

- (UIButton *)_orangeButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor systemIndigoColor];
    b.layer.cornerRadius = 14;
    b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [[b.heightAnchor constraintEqualToConstant:54] setActive:YES];
    return b;
}
- (UIButton *)_blueButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [self _orangeButton:title action:sel];
    b.backgroundColor = [UIColor systemBlueColor];
    return b;
}

- (void)refresh {
    NSDictionary *d = [CIConfig shared].dict;
    NSArray *targets = [[CIConfig shared] targetBundles];
    NSString *udid = d[@"UniqueDeviceID"] ?: @"";
    NSString *udidShort = (udid.length >= 16) ? [udid substringToIndex:16] : udid;
    _currentDeviceLbl.text = [NSString stringWithFormat:
        @"📱  %@ (%@)\n🔢  UDID: %@\n📞  IMEI: %@\n🌐  Carrier: VN/Viettel  iOS %@\n☑️  Apps đã tích: %lu",
        d[@"MarketingName"] ?: @"?",
        d[@"ProductType"]   ?: @"?",
        udidShort,
        d[@"InternationalMobileEquipmentIdentity"] ?: @"?",
        d[@"ProductVersion"] ?: @"?",
        (unsigned long)targets.count];
}

// ----- Actions -----

- (void)onPickPreset {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Chọn preset thiết bị"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *preset in kDevicePresets()) {
        NSString *t = [NSString stringWithFormat:@"%@ (%@)", preset[@"MarketingName"], preset[@"ProductType"]];
        [ac addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [[CIConfig shared] applyDevicePreset:preset];
            [[CIConfig shared] save];
            [self refresh];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)onPickApps {
    AppPickerVC *vc = [AppPickerVC new];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)onChange {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Change Device"
                                                                message:@"Sẽ wipe data của các app đã tích + randomize identity + push fake config tới MG tweak. Tiếp tục?"
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK CHANGE" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
        [self _performChange];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Huỷ" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)_performChange {
    UIAlertController *hud = [UIAlertController alertControllerWithTitle:@"Đang Change Device..."
                                                                 message:@"Bước 1/4: randomize identity"
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:hud animated:YES completion:^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            // 1. Randomize identity
            [[CIConfig shared] randomizeIdentity];

            dispatch_async(dispatch_get_main_queue(), ^{ hud.message = @"Bước 2/4: lưu config + thông báo MG tweak"; });
            [[CIConfig shared] save];

            dispatch_async(dispatch_get_main_queue(), ^{ hud.message = @"Bước 3/4: wipe container các app đã tích"; });
            NSArray *tBids = [[CIConfig shared] targetBundles];
            NSArray<CIAppInfo *> *all = [CIAppLister allApps];
            for (CIAppInfo *a in all) {
                if ([tBids containsObject:a.bundleID]) ciResetContainer(a);
            }

            dispatch_async(dispatch_get_main_queue(), ^{ hud.message = @"Bước 4/4: kill app + respring"; });
            for (CIAppInfo *a in all) {
                if ([tBids containsObject:a.bundleID]) {
                    NSString *exec = [a.bundlePath.lastPathComponent stringByDeletingPathExtension];
                    if (exec.length) {
                        NSString *killCmd = [NSString stringWithFormat:@"killall -9 '%@' 2>/dev/null", exec];
                        ciRunShell(killCmd);
                    }
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                [hud dismissViewControllerAnimated:YES completion:^{
                    UIAlertController *done = [UIAlertController alertControllerWithTitle:@"✅ Xong"
                                                                                  message:@"Change Device hoàn tất. Mở app đã tích để check fake values."
                                                                           preferredStyle:UIAlertControllerStyleAlert];
                    [done addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                    [self presentViewController:done animated:YES completion:nil];
                    [self refresh];
                }];
            });
        });
    }];
}

- (void)onVerify {
    VerifyVC *vc = [VerifyVC new];
    [self.navigationController pushViewController:vc animated:YES];
}
@end

// ============================================================
// App picker
// ============================================================
@interface AppPickerVC ()
@property (nonatomic, strong) NSArray<CIAppInfo *> *apps;
@property (nonatomic, strong) NSMutableSet<NSString *> *picked;
@end
@implementation AppPickerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Chọn app fake";
    _apps = [CIAppLister allApps];
    _picked = [NSMutableSet setWithArray:[[CIConfig shared] targetBundles]];
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    [self.tableView reloadData];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone
        target:self action:@selector(onSave)];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _apps.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"c"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    CIAppInfo *a = _apps[ip.row];
    cell.textLabel.text = a.name;
    cell.detailTextLabel.text = a.bundleID;
    cell.accessoryType = [_picked containsObject:a.bundleID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    CIAppInfo *a = _apps[ip.row];
    if ([_picked containsObject:a.bundleID]) [_picked removeObject:a.bundleID];
    else                                       [_picked addObject:a.bundleID];
    [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
    [tv deselectRowAtIndexPath:ip animated:YES];
}
- (void)onSave {
    [[CIConfig shared] setTargetBundles:_picked.allObjects];
    [[CIConfig shared] save];
    [self.navigationController popViewControllerAnimated:YES];
}
@end

// ============================================================
// Verify viewer — calls MGCopyAnswer to show what tweak returns
// ============================================================
@interface VerifyVC ()
@property (nonatomic, strong) NSArray<NSArray *> *rows;  // [[label, key], ...]
@property (nonatomic, strong) NSMutableDictionary *vals;
@end
@implementation VerifyVC

typedef CFTypeRef (*MGCopyAnswer_t)(CFStringRef);

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Verify spoof";
    _rows = @[
        @[@"Marketing Name",  @"MarketingName"],
        @[@"Product Type",    @"ProductType"],
        @[@"Hardware Model",  @"HardwareModel"],
        @[@"Model Number",    @"ModelNumber"],
        @[@"Serial Number",   @"SerialNumber"],
        @[@"UDID",            @"UniqueDeviceID"],
        @[@"IMEI",            @"InternationalMobileEquipmentIdentity"],
        @[@"WiFi MAC",        @"WiFiAddress"],
        @[@"Bluetooth MAC",   @"BluetoothAddress"],
        @[@"Region",          @"RegionCode"],
        @[@"iOS Version",     @"ProductVersion"],
        @[@"Build",           @"BuildVersion"],
    ];
    _vals = [NSMutableDictionary dictionary];
    [self _query];
}
- (void)_query {
    void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    if (!h) return;
    MGCopyAnswer_t fn = (MGCopyAnswer_t)dlsym(h, "MGCopyAnswer");
    if (!fn) return;
    for (NSArray *row in _rows) {
        CFTypeRef r = fn((__bridge CFStringRef)row[1]);
        if (r) {
            _vals[row[1]] = [NSString stringWithFormat:@"%@", (__bridge id)r];
            CFRelease(r);
        }
    }
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return _rows.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"v"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"v"];
    NSArray *row = _rows[ip.row];
    cell.textLabel.text = row[0];
    cell.detailTextLabel.text = _vals[row[1]] ?: @"(real / not in cache)";
    cell.detailTextLabel.textColor = _vals[row[1]] ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    return cell;
}
@end

// ============================================================
// App delegate
// ============================================================
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    MainVC *vc = [MainVC new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
