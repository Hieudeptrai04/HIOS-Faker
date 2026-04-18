#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <sys/types.h>
#import <spawn.h>
#import <notify.h>
#import <dlfcn.h>
#import <sys/utsname.h>

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
static NSString *const kRRSDir         = @"/var/mobile/Library/ChangeInfoIos/RRS";
static NSString *const kNotifyReload   = @"com.changeinfoios/ReloadPrefs";

static NSString *const kAppVersion = @"2.2.1-native";

static NSString *CILocalConfigPath(void) {
    static NSString *p = nil; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        p = [dirs.firstObject stringByAppendingPathComponent:@"config.plist"];
    });
    return p;
}

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
    // 1) Always persist to app sandbox (writable, survives cold launch)
    [data writeToFile:CILocalConfigPath() atomically:YES];
    // 2) Best-effort mirror to shared path so tweak can read it (may fail on stock sandbox)
    NSString *dir = [kSharedPrefPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [data writeToFile:kSharedPrefPath atomically:YES];
    chmod([kSharedPrefPath fileSystemRepresentation], 0644);
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
    Class UIImageCls = NSClassFromString(@"UIImage");
    SEL sel = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([UIImageCls respondsToSelector:sel]) {
        NSMethodSignature *sig = [UIImageCls methodSignatureForSelector:sel];
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
        if (img) return img;
    }
    return nil;
}

+ (NSArray<CIAppInfo *> *)allApps {
    static NSArray *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *result = [NSMutableArray array];
        Class LSAWCls = NSClassFromString(@"LSApplicationWorkspace");
        LSApplicationWorkspace *ws = [LSAWCls performSelector:@selector(defaultWorkspace)];
        NSArray *apps = [ws allInstalledApplications];
        for (LSApplicationProxy *proxy in apps) {
            @autoreleasepool {
                NSString *bid = [proxy bundleIdentifier] ?: [proxy applicationIdentifier];
                if (!bid) continue;
                // Only AppStore-installed (User) apps — skip System / Internal / Hidden / jb app itself
                NSString *type = [proxy applicationType] ?: @"";
                if (![type isEqualToString:@"User"]) continue;
                if ([bid hasPrefix:@"com.apple."]) continue;
                if ([bid isEqualToString:@"com.changeinfoios.app"]) continue;
                CIAppInfo *info = [[CIAppInfo alloc] init];
                info.bundleID = bid;
                info.name = [proxy localizedName] ?: bid;
                id burl = [proxy bundleURL];
                info.bundlePath = [burl respondsToSelector:@selector(path)] ? [burl path] : nil;
                id durl = [proxy dataContainerURL];
                info.containerPath = [durl respondsToSelector:@selector(path)] ? [durl path] : nil;
                info.isSystem = NO;
                info.icon = [self iconForBundle:bid size:60];
                info.containerSize = 0; // lazy
                [result addObject:info];
            }
        }
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
    c.detailTextLabel.text = a.bundleID;
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

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Fake iOS version & model";
    self.view.backgroundColor = [CITheme bg];
    self.tableView.backgroundColor = [CITheme bg];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self buildRows];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
}

- (void)done { [[CIConfigManager shared] save]; [self.navigationController popViewControllerAnimated:YES]; }

- (void)buildRows {
    Class C = [CIFakeSettingsViewController class];
    _rows = [NSMutableArray array];

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
    CGFloat pad = 12 + r.leftPad;

    if (r.kind == CIRowHeader) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 12, W-pad-12, 28)];
        l.text = r.title; l.font = [CITheme h2]; l.textColor = [CITheme blue];
        [c.contentView addSubview:l];
        return c;
    }
    if (r.kind == CIRowNote) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 4, W-pad-12, 36)];
        l.text = r.title; l.font = [UIFont italicSystemFontOfSize:13]; l.textColor = [CITheme orange];
        l.numberOfLines = 0;
        [c.contentView addSubview:l];
        return c;
    }
    if (r.kind == CIRowToggle) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 10, W-pad-70, 32)];
        l.text = r.title; l.font = [CITheme body]; l.textColor = [CITheme blue];
        l.numberOfLines = 0; l.adjustsFontSizeToFitWidth = YES; l.minimumScaleFactor = 0.8;
        [c.contentView addSubview:l];
        UISwitch *sw = [[UISwitch alloc] init];
        sw.frame = CGRectMake(W-60, 8, 51, 31);
        sw.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
        sw.onTintColor = [CITheme blue];
        NSString *cfgKey = [r.key hasPrefix:@"fake_"] ? [@"fake_" stringByAppendingString:[r.key substringFromIndex:5]] : r.key;
        sw.on = [[CIConfigManager shared] boolForKey:cfgKey];
        objc_setAssociatedObject(sw, @"ciKey", cfgKey, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        [c.contentView addSubview:sw];
        return c;
    }
    if (r.kind == CIRowText) {
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(pad, 6, W-pad-12, 18)];
        l.text = r.title; l.font = [CITheme small]; l.textColor = [CITheme dim];
        [c.contentView addSubview:l];
        UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(pad, 26, W-pad-12, 34)];
        tf.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        tf.placeholder = r.placeholder ?: @"";
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
    return 70;
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
    self.title = @"Xóa Info";

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
    foot.text = @"fb.com/groups/XoaInfo"; foot.textAlignment = NSTextAlignmentCenter;
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
    if (backup) {
        NSArray<NSString *> *rrsBids = [[CIConfigManager shared] rrsBundles];
        if (rrsBids.count == 0) {
            [self alert:@"Chưa chọn app lưu RRS" msg:@"Vào mục 2 để chọn app cần lưu retention."]; return;
        }
        [self createRRSForBundles:rrsBids note:_noteField.text];
    }

    NSArray<CIAppInfo *> *all = [CIAppLister allApps];
    NSMutableArray *names = [NSMutableArray array]; NSMutableArray *paths = [NSMutableArray array];
    for (CIAppInfo *a in all) {
        if ([resetBids containsObject:a.bundleID] && a.containerPath.length) {
            [names addObject:a.name]; [paths addObject:a.containerPath];
        }
    }
    if (paths.count == 0) { [self alert:@"Không tìm thấy container" msg:@"Không đọc được data container của app đã chọn."]; return; }

    int failed = 0;
    for (NSString *p in paths) {
        NSString *cmd = [NSString stringWithFormat:@"rm -rf %@/Documents/* %@/Library/Caches/* %@/Library/Preferences/* %@/tmp/* 2>/dev/null", p, p, p, p];
        if (ci_run([cmd UTF8String]) != 0) failed++;
    }
    [[CIConfigManager shared] notifyReload];
    [self alert:@"Hoàn tất" msg:[NSString stringWithFormat:@"Đã reset %lu/%lu app.%@", (unsigned long)(paths.count-failed), (unsigned long)paths.count, failed ? @"\n(Lỗi có thể do quyền)" : @""]];
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
    NSString *cmd = [NSString stringWithFormat:@"tar -xzf %@ -C /", tar];
    int rc = ci_run([cmd UTF8String]);
    [self alert:(rc == 0 ? @"Đã restore" : @"Restore fail") msg:[NSString stringWithFormat:@"rc=%d", rc]];
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
