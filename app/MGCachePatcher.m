// MGCachePatcher.m — see .h for the architectural motivation.
//
// Keys below are the obfuscated hashes libMobileGestalt uses as entries in the
// CacheExtra dict of /…/com.apple.MobileGestalt.plist. Reverse-engineered by
// the jailbreak community from the libMobileGestalt binary; the mapping is
// stable across iOS versions on this device class.

#import "MGCachePatcher.h"
#import <sys/stat.h>
#import <sys/wait.h>
#import <spawn.h>
extern char **environ;

static NSString *const kMGCacheLive =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
static NSString *const kMGCacheBackup =
    @"/var/jb/etc/changeinfoios/mg_cache_orig.plist";

// Known reversible keys (value-type match confirms semantic). More keys can be
// added as they become needed; absent patches just mean the live file keeps
// its original value for that key.
static NSString *const kKeyHWMachine        = @"h9jDsbgj7xIVeIQ8S3/X3Q"; // iPhone11,2
static NSString *const kKeyHWModelStr       = @"/YYygAofPDbhrwToVsXdeA"; // D321AP
static NSString *const kKeyMarketingName    = @"Z/dqyWS6OZTRy10UcmUAhw"; // iPhone XS
static NSString *const kKeyMarketingNameAlt = @"bbtR9jQx50Fv5Af/affNtA"; // iPhone XS
static NSString *const kKeyModelNumber      = @"97JDvERpVwO+GHtthIh7hA"; // A1920

// Run a short command through /usr/bin/sudo so we inherit root and can write
// to the SystemGroup container. iOS has no NSTask so we use posix_spawn.
// -n keeps sudo non-interactive: if a password would be prompted, we fail
// loudly rather than hang the main thread.
static BOOL ci_runSudo(NSArray<NSString *> *args) {
    NSMutableArray<NSString *> *full = [NSMutableArray arrayWithObjects:@"sudo", @"-n", nil];
    [full addObjectsFromArray:args];
    char **argv = (char **)malloc(sizeof(char *) * (full.count + 1));
    for (NSUInteger i = 0; i < full.count; i++) {
        argv[i] = strdup([full[i] UTF8String]);
    }
    argv[full.count] = NULL;

    pid_t pid = 0;
    int rc = posix_spawn(&pid, "/usr/bin/sudo", NULL, NULL, argv, environ);
    for (NSUInteger i = 0; i < full.count; i++) free(argv[i]);
    free(argv);

    if (rc != 0) {
        NSLog(@"[MGCache] posix_spawn err=%d", rc);
        return NO;
    }
    int status = 0;
    waitpid(pid, &status, 0);
    int exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    return exitCode == 0;
}

@implementation CIMGCachePatcher

+ (BOOL)backupExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:kMGCacheBackup];
}

+ (BOOL)backupOriginalIfNeeded {
    if ([self backupExists]) return YES;
    // Ensure parent directory exists (postinst creates it, but guard anyway).
    (void)ci_runSudo(@[@"mkdir", @"-p", [kMGCacheBackup stringByDeletingLastPathComponent]]);
    BOOL ok = ci_runSudo(@[@"cp", kMGCacheLive, kMGCacheBackup]);
    if (ok) {
        (void)ci_runSudo(@[@"chown", @"mobile:wheel", kMGCacheBackup]);
        (void)ci_runSudo(@[@"chmod", @"644", kMGCacheBackup]);
        NSLog(@"[MGCache] backup saved to %@", kMGCacheBackup);
    } else {
        NSLog(@"[MGCache] backup failed");
    }
    return ok;
}

