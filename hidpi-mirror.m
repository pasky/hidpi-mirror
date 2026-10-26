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

// YES unless some physical (non-virtual) online display is awake. While
// the displays sleep (incl. dark wakes), WindowServer reports the Dell as
// unmirrored, but can't reconfigure anything: transactions block 10s+
// and fail (err 1014), often spanning system sleep. It restores the
// saved arrangement on wake by itself, so just stay out of its way.
static BOOL displaysAsleep(void) {
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return YES;
    for (uint32_t i = 0; i < n; i++)
        if (ids[i] != gVirtualID && !CGDisplayIsAsleep(ids[i])) return NO;
    return YES;
}

// When WindowServer fails to restore the saved arrangement and we have to
// re-establish the mirror ourselves (e.g. after a messy reconnect with
// err 1014 transactions), the built-in display ends up main -- reclaim
// the main role for the mirror set. Translate the WHOLE arrangement so
// the virtual display lands on (0,0): setting just one display's origin
// is silently normalized away. Separate transaction after the mirror.
static void claimMain(void) {
    CGRect vb = CGDisplayBounds(gVirtualID);
    int32_t dx = (int32_t)vb.origin.x, dy = (int32_t)vb.origin.y;
    if (dx == 0 && dy == 0) return; // already main
    CGDirectDisplayID ids[16];
    uint32_t n = 0;
    if (CGGetOnlineDisplayList(16, ids, &n) != kCGErrorSuccess) return;
    CGDisplayConfigRef cfg;
    if (CGBeginDisplayConfiguration(&cfg) != kCGErrorSuccess) return;
    for (uint32_t i = 0; i < n; i++) {
        if (CGDisplayMirrorsDisplay(ids[i]) != kCGNullDirectDisplay)
            continue; // mirror followers inherit their master's origin
        CGRect b = CGDisplayBounds(ids[i]);
        if (CGConfigureDisplayOrigin(cfg, ids[i], (int32_t)b.origin.x - dx,
                                     (int32_t)b.origin.y - dy) !=
            kCGErrorSuccess) {
            // Never persist a partial translation (e.g. hot-unplug).
            CGCancelDisplayConfiguration(cfg);
            NSLog(@"claimMain: configuring origin of %u failed", ids[i]);
            return;
        }
    }
    CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigurePermanently);
    NSLog(@"claimMain: shift arrangement by (%d,%d): %s (err=%d)", -dx, -dy,
          err == kCGErrorSuccess ? "OK" : "FAILED", err);
}

// Bumped on every mirror attempt and whenever the Dell is offline or the
// displays sleep, invalidating pending claimMain follow-ups.
static unsigned gMirrorSeq = 0;

static void mirrorNow(void) {
    static BOOL wasOffline = NO, wasAsleep = NO;
    if (displaysAsleep()) {
        gMirrorSeq++;
        if (!wasAsleep) NSLog(@"displays asleep, leaving configuration alone");
        wasAsleep = YES;
        return;
    }
    if (wasAsleep) NSLog(@"displays awake");
    wasAsleep = NO;
    CGDirectDisplayID dell = findDell();
    if (dell == kCGNullDirectDisplay) {
        if (!wasOffline)
            NSLog(@"display not online (KVM switched away?), waiting...");
        wasOffline = YES;
        gMirrorSeq++;
        return;
    }
    wasOffline = NO;
    BOOL mirrored = (CGDisplayMirrorsDisplay(dell) == gVirtualID);
    // NB: CGDisplayCopyDisplayMode can return NULL (CFAutorelease(NULL)
    // would crash), e.g. while the virtual display is the master of a
    // hardware mirror set -- then the Dell reflects the set's mode.
    CGDisplayModeRef curMode = CGDisplayCopyDisplayMode(gVirtualID);
    if (!curMode && mirrored) curMode = CGDisplayCopyDisplayMode(dell);
    BOOL rightMode =
        curMode && CGDisplayModeGetPixelWidth(curMode) == 2 * gLW;
    if (curMode) CFRelease(curMode);
    if (mirrored && rightMode) return; // nothing to do
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
    unsigned seq = ++gMirrorSeq;
    // Claim main only if WE just (re)established the mirror -- not after a
    // mode-only repair -- so manual rearranging is respected otherwise.
    BOOL claim = !mirrored && err == kCGErrorSuccess;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        // Skip if superseded (new attempt, disconnect, display sleep --
        // reconfiguring then blocks and fails) or the mirror didn't take.
        if (claim && seq == gMirrorSeq && !displaysAsleep() &&
            findDell() == dell && CGDisplayMirrorsDisplay(dell) == gVirtualID)
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
    if (flags & kCGDisplayAddFlag) {
        // Display (re)appeared -- e.g. KVM switched back. Give WindowServer
        // a moment to settle, then re-establish the mirror.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ mirrorNow(); });
    }
}

