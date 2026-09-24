// hidpi-mirror: force HiDPI rendering on a non-4K external display by
// creating a virtual HiDPI display (private CGVirtualDisplay API, same
// technique as BetterDummy/BetterDisplay) and mirroring the physical
// display onto it. The GPU downsamples the 2x framebuffer -> sharp text.
//
// Build: clang -fobjc-arc -framework Foundation -framework CoreGraphics \
//        -o hidpi-mirror hidpi-mirror.m
// Usage: ./hidpi-mirror [lookslike_width lookslike_height [vendor_id]]
//        default 2048 1152 (~125% UI scale on QHD); vendor_id selects the
//        physical display to mirror onto (default 4268 = Dell).
//        Runs until killed; on exit the physical display reverts.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

// ---- Private CoreGraphics API declarations (typing only; classes are
// ---- instantiated via NSClassFromString so we don't need link symbols) ----
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end
// --------------------------------------------------------------------------

static uint32_t gVendor = 4268; // 0x10AC = Dell; override via argv[3]

static CGVirtualDisplay *gVirtual = nil;  // keep-alive
static CGDirectDisplayID gVirtualID = 0;
static unsigned int gLW = 2048, gLH = 1152; // desired "looks like" size
static unsigned gGeneration = 0; // bumped per virtual-display (re)create

static CGDirectDisplayID findDell(void) {
    CGDirectDisplayID ids[16];
    uint32_t count = 0;
    CGGetOnlineDisplayList(16, ids, &count);
    for (uint32_t i = 0; i < count; i++) {
        if (CGDisplayIsBuiltin(ids[i])) continue;
        if (ids[i] == gVirtualID) continue;
        if (CGDisplayVendorNumber(ids[i]) == gVendor) return ids[i];
    }
    return kCGNullDirectDisplay;
}

