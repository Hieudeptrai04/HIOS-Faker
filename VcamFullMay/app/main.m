// ============================================================
// VcamFullMay App — companion UI for the camera-spoof tweak.
//
// Single-screen iOS app that lets the user:
//   1. Pick a video from Photos library
//   2. Copy it to /var/jb/etc/vcam/video.mp4 (the path the tweak reads)
//   3. Toggle vcam on/off
//   4. Re-roll the random GPS city
//   5. See current spoof status
//
// Requires no-sandbox entitlement to write to /var/jb/etc/vcam/
// (handled by entitlements.plist).
// ============================================================

#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>

// kUTTypeMovie was deprecated in iOS 14 and removed from MobileCoreServices
// headers in iOS 15 SDK. The string constant is stable: "public.movie".
static NSString *const kVcamUTTypeMovie = @"public.movie";

static NSString *const kVcamConfigPath = @"/var/jb/etc/vcam/config.plist";
static NSString *const kVcamVideoPath  = @"/var/jb/etc/vcam/video.mp4";
static NSString *const kVcamDir        = @"/var/jb/etc/vcam";

// ============================================================
// CONFIG HELPERS
// ============================================================
static NSMutableDictionary *vcamLoadConfig(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kVcamConfigPath];
    return d ? [d mutableCopy] : [NSMutableDictionary new];
}

static BOOL vcamSaveConfig(NSDictionary *cfg) {
    [[NSFileManager defaultManager] createDirectoryAtPath:kVcamDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return [cfg writeToFile:kVcamConfigPath atomically:YES];
}

static BOOL vcamIsEnabled(void) {
    NSDictionary *cfg = vcamLoadConfig();
    id e = cfg[@"enabled"];
    if (e && [e respondsToSelector:@selector(boolValue)]) return [e boolValue];
    return YES;
}

static NSString *vcamCurrentVideoSize(void) {
    NSError *err = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfItemAtPath:kVcamVideoPath error:&err];
    if (!attrs) return @"chưa có";
    unsigned long long sz = [attrs[NSFileSize] unsignedLongLongValue];
    if (sz < 1024)         return [NSString stringWithFormat:@"%llu B", sz];
    if (sz < 1024*1024)    return [NSString stringWithFormat:@"%.1f KB", (double)sz/1024.0];
    return [NSString stringWithFormat:@"%.1f MB", (double)sz/1024.0/1024.0];
}

// ============================================================
// MAIN VIEW CONTROLLER
// ============================================================
@interface VcamRootVC : UIViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, strong) UILabel  *statusLabel;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@end

@implementation VcamRootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"VcamFullMay";

    // === Status section ===
    self.statusLabel = [UILabel new];
    self.statusLabel.numberOfLines  = 0;
    self.statusLabel.font           = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    // === Enabled toggle ===
    UILabel *toggleLbl = [UILabel new];
    toggleLbl.text = @"Bật vcam (camera fake)";
    toggleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:toggleLbl];

    self.enabledSwitch = [UISwitch new];
    self.enabledSwitch.on = vcamIsEnabled();
    [self.enabledSwitch addTarget:self action:@selector(toggleEnabled:) forControlEvents:UIControlEventValueChanged];
    self.enabledSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.enabledSwitch];

    // === Pick video button ===
    UIButton *pickBtn = [self primaryButton:@"📹 Chọn video từ thư viện ảnh"
                                     action:@selector(pickVideo)];
    [self.view addSubview:pickBtn];

    // === Random GPS button ===
    UIButton *gpsBtn = [self primaryButton:@"🌏 Random GPS Việt Nam"
                                    action:@selector(randomGPS)];
    [self.view addSubview:gpsBtn];

    // === Clear video button ===
    UIButton *clearBtn = [self secondaryButton:@"🗑 Xóa video hiện tại"
                                        action:@selector(clearVideo)];
    [self.view addSubview:clearBtn];

    // === Layout ===
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.statusLabel.topAnchor      constraintEqualToAnchor:safe.topAnchor constant:20],
        [self.statusLabel.leadingAnchor  constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [toggleLbl.topAnchor        constraintEqualToAnchor:self.statusLabel.bottomAnchor constant:30],
        [toggleLbl.leadingAnchor    constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.enabledSwitch.centerYAnchor constraintEqualToAnchor:toggleLbl.centerYAnchor],
        [self.enabledSwitch.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],

        [pickBtn.topAnchor       constraintEqualToAnchor:toggleLbl.bottomAnchor constant:30],
        [pickBtn.leadingAnchor   constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [pickBtn.trailingAnchor  constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [pickBtn.heightAnchor    constraintEqualToConstant:54],

        [gpsBtn.topAnchor        constraintEqualToAnchor:pickBtn.bottomAnchor constant:12],
        [gpsBtn.leadingAnchor    constraintEqualToAnchor:pickBtn.leadingAnchor],
        [gpsBtn.trailingAnchor   constraintEqualToAnchor:pickBtn.trailingAnchor],
        [gpsBtn.heightAnchor     constraintEqualToConstant:54],

        [clearBtn.topAnchor      constraintEqualToAnchor:gpsBtn.bottomAnchor constant:12],
        [clearBtn.leadingAnchor  constraintEqualToAnchor:pickBtn.leadingAnchor],
        [clearBtn.trailingAnchor constraintEqualToAnchor:pickBtn.trailingAnchor],
        [clearBtn.heightAnchor   constraintEqualToConstant:48],
    ]];

    [self refreshStatus];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshStatus];
}

