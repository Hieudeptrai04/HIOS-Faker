#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <stdlib.h>
#import <stdio.h>
#import <sys/stat.h>
#import <spawn.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

extern char **environ;
static inline void ci_run_cmd(const char *cmd) {
    pid_t pid;
    const char *argv[] = {"/bin/sh", "-c", cmd, NULL};
    posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *const *)argv, environ);
    waitpid(pid, NULL, 0);
}

@interface CIAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@interface CIMainViewController : UIViewController <WKNavigationDelegate, WKScriptMessageHandler>
@property (strong, nonatomic) WKWebView *webView;
@end

// Private interfaces (LSApplicationWorkspace / LSApplicationProxy)
// Declared locally so compiler does not require private headers.
@interface LSApplicationProxy : NSObject
- (NSString *)localizedName;
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
- (NSString *)bundleURL;
- (NSURL *)bundleURL_typed;
- (NSString *)resourcesDirectoryURL;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (NSArray *)allInstalledApplications;
- (NSArray *)installedApplications;
- (NSArray *)allApplications;
@end

/* Ensure private framework is loaded so LSApplicationWorkspace is available. */
__attribute__((constructor))
static void ci_load_private_frameworks(void) {
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
}

/* WKWebView JSON may contain NSNull; writeToFile: fails on non-plist types. */
static id CISanitizePlistValue(id obj);
static NSDictionary *CISanitizePlistDictionary(NSDictionary *dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:dict.count];
    for (id k in dict) {
        if (![k isKindOfClass:[NSString class]]) continue;
        id v = CISanitizePlistValue(dict[k]);
        if (v != nil) out[k] = v;
    }
    return out;
}

static id CISanitizePlistValue(id obj) {
    if (obj == nil || obj == [NSNull null]) return nil;
    if ([obj isKindOfClass:[NSDictionary class]]) return CISanitizePlistDictionary(obj);
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id x in (NSArray *)obj) {
            id v = CISanitizePlistValue(x);
            if (v != nil) [a addObject:v];
        }
        return a;
    }
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]] ||
        [obj isKindOfClass:[NSDate class]] || [obj isKindOfClass:[NSData class]]) {
        return obj;
    }
    return [NSString stringWithFormat:@"%@", obj];
}

@implementation CIMainViewController

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

- (NSArray<LSApplicationProxy *> *)rawApplicationsFromWorkspace:(LSApplicationWorkspace *)workspace {
    if (!workspace) return @[];

    if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
        NSArray *all = [workspace allInstalledApplications];
        if ([all isKindOfClass:[NSArray class]] && all.count > 0) return all;
    }
    if ([workspace respondsToSelector:@selector(installedApplications)]) {
        NSArray *installed = [workspace installedApplications];
        if ([installed isKindOfClass:[NSArray class]] && installed.count > 0) return installed;
    }
    if ([workspace respondsToSelector:@selector(allApplications)]) {
        NSArray *apps = [workspace allApplications];
        if ([apps isKindOfClass:[NSArray class]] && apps.count > 0) return apps;
    }
    return @[];
}

