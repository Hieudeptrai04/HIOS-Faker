// ============================================================
// VcamFullMay — Virtual camera replacement tweak (iOS rootless JB)
//
// Replaces the live camera feed with frames decoded from a user-chosen
// video file. Works in any app that uses AVCaptureSession +
// AVCaptureVideoDataOutput — Zalo, FB, Instagram, TikTok, WhatsApp, etc.
//
// Strategy:
//   1. Hook -[AVCaptureVideoDataOutput setSampleBufferDelegate:queue:]
//   2. Wrap the app's real delegate with a proxy.
//   3. Proxy decodes next frame from the user's video (matched to the
//      session's exact pixel format + dimensions via AVAssetReader output
//      settings) and rebuilds a CMSampleBuffer that keeps the real
//      frame's timing info — encoders downstream see consistent PTS.
//   4. Audio stream from the mic is UNTOUCHED — only video is replaced.
//
// Anti-detection (comprehensive — matches what banking / tier-1 anti-
// fraud SDKs probe):
//   Obj-C:
//     - NSFileManager hides /var/jb, Cydia/Sileo/Zebra paths
//     - UIApplication.canOpenURL blocks cydia/sileo/filza schemes
//   C-level (THE PART MOST OTHER VCAM TWEAKS MISS):
//     - dlopen   returns NULL for substrate-family dylib paths
//     - stat / lstat / access / fopen return ENOENT for /var/jb + JB paths
//     - _dyld_image_count + _dyld_get_image_name hide our dylib and the
//       substrate hook engines from dyld walks
//     - dladdr masks substrate symbol lookups as UIKit
//
// Configuration:
//   /var/jb/etc/vcam/config.plist (optional):
//     <key>videoPath</key>     <string>/var/jb/etc/vcam/video.mp4</string>
//     <key>enabled</key>       <true/>
//
//   Default video path: /var/jb/etc/vcam/video.mp4
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <stdio.h>
#import <errno.h>
#import <string.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>

// Logos preprocesses Tweak.xm into Obj-C++ when any class is declared,
// so external C symbols need explicit C linkage or clang mangles the name.
#ifdef __cplusplus
extern "C" {
#endif
void MSHookFunction(void *symbol, void *replace, void **result);
#ifdef __cplusplus
}
#endif

// ============================================================
// HOOK ACTIVATION GATE
// ============================================================
// CRITICAL: Logos `%hook` directives generate Obj-C `+load` methods that
// install method swizzles BEFORE %ctor runs. That means once our dylib is
// loaded into a process (broad UIKit filter loads us into every UIKit-using
// process — SpringBoard, Sileo, contextstored, healthd, …), the hooks fire
// unconditionally and spoof methods system daemons depend on, crashing them.
//
// %ctor's allowlist check therefore isn't enough — we also need each hook
// method to self-gate. The pattern: a global `g_vcam_active` flag that
// stays 0 by default and is set to 1 only inside %ctor after the bundle-ID
// allowlist passes. Every hooked method starts with `if (!g_vcam_active)
// return %orig;` to fall through to original behavior when the flag isn't
// set, leaving non-target processes completely untouched at runtime.
//
// Discovered the hard way after the broad UIKit filter put us in 165+
// processes and contextstored/healthd/parsecd entered a crash loop.
// The gate flag itself. Each %hook method writes its own check inline —
// `%orig` is a logos preprocessor token and cannot appear inside a C macro
// (the preprocessor only recognizes it at the method call site).
static int g_vcam_active = 0;

// ============================================================
// CONFIG
// ============================================================
static NSString *const kVcamConfigPath       = @"/var/jb/etc/vcam/config.plist";
static NSString *const kVcamDefaultVideoPath = @"/var/jb/etc/vcam/video.mp4";

static NSDictionary *vcamConfig(void) {
    return [NSDictionary dictionaryWithContentsOfFile:kVcamConfigPath];
}

static BOOL vcamEnabled(void) {
    NSDictionary *cfg = vcamConfig();
    id e = cfg[@"enabled"];
    if (e && [e respondsToSelector:@selector(boolValue)]) return [e boolValue];
    return YES;
}

