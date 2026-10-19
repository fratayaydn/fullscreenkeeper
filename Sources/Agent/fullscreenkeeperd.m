// fullscreenkeeperd: remembers native full screen across app launches.
// Only launch restores use AX observers. Space transitions handle normal recording.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <os/log.h>
#include <sys/stat.h>
#include "Policy.h"
#import "Updater.h"

#define PREFS_DOMAIN CFSTR("io.github.fratayaydn.fullscreenkeeper")
#define KEY_APPLICATIONS CFSTR("Applications")
#define KEY_IGNORED_APPLICATIONS CFSTR("IgnoredApplications")
#define AGENT_PLIST @"io.github.fratayaydn.fullscreenkeeper.agent.plist"
#define UPDATER_PLIST @"io.github.fratayaydn.fullscreenkeeper.updater.plist"
static NSString *const SettingsChanged = @"io.github.fratayaydn.fullscreenkeeper.SettingsChanged";
static NSString *const StatusChanged = @"io.github.fratayaydn.fullscreenkeeper.StatusChanged";
static NSString *const StatusRequest = @"io.github.fratayaydn.fullscreenkeeper.StatusRequest";
static NSString *const StatusReply = @"io.github.fratayaydn.fullscreenkeeper.StatusReply";

// ServiceManagement is loaded only when the app is removed.
@interface NSObject (SMAppService)
+ (id)agentServiceWithPlistName:(NSString *)name;
- (BOOL)unregisterAndReturnError:(NSError **)error;
@end

@interface RestoreSession : NSObject {
@public
    NSRunningApplication *app;
    AXUIElementRef element;
    AXObserverRef observer;
    AXUIElementRef target;
    RestorePolicy policy;
    NSMutableArray<dispatch_block_t> *checks;
    dispatch_block_t readBack;
    dispatch_block_t expiry;
}
- (void)stop;
@end

@implementation RestoreSession
- (void)stop {
    for (dispatch_block_t check in checks) dispatch_block_cancel(check);
    if (readBack) dispatch_block_cancel(readBack);
    if (expiry) dispatch_block_cancel(expiry);
    checks = nil;
    readBack = nil;
    expiry = nil;
    if (observer) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
        CFRelease(observer);
        observer = NULL;
    }
    if (target) { CFRelease(target); target = NULL; }
    if (element) { CFRelease(element); element = NULL; }
}
- (void)dealloc { [self stop]; }
@end

@interface SpaceSeries : NSObject {
@public
    NSRunningApplication *app;
    NSMutableArray<dispatch_block_t> *checks;
}
- (void)stop;
@end

@implementation SpaceSeries
- (void)stop {
    for (dispatch_block_t check in checks) dispatch_block_cancel(check);
    checks = nil;
}
- (void)dealloc { [self stop]; }
@end

static NSDictionary *gApplications;
static NSDictionary *gIgnoredApplications;
static NSMutableDictionary<NSNumber *, RestoreSession *> *gRestores;
static NSMutableDictionary<NSNumber *, SpaceSeries *> *gSpaceChecks;
static NSMutableDictionary<NSNumber *, NSNumber *> *gLastSpaceChanges;
// A failed restore cannot teach a windowed launch as a deliberate exit from full screen.
static NSMutableDictionary<NSNumber *, NSRunningApplication *> *gProtected;
static id gActivationObserver;
static id gTerminationObserver;
static BOOL gTrusted;
static pid_t gPreviousSpacePID;
static dispatch_source_t gBundleWatch;
static char gExecutable[PATH_MAX];
static double now(void) { return NSProcessInfo.processInfo.systemUptime; }
static void updateTerminationObserver(void);

static os_log_t agentLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("io.github.fratayaydn.fullscreenkeeper", "agent"); });
    return log;
}

#pragma mark - Accessibility

static BOOL ignored(NSString *bundleID) {
    return bundleID.length && gIgnoredApplications[bundleID] != nil;
}

static BOOL eligible(NSRunningApplication *app) {
    return app && !app.terminated && app.activationPolicy == NSApplicationActivationPolicyRegular &&
           app.bundleIdentifier.length && !ignored(app.bundleIdentifier) &&
           ![app.bundleIdentifier isEqualToString:(__bridge NSString *)PREFS_DOMAIN];
}

static id attribute(AXUIElementRef element, CFStringRef key, AXError *failure) {
    CFTypeRef value = NULL;
    AXError error = AXUIElementCopyAttributeValue(element, key, &value);
    if (error != kAXErrorSuccess) {
        if (failure && *failure == kAXErrorSuccess) *failure = error;
        if (value) CFRelease(value);
        return nil;
    }
    return CFBridgingRelease(value);
}

static WindowState booleanAttribute(AXUIElementRef element, CFStringRef key, AXError *failure) {
    id value = attribute(element, key, failure);
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return StateUnknown;
    return [value boolValue] ? StateFullscreen : StateWindowed;
}

// Nonstandard and minimized windows do not contribute to the app's full-screen state.
static WindowState windowState(AXUIElementRef window, BOOL *standard, AXError *failure) {
    *standard = NO;
    id subrole = attribute(window, kAXSubroleAttribute, failure);
    if (![subrole isKindOfClass:[NSString class]]) return StateUnknown;
    if (![subrole isEqualToString:(__bridge NSString *)kAXStandardWindowSubrole]) return StateWindowed;
    WindowState minimized = booleanAttribute(window, kAXMinimizedAttribute, failure);
    if (minimized == StateUnknown) return StateUnknown;
    if (minimized == StateFullscreen) return StateWindowed;
    *standard = YES;
    return booleanAttribute(window, CFSTR("AXFullScreen"), failure);
}

static NSString *rawBoolean(id value, AXError error) {
    if (error != kAXErrorSuccess) return [NSString stringWithFormat:@"%d", error];
    if (!value || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID()) return @"invalid";
    return [value boolValue] ? @"true" : @"false";
}

