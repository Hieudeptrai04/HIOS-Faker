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
// 4.4.5: Artwork + GPU-family dict. Anti-tamper SDKs read this to decide which
// GPU feature set the device claims. Must stay in sync with the claimed chip.
static NSString *const kKeyArtworkDict      = @"oPeik/9e8lQWMszEjbPzng";

// Metal GPU family per iPhone generation. iPhone 8+ anti-tamper uses this to
// compare claimed vs real GPU. Not every ProductType is listed; nil means we
// don't rewrite the artwork dict (user can still patch the plain string keys).
static NSString *ci_graphicsClassForProductType(NSString *pt) {
    if ([pt hasPrefix:@"iPhone8,"]  || [pt hasPrefix:@"iPhone9,"])   return @"APPLE3"; // A9/A10
    if ([pt hasPrefix:@"iPhone10,"])                                 return @"APPLE4"; // A11
    if ([pt hasPrefix:@"iPhone11,"])                                 return @"APPLE5"; // A12
    if ([pt hasPrefix:@"iPhone12,"])                                 return @"APPLE6"; // A13
    if ([pt hasPrefix:@"iPhone13,"])                                 return @"APPLE7"; // A14
    if ([pt hasPrefix:@"iPhone14,"])                                 return @"APPLE8"; // A15
    if ([pt hasPrefix:@"iPhone15,"] || [pt hasPrefix:@"iPhone16,"])  return @"APPLE8"; // A16/A17
    if ([pt hasPrefix:@"iPhone17,"])                                 return @"APPLE9"; // A18
    return nil;
}

static NSString *ci_fallbackChainForClass(NSString *gpuClass) {
    if (![gpuClass hasPrefix:@"APPLE"]) return nil;
    NSInteger n = [[gpuClass substringFromIndex:5] integerValue];
    if (n < 1) return nil;
    NSMutableArray *items = [NSMutableArray array];
    for (NSInteger i = n - 1; i >= 1; i--) {
        [items addObject:[NSString stringWithFormat:@"APPLE%ld", (long)i]];
    }
    [items addObject:@"GLES2,0"];
    return [items componentsJoinedByString:@":"];
}

// HIOSFakerV3.app ships with com.apple.private.security.no-sandbox, so the
// entitled process can read/write files outside its container directly.
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

    NSString *productType  = fakeValues[@"productType"];
    NSString *hwModelStr   = fakeValues[@"hwModelStr"];
    NSString *marketing    = fakeValues[@"marketingName"];
    NSString *modelNumber  = fakeValues[@"modelNumber"];

    NSInteger patched = 0;
    if (productType.length)  { extra[kKeyHWMachine]        = productType; patched++; }
    if (hwModelStr.length)   { extra[kKeyHWModelStr]       = hwModelStr;  patched++; }
    if (marketing.length)    { extra[kKeyMarketingName]    = marketing;   patched++; }
    if (marketing.length)    { extra[kKeyMarketingNameAlt] = marketing;   patched++; }
    if (modelNumber.length)  { extra[kKeyModelNumber]      = modelNumber; patched++; }

    // 4.4.5: patch the Artwork / GPU-family dict so anti-tamper probes that
    // ask MG for GraphicsFeatureSetClass get a value consistent with the
    // claimed chip. Prevents the "claim iPhone 12 but MG says APPLE5" tell.
    NSString *gpuClass = productType.length ? ci_graphicsClassForProductType(productType) : nil;
    if (productType.length && gpuClass.length && marketing.length) {
        NSMutableDictionary *artwork = extra[kKeyArtworkDict];
        if (![artwork isKindOfClass:[NSMutableDictionary class]]) {
            artwork = [NSMutableDictionary dictionary];
        } else {
            artwork = [artwork mutableCopy];
        }
        artwork[@"ArtworkDeviceProductDescription"] = marketing;
        artwork[@"GraphicsFeatureSetClass"]         = gpuClass;
        artwork[@"CompatibleDeviceFallback"]        = productType;
        NSString *chain = ci_fallbackChainForClass(gpuClass);
        if (chain.length) artwork[@"GraphicsFeatureSetFallbacks"] = chain;
        extra[kKeyArtworkDict] = artwork;
        patched++;
    }

    NSLog(@"[MGCache] applied %ld patches (ProductType=%@ GPU=%@)",
          (long)patched, productType ?: @"-", gpuClass ?: @"-");

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
    NSDictionary *artwork = extra[kKeyArtworkDict];
    if (![artwork isKindOfClass:[NSDictionary class]]) artwork = @{};
    return @{
        @"productType":            extra[kKeyHWMachine]        ?: @"",
        @"hwModelStr":             extra[kKeyHWModelStr]       ?: @"",
        @"marketingName":          extra[kKeyMarketingName]    ?: @"",
        @"modelNumber":            extra[kKeyModelNumber]      ?: @"",
        @"graphicsFeatureSetClass": artwork[@"GraphicsFeatureSetClass"] ?: @"",
    };
}

@end