static NSString *vcamVideoPath(void) {
    NSDictionary *cfg = vcamConfig();
    NSString *p = cfg[@"videoPath"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (p.length > 0 && [fm fileExistsAtPath:p]) return p;
    if ([fm fileExistsAtPath:kVcamDefaultVideoPath]) return kVcamDefaultVideoPath;
    return nil;
}

// ============================================================
// PROXY DELEGATE — replaces camera frames with video frames
// ============================================================
@interface VcamProxyDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak)   id<AVCaptureVideoDataOutputSampleBufferDelegate> realDelegate;
@property (nonatomic, copy)   NSString *videoPath;
@property (nonatomic, strong) AVAssetReader *reader;
@property (nonatomic, strong) AVAssetReaderTrackOutput *trackOutput;
@property (nonatomic, assign) int initState;          // 0 unset, 1 ready, 2 failed
@property (nonatomic, assign) size_t  targetW;
@property (nonatomic, assign) size_t  targetH;
@property (nonatomic, assign) OSType  targetPixelFormat;
@end

@implementation VcamProxyDelegate

- (BOOL)setupReader {
    @autoreleasepool {
        AVAsset *asset = [AVAsset assetWithURL:[NSURL fileURLWithPath:self.videoPath]];
        if (!asset) return NO;
        NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
        if (tracks.count == 0) return NO;
        NSError *err = nil;
        AVAssetReader *r = [AVAssetReader assetReaderWithAsset:asset error:&err];
        if (!r) return NO;
        NSDictionary *outSettings = @{
            (NSString *)kCVPixelBufferPixelFormatTypeKey: @(self.targetPixelFormat),
            (NSString *)kCVPixelBufferWidthKey:           @(self.targetW),
            (NSString *)kCVPixelBufferHeightKey:          @(self.targetH),
        };
        AVAssetReaderTrackOutput *o = [AVAssetReaderTrackOutput
            assetReaderTrackOutputWithTrack:tracks[0]
                             outputSettings:outSettings];
        if (![r canAddOutput:o]) return NO;
        [r addOutput:o];
        if (![r startReading]) return NO;
        self.reader = r;
        self.trackOutput = o;
        return YES;
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
       didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if (self.initState == 0) {
        CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sampleBuffer);
        if (ib) {
            self.targetW = CVPixelBufferGetWidth(ib);
            self.targetH = CVPixelBufferGetHeight(ib);
            self.targetPixelFormat = CVPixelBufferGetPixelFormatType(ib);
            self.initState = [self setupReader] ? 1 : 2;
        }
    }
    if (self.initState != 1) {
        if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.realDelegate captureOutput:output
                       didOutputSampleBuffer:sampleBuffer
                              fromConnection:connection];
        }
        return;
    }

    CMSampleBufferRef fakeFrame = [self.trackOutput copyNextSampleBuffer];
    if (!fakeFrame) {
        [self.reader cancelReading];
        self.reader = nil;
        self.trackOutput = nil;
        self.initState = [self setupReader] ? 1 : 2;
        fakeFrame = (self.trackOutput ? [self.trackOutput copyNextSampleBuffer] : NULL);
    }
    if (!fakeFrame) {
        if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.realDelegate captureOutput:output
                       didOutputSampleBuffer:sampleBuffer
                              fromConnection:connection];
        }
        return;
    }

    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timing);

    CVImageBufferRef fakeIB = CMSampleBufferGetImageBuffer(fakeFrame);
    CMVideoFormatDescriptionRef desc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, fakeIB, &desc);

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateForImageBuffer(NULL, fakeIB, YES, NULL,
                                                    NULL, desc, &timing, &out);
    if (desc) CFRelease(desc);
    CFRelease(fakeFrame);

    if (s != noErr || !out) {
        if ([self.realDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
            [self.realDelegate captureOutput:output
                       didOutputSampleBuffer:sampleBuffer
                              fromConnection:connection];
        }
        return;
    }

    [self.realDelegate captureOutput:output
               didOutputSampleBuffer:out
                      fromConnection:connection];
    CFRelease(out);
}

- (void)captureOutput:(AVCaptureOutput *)output
       didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    if ([self.realDelegate respondsToSelector:_cmd]) {
        [self.realDelegate captureOutput:output
                     didDropSampleBuffer:sampleBuffer
                          fromConnection:connection];
    }
}

@end