// Read diagnostic attributes even for nonstandard/minimized windows, without changing their state rules.
static WindowState loggedWindowState(AXUIElementRef window, NSRunningApplication *app, const char *phase,
                                     NSUInteger index, BOOL *standard, AXError *failure) {
    AXError subroleError = kAXErrorSuccess, minimizedError = kAXErrorSuccess, fullscreenError = kAXErrorSuccess;
    id subrole = attribute(window, kAXSubroleAttribute, &subroleError);
    id minimized = attribute(window, kAXMinimizedAttribute, &minimizedError);
    id fullscreen = attribute(window, CFSTR("AXFullScreen"), &fullscreenError);
    os_log_debug(agentLog(), "%{public}s pid=%d window=%lu subrole=%{public}@ fullscreen=%{public}@ minimized=%{public}@",
                phase, app.processIdentifier, (unsigned long)index,
                [subrole isKindOfClass:[NSString class]] ? subrole : [NSString stringWithFormat:@"%d", subroleError],
                rawBoolean(fullscreen, fullscreenError), rawBoolean(minimized, minimizedError));
    *standard = NO;
    if (*failure == kAXErrorSuccess) *failure = subroleError;
    if (![subrole isKindOfClass:[NSString class]]) return StateUnknown;
    if (![subrole isEqualToString:(__bridge NSString *)kAXStandardWindowSubrole]) return StateWindowed;
    if (*failure == kAXErrorSuccess) *failure = minimizedError;
    if (minimizedError != kAXErrorSuccess || !minimized ||
        CFGetTypeID((__bridge CFTypeRef)minimized) != CFBooleanGetTypeID()) return StateUnknown;
    if ([minimized boolValue]) return StateWindowed;
    *standard = YES;
    if (*failure == kAXErrorSuccess) *failure = fullscreenError;
    if (fullscreenError != kAXErrorSuccess || !fullscreen ||
        CFGetTypeID((__bridge CFTypeRef)fullscreen) != CFBooleanGetTypeID()) return StateUnknown;
    return [fullscreen boolValue] ? StateFullscreen : StateWindowed;
}

static WindowState applicationState(NSRunningApplication *app, const char *phase) {
    if (!eligible(app)) return StateUnknown;
    AXError failure = kAXErrorSuccess;
    AXUIElementRef element = AXUIElementCreateApplication(app.processIdentifier);
    id windows = attribute(element, kAXWindowsAttribute, &failure);
    CFRelease(element);
    BOOL found = [windows isKindOfClass:[NSArray class]];
    NSUInteger standardCount = 0;
    WindowState result = found ? StateWindowed : StateUnknown;
    BOOL debug = os_log_type_enabled(agentLog(), OS_LOG_TYPE_DEBUG);
    NSUInteger index = 0;
    for (id window in found ? windows : @[]) {
        NSUInteger windowIndex = index++;
        if (CFGetTypeID((__bridge CFTypeRef)window) != AXUIElementGetTypeID()) {
            if (debug && windowIndex < 4)
                os_log_debug(agentLog(), "%{public}s pid=%d window=%lu invalid", phase, app.processIdentifier, (unsigned long)windowIndex);
            result = combineWindows(result, StateUnknown);
            continue;
        }
        BOOL standard;
        WindowState state = debug && windowIndex < 4
            ? loggedWindowState((__bridge AXUIElementRef)window, app, phase, windowIndex, &standard, &failure)
            : windowState((__bridge AXUIElementRef)window, &standard, &failure);
        result = combineWindows(result, state);
        if (standard) standardCount++;
    }
    if (!standardCount || app.terminated) result = StateUnknown;
    os_log_debug(agentLog(), "%{public}s pid=%d bundle=%{public}@ windows=%ld standard=%lu fullscreen=%d state=%d ax=%d",
                phase, app.processIdentifier, app.bundleIdentifier, found ? (long)[windows count] : -1L,
                (unsigned long)standardCount, result == StateFullscreen, result, failure);
    return result;
}

#pragma mark - Settings and recording

static void saveApplications(NSDictionary *records) {
    gApplications = records;
    CFPreferencesSetAppValue(KEY_APPLICATIONS, (__bridge CFDictionaryRef)records, PREFS_DOMAIN);
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:StatusChanged object:nil userInfo:nil deliverImmediately:YES];
}

static void loadSettings(void) {
    for (NSNumber *pid in gProtected.allKeys)
        if (gProtected[pid].terminated) [gProtected removeObjectForKey:pid];
    CFPreferencesAppSynchronize(PREFS_DOMAIN);
    id ignoredValue = CFBridgingRelease(CFPreferencesCopyAppValue(KEY_IGNORED_APPLICATIONS, PREFS_DOMAIN));
    gIgnoredApplications = [ignoredValue isKindOfClass:[NSDictionary class]] ? ignoredValue : @{};
    id value = CFBridgingRelease(CFPreferencesCopyAppValue(KEY_APPLICATIONS, PREFS_DOMAIN));
    gApplications = [value isKindOfClass:[NSDictionary class]] ? value : @{};
    NSMutableDictionary *records = [gApplications mutableCopy];
    for (NSString *bundleID in gApplications) {
        id entry = gApplications[bundleID];
        id fullscreen = [entry isKindOfClass:[NSDictionary class]] ? entry[@"fullscreen"] : nil;
        if (ignored(bundleID) || ![fullscreen isKindOfClass:[NSNumber class]] || ![fullscreen boolValue])
            [records removeObjectForKey:bundleID];
    }
    if (records.count != gApplications.count) saveApplications(records);
}

static WindowState remembered(NSString *bundleID) {
    if (ignored(bundleID)) return StateWindowed;
    id entry = gApplications[bundleID];
    return entry ? StateFullscreen : StateWindowed;
}

