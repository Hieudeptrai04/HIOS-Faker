// ChangeInfoIosLocation — minimal GPS spoof sidecar for Apple system
// apps that the main tweak's broader %hook surface would crash.
//
// v2.5.29 — REWORKED to address two issues from v2.5.28:
// (1) Weather crashed with EXC_BREAKPOINT in `_dispatch_assert_queue_fail`
//     because we dispatched the synthetic delegate callback on
//     dispatch_get_main_queue() while Swift+SwiftUI's CLLocationManager
//     delegate has `dispatchPrecondition(.onQueue(...))` against the
//     framework's internal queue. Removed all synthetic dispatch_after
//     calls — they were the regression.
// (2) Maps showed real location because Maps doesn't call `.location`;
//     it subscribes to delegate updates from locationd directly.
//     New approach: when `setDelegate:` lands, runtime-swizzle the
//     delegate class's `locationManager:didUpdateLocations:` to REPLACE
//     the incoming locations array with our fake location. The swizzle
//     fires on the framework's own queue — no precondition violation.
//
// Net: hooks are STILL minimal (no UI / network / FS); apps see fake
// coordinates via the natural delegate channel, no synthetic delivery.

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---------- diagnostic marker (per-sandbox tmp) ----------
static void ci_locMark(const char *tag) {
    @autoreleasepool {
        NSString *dir = NSTemporaryDirectory();
        if (!dir.length) return;
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        NSString *path = [dir stringByAppendingFormat:@"/ci_loc_%s.txt", tag];
        NSString *stamp = [NSString stringWithFormat:@"%@ bid=%@\n", [NSDate date], bid];
        FILE *f = fopen([path UTF8String], "a");
        if (f) { fputs([stamp UTF8String], f); fclose(f); }
    }
}

// ---------- shared config plist ----------
static NSDictionary *g_locConfig = nil;
static NSTimeInterval g_locConfigLoadTime = 0;

static NSDictionary *ci_loadLocConfig(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (g_locConfig && (now - g_locConfigLoadTime) < 5.0) return g_locConfig;
    @autoreleasepool {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                            @"/var/jb/etc/changeinfoios/config.plist"];
        if (d) { g_locConfig = d; g_locConfigLoadTime = now; }
    }
    return g_locConfig;
}

static id ci_locConfigVal(NSString *key) {
    NSDictionary *d = ci_loadLocConfig();
    return d ? d[key] : nil;
}

static BOOL ci_locEnabled(void) {
    id v = ci_locConfigVal(@"locationEnabled");
    return ([v isKindOfClass:[NSNumber class]]) ? [v boolValue] : NO;
}

// ---------- fake CLLocation builder ----------
static CLLocation *ci_buildFakeLocation(void) {
    id lat = ci_locConfigVal(@"latitude");
    id lng = ci_locConfigVal(@"longitude");
    if (!lat || !lng) return nil;

    CLLocationCoordinate2D coord;
    coord.latitude  = [lat doubleValue];
    coord.longitude = [lng doubleValue];
    double jitterLat = ((double)arc4random_uniform(100) - 50.0) / 1000000.0;
    double jitterLng = ((double)arc4random_uniform(100) - 50.0) / 1000000.0;
    coord.latitude  += jitterLat;
    coord.longitude += jitterLng;

    id alt  = ci_locConfigVal(@"altitude");
    id acc  = ci_locConfigVal(@"locationAccuracy");
    id spdV = ci_locConfigVal(@"locationSpeed");
    id crsV = ci_locConfigVal(@"locationCourse");
    double altitude = alt  ? [alt  doubleValue]  : 15.0;
    double hAcc     = acc  ? [acc  doubleValue]  : (5.0 + arc4random_uniform(30));
    double speed    = spdV ? [spdV doubleValue]  : 0.0;
    double course   = crsV ? [crsV doubleValue]  : (double)arc4random_uniform(360);

    return [[CLLocation alloc]
            initWithCoordinate:coord
            altitude:altitude
            horizontalAccuracy:hAcc
            verticalAccuracy:hAcc * 1.5
            course:course
            speed:speed
            timestamp:[NSDate date]];
}