// ============================================================
// CAMERA HOOK
// ============================================================
static const void *kVcamProxyKey = &kVcamProxyKey;

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                            queue:(dispatch_queue_t)queue
{
    if (!g_vcam_active || !vcamEnabled() || !delegate) { %orig; return; }
    NSString *video = vcamVideoPath();
    if (!video) { %orig; return; }

    VcamProxyDelegate *proxy = [VcamProxyDelegate new];
    proxy.realDelegate = delegate;
    proxy.videoPath    = video;

    objc_setAssociatedObject(self, kVcamProxyKey, proxy,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig(proxy, queue);
}

%end

// ============================================================
// SHARED PATH TABLE for JB hide — C strncmp on the hot path
// ============================================================
typedef struct { const char *p; size_t len; } vcam_prefix_t;
#define VCAM_P(s) { (s), sizeof(s) - 1 }

static const vcam_prefix_t kHiddenPrefixes[] = {
    // rootless roots (+ /private symlink alias)
    VCAM_P("/var/jb"),
    VCAM_P("/private/var/jb"),
    // rootful + install markers
    VCAM_P("/var/binpack"),
    VCAM_P("/var/LIB"),
    VCAM_P("/.installed_dopamine"),
    VCAM_P("/.installed_palera1n"),
    VCAM_P("/.bootstrapped"),
    VCAM_P("/private/preboot"),
    // package manager apps
    VCAM_P("/Applications/Cydia.app"),
    VCAM_P("/Applications/Sileo.app"),
    VCAM_P("/Applications/Zebra.app"),
    VCAM_P("/Applications/Installer.app"),
    // substrate / hook engines
    VCAM_P("/Library/MobileSubstrate"),
    VCAM_P("/usr/lib/TweakInject"),
    VCAM_P("/usr/lib/substrate"),
    VCAM_P("/usr/lib/libsubstrate.dylib"),
    VCAM_P("/usr/lib/libhooker.dylib"),
    VCAM_P("/usr/lib/libsubstitute.dylib"),
    VCAM_P("/usr/libexec/cydia"),
    // SSH
    VCAM_P("/usr/sbin/sshd"),
    VCAM_P("/usr/bin/ssh"),
    VCAM_P("/etc/ssh"),
    VCAM_P("/private/etc/ssh"),
    // apt / dpkg
    VCAM_P("/etc/apt"),
    VCAM_P("/private/etc/apt"),
    VCAM_P("/var/lib/apt"),
    VCAM_P("/var/lib/dpkg"),
    VCAM_P("/var/cache/apt"),
    VCAM_P("/usr/bin/dpkg"),
    VCAM_P("/usr/bin/apt"),
    // common JB binaries
    VCAM_P("/bin/bash"),
    VCAM_P("/bin/sh"),
};
static const size_t kHiddenPrefixCount = sizeof(kHiddenPrefixes) / sizeof(kHiddenPrefixes[0]);

static inline BOOL vcam_isHiddenPath(const char *path) {
    if (!path || path[0] != '/') return NO;
    char c = path[1];
    // Second-char gate — drops >99% of paths instantly.
    if (c != '.' && c != 'A' && c != 'L' && c != 'b' && c != 'e'
        && c != 'p' && c != 'u' && c != 'v') return NO;
    for (size_t i = 0; i < kHiddenPrefixCount; i++) {
        const vcam_prefix_t *e = &kHiddenPrefixes[i];
        if (e->p[1] != c) continue;
        if (strncmp(path, e->p, e->len) == 0) return YES;
    }
    return NO;
}

// ============================================================
// SUBSTRATE-DYLIB NAME TABLE — used by dyld/dlopen/dladdr hooks
// ============================================================
static const char *kSubstrateSubstrings[] = {
    "Substrate", "TweakInject", "ElleKit",
    "libhooker", "substitute", "pspawn_payload",
    "VcamFullMay",     // hide ourselves
    NULL
};

static inline BOOL vcam_isSubstrateLib(const char *path) {
    if (!path) return NO;
    for (const char **s = kSubstrateSubstrings; *s; s++) {
        if (strstr(path, *s)) return YES;
    }
    return NO;
}

// ============================================================
// JB HIDE — Obj-C: NSFileManager
// ============================================================
%hook NSFileManager

- (BOOL)fileExistsAtPath:(NSString *)path {
    if (!g_vcam_active) return %orig;
    const char *c = path.UTF8String;
    if (c && vcam_isHiddenPath(c)) return NO;
    return %orig;
}

- (BOOL)fileExistsAtPath:(NSString *)path isDirectory:(BOOL *)isDirectory {
    if (!g_vcam_active) return %orig;
    const char *c = path.UTF8String;
    if (c && vcam_isHiddenPath(c)) return NO;
    return %orig;
}

%end

// ============================================================
// JB HIDE — Obj-C: UIApplication canOpenURL
// ============================================================
%hook UIApplication

- (BOOL)canOpenURL:(NSURL *)url {
    if (!g_vcam_active) return %orig;
    NSString *scheme = url.scheme;
    if (scheme.length > 0) {
        static NSArray *blocked = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            blocked = @[ @"cydia", @"sileo", @"zbra", @"filza",
                         @"undecimus", @"activator", @"flex" ];
        });
        for (NSString *s in blocked) {
            if ([scheme isEqualToString:s]) return NO;
        }
    }
    return %orig;
}