static void saveState(NSRunningApplication *app, WindowState state) {
    if (app.terminated || state == StateUnknown) return;
    loadSettings();  // merge with entries forgotten in the settings window
    if (!eligible(app)) return;
    if (remembered(app.bundleIdentifier) == state) return;
    NSMutableDictionary *records = [gApplications mutableCopy];
    if (state == StateFullscreen)
        records[app.bundleIdentifier] = @{ @"name": app.localizedName ?: app.bundleIdentifier, @"fullscreen": @YES };
    else
        [records removeObjectForKey:app.bundleIdentifier];
    if (app.terminated) return;
    saveApplications(records);
    os_log_info(agentLog(), "%{public}s pid=%d bundle=%{public}@",
                state == StateFullscreen ? "save" : "remove", app.processIdentifier, app.bundleIdentifier);
}

static WindowState recordApplication(NSRunningApplication *app, BOOL startup, const char *phase) {
    if (!gTrusted || !eligible(app)) {
        os_log_debug(agentLog(), "%{public}s pid=%d bundle=%{public}@ skip", phase, app.processIdentifier, app.bundleIdentifier);
        return StateUnknown;
    }
    NSNumber *pid = @(app.processIdentifier);
    if (gProtected[pid].terminated) [gProtected removeObjectForKey:pid];
    if (gRestores[pid]) {
        os_log_debug(agentLog(), "%{public}s pid=%d bundle=%{public}@ restoring", phase, app.processIdentifier, app.bundleIdentifier);
        return StateUnknown;
    }
    WindowState observed = applicationState(app, phase);
    if (app.terminated) { [gProtected removeObjectForKey:pid]; return StateUnknown; }
    if (observed == StateFullscreen) [gProtected removeObjectForKey:pid];
    WindowState saved = remembered(app.bundleIdentifier);
    RecordAction action = startup ? startupRecordAction(saved, observed)
                                 : recordAction(saved, observed, NO, gProtected[pid] != nil);
    if (action == RecordFullscreen || action == RecordWindowed) saveState(app, observed);
    return observed;
}

static void stopSpaceSeries(NSNumber *pid) {
    [gSpaceChecks[pid] stop];
    [gSpaceChecks removeObjectForKey:pid];
    updateTerminationObserver();
}

static void updateTerminationObserver(void) {
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    if (!gSpaceChecks.count && !gRestores.count) {
        if (gTerminationObserver) [center removeObserver:gTerminationObserver];
        gTerminationObserver = nil;
        return;
    }
    if (gTerminationObserver) return;
    gTerminationObserver = [center addObserverForName:NSWorkspaceDidTerminateApplicationNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            @autoreleasepool {
                NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                if (!app) return;
                NSNumber *pid = @(app.processIdentifier);
                if (gSpaceChecks[pid] || remembered(app.bundleIdentifier) == StateFullscreen) {
                    NSNumber *lastSpace = gLastSpaceChanges[pid];
                    os_log_debug(agentLog(), "terminate pid=%d bundle=%{public}@ series=%d saved=%d since-space=%.3f",
                                app.processIdentifier, app.bundleIdentifier, gSpaceChecks[pid] != nil,
                                remembered(app.bundleIdentifier) == StateFullscreen,
                                lastSpace ? now() - lastSpace.doubleValue : -1.0);
                }
                [gLastSpaceChanges removeObjectForKey:pid];
                stopSpaceSeries(pid);
            }
        }];
}

static void recordSpaceApplication(NSRunningApplication *app, BOOL seriesAllowed, double changedAt) {
    NSNumber *pid = @(app.processIdentifier);
    stopSpaceSeries(pid);
    WindowState state = recordApplication(app, NO, "now");
    if (!seriesAllowed || state != StateUnknown || !gTrusted || !eligible(app)) return;
    SpaceSeries *series = [SpaceSeries new];
    series->app = app;
    series->checks = [NSMutableArray array];
    gSpaceChecks[pid] = series;
    updateTerminationObserver();
    __weak SpaceSeries *weakSeries = series;
    for (NSNumber *offset in @[@0.15, @0.35, @0.6, @1.0]) {
        dispatch_block_t check = dispatch_block_create(0, ^{
            @autoreleasepool {
                SpaceSeries *s = weakSeries;
                if (!s || gSpaceChecks[pid] != s) return;
                os_log_debug(agentLog(), "series pid=%d offset=%.2f since-space=%.3f",
                            s->app.processIdentifier, offset.doubleValue, now() - changedAt);
                WindowState observed = recordApplication(s->app, NO, "series");
                if (observed != StateUnknown || s->app.terminated || offset.doubleValue == 1.0) stopSpaceSeries(pid);
            }
        });
        [series->checks addObject:check];
        double delay = MAX(0, changedAt + offset.doubleValue - now());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), check);
    }
}

static void recordSpaceChange(BOOL transition) {
    double changedAt = now();
    NSRunningApplication *app = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSNumber *pid = @(app.processIdentifier);
    if (app) gLastSpaceChanges[pid] = @(changedAt);
    BOOL seriesAllowed = transition || gPreviousSpacePID == app.processIdentifier;
    BOOL query = transition || shouldQuerySpaceChange(gPreviousSpacePID, app.processIdentifier,
                                                     remembered(app.bundleIdentifier));
    gPreviousSpacePID = app.processIdentifier;
    os_log_debug(agentLog(), "space pid=%d bundle=%{public}@ %{public}s",
                app.processIdentifier, app.bundleIdentifier, query ? "query" : "skip");
    if (!query) return;
    recordSpaceApplication(app, seriesAllowed, changedAt);
}

static void spaceChanged(void) { recordSpaceChange(NO); }

#pragma mark - WindowServer Space events

