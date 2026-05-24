// ChangeInfoIosCT v3.0.0 — STUB (Phase 3 milestone)
//
// Targets CommCenter daemon to spoof carrier name / MCC / MNC at the
// XPC source, so every app reading CTCarrier sees the fake value
// without us injecting into the app.
//
// MVP NOTE: this stub is a no-op. CommCenter internals are deep iOS
// telephony — hooking incorrectly = SafeMode + no cellular = unrecoverable
// without IPSW restore. We ship the v3 MVP with carrier handled by the
// MG tweak's MobileSubscriberCountryCode / MobileSubscriberNetworkCode
// keys (which is what most apps actually query). Pure-CTCarrier-only
// apps will see the real carrier — same trade-off Phase 3.9 of PLAN.md
// documents.
//
// Re-enable Phase 3 work by replacing this stub with proper CTCarrier
// or _CTServerConnection IPC return-value hooks once we have a CommCenter
// fuzzing rig set up.

#import <Foundation/Foundation.h>
#import <time.h>

%ctor {
    @autoreleasepool {
        NSString *exec = [[NSProcessInfo processInfo] processName] ?: @"?";
        NSLog(@"[ChangeInfoIosCT v3 stub] loaded into %@ — no-op (MG tweak handles MCC/MNC)", exec);
        NSString *marker = @"/var/jb/etc/changeinfoios/v3_ct_loaded.txt";
        NSString *body = [NSString stringWithFormat:@"%@\n%ld\n", exec, (long)time(NULL)];
        [body writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}