%end

// ============================================================
// JB HIDE — C-level hooks (the part that defeats tier-1 anti-fraud)
// ============================================================

// --- dlopen: block substrate dylib loads ---
typedef void *(*dlopen_t)(const char *, int);
static dlopen_t orig_dlopen = NULL;
static void *vcam_dlopen(const char *path, int mode) {
    if (vcam_isSubstrateLib(path)) return NULL;
    return orig_dlopen ? orig_dlopen(path, mode) : NULL;
}

// --- stat / lstat / access / fopen: pretend JB paths don't exist ---
typedef int (*stat_t)(const char *, struct stat *);
static stat_t orig_stat = NULL;
static int vcam_stat(const char *path, struct stat *buf) {
    if (vcam_isHiddenPath(path)) { errno = ENOENT; return -1; }
    return orig_stat ? orig_stat(path, buf) : -1;
}

static stat_t orig_lstat = NULL;
static int vcam_lstat(const char *path, struct stat *buf) {
    if (vcam_isHiddenPath(path)) { errno = ENOENT; return -1; }
    return orig_lstat ? orig_lstat(path, buf) : -1;
}

typedef int (*access_t)(const char *, int);
static access_t orig_access = NULL;
static int vcam_access(const char *path, int mode) {
    if (vcam_isHiddenPath(path)) { errno = ENOENT; return -1; }
    return orig_access ? orig_access(path, mode) : -1;
}

typedef FILE *(*fopen_t)(const char *, const char *);
static fopen_t orig_fopen = NULL;
static FILE *vcam_fopen(const char *path, const char *mode) {
    if (vcam_isHiddenPath(path)) { errno = ENOENT; return NULL; }
    return orig_fopen ? orig_fopen(path, mode) : NULL;
}

// --- _dyld_image_count + _dyld_get_image_name: HIDE our dylib + substrate ---
// Critical for anti-tweak SDKs that walk dyld to find injected libraries.
// Cached count: walks are O(n) per call, but app calls _dyld_image_count
// thousands of times during navigation — without the cache we'd add seconds
// of lag.
typedef uint32_t (*dyld_count_t)(void);
typedef const char *(*dyld_name_t)(uint32_t);
static dyld_count_t orig_dyld_count = NULL;
static dyld_name_t  orig_dyld_name  = NULL;
static _Atomic int32_t s_lastRealCount   = -1;
static _Atomic int32_t s_lastHiddenCount = 0;

static uint32_t vcam_dyld_count(void) {
    uint32_t count = orig_dyld_count ? orig_dyld_count() : 0;
    int32_t prev = atomic_load_explicit(&s_lastRealCount, memory_order_relaxed);
    if ((int32_t)count != prev) {
        uint32_t hidden = 0;
        for (uint32_t i = 0; i < count; i++) {
            const char *n = orig_dyld_name ? orig_dyld_name(i) : NULL;
            if (n && vcam_isSubstrateLib(n)) hidden++;
        }
        atomic_store_explicit(&s_lastHiddenCount, (int32_t)hidden, memory_order_relaxed);
        atomic_store_explicit(&s_lastRealCount,   (int32_t)count,  memory_order_relaxed);
        return count - hidden;
    }
    int32_t cached = atomic_load_explicit(&s_lastHiddenCount, memory_order_relaxed);
    return count - (uint32_t)cached;
}