typedef void (*ConnectionNotifyProc)(uint32_t type, void *data, size_t length, void *context, int cid);
static CGEventRef (*gNextWindowServerEvent)(int cid);
static int gWindowServerConnection;
// Only the main queue reads or writes these flags, including after setup falls back.
static BOOL gWindowServerSpaceEvents;
static BOOL gWindowServerTransitions;
static BOOL gSpaceChangePending;
static int (*gSpaceGetType)(int cid, uint64_t sid);
// Main-queue ownership records retain the original process, so PID reuse cannot target a new app.
@interface FullscreenSpace : NSObject {
@public
    NSRunningApplication *app;
    pid_t pid;
    NSString *bundleID;
}
@end
@implementation FullscreenSpace
@end
static NSMutableDictionary<NSNumber *, FullscreenSpace *> *gFullscreenSpaces;

static void collectSpaceOwnerPIDs(id value, NSMutableSet<NSNumber *> *pids) {
    if ([value isKindOfClass:[NSArray class]]) {
        for (id pid in value) collectSpaceOwnerPIDs(pid, pids);
    } else if ([value isKindOfClass:[NSNumber class]]) {
        long long pid = [value longLongValue];
        if (pid > 0 && pid <= INT_MAX) [pids addObject:@(pid)];
    }
}

static NSRunningApplication *startupSpaceOwner(NSDictionary *info) {
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set];
    collectSpaceOwnerPIDs(info[@"pid"], pids);
    id layout = info[@"TileLayoutManager"];
    if ([layout isKindOfClass:[NSDictionary class]]) {
        collectSpaceOwnerPIDs(layout[@"pid"], pids);
        id tiles = layout[@"TileSpaces"];
        if ([tiles isKindOfClass:[NSArray class]])
            for (id tile in tiles)
                if ([tile isKindOfClass:[NSDictionary class]]) collectSpaceOwnerPIDs(tile[@"pid"], pids);
    }
    // Split View has multiple owners. Use the frontmost participant, or leave it unknown.
    NSRunningApplication *frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
    NSRunningApplication *owner = [pids containsObject:@(frontmost.processIdentifier)] ? frontmost :
        (pids.count == 1 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pids.anyObject.intValue] : nil);
    // Retain a known ignored owner so its destruction cannot fall back to a different app.
    return eligible(owner) || ignored(owner.bundleIdentifier) ? owner : nil;
}

static void seedFullscreenSpaces(void *skyLight) {
    CFArrayRef (*copyManagedDisplaySpaces)(int) = dlsym(skyLight, "SLSCopyManagedDisplaySpaces");
    id displays = copyManagedDisplaySpaces ? CFBridgingRelease(copyManagedDisplaySpaces(gWindowServerConnection)) : nil;
    NSMutableSet<NSNumber *> *found = [NSMutableSet set];
    if ([displays isKindOfClass:[NSArray class]]) {
        for (id display in displays) {
            if (![display isKindOfClass:[NSDictionary class]]) continue;
            id spaces = display[@"Spaces"];
            if (![spaces isKindOfClass:[NSArray class]]) continue;
            for (id info in spaces) {
                if (![info isKindOfClass:[NSDictionary class]]) continue;
                id identifier = info[@"id64"] ?: info[@"ManagedSpaceID"];
                if (![identifier isKindOfClass:[NSNumber class]]) continue;
                uint64_t sid = [identifier unsignedLongLongValue];
                if (!sid) continue;
                int type = gSpaceGetType ? gSpaceGetType(gWindowServerConnection, sid) : -1;
                id dictionaryType = info[@"type"];
                if (type < 0 && [dictionaryType isKindOfClass:[NSNumber class]]) type = [dictionaryType intValue];
                if (type != 4) continue;
                NSNumber *key = @(sid);
                [found addObject:key];
                if (gFullscreenSpaces[key]) continue;
                if (!gFullscreenSpaces) gFullscreenSpaces = [NSMutableDictionary dictionary];
                FullscreenSpace *space = [FullscreenSpace new];
                space->app = startupSpaceOwner(info);
                space->pid = space->app.processIdentifier;
                space->bundleID = [space->app.bundleIdentifier copy];
                gFullscreenSpaces[key] = space;
            }
        }
    }
    os_log_debug(agentLog(), "fullscreen startup spaces=%lu", (unsigned long)found.count);
}

static void recordFullscreenSpace(uint32_t type, uint64_t sid, NSRunningApplication *frontmost) {
    NSNumber *key = @(sid);
    if (type == 1327) {
        if (!gTrusted || !eligible(frontmost)) return;
        if (!gFullscreenSpaces) gFullscreenSpaces = [NSMutableDictionary dictionary];
        FullscreenSpace *space = [FullscreenSpace new];
        space->app = frontmost;
        space->pid = frontmost.processIdentifier;
        space->bundleID = [frontmost.bundleIdentifier copy];
        gFullscreenSpaces[key] = space;
        os_log_debug(agentLog(), "fullscreen create sid=%llu pid=%d bundle=%{public}@",
                     (unsigned long long)sid, space->pid, space->bundleID);
        NSNumber *pid = @(space->pid);
        gLastSpaceChanges[pid] = @(now());
        stopSpaceSeries(pid);
        if (gRestores[pid]) return;
        [gProtected removeObjectForKey:pid];
        saveState(frontmost, StateFullscreen);
        return;
    }
    FullscreenSpace *space = gFullscreenSpaces[key];
    if (!space) return;
    [gFullscreenSpaces removeObjectForKey:key];
    os_log_debug(agentLog(), "fullscreen destroy sid=%llu pid=%d bundle=%{public}@",
                 (unsigned long long)sid, space->pid, space->bundleID);
    if (space->app)
        for (FullscreenSpace *other in gFullscreenSpaces.allValues) {
            if (other->pid == space->pid && [other->bundleID isEqualToString:space->bundleID]) return;
        }
    NSRunningApplication *app = space->app ?: frontmost;
    double changedAt = now();
    if (app) gLastSpaceChanges[@(app.processIdentifier)] = @(changedAt);
    recordSpaceApplication(app, YES, changedAt);
}

