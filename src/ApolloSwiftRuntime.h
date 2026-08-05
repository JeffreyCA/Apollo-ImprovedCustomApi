// ApolloSwiftRuntime — shared helpers for reading Apollo's private Swift stored
// properties (title/subtitle strings, action arrays, boolean flags) directly off
// ivar offsets, without an @objc-visible getter.
//
// Swift stored properties on a class are laid out inline at a fixed ivar offset
// but have no ObjC getter unless explicitly @objc; these helpers read them by
// name via the ObjC runtime's ivar list, exactly like MSHookIvar but usable
// outside a %hook block (see AGENTS.md's "Swift Struct Ivars and iOS Version
// Pitfalls" for why this is necessary and its limits).
//
// static inline, header-only: each including .xm gets its own copy, so there is
// no shared translation unit to add to the Makefile.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>

// Decodes a Swift String stored inline across two 64-bit words (small-string
// representation, <=15 UTF-8 bytes) or bridges a heap-allocated Swift String via
// its private _bridgeToObjectiveC symbol. See AGENTS.md's "Decoding Swift small
// strings from assembly" for the byte layout this mirrors.
static inline NSString *ApolloDecodeSwiftString(uint64_t w0, uint64_t w1) {
    if (w1 == 0) {
        return nil;
    }

    uint8_t disc = (uint8_t)(w1 >> 56);
    if (disc >= 0xE0 && disc <= 0xEF) {
        NSUInteger len = disc - 0xE0;
        if (len == 0) return @"";

        char buf[16] = {0};
        memcpy(buf, &w0, 8);
        uint64_t w1clean = w1 & 0x00FFFFFFFFFFFFFFULL;
        memcpy(buf + 8, &w1clean, 7);
        return [[NSString alloc] initWithBytes:buf length:len encoding:NSUTF8StringEncoding];
    }

    typedef NSString *(*BridgeFn)(uint64_t, uint64_t);
    static BridgeFn sBridge = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sBridge = (BridgeFn)dlsym(RTLD_DEFAULT,
            "$sSS10FoundationE19_bridgeToObjectiveCSo8NSStringCyF");
    });

    return sBridge ? sBridge(w0, w1) : nil;
}

static inline ptrdiff_t ApolloIvarOffset(Class cls, const char *name) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    return ivar ? ivar_getOffset(ivar) : -1;
}

static inline void *ApolloReadRawIvar(id object, const char *name) {
    if (!object) return NULL;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return NULL;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return *(void **)(base + offset);
}

static inline id ApolloReadObjectIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    void *value = *(void **)(base + offset);
    return (__bridge id)value;
}

static inline BOOL ApolloReadBoolIvar(id object, const char *name, BOOL defaultValue) {
    if (!object) return defaultValue;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return defaultValue;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return *(uint8_t *)(base + offset) != 0;
}

static inline NSString *ApolloReadSwiftStringIvar(id object, const char *name) {
    if (!object) return nil;
    ptrdiff_t offset = ApolloIvarOffset(object_getClass(object), name);
    if (offset < 0) return nil;
    uint8_t *base = (uint8_t *)(__bridge void *)object;
    return ApolloDecodeSwiftString(*(uint64_t *)(base + offset), *(uint64_t *)(base + offset + 0x08));
}

// Element count of a Swift Array<T> stored inline as a buffer pointer (the count
// word sits at buffer+0x10; see ApolloNativeActionMenus.xm's action-array layout
// comments for the full element stride/offset convention built on top of this).
static inline int64_t ApolloSwiftArrayCount(void *buffer) {
    if (!buffer) return 0;
    int64_t count = *(int64_t *)((uint8_t *)buffer + 0x10);
    return count > 0 ? count : 0;
}
