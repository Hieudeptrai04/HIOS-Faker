// ChangeInfoIosMG v3.0.0 — hyper-minimal CI validation build.
// If THIS builds + loads into MobileGestaltHelper without crash, we
// know the deploy pipeline works. Then we add MGCopyAnswer hooks back.

#import <Foundation/Foundation.h>

%ctor {
    @autoreleasepool {
        NSString *exec = [[NSProcessInfo processInfo] processName] ?: @"?";
        NSLog(@"[ChangeInfoIosMG v3] loaded into %@", exec);
        NSString *marker = @"/var/jb/etc/changeinfoios/v3_mg_loaded.txt";
        NSString *body = [NSString stringWithFormat:@"%@ %@", exec, [NSDate date]];
        [body writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