- (UIButton *)primaryButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = [UIColor systemBlueColor];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    b.layer.cornerRadius = 12;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (UIButton *)secondaryButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = [UIColor systemGray5Color];
    [b setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:15];
    b.layer.cornerRadius = 10;
    b.translatesAutoresizingMaskIntoConstraints = NO;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)refreshStatus {
    NSMutableDictionary *cfg = vcamLoadConfig();
    NSString *videoStatus = vcamCurrentVideoSize();
    NSString *lat = cfg[@"latitude"]    ?: @"(random)";
    NSString *lng = cfg[@"longitude"]   ?: @"(random)";
    NSString *city = cfg[@"_locationName"] ?: @"(auto-pick lúc app inject)";

    self.statusLabel.text =
        [NSString stringWithFormat:
            @"VIDEO\n  Path:  /var/jb/etc/vcam/video.mp4\n  Size:  %@\n\n"
            @"GPS\n  City:  %@\n  Lat:   %@\n  Lng:   %@\n\n"
            @"STATUS\n  Tweak: %@",
         videoStatus,
         city,
         lat, lng,
         vcamIsEnabled() ? @"BẬT (vcam đang hoạt động)" : @"TẮT"];
}

- (void)toggleEnabled:(UISwitch *)sw {
    NSMutableDictionary *cfg = vcamLoadConfig();
    cfg[@"enabled"] = @(sw.isOn);
    vcamSaveConfig(cfg);
    [self refreshStatus];
    [self toast:sw.isOn ? @"Đã bật vcam — respring app target để có hiệu lực" : @"Đã tắt vcam"];
}

// ============================================================
// VIDEO PICKER
// ============================================================
- (void)pickVideo {
    // Request Photos auth first (entitlement pre-grants but the framework
    // still needs a permission check via PHPhotoLibrary).
    PHAuthorizationStatus auth = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    if (auth == PHAuthorizationStatusDenied || auth == PHAuthorizationStatusRestricted) {
        [self alert:@"Lỗi quyền"
            message:@"Hãy vào Cài đặt → VcamFullMay → bật quyền truy cập Ảnh."];
        return;
    }
    if (auth == PHAuthorizationStatusNotDetermined) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
                                                   handler:^(PHAuthorizationStatus s) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (s == PHAuthorizationStatusAuthorized || s == PHAuthorizationStatusLimited) {
                    [self presentPicker];
                }
            });
        }];
        return;
    }
    [self presentPicker];
}