- (NSString *)bundleIdForApplicationProxy:(LSApplicationProxy *)app {
    NSString *bid = nil;
    if ([app respondsToSelector:@selector(applicationIdentifier)]) {
        NSString *b = [app applicationIdentifier];
        if ([b isKindOfClass:[NSString class]]) bid = b;
    }
    if (bid.length < 2 && [app respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *b = [app bundleIdentifier];
        if ([b isKindOfClass:[NSString class]]) bid = b;
    }
    return bid;
}

- (NSString *)displayNameForApplicationProxy:(LSApplicationProxy *)app fallbackBundle:(NSString *)bid {
    NSString *name = bid ?: @"";
    if ([app respondsToSelector:@selector(localizedName)]) {
        NSString *n = [app localizedName];
        if ([n isKindOfClass:[NSString class]] && n.length > 0) name = n;
    }
    return name;
}

/* Try to find the app bundle path from LSApplicationProxy. */
- (NSString *)bundlePathForApplicationProxy:(LSApplicationProxy *)app {
    // Try bundleURL (returns NSURL on some iOS versions, NSString on others)
    if ([app respondsToSelector:@selector(bundleURL)]) {
        id val = [app performSelector:@selector(bundleURL)];
        if ([val isKindOfClass:[NSURL class]]) return [(NSURL *)val path];
        if ([val isKindOfClass:[NSString class]]) return val;
    }
    if ([app respondsToSelector:@selector(resourcesDirectoryURL)]) {
        id val = [app performSelector:@selector(resourcesDirectoryURL)];
        if ([val isKindOfClass:[NSURL class]]) return [(NSURL *)val path];
        if ([val isKindOfClass:[NSString class]]) return val;
    }
    return nil;
}

/* Read app icon as base64 PNG string from the .app bundle. */
- (NSString *)iconBase64ForBundlePath:(NSString *)bundlePath {
    if (!bundlePath) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    // Common icon file names in descending priority
    NSArray *iconNames = @[
        @"AppIcon60x60@2x.png", @"AppIcon60x60@3x.png",
        @"AppIcon76x76@2x.png", @"AppIcon40x40@2x.png",
        @"Icon-60@2x.png", @"Icon-60@3x.png",
        @"icon@2x.png", @"Icon@2x.png",
        @"icon.png", @"Icon.png",
    ];
    // 1) Check Info.plist for declared icon files
    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (info) {
        NSMutableArray *candidates = [NSMutableArray array];
        // CFBundleIcons > CFBundlePrimaryIcon > CFBundleIconFiles
        NSDictionary *icons = info[@"CFBundleIcons"];
        if ([icons isKindOfClass:[NSDictionary class]]) {
            NSDictionary *primary = icons[@"CFBundlePrimaryIcon"];
            if ([primary isKindOfClass:[NSDictionary class]]) {
                NSArray *files = primary[@"CFBundleIconFiles"];
                if ([files isKindOfClass:[NSArray class]]) {
                    for (NSString *f in files) {
                        if ([f isKindOfClass:[NSString class]]) [candidates addObject:f];
                    }
                }
            }
        }
        // Legacy CFBundleIconFiles
        NSArray *legacyIcons = info[@"CFBundleIconFiles"];
        if ([legacyIcons isKindOfClass:[NSArray class]]) {
            for (NSString *f in legacyIcons) {
                if ([f isKindOfClass:[NSString class]]) [candidates addObject:f];
            }
        }
        // Try each candidate with @2x/@3x suffixes
        for (NSString *base in candidates) {
            NSArray *suffixes = @[@"@2x.png", @"@3x.png", @".png", @"@2x~iphone.png", @"@3x~iphone.png"];
            for (NSString *suffix in suffixes) {
                NSString *tryName = base;
                if (![tryName hasSuffix:@".png"]) tryName = [tryName stringByAppendingString:suffix];
                NSString *full = [bundlePath stringByAppendingPathComponent:tryName];
                if ([fm fileExistsAtPath:full]) {
                    NSData *data = [NSData dataWithContentsOfFile:full];
                    if (data.length > 0 && data.length < 500000) {
                        return [data base64EncodedStringWithOptions:0];
                    }
                }
                if ([tryName hasSuffix:@".png"]) break; // already had extension
            }
        }
    }
    // 2) Fallback: try common file names
    for (NSString *name in iconNames) {
        NSString *full = [bundlePath stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:full]) {
            NSData *data = [NSData dataWithContentsOfFile:full];
            if (data.length > 0 && data.length < 500000) {
                return [data base64EncodedStringWithOptions:0];
            }
        }
    }
    return nil;
}