// Find the HiDPI mode (points = gLW x gLH, pixels = 2x) on the virtual
// display. Returns a retained mode ref, or NULL.
static CGDisplayModeRef copyWantedMode(void) {
    CFStringRef k = kCGDisplayShowDuplicateLowResolutionModes;
    CFBooleanRef v = kCFBooleanTrue;
    CFDictionaryRef opts = CFDictionaryCreate(
        NULL, (const void **)&k, (const void **)&v, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef modes = CGDisplayCopyAllDisplayModes(gVirtualID, opts);
    CFRelease(opts);
    if (!modes) { NSLog(@"no modes for virtual display?"); return NULL; }
    CGDisplayModeRef want = NULL;
    for (CFIndex i = 0; i < CFArrayGetCount(modes); i++) {
        CGDisplayModeRef m =
            (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
        if (CGDisplayModeGetWidth(m) == gLW &&
            CGDisplayModeGetHeight(m) == gLH &&
            CGDisplayModeGetPixelWidth(m) == 2 * gLW) {
            want = (CGDisplayModeRef)CFRetain(m);
            break;
        }
    }
    CFRelease(modes);
    if (!want) NSLog(@"HiDPI mode %ux%u@2x not found!", gLW, gLH);
    return want;
}

// Create the virtual HiDPI display. Returns NO on failure.
static BOOL createVirtual(void) {
    CGVirtualDisplayDescriptor *desc =
        [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    desc.name = @"HiDPI Mirror";
    desc.queue = dispatch_get_main_queue();
    // Physical size of the U2520D panel => sane reported DPI
    desc.sizeInMillimeters = CGSizeMake(553.7, 311.3);
    desc.maxPixelsWide = 5120;
    desc.maxPixelsHigh = 2880;
    // sRGB-ish primaries
    desc.redPrimary   = CGPointMake(0.680, 0.320);
    desc.greenPrimary = CGPointMake(0.265, 0.690);
    desc.bluePrimary  = CGPointMake(0.150, 0.060);
    desc.whitePoint   = CGPointMake(0.3127, 0.3290);
    // Fresh identity (macOS stores mode prefs per vendor+product; the
    // original identity has a stale 3840x2160@1x preference stuck to it)
    desc.vendorID  = 0xB33F;
    desc.productID = 0x2049 + gLW / 16 + gLH; // identity varies per size
    desc.serialNum = 1;
    unsigned gen = ++gGeneration;
    desc.terminationHandler = ^(id a, id b) {
        // Only react if THIS instance is still the live one; our own
        // teardown (destroyVirtual) bumps the generation first.
        if (gen != gGeneration) return;
        NSLog(@"virtual display terminated");
        exit(0);
    };

    gVirtual = [[NSClassFromString(@"CGVirtualDisplay") alloc]
                   initWithDescriptor:desc];
    if (!gVirtual) { NSLog(@"failed to create virtual display"); return NO; }
    gVirtualID = gVirtual.displayID;

    CGVirtualDisplaySettings *settings =
        [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = 1;
    Class modeCls = NSClassFromString(@"CGVirtualDisplayMode");
    // WindowServer ignores programmatic mode changes on virtual displays
    // and always runs the PREFERRED (first listed) mode -- so put the
    // desired mode first; keep the rest for HiDPI mode-list synthesis.
    NSMutableArray *modes = [NSMutableArray arrayWithObject:
        [[modeCls alloc] initWithWidth:gLW * 2 height:gLH * 2 refreshRate:60]];
    unsigned int extra[][2] = {
        {5120, 2880}, {4608, 2592}, {4096, 2304},
        {3840, 2160}, {3360, 1890}, {3200, 1800},
    };
    for (size_t i = 0; i < sizeof(extra) / sizeof(extra[0]); i++)
        if (extra[i][0] != gLW * 2)
            [modes addObject:[[modeCls alloc] initWithWidth:extra[i][0]
                                                     height:extra[i][1]
                                                refreshRate:60]];
    settings.modes = modes;
    if (![gVirtual applySettings:settings]) {
        NSLog(@"applySettings failed");
        // Invalidate first so this failed instance's terminationHandler
        // doesn't mistake our cleanup for external termination and exit(0).
        gGeneration++;
        gVirtual = nil;
        gVirtualID = 0;
        return NO;
    }
    NSLog(@"virtual display up, id=%u (UI looks like %ux%u, framebuffer %ux%u)",
          gVirtualID, gLW, gLH, gLW * 2, gLH * 2);
    return YES;
}

static void destroyVirtual(void) {
    if (!gVirtual) return;
    NSLog(@"physical display gone, tearing down virtual display");
    gGeneration++; // invalidate this instance's terminationHandler
    gVirtual = nil; // releasing the object terminates the virtual display
    gVirtualID = 0;
}

// ---- Kernel-level external video link detection (IOKit) ----
// This process's CoreGraphics view can go stale (observed: after a
// disconnect it kept listing the Dell as online and mirrored, with no
// reconfiguration callback), leaving the virtual display as an invisible
// main display. The display coprocessor publishes a DCPAVVideoInterfaceProxy
// with Location=External exactly while an external video link is up; IOKit
// state comes from the kernel and can't go stale, and its match/terminate
// notifications are instant.

static CFMutableDictionaryRef externalLinkMatching(void) {
    CFMutableDictionaryRef m = IOServiceMatching("DCPAVVideoInterfaceProxy");
    if (!m) return NULL;
    CFMutableDictionaryRef props = CFDictionaryCreateMutable(
        NULL, 0, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(props, CFSTR("Location"), CFSTR("External"));
    CFDictionarySetValue(m, CFSTR(kIOPropertyMatchKey), props);
    CFRelease(props);
    return m;
}

// NO only when IOKit positively reports no external video link; on any
// IOKit error assume YES (i.e. fall back to trusting CoreGraphics).
static BOOL externalLinkUp(void) {
    CFMutableDictionaryRef m = externalLinkMatching();
    if (!m) return YES;
    io_iterator_t it = IO_OBJECT_NULL;
    // IOServiceGetMatchingServices consumes the matching dictionary.
    if (IOServiceGetMatchingServices(kIOMainPortDefault, m, &it) !=
        KERN_SUCCESS)
        return YES;
    BOOL any = NO;
    io_object_t o;
    while ((o = IOIteratorNext(it))) {
        any = YES;
        IOObjectRelease(o);
    }
    IOObjectRelease(it);
    return any;
}

// The virtual display is (re)created on demand, so macOS forgets it was
// the main display across reconnects; the display whose origin is (0,0)
// becomes main -- reclaim it for the mirror set. Must run as a separate
// transaction after the mirror is established.
static void claimMain(void) {
    if (!gVirtual) return;
    CGRect vb = CGDisplayBounds(gVirtualID);
    int32_t dx = (int32_t)vb.origin.x, dy = (int32_t)vb.origin.y;
    if (dx == 0 && dy == 0) return; // already main
    // Translate the WHOLE arrangement so the virtual lands on (0,0):
    // setting just one display's origin is silently normalized away.
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    CGGetOnlineDisplayList(16, ids, &n);
    CGDisplayConfigRef cfg;
    CGBeginDisplayConfiguration(&cfg);
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay)
            continue; // mirror followers inherit their master's origin
        CGRect b = CGDisplayBounds(ids[i]);
        CGConfigureDisplayOrigin(cfg, ids[i],
                                 (int32_t)b.origin.x - dx,
                                 (int32_t)b.origin.y - dy);
    }
    CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
    NSLog(@"claimMain: shift arrangement by (%d,%d): %s (err=%d)", -dx, -dy,
          err == kCGErrorSuccess ? "OK" : "FAILED", err);
}

// Run `action` as soon as `ready` holds (checked every 250ms), but after
// at most `tries` checks regardless -- i.e. never later than the fixed
// delays this replaces. Aborts if the virtual display instance changes.
static void whenReady(int tries, BOOL (^ready)(void), void (^action)(void)) {
    unsigned gen = gGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                   dispatch_get_main_queue(), ^{
        if (!gVirtual || gen != gGeneration) return;
        if (tries <= 1 || ready()) action();
        else whenReady(tries - 1, ready, action);
    });
}

static void mirrorNow(void) {
    static BOOL wasOffline = NO;
    if (!externalLinkUp()) {
        // Kernel says no external video link: the physical display is gone,
        // whatever our (possibly stale) CoreGraphics view claims.
        if (!wasOffline)
            NSLog(@"no external video link (IOKit), waiting...");
        wasOffline = YES;
        destroyVirtual();
        return;
    }
    CGDirectDisplayID dell = findDell();
    if (dell == kCGNullDirectDisplay) {
        if (!wasOffline)
            NSLog(@"display not online (KVM switched away?), waiting...");
        wasOffline = YES;
        // No physical display -> no reason to keep the virtual one around
        // (it would act as invisible screen estate collecting windows).
        destroyVirtual();
        return;
    }
    wasOffline = NO;
    if (!gVirtual) {
        if (!createVirtual()) return; // retry on next poll
        // Let WindowServer settle (publish modes) before mirroring onto
        // the fresh display -- proceed as soon as the wanted HiDPI mode is
        // published, or after 2s at the latest (as before).
        whenReady(8, ^BOOL { // quiet check: modes published yet?
            CFArrayRef modes = CGDisplayCopyAllDisplayModes(gVirtualID, NULL);
            CFIndex n = modes ? CFArrayGetCount(modes) : 0;
            if (modes) CFRelease(modes);
            return n > 0;
        }, ^{ mirrorNow(); });
        return;
    }
    BOOL mirrored = (CGDisplayMirrorsDisplay(dell) == gVirtualID);
    // NB: CGDisplayCopyDisplayMode can return NULL right after the virtual
    // display is created (mode not yet published), and also while the
    // virtual display is the master of a hardware mirror set -- in that
    // case the Dell reflects the mirror set's mode, so query it instead.
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(gVirtualID);
    if (!curMode && mirrored) curMode = CGDisplayCopyDisplayMode(dell);
    BOOL rightMode =
        curMode && CGDisplayModeGetPixelWidth(curMode) == 2 * gLW;
    if (curMode) CFRelease(curMode);
    if (mirrored && rightMode) {
        // WindowServer may restore the mirror on its own from a saved
        // arrangement (e.g. on reconnect), skipping our transaction and
        // its claimMain follow-up -- so ensure the main role here too.
        // No-op (no reconfiguration) when the virtual is already main.
        claimMain();
        return;
    }
    CGDisplayModeRef want = rightMode ? NULL : copyWantedMode();
    NSLog(@"mirrorNow: mirrored=%d rightMode=%d want=%s", mirrored, rightMode,
          want ? "found" : "NULL");
    // Single transaction: set HiDPI mode AND mirror atomically.
    CGError err = kCGErrorFailure;
    CGConfigureOption options[] = {kCGConfigureForSession,
                                   kCGConfigurePermanently};
    for (int i = 0; i < 2 && err != kCGErrorSuccess; i++) {
        CGDisplayConfigRef cfg;
        CGBeginDisplayConfiguration(&cfg);
        if (want) {
            CGError e1 = CGConfigureDisplayWithDisplayMode(cfg, gVirtualID,
                                                           want, NULL);
            NSLog(@"  CGConfigureDisplayWithDisplayMode: err=%d", e1);
        }
        if (!mirrored) CGConfigureDisplayMirrorOfDisplay(cfg, dell, gVirtualID);
        err = CGCompleteDisplayConfiguration(cfg, options[i]);
        NSLog(@"mode+mirror transaction (%s): %s (err=%d)",
              i == 0 ? "session" : "permanent",
              err == kCGErrorSuccess ? "OK" : "FAILED", err);
    }
    if (want) CFRelease(want);
    if (err != kCGErrorSuccess) return; // nothing to follow up on
    unsigned gen = gGeneration;
    // Follow up as soon as the mirror is established (2s at the latest).
    whenReady(8, ^BOOL {
        CGDirectDisplayID d = findDell();
        return d != kCGNullDirectDisplay &&
               CGDisplayMirrorsDisplay(d) == gVirtualID;
    }, ^{
        // Only follow up on the SAME virtual display instance we just
        // configured, and only if the mirror is actually established --
        // otherwise a stale block could promote an unmirrored virtual
        // display to main during a disconnect/reconnect shuffle.
        if (!gVirtual || gen != gGeneration) return;
        CGDirectDisplayID d = findDell();
        if (d == kCGNullDirectDisplay ||
            CGDisplayMirrorsDisplay(d) != gVirtualID) return;
        claimMain();
        CGDisplayModeRef cur = CGDisplayCopyDisplayMode(gVirtualID);
        if (!cur) return;
        CFAutorelease(cur);
        NSLog(@"post-transaction actual mode: %zux%zu points, %zux%zu pixels",
              CGDisplayModeGetWidth(cur), CGDisplayModeGetHeight(cur),
              CGDisplayModeGetPixelWidth(cur), CGDisplayModeGetPixelHeight(cur));
    });
}

static void unmirror(void) {
    CGDirectDisplayID dell = findDell();
    if (dell == kCGNullDirectDisplay) return;
    if (CGDisplayMirrorsDisplay(dell) == kCGNullDirectDisplay) return;
    CGDisplayConfigRef cfg;
    CGBeginDisplayConfiguration(&cfg);
    CGConfigureDisplayMirrorOfDisplay(cfg, dell, kCGNullDirectDisplay);
    // Session only: a stop/restart of this agent must not persist an
    // unmirrored arrangement that WindowServer would later restore.
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForSession);
    NSLog(@"unmirrored");
}

static void reconfigCB(CGDirectDisplayID d, CGDisplayChangeSummaryFlags flags,
                       void *userInfo) {
    if (flags & (kCGDisplayAddFlag | kCGDisplayRemoveFlag)) {
        // Display (dis)appeared -- e.g. KVM switch. Give WindowServer
        // a moment to settle, then re-establish (or tear down) the mirror.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ mirrorNow(); });
    }
}

// Link came up: act as soon as CoreGraphics brings the display online,
// instead of waiting for a (possibly missing) reconfiguration callback or
// the 10s poll. Calls mirrorNow() exactly once.
static void mirrorWhenOnline(int triesLeft) {
    if (findDell() != kCGNullDirectDisplay || triesLeft <= 0) {
        mirrorNow();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4),
                   dispatch_get_main_queue(),
                   ^{ mirrorWhenOnline(triesLeft - 1); });
}