static const char *vcam_dyld_name(uint32_t i) {
    const char *n = orig_dyld_name ? orig_dyld_name(i) : NULL;
    if (n && vcam_isSubstrateLib(n)) {
        return "/System/Library/Frameworks/UIKit.framework/UIKit";
    }
    return n;
}

// --- dladdr: mask substrate symbol lookups so apps walking addresses
//            don't find our hook engine ---
typedef int (*dladdr_t)(const void *, Dl_info *);
static dladdr_t orig_dladdr = NULL;
static int vcam_dladdr(const void *addr, Dl_info *info) {
    int ret = orig_dladdr ? orig_dladdr(addr, info) : 0;
    if (ret && info && info->dli_fname && vcam_isSubstrateLib(info->dli_fname)) {
        info->dli_fname = "/System/Library/Frameworks/UIKit.framework/UIKit";
        info->dli_sname = "UIApplicationMain";
        info->dli_saddr = NULL;
    }
    return ret;
}

// ============================================================
// GPS / LOCATION SPOOF — random VN city, persistent per process
//
// KYC apps cross-check claimed-country (CMND/CCCD region) against GPS.
// If real GPS says "Hà Nội" but the ID is from HCM → flag. We need to
// match a believable VN coordinate.
//
// Strategy: pick ONE random VN city + small ~1km jitter when the tweak
// first loads in a process (dispatch_once). All subsequent location
// reads in that process return the same pinned location → not "jumping"
// across the screen frame-to-frame (would look fake immediately).
//
// Each app launch / respring re-rolls a new city → no two consecutive
// KYC attempts share the exact same coords.
//
// 30 cities span the whole length of Vietnam (Hà Giang in the far north
// down to Cà Mau in the far south) so distribution is wide.
// ============================================================
typedef struct { double lat; double lng; const char *name; } vcam_geo_t;

static const vcam_geo_t kVNCities[] = {
    { 21.0285,  105.8542, "Hà Nội"          },
    { 20.8449,  106.6881, "Hải Phòng"       },
    { 20.9601,  107.0763, "Hạ Long"         },
    { 21.5944,  105.8480, "Thái Nguyên"     },
    { 21.7167,  104.9000, "Yên Bái"         },
    { 21.1861,  106.0763, "Bắc Ninh"        },
    { 21.2731,  106.1947, "Bắc Giang"       },
    { 22.8268,  104.9784, "Hà Giang"        },
    { 19.8067,  105.7852, "Thanh Hóa"       },
    { 18.6792,  105.6817, "Vinh"            },
    { 17.4683,  106.6222, "Đồng Hới"        },
    { 16.4637,  107.5909, "Huế"             },
    { 16.0544,  108.2022, "Đà Nẵng"         },
    { 15.5793,  108.4791, "Tam Kỳ"          },
    { 15.1213,  108.8044, "Quảng Ngãi"      },
    { 13.7820,  109.2192, "Quy Nhơn"        },
    { 13.0942,  109.2960, "Tuy Hòa"         },
    { 12.2388,  109.1967, "Nha Trang"       },
    { 11.5645,  108.9889, "Phan Rang"       },
    { 13.9833,  108.0000, "Pleiku"          },
    { 12.6798,  108.0383, "Buôn Ma Thuột"   },
    { 11.9404,  108.4583, "Đà Lạt"          },
    { 10.9332,  108.0950, "Phan Thiết"      },
    { 10.7769,  106.7009, "Hồ Chí Minh"     },
    { 10.9574,  106.8426, "Biên Hòa"        },
    { 10.3460,  107.0843, "Vũng Tàu"        },
    { 10.3600,  106.3590, "Mỹ Tho"          },
    { 10.0452,  105.7469, "Cần Thơ"         },
    { 10.0125,  105.0807, "Rạch Giá"        },
    {  9.1768,  105.1524, "Cà Mau"          },
};
static const size_t kVNCityCount = sizeof(kVNCities) / sizeof(kVNCities[0]);

static CLLocationCoordinate2D g_fakeCoord    = {0, 0};
static double                 g_fakeAltitude = 0;
static const char            *g_fakeCityName = "";
static dispatch_once_t        g_fakeGeoOnce  = 0;

