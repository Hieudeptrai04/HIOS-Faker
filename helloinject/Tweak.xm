#import <Foundation/Foundation.h>

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        NSString *dir = @"/var/mobile/Library/Caches/ChangeInfoIos";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [dir stringByAppendingFormat:@"/hello_%@.txt", bid];
        NSString *stamp = [NSString stringWithFormat:@"%@|%ld", bid, (long)time(NULL)];
        [stamp writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