// Link went away but CoreGraphics still lists the display: our CG view is
// stale and won't recover in-process. Nothing is displayed via the virtual
// display anymore, so a restart (launchd KeepAlive) is harmless.
static void checkStaleAfterLinkDown(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        if (externalLinkUp() || findDell() == kCGNullDirectDisplay) return;
        NSLog(@"external link gone (IOKit) but CoreGraphics still lists the "
              @"display: stale CG state, exiting for a clean restart");
        exit(2);
    });
}

static void drainIterator(io_iterator_t it) {
    io_object_t o;
    while ((o = IOIteratorNext(it))) IOObjectRelease(o);
}

static void linkAppeared(void *refcon, io_iterator_t it) {
    drainIterator(it); // also re-arms the notification
    NSLog(@"external video link up (IOKit)");
    mirrorWhenOnline(40); // up to 10s
}

static void linkGone(void *refcon, io_iterator_t it) {
    drainIterator(it);
    NSLog(@"external video link down (IOKit)");
    mirrorNow(); // tears down the virtual display immediately
    checkStaleAfterLinkDown();
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (!NSClassFromString(@"CGVirtualDisplayDescriptor")) {
            NSLog(@"CGVirtualDisplay API unavailable");
            return 1;
        }
        if (argc >= 3) {
            gLW = (unsigned int)atoi(argv[1]);
            gLH = (unsigned int)atoi(argv[2]);
        }
        if (argc >= 4)
            gVendor = (uint32_t)strtoul(argv[3], NULL, 0);
        NSLog(@"UI will look like %ux%u (framebuffer %ux%u); virtual display "
              @"created on demand when physical display is online",
              gLW, gLH, gLW * 2, gLH * 2);


        // Opt out of App Nap: as a windowless background agent we are a
        // prime timer-coalescing victim -- observed in the wild as the 10s
        // poll silently never firing again after days of sleep/wake cycles,
        // leaving a phantom virtual display behind when the physical
        // display disconnected. (Also: ProcessType=Interactive in the
        // launchd plist, and DISPATCH_TIMER_STRICT below.)
        static id activity; // hold the assertion for process lifetime
        activity = [[NSProcessInfo processInfo]
            beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                              reason:@"display watchdog must keep polling"];

        signal(SIGINT, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t sigint = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
        dispatch_source_t sigterm = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
        void (^bail)(void) = ^{ unmirror(); exit(0); };
        dispatch_source_set_event_handler(sigint, bail);
        dispatch_source_set_event_handler(sigterm, bail);
        dispatch_resume(sigint);
        dispatch_resume(sigterm);

        CGDisplayRegisterReconfigurationCallback(reconfigCB, NULL);
        // Instant, never-stale external link (dis)connect events.
        IONotificationPortRef np = IONotificationPortCreate(kIOMainPortDefault);
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           IONotificationPortGetRunLoopSource(np),
                           kCFRunLoopDefaultMode);
        static io_iterator_t upIt, downIt; // live for process lifetime
        if (IOServiceAddMatchingNotification(np, kIOFirstMatchNotification,
                                             externalLinkMatching(),
                                             linkAppeared, NULL,
                                             &upIt) == KERN_SUCCESS)
            drainIterator(upIt); // arm; current state handled below
        else
            NSLog(@"IOKit link-up notification unavailable");
        if (IOServiceAddMatchingNotification(np, kIOTerminatedNotification,
                                             externalLinkMatching(),
                                             linkGone, NULL,
                                             &downIt) == KERN_SUCCESS)
            drainIterator(downIt);
        else
            NSLog(@"IOKit link-down notification unavailable");
        mirrorNow();
        // Belt and braces: reconfiguration callbacks have proven flaky
        // across login sessions, so also poll (cheap no-op when all good).
        // DISPATCH_TIMER_STRICT: no coalescing/deferral -- see App Nap
        // note above; a lazily-coalesced watchdog is no watchdog.
        dispatch_source_t poll = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
            dispatch_get_main_queue());
        // First poll only after 10s: mirrorNow() above already ran, and an
        // immediate poll would re-enter before the fresh virtual display
        // has published its modes, mirroring without the atomic mode setup.
        dispatch_source_set_timer(poll,
                                  dispatch_time(DISPATCH_TIME_NOW,
                                                10 * NSEC_PER_SEC),
                                  10 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(poll, ^{ mirrorNow(); });
        dispatch_resume(poll);
        // NB: must be CFRunLoopRun, NOT dispatch_main() --
        // CGDisplayRegisterReconfigurationCallback delivers via CFRunLoop
        // (and the main runloop drains the main GCD queue too).
        CFRunLoopRun();
    }
    return 0;
}
