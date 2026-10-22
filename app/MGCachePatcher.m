// MGCachePatcher.m — see .h for the architectural motivation.
//
// Keys below are the obfuscated hashes libMobileGestalt uses as entries in the
// CacheExtra dict of /…/com.apple.MobileGestalt.plist. Reverse-engineered by
// the jailbreak community from the libMobileGestalt binary; the mapping is
// stable across iOS versions on this device class.

#import "MGCachePatcher.h"
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kMGCacheLive =
    @"/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist";
static NSString *const kMGCacheBackup =
    @"/var/jb/etc/changeinfoios/mg_cache_orig.plist";

// Known reversible keys (value-type match confirms semantic).
static NSString *const kKeyHWMachine        = @"h9jDsbgj7xIVeIQ8S3/X3Q";
static NSString *const kKeyHWModelStr       = @"/YYygAofPDbhrwToVsXdeA";
static NSString *const kKeyMarketingName    = @"Z/dqyWS6OZTRy10UcmUAhw";
static NSString *const kKeyMarketingNameAlt = @"bbtR9jQx50Fv5Af/affNtA";
static NSString *const kKeyModelNumber      = @"97JDvERpVwO+GHtthIh7hA";

// HIOSFakerV3.app ships with com.apple.private.security.no-sandbox, so the
// entitled process can read/write files outside its container directly — no
// external binary spawn needed.
static BOOL ci_writeDataToPath(NSData *data, NSString *path) {
    NSError *err = nil;
    BOOL ok = [data writeToFile:path options:NSDataWritingAtomic error:&err];
    if (!ok) NSLog(@"[MGCache] write %@: %@", path, err);
    return ok;
}

static BOOL ci_copyFileAtPath(NSString *src, NSString *dst) {
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
    BOOL ok = [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&err];
    if (!ok) NSLog(@"[MGCache] copy %@ -> %@: %@", src, dst, err);
    return ok;
}

static void ci_chmodMobileWheel(NSString *path) {
    (void)chown([path fileSystemRepresentation], 501, 0);
    (void)chmod([path fileSystemRepresentation], 0644);
}

@implementation CIMGCachePatcher

+ (BOOL)backupExists {
    return [[NSFileManager defaultManager] fileExistsAtPath:kMGCacheBackup];
}

+ (BOOL)backupOriginalIfNeeded {
    if ([self backupExists]) return YES;
    NSString *parent = [kMGCacheBackup stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:parent
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    BOOL ok = ci_copyFileAtPath(kMGCacheLive, kMGCacheBackup);
    if (ok) {
        ci_chmodMobileWheel(kMGCacheBackup);
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
        extra = [NSMutableDictionary dictionary];
        top[@"CacheExtra"] = extra;
    }

    NSMutableDictionary *patches = [NSMutableDictionary dictionary];
    NSString *productType  = fakeValues[@"productType"];
    NSString *hwModelStr   = fakeValues[@"hwModelStr"];
    NSString *marketing    = fakeValues[@"marketingName"];
    NSString *modelNumber  = fakeValues[@"modelNumber"];

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

    if (!ci_writeDataToPath(outData, kMGCacheLive)) return NO;
    ci_chmodMobileWheel(kMGCacheLive);
    NSLog(@"[MGCache] live patched OK");
    return YES;
}

+ (BOOL)restoreOriginal {
    if (![self backupExists]) {
        NSLog(@"[MGCache] restore: no backup");
        return NO;
    }
    BOOL ok = ci_copyFileAtPath(kMGCacheBackup, kMGCacheLive);
    if (ok) {
        ci_chmodMobileWheel(kMGCacheLive);
        NSLog(@"[MGCache] restored from backup");
    } else {
        NSLog(@"[MGCache] restore failed");
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
