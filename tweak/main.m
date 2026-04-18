#import <UIKit/UIKit.h>
#import <objc/runtime.h>

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
- (id)bundleURL;
@end

// ============================================================
// CONSTANTS
// ============================================================
static NSString *const kPrefPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
static NSString *const kNotifyName = @"com.changeinfoios/ReloadPrefs";

// ============================================================
// CONFIG MANAGER
// ============================================================
@interface CIConfigManager : NSObject
+ (instancetype)shared;
- (NSMutableDictionary *)config;
- (void)load;
- (void)save;
- (void)setValue:(id)value forKey:(NSString *)key;
- (void)setBool:(BOOL)val forKey:(NSString *)key;
- (id)valueForKey:(NSString *)key;
- (BOOL)boolForKey:(NSString *)key;
- (void)postReload;
@end

@implementation CIConfigManager
static CIConfigManager *_shared;
static NSMutableDictionary *_config;

+ (instancetype)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ _shared = [[CIConfigManager alloc] init]; });
    return _shared;
}

- (void)load {
    @autoreleasepool {
        _config = [[NSMutableDictionary dictionaryWithContentsOfFile:kPrefPath] mutableCopy];
        if (!_config) _config = [NSMutableDictionary dictionary];
    }
}

- (void)save {
    @autoreleasepool {
        NSData *data = [NSPropertyListSerialization dataWithPropertyList:_config
                                                               format:NSPropertyListXMLFormat_v1_0
                                                              options:0 error:nil];
        if (data) {
            [data writeToFile:kPrefPath atomically:YES];
            chmod([kPrefPath fileSystemRepresentation], 0644);
            [[NSFileManager defaultManager] setAttributes:@{NSOwnerAccountName: @"mobile"}
                                            ofItemAtPath:kPrefPath error:nil];
        }
    }
}

- (void)postReload {
    system("notify_post com.changeinfoios/ReloadPrefs");
}

- (NSMutableDictionary *)config {
    if (!_config) [self load];
    return _config;
}

- (void)setValue:(id)value forKey:(NSString *)key {
    [[self config] setValue:value forKey:key];
}

- (void)setBool:(BOOL)val forKey:(NSString *)key {
    [[self config] setValue:@(val) forKey:key];
}

- (id)valueForKey:(NSString *)key {
    return [[self config] valueForKey:key];
}

- (BOOL)boolForKey:(NSString *)key {
    id v = [[self config] valueForKey:key];
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
}
@end

// ============================================================
// APP SCANNER
// ============================================================
@interface CIAppInfo : NSObject
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *iconBase64;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, assign) NSUInteger appSize;
@end

@implementation CIAppInfo
- (NSString *)description { return [NSString stringWithFormat:@"<CIAppInfo %@: %@>", self.bundleId, self.name]; }
@end

@interface CIAppScanner : NSObject
+ (NSArray<CIAppInfo *> *)scanInstalledApps;
@end

@implementation CIAppScanner

+ (unsigned long long)sizeOfDirectoryAtPath:(NSString *)path {
    unsigned long long totalSize = 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:path];
    NSString *file;
    while ((file = [en nextObject])) {
        NSString *fullPath = [path stringByAppendingPathComponent:file];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        if ([attrs[NSFileType] isEqualToString:NSFileTypeRegularFile]) {
            totalSize += [attrs[NSFileSize] unsignedLongLongValue];
        }
    }
    return totalSize;
}

+ (NSString *)formatSize:(unsigned long long)bytes {
    if (bytes >= 1073741824ULL) return [NSString stringWithFormat:@"%.1fGB", bytes / 1073741824.0];
    if (bytes >= 1048576ULL) return [NSString stringWithFormat:@"%.0fMB", bytes / 1048576.0];
    if (bytes >= 1024ULL) return [NSString stringWithFormat:@"%.0fKB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%lluB", bytes];
}