static void windowServerSpaceChanged(uint32_t type, void *data, size_t length, void *context, int cid) {
    (void)context;
    @autoreleasepool {
        BOOL typed = gSpaceGetType && (type == 1327 || type == 1328);
        uint64_t sid = 0;
        NSRunningApplication *frontmost = nil;
        if (typed) {
            if (!data || length < sizeof(sid)) return;
            // Read the type while the created Space exists; never query a destroyed Space.
            memcpy(&sid, data, sizeof(sid));
            if (type == 1327) {
                if (gSpaceGetType(cid, sid) != 4) return;
            }
            frontmost = NSWorkspace.sharedWorkspace.frontmostApplication;
        } else {
            os_log_debug(agentLog(), "windowserver event type=%u length=%zu", type, length);
        }
        if (type != 1327 && type != 1328 && type != 1401) return;
        // Policy work stays on the main queue; never retain WindowServer's payload.
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!gWindowServerSpaceEvents) return;
            // A partially registered transition path must not duplicate fallback Space changes.
            if (gWindowServerTransitions ? type == 1401 : type != 1401) return;
            if (typed) {
                recordFullscreenSpace(type, sid, frontmost);
                return;
            }
            if (gSpaceChangePending) return;
            gSpaceChangePending = YES;
            int64_t delay = (gWindowServerTransitions ? 100 : 50) * NSEC_PER_MSEC;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
                @autoreleasepool {
                    gSpaceChangePending = NO;
                    if (gWindowServerSpaceEvents) recordSpaceChange(gWindowServerTransitions);
                }
            });
        });
    }
}

static void pumpWindowServerEvents(CFMachPortRef port, void *message, CFIndex size, void *context) {
    (void)port; (void)message; (void)size; (void)context;
    @autoreleasepool {
        CGEventRef event;
        while ((event = gNextWindowServerEvent(gWindowServerConnection))) CFRelease(event);
    }
}

static BOOL appKitSpaceEventsFallback(NSString *reason) {
    os_log_info(agentLog(), "space events: appkit fallback (%{public}@)", reason);
    return NO;
}

static BOOL startWindowServerSpaceEvents(void) {
    // Keep the images loaded for the lifetime of the function pointers and registered callback.
    void *skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL);
    if (!skyLight) return appKitSpaceEventsFallback([NSString stringWithFormat:@"SkyLight load failed: %s", dlerror()]);
    void *coreFoundation = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_NOW | RTLD_LOCAL);
    if (!coreFoundation)
        return appKitSpaceEventsFallback([NSString stringWithFormat:@"CoreFoundation load failed: %s", dlerror()]);
    const char *names[] = { "SLSMainConnectionID", "SLSRegisterConnectionNotifyProc", "SLSGetEventPort",
                           "SLEventCreateNextEvent", "_CFMachPortSetOptions" };
    void *symbols[5];
    for (size_t i = 0; i < 5; i++) {
        symbols[i] = dlsym(i == 4 ? coreFoundation : skyLight, names[i]);
        if (!symbols[i]) return appKitSpaceEventsFallback([NSString stringWithFormat:@"missing symbol %s", names[i]]);
    }
    int (*mainConnection)(void) = symbols[0];
    CGError (*registerNotify)(int, ConnectionNotifyProc, uint32_t, void *) = symbols[1];
    CGError (*getEventPort)(int, mach_port_t *) = symbols[2];
    gNextWindowServerEvent = symbols[3];
    void (*setPortOptions)(CFMachPortRef, int) = symbols[4];
    gWindowServerConnection = mainConnection();
    if (gWindowServerConnection <= 0) return appKitSpaceEventsFallback(@"SLSMainConnectionID returned no connection");
    gSpaceGetType = dlsym(skyLight, "SLSSpaceGetType");
    BOOL transitions = YES;
    const uint32_t transitionTypes[] = { 1327, 1328 };
    CGError error;
    for (size_t i = 0; i < sizeof(transitionTypes) / sizeof(transitionTypes[0]); i++) {
        error = registerNotify(gWindowServerConnection, windowServerSpaceChanged, transitionTypes[i], NULL);
        if (error != kCGErrorSuccess) {
            os_log_info(agentLog(), "SLSRegisterConnectionNotifyProc type=%u failed: %d", transitionTypes[i], error);
            transitions = NO;
            break;
        }
    }
    if (!transitions) {
        error = registerNotify(gWindowServerConnection, windowServerSpaceChanged, 1401, NULL);
        if (error != kCGErrorSuccess)
            return appKitSpaceEventsFallback([NSString stringWithFormat:@"SLSRegisterConnectionNotifyProc failed: %d", error]);
    }
    mach_port_t eventPort = MACH_PORT_NULL;
    error = getEventPort(gWindowServerConnection, &eventPort);
    if (error != kCGErrorSuccess || !MACH_PORT_VALID(eventPort))
        return appKitSpaceEventsFallback([NSString stringWithFormat:@"SLSGetEventPort failed: %d, port=%u", error, eventPort]);
    CFMachPortRef port = CFMachPortCreateWithPort(NULL, eventPort, pumpWindowServerEvents, NULL, NULL);
    if (!port) return appKitSpaceEventsFallback(@"CFMachPortCreateWithPort failed");
    setPortOptions(port, 0x40);
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, port, 0);
    if (!source) {
        CFRelease(port);
        return appKitSpaceEventsFallback(@"CFMachPortCreateRunLoopSource failed");
    }
    gWindowServerTransitions = transitions;
    gWindowServerSpaceEvents = YES;
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFRelease(port);
    if (gTrusted) seedFullscreenSpaces(skyLight);
    os_log_info(agentLog(), "space events: windowserver %{public}s", transitions ? "transitions" : "space changes");
    return YES;
}