static void vcam_ensureFakeGeoPicked(void) {
    dispatch_once(&g_fakeGeoOnce, ^{
        // 1. Prefer user override from config.plist (companion app writes this).
        NSDictionary *cfg = vcamConfig();
        id latV = cfg[@"latitude"];
        id lngV = cfg[@"longitude"];
        if ([latV respondsToSelector:@selector(doubleValue)] &&
            [lngV respondsToSelector:@selector(doubleValue)] &&
            [latV doubleValue] != 0.0 && [lngV doubleValue] != 0.0) {
            g_fakeCoord.latitude  = [latV doubleValue];
            g_fakeCoord.longitude = [lngV doubleValue];
            id alt = cfg[@"altitude"];
            g_fakeAltitude = [alt respondsToSelector:@selector(doubleValue)] ? [alt doubleValue] : 10.0;
            return;
        }
        // 2. Random pick from VN city pool + ~1km jitter (~0.01° in lat/lng).
        uint32_t idx = arc4random_uniform((uint32_t)kVNCityCount);
        const vcam_geo_t *city = &kVNCities[idx];
        double jLat = ((double)arc4random_uniform(20000) / 1000000.0) - 0.010;
        double jLng = ((double)arc4random_uniform(20000) / 1000000.0) - 0.010;
        g_fakeCoord.latitude  = city->lat + jLat;
        g_fakeCoord.longitude = city->lng + jLng;
        g_fakeAltitude        = 5.0 + (double)arc4random_uniform(50);
        g_fakeCityName        = city->name;
    });
}

static CLLocation *vcam_makeFakeLocation(void) {
    vcam_ensureFakeGeoPicked();
    return [[CLLocation alloc]
        initWithCoordinate:g_fakeCoord
                  altitude:g_fakeAltitude
        horizontalAccuracy:5.0
          verticalAccuracy:5.0
                    course:0.0
                     speed:0.0
                 timestamp:[NSDate date]];
}

// --- CLLocationManager ---
%hook CLLocationManager

- (CLLocation *)location {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return vcam_makeFakeLocation();
}

- (void)requestLocation {
    if (!g_vcam_active || !vcamEnabled()) { %orig; return; }
    CLLocation *fake = vcam_makeFakeLocation();
    id<CLLocationManagerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [d locationManager:self didUpdateLocations:@[fake]];
        });
    }
}

- (void)startUpdatingLocation {
    if (!g_vcam_active || !vcamEnabled()) { %orig; return; }
    CLLocation *fake = vcam_makeFakeLocation();
    id<CLLocationManagerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [d locationManager:self didUpdateLocations:@[fake]];
        });
    }
}

- (void)startMonitoringSignificantLocationChanges {
    if (!g_vcam_active || !vcamEnabled()) { %orig; return; }
    CLLocation *fake = vcam_makeFakeLocation();
    id<CLLocationManagerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [d locationManager:self didUpdateLocations:@[fake]];
        });
    }
}

- (CLAuthorizationStatus)authorizationStatus {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return kCLAuthorizationStatusAuthorizedWhenInUse;
}

%end

%hook CLGeocoder

// Bypass — let the real geocoder run against our spoofed location.
// CLGeocoder calls Apple's MapKit reverse-geo backend with whatever
// CLLocation we pass. Since CLLocationManager hooks above already
// guarantee the location is our fake VN coord, the placemark returned
// by Apple WILL already be a VN city (matching whatever city we picked
// from kVNCities). No need to synthesize a fake CLPlacemark — the
// private init API isn't in the public SDK, and forwarding to %orig
// produces a real, valid CLPlacemark that passes any app's plist
// validation.
//
// Edge case: if reverseGeocodeLocation is called with a different
// CLLocation than our fake (e.g., app passes a stored old location),
// rewrite it to our fake coord before forwarding.
- (void)reverseGeocodeLocation:(CLLocation *)location
              completionHandler:(CLGeocodeCompletionHandler)completionHandler {
    if (!vcamEnabled() || !location) { %orig; return; }
    CLLocation *spoofed = vcam_makeFakeLocation();
    %orig(spoofed, completionHandler);
}

%end

// ============================================================
// LOCALE / TIMEZONE SPOOF — keep VN consistency
//
// If GPS says VN but device locale = en_US + timezone = America/* →
// KYC anti-fraud flags inconsistency. Lock everything to VN canonical.
// ============================================================
%hook NSLocale