// ============================================================
// Delegate-method swizzle. Replaces the locations array in-flight
// on the framework's own queue — no precondition violation.
// ============================================================
static NSMutableSet *g_swizzledClasses = nil;   // delegate Class objects already swizzled
static dispatch_once_t g_swizzledOnce;
static const void *kOrigImplKey = &kOrigImplKey;

static void ci_locDelegateUpdates(id delegateSelf, SEL _cmd,
                                    CLLocationManager *mgr,
                                    NSArray<CLLocation *> *locations) {
    NSArray<CLLocation *> *forward = locations;
    if (ci_locEnabled()) {
        CLLocation *fake = ci_buildFakeLocation();
        if (fake) {
            forward = @[fake];
            ci_locMark("delegate_updates_swapped");
        }
    }
    Class cls = object_getClass(delegateSelf);
    NSValue *boxed = objc_getAssociatedObject(cls, kOrigImplKey);
    void (*orig)(id, SEL, CLLocationManager *, NSArray *) =
        (void (*)(id, SEL, CLLocationManager *, NSArray *))[boxed pointerValue];
    if (orig) orig(delegateSelf, _cmd, mgr, forward);
}

static void ci_swizzleDelegateIfNeeded(id delegate) {
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    if (!cls) return;
    dispatch_once(&g_swizzledOnce, ^{ g_swizzledClasses = [NSMutableSet new]; });
    @synchronized (g_swizzledClasses) {
        if ([g_swizzledClasses containsObject:NSStringFromClass(cls)]) return;
        SEL sel = @selector(locationManager:didUpdateLocations:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;  // delegate doesn't implement the optional method
        IMP origIMP = method_getImplementation(m);
        if (!origIMP) return;
        NSValue *boxed = [NSValue valueWithPointer:(const void *)origIMP];
        objc_setAssociatedObject(cls, kOrigImplKey, boxed, OBJC_ASSOCIATION_RETAIN);
        method_setImplementation(m, (IMP)ci_locDelegateUpdates);
        [g_swizzledClasses addObject:NSStringFromClass(cls)];
        ci_locMark("delegate_class_swizzled");
    }
}

// ============================================================
// CLLocationManager hooks — READ-ONLY, no synthetic delegate dispatch.
// ============================================================
%hook CLLocationManager

- (CLLocation *)location {
    if (!ci_locEnabled()) return %orig;
    CLLocation *fake = ci_buildFakeLocation();
    if (fake) {
        ci_locMark("location_get_fake");
        return fake;
    }
    return %orig;
}

// Trigger delegate-class swizzle the moment the host app sets a delegate.
- (void)setDelegate:(id<CLLocationManagerDelegate>)delegate {
    %orig;
    if (ci_locEnabled() && delegate) {
        ci_swizzleDelegateIfNeeded(delegate);
    }
}

- (CLAuthorizationStatus)authorizationStatus {
    if (!ci_locEnabled()) return %orig;
    ci_locMark("authstatus_authorized");
    return kCLAuthorizationStatusAuthorizedWhenInUse;
}

%end

%hook CLLocationManager
+ (BOOL)locationServicesEnabled {
    if (!ci_locEnabled()) return %orig;
    return YES;
}
%end

%hook CLGeocoder

- (void)reverseGeocodeLocation:(CLLocation *)location
             completionHandler:(void (^)(NSArray *placemarks, NSError *error))completionHandler {
    if (!ci_locEnabled()) { %orig; return; }
    CLLocation *fake = ci_buildFakeLocation();
    if (fake) {
        ci_locMark("reverse_geocode_fake");
        %orig(fake, completionHandler);
    } else {
        %orig;
    }
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        ci_locMark("ctor_entered");
        NSLog(@"[ChangeInfoIosLocation] v2.5.29 loaded in %@", bid);
    }
}