#pragma mark - Launch restores

static void attemptRestore(RestoreSession *session);

static void finishRestore(RestoreSession *session, BOOL succeeded, const char *reason) {
    NSNumber *pid = @(session->app.processIdentifier);
    if (gRestores[pid] != session) return;
    os_log_info(agentLog(), "restore finish pid=%d bundle=%{public}@ %{public}s attempts=%u",
                session->app.processIdentifier, session->app.bundleIdentifier,
                session->app.terminated ? "terminated" : reason, session->policy.attempts);
    if (session->app.terminated) {
        [gProtected removeObjectForKey:pid];
    } else if (!succeeded && !ignored(session->app.bundleIdentifier)) gProtected[pid] = session->app;
    [session stop];
    [gRestores removeObjectForKey:pid];
    updateTerminationObserver();
    if (!gRestores.count && gActivationObserver) {
        [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:gActivationObserver];
        gActivationObserver = nil;
    }
}

// App switching matters only while a launch restore is waiting for its app to come forward.
static void observeRestoreActivation(void) {
    if (gActivationObserver) return;
    gActivationObserver = [NSWorkspace.sharedWorkspace.notificationCenter
        addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *note) {
            @autoreleasepool {
                NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
                if (!app) return;
                RestoreSession *session = gRestores[@(app.processIdentifier)];
                if (session) attemptRestore(session);
            }
        }];
}

static void scheduleLaunchChecks(RestoreSession *session) {
    session->checks = [NSMutableArray array];
    __weak RestoreSession *weakSession = session;
    for (NSNumber *offset in @[@0.3, @1, @2, @4, @7, @11]) {
        dispatch_block_t check = dispatch_block_create(0, ^{
            @autoreleasepool {
                RestoreSession *s = weakSession;
                if (s) attemptRestore(s);
            }
        });
        [session->checks addObject:check];
        double delay = MAX(0, session->policy.deadline - 15 + offset.doubleValue - now());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), check);
    }
}

static void attemptRestore(RestoreSession *session) {
    NSNumber *pid = @(session->app.processIdentifier);
    if (gRestores[pid] != session) return;
    if (!gTrusted || !eligible(session->app)) { finishRestore(session, NO, "unavailable"); return; }
    if (session->readBack || !restoreDue(&session->policy, now())) {
        os_log_debug(agentLog(), "restore check pid=%d wait", session->app.processIdentifier);
        return;
    }
    BOOL frontmost = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == session->app.processIdentifier;
    id focused = nil;
    WindowState state = StateUnknown;
    Boolean writable = false;
    AXError failure = kAXErrorSuccess;
    if (frontmost && now() < session->policy.deadline && session->policy.attempts < 5) {
        focused = attribute(session->element, kAXFocusedWindowAttribute, &failure);
        if (focused && CFGetTypeID((__bridge CFTypeRef)focused) == AXUIElementGetTypeID()) {
            BOOL standard;
            state = windowState((__bridge AXUIElementRef)focused, &standard, &failure);
            if (!standard) state = StateUnknown;
            if (state == StateWindowed) {
                failure = AXUIElementIsAttributeSettable((__bridge AXUIElementRef)focused, CFSTR("AXFullScreen"), &writable);
                if (failure != kAXErrorSuccess) state = StateUnknown;
            }
        }
    }
    // Check focus again after the AX round trips. Only a real write uses an attempt.
    os_log_debug(agentLog(), "restore check pid=%d bundle=%{public}@ front=%d state=%d writable=%d ax=%d",
                session->app.processIdentifier, session->app.bundleIdentifier, frontmost, state, writable, failure);
    if (session->app.terminated) { finishRestore(session, NO, "terminated"); return; }
    frontmost = frontmost && NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == session->app.processIdentifier;
    RestoreAction action = restoreAttempt(&session->policy, now(), frontmost, state, writable);
    if (action == RestoreComplete || action == RestoreGiveUp) {
        finishRestore(session, action == RestoreComplete, action == RestoreComplete ? "fullscreen" :
                      now() >= session->policy.deadline ? "timeout" : session->policy.attempts >= 5 ? "attempts" : "not writable");
        return;
    }
    if (action == RestoreWrite) {
        if (session->app.terminated) { finishRestore(session, NO, "terminated"); return; }
        AXError error = AXUIElementSetAttributeValue((__bridge AXUIElementRef)focused, CFSTR("AXFullScreen"), kCFBooleanTrue);
        os_log_info(agentLog(), "restore write pid=%d attempt=%u ax=%d", session->app.processIdentifier, session->policy.attempts, error);
        session->target = (AXUIElementRef)CFRetain((__bridge CFTypeRef)focused);
        __weak RestoreSession *weakSession = session;
        session->readBack = dispatch_block_create(0, ^{
            @autoreleasepool {
                RestoreSession *s = weakSession;
                if (!s || gRestores[@(s->app.processIdentifier)] != s) return;
                s->readBack = nil;
                if (!gTrusted || !eligible(s->app)) { finishRestore(s, NO, "unavailable"); return; }
                AXError error = kAXErrorSuccess;
                WindowState result = booleanAttribute(s->target, CFSTR("AXFullScreen"), &error);
                os_log_debug(agentLog(), "restore read-back pid=%d state=%d ax=%d", s->app.processIdentifier, result, error);
                if (s->app.terminated) { finishRestore(s, NO, "terminated"); return; }
                CFRelease(s->target);
                s->target = NULL;
                RestoreAction next = restoreReadBack(&s->policy, now(), result);
                if (next == RestoreComplete || next == RestoreGiveUp)
                    finishRestore(s, next == RestoreComplete, next == RestoreComplete ? "fullscreen" :
                                  now() >= s->policy.deadline ? "timeout" : "attempts");
                else attemptRestore(s);
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), session->readBack);
    }
}

static void windowChanged(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context) {
    (void)observer; (void)element; (void)notification;
    @autoreleasepool { attemptRestore((__bridge RestoreSession *)context); }
}

static void startRestore(NSRunningApplication *app) {
    if (!gTrusted || !eligible(app) || remembered(app.bundleIdentifier) != StateFullscreen) return;
    RestorePolicy policy = restorePolicy(remembered(app.bundleIdentifier), YES, now());
    NSNumber *pid = @(app.processIdentifier);
    RestoreSession *previous = gRestores[pid];
    if (previous && previous->app.terminated) finishRestore(previous, NO, "terminated");
    if (!policy.pending || gRestores[pid]) return;
    RestoreSession *session = [RestoreSession new];
    session->app = app;
    session->policy = policy;
    session->element = AXUIElementCreateApplication(app.processIdentifier);
    gRestores[pid] = session;
    [gLastSpaceChanges removeObjectForKey:pid];  // a newly launched process has not changed Spaces yet
    updateTerminationObserver();
    os_log_info(agentLog(), "restore start pid=%d bundle=%{public}@", app.processIdentifier, app.bundleIdentifier);
    observeRestoreActivation();
    AXError error = AXObserverCreate(app.processIdentifier, windowChanged, &session->observer);
    os_log_debug(agentLog(), "restore observer pid=%d ax=%d", app.processIdentifier, error);
    if (error == kAXErrorSuccess) {
        for (NSString *name in @[(__bridge NSString *)kAXFocusedWindowChangedNotification,
                                 (__bridge NSString *)kAXWindowCreatedNotification,
                                 (__bridge NSString *)kAXMainWindowChangedNotification]) {
            AXError added = AXObserverAddNotification(session->observer, session->element, (__bridge CFStringRef)name, (__bridge void *)session);
            os_log_debug(agentLog(), "restore subscribe pid=%d notification=%{public}@ ax=%d", app.processIdentifier, name, added);
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(session->observer), kCFRunLoopCommonModes);
    }
    __weak RestoreSession *weakSession = session;
    session->expiry = dispatch_block_create(0, ^{
        @autoreleasepool {
            RestoreSession *s = weakSession;
            if (s) finishRestore(s, NO, "timeout");
        }
    });
    double delay = MAX(0, policy.deadline - now());
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), session->expiry);
    scheduleLaunchChecks(session);
    attemptRestore(session);
}

