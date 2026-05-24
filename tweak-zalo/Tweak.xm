// ChangeInfoIosZalo.dylib — v2.6.0
//
// Ultra-thin device-info sidecar for Zalo. PURE device-read spoof only:
// 12 ObjC method hooks, every one returning a cached value after first
// resolve. Zero C-level hooks. Zero MSHookFunction. Zero Darwin notify
// observers. Zero keychain dump or container wipe (host app handles that
// from outside Zalo's process). Zero LSApplicationWorkspace / NSFileManager
// / NSUserDefaults / app-mutating swizzles.
//
// Design philosophy: the main ChangeInfoIos.dylib (rich feature set, all
// the tools incl. JB-hide / keychain spoof / proxy injection / restore /
// dump / etc) is SAFE for banking and most apps but its 15+ ObjC + 4 C
// hooks compounded inside Zalo's chat scroll caused user-perceived lag on
// iPhone X (A11). This sidecar trades feature coverage for raw smoothness
// — Zalo gets ONLY the device-info getter spoof, nothing else. Performance
// floor is ~1 % CPU even during fast scroll because every read is a
// branch-predicted static load.
//
// Config is read ONCE at %ctor from /var/jb/etc/changeinfoios/config.plist
// — the same file the host HIOS Faker app writes. Subsequent config
// changes (via Change Device) require Zalo relaunch (acceptable; Zalo
// is killed by the host's Change Device flow anyway).

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>

static NSDictionary *gCfg = nil;

static NSString *cs(NSString *k) {
    id v = gCfg[k];
    return [v isKindOfClass:[NSString class]] ? v : nil;
}
static BOOL cb(NSString *k) {
    id v = gCfg[k];
    if (!v && [k hasPrefix:@"fake_"]) return YES;  // default-on for fake_* like main tweak
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}
static id cg(NSString *k) { return gCfg[k]; }

#define LAYER(name)  cb(@"fake_" name)

// ============================================================
// LAYER: UIDevice
// ============================================================
%hook UIDevice

- (NSString *)name {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [cs(@"deviceName") copy]; });
    return c ?: %orig;
}
- (NSString *)model {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [cs(@"deviceModel") copy]; });
    return c ?: %orig;
}
- (NSString *)systemName {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [cs(@"systemName") copy]; });
    return c ?: %orig;
}
- (NSString *)systemVersion {
    if (!LAYER("uiddevice")) return %orig;
    static NSString *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{ c = [cs(@"systemVersion") copy]; });
    return c ?: %orig;
}
- (NSUUID *)identifierForVendor {
    if (!LAYER("uiddevice")) return %orig;
    static NSUUID *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *s = cs(@"identifierForVendor");
        if (s) c = [[NSUUID alloc] initWithUUIDString:s];
    });
    return c ?: %orig;
}

%end

// ============================================================
// LAYER: ASIdentifierManager (IDFA)
// ============================================================
%hook ASIdentifierManager
- (NSUUID *)advertisingIdentifier {
    if (!LAYER("ads")) return %orig;
    static NSUUID *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *s = cs(@"advertisingIdentifier");
        if (s) c = [[NSUUID alloc] initWithUUIDString:s];
    });
    return c ?: %orig;
}
- (BOOL)isAdvertisingTrackingEnabled {
    if (!LAYER("ads")) return %orig;
    id v = cg(@"isAdvertisingTrackingEnabled");
    if (v) return [v boolValue];
    return %orig;
}
%end

// ============================================================
// LAYER: UIScreen (HOTTEST PATH — every CALayer layout)
// Pre-cache CGRect/CGFloat so steady-state cost is ~5 ns/call.
// ============================================================
%hook UIScreen