+ (BOOL)patchWithFakeValues:(NSDictionary<NSString *, id> *)fakeValues {
    if (!fakeValues.count) {
        NSLog(@"[MGCache] patch: no values provided");
        return NO;
    }
    if (![self backupOriginalIfNeeded]) {
        NSLog(@"[MGCache] patch: refusing to proceed without backup");
        return NO;
    }

    NSError *err = nil;
    NSData *liveData = [NSData dataWithContentsOfFile:kMGCacheLive
                                              options:0
                                                error:&err];
    if (!liveData) {
        NSLog(@"[MGCache] read live: %@", err);
        return NO;
    }

    NSPropertyListFormat fmt = 0;
    id plist = [NSPropertyListSerialization
                    propertyListWithData:liveData
                                 options:NSPropertyListMutableContainersAndLeaves
                                  format:&fmt
                                   error:&err];
    if (![plist isKindOfClass:[NSMutableDictionary class]]) {
        NSLog(@"[MGCache] parse live: top-level not dict (%@)", err);
        return NO;
    }
    NSMutableDictionary *top = (NSMutableDictionary *)plist;
    NSMutableDictionary *extra = top[@"CacheExtra"];
    if (![extra isKindOfClass:[NSMutableDictionary class]]) {
        // Create CacheExtra if missing; iOS reads it when present.
        extra = [NSMutableDictionary dictionary];
        top[@"CacheExtra"] = extra;
    }

    // Build the exact set of (keyHash -> value) patches from the semantic
    // input. Missing semantic fields are skipped so partial profiles still
    // apply the rest.
    NSMutableDictionary *patches = [NSMutableDictionary dictionary];
    NSString *productType  = fakeValues[@"productType"];     // iPhone12,5
    NSString *hwModelStr   = fakeValues[@"hwModelStr"];      // D431AP
    NSString *marketing    = fakeValues[@"marketingName"];   // iPhone 11 Pro Max
    NSString *modelNumber  = fakeValues[@"modelNumber"];     // A2160

    if (productType.length)  patches[kKeyHWMachine]        = productType;
    if (hwModelStr.length)   patches[kKeyHWModelStr]       = hwModelStr;
    if (marketing.length)    patches[kKeyMarketingName]    = marketing;
    if (marketing.length)    patches[kKeyMarketingNameAlt] = marketing;
    if (modelNumber.length)  patches[kKeyModelNumber]      = modelNumber;

    for (NSString *k in patches) extra[k] = patches[k];
    NSLog(@"[MGCache] applying %lu patches", (unsigned long)patches.count);

    NSData *outData = [NSPropertyListSerialization
                           dataWithPropertyList:top
                                         format:NSPropertyListBinaryFormat_v1_0
                                        options:0
                                          error:&err];
    if (!outData) {
        NSLog(@"[MGCache] serialize: %@", err);
        return NO;
    }

    // Stage to tmp then sudo cp onto the live path. Writing directly to the
    // SystemGroup container needs root; the staging keeps the live file atomic
    // and keeps the error surface small (one cp either works or doesn't).
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"mg_cache_patched.plist"];
    if (![outData writeToFile:tmp atomically:YES]) {
        NSLog(@"[MGCache] tmp write failed");
        return NO;
    }

    BOOL cp = ci_runSudo(@[@"cp", tmp, kMGCacheLive]);
    if (!cp) {
        NSLog(@"[MGCache] sudo cp onto live failed");
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        return NO;
    }
    (void)ci_runSudo(@[@"chown", @"mobile:wheel", kMGCacheLive]);
    (void)ci_runSudo(@[@"chmod", @"644", kMGCacheLive]);
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    NSLog(@"[MGCache] live patched OK");
    return YES;
}

+ (BOOL)restoreOriginal {
    if (![self backupExists]) {
        NSLog(@"[MGCache] restore: no backup");
        return NO;
    }
    BOOL ok = ci_runSudo(@[@"cp", kMGCacheBackup, kMGCacheLive]);
    if (ok) {
        (void)ci_runSudo(@[@"chown", @"mobile:wheel", kMGCacheLive]);
        (void)ci_runSudo(@[@"chmod", @"644", kMGCacheLive]);
        NSLog(@"[MGCache] restored from backup");
    } else {
        NSLog(@"[MGCache] restore cp failed");
    }
    return ok;
}

+ (nullable NSDictionary *)readLiveSnapshot {
    NSData *data = [NSData dataWithContentsOfFile:kMGCacheLive];
    if (!data) return nil;
    id plist = [NSPropertyListSerialization
                    propertyListWithData:data
                                 options:0
                                  format:NULL
                                   error:NULL];
    if (![plist isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *extra = plist[@"CacheExtra"];
    if (![extra isKindOfClass:[NSDictionary class]]) return @{};
    return @{
        @"productType":   extra[kKeyHWMachine]        ?: @"",
        @"hwModelStr":    extra[kKeyHWModelStr]       ?: @"",
        @"marketingName": extra[kKeyMarketingName]    ?: @"",
        @"modelNumber":   extra[kKeyModelNumber]      ?: @"",
    };
}

@end