+ (NSArray<CIAppInfo *> *)scanInstalledApps {
    NSMutableArray<CIAppInfo *> *result = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    // Try LastLaunchServicesMap first
    NSArray *mapPaths = @[
        @"/var/installd/Library/MobileInstallation/LastLaunchServicesMap.plist",
        @"/private/var/installd/Library/MobileInstallation/LastLaunchServicesMap.plist"
    ];

    NSDictionary *map = nil;
    for (NSString *p in mapPaths) {
        map = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([map isKindOfClass:[NSDictionary class]] && map.count > 0) break;
        map = nil;
    }

    if (map) {
        for (NSString *cat in map) {
            NSDictionary *appsDict = map[cat];
            if (![appsDict isKindOfClass:[NSDictionary class]]) continue;
            for (NSString *bid in appsDict) {
                if (bid.length < 4) continue;
                if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.mobilesafari"]) continue;

                CIAppInfo *info = [[CIAppInfo alloc] init];
                info.bundleId = bid;

                id entry = appsDict[bid];
                NSString *bundlePath = nil;
                if ([entry isKindOfClass:[NSDictionary class]]) {
                    bundlePath = entry[@"Path"];
                } else if ([entry isKindOfClass:[NSString class]]) {
                    bundlePath = entry;
                }

                if (bundlePath) {
                    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                    if ([infoPlist isKindOfClass:[NSDictionary class]]) {
                        NSString *dn = infoPlist[@"CFBundleDisplayName"];
                        if (![dn isKindOfClass:[NSString class]] || dn.length == 0)
                            dn = infoPlist[@"CFBundleName"];
                        if ([dn isKindOfClass:[NSString class]] && dn.length > 0)
                            info.name = dn;
                        else
                            info.name = bid;
                    } else {
                        info.name = bid;
                    }
                    if ([fm fileExistsAtPath:bundlePath isDirectory:nil]) {
                        info.appSize = [self sizeOfDirectoryAtPath:bundlePath];
                    }
                } else {
                    info.name = bid;
                }

                [result addObject:info];
            }
        }
    }

    // Fallback: filesystem scan
    if (result.count == 0) {
        NSArray *roots = @[
            @"/var/containers/Bundle/Application",
            @"/Applications",
            @"/var/jb/Applications"
        ];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSString *root in roots) {
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;
            NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
            NSString *rel = nil;
            while ((rel = [en nextObject])) {
                if (![rel.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
                [en skipDescendants];
                NSString *appPath = [root stringByAppendingPathComponent:rel];
                NSString *plistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                if (![infoPlist isKindOfClass:[NSDictionary class]]) continue;

                NSString *bid = infoPlist[@"CFBundleIdentifier"];
                if (![bid isKindOfClass:[NSString class]] || bid.length < 4) continue;
                if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.mobilesafari"]) continue;
                if ([seen containsObject:bid]) continue;
                [seen addObject:bid];

                CIAppInfo *info = [[CIAppInfo alloc] init];
                info.bundleId = bid;

                NSString *dn = infoPlist[@"CFBundleDisplayName"];
                if (![dn isKindOfClass:[NSString class]] || dn.length == 0)
                    dn = infoPlist[@"CFBundleName"];
                info.name = ([dn isKindOfClass:[NSString class]] && dn.length > 0) ? dn : bid;

                info.appSize = [self sizeOfDirectoryAtPath:appPath];

                [result addObject:info];
            }
        }
    }

    return [result sortedArrayUsingComparator:^NSComparisonResult(CIAppInfo *a, CIAppInfo *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];
}
@end

// ============================================================
// COMMAND RUNNER
// ============================================================
static void ci_run_cmd(const char *cmd) {
    pid_t pid;
    char *envp[] = { NULL };
    const char *argv[] = {"/bin/sh", "-c", cmd, NULL};
    posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, envp);
    waitpid(pid, NULL, 0);
}

// ============================================================
// THEME COLORS
// ============================================================
@interface CITheme : NSObject
+ (UIColor *)backgroundColor;
+ (UIColor *)cardBackground;
+ (UIColor *)textColor;
+ (UIColor *)textSecondary;
+ (UIColor *)accentColor;
+ (UIColor *)destructiveColor;
+ (UIColor *)separatorColor;
@end

@implementation CITheme
+ (UIColor *)colorWithRGB:(NSUInteger)hex alpha:(CGFloat)a {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0
                           green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0
                           alpha:a];
}
+ (UIColor *)backgroundColor { return [self colorWithRGB:0x060B16 alpha:1]; }
+ (UIColor *)cardBackground  { return [self colorWithRGB:0x0D1520 alpha:1]; }
+ (UIColor *)textColor       { return [self colorWithRGB:0xD7E6D8 alpha:1]; }
+ (UIColor *)textSecondary   { return [self colorWithRGB:0x8A9A8B alpha:1]; }
+ (UIColor *)accentColor      { return [self colorWithRGB:0x4A9EFF alpha:1]; }
+ (UIColor *)destructiveColor { return [self colorWithRGB:0xFF4D4D alpha:1]; }
+ (UIColor *)separatorColor  { return [self colorWithRGB:0x1A2530 alpha:1]; }
@end

