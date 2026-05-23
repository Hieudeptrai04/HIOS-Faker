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
#import <MapKit/MapKit.h>
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
static NSMutableSet *g_swizzledClasses = nil;   // delegate Class objects already swizzled (didUpdateLocations:)
static NSMutableSet *g_swizzledClasses2 = nil;  // ... for didUpdateToLocation:fromLocation:
static dispatch_once_t g_swizzledOnce;
static const void *kOrigImplKey  = &kOrigImplKey;
static const void *kOrigImplKey2 = &kOrigImplKey2;

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

// Deprecated single-location delegate (pre-iOS 6 but some apps still use it).
static void ci_locDelegateUpdateTo(id delegateSelf, SEL _cmd,
                                     CLLocationManager *mgr,
                                     CLLocation *newLoc,
                                     CLLocation *oldLoc) {
    CLLocation *forward = newLoc;
    if (ci_locEnabled()) {
        CLLocation *fake = ci_buildFakeLocation();
        if (fake) { forward = fake; ci_locMark("delegate_updateTo_swapped"); }
    }
    Class cls = object_getClass(delegateSelf);
    NSValue *boxed = objc_getAssociatedObject(cls, kOrigImplKey2);
    void (*orig)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *) =
        (void (*)(id, SEL, CLLocationManager *, CLLocation *, CLLocation *))[boxed pointerValue];
    if (orig) orig(delegateSelf, _cmd, mgr, forward, oldLoc);
}

static void ci_swizzleDelegateClassIfNeeded(Class cls) {
    if (!cls) return;
    dispatch_once(&g_swizzledOnce, ^{
        g_swizzledClasses  = [NSMutableSet new];
        g_swizzledClasses2 = [NSMutableSet new];
    });
    NSString *clsName = NSStringFromClass(cls);
    if (!clsName.length) return;

    // Modern signature
    @synchronized (g_swizzledClasses) {
        if (![g_swizzledClasses containsObject:clsName]) {
            SEL sel = @selector(locationManager:didUpdateLocations:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                IMP curIMP = method_getImplementation(m);
                if (curIMP && curIMP != (IMP)ci_locDelegateUpdates) {
                    objc_setAssociatedObject(cls, kOrigImplKey,
                        [NSValue valueWithPointer:(const void *)curIMP],
                        OBJC_ASSOCIATION_RETAIN);
                    method_setImplementation(m, (IMP)ci_locDelegateUpdates);
                    [g_swizzledClasses addObject:clsName];
                    ci_locMark("delegate_class_swizzled");
                }
            }
        }
    }
    // Deprecated single-location signature
    @synchronized (g_swizzledClasses2) {
        if (![g_swizzledClasses2 containsObject:clsName]) {
            SEL sel = @selector(locationManager:didUpdateToLocation:fromLocation:);
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                IMP curIMP = method_getImplementation(m);
                if (curIMP && curIMP != (IMP)ci_locDelegateUpdateTo) {
                    objc_setAssociatedObject(cls, kOrigImplKey2,
                        [NSValue valueWithPointer:(const void *)curIMP],
                        OBJC_ASSOCIATION_RETAIN);
                    method_setImplementation(m, (IMP)ci_locDelegateUpdateTo);
                    [g_swizzledClasses2 addObject:clsName];
                    ci_locMark("delegate_class2_swizzled");
                }
            }
        }
    }
}

static void ci_swizzleDelegateIfNeeded(id delegate) {
    if (!delegate) return;
    ci_swizzleDelegateClassIfNeeded(object_getClass(delegate));
}

// At ctor time, scan EVERY class in the process and swizzle any that
// implement -locationManager:didUpdateLocations:. This catches delegates
// that were set before our setDelegate: hook installed (apps that build
// the CLLocationManager from a static initializer or +load method).
static void ci_swizzleAllExistingDelegates(void) {
    SEL sel1 = @selector(locationManager:didUpdateLocations:);
    SEL sel2 = @selector(locationManager:didUpdateToLocation:fromLocation:);
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    if (!classes) return;
    NSUInteger swizzled = 0;
    for (unsigned int i = 0; i < classCount; i++) {
        Class cls = classes[i];
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        BOOL has1 = NO, has2 = NO;
        if (methods) {
            for (unsigned int j = 0; j < methodCount; j++) {
                SEL s = method_getName(methods[j]);
                if (s == sel1) has1 = YES;
                if (s == sel2) has2 = YES;
            }
            free(methods);
        }
        if (has1 || has2) {
            ci_swizzleDelegateClassIfNeeded(cls);
            swizzled++;
        }
    }
    free(classes);
    if (swizzled > 0) ci_locMark("scan_swizzled_some");
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

// ============================================================
// v2.5.32: MapKit MKMapView + MKUserLocation hooks. Apple Maps and
// any app embedding MKMapView display the user's position via
// MKUserLocation, which has its own internal CLLocationManager
// subscription that runs AFTER our setDelegate: hook installed but
// BEFORE our delegate sweep covers its delegate class. Hook the
// MKUserLocation getters directly so the blue dot shows our fake
// coordinate regardless of how MKMapView fetches its location.
// ============================================================
%hook MKUserLocation

- (CLLocation *)location {
    if (!ci_locEnabled()) return %orig;
    CLLocation *fake = ci_buildFakeLocation();
    if (fake) { ci_locMark("mkuserloc_location_fake"); return fake; }
    return %orig;
}

- (CLLocationCoordinate2D)coordinate {
    if (!ci_locEnabled()) return %orig;
    CLLocation *fake = ci_buildFakeLocation();
    if (fake) { ci_locMark("mkuserloc_coord_fake"); return fake.coordinate; }
    return %orig;
}

%end

%hook MKMapView

- (MKUserLocation *)userLocation {
    MKUserLocation *real = %orig;
    if (ci_locEnabled() && real) {
        CLLocation *fake = ci_buildFakeLocation();
        if (fake) {
            // Try KVC update so MKMapView's internal observers see the change.
            // MKUserLocation.location is publicly readonly but internally KVC-writable.
            @try {
                [real setValue:fake forKey:@"location"];
                ci_locMark("mkmapview_userloc_kvc_set");
            } @catch (NSException *e) {
                // Fall back to just letting the MKUserLocation getter hook above
                // intercept the next read.
                ci_locMark("mkmapview_userloc_kvc_fail");
            }
        }
    }
    return real;
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"?";
        ci_locMark("ctor_entered");
        // Sweep all already-loaded classes for delegates that registered
        // before our setDelegate: hook was installed.
        ci_swizzleAllExistingDelegates();
        // Re-sweep after a short delay so delegates created during the
        // app's UIScene lifecycle (which runs AFTER %ctor) also get caught.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ci_swizzleAllExistingDelegates();
            ci_locMark("ctor_delayed_sweep_done");
        });
        NSLog(@"[ChangeInfoIosLocation] v2.5.30 loaded in %@", bid);
    }
}