/* Fallback for iOS builds where LSApplicationWorkspace is restricted. */
- (NSArray<NSDictionary *> *)scanApplicationsFromFilesystem {
    NSArray<NSString *> *roots = @[
        @"/var/containers/Bundle/Application",
        @"/private/var/containers/Bundle/Application",
        @"/Applications",
        @"/var/jb/Applications"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
    NSMutableArray *rows = [NSMutableArray array];

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
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (![info isKindOfClass:[NSDictionary class]]) continue;

            NSString *bid = info[@"CFBundleIdentifier"];
            if (![bid isKindOfClass:[NSString class]] || bid.length < 4) continue;
            if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.mobilesafari"]) continue;
            if ([seen containsObject:bid]) continue;
            [seen addObject:bid];

            NSString *name = info[@"CFBundleDisplayName"];
            if (![name isKindOfClass:[NSString class]] || name.length == 0) name = info[@"CFBundleName"];
            if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bid;
            NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{@"bundleId": bid, @"name": name}];
            NSString *icon = [self iconBase64ForBundlePath:appPath];
            if (icon) row[@"icon"] = icon;
            [rows addObject:row];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    return rows;
}

/* ────────────────────────────────────────────────────────────────────────
   FASTEST SCAN: LastLaunchServicesMap.plist
   This single plist file is maintained by installd and contains every
   registered bundle-id → bundle-path mapping on the device.
   Works on ALL jailbreaks (rootful + rootless).
   ──────────────────────────────────────────────────────────────────────── */