// ============================================================
// TAB BAR CONTROLLER
// ============================================================
@interface CITabBarController : UITabBarController
@end

@implementation CITabBarController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.tabBar.barTintColor = [CITheme backgroundColor];
    self.tabBar.backgroundColor = [CITheme backgroundColor];
    self.tabBar.tintColor = [CITheme accentColor];
    self.tabBar.unselectedItemTintColor = [CITheme textSecondary];

    if (@available(iOS 15.0, *)) {
        UITabBarAppearance *app = [[UITabBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [CITheme backgroundColor];
        self.tabBar.standardAppearance = app;
        self.tabBar.scrollEdgeAppearance = app;
    }

    [self setViewControllers:@[
        [[CIMainViewController alloc] init],
        [[CIRRSViewController alloc] init],
        [[CIAppsViewController alloc] init],
        [[CISetupViewController alloc] init],
        [[CISettingsViewController alloc] init],
    ] animated:NO];
}
@end

// ============================================================
// BASE CELL
// ============================================================
@interface CISwitchCell : UITableViewCell
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, copy) NSString *configKey;
@property (nonatomic, copy) void (^onToggle)(BOOL on);
@end

@implementation CISwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [CITheme cardBackground];
        self.textLabel.textColor = [CITheme textColor];
        self.textLabel.font = [UIFont systemFontOfSize:16];

        self.toggle = [[UISwitch alloc] init];
        self.toggle.onTintColor = [CITheme accentColor];
        [self.toggle addTarget:self action:@selector(toggled:) forControlEvents:UIControlEventValueChanged];
        self.accessoryView = self.toggle;

        self.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return self;
}

- (void)setConfigKey:(NSString *)configKey {
    _configKey = configKey;
    self.toggle.on = [[CIConfigManager shared] boolForKey:configKey];
}

- (void)toggled:(UISwitch *)sw {
    [[CIConfigManager shared] setBool:sw.on forKey:self.configKey];
    if (self.onToggle) self.onToggle(sw.on);
}

@end

@interface CITextFieldCell : UITableViewCell <UITextFieldDelegate>
@property (nonatomic, strong) UITextField *textField;
@property (nonatomic, copy) NSString *configKey;
@property (nonatomic, copy) void (^onEndEditing)(NSString *val);
@end

@implementation CITextFieldCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [CITheme cardBackground];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        self.textField = [[UITextField alloc] init];
        self.textField.textColor = [CITheme textColor];
        self.textField.font = [UIFont systemFontOfSize:15];
        self.textField.textAlignment = NSTextAlignmentRight;
        self.textField.returnKeyType = UIReturnKeyDone;
        self.textField.delegate = self;
        self.textField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        [self.textField addTarget:self action:@selector(textChanged:) forControlEvents:UIControlEventEditingChanged];
        self.textField.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:self.textField];

        [NSLayoutConstraint activateConstraints:@[
            [self.textField.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [self.textField.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [self.textField.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.textLabel.trailingAnchor constant:12],
            [self.textField.widthAnchor constraintGreaterThanOrEqualToConstant:160],
        ]];
    }
    return self;
}

- (void)setConfigKey:(NSString *)configKey {
    _configKey = configKey;
    self.textField.text = [[CIConfigManager shared] valueForKey:configKey];
}

- (void)textChanged:(UITextField *)tf {
    [[CIConfigManager shared] setValue:tf.text forKey:self.configKey];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    if (self.onEndEditing) self.onEndEditing(tf.text);
    return YES;
}

@end

// ============================================================
// SECTION HEADER
// ============================================================
@interface CISectionHeader : UIView
@property (nonatomic, strong) UILabel *label;
@end

@implementation CISectionHeader

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width, 44)];
    if (self) {
        self.backgroundColor = [CITheme backgroundColor];

        self.label = [[UILabel alloc] init];
        self.label.text = [title uppercaseString];
        self.label.textColor = [CITheme textSecondary];
        self.label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        self.label.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.label];

        [NSLayoutConstraint activateConstraints:@[
            [self.label.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:20],
            [self.label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        ]];
    }
    return self;
}

@end

// ============================================================
// PAGE 0: MAIN
// ============================================================
@interface CIMainViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *sections;
@end