- (NSString *)countryCode {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return @"VN";
}

- (NSString *)languageCode {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return @"vi";
}

- (NSString *)currencyCode {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return @"VND";
}

- (NSString *)localeIdentifier {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return @"vi_VN";
}

%end

%hook NSTimeZone

- (NSString *)name {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return @"Asia/Ho_Chi_Minh";
}

- (NSString *)abbreviation {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return @"ICT";
}

- (NSInteger)secondsFromGMT {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return 7 * 3600;  // UTC+7
}

%end

// ============================================================
// CARRIER SPOOF — VN mobile operator
//
// Random pick across resets so multiple accs don't all claim Viettel.
// ============================================================
typedef struct { const char *name; const char *mcc; const char *mnc; } vcam_carrier_t;
static const vcam_carrier_t kVNCarriers[] = {
    { "Viettel",      "452", "04" },
    { "MobiFone",     "452", "01" },
    { "Vinaphone",    "452", "02" },
    { "Vinaphone",    "452", "03" },
    { "Vietnamobile", "452", "05" },
    { "Gmobile",      "452", "07" },
};
static const size_t kVNCarrierCount = sizeof(kVNCarriers) / sizeof(kVNCarriers[0]);

static const vcam_carrier_t *g_fakeCarrier = NULL;
static dispatch_once_t       g_fakeCarrierOnce = 0;

static void vcam_ensureFakeCarrierPicked(void) {
    dispatch_once(&g_fakeCarrierOnce, ^{
        g_fakeCarrier = &kVNCarriers[arc4random_uniform((uint32_t)kVNCarrierCount)];
    });
}

%hook CTCarrier

- (NSString *)carrierName {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    vcam_ensureFakeCarrierPicked();
    return [NSString stringWithUTF8String:g_fakeCarrier->name];
}

- (NSString *)mobileCountryCode {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    vcam_ensureFakeCarrierPicked();
    return [NSString stringWithUTF8String:g_fakeCarrier->mcc];
}

- (NSString *)mobileNetworkCode {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    vcam_ensureFakeCarrierPicked();
    return [NSString stringWithUTF8String:g_fakeCarrier->mnc];
}

- (NSString *)isoCountryCode {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return @"vn";
}

- (BOOL)allowsVOIP {
    if (!g_vcam_active || !vcamEnabled()) return %orig;
    return YES;
}

%end

// ============================================================
// CTOR — install all C-level hooks
// ============================================================
// Defense-in-depth: even with a correct filter, if the dylib ever ends up
// injected into a shell or system tool (misconfigured plist, future ellekit
// edge case), our libc hooks can break PAM/auth and lock SSH out — which
// already happened once in dev. Bail out *before* installing any hook if
// the host process is a known shell/tool.
static int vcam_unsafe_host(void) {
    char buf[256] = {0};
    uint32_t sz = sizeof(buf);
    extern int _NSGetExecutablePath(char *buf, uint32_t *bufsize);
    if (_NSGetExecutablePath(buf, &sz) != 0) return 0;
    const char *slash = strrchr(buf, '/');
    const char *exe = slash ? slash + 1 : buf;
    static const char *kBlocked[] = {
        "sh", "bash", "zsh", "dash", "ksh", "fish",
        "sshd", "sftp-server", "ssh", "scp",
        "sudo", "su", "doas",
        "ps", "ls", "cat", "cp", "mv", "rm", "ln", "mkdir", "rmdir",
        "echo", "grep", "find", "head", "tail", "sed", "awk", "tr",
        "tar", "gzip", "xz", "dpkg", "dpkg-deb", "apt", "apt-get",
        "killall", "kill", "pkill",
        "jbctl", "uicache", "uiopen", "opainject", "ldid",
        "launchctl", "open", NULL
    };
    for (int i = 0; kBlocked[i]; i++) {
        if (strcmp(exe, kBlocked[i]) == 0) return 1;
    }
    return 0;
}