- (NSArray<NSDictionary *> *)scanApplicationsFromLaunchServicesMap {
    NSArray *candidates = @[
        @"/var/installd/Library/MobileInstallation/LastLaunchServicesMap.plist",
        @"/private/var/installd/Library/MobileInstallation/LastLaunchServicesMap.plist",
        @"/var/MobileInstallation/LastLaunchServicesMap.plist",
    ];
    NSDictionary *map = nil;
    for (NSString *path in candidates) {
        map = [NSDictionary dictionaryWithContentsOfFile:path];
        if ([map isKindOfClass:[NSDictionary class]] && map.count > 0) {
            NSLog(@"[ChangeInfoIos] LaunchServicesMap loaded from %@ (%lu entries)", path, (unsigned long)map.count);
            break;
        }
    }
    if (!map) {
        NSLog(@"[ChangeInfoIos] LaunchServicesMap not found at any known path");
        return @[];
    }

    NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
    NSMutableArray *rows = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    /* The map has top-level keys like "User", "System", "Internal" etc.
       Each value is a dict of bundleId → metadata dict. */
    for (NSString *category in map) {
        id section = map[category];
        if (![section isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *appsDict = (NSDictionary *)section;

        for (NSString *bid in appsDict) {
            if (![bid isKindOfClass:[NSString class]] || bid.length < 4) continue;
            if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.mobilesafari"]) continue;
            if ([seen containsObject:bid]) continue;
            [seen addObject:bid];

            id entry = appsDict[bid];
            NSString *bundlePath = nil;
            if ([entry isKindOfClass:[NSDictionary class]]) {
                /* entry may have "Path", "BundleContainer", or just be a path string */
                bundlePath = entry[@"Path"];
                if (!bundlePath) bundlePath = entry[@"BundleContainer"];
                if ([bundlePath isKindOfClass:[NSString class]] && bundlePath.length > 0) {
                    /* BundleContainer points to the UUID dir; append the .app */
                    if (![bundlePath hasSuffix:@".app"]) {
                        NSArray *contents = [fm contentsOfDirectoryAtPath:bundlePath error:nil];
                        for (NSString *item in contents) {
                            if ([item.pathExtension.lowercaseString isEqualToString:@"app"]) {
                                bundlePath = [bundlePath stringByAppendingPathComponent:item];
                                break;
                            }
                        }
                    }
                } else {
                    bundlePath = nil;
                }
            } else if ([entry isKindOfClass:[NSString class]]) {
                bundlePath = (NSString *)entry;
            }

            /* Read name from bundle's Info.plist */
            NSString *name = bid;
            if (bundlePath) {
                NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                if ([info isKindOfClass:[NSDictionary class]]) {
                    NSString *dn = info[@"CFBundleDisplayName"];
                    if (![dn isKindOfClass:[NSString class]] || dn.length == 0) dn = info[@"CFBundleName"];
                    if ([dn isKindOfClass:[NSString class]] && dn.length > 0) name = dn;
                }
            }

            NSMutableDictionary *row = [NSMutableDictionary dictionaryWithDictionary:@{@"bundleId": bid, @"name": name}];
            NSString *icon = [self iconBase64ForBundlePath:bundlePath];
            if (icon) row[@"icon"] = icon;
            [rows addObject:row];
        }
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
    }];
    NSLog(@"[ChangeInfoIos] LaunchServicesMap produced %lu user apps", (unsigned long)rows.count);
    return rows;
}

/* Scan data containers for bundle IDs via metadata plists. */
- (NSArray<NSDictionary *> *)scanApplicationsFromDataContainers {
    NSArray *roots = @[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
    NSMutableArray *rows = [NSMutableArray array];

    for (NSString *root in roots) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) continue;
        NSArray *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
        for (NSString *uuid in uuids) {
            NSString *metaPath = [[root stringByAppendingPathComponent:uuid]
                                    stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
            if (![meta isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = meta[@"MCMMetadataIdentifier"];
            if (![bid isKindOfClass:[NSString class]] || bid.length < 4) continue;
            if ([bid hasPrefix:@"com.apple."]) continue;
            if ([seen containsObject:bid]) continue;
            [seen addObject:bid];
            [rows addObject:@{@"bundleId": bid, @"name": bid}];
        }
    }
    NSLog(@"[ChangeInfoIos] DataContainer scan found %lu apps", (unsigned long)rows.count);
    return rows;
}

/* ────────────────────────────────────────────────────────────────────────
   MASTER: buildInstalledAppList
   Priority order:
     1. LSApplicationWorkspace (best: names + icons + all apps)
     2. LastLaunchServicesMap.plist (fast single-file, names + icons)
     3. Filesystem scan (/var/containers/Bundle/Application)
     4. Data container metadata (bundle IDs only)
   ──────────────────────────────────────────────────────────────────────── */
- (NSArray<NSDictionary *> *)buildInstalledAppList {
    /* ── Try 1: LSApplicationWorkspace ── */
    Class wsClass = objc_getClass("LSApplicationWorkspace");
    if (!wsClass) {
        /* Also try NSClassFromString which searches all loaded images */
        wsClass = NSClassFromString(@"LSApplicationWorkspace");
    }
    if (wsClass) {
        LSApplicationWorkspace *workspace = ((id (*)(id, SEL))objc_msgSend)(wsClass, @selector(defaultWorkspace));
        if (workspace) {
            NSArray<LSApplicationProxy *> *apps = [self rawApplicationsFromWorkspace:workspace];
            NSLog(@"[ChangeInfoIos] LSApplicationWorkspace returned %lu raw apps", (unsigned long)apps.count);
            if (apps.count > 0) {
                NSMutableOrderedSet *seen = [NSMutableOrderedSet orderedSet];
                NSMutableArray *rows = [NSMutableArray array];
                for (id app in apps) {
                    NSString *bid = [self bundleIdForApplicationProxy:app];
                    if (bid.length < 4) continue;
                    if ([bid hasPrefix:@"com.apple."] && ![bid isEqualToString:@"com.apple.mobilesafari"]) continue;
                    if ([seen containsObject:bid]) continue;
                    [seen addObject:bid];
                    NSString *name = [self displayNameForApplicationProxy:app fallbackBundle:bid];
                    NSString *bundlePath = [self bundlePathForApplicationProxy:app];
                    NSMutableDictionary *row = [@{@"bundleId": bid, @"name": name} mutableCopy];
                    NSString *icon = [self iconBase64ForBundlePath:bundlePath];
                    if (icon) row[@"icon"] = icon;
                    [rows addObject:row];
                }
                if (rows.count > 0) {
                    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                        return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
                    }];
                    NSLog(@"[ChangeInfoIos] ✓ Using LSApplicationWorkspace: %lu apps", (unsigned long)rows.count);
                    return rows;
                }
            }
        }
    }
    NSLog(@"[ChangeInfoIos] LSApplicationWorkspace unavailable or empty, trying LaunchServicesMap...");

    /* ── Try 2: LastLaunchServicesMap.plist ── */
    NSArray *mapRows = [self scanApplicationsFromLaunchServicesMap];
    if (mapRows.count > 0) {
        NSLog(@"[ChangeInfoIos] ✓ Using LaunchServicesMap: %lu apps", (unsigned long)mapRows.count);
        return mapRows;
    }

    /* ── Try 3: Filesystem scan ── */
    NSArray *fsRows = [self scanApplicationsFromFilesystem];
    if (fsRows.count > 0) {
        NSLog(@"[ChangeInfoIos] ✓ Using filesystem scan: %lu apps", (unsigned long)fsRows.count);
        return fsRows;
    }

    /* ── Try 4: Data container metadata ── */
    NSArray *dcRows = [self scanApplicationsFromDataContainers];
    if (dcRows.count > 0) {
        NSLog(@"[ChangeInfoIos] ✓ Using data container scan: %lu apps", (unsigned long)dcRows.count);
        return dcRows;
    }

    NSLog(@"[ChangeInfoIos] ✗ All scan methods returned 0 apps!");
    return @[];
}

- (void)sendInstalledAppsToWebView {
    NSArray *list = [self buildInstalledAppList];
    NSLog(@"[ChangeInfoIos] Sending installed apps: %lu", (unsigned long)list.count);
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:list options:0 error:&err];
    if (!data) {
        NSString *msg = [NSString stringWithFormat:@"serialize_failed:%@", err.localizedDescription ?: @"unknown"];
        NSString *jsErr = [NSString stringWithFormat:
            @"(function(){window.__ciSetInstallError&&window.__ciSetInstallError(%@);})();",
            [NSString stringWithFormat:@"'%@'", [msg stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"]]];
        [self.webView evaluateJavaScript:jsErr completionHandler:nil];
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!json) return;
    NSString *js = [NSString stringWithFormat:
        @"(function(){try{window.__ciSetInstalledApps&&window.__ciSetInstalledApps(%@);}catch(e){window.__ciSetInstallError&&window.__ciSetInstallError(String(e));}})();", json];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.webView evaluateJavaScript:js completionHandler:^(id _Nullable result, NSError *error) {
            if (error) {
                NSLog(@"[ChangeInfoIos] __ciSetInstalledApps eval error: %@", error);
            }
        }];
    });
}