@implementation CIMainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"HIOS Faker";
    self.view.backgroundColor = [CITheme backgroundColor];

    self.navigationController.navigationBar.barTintColor = [CITheme backgroundColor];
    self.navigationController.navigationBar.backgroundColor = [CITheme backgroundColor];
    self.navigationController.navigationBar.titleTextAttributes = @{NSForegroundColorAttributeName: [CITheme textColor]};
    self.navigationController.navigationBar.tintColor = [CITheme accentColor];

    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [CITheme backgroundColor];
        app.titleTextAttributes = @{NSForegroundColorAttributeName: [CITheme textColor]};
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [CITheme backgroundColor];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.separatorColor = [CITheme separatorColor];
    [self.view addSubview:self.table];

    [self buildSections];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[CIConfigManager shared] load];
    [self.table reloadData];
}

- (void)buildSections {
    self.sections = @[
        // Section 0: Device Info
        @{@"header": @"Device Info", @"rows": @[
            @{@"title": @"Device Model", @"key": @"deviceModel", @"placeholder": @"iPhone 15 Pro"},
            @{@"title": @"iOS Version", @"key": @"systemVersion", @"placeholder": @"17.0"},
            @{@"title": @"Device Name", @"key": @"deviceName", @"placeholder": @"Hieu's iPhone"},
        ]},
        // Section 1: Hardware Spoof
        @{@"header": @"Hardware", @"rows": @[
            @{@"title": @"Enable Hardware Spoof", @"key": @"fake_hardware", @"type": @"switch"},
            @{@"title": @"Serial Number", @"key": @"SerialNumber", @"placeholder": @"Serial"},
            @{@"title": @"UniqueDeviceID (UDID)", @"key": @"UniqueDeviceID", @"placeholder": @"00000000-0000000000"},
            @{@"title": @"IMEI", @"key": @"InternationalMobileEquipmentIdentity", @"placeholder": @"35xxxxxxxxxxxxx"},
            @{@"title": @"WiFi MAC", @"key": @"WiFiAddress", @"placeholder": @"AA:BB:CC:DD:EE:FF"},
            @{@"title": @"Bluetooth MAC", @"key": @"BluetoothAddress", @"placeholder": @"AA:BB:CC:DD:EE:FF"},
        ]},
        // Section 2: Network
        @{@"header": @"Network", @"rows": @[
            @{@"title": @"Enable Network Spoof", @"key": @"fake_network", @"type": @"switch"},
            @{@"title": @"Carrier Name", @"key": @"carrierName", @"placeholder": @"Viettel"},
            @{@"title": @"Carrier MCC", @"key": @"carrierMCC", @"placeholder": @"452"},
            @{@"title": @"Carrier MNC", @"key": @"carrierMNC", @"placeholder": @"04"},
            @{@"title": @"WiFi SSID", @"key": @"wifiSSID", @"placeholder": @"MyWiFi"},
            @{@"title": @"WiFi BSSID", @"key": @"wifiBSSID", @"placeholder": @"AA:BB:CC:DD:EE:FF"},
        ]},
        // Section 3: Location
        @{@"header": @"Location", @"rows": @[
            @{@"title": @"Enable Location Spoof", @"key": @"fake_location", @"type": @"switch"},
            @{@"title": @"Enable Location", @"key": @"locationEnabled", @"type": @"switch"},
            @{@"title": @"Latitude", @"key": @"latitude", @"placeholder": @"21.0285"},
            @{@"title": @"Longitude", @"key": @"longitude", @"placeholder": @"105.8542"},
        ]},
        // Section 4: UIDevice
        @{@"header": @"UIDevice", @"rows": @[
            @{@"title": @"Enable UIDevice Spoof", @"key": @"fake_uiddevice", @"type": @"switch"},
            @{@"title": @"IDFA", @"key": @"advertisingIdentifier", @"placeholder": @"UUID"},
            @{@"title": @"Battery Level", @"key": @"batteryLevel", @"placeholder": @"0.8"},
        ]},
        // Section 5: Actions
        @{@"header": @"Actions", @"rows": @[
            @{@"title": @"Save & Respring", @"action": @"save", @"style": @"accent"},
            @{@"title": @"Reset All Settings", @"action": @"reset", @"style": @"destructive"},
        ]},
    ];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [self.sections[section][@"header"] uppercaseString];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hv = (UITableViewHeaderFooterView *)view;
        hv.textLabel.textColor = [CITheme textSecondary];
        hv.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"rows"] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    NSString *type = row[@"type"];
    NSString *action = row[@"action"];

    if ([action isEqualToString:@"save"]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.backgroundColor = [CITheme cardBackground];
        cell.textLabel.text = row[@"title"];
        cell.textLabel.textColor = [CITheme accentColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    if ([action isEqualToString:@"reset"]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.backgroundColor = [CITheme cardBackground];
        cell.textLabel.text = row[@"title"];
        cell.textLabel.textColor = [CITheme destructiveColor];
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    if ([type isEqualToString:@"switch"]) {
        static NSString *sid = @"SwitchCell";
        CISwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:sid];
        if (!cell) cell = [[CISwitchCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:sid];
        cell.textLabel.text = row[@"title"];
        cell.configKey = row[@"key"];
        return cell;
    }

    // Text field cell
    static NSString *tid = @"TextCell";
    CITextFieldCell *cell = [tableView dequeueReusableCellWithIdentifier:tid];
    if (!cell) cell = [[CITextFieldCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:tid];
    cell.textLabel.text = row[@"title"];
    cell.configKey = row[@"key"];
    cell.textField.placeholder = row[@"placeholder"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    NSString *action = row[@"action"];

    if ([action isEqualToString:@"save"]) {
        [[CIConfigManager shared] save];
        [[CIConfigManager shared] postReload];
        ci_run_cmd("/var/jb/usr/bin/sbreload 2>/dev/null || killall -9 SpringBoard 2>/dev/null");
        [self showAlert:@"Saved" message:@"Settings saved and respring triggered."];
    }

    if ([action isEqualToString:@"reset"]) {
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"Reset All"
                                                                   message:@"This will remove all spoof settings. Are you sure?"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
            [[NSFileManager defaultManager] removeItemAtPath:kPrefPath error:nil];
            [[CIConfigManager shared] load];
            [self.table reloadData];
            [self showAlert:@"Reset" message:@"All settings cleared."];
        }]];
        [self presentViewController:ac animated:YES completion:nil];
    }
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

// ============================================================
// PAGE 1: RRS (App List)
// ============================================================
@interface CIRRSViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<CIAppInfo *> *allApps;
@property (nonatomic, strong) NSArray<CIAppInfo *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedBundles;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation CIRRSViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"App List";
    self.view.backgroundColor = [CITheme backgroundColor];
    self.selectedBundles = [NSMutableSet set];

    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [CITheme backgroundColor];
        app.titleTextAttributes = @{NSForegroundColorAttributeName: [CITheme textColor]};
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"Search by name or bundle ID...";
    self.searchBar.delegate = self;
    self.searchBar.barTintColor = [CITheme backgroundColor];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = [CITheme backgroundColor];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.separatorColor = [CITheme separatorColor];
    [self.view addSubview:self.table];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [CITheme accentColor];
    [self.view addSubview:self.spinner];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Select All" style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)],
        [[UIBarButtonItem alloc] initWithTitle:@"Reset" style:UIBarButtonItemStylePlain target:self action:@selector(resetSelected)],
    ];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [self loadApps];
}

