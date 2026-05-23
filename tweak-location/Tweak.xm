// ChangeInfoIosLocation — minimal GPS spoof sidecar for Apple system
// apps that the main tweak's broader %hook surface would crash:
//   Maps, Weather, Camera, Photos, Spotlight, FindMy, Compass.
//
// Hooks ONLY CLLocationManager + CLGeocoder (read-only, narrow API surface),
// reads from the SAME shared config (/var/jb/etc/changeinfoios/config.plist)
// as the main tweak — same coord/altitude/speed/course keys.
//
// Philosophy (same as Safari sidecar): keep hook surface tiny so the
// process model of the host system app doesn't get destabilised. We do
// NOT hook the UI, file system, network, or any non-location framework.

#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

// Marker writer — per-sandbox tmp dir so we can confirm injection.
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

// Shared config plist read — same path the main tweak uses.
static NSDictionary *g_locConfig = nil;
static NSTimeInterval g_locConfigLoadTime = 0;

static NSDictionary *ci_loadLocConfig(void) {
    // Reload at most once per 5s so VPN-sync coord changes propagate
    // without restarting the host app.
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (g_locConfig && (now - g_locConfigLoadTime) < 5.0) return g_locConfig;
    @autoreleasepool {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                            @"/var/jb/etc/changeinfoios/config.plist"];
        if (d) {
            g_locConfig = d;
            g_locConfigLoadTime = now;
        }
    }
    return g_locConfig;
}

static id ci_locConfigVal(NSString *key) {
    NSDictionary *d = ci_loadLocConfig();
    return d ? d[key] : nil;
}

static BOOL ci_locEnabled(void) {
    id v = ci_locConfigVal(@"locationEnabled");
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    return NO;
}

// Build fake CLLocation from config (matches main tweak's buildFakeLocation).
static CLLocation *ci_buildFakeLocation(void) {
    id lat = ci_locConfigVal(@"latitude");
    id lng = ci_locConfigVal(@"longitude");
    if (!lat || !lng) return nil;

    CLLocationCoordinate2D coord;
    coord.latitude  = [lat doubleValue];
    coord.longitude = [lng doubleValue];

    // Mini-jitter (~5 cm) per read — mimics noisy GPS sensor.
    double jitterLat = ((double)arc4random_uniform(100) - 50.0) / 1000000.0;
    double jitterLng = ((double)arc4random_uniform(100) - 50.0) / 1000000.0;
    coord.latitude  += jitterLat;
    coord.longitude += jitterLng;

    id alt    = ci_locConfigVal(@"altitude");
    id acc    = ci_locConfigVal(@"locationAccuracy");
    id spdV   = ci_locConfigVal(@"locationSpeed");
    id crsV   = ci_locConfigVal(@"locationCourse");
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

- (void)startUpdatingLocation {
    %orig;
    if (!ci_locEnabled() || !self.delegate) return;
    CLLocation *fake = ci_buildFakeLocation();
    if (!fake) return;
    if (![self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) return;
    ci_locMark("start_update_fake");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && [s.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [s.delegate locationManager:s didUpdateLocations:@[fake]];
        }
    });
}

- (void)startMonitoringSignificantLocationChanges {
    %orig;
    if (!ci_locEnabled() || !self.delegate) return;
    CLLocation *fake = ci_buildFakeLocation();
    if (!fake) return;
    if (![self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) return;
    ci_locMark("start_sig_fake");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && [s.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [s.delegate locationManager:s didUpdateLocations:@[fake]];
        }
    });
}

- (void)requestLocation {
    if (!ci_locEnabled() || !self.delegate) { %orig; return; }
    CLLocation *fake = ci_buildFakeLocation();
    if (!fake) { %orig; return; }
    if (![self.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        %orig; return;
    }
    ci_locMark("request_loc_fake");
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (s && [s.delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [s.delegate locationManager:s didUpdateLocations:@[fake]];
        }
    });
}

// Authorization: report authorized-when-in-use so the calling app doesn't
// degrade to "Location not available" UI even when our coords are returned.
- (CLAuthorizationStatus)authorizationStatus {
    if (!ci_locEnabled()) return %orig;
    ci_locMark("authstatus_authorized");
    return kCLAuthorizationStatusAuthorizedWhenInUse;
}

%end

%hook CLLocationManager  // class-method hooks separated to silence the deprecated-class-method warning that may treat as error
+ (BOOL)locationServicesEnabled {
    if (!ci_locEnabled()) return %orig;
    return YES;
}
%end

%hook CLGeocoder

// Reverse geocode → feed the fake coordinate so Maps/Weather show the
// city/country of the spoofed location, not the real GPS coord.
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
        NSLog(@"[ChangeInfoIosLocation] loaded in %@", bid);
    }
}