static void settingsChanged(void) {
    loadSettings();
    for (NSNumber *pid in gSpaceChecks.allKeys)
        if (ignored(gSpaceChecks[pid]->app.bundleIdentifier)) stopSpaceSeries(pid);
    for (RestoreSession *session in gRestores.allValues)
        if (remembered(session->app.bundleIdentifier) != StateFullscreen) finishRestore(session, NO, "forgotten");
    for (NSNumber *pid in gProtected.allKeys)
        if (remembered(gProtected[pid].bundleIdentifier) != StateFullscreen) [gProtected removeObjectForKey:pid];
}

#pragma mark - Status

static int printStatus(void) {
    loadSettings();
    __block NSDictionary *reply = nil;
    NSString *request = NSUUID.UUID.UUIDString;
    NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
    id token = [center addObserverForName:StatusReply object:request queue:nil usingBlock:^(NSNotification *note) {
        reply = note.userInfo;
    }];
    [center postNotificationName:StatusRequest object:request userInfo:nil deliverImmediately:YES];
    double deadline = now() + 1;
    while (!reply && now() < deadline) CFRunLoopRunInMode(kCFRunLoopDefaultMode, MAX(0, deadline - now()), true);
    [center removeObserver:token];
    BOOL trusted = reply ? [reply[@"accessibility"] boolValue] : AXIsProcessTrusted();
    printf("Accessibility: %s\n", trusted ? "granted" : "not granted");
    printf("Restore pending: %s\n", reply ? ([reply[@"pending"] boolValue] ? "yes" : "no") : "unknown (agent not responding)");
    printf("Remembered apps:\n");
    if (!gApplications.count) printf("  None\n");
    for (NSString *bundleID in [gApplications.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id entry = gApplications[bundleID];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = [entry[@"name"] isKindOfClass:[NSString class]] ? entry[@"name"] : bundleID;
        printf("  %s (%s): %s\n", name.UTF8String, bundleID.UTF8String,
               remembered(bundleID) == StateFullscreen ? "Full screen" : "Windowed");
    }
    return 0;
}

#pragma mark - App bundle

static BOOL selfPath(char *path, uint32_t size) {
    return _NSGetExecutablePath(path, &size) == 0;
}

// Trust is cached per process. Ask a fresh copy, then let launchd restart us if permission changed.
static void checkPermission(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            char path[PATH_MAX];
            if (!selfPath(path, sizeof(path))) return;
            NSTask *task = [NSTask new];
            task.executableURL = [NSURL fileURLWithPath:@(path)];
            task.arguments = @[@"--check"];
            task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
            task.standardError = NSFileHandle.fileHandleWithNullDevice;
            if (![task launchAndReturnError:NULL]) return;
            [task waitUntilExit];
            if (task.terminationReason != NSTaskTerminationReasonExit) return;
            int status = task.terminationStatus;
            if ((status == 0 || status == 1) && (status == 0) != gTrusted)
                dispatch_async(dispatch_get_main_queue(), ^{ exit(1); });
        }
    });
}