- (void)loadApps {
    [self.spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *apps = [CIAppScanner scanInstalledApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allApps = apps;
            self.filteredApps = apps;
            [self.spinner stopAnimating];
            [self.table reloadData];
        });
    });
}

- (void)selectAll {
    [self.selectedBundles removeAllObjects];
    for (CIAppInfo *app in self.filteredApps) {
        [self.selectedBundles addObject:app.bundleId];
    }
    [self.table reloadData];
}

- (void)resetSelected {
    if (self.selectedBundles.count == 0) {
        [self showAlert:@"No Apps Selected" message:@"Please select apps to reset."];
        return;
    }

    [[CIConfigManager shared] setValue:[self.selectedBundles allObjects] forKey:@"targetBundles"];
    [[CIConfigManager shared] save];

    // Wipe selected apps
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSString *bid in self.selectedBundles) {
            NSString *esc = [bid stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
            NSString *script = [NSString stringWithFormat:
                @"for dir in /var/mobile/Containers/Data/Application/*; do "
                "  if [ -f \"$dir/.com.apple.mobile_container_manager.metadata.plist\" ]; then "
                "    if grep -qF '%@' \"$dir/.com.apple.mobile_container_manager.metadata.plist\" 2>/dev/null; then "
                "      rm -rf \"$dir/Library/Caches\" \"$dir/Library/Preferences\" \"$dir/Library/WebKit\" \"$dir/Documents\" 2>/dev/null; "
                "    fi; "
                "  fi; "
                "done", esc];
            ci_run_cmd([script cStringUsingEncoding:NSUTF8StringEncoding]);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [[CIConfigManager shared] postReload];
            ci_run_cmd("/var/jb/usr/bin/sbreload 2>/dev/null || killall -9 SpringBoard 2>/dev/null");
            [self showAlert:@"Reset Complete" message:[NSString stringWithFormat:@"%lu apps reset.", (unsigned long)self.selectedBundles.count]];
            [self.selectedBundles removeAllObjects];
            [self.table reloadData];
        });
    });
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR bundleId CONTAINS[cd] %@", searchText, searchText];
        self.filteredApps = [self.allApps filteredArrayUsingPredicate:pred];
    }
    [self.table reloadData];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"AppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [CITheme cardBackground];
        cell.textLabel.textColor = [CITheme textColor];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.textColor = [CITheme textSecondary];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    CIAppInfo *app = self.filteredApps[indexPath.row];
    cell.textLabel.text = app.name;
    cell.detailTextLabel.text = app.bundleId;

    if ([self.selectedBundles containsObject:app.bundleId]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
        cell.tintColor = [CITheme accentColor];
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    CIAppInfo *app = self.filteredApps[indexPath.row];
    if ([self.selectedBundles containsObject:app.bundleId]) {
        [self.selectedBundles removeObject:app.bundleId];
    } else {
        [self.selectedBundles addObject:app.bundleId];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end

// ============================================================
// PAGE 2: BACKUP / APP SELECTION
// ============================================================
@interface CIAppsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<CIAppInfo *> *allApps;
@property (nonatomic, strong) NSArray<CIAppInfo *> *filteredApps;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedBundles;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation CIAppsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Backup & Reset";
    self.view.backgroundColor = [CITheme backgroundColor];
    self.selectedBundles = [NSMutableSet set];

    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [CITheme backgroundColor];
        app.titleTextAttributes = @{NSForegroundColorAttributeName: [CITheme textColor]};
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    self.searchBar = [[UISearchBar alloc] init];
    self.searchBar.placeholder = @"Search apps...";
    self.searchBar.delegate = self;
    self.searchBar.barTintColor = [CITheme backgroundColor];
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.table.translatesAutoresizingMaskIntoConstraints = NO;
    self.table.backgroundColor = [CITheme backgroundColor];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.separatorColor = [CITheme separatorColor];
    [self.view addSubview:self.table];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.color = [CITheme accentColor];
    [self.view addSubview:self.spinner];

    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Select All" style:UIBarButtonItemStylePlain target:self action:@selector(selectAll)],
        [[UIBarButtonItem alloc] initWithTitle:@"Backup" style:UIBarButtonItemStylePlain target:self action:@selector(backupSelected)],
    ];

    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.table.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    [self loadApps];
}

