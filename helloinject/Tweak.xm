#import <Foundation/Foundation.h>
#import <os/log.h>

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        NSString *proc = [[NSProcessInfo processInfo] processName] ?: @"?";

        // (1) os_log fires REGARDLESS of sandbox — proves the ctor ran even
        // when filesystem markers are blocked by the host process's sandbox.
        // Visible via Console.app or `log show --predicate 'subsystem ==
        // "com.changeinfoios.hello"'`.
        os_log_t log = os_log_create("com.changeinfoios.hello", "ctor");
        os_log(log, "[HelloInject] CTOR FIRED — bid=%{public}@ proc=%{public}@",
               bid, proc);

        // (2) System-wide marker — works for permissive procs (system daemons),
        // fails silently for App Store apps with strict sandboxes.
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

        // (3) Sandbox-friendly marker inside the host's OWN container/tmp.
        // When system path (#2) silently fails, this one still lands and is
        // readable from outside via /var/mobile/Containers/Data/Application/
        // <UUID>/tmp/. Confirms the ctor ran even when (2) is blocked.
        NSString *tmp = NSTemporaryDirectory();
        if (tmp.length) {
            NSString *tmpMarker = [tmp stringByAppendingPathComponent:@"hios_hello.txt"];
            [stamp writeToFile:tmpMarker atomically:YES encoding:NSUTF8StringEncoding error:nil];

            // Also probe which prefs paths the host app can actually read,
            // so we know where to ship the config. Each candidate gets a
            // line: "<path>\t<size or -1>".
            NSArray *candidates = @[
                @"/var/mobile/Library/Preferences/com.changeinfoios.plist",
                @"/var/jb/var/mobile/Library/Preferences/com.changeinfoios.plist",
                @"/var/jb/etc/changeinfoios/config.plist",
                @"/var/jb/etc/changeinfoios/cdhashes",
            ];
            NSMutableString *probe = [NSMutableString string];
            for (NSString *p in candidates) {
                NSError *err = nil;
                NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:&err];
                long long sz = attr ? [attr[NSFileSize] longLongValue] : -1;
                NSData *data = sz > 0 ? [NSData dataWithContentsOfFile:p options:0 error:nil] : nil;
                [probe appendFormat:@"%@\tstat=%lld\tread=%lu\n", p, sz, (unsigned long)data.length];
            }
            NSString *probePath = [tmp stringByAppendingPathComponent:@"hios_probe.txt"];
            [probe writeToFile:probePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}