// Remove our login item, as turning off "Enable FullscreenKeeper" does, so nothing is left in Login Items and launchd
// does not start another copy of FullscreenKeeper at the next login.
static void unregisterLoginItem(void) {
    if (!dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", RTLD_NOW)) return;
    // Remove the updater first: unregistering the main job can stop this process immediately.
    for (NSString *plist in @[UPDATER_PLIST, AGENT_PLIST]) {
        NSError *error = nil;
        if (![[NSClassFromString(@"SMAppService") agentServiceWithPlistName:plist] unregisterAndReturnError:&error])
            fprintf(stderr, "fullscreenkeeperd: could not remove %s: %s\n", plist.UTF8String, error.localizedDescription.UTF8String);
    }
}

// FullscreenKeeper.app was moved to the Trash or replaced by an update. An update puts a new copy at the same path within
// moments: exit with an error so launchd starts the new agent. Otherwise the app is gone: remove the login item and
// exit for good (a successful exit is not restarted).
static void appMoved(void) {
    dispatch_source_cancel(gBundleWatch);
    for (int i = 0; i < 10; i++) {
        sleep(1);
        struct stat st;
        if (stat(gExecutable, &st) == 0) {
            fprintf(stderr, "fullscreenkeeperd: FullscreenKeeper.app was updated, restarting\n");
            exit(1);
        }
    }
    fprintf(stderr, "fullscreenkeeperd: FullscreenKeeper.app was removed, exiting\n");
    unregisterLoginItem();  // launchd may stop us right here
    exit(0);
}

// Watch the app bundle through the kernel's event queue: no polling, no wakeups until it moves.
static void watchAppBundle(void) {
    char path[PATH_MAX], resolved[PATH_MAX];
    if (!selfPath(path, sizeof(path)) || !realpath(path, resolved)) return;
    strlcpy(gExecutable, resolved, sizeof(gExecutable));
    char *contents = strstr(resolved, "/Contents/MacOS/");
    if (!contents) return;  // not running from an app bundle
    *contents = 0;
    int fd = open(resolved, O_EVTONLY);
    if (fd < 0) return;
    gBundleWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                          DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE,
                                          dispatch_get_main_queue());
    dispatch_source_set_event_handler(gBundleWatch, ^{ appMoved(); });
    dispatch_source_set_cancel_handler(gBundleWatch, ^{ close(fd); });
    dispatch_resume(gBundleWatch);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc > 1 && !strcmp(argv[1], "--update-check")) {
            BOOL force = NO, install = NO;
            for (int i = 2; i < argc; i++) {
                if (!strcmp(argv[i], "--force")) force = YES;
                else if (!strcmp(argv[i], "--install")) install = YES;
                else return 1;
            }
            return updaterRun(force, install);
        }
        if (argc > 1 && !strcmp(argv[1], "--check")) {
            BOOL trusted = AXIsProcessTrusted();
            puts(trusted ? "granted" : "not granted");
            return trusted ? 0 : 1;
        }
        if (argc > 1 && !strcmp(argv[1], "--prompt")) {
            NSDictionary *options = @{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES };
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
            return 0;
        }
        if (argc > 1 && !strcmp(argv[1], "--status")) return printStatus();
        os_log_info(agentLog(), "agent start");
        gTrusted = AXIsProcessTrusted();
        gPreviousSpacePID = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        gRestores = [NSMutableDictionary dictionary];
        gSpaceChecks = [NSMutableDictionary dictionary];
        gLastSpaceChanges = [NSMutableDictionary dictionary];
        gProtected = [NSMutableDictionary dictionary];
        loadSettings();
        watchAppBundle();
        BOOL appKitSpaceEvents = NO;
        if (gTrusted) {
            appKitSpaceEvents = !startWindowServerSpaceEvents();
            if (appKitSpaceEvents) {
                [NSApplication sharedApplication];
                [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
            }
            os_log_debug(agentLog(), "WindowServer connection is up");
            AXUIElementRef system = AXUIElementCreateSystemWide();
            AXUIElementSetMessagingTimeout(system, 0.25);
            CFRelease(system);
            NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
            [workspace addObserverForName:NSWorkspaceDidLaunchApplicationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                @autoreleasepool { startRestore(note.userInfo[NSWorkspaceApplicationKey]); }
            }];
            if (appKitSpaceEvents) [workspace addObserverForName:NSWorkspaceActiveSpaceDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                (void)note;
                static BOOL receivedSpaceChange;
                if (!receivedSpaceChange) {
                    receivedSpaceChange = YES;
                    os_log_debug(agentLog(), "first Space change received");
                }
                @autoreleasepool { spaceChanged(); }
            }];
        }
        NSString *spaceEventsPath = gWindowServerSpaceEvents ?
            (gWindowServerTransitions ? @"windowserver transitions" : @"windowserver space changes") : @"appkit fallback";
        CFPreferencesSetAppValue(CFSTR("SpaceEventsPath"), (__bridge CFStringRef)spaceEventsPath, PREFS_DOMAIN);
        CFPreferencesAppSynchronize(PREFS_DOMAIN);
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:StatusChanged object:nil userInfo:nil deliverImmediately:YES];
        NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
        [center addObserverForName:@"com.apple.accessibility.api" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            (void)note;
            checkPermission();
        }];
        [center addObserverForName:SettingsChanged object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;
            @autoreleasepool { settingsChanged(); }
        }];
        [center addObserverForName:StatusRequest object:nil queue:nil usingBlock:^(NSNotification *note) {
            @autoreleasepool {
                if (![note.object isKindOfClass:[NSString class]]) return;
                [NSDistributedNotificationCenter.defaultCenter postNotificationName:StatusReply object:note.object
                                    userInfo:@{ @"pending": @(gRestores.count > 0), @"accessibility": @(gTrusted) }
                          deliverImmediately:YES];
            }
        }];
        // Existing windowed apps at startup are not evidence of a deliberate full-screen exit.
        if (gTrusted)
            for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) recordApplication(app, YES, "startup");
        // AppKit supplies the event pump only when the private WindowServer path is unavailable.
        if (appKitSpaceEvents) [NSApp run];
        else CFRunLoopRun();
    }
    return 0;
}