- (void)loadApps {
    [self.spinner startAnimating];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *apps = [CIAppScanner scanInstalledApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allApps = apps;
            self.filteredApps = apps;
            [self.spinner stopAnimating];
            [self.table reloadData];
        });
    });
}

- (void)selectAll {
    [self.selectedBundles removeAllObjects];
    for (CIAppInfo *app in self.filteredApps) {
        [self.selectedBundles addObject:app.bundleId];
    }
    [self.table reloadData];
}

- (void)backupSelected {
    if (self.selectedBundles.count == 0) {
        [self showAlert:@"No Apps Selected" message:@"Please select apps to backup."];
        return;
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *ts = [self timestamp];
        NSString *backupDir = @"/var/mobile/ChangeInfoIos/backups";
        ci_run_cmd([[NSString stringWithFormat:@"mkdir -p %@", backupDir] cStringUsingEncoding:NSUTF8StringEncoding]);

        for (NSString *bid in self.selectedBundles) {
            NSString *esc = [bid stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
            NSString *cmd = [NSString stringWithFormat:
                @"TS=%@; mkdir -p %@; "
                "for dir in /var/mobile/Containers/Data/Application/*; do "
                "  if [ -f \"$dir/.com.apple.mobile_container_manager.metadata.plist\" ]; then "
                "    if grep -qF '%@' \"$dir/.com.apple.mobile_container_manager.metadata.plist\" 2>/dev/null; then "
                "      tar -czf \"%@/%@-${TS}.tgz\" -C \"$dir\" . 2>/dev/null; "
                "    fi; "
                "  fi; "
                "done", ts, backupDir, esc, backupDir, esc];
            ci_run_cmd([cmd cStringUsingEncoding:NSUTF8StringEncoding]);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            ci_run_cmd([[NSString stringWithFormat:@"chown -R mobile:mobile %@", backupDir] cStringUsingEncoding:NSUTF8StringEncoding]);
            [self showAlert:@"Backup Complete" message:[NSString stringWithFormat:@"%lu apps backed up to %@", (unsigned long)self.selectedBundles.count, backupDir]];
        });
    });
}

