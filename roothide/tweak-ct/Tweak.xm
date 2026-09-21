// MINIMAL no-substrate no-hook test build (roothide injection crash isolation).
// If this loads into a target app (bisect marker appears in the app's tmp) it
// proves the substrate/libellekit load-time dependency was the crash cause.
#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <stdio.h>

static void ci_bisect(const char *m) {
    const char *td = getenv("TMPDIR");
    char path[600];
    if (td && td[0]) snprintf(path, sizeof(path), "%s%sci_bisect_ct.log",
                              td, (td[strlen(td)-1]=='/') ? "" : "/");
    else snprintf(path, sizeof(path), "/tmp/ci_bisect_ct.log");
    int fd = open(path, O_CREAT|O_WRONLY|O_APPEND, 0666);
    if (fd >= 0) { write(fd, m, strlen(m)); write(fd, "\n", 1); close(fd); }
}

__attribute__((constructor(101)))
static void ci_min_early(void) { ci_bisect("MIN_A_ctor101"); }

__attribute__((constructor))
static void ci_min_default(void) { ci_bisect("MIN_B_ctor_default"); }