#pragma clang diagnostic pop

- (void)writeProfilePlist:(NSDictionary *)profile {
    NSString *plistPath = @"/var/mobile/Library/Preferences/com.changeinfoios.plist";
    NSDictionary *clean = CISanitizePlistDictionary(profile);
    NSError *err = nil;
    NSData *xml = [NSPropertyListSerialization dataWithPropertyList:clean
                                                           format:NSPropertyListXMLFormat_v1_0
                                                          options:0
                                                            error:&err];
    if (!xml || err) {
        NSLog(@"[ChangeInfoIos] Plist serialize failed: %@", err);
        return;
    }
    [xml writeToFile:plistPath atomically:YES];
    chmod([plistPath fileSystemRepresentation], 0644);
    ci_run_cmd("chown mobile:mobile /var/mobile/Library/Preferences/com.changeinfoios.plist");
}

- (void)appendWipeScript:(NSMutableString *)bash forBundleId:(NSString *)bundleId {
    if ([bundleId length] == 0) return;
    if ([bundleId isEqualToString:@"com.apple.mobilesafari"]) {
        [bash appendString:@"killall -9 MobileSafari 2>/dev/null\n"];
        [bash appendString:@"rm -rf /var/mobile/Library/Safari/*\n"];
        [bash appendString:@"rm -rf /var/mobile/Library/Cookies/*\n"];
        return;
    }
    if ([bundleId isEqualToString:@"com.vng.zalo"]) {
        [bash appendString:@"killall -9 Zalo 2>/dev/null\n"];
    }
    NSString *escaped = [bundleId stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    [bash appendFormat:@"for dir in /var/mobile/Containers/Data/Application/*; do\n"];
    [bash appendString:@"  if [ -f \"$dir/.com.apple.mobile_container_manager.metadata.plist\" ]; then\n"];
    [bash appendFormat:@"    if grep -qF '%@' \"$dir/.com.apple.mobile_container_manager.metadata.plist\" 2>/dev/null; then\n", escaped];
    [bash appendString:@"      rm -rf \"$dir/Library/Caches\" \"$dir/Library/Preferences\" \"$dir/Library/Cookies\" \"$dir/Library/WebKit\" \"$dir/Documents\" \"$dir/tmp\" 2>/dev/null\n"];
    [bash appendString:@"    fi\n"];
    [bash appendString:@"  fi\n"];
    [bash appendString:@"done\n"];
}

- (void)runWipeBundles:(NSArray *)wipes respring:(BOOL)doRespring {
    NSMutableString *bashScript = [NSMutableString stringWithString:@"#!/bin/bash\n"];
    for (NSString *bundleId in wipes) {
        if (![bundleId isKindOfClass:[NSString class]]) continue;
        [self appendWipeScript:bashScript forBundleId:bundleId];
    }
    NSString *scriptPath = @"/tmp/ci_wipe.sh";
    [bashScript writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ci_run_cmd("chmod 755 /tmp/ci_wipe.sh && /tmp/ci_wipe.sh");
    ci_run_cmd("rm -f /tmp/ci_wipe.sh");
    if (doRespring) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ci_run_cmd("notify_post com.changeinfoios/ReloadPrefs");
            ci_run_cmd("/var/jb/usr/bin/sbreload 2>/dev/null || killall -9 SpringBoard");
        });
    }
}