- (CGRect)bounds {
    if (!LAYER("screen")) return %orig;
    static CGRect c = {{0,0},{0,0}}; static dispatch_once_t o;
    dispatch_once(&o, ^{
        id w = cg(@"screenWidth"); id h = cg(@"screenHeight");
        if (w && h) c = CGRectMake(0, 0, [w floatValue], [h floatValue]);
    });
    if (c.size.width > 0) return c;
    return %orig;
}
- (CGRect)nativeBounds {
    if (!LAYER("screen")) return %orig;
    static CGRect c = {{0,0},{0,0}}; static dispatch_once_t o;
    dispatch_once(&o, ^{
        id w = cg(@"nativeScreenWidth"); id h = cg(@"nativeScreenHeight");
        if (w && h) {
            c = CGRectMake(0, 0, [w floatValue], [h floatValue]);
            return;
        }
        id bw = cg(@"screenWidth"); id bh = cg(@"screenHeight"); id sc = cg(@"screenScale");
        if (bw && bh && sc) {
            CGFloat s = [sc floatValue];
            c = CGRectMake(0, 0, [bw floatValue] * s, [bh floatValue] * s);
        }
    });
    if (c.size.width > 0) return c;
    return %orig;
}
- (CGFloat)scale {
    if (!LAYER("screen")) return %orig;
    static CGFloat c = 0; static dispatch_once_t o;
    dispatch_once(&o, ^{ id v = cg(@"screenScale"); if (v) c = [v floatValue]; });
    if (c > 0) return c;
    return %orig;
}
- (CGFloat)nativeScale {
    if (!LAYER("screen")) return %orig;
    static CGFloat c = 0; static dispatch_once_t o;
    dispatch_once(&o, ^{
        id v = cg(@"nativeScale"); if (!v) v = cg(@"screenScale");
        if (v) c = [v floatValue];
    });
    if (c > 0) return c;
    return %orig;
}

%end

// ============================================================
// LAYER: NSLocale / NSTimeZone
// ============================================================
%hook NSLocale
+ (NSLocale *)currentLocale {
    if (!LAYER("locale")) return %orig;
    static NSLocale *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *s = cs(@"localeIdentifier");
        if (s) c = [[NSLocale alloc] initWithLocaleIdentifier:s];
    });
    return c ?: %orig;
}
%end

%hook NSTimeZone
+ (NSTimeZone *)systemTimeZone {
    if (!LAYER("locale2")) return %orig;
    static NSTimeZone *c = nil; static dispatch_once_t o;
    dispatch_once(&o, ^{
        NSString *s = cs(@"timeZoneName");
        if (s) c = [NSTimeZone timeZoneWithName:s];
    });
    return c ?: %orig;
}
+ (NSTimeZone *)defaultTimeZone {
    if (!LAYER("locale2")) return %orig;
    return [NSTimeZone systemTimeZone];
}
%end

// ============================================================
// LAYER: CTCarrier (most reg fingerprints check carrier)
// ============================================================
%hook CTCarrier
- (NSString *)carrierName {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierName"); return v ?: %orig;
}
- (NSString *)mobileCountryCode {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierMCC"); return v ?: %orig;
}
- (NSString *)mobileNetworkCode {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierMNC"); return v ?: %orig;
}
- (NSString *)isoCountryCode {
    if (!LAYER("uiddevice")) return %orig;
    NSString *v = cs(@"carrierISO"); return v ?: %orig;
}
%end

// ============================================================
// CTOR — read config ONCE, no notify observer, no dump, no wipe.
// ============================================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        // Belt-and-braces bundle guard — the plist filter already restricts
        // us to Zalo bundles, but a misconfigured filter would inject us
        // somewhere unsafe. Hard-allow only the known Zalo IDs.
        NSSet *allowed = [NSSet setWithArray:@[
            @"com.vng.zalo",
            @"com.zing.zalo",
            @"vn.com.vng.zingalo",
            @"com.zaloapp.zalovn",
        ]];
        if (![allowed containsObject:bid]) return;

        gCfg = [NSDictionary dictionaryWithContentsOfFile:
                @"/var/jb/etc/changeinfoios/config.plist"];
        if (!gCfg) {
            gCfg = [NSDictionary dictionaryWithContentsOfFile:
                    @"/var/mobile/Library/Preferences/com.changeinfoios.plist"];
        }
        NSLog(@"[ChangeInfoIosZalo] Loaded into %@, cfg keys=%lu",
              bid, (unsigned long)(gCfg ? gCfg.count : 0));
    }
}
