#import <Foundation/Foundation.h>

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";
        NSString *dir = @"/var/mobile/Library/Caches/ChangeInfoIos";
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *path = [dir stringByAppendingFormat:@"/hello_%@.txt", bid];
        NSString *stamp = [NSString stringWithFormat:@"%@|proc=%@|t=%ld", bid, proc, (long)time(NULL)];
        [stamp writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *allPath = [dir stringByAppendingPathComponent:@"hello_all.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:allPath];
        if (!fh) {
            [[NSFileManager defaultManager] createFileAtPath:allPath contents:nil attributes:nil];
            fh = [NSFileHandle fileHandleForWritingAtPath:allPath];
        }
        if (fh) {
            [fh seekToEndOfFile];
            [fh writeData:[[NSString stringWithFormat:@"%ld\t%@\t%@\n", (long)time(NULL), bid, proc] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
