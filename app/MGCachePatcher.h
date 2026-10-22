// MGCachePatcher.h — persistent device-wide MG spoof via CacheExtra edit.
// 5.0.0: alternative to the ellekit per-app injection path. Patches the system
// MG cache plist so every app on the device sees the faked identity without a
// dylib hook running inside it (Zalo cannot detect what is not there).

#import <Foundation/Foundation.h>

@interface CIMGCachePatcher : NSObject

// Backup the live MG cache to a safe location once per lifetime. Idempotent.
+ (BOOL)backupOriginalIfNeeded;

// Apply the fake identity to the live MG cache's CacheExtra section. Keys that
// are not present in the current cache are added; keys that are present are
// overwritten. Returns YES only when the patched file is on disk at the live
// path with correct ownership.
//   fakeValues: { productType, hwModelStr, marketingName, modelNumber }
+ (BOOL)patchWithFakeValues:(NSDictionary<NSString *, id> *)fakeValues;

// Revert the live MG cache to the pristine backup. No-op (returns NO) when no
// backup exists.
+ (BOOL)restoreOriginal;

// Convenience: is a backup already captured?
+ (BOOL)backupExists;

// For UI reporting — read the live cache and return current ProductType /
// HWModel / MarketingName as a dict (nil on parse failure).
+ (nullable NSDictionary *)readLiveSnapshot;

@end