// ---- Watchdog: WindowServer failing to feed our virtual display ----
// Observed after days of sleep/wake/unplug cycles: our virtual display
// instance goes bad and WindowServer logs "VirtualDisplay::clone_update
// failed to copy surface" up to once per frame (120/s), freezing the
// built-in display and never mirroring onto a reconnected Dell. Our own
// CoreGraphics view sees nothing wrong (it goes stale too). A fresh
// process with a fresh virtual display fixes it, so watch WindowServer's
// log and exit -- launchd (KeepAlive) restarts us.
#ifndef WATCHDOG_MATCH // overridable for testing
#define WATCHDOG_MATCH "VirtualDisplay::clone_update failed"
#endif
static NSTask *gLogTask = nil;
static CFAbsoluteTime gStartTime;

static void watchdogHit(void) {
    static CFAbsoluteTime windowStart = 0;
    static int hits = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - windowStart > 10) { windowStart = now; hits = 0; }
    // Never healthy, but require a burst (and a minimum uptime, so a
    // persistent problem can't turn into a tight restart loop).
    if (++hits < 10 || now - gStartTime < 60) return;
    NSLog(@"watchdog: WindowServer keeps failing to update our virtual "
          @"display (" WATCHDOG_MATCH "), restarting");
    // No unmirror(): reconfiguring may block; exiting destroys the
    // virtual display and with it the mirror.
    exit(3);
}

static void startWatchdog(void) {
    NSTask *t = [[NSTask alloc] init];
    t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/log"];
    t.arguments = @[ @"stream", @"--style", @"compact", @"--predicate",
        @"process == \"WindowServer\" AND eventMessage CONTAINS \""
        WATCHDOG_MATCH "\"" ];
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = [NSFileHandle fileHandleWithNullDevice];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (!d.length) { h.readabilityHandler = nil; return; } // EOF
        // Count matching lines (skips log stream's "Filtering..." header).
        NSString *s = [[NSString alloc] initWithData:d
                                            encoding:NSUTF8StringEncoding];
        NSUInteger n = 0;
        for (NSString *l in [s componentsSeparatedByString:@"\n"])
            if ([l containsString:@"WindowServer"] &&
                [l containsString:@WATCHDOG_MATCH]) n++;
        if (n) dispatch_async(dispatch_get_main_queue(), ^{
            for (NSUInteger i = 0; i < n; i++) watchdogHit();
        });
    };
    t.terminationHandler = ^(NSTask *task) {
        NSLog(@"watchdog: log stream exited (%d), restarting it in 10s",
              task.terminationStatus);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{ startWatchdog(); });
    };
    NSError *err = nil;
    if (![t launchAndReturnError:&err]) {
        NSLog(@"watchdog: can't run log stream: %@", err);
        return;
    }
    gLogTask = t;
}

// Don't leave an orphaned log stream behind when we exit.
static void stopWatchdog(void) {
    NSTask *t = gLogTask;
    gLogTask = nil;
    if (t.running) { t.terminationHandler = nil; [t terminate]; }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        CGVirtualDisplayDescriptor *desc =
            [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        if (!desc) { NSLog(@"CGVirtualDisplay API unavailable"); return 1; }
        if (argc >= 3) {
            gLW = (unsigned int)atoi(argv[1]);
            gLH = (unsigned int)atoi(argv[2]);
        }
        if (argc >= 4)
            gVendor = (uint32_t)strtoul(argv[3], NULL, 0);
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
        desc.terminationHandler = ^(id a, id b) {
            NSLog(@"virtual display terminated");
            exit(0);
        };

        gVirtual = [[NSClassFromString(@"CGVirtualDisplay") alloc]
                       initWithDescriptor:desc];
        if (!gVirtual) { NSLog(@"failed to create virtual display"); return 1; }
        gVirtualID = gVirtual.displayID;

        CGVirtualDisplaySettings *settings =
            [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        settings.hiDPI = 1;
        // Offer exactly ONE mode: the desired "looks like" size at 2x.
        // This way neither macOS nor a stray click can pick a wrong mode.
        // Full mode list (macOS only synthesizes proper HiDPI variants with
        // a rich list topped by maxPixels); the desired one is selected
        // explicitly in setHiDPIMode().
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
        NSLog(@"UI will look like %ux%u (framebuffer %ux%u)", gLW, gLH, gLW*2, gLH*2);
        if (![gVirtual applySettings:settings]) {
            NSLog(@"applySettings failed");
            return 1;
        }
        NSLog(@"virtual display up, id=%u", gVirtualID);

        // Opt out of App Nap: as a windowless background agent we are a
        // prime timer-coalescing victim -- observed in the wild as the 10s
        // poll silently never firing again after days of sleep/wake
        // cycles. (Also: ProcessType=Interactive in the launchd plist,
        // and DISPATCH_TIMER_STRICT below.)
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

        gStartTime = CFAbsoluteTimeGetCurrent();
        atexit(stopWatchdog);
        startWatchdog();

        CGDisplayRegisterReconfigurationCallback(reconfigCB, NULL);
        mirrorNow();
        // Belt and braces: reconfiguration callbacks have proven flaky
        // across login sessions, so also poll (cheap no-op when all good).
        dispatch_source_t poll = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT,
            dispatch_get_main_queue());
        dispatch_source_set_timer(poll,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
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