- (void)presentPicker {
    UIImagePickerController *picker = [UIImagePickerController new];
    picker.sourceType  = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes  = @[kVcamUTTypeMovie];
    picker.delegate    = self;
    picker.videoQuality = UIImagePickerControllerQualityTypeHigh;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker
       didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    NSURL *src = info[UIImagePickerControllerMediaURL];
    [picker dismissViewControllerAnimated:YES completion:^{
        if (!src) {
            [self toast:@"❌ Không lấy được URL video"];
            return;
        }
        [self copyVideoFromURL:src];
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyVideoFromURL:(NSURL *)src {
    NSFileManager *fm = [NSFileManager defaultManager];

    // Ensure target dir exists, world-writable.
    [fm createDirectoryAtPath:kVcamDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Remove existing video (overwrite).
    [fm removeItemAtPath:kVcamVideoPath error:nil];

    NSError *err = nil;
    BOOL ok = [fm copyItemAtURL:src toURL:[NSURL fileURLWithPath:kVcamVideoPath] error:&err];
    if (!ok) {
        [self alert:@"Copy lỗi"
            message:[NSString stringWithFormat:@"Không copy được video:\n%@\n\nTarget path có thể không ghi được. SSH check chmod /var/jb/etc/vcam", err.localizedDescription]];
        return;
    }

    // Set 0644 so the tweak running in target app's sandbox can read.
    [fm setAttributes:@{NSFilePosixPermissions: @0644}
         ofItemAtPath:kVcamVideoPath
                error:nil];

    [self refreshStatus];
    [self alert:@"✓ Đã lưu video"
        message:[NSString stringWithFormat:
            @"Video đã copy sang:\n%@\n\nKích thước: %@\n\nBật/relaunch Zalo (hoặc app target) để vcam phát video này.",
            kVcamVideoPath, vcamCurrentVideoSize()]];
}

- (void)clearVideo {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:@"Xóa video?"
                         message:@"Sau khi xóa, camera sẽ về camera thật cho tới khi bạn chọn video mới."
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"Xóa" style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        [[NSFileManager defaultManager] removeItemAtPath:kVcamVideoPath error:nil];
        [self refreshStatus];
        [self toast:@"Đã xóa video"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

// ============================================================
// RANDOM GPS — pick from VN cities + write to config
// ============================================================
- (void)randomGPS {
    // Same 30-city pool as Tweak.xm. Re-roll + persist to config.
    static NSArray *cities = nil;
    if (!cities) cities = @[
        @[@21.0285, @105.8542, @"Hà Nội"],
        @[@20.8449, @106.6881, @"Hải Phòng"],
        @[@20.9601, @107.0763, @"Hạ Long"],
        @[@21.5944, @105.8480, @"Thái Nguyên"],
        @[@21.7167, @104.9000, @"Yên Bái"],
        @[@21.1861, @106.0763, @"Bắc Ninh"],
        @[@21.2731, @106.1947, @"Bắc Giang"],
        @[@22.8268, @104.9784, @"Hà Giang"],
        @[@19.8067, @105.7852, @"Thanh Hóa"],
        @[@18.6792, @105.6817, @"Vinh"],
        @[@17.4683, @106.6222, @"Đồng Hới"],
        @[@16.4637, @107.5909, @"Huế"],
        @[@16.0544, @108.2022, @"Đà Nẵng"],
        @[@15.5793, @108.4791, @"Tam Kỳ"],
        @[@15.1213, @108.8044, @"Quảng Ngãi"],
        @[@13.7820, @109.2192, @"Quy Nhơn"],
        @[@13.0942, @109.2960, @"Tuy Hòa"],
        @[@12.2388, @109.1967, @"Nha Trang"],
        @[@11.5645, @108.9889, @"Phan Rang"],
        @[@13.9833, @108.0000, @"Pleiku"],
        @[@12.6798, @108.0383, @"Buôn Ma Thuột"],
        @[@11.9404, @108.4583, @"Đà Lạt"],
        @[@10.9332, @108.0950, @"Phan Thiết"],
        @[@10.7769, @106.7009, @"Hồ Chí Minh"],
        @[@10.9574, @106.8426, @"Biên Hòa"],
        @[@10.3460, @107.0843, @"Vũng Tàu"],
        @[@10.3600, @106.3590, @"Mỹ Tho"],
        @[@10.0452, @105.7469, @"Cần Thơ"],
        @[@10.0125, @105.0807, @"Rạch Giá"],
        @[@9.1768,  @105.1524, @"Cà Mau"],
    ];
    uint32_t idx = arc4random_uniform((uint32_t)cities.count);
    NSArray *city = cities[idx];
    double lat = [city[0] doubleValue];
    double lng = [city[1] doubleValue];
    NSString *name = city[2];
    // Add ±0.01° (~1km) jitter.
    lat += ((double)arc4random_uniform(20000) / 1000000.0) - 0.010;
    lng += ((double)arc4random_uniform(20000) / 1000000.0) - 0.010;

    NSMutableDictionary *cfg = vcamLoadConfig();
    cfg[@"latitude"]      = @(lat);
    cfg[@"longitude"]     = @(lng);
    cfg[@"altitude"]      = @(5.0 + (double)arc4random_uniform(50));
    cfg[@"_locationName"] = name;
    vcamSaveConfig(cfg);

    [self refreshStatus];
    [self toast:[NSString stringWithFormat:@"📍 GPS mới: %@", name]];
}

// ============================================================
// UI HELPERS
// ============================================================
- (void)toast:(NSString *)msg {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:nil message:msg
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:ac animated:YES completion:^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ac dismissViewControllerAnimated:YES completion:nil];
        });
    }];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *ac = [UIAlertController
        alertControllerWithTitle:title message:msg
                  preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"OK"
                                           style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

@end

// ============================================================
// APP DELEGATE
// ============================================================
@interface VcamAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation VcamAppDelegate
- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController =
        [[UINavigationController alloc] initWithRootViewController:[VcamRootVC new]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([VcamAppDelegate class]));
    }
}