- (void)appendBackupScript:(NSMutableString *)bash forBundleId:(NSString *)bundleId {
    if (bundleId.length == 0) return;
    NSString *escaped = [bundleId stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    [bash appendString:@"TS=$(date +%Y%m%d-%H%M%S)\n"];
    [bash appendString:@"mkdir -p /var/mobile/ChangeInfoIos/backups\n"];
    [bash appendString:@"for dir in /var/mobile/Containers/Data/Application/*; do\n"];
    [bash appendString:@"  [ -f \"$dir/.com.apple.mobile_container_manager.metadata.plist\" ] || continue\n"];
    [bash appendFormat:@"  if grep -qF '%@' \"$dir/.com.apple.mobile_container_manager.metadata.plist\" 2>/dev/null; then\n", escaped];
    [bash appendFormat:@"    tar -czf \"/var/mobile/ChangeInfoIos/backups/%@-${TS}.tgz\" -C \"$dir\" . 2>/dev/null || true\n", escaped];
    [bash appendString:@"  fi\n"];
    [bash appendString:@"done\n"];
}

- (void)runBackupBundles:(NSArray *)bundles {
    NSMutableString *bashScript = [NSMutableString stringWithString:@"#!/bin/bash\n"];
    for (NSString *bundleId in bundles) {
        if (![bundleId isKindOfClass:[NSString class]]) continue;
        [self appendBackupScript:bashScript forBundleId:bundleId];
    }
    NSString *scriptPath = @"/tmp/ci_backup.sh";
    [bashScript writeToFile:scriptPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ci_run_cmd("chmod 755 /tmp/ci_backup.sh && /tmp/ci_backup.sh");
    ci_run_cmd("rm -f /tmp/ci_backup.sh");
    ci_run_cmd("chown -R mobile:mobile /var/mobile/ChangeInfoIos/backups 2>/dev/null || true");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.055 blue:0.09 alpha:1.0];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    [config.userContentController addScriptMessageHandler:self name:@"changeinfo"];

    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = [UIColor clearColor];
    self.webView.opaque = NO;
    self.webView.navigationDelegate = self;
    [self.view addSubview:self.webView];

    // Robust HTML loader: bundle first, then fallback paths on filesystem.
    NSArray<NSString *> *candidates = @[
        [[NSBundle mainBundle] pathForResource:@"mobile-app-standalone" ofType:@"html"] ?: @"",
        @"/var/jb/Applications/ChangeInfoIos.app/mobile-app-standalone.html",
        @"/Applications/ChangeInfoIos.app/mobile-app-standalone.html",
        @"/var/mobile/ChangeInfoIos/mobile-app-standalone.html"
    ];
    NSString *loadedPath = nil;
    NSString *loadedHTML = nil;
    for (NSString *p in candidates) {
        if (p.length == 0) continue;
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] || isDir) continue;
        NSError *readErr = nil;
        NSString *html = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:&readErr];
        if (html.length > 0 && !readErr) {
            loadedPath = p;
            loadedHTML = html;
            break;
        }
    }
    if (loadedHTML.length > 0) {
        NSURL *baseURL = [NSURL fileURLWithPath:[loadedPath stringByDeletingLastPathComponent] isDirectory:YES];
        [self.webView loadHTMLString:loadedHTML baseURL:baseURL];
        NSLog(@"[ChangeInfoIos] Loaded HTML from: %@", loadedPath);
    } else {
        NSString *errHTML = @"<html><body style='background:#060b16;color:#d7e6d8;font-family:-apple-system;padding:16px;'>"
                            "<h3>ChangeInfo load error</h3>"
                            "<p>mobile-app-standalone.html not found/readable.</p>"
                            "<p>Reinstall package, then respring.</p>"
                            "</body></html>";
        [self.webView loadHTMLString:errHTML baseURL:nil];
        NSLog(@"[ChangeInfoIos] HTML load failed for all candidate paths");
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView != self.webView) return;
    NSString *inj = @"(function(){window.__CI_NATIVE_SHELL=1;try{document.documentElement.setAttribute('data-ci-shell','native');}catch(e){}if(window.__ciOnShellReady)window.__ciOnShellReady();})();";
    [webView evaluateJavaScript:inj completionHandler:nil];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[ChangeInfoIos] WebView didFailNavigation: %@", error);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[ChangeInfoIos] WebView didFailProvisionalNavigation: %@", error);
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.name isEqualToString:@"changeinfo"]) return;
    NSDictionary *body = message.body;
    if (![body isKindOfClass:[NSDictionary class]]) return;
    NSString *action = body[@"action"];

    if ([action isEqualToString:@"listApps"]) {
        [self sendInstalledAppsToWebView];
    } else if ([action isEqualToString:@"wipe"]) {
        NSArray *wipes = body[@"wipes"];
        if ([wipes isKindOfClass:[NSArray class]] && [wipes count] > 0) {
            [self runWipeBundles:wipes respring:YES];
        }
    } else if ([action isEqualToString:@"backup"]) {
        NSArray *bundles = body[@"bundles"];
        if ([bundles isKindOfClass:[NSArray class]] && [bundles count] > 0) {
            [self runBackupBundles:bundles];
        }
    } else if ([action isEqualToString:@"deploy"]) {
        NSDictionary *profile = body[@"profile"];
        NSMutableDictionary *mergedProfile = nil;
        if ([profile isKindOfClass:[NSDictionary class]]) {
            mergedProfile = [profile mutableCopy];
        }
        NSArray *wipes = body[@"wipes"];
        if ([wipes isKindOfClass:[NSArray class]] && [wipes count] > 0) {
            if (!mergedProfile) mergedProfile = [NSMutableDictionary dictionary];
            [mergedProfile setObject:wipes forKey:@"targetBundles"];
        }
        if (mergedProfile) {
            [self writeProfilePlist:mergedProfile];
        }
        // Run wipes first, then signal JS
        if ([wipes isKindOfClass:[NSArray class]] && [wipes count] > 0) {
            [self runWipeBundles:wipes respring:NO];
        }
        // Now tell the webview that plist+wipes are done and respring is about to fire
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *js = @"(function(){try{if(window.__ciOnDeployProgress)window.__ciOnDeployProgress('configWritten');}catch(e){}})();";
            [self.webView evaluateJavaScript:js completionHandler:nil];
        });
        // Respring after wipes complete
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ci_run_cmd("notify_post com.changeinfoios/ReloadPrefs");
            ci_run_cmd("/var/jb/usr/bin/sbreload 2>/dev/null || killall -9 SpringBoard");
            // Tell the webview that respring has been triggered
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSString *js2 = @"(function(){try{if(window.__ciOnDeployProgress)window.__ciOnDeployProgress('respringTriggered');}catch(e){}})();";
                [self.webView evaluateJavaScript:js2 completionHandler:nil];
            });
        });
    }
}

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

@end

@implementation CIAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = [[CIMainViewController alloc] init];
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([CIAppDelegate class]));
    }
}
