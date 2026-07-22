// Copyright (c) 2013, Facebook, Inc.  All rights reserved.
// Licensed under the BSD-2-Clause license (see LICENSE in fishhook source).
//
// Embedded into ChangeInfoIos to provide GOT-rebinding hook for MGCopyAnswer
// on iOS 16.7.11 where MSHookFunction's prologue patch trips the AMFI brk
// trap and crashes the host process at first call. Fishhook does NOT modify
// libMobileGestalt's code — it only rewrites the import slot of other dylibs
// that call MGCopyAnswer through their __DATA/__got entries.
//
// Coverage: catches every call through a dyld-stub (i.e. apps/SDKs that
// declare `extern CFTypeRef MGCopyAnswer(CFStringRef);` and let the linker
// resolve it). Misses calls via dlsym(RTLD_DEFAULT, "MGCopyAnswer").

#ifndef fishhook_h
#define fishhook_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct rebinding {
    const char *name;
    void *replacement;
    void **replaced;
};

int rebind_symbols(struct rebinding rebindings[], size_t rebindings_nel);

#ifdef __cplusplus
}
#endif

#endif // fishhook_h