// Allowlist: only install hooks if running inside one of our target apps.
// The substrate filter (com.apple.UIKit) loads us into every UIKit process —
// SpringBoard, Sileo, Settings, etc. Without this allowlist those apps would
// get our anti-detection hooks for free, slowing them down and risking
// stat/fopen returning ENOENT for /var/jb paths the app legitimately needs.
//
// Reason: ellekit's `Filter > Bundles` only matches loaded *framework* bundle
// IDs, not the app's own CFBundleIdentifier — so we can't narrow at the
// filter level. Allowlist-in-%ctor is the standard pattern (see Choicy).
static int vcam_target_app(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid || bid.length == 0) return 0;
    static NSSet *targets = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        targets = [NSSet setWithArray:@[
            // Messaging / video call
            @"com.vng.zalo", @"com.zing.zalo", @"vn.com.vng.zingalo",
            @"com.facebook.Facebook", @"com.facebook.Messenger",
            @"net.whatsapp.WhatsApp",
            @"com.tencent.mm", @"com.netease.mm",
            @"com.viber",
            @"com.skype.skype", @"com.skype.SkypeForiPad",
            @"ph.telegra.Telegraph",
            @"com.hammerandchisel.discord",
            @"jp.naver.line",
            @"com.kakao.talk",
            // Social / video upload
            @"com.burbn.instagram",
            @"com.zhiliaoapp.musically",
            @"com.ss.iphone.ugc.Aweme",
            @"com.toyopagroup.picaboo",
            @"com.google.ios.youtube",
            @"com.atebits.Tweetie2",
            // Productivity / browser using camera
            @"com.microsoft.Office.Outlook",
            @"com.google.chrome.ios",
            // Banking / e-KYC
            @"com.tpbank.ebank",
            @"com.acb.acbmobileapp",
            @"com.VPBank.VPBankNeo",
        ]];
    });
    return [targets containsObject:bid] ? 1 : 0;
}

%ctor {
    if (vcam_unsafe_host()) return;   // skip injection into shells / tools
    if (!vcam_target_app()) return;   // skip non-target apps (SpringBoard etc.)

    // Activate hooks. Every %hook method gates on this flag — without it
    // the hooks would still fire in any UIKit-loading process (Sileo,
    // SpringBoard, system daemons) because logos installs +load swizzles
    // unconditionally. See g_vcam_active comment block at top.
    g_vcam_active = 1;

    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSLog(@"[VcamFullMay] loading in %@", bid);

        // Drop a marker file so we can SSH-verify the dylib actually
        // loaded into this bundle. Filename = bundle id so multiple apps
        // each leave their own marker. Useful when "tweak doesn't seem
        // to work" — if no marker for the target bundle → dylib never
        // got injected (filter plist / cache issue).
        @try {
            NSString *safeBid = [bid stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            NSString *markerDir = @"/var/jb/etc/vcam";
            NSString *marker    = [NSString stringWithFormat:@"%@/loaded_%@.txt",
                                   markerDir, safeBid];
            NSString *content   = [NSString stringWithFormat:@"loaded %@\npid %d\nat %@\n",
                                   bid, getpid(), [NSDate date]];
            [content writeToFile:marker atomically:YES
                        encoding:NSUTF8StringEncoding error:nil];
        } @catch (...) {}

        // Resolve via dlsym from the global handle. Easier than typing the
        // dylib path for every libsystem function.
        void *RTLD = RTLD_DEFAULT;

        #define VCAM_INSTALL(sym, repl, origp) do {                       \
            void *_s = dlsym(RTLD, #sym);                                 \
            if (_s && !*((void **)(origp))) {                             \
                MSHookFunction(_s, (void *)(repl), (void **)(origp));     \
                NSLog(@"[VcamFullMay] hooked " #sym);                     \
            }                                                             \
        } while (0)

        VCAM_INSTALL(dlopen,                 vcam_dlopen,     &orig_dlopen);
        VCAM_INSTALL(stat,                   vcam_stat,       &orig_stat);
        VCAM_INSTALL(lstat,                  vcam_lstat,      &orig_lstat);
        VCAM_INSTALL(access,                 vcam_access,     &orig_access);
        VCAM_INSTALL(fopen,                  vcam_fopen,      &orig_fopen);
        VCAM_INSTALL(_dyld_image_count,      vcam_dyld_count, &orig_dyld_count);
        VCAM_INSTALL(_dyld_get_image_name,   vcam_dyld_name,  &orig_dyld_name);
        VCAM_INSTALL(dladdr,                 vcam_dladdr,     &orig_dladdr);

        #undef VCAM_INSTALL

        NSLog(@"[VcamFullMay] init complete");
    }
}