- (NSString *)timestamp {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    return [fmt stringFromDate:[NSDate date]];
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredApps = self.allApps;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithFormat:@"name CONTAINS[cd] %@ OR bundleId CONTAINS[cd] %@", searchText, searchText];
        self.filteredApps = [self.allApps filteredArrayUsingPredicate:pred];
    }
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"AppCell2";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
        cell.backgroundColor = [CITheme cardBackground];
        cell.textLabel.textColor = [CITheme textColor];
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.detailTextLabel.textColor = [CITheme textSecondary];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    }

    CIAppInfo *app = self.filteredApps[indexPath.row];
    cell.textLabel.text = app.name;
    cell.detailTextLabel.text = app.bundleId;
    cell.accessoryType = [self.selectedBundles containsObject:app.bundleId] ?
        UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [CITheme accentColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    CIAppInfo *app = self.filteredApps[indexPath.row];
    if ([self.selectedBundles containsObject:app.bundleId]) {
        [self.selectedBundles removeObject:app.bundleId];
    } else {
        [self.selectedBundles addObject:app.bundleId];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end

// ============================================================
// PAGE 3: SETUP / WIPE SETTINGS
// ============================================================
@interface CISetupViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *sections;
@end

@implementation CISetupViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Thiết lập";
    self.view.backgroundColor = [CITheme backgroundColor];

    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [CITheme backgroundColor];
        app.titleTextAttributes = @{NSForegroundColorAttributeName: [CITheme textColor]};
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [CITheme backgroundColor];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.separatorColor = [CITheme separatorColor];
    [self.view addSubview:self.table];

    self.sections = @[
        @{@"header": @"Wipe Settings", @"rows": @[
            @{@"title": @"Clear All Apps",         @"key": @"set_clearAllApps"},
            @{@"title": @"Clear Safari Data",      @"key": @"set_clearSafari"},
            @{@"title": @"Backup Safari Data",     @"key": @"set_backupSafari"},
            @{@"title": @"Auto Allow Permissions",  @"key": @"set_autoAllow"},
            @{@"title": @"Wipe After Deploy",       @"key": @"set_wipeAfterDeploy"},
        ]},
        @{@"header": @"Reset Settings", @"rows": @[
            @{@"title": @"Apply Spoof on Reset",   @"key": @"set_applySpoofOnReset"},
            @{@"title": @"Proxy on Reset",          @"key": @"set_proxyOnReset"},
            @{@"title": @"Close After Reset",       @"key": @"set_closeAfter"},
            @{@"title": @"Loop Proxy",              @"key": @"set_loopProxy"},
        ]},
        @{@"header": @"About", @"rows": @[
            @{@"title": @"Version",    @"detail": @"2.2.1"},
            @{@"title": @"Build",      @"detail": @"Native UI"},
            @{@"title": @"Contact",    @"detail": @"ios.shadowtech.vip"},
        ]},
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[CIConfigManager shared] load];
    [self.table reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [self.sections[section][@"header"] uppercaseString];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hv = (UITableViewHeaderFooterView *)view;
        hv.textLabel.textColor = [CITheme textSecondary];
        hv.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.sections[section][@"rows"] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
    NSString *key = row[@"key"];
    NSString *detail = row[@"detail"];

    if (key) {
        static NSString *sid = @"SetupSwitchCell";
        CISwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:sid];
        if (!cell) cell = [[CISwitchCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:sid];
        cell.textLabel.text = row[@"title"];
        cell.configKey = key;
        return cell;
    } else {
        static NSString *did = @"DetailCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:did];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:did];
            cell.backgroundColor = [CITheme cardBackground];
            cell.textLabel.textColor = [CITheme textColor];
            cell.detailTextLabel.textColor = [CITheme textSecondary];
        }
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = detail;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
}

@end

// ============================================================
// PAGE 4: SETTINGS (Fake Layers)
// ============================================================
@interface CISettingsViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) NSArray *fakeLayers;
@end

@implementation CISettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.view.backgroundColor = [CITheme backgroundColor];

    if (@available(iOS 15.0, *)) {
        UINavigationBarAppearance *app = [[UINavigationBarAppearance alloc] init];
        [app configureWithOpaqueBackground];
        app.backgroundColor = [CITheme backgroundColor];
        app.titleTextAttributes = @{NSForegroundColorAttributeName: [CITheme textColor]};
        self.navigationController.navigationBar.standardAppearance = app;
        self.navigationController.navigationBar.scrollEdgeAppearance = app;
    }

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.backgroundColor = [CITheme backgroundColor];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.separatorColor = [CITheme separatorColor];
    [self.view addSubview:self.table];

    self.fakeLayers = @[
        @{@"title": @"UIDevice",        @"desc": @"Name, Model, System Version, IDFA, Battery",  @"key": @"fake_uiddevice"},
        @{@"title": @"Hardware",         @"desc": @"UDID, Serial, IMEI, MAC, ChipID",          @"key": @"fake_hardware"},
        @{@"title": @"Network",          @"desc": @"Carrier Name, MCC, MNC, WiFi SSID/BSSID",    @"key": @"fake_network"},
        @{@"title": @"Screen",           @"desc": @"Resolution, Scale, Native bounds",            @"key": @"fake_screen"},
        @{@"title": @"Location",         @"desc": @"GPS coordinates, Altitude, Accuracy",       @"key": @"fake_location"},
        @{@"title": @"Browser",          @"desc": @"WebView UA, WebGL, Canvas fingerprint",      @"key": @"fake_browser"},
        @{@"title": @"WebRTC",           @"desc": @"Block WebRTC camera/mic enumeration",       @"key": @"fake_webrtc"},
        @{@"title": @"Locale",           @"desc": @"Country, Language, Currency",               @"key": @"fake_locale"},
        @{@"title": @"DateTime",         @"desc": @"Timezone override",                          @"key": @"fake_datetime"},
        @{@"title": @"Sensor",           @"desc": @"Gyroscope, Accelerometer, Magnetometer",    @"key": @"fake_sensor"},
        @{@"title": @"Tracking Defaults",@"desc": @"Block tracking keys in NSUserDefaults",     @"key": @"fake_trackingdefaults"},
        @{@"title": @"Pasteboard",       @"desc": @"Clear clipboard tracking",                   @"key": @"fake_tracking_pasteboard"},
        @{@"title": @"Jailbreak Hide",   @"desc": @"Hide jailbreak files from app checks",      @"key": @"fake_jbhide"},
        @{@"title": @"Real Screen",      @"desc": @"Native screen resolution",                  @"key": @"fake_realscreen"},
        @{@"title": @"Process Info",     @"desc": @"Hostname, CPU count, RAM, Uptime",           @"key": @"fake_processinfo"},
    ];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[CIConfigManager shared] load];
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.fakeLayers.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *sid = @"FakeLayerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:sid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:sid];
        cell.backgroundColor = [CITheme cardBackground];
        cell.textLabel.textColor = [CITheme textColor];
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        cell.detailTextLabel.textColor = [CITheme textSecondary];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    }

    NSDictionary *layer = self.fakeLayers[indexPath.row];
    cell.textLabel.text = layer[@"title"];
    cell.detailTextLabel.text = layer[@"desc"];

    BOOL on = [[CIConfigManager shared] boolForKey:layer[@"key"]];
    cell.accessoryType = on ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.tintColor = [CITheme accentColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSDictionary *layer = self.fakeLayers[indexPath.row];
    NSString *key = layer[@"key"];
    BOOL current = [[CIConfigManager shared] boolForKey:key];
    [[CIConfigManager shared] setBool:!current forKey:key];
    [[CIConfigManager shared] save];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @"FAKE LAYERS";
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    if ([view isKindOfClass:[UITableViewHeaderFooterView class]]) {
        UITableViewHeaderFooterView *hv = (UITableViewHeaderFooterView *)view;
        hv.textLabel.textColor = [CITheme textSecondary];
        hv.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    }
}

@end

// ============================================================
// APP DELEGATE
// ============================================================
@interface CIAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation CIAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[CIConfigManager shared] load];

    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    CITabBarController *tabs = [[CITabBarController alloc] init];
    self.window.rootViewController = tabs;
    [self.window makeKeyAndVisible];

    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

@end

// ============================================================
// MAIN
// ============================================================
int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, @"CIAppDelegate");
    }
}
