// Exercise workspace and scheduled restore steps without other apps, permissions or saved preferences.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <os/log.h>
#include <assert.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <math.h>

static unsigned applicationCreations, activationPolicyChanges, applicationRuns, runLoopRuns;
static dispatch_block_t agentRunHook, preferenceReadHook;
static unsigned settingsObserverRegistrations;
@interface TestAgentApplication : NSObject
+ (instancetype)sharedApplication;
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy;
- (void)run;
@end
static TestAgentApplication *testApp;
@implementation TestAgentApplication
+ (instancetype)sharedApplication {
    applicationCreations++;
    testApp = [self new];
    return testApp;
}
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy {
    assert(policy == NSApplicationActivationPolicyProhibited);
    activationPolicyChanges++;
    return YES;
}
- (void)run {
    assert(NSThread.isMainThread && activationPolicyChanges == 1);
    applicationRuns++;
    if (agentRunHook) agentRunHook();
}
@end

@interface TestApplication : NSObject
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid;
@property BOOL terminated;
@property pid_t processIdentifier;
@property NSApplicationActivationPolicy activationPolicy;
@property(copy) NSString *bundleIdentifier;
@property(copy) NSString *localizedName;
@end
static NSMutableDictionary<NSNumber *, TestApplication *> *testApplications;
@implementation TestApplication
+ (instancetype)runningApplicationWithProcessIdentifier:(pid_t)pid { return testApplications[@(pid)]; }
@end

@interface TestWorkspace : NSObject
@property(strong) NSNotificationCenter *notificationCenter;
@property(strong) TestApplication *frontmostApplication;
@property(copy) NSArray *runningApplications;
+ (instancetype)sharedWorkspace;
@end
static TestWorkspace *workspace;
@implementation TestWorkspace
+ (instancetype)sharedWorkspace { return workspace; }
@end

@interface TestDistributedCenter : NSNotificationCenter
+ (instancetype)defaultCenter;
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)info deliverImmediately:(BOOL)immediately;
@end
static TestDistributedCenter *distributedCenter;
@implementation TestDistributedCenter
+ (instancetype)defaultCenter { return distributedCenter; }
- (id<NSObject>)addObserverForName:(NSNotificationName)name object:(id)object queue:(NSOperationQueue *)queue
                      usingBlock:(void (^)(NSNotification *))block {
    if ([name isEqualToString:@"io.github.fratayaydn.fullscreenkeeper.SettingsChanged"])
        settingsObserverRegistrations++;
    return [super addObserverForName:name object:object queue:queue usingBlock:block];
}
- (void)postNotificationName:(NSString *)name object:(NSString *)object userInfo:(NSDictionary *)info deliverImmediately:(BOOL)immediately {
    (void)immediately;
    [self postNotificationName:name object:object userInfo:info];
}
@end

@interface TestTask : NSObject
@property(copy) NSURL *executableURL;
@property(copy) NSArray *arguments;
@property(strong) id standardOutput;
@property(strong) id standardError;
@property(readonly) NSTaskTerminationReason terminationReason;
@property(readonly) int terminationStatus;
- (BOOL)launchAndReturnError:(NSError **)error;
- (void)waitUntilExit;
@end
static BOOL childLaunches;
static int childStatus, restartStatus;
static unsigned childChecks;
static NSTaskTerminationReason childReason;
@implementation TestTask
- (BOOL)launchAndReturnError:(NSError **)error {
    (void)error;
    assert(self.executableURL.isFileURL && [self.arguments isEqual:@[@"--check"]]);
    childChecks++;
    return childLaunches;
}
- (void)waitUntilExit {}
- (NSTaskTerminationReason)terminationReason { return childReason; }
- (int)terminationStatus { return childStatus; }
@end

static NSDictionary *preferences;
static id ignoredPreferences;
static id reopenPreference, forceFnFPreference;
static unsigned tapCreations, tapInvalidations, tapSourceCreations, tapSourceRemovals;
static unsigned keyTapEnableCalls;
static unsigned failTapCreation, failTapSourceCreation;
static BOOL keyTapEnabled, fullscreenUnwritable, lastWrittenFullscreen;
typedef struct { unsigned keycode; CGEventFlags flags; BOOL autorepeat; pid_t pid; } TestKeyEvent;
static unsigned axCalls, writes, saves, trustChecks;
static NSString *spaceEventsPreference;
static BOOL permission, fullscreen, nonstandard, minimized;
static NSArray *reportedWindows;
static NSMutableArray<NSNumber *> *queriedPIDs;
static AXError windowsError, fullscreenError;
static NSMutableArray<NSString *> *logs;
static NSMutableArray<NSNumber *> *scheduledDelays;
static CFStringRef terminateDuringAttribute;
static BOOL terminateDuringSettable;
static BOOL privateAPIAvailable, failCoreFoundation, failMachPort, failRunLoopSource, nullEventPort;
static const char *missingSymbol;
static CGError registrationError, eventPortError;
static int connectionID;
static uint32_t failedRegistrationType;
static NSMutableArray<NSNumber *> *registeredTypes;
static NSMutableSet<NSNumber *> *activeTypes;
static unsigned unregistrations, removedSpaceSources;
static unsigned libraryLoads, registrations, portRequests, portOptions, addedSources, eventReads, eventsToDrain;
static void (*registeredNotify)(uint32_t, void *, size_t, void *, int);
static CFMachPortCallBack portCallback;
static CFTypeRef pumpEvent;
static BOOL deferMainQueue;
static NSMutableArray<dispatch_block_t> *mainQueueBlocks;
static NSMutableArray<dispatch_block_t> *delayedBlocks;
static int reportedSpaceType;
static unsigned spaceTypeReads;
static uint64_t queriedSpaceID;
static id managedDisplays;
static NSDictionary<NSNumber *, NSNumber *> *reportedSpaceTypes;
static unsigned managedDisplayReads;

static CFArrayRef testCopyManagedDisplaySpaces(int cid) {
    assert(cid == connectionID);
    managedDisplayReads++;
    return managedDisplays ? (CFArrayRef)CFRetain((__bridge CFTypeRef)managedDisplays) : NULL;
}

static int testSpaceType(int cid, uint64_t sid) {
    assert(cid == connectionID);
    queriedSpaceID = sid;
    spaceTypeReads++;
    NSNumber *type = reportedSpaceTypes[@(sid)];
    return type ? type.intValue : reportedSpaceType;
}
static int testMainConnection(void) { return connectionID; }
static CGError testRegisterNotify(int cid, void (*callback)(uint32_t, void *, size_t, void *, int),
                                  uint32_t type, void *context) {
    assert(cid == connectionID && !context);
    assert(type == 1327 || type == 1328 || type == 1401);
    if (registeredNotify) assert(callback == registeredNotify);
    [registeredTypes addObject:@(type)];
    registrations++;
    if (type == failedRegistrationType) return kCGErrorFailure;
    if (registrationError == kCGErrorSuccess) { registeredNotify = callback; [activeTypes addObject:@(type)]; }
    return registrationError;
}
static CGError testRemoveNotify(int cid, void (*callback)(uint32_t, void *, size_t, void *, int),
                                uint32_t type, void *context) {
    assert(cid == connectionID && callback == registeredNotify && !context);
    assert([activeTypes containsObject:@(type)]);
    [activeTypes removeObject:@(type)];
    unregistrations++;
    return kCGErrorSuccess;
}
static CGError testEventPort(int cid, mach_port_t *port) {
    assert(cid == connectionID);
    portRequests++;
    *port = nullEventPort ? MACH_PORT_NULL : 123;
    return eventPortError;
}
static CGEventRef testNextEvent(int cid) {
    assert(cid == connectionID);
    eventReads++;
    if (!eventsToDrain) return NULL;
    eventsToDrain--;
    return (CGEventRef)CFRetain(pumpEvent);
}
static void testPortOptions(CFMachPortRef port, int options) {
    assert(CFEqual(port, CFSTR("port")) && options == 0x40);
    portOptions++;
}
static void *testDlopen(const char *path, int flags) {
    assert(flags == (RTLD_NOW | RTLD_LOCAL));
    libraryLoads++;
    if (!privateAPIAvailable) return NULL;
    if (!strcmp(path, "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")) return (void *)1;
    assert(!strcmp(path, "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"));
    return failCoreFoundation ? NULL : (void *)2;
}
static char *testDlerror(void) { return "simulated load failure"; }
static void *testDlsym(void *handle, const char *name) {
    assert(handle == (void *)(uintptr_t)(!strcmp(name, "_CFMachPortSetOptions") ? 2 : 1));
    if (missingSymbol && !strcmp(name, missingSymbol)) return NULL;
    if (!strcmp(name, "SLSMainConnectionID")) return (void *)testMainConnection;
    if (!strcmp(name, "SLSRegisterConnectionNotifyProc")) return (void *)testRegisterNotify;
    if (!strcmp(name, "SLSRemoveConnectionNotifyProc")) return (void *)testRemoveNotify;
    if (!strcmp(name, "SLSGetEventPort")) return (void *)testEventPort;
    if (!strcmp(name, "SLEventCreateNextEvent")) return (void *)testNextEvent;
    if (!strcmp(name, "SLSSpaceGetType")) return (void *)testSpaceType;
    if (!strcmp(name, "SLSCopyManagedDisplaySpaces")) return (void *)testCopyManagedDisplaySpaces;
    assert(!strcmp(name, "_CFMachPortSetOptions"));
    return (void *)testPortOptions;
}
static CFMachPortRef testMachPort(CFAllocatorRef allocator, mach_port_t port, CFMachPortCallBack callback,
                                CFMachPortContext *context, Boolean *shouldFreeInfo) {
    assert(!allocator && port == 123 && !context && !shouldFreeInfo);
    portCallback = callback;
    return failMachPort ? NULL : (CFMachPortRef)CFRetain(CFSTR("port"));
}
static CFRunLoopSourceRef testPortSource(CFAllocatorRef allocator, CFMachPortRef port, CFIndex order) {
    if (CFEqual(port, CFSTR("fnFKeys"))) {
        assert(!allocator && order == 0);
        if (++tapSourceCreations == failTapSourceCreation) return NULL;
        return (CFRunLoopSourceRef)CFRetain(CFSTR("fnFKeySource"));
    }
    assert(!allocator && CFEqual(port, CFSTR("port")) && order == 0 && portOptions >= 1);
    return failRunLoopSource ? NULL : (CFRunLoopSourceRef)CFRetain(CFSTR("source"));
}
static void testAddSource(CFRunLoopRef loop, CFRunLoopSourceRef source, CFRunLoopMode mode) {
    if (CFEqual(source, CFSTR("fnFKeySource"))) {
        assert(loop == CFRunLoopGetMain() && mode == kCFRunLoopCommonModes);
        return;
    }
    assert(loop == CFRunLoopGetMain() && CFEqual(source, CFSTR("source")) && mode == kCFRunLoopCommonModes);
    addedSources++;
}

static CFMachPortRef testTapCreate(CGEventTapLocation location, CGEventTapPlacement placement, CGEventTapOptions options,
                                  CGEventMask mask, CGEventTapCallBack callback, void *context) {
    assert(location == kCGSessionEventTap && placement == kCGHeadInsertEventTap && options == kCGEventTapOptionDefault);
    assert(callback && !context);
    assert(mask == (CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)));
    if (++tapCreations == failTapCreation) return NULL;
    keyTapEnabled = YES;
    return (CFMachPortRef)CFRetain(CFSTR("fnFKeys"));
}
static void testTapEnable(CFMachPortRef tap, bool enabled) {
    assert(CFEqual(tap, CFSTR("fnFKeys")));
    keyTapEnableCalls++;
    keyTapEnabled = enabled;
}
static bool testTapIsEnabled(CFMachPortRef tap) {
    assert(CFEqual(tap, CFSTR("fnFKeys")));
    return keyTapEnabled;
}
static void testTapInvalidate(CFMachPortRef tap) {
    assert(!testTapIsEnabled(tap));
    tapInvalidations++;
}
static void testRemoveSource(CFRunLoopRef loop, CFRunLoopSourceRef source, CFRunLoopMode mode) {
    assert(loop == CFRunLoopGetMain() && mode == kCFRunLoopCommonModes);
    if (CFEqual(source, CFSTR("source"))) { removedSpaceSources++; return; }
    assert(CFEqual(source, CFSTR("fnFKeySource")));
    tapSourceRemovals++;
}
static int64_t testEventInteger(CGEventRef event, CGEventField field) {
    TestKeyEvent *key = (TestKeyEvent *)event;
    if (field == kCGKeyboardEventKeycode) return key->keycode;
    if (field == kCGKeyboardEventAutorepeat) return key->autorepeat;
    assert(field == kCGEventTargetUnixProcessID);
    return key->pid;
}
static CGEventFlags testEventFlags(CGEventRef event) { return ((TestKeyEvent *)event)->flags; }

static BOOL inputPermission, failHIDCreation, failHIDOpen, hidFiltered, hidMatched, hidScheduled, hidOpen;
static unsigned hidCreations, hidCloses, hidUnscheduled, inputChecks;
static IOHIDValueCallback hidCallback;
typedef struct { uint32_t page, usage; CFIndex input; } TestHIDValue;
static IOHIDAccessType testInputAccess(IOHIDRequestType type) {
    assert(type == kIOHIDRequestTypeListenEvent);
    inputChecks++;
    return inputPermission ? kIOHIDAccessTypeGranted : kIOHIDAccessTypeDenied;
}
static IOHIDManagerRef testHIDCreate(CFAllocatorRef allocator, IOOptionBits options) {
    assert(allocator == kCFAllocatorDefault && options == kIOHIDOptionsTypeNone);
    assert(inputPermission && !keyTapEnabled);
    hidCreations++;
    hidFiltered = hidMatched = NO;
    return failHIDCreation ? NULL : (IOHIDManagerRef)CFRetain(CFSTR("fnHID"));
}
static void testHIDFilter(IOHIDManagerRef manager, CFArrayRef multiple) {
    assert(CFEqual(manager, CFSTR("fnHID")) && !hidScheduled && !hidOpen && !hidMatched);
    NSArray *matches = (__bridge NSArray *)multiple;
    assert(([matches isEqual:@[
        @{ @kIOHIDElementUsagePageKey: @0xFF, @kIOHIDElementUsageKey: @3 },
        @{ @kIOHIDElementUsagePageKey: @0xFF00, @kIOHIDElementUsageKey: @3 }
    ]]));
    hidFiltered = YES;
}
static void testHIDMatch(IOHIDManagerRef manager, CFDictionaryRef matching) {
    assert(CFEqual(manager, CFSTR("fnHID")) && hidFiltered && !hidScheduled && !hidOpen);
    assert(([(__bridge NSDictionary *)matching isEqual:@{
        @kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Keyboard)
    }]));
    hidMatched = YES;
}
static void testHIDCallback(IOHIDManagerRef manager, IOHIDValueCallback callback, void *context) {
    assert(CFEqual(manager, CFSTR("fnHID")) && hidFiltered && hidMatched && !context);
    hidCallback = callback;
}
static void testHIDSchedule(IOHIDManagerRef manager, CFRunLoopRef loop, CFStringRef mode) {
    assert(CFEqual(manager, CFSTR("fnHID")) && loop == CFRunLoopGetMain() && mode == kCFRunLoopCommonModes);
    assert(hidFiltered && hidMatched && hidCallback && !hidScheduled);
    hidScheduled = YES;
}
static IOReturn testHIDOpen(IOHIDManagerRef manager, IOOptionBits options) {
    assert(CFEqual(manager, CFSTR("fnHID")) && options == kIOHIDOptionsTypeNone && hidScheduled);
    hidOpen = !failHIDOpen;
    return failHIDOpen ? kIOReturnError : kIOReturnSuccess;
}
static void testHIDUnschedule(IOHIDManagerRef manager, CFRunLoopRef loop, CFStringRef mode) {
    assert(CFEqual(manager, CFSTR("fnHID")) && loop == CFRunLoopGetMain() && mode == kCFRunLoopCommonModes);
    assert(hidScheduled);
    hidScheduled = NO;
    hidUnscheduled++;
}
static IOReturn testHIDClose(IOHIDManagerRef manager, IOOptionBits options) {
    assert(CFEqual(manager, CFSTR("fnHID")) && options == kIOHIDOptionsTypeNone && !hidScheduled);
    hidOpen = NO;
    hidCloses++;
    return kIOReturnSuccess;
}
static IOHIDElementRef testHIDElement(IOHIDValueRef value) { return (IOHIDElementRef)value; }
static uint32_t testHIDPage(IOHIDElementRef element) { return ((TestHIDValue *)element)->page; }
static uint32_t testHIDUsage(IOHIDElementRef element) { return ((TestHIDValue *)element)->usage; }
static CFIndex testHIDInput(IOHIDValueRef value) { return ((TestHIDValue *)value)->input; }

static Boolean testTrusted(void) { trustChecks++; return permission; }
static AXUIElementRef testCreateApplication(pid_t pid) {
    [queriedPIDs addObject:@(pid)];
    axCalls++;
    return (AXUIElementRef)CFRetain(CFSTR("application"));
}
static AXUIElementRef testCreateSystem(void) { return testCreateApplication(0); }
static AXError testTimeout(AXUIElementRef element, float timeout) {
    (void)element;
    assert(timeout == 0.25);
    axCalls++;
    return kAXErrorSuccess;
}
static CFTypeID testElementType(void) { return CFStringGetTypeID(); }
static AXError testAttribute(AXUIElementRef element, CFStringRef key, CFTypeRef *value) {
    (void)element;
    axCalls++;
    if (terminateDuringAttribute && CFEqual(key, terminateDuringAttribute)) workspace.frontmostApplication.terminated = YES;
    id result = nil;
    if (CFEqual(key, kAXWindowsAttribute)) {
        if (windowsError != kAXErrorSuccess) { *value = NULL; return windowsError; }
        result = reportedWindows;
    }
    else if (CFEqual(key, kAXFocusedWindowAttribute)) result = @"window";
    else if (CFEqual(key, kAXSubroleAttribute)) result = (__bridge NSString *)(nonstandard ? kAXDialogSubrole : kAXStandardWindowSubrole);
    else if (CFEqual(key, kAXMinimizedAttribute)) result = @(minimized);
    else if (CFEqual(key, CFSTR("AXFullScreen"))) {
        if (fullscreenError != kAXErrorSuccess) { *value = NULL; return fullscreenError; }
        result = @(fullscreen);
    }
    *value = result ? CFRetain((__bridge CFTypeRef)result) : NULL;
    return result ? kAXErrorSuccess : kAXErrorNoValue;
}
static AXError testSettable(AXUIElementRef element, CFStringRef key, Boolean *writable) {
    (void)element; (void)key;
    axCalls++;
    if (terminateDuringSettable) workspace.frontmostApplication.terminated = YES;
    *writable = !fullscreenUnwritable;
    return kAXErrorSuccess;
}
static AXError testWrite(AXUIElementRef element, CFStringRef key, CFTypeRef value) {
    (void)element; (void)key;
    assert(!workspace.frontmostApplication.terminated);
    axCalls++;
    writes++;
    lastWrittenFullscreen = CFBooleanGetValue(value);
    return kAXErrorSuccess;
}
static AXError testObserver(pid_t pid, AXObserverCallback callback, AXObserverRef *observer) {
    (void)pid; (void)callback;
    axCalls++;
    *observer = NULL;
    return kAXErrorCannotComplete;
}
static Boolean testSynchronize(CFStringRef domain) { (void)domain; return true; }
static CFPropertyListRef testCopyPreference(CFStringRef key, CFStringRef domain) {
    assert(CFEqual(domain, CFSTR("io.github.fratayaydn.fullscreenkeeper")));
    if (CFEqual(key, CFSTR("ReopenInFullScreen")))
        return reopenPreference ? CFRetain((__bridge CFTypeRef)reopenPreference) : NULL;
    if (CFEqual(key, CFSTR("ForceFnF"))) {
        CFPropertyListRef value = forceFnFPreference ? CFRetain((__bridge CFTypeRef)forceFnFPreference) : NULL;
        if (preferenceReadHook) {
            dispatch_block_t hook = preferenceReadHook;
            preferenceReadHook = nil;
            hook();
        }
        return value;
    }
    assert(CFEqual(key, CFSTR("Applications")) || CFEqual(key, CFSTR("IgnoredApplications")));
    id value = CFEqual(key, CFSTR("IgnoredApplications")) ? ignoredPreferences : preferences;
    return value ? CFRetain((__bridge CFTypeRef)value) : NULL;
}
static void testSavePreference(CFStringRef key, CFPropertyListRef value, CFStringRef domain) {
    assert(CFEqual(domain, CFSTR("io.github.fratayaydn.fullscreenkeeper")));
    if (CFEqual(key, CFSTR("SpaceEventsPath"))) {
        spaceEventsPreference = (__bridge NSString *)value;
        return;
    }
    assert(CFEqual(key, CFSTR("Applications")));
    saves++;
    preferences = (__bridge NSDictionary *)value;
}
static void testAfter(dispatch_time_t time, dispatch_queue_t queue, dispatch_block_t block) {
    (void)time; (void)queue;
    [delayedBlocks addObject:block];  // scheduled blocks are invoked explicitly below
}
static dispatch_time_t testDispatchTime(dispatch_time_t when, int64_t delta) {
    [scheduledDelays addObject:@((double)delta / NSEC_PER_SEC)];
    return dispatch_time(when, delta);
}
static void testLog(const char *format, ...) {
    NSString *plain = [@(format) stringByReplacingOccurrencesOfString:@"{public}" withString:@""];
    va_list arguments;
    va_start(arguments, format);
    [logs addObject:[[NSString alloc] initWithFormat:plain arguments:arguments]];
    va_end(arguments);
}
static void testRunLoop(void) { runLoopRuns++; if (agentRunHook) agentRunHook(); }
static void testAsync(dispatch_queue_t queue, dispatch_block_t block) {
    if (deferMainQueue && queue == dispatch_get_main_queue()) [mainQueueBlocks addObject:block];
    else block();
}
static void testExit(int status) { restartStatus = status; }

#define NSRunningApplication TestApplication
#define NSApplication TestAgentApplication
#define NSApp testApp
#define NSWorkspace TestWorkspace
#define NSDistributedNotificationCenter TestDistributedCenter
#define NSTask TestTask
#define AXIsProcessTrusted testTrusted
#define AXUIElementCreateApplication testCreateApplication
#define AXUIElementCreateSystemWide testCreateSystem
#define AXUIElementSetMessagingTimeout testTimeout
#define AXUIElementGetTypeID testElementType
#define AXUIElementCopyAttributeValue testAttribute
#define AXUIElementIsAttributeSettable testSettable
#define AXUIElementSetAttributeValue testWrite
#define AXObserverCreate testObserver
#define CFPreferencesAppSynchronize testSynchronize
#define CFPreferencesCopyAppValue testCopyPreference
#define CFPreferencesSetAppValue testSavePreference
#define dispatch_after testAfter
#define dispatch_time testDispatchTime
#define dispatch_async testAsync
#define CFRunLoopRun testRunLoop
#define dlopen testDlopen
#define dlerror testDlerror
#define dlsym testDlsym
#define CFMachPortCreateWithPort testMachPort
#define CFMachPortCreateRunLoopSource testPortSource
#define CFRunLoopAddSource testAddSource
#define CFRunLoopRemoveSource testRemoveSource
#define CFMachPortInvalidate testTapInvalidate
#define CGEventTapCreate testTapCreate
#define CGEventTapEnable testTapEnable
#define CGEventTapIsEnabled testTapIsEnabled
#define CGEventGetIntegerValueField testEventInteger
#define CGEventGetFlags testEventFlags
#define IOHIDCheckAccess testInputAccess
#define IOHIDManagerCreate testHIDCreate
#define IOHIDManagerSetInputValueMatchingMultiple testHIDFilter
#define IOHIDManagerSetDeviceMatching testHIDMatch
#define IOHIDManagerRegisterInputValueCallback testHIDCallback
#define IOHIDManagerScheduleWithRunLoop testHIDSchedule
#define IOHIDManagerOpen testHIDOpen
#define IOHIDManagerUnscheduleFromRunLoop testHIDUnschedule
#define IOHIDManagerClose testHIDClose
#define IOHIDValueGetElement testHIDElement
#define IOHIDElementGetUsagePage testHIDPage
#define IOHIDElementGetUsage testHIDUsage
#define IOHIDValueGetIntegerValue testHIDInput
#define exit testExit
static BOOL debugLogging;
#define os_log_type_enabled(log, type) ((void)(log), (void)(type), debugLogging)
#undef os_log_debug
#define os_log_debug(log, format, ...) do { if (debugLogging) { (void)(log); testLog(format, ##__VA_ARGS__); } } while (0)
#undef os_log_info
#define os_log_info(log, format, ...) ((void)(log), testLog(format, ##__VA_ARGS__))
#undef os_log_error
#define os_log_error(log, format, ...) ((void)(log), testLog(format, ##__VA_ARGS__))
static unsigned updaterCalls;
static BOOL updaterForce, updaterInstall;
static int testUpdaterRun(BOOL force, BOOL install) {
    updaterCalls++;
    updaterForce = force;
    updaterInstall = install;
    return 0;
}
#define updaterRun testUpdaterRun
#define main agentMain
#include "../Sources/Agent/fullscreenkeeperd.m"
#undef main
#undef updaterRun

static void fnInput(uint32_t page, CFIndex input) {
    assert(hidCallback && hidOpen && hidFiltered);
    TestHIDValue value = { page, 3, input };
    hidCallback(NULL, kIOReturnSuccess, NULL, (IOHIDValueRef)&value);
}

static void reset(void) {
    stopReopen();
    stopFnFTaps();
    for (RestoreSession *session in gRestores.allValues) finishRestore(session, YES, "test reset");
    for (SpaceSeries *series in gSpaceChecks.allValues) [series stop];
    if (gTerminationObserver) [workspace.notificationCenter removeObserver:gTerminationObserver];
    gTerminationObserver = nil;
    workspace = [TestWorkspace new];
    testApplications = [NSMutableDictionary dictionary];
    workspace.notificationCenter = [NSNotificationCenter new];
    workspace.runningApplications = @[];
    distributedCenter = [TestDistributedCenter new];
    agentRunHook = preferenceReadHook = nil;
    settingsObserverRegistrations = 0;
    gRestores = [NSMutableDictionary dictionary];
    gSpaceChecks = [NSMutableDictionary dictionary];
    gLastSpaceChanges = [NSMutableDictionary dictionary];
    gProtected = [NSMutableDictionary dictionary];
    gApplications = preferences = @{};
    gIgnoredApplications = ignoredPreferences = @{};
    reopenPreference = forceFnFPreference = nil;
    gReopenInFullScreen = YES;
    // Direct policy seams below simulate an already started reopen feature.
    gReopenRunning = YES;
    gAppKitEventPump = gAgentRunLoopStarted = NO;
    gApplyingSettings = NO;
    gForceFnF = NO;
    tapCreations = tapInvalidations = tapSourceCreations = tapSourceRemovals = 0;
    keyTapEnableCalls = 0;
    failTapCreation = failTapSourceCreation = 0;
    keyTapEnabled = fullscreenUnwritable = lastWrittenFullscreen = NO;
    inputPermission = gInputMonitoringGranted = YES;
    failHIDCreation = failHIDOpen = hidFiltered = hidMatched = hidScheduled = hidOpen = NO;
    hidCreations = hidCloses = hidUnscheduled = inputChecks = 0;
    hidCallback = NULL;
    axCalls = writes = saves = trustChecks = 0;
    applicationCreations = activationPolicyChanges = 0;
    applicationRuns = runLoopRuns = 0;
    testApp = nil;
    gTrusted = permission = YES;
    spaceEventsPreference = nil;
    fullscreen = nonstandard = minimized = terminateDuringSettable = NO;
    reportedWindows = @[@"window"];
    queriedPIDs = [NSMutableArray array];
    logs = [NSMutableArray array];
    scheduledDelays = [NSMutableArray array];
    windowsError = fullscreenError = kAXErrorSuccess;
    gPreviousSpacePID = 0;
    debugLogging = YES;
    terminateDuringAttribute = NULL;
    childLaunches = YES;
    childStatus = 0;
    childReason = NSTaskTerminationReasonExit;
    restartStatus = -1;
    childChecks = 0;
    privateAPIAvailable = failCoreFoundation = failMachPort = failRunLoopSource = nullEventPort = NO;
    missingSymbol = NULL;
    registrationError = eventPortError = kCGErrorSuccess;
    connectionID = 42;
    failedRegistrationType = 0;
    registeredTypes = [NSMutableArray array];
    activeTypes = [NSMutableSet set];
    unregistrations = removedSpaceSources = 0;
    libraryLoads = registrations = portRequests = portOptions = addedSources = eventReads = eventsToDrain = 0;
    registeredNotify = NULL;
    portCallback = NULL;
    gWindowServerSpaceEvents = gWindowServerTransitions = gSpaceChangePending = NO;
    atomic_store(&gSpaceEventsGeneration, 0);
    gNextWindowServerEvent = NULL;
    gWindowServerConnection = 0;
    gSpaceGetType = NULL;
    gFullscreenSpaces = nil;
    reportedSpaceType = 4;
    spaceTypeReads = 0;
    queriedSpaceID = 0;
    managedDisplays = @[];
    reportedSpaceTypes = @{};
    managedDisplayReads = 0;
    deferMainQueue = NO;
    mainQueueBlocks = [NSMutableArray array];
    delayedBlocks = [NSMutableArray array];
}

static TestApplication *application(pid_t pid, BOOL saved) {
    TestApplication *app = [TestApplication new];
    app.processIdentifier = pid;
    testApplications[@(pid)] = app;
    app.bundleIdentifier = [NSString stringWithFormat:@"test.app.%d", pid];
    app.localizedName = @"Test App";
    NSMutableDictionary *records = [preferences mutableCopy];
    if (saved) records[app.bundleIdentifier] = @{ @"name": app.localizedName, @"fullscreen": @YES };
    gApplications = preferences = records;
    return app;
}

static void reopenDefaults(void) {
    reset();
    loadSettings();
    assert(gReopenInFullScreen && !gForceFnF && !saves);
    reopenPreference = @NO;
    loadSettings();
    assert(!gReopenInFullScreen && !saves);
    reopenPreference = @YES;
    loadSettings();
    assert(gReopenInFullScreen && !saves);
    reopenPreference = @"invalid";
    loadSettings();
    assert(gReopenInFullScreen && !saves);
}

static void reopenOffAtStartup(void) {
    for (unsigned privateAPI = 0; privateAPI < 2; privateAPI++) {
        for (unsigned force = 0; force < 2; force++) {
            reset();
            privateAPIAvailable = privateAPI;
            reopenPreference = @NO;
            forceFnFPreference = @(force);
            TestApplication *app = application(220, YES);
            workspace.frontmostApplication = app;
            workspace.runningApplications = @[app];
            // Even obsolete or ignored entries must remain untouched while reopen is off.
            preferences = @{ app.bundleIdentifier: preferences[app.bundleIdentifier],
                             @"old.windowed": @{ @"fullscreen": @NO } };
            ignoredPreferences = @{ app.bundleIdentifier: @{} };
            NSDictionary *before = preferences;
            fullscreen = YES;
            char *arguments[] = { "fullscreenkeeperd", NULL };
            assert(agentMain(1, arguments) == 0);
            assert(!gReopenInFullScreen && !gReopenRunning && !gWindowServerSpaceEvents);
            assert(!libraryLoads && !registrations && !managedDisplayReads && !addedSources);
            assert(!applicationCreations && !applicationRuns && runLoopRuns == 1);
            assert(!gLaunchObserver && !gSpaceObserver && !gActivationObserver && !gTerminationObserver);
            assert(!spaceEventsPreference && !axCalls && !writes && !saves);
            assert([preferences isEqual:before] && tapCreations == force);
            [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                                     userInfo:@{ NSWorkspaceApplicationKey: app }];
            [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
            recordApplication(app, YES, "startup");
            recordSpaceChange(YES);
            recordFullscreenSpace(1327, 1, app);
            saveState(app, StateWindowed);
            startRestore(app);
            assert(!startWindowServerSpaceEvents());
            settingsChanged();
            assert(!axCalls && !writes && !saves && !registrations && !libraryLoads);
            assert(!gRestores.count && !gSpaceChecks.count && !delayedBlocks.count);
            assert([preferences isEqual:before]);
            // Force fn-F still toggles ignored apps while remembering is off.
            settingsChanged();
            if (force) {
                fnInput(0xFF, 1);
                TestKeyEvent key = { kVK_ANSI_F, kCGEventFlagMaskSecondaryFn, NO, app.processIdentifier };
                NSUInteger logCount = logs.count;
                assert(!fnFKeyEvent(NULL, kCGEventKeyDown, (CGEventRef)&key, NULL));
                assert(writes == 1 && !lastWrittenFullscreen && !saves && logs.count == logCount);
                assert([preferences isEqual:before] && !registrations && !gRestores.count);
            }
        }
    }
}

static void legacySettingsCleanup(void) {
    reset();
    TestApplication *kept = application(90, YES);
    NSDictionary *entry = preferences[kept.bundleIdentifier];
    NSMutableDictionary *records = [preferences mutableCopy];
    records[@"test.old.windowed"] = @{ @"name": @"Old Windowed App", @"fullscreen": @NO };
    preferences = records;
    loadSettings();
    assert(saves == 1 && gApplications.count == 1 && preferences.count == 1);
    assert([preferences[kept.bundleIdentifier] isEqual:entry]);
    assert(remembered(kept.bundleIdentifier) == StateFullscreen);
    assert(remembered(@"test.old.windowed") == StateWindowed);
    assert(remembered(@"test.absent") == StateWindowed);
    loadSettings();
    assert(saves == 1);  // migration writes once
}

static void immediateExitRemovesEntry(void) {
    reset();
    TestApplication *app = application(91, YES);
    TestApplication *other = application(92, YES);
    recordApplication(app, NO, "now");
    assert(saves == 1 && preferences.count == 1);
    assert(!preferences[app.bundleIdentifier] && !gApplications[app.bundleIdentifier]);
    assert(remembered(app.bundleIdentifier) == StateWindowed);
    assert(remembered(other.bundleIdentifier) == StateFullscreen);
    recordApplication(app, NO, "now");
    saveState(app, StateWindowed);
    assert(saves == 1);
    fullscreen = YES;
    recordApplication(app, NO, "now");
    assert(saves == 2 && preferences.count == 2);
    assert(([preferences[app.bundleIdentifier] isEqual:@{ @"name": app.localizedName, @"fullscreen": @YES }]));
    recordApplication(app, NO, "now");
    assert(saves == 2);
}

static void startupKeepsEntries(void) {
    reset();
    TestApplication *rememberedApp = application(93, YES);
    TestApplication *windowed = application(94, NO);
    NSDictionary *before = preferences;
    workspace.runningApplications = @[rememberedApp, windowed];
    workspace.frontmostApplication = rememberedApp;
    char *arguments[] = { "fullscreenkeeperd", NULL };
    assert(agentMain(1, arguments) == 0);
    assert([preferences isEqual:before] && saves == 0 && !gRestores.count);
    fullscreen = YES;
    recordApplication(windowed, YES, "startup");
    assert(saves == 1 && remembered(windowed.bundleIdentifier) == StateFullscreen);
    fullscreen = NO;
    recordApplication(windowed, YES, "startup");
    assert(saves == 1 && remembered(windowed.bundleIdentifier) == StateFullscreen);
}

static void failedRestoreKeepsEntry(void) {
    reset();
    TestApplication *app = application(95, YES);
    workspace.frontmostApplication = app;
    NSDictionary *before = preferences;
    startRestore(app);
    RestoreSession *session = gRestores[@95];
    for (unsigned attempt = 0; attempt < 5; attempt++) {
        assert(writes == attempt + 1 && session->readBack);
        dispatch_block_t readBack = session->readBack;
        readBack();
    }
    assert(!gRestores.count && gProtected[@95] == app);
    recordApplication(app, NO, "now");
    assert(saves == 0 && [preferences isEqual:before]);
    assert(remembered(app.bundleIdentifier) == StateFullscreen);
    fullscreen = YES;
    recordApplication(app, NO, "now");
    assert(!gProtected.count && saves == 0);
    fullscreen = NO;
    recordApplication(app, NO, "now");
    assert(saves == 1 && !preferences[app.bundleIdentifier]);
}

static void startupObservers(void) {
    for (unsigned trusted = 0; trusted < 2; trusted++) {
        reset();
        permission = trusted;
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        assert(trustChecks == 1 && gTrusted == permission && !gActivationObserver);
        assert(applicationCreations == trusted && activationPolicyChanges == trusted);
        assert(applicationRuns == trusted && runLoopRuns == !trusted);
        TestApplication *app = application(100, NO);
        workspace.frontmostApplication = app;
        fullscreen = YES;
        unsigned before = axCalls;
        [workspace.notificationCenter postNotificationName:NSWorkspaceDidActivateApplicationNotification object:nil
                                                 userInfo:@{ NSWorkspaceApplicationKey: app }];
        [workspace.notificationCenter postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
                                                 userInfo:@{ NSWorkspaceApplicationKey: app }];
        [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                                 userInfo:@{ NSWorkspaceApplicationKey: app }];
        assert(axCalls == before && saves == 0);
        [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
        assert(saves == trusted);
        assert(!gSpaceChecks.count && !gTerminationObserver);
        if (!trusted) assert(axCalls == 0);
        assert(trustChecks == 1);
    }
}

static NSDictionary *requestAgentStatus(void) {
    __block NSDictionary *reply;
    NSString *request = NSUUID.UUID.UUIDString;
    id token = [distributedCenter addObserverForName:StatusReply object:request queue:nil
        usingBlock:^(NSNotification *note) { reply = note.userInfo; }];
    [distributedCenter postNotificationName:StatusRequest object:request userInfo:nil deliverImmediately:YES];
    [distributedCenter removeObserver:token];
    assert(reply);
    return reply;
}

static NSString *statusOutput(NSDictionary *reply) {
    id token = [distributedCenter addObserverForName:StatusRequest object:nil queue:nil
        usingBlock:^(NSNotification *note) {
            if (reply) [distributedCenter postNotificationName:StatusReply object:note.object
                userInfo:reply deliverImmediately:YES];
        }];
    fflush(stdout);
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    int saved = dup(STDOUT_FILENO);
    assert(saved >= 0 && dup2(descriptors[1], STDOUT_FILENO) >= 0);
    close(descriptors[1]);
    char *arguments[] = { "fullscreenkeeperd", "--status", NULL };
    assert(agentMain(2, arguments) == 0);
    fflush(stdout);
    assert(dup2(saved, STDOUT_FILENO) >= 0);
    close(saved);
    char buffer[4096];
    ssize_t length = read(descriptors[0], buffer, sizeof(buffer));
    close(descriptors[0]);
    [distributedCenter removeObserver:token];
    assert(length > 0 && length < (ssize_t)sizeof(buffer));
    return [[NSString alloc] initWithBytes:buffer length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

static void statusUsesAgentReply(void) {
    for (unsigned enabled = 0; enabled < 2; enabled++) {
        reset();
        reopenPreference = @(!enabled);
        forceFnFPreference = @(!enabled);
        permission = !enabled;
        inputPermission = !enabled;
        NSString *output = statusOutput(@{ @"accessibility": @(enabled), @"reopenInFullScreen": @(enabled),
            @"forceFnF": @(enabled), @"fnFWatch": @(enabled), @"fnFKeyTap": @(!enabled), @"pending": @(enabled) });
        assert([output containsString:enabled ? @"Accessibility: granted\n" : @"Accessibility: not granted\n"]);
        assert([output containsString:enabled ? @"Reopen in full screen: on\n" : @"Reopen in full screen: off\n"]);
        assert([output containsString:enabled ? @"Force fn-F: on, fn watch active, key tap inactive\n"
            : @"Force fn-F: off, fn watch inactive, key tap active\n"]);
        assert(!trustChecks && !inputChecks);
    }
    reset();
    NSString *output = statusOutput(nil);
    assert([output containsString:@"Accessibility: unknown (agent not responding)\n"]);
    assert([output containsString:@"Reopen in full screen: unknown (agent not responding)\n"]);
    assert([output containsString:@"Force fn-F: unknown, fn watch unknown, key tap unknown (agent not responding)\n"]);
    assert(!trustChecks && !inputChecks);

    reset();
    forceFnFPreference = @YES;
    failHIDOpen = YES;
    __block unsigned replies = 0;
    agentRunHook = ^{
        replies++;
        NSDictionary *reply = requestAgentStatus();
        assert([reply[@"accessibility"] boolValue] && [reply[@"forceFnF"] boolValue]);
        assert(![reply[@"fnFWatch"] boolValue] && ![reply[@"fnFKeyTap"] boolValue]);
    };
    char *arguments[] = { "fullscreenkeeperd", NULL };
    assert(agentMain(1, arguments) == 0 && replies == 1);
}

static void settingsDuringStartup(void) {
    for (unsigned privateAPI = 0; privateAPI < 2; privateAPI++) {
        for (unsigned force = 0; force < 2; force++) {
            for (unsigned reopen = 0; reopen < 2; reopen++) {
                reset();
                privateAPIAvailable = privateAPI;
                reopenPreference = @YES;
                forceFnFPreference = @(!force);
                __block unsigned notifications = 0, runs = 0;
                preferenceReadHook = ^{
                    // The first read has captured the old fn-F value. Deliver the change before startup finishes.
                    assert(settingsObserverRegistrations == 1);
                    assert(!gReopenRunning && !gFnFHID && !gFnFKeyTap);
                    reopenPreference = @(reopen);
                    forceFnFPreference = @(force);
                    [distributedCenter postNotificationName:SettingsChanged object:nil userInfo:nil deliverImmediately:YES];
                    notifications++;
                    // Applying is deferred until startup has initialized the feature resources.
                    assert(!gReopenRunning && !gFnFHID && !gFnFKeyTap);
                };
                agentRunHook = ^{
                    runs++;
                    assert(notifications == 1 && !preferenceReadHook);
                    assert(gReopenInFullScreen == reopen && gReopenRunning == reopen && gForceFnF == force);
                    assert((gFnFHID != NULL) == force && (gFnFKeyTap != NULL) == force);
                    assert(hidOpen == force && !keyTapEnabled);
                    unsigned creations = tapCreations, spaceRegistrations = registrations;
                    loadSettings();
                    loadSettings();
                    assert(tapCreations == creations && registrations == spaceRegistrations);
                    NSDictionary *reply = requestAgentStatus();
                    assert([reply[@"accessibility"] boolValue] == gTrusted);
                    assert([reply[@"reopenInFullScreen"] boolValue] == reopen);
                    assert([reply[@"forceFnF"] boolValue] == force);
                    assert([reply[@"fnFWatch"] boolValue] == force && ![reply[@"fnFKeyTap"] boolValue]);
                    if (force) {
                        // Live state wins over both preferences and the stored enable intent.
                        forceFnFPreference = @NO;
                        keyTapEnabled = YES;
                        reply = requestAgentStatus();
                        assert([reply[@"fnFWatch"] boolValue] && [reply[@"fnFKeyTap"] boolValue]);
                        keyTapEnabled = NO;
                        forceFnFPreference = @YES;
                    }
                };
                char *arguments[] = { "fullscreenkeeperd", NULL };
                assert(agentMain(1, arguments) == 0 && runs == 1);
                assert(!gFnFHID && !gFnFKeyTap);
            }
        }
    }
}

static void launchAndObserverLifetime(void) {
    reset();
    TestApplication *windowed = application(101, NO);
    startRestore(windowed);
    gApplications = preferences = @{};
    startRestore(windowed);
    assert(axCalls == 0 && !gRestores.count && !gActivationObserver);
    TestApplication *first = application(102, YES);
    TestApplication *second = application(103, YES);
    startRestore(first);
    id token = gActivationObserver;
    startRestore(second);
    assert(token && gActivationObserver == token && gRestores.count == 2);
    workspace.frontmostApplication = first;
    fullscreen = YES;
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidActivateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: first }];
    assert(!gRestores[@102] && gRestores[@103] && gActivationObserver == token && writes == 0);
    finishRestore(gRestores[@103], NO, "test stop");
    assert(!gActivationObserver && !gRestores.count && trustChecks == 0);
    unsigned before = axCalls;
    workspace.frontmostApplication = second;
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidActivateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: second }];
    assert(axCalls == before && saves == 0);
}

static void runSpaceCheck(pid_t pid, NSUInteger index) {
    SpaceSeries *series = gSpaceChecks[@(pid)];
    assert(series && index < series->checks.count);
    dispatch_block_t check = series->checks[index];
    assert(!dispatch_block_testcancel(check));
    check();
}

static void assertStopped(SpaceSeries *series, NSArray<dispatch_block_t> *checks) {
    assert(!series->checks);
    for (dispatch_block_t check in checks) assert(dispatch_block_testcancel(check));
}

static void spaceChangeQueries(void) {
    reset();
    TestApplication *first = application(110, YES);
    TestApplication *second = application(111, YES);
    TestApplication *windowed = application(112, NO);
    workspace.frontmostApplication = first;
    char *arguments[] = { "fullscreenkeeperd", NULL };
    assert(agentMain(1, arguments) == 0);
    assert(gPreviousSpacePID == first.processIdentifier);

    // Only unknown reads schedule a series; the same PID's next query replaces it.
    nonstandard = YES;
    unsigned before = axCalls;
    [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    SpaceSeries *replaced = gSpaceChecks[@110];
    NSArray *oldChecks = [replaced->checks copy];
    assert(replaced && oldChecks.count == 4 && axCalls > before && saves == 0);
    before = axCalls;
    [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    assert(gSpaceChecks.count == 1 && gSpaceChecks[@110] != replaced);
    assertStopped(replaced, oldChecks);
    assert(axCalls > before && saves == 0);
    before = axCalls;
    for (dispatch_block_t check in oldChecks) check();
    assert(axCalls == before && gSpaceChecks.count == 1);  // stale callbacks cannot remove the replacement

    // Switching to a remembered app skips querying without canceling another app's series.
    workspace.frontmostApplication = second;
    before = axCalls;
    [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    assert(axCalls == before && gSpaceChecks.count == 1 && gSpaceChecks[@110]);
    assert(gPreviousSpacePID == second.processIdentifier && gLastSpaceChanges[@111]);
    nonstandard = NO;
    runSpaceCheck(110, 0);
    assert(axCalls > before && queriedPIDs.lastObject.intValue == 110 && saves == 1);
    assert(!gSpaceChecks.count && !gTerminationObserver);

    // A definite immediate read acts and ends the series, even if no settings write is needed.
    fullscreen = YES;
    workspace.frontmostApplication = first;
    spaceChanged();
    assert(preferences[first.bundleIdentifier] && saves == 2 && !gSpaceChecks.count);
    workspace.frontmostApplication = second;
    before = axCalls;
    spaceChanged();
    assert(axCalls == before && !gSpaceChecks.count);
    workspace.frontmostApplication = windowed;
    fullscreen = NO;
    spaceChanged();
    assert(!gSpaceChecks.count && saves == 2);

    // An unknown immediate read can resolve as full screen on any later read.
    nonstandard = YES;
    spaceChanged();
    assert(gSpaceChecks[@112] && !preferences[windowed.bundleIdentifier]);
    nonstandard = NO;
    fullscreen = YES;
    runSpaceCheck(112, 0);
    assert(remembered(windowed.bundleIdentifier) == StateFullscreen && saves == 3 && !gSpaceChecks.count);
}

static void differentAppImmediateOnly(void) {
    for (unsigned kind = 0; kind < 3; kind++) {
        reset();
        debugLogging = NO;
        TestApplication *app = application(127, NO);
        workspace.frontmostApplication = app;
        gPreviousSpacePID = 128;
        if (kind == 0) reportedWindows = @[];
        if (kind == 1) nonstandard = YES;
        if (kind == 2) windowsError = kAXErrorCannotComplete;
        spaceChanged();
        assert(([queriedPIDs isEqual:@[@127]]));
        assert(axCalls > 0 && saves == 0 && !logs.count);
        assert(!scheduledDelays.count && !gSpaceChecks.count && !gTerminationObserver);
        assert(gPreviousSpacePID == 127);
    }
}

static void boundedSpaceSeries(void) {
    // Every offset can be the first definite observation, or all four may remain unknown.
    for (NSUInteger definite = 0; definite <= 4; definite++) {
        for (unsigned full = 0; full < 2; full++) {
            reset();
            TestApplication *app = application(113, !full);
            workspace.frontmostApplication = app;
            gPreviousSpacePID = app.processIdentifier;
            nonstandard = YES;
            spaceChanged();
            SpaceSeries *series = gSpaceChecks[@113];
            NSArray *checks = [series->checks copy];
            assert(series && checks.count == 4 && gTerminationObserver && !gActivationObserver);
            assert(scheduledDelays.count == 4);
            const double expected[] = {0.15, 0.35, 0.6, 1.0};
            for (NSUInteger i = 0; i < 4; i++) {
                double delay = scheduledDelays[i].doubleValue;
                assert(delay > expected[i] - 0.05 && delay <= expected[i]);
                if (i == definite) { nonstandard = NO; fullscreen = full; }
                runSpaceCheck(113, i);
                if (i == definite || i == 3) break;
                assert(gSpaceChecks[@113] == series && saves == 0);
            }
            assert(!gSpaceChecks.count && !gTerminationObserver);
            assertStopped(series, checks);
            assert(saves == (definite < 4 ? 1u : 0u));
            assert(remembered(app.bundleIdentifier) == (definite < 4 ? (full ? StateFullscreen : StateWindowed)
                                                                 : (full ? StateWindowed : StateFullscreen)));
            unsigned before = axCalls;
            for (dispatch_block_t check in checks) check();
            assert(axCalls == before);  // even an explicitly invoked canceled block is harmless
        }
    }
}

static void twoAppsBothGetRead(void) {
    reset();
    TestApplication *first = application(114, YES);
    TestApplication *second = application(115, NO);
    workspace.frontmostApplication = first;
    gPreviousSpacePID = first.processIdentifier;
    nonstandard = YES;
    spaceChanged();
    assert(gSpaceChecks[@114] && preferences[first.bundleIdentifier] && saves == 0);
    id token = gTerminationObserver;
    workspace.frontmostApplication = second;
    spaceChanged();
    assert(gSpaceChecks.count == 1 && !gSpaceChecks[@115] && gTerminationObserver == token);
    assert(scheduledDelays.count == 4);  // a different app gets only its immediate read
    assert(([queriedPIDs isEqual:@[@114, @115]]));
    spaceChanged();  // the same app's next Space change may start its own series
    assert(gSpaceChecks.count == 2 && gTerminationObserver == token);
    assert(([queriedPIDs isEqual:@[@114, @115, @115]]));

    // Both transitions finish after their immediate reads; each series reads its original app.
    nonstandard = NO;
    fullscreen = NO;
    runSpaceCheck(114, 0);
    assert(!preferences[first.bundleIdentifier] && !preferences[second.bundleIdentifier]);
    assert(gSpaceChecks.count == 1 && gSpaceChecks[@115] && gTerminationObserver == token);
    fullscreen = YES;
    runSpaceCheck(115, 0);
    assert(!preferences[first.bundleIdentifier] && preferences[second.bundleIdentifier] && saves == 2);
    assert(([queriedPIDs isEqual:@[@114, @115, @115, @114, @115]]));
    assert(!gTerminationObserver);
}

static void quickExitThenQuit(void) {
    reset();
    TestApplication *app = application(116, YES);
    workspace.frontmostApplication = app;
    gPreviousSpacePID = app.processIdentifier;
    nonstandard = YES;  // Chess's exit animation has not exposed a standard window yet
    spaceChanged();
    assert(preferences[app.bundleIdentifier] && saves == 0 && gSpaceChecks[@116]);
    runSpaceCheck(116, 0);
    runSpaceCheck(116, 1);
    nonstandard = NO;  // standard at about 0.6 s, quits before the old one-second read
    runSpaceCheck(116, 2);
    assert(!preferences[app.bundleIdentifier] && saves == 1 && !gSpaceChecks.count);
    app.terminated = YES;
    assert(!gTerminationObserver);
}

static void seriesEligibility(void) {
    for (unsigned step = 0; step < 5; step++) {
        reset();
        TestApplication *app = application(117, NO);
        gPreviousSpacePID = app.processIdentifier;
        workspace.frontmostApplication = app;
        nonstandard = YES;
        spaceChanged();
        unsigned before = axCalls;
        if (step == 0) app.terminated = YES;
        if (step == 1) app.activationPolicy = NSApplicationActivationPolicyProhibited;
        if (step == 2) gTrusted = NO;
        if (step == 3) workspace.frontmostApplication = nil;
        if (step == 4) terminateDuringAttribute = CFSTR("AXFullScreen");
        nonstandard = NO;
        fullscreen = YES;
        runSpaceCheck(117, 0);
        if (step == 3) assert(axCalls > before && saves == 1 && preferences[app.bundleIdentifier]);
        else if (step == 4) assert(axCalls > before && app.terminated && saves == 0);
        else assert(axCalls == before && saves == 0 && !preferences[app.bundleIdentifier]);
        if (step == 1 || step == 2) {
            for (NSUInteger i = 1; i < 4; i++) runSpaceCheck(117, i);
            assert(axCalls == before);
        }
        assert(!gSpaceChecks.count && !gTerminationObserver);
    }
}

static void unknownWindowsKeepState(void) {
    // Empty, nonstandard, minimized, malformed and failed reads never learn Windowed.
    for (unsigned saved = 0; saved < 2; saved++) {
        for (unsigned kind = 0; kind < 7; kind++) {
            reset();
            TestApplication *app = application(118, saved);
            workspace.frontmostApplication = app;
            gPreviousSpacePID = app.processIdentifier;
            if (kind == 0) reportedWindows = @[];
            if (kind == 1) nonstandard = YES;
            if (kind == 2) minimized = YES;
            if (kind == 3) reportedWindows = @[@42];
            if (kind == 4) windowsError = kAXErrorCannotComplete;
            if (kind == 5) fullscreenError = kAXErrorCannotComplete;
            if (kind == 6) reportedWindows = nil;
            assert(applicationState(app, "test") == StateUnknown);
            spaceChanged();
            for (NSUInteger i = 0; i < 4; i++) runSpaceCheck(118, i);
            assert(!gSpaceChecks.count && !gTerminationObserver);
            assert(saves == 0 && remembered(app.bundleIdentifier) == (saved ? StateFullscreen : StateWindowed));
        }
    }
}

static NSArray<NSString *> *matchingLogs(NSString *text) {
    return [logs filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *line, NSDictionary *bindings) {
        (void)bindings;
        return [line containsString:text];
    }]];
}

static void windowServerStartup(void) {
    reset();
    privateAPIAvailable = YES;
    char *arguments[] = { "fullscreenkeeperd", NULL };
    assert(agentMain(1, arguments) == 0);
    assert(gWindowServerSpaceEvents && gWindowServerTransitions && libraryLoads == 2 && registrations == 2 && portRequests == 1);
    assert(([registeredTypes isEqual:@[@1327, @1328]]));
    assert(portOptions == 1 && addedSources == 1 && registeredNotify && portCallback);
    assert(managedDisplayReads == 1 && matchingLogs(@"fullscreen startup spaces=0").count == 1);
    assert(!applicationCreations && !activationPolicyChanges && !applicationRuns && runLoopRuns == 1);
    assert(matchingLogs(@"space events: windowserver transitions").count == 1);
    assert([spaceEventsPreference isEqual:@"windowserver transitions"]);
    TestApplication *app = application(130, NO);
    workspace.frontmostApplication = app;
    fullscreen = YES;
    unsigned before = axCalls;
    [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
    assert(axCalls == before && saves == 0);  // the public Space observer exists only in the fallback
    registeredNotify(1401, NULL, 0, NULL, connectionID);
    assert(axCalls == before && !delayedBlocks.count && !gSpaceChangePending);
    app = application(131, YES);
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: app }];
    assert(gRestores[@131] && gActivationObserver && gTerminationObserver);
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidActivateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: app }];
    finishRestore(gRestores[@131], YES, "test stop");
    assert(!gActivationObserver && !gTerminationObserver);

    // The pump drains every event and releases each returned reference.
    pumpEvent = CFDataCreateMutable(NULL, 0);
    CFIndex references = CFGetRetainCount(pumpEvent);
    eventsToDrain = 3;
    portCallback(NULL, NULL, 0, NULL);
    assert(eventReads == 4 && !eventsToDrain && CFGetRetainCount(pumpEvent) == references);
    portCallback(NULL, NULL, 0, NULL);
    assert(eventReads == 5);
    CFRelease(pumpEvent);
    pumpEvent = NULL;

    reset();
    privateAPIAvailable = YES;
    permission = NO;
    assert(agentMain(1, arguments) == 0);
    assert(!libraryLoads && !registrations && !managedDisplayReads && !applicationCreations && runLoopRuns == 1);
    assert(!matchingLogs(@"space events:").count);
}

static void windowServerFallbacks(void) {
    const char *symbols[] = { "SLSMainConnectionID", "SLSRegisterConnectionNotifyProc", "SLSGetEventPort",
                             "SLEventCreateNextEvent", "_CFMachPortSetOptions" };
    NSArray<NSString *> *reasons = @[@"SkyLight load failed", @"CoreFoundation load failed",
        @"missing symbol SLSMainConnectionID", @"missing symbol SLSRegisterConnectionNotifyProc",
        @"missing symbol SLSGetEventPort", @"missing symbol SLEventCreateNextEvent",
        @"missing symbol _CFMachPortSetOptions", @"SLSMainConnectionID returned no connection",
        @"SLSRegisterConnectionNotifyProc failed", @"SLSGetEventPort failed", @"SLSGetEventPort failed",
        @"CFMachPortCreateWithPort failed", @"CFMachPortCreateRunLoopSource failed",
        @"missing symbol SLSRemoveConnectionNotifyProc"];
    for (NSUInteger failure = 0; failure < reasons.count; failure++) {
        reset();
        privateAPIAvailable = failure != 0;
        if (failure == 1) failCoreFoundation = YES;
        if (failure >= 2 && failure <= 6) missingSymbol = symbols[failure - 2];
        if (failure == 7) connectionID = 0;
        if (failure == 8) registrationError = kCGErrorFailure;
        if (failure == 9) eventPortError = kCGErrorFailure;
        if (failure == 10) nullEventPort = YES;
        if (failure == 11) failMachPort = YES;
        if (failure == 12) failRunLoopSource = YES;
        if (failure == 13) missingSymbol = "SLSRemoveConnectionNotifyProc";
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        assert(!gWindowServerSpaceEvents && !addedSources && !managedDisplayReads && !activeTypes.count);
        assert(applicationCreations == 1 && activationPolicyChanges == 1 && applicationRuns == 1 && !runLoopRuns);
        assert(matchingLogs(@"space events: appkit fallback").count == 1 && matchingLogs(reasons[failure]).count == 1);
        assert([spaceEventsPreference isEqual:@"appkit fallback"]);
        TestApplication *app = application(132, NO);
        workspace.frontmostApplication = app;
        fullscreen = YES;
        unsigned before = axCalls;
        if (registeredNotify) {
            registeredNotify(1327, NULL, 16, NULL, connectionID);
            registeredNotify(1328, NULL, 16, NULL, connectionID);
            registeredNotify(1401, NULL, 16, NULL, connectionID);
        }
        assert(axCalls == before && !delayedBlocks.count);  // a partial setup cannot duplicate fallback delivery
        [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
        assert(axCalls > before && saves == 1);
    }
}

static void windowServerRegistrationFallbacks(void) {
    for (uint32_t type = 1327; type <= 1328; type++) {
        reset();
        privateAPIAvailable = YES;
        failedRegistrationType = type;
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        assert(gWindowServerSpaceEvents && !gWindowServerTransitions && addedSources == 1);
        NSArray *expected = type == 1327 ? @[@1327, @1401] : @[@1327, @1328, @1401];
        assert([registeredTypes isEqual:expected] && registrations == expected.count);
        assert(!applicationCreations && !applicationRuns && runLoopRuns == 1);
        assert(matchingLogs(@"space events: windowserver space changes").count == 1);
        assert([spaceEventsPreference isEqual:@"windowserver space changes"]);
        assert(matchingLogs([NSString stringWithFormat:@"SLSRegisterConnectionNotifyProc type=%u failed:", type]).count == 1);
        assert(!matchingLogs(@"appkit fallback").count);

        TestApplication *app = application(135, NO);
        workspace.frontmostApplication = app;
        fullscreen = YES;
        unsigned before = axCalls;
        [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
        registeredNotify(1327, NULL, 0, NULL, connectionID);
        registeredNotify(1328, NULL, 0, NULL, connectionID);
        assert(axCalls == before && !delayedBlocks.count && !gSpaceChangePending);
        registeredNotify(1401, NULL, 0, NULL, connectionID);
        assert(gSpaceChangePending && delayedBlocks.count == 1 && axCalls == before);
        assert(fabs(scheduledDelays[0].doubleValue - 0.05) < 0.000001);
        delayedBlocks[0]();
        assert(axCalls > before && saves == 1 && !gSpaceChangePending);
    }
}

static void notifySpace(uint32_t type, uint64_t sid) {
    registeredNotify(type, &sid, sizeof(sid), NULL, connectionID);
}

static void existingFullscreenSpaces(void) {
    reset();
    privateAPIAvailable = YES;
    TestApplication *direct = application(180, YES);
    TestApplication *tiled = application(181, YES);
    TestApplication *split = application(182, YES);
    workspace.frontmostApplication = split;
    uint64_t largeID = UINT64_C(0xfedcba9876543210);
    managedDisplays = @[@{ @"Spaces": @[
        @{ @"id64": @(largeID) },
        @{ @"ManagedSpaceID": @61, @"pid": @180 },
        @{ @"id64": @62, @"TileLayoutManager": @{ @"TileSpaces": @[@{ @"pid": @181 }] } },
        @{ @"id64": @63, @"pid": @[@181, @182] },
        @{ @"id64": @64, @"TileLayoutManager": @{ @"pid": @181 } },
        @{ @"id64": @65, @"pid": @[@180, @181] },
        @{ @"id64": @66, @"pid": @999 },
        @{ @"id64": @67, @"pid": @"bad", @"TileLayoutManager": @[@1] },
        @{ @"id64": @3, @"type": @4 }, @{ @"id64": @5 }, @{ @"id64": @6 },
        @{ @"id64": @0 }, @{ @"id64": @"bad", @"ManagedSpaceID": @68 }, @{}, @"bad"
    ] }, @{ @"Spaces": @[@{ @"id64": @(largeID) }] },
        @{ @"Spaces": @"bad" }, @"bad"];
    reportedSpaceTypes = @{ @3: @3, @5: @5, @6: @6 };
    CFIndex references = CFGetRetainCount((__bridge CFTypeRef)managedDisplays);
    char *arguments[] = { "fullscreenkeeperd", NULL };
    assert(agentMain(1, arguments) == 0);
    assert(managedDisplayReads == 1 && gFullscreenSpaces.count == 8 && !saves && !writes);
    assert(CFGetRetainCount((__bridge CFTypeRef)managedDisplays) == references);
    assert(matchingLogs(@"fullscreen startup spaces=8").count == 1);
    assert(!gFullscreenSpaces[@(largeID)]->app);
    assert(gFullscreenSpaces[@61]->app == direct && gFullscreenSpaces[@61]->pid == 180);
    assert([gFullscreenSpaces[@61]->bundleID isEqualToString:direct.bundleIdentifier]);
    assert(gFullscreenSpaces[@62]->app == tiled && gFullscreenSpaces[@64]->app == tiled);
    assert(gFullscreenSpaces[@63]->app == split);
    assert(!gFullscreenSpaces[@65]->app && !gFullscreenSpaces[@66]->app && !gFullscreenSpaces[@67]->app);
    // A known startup owner is retained even when a different app is frontmost at exit.
    unsigned before = axCalls;
    notifySpace(1328, 61);
    assert(!preferences[direct.bundleIdentifier] && preferences[split.bundleIdentifier] && saves == 1);
    assert(axCalls > before && queriedPIDs.lastObject.intValue == 180 && managedDisplayReads == 1);

    // Missing typing and failed type reads fall back to the dictionary; enumeration is optional.
    for (unsigned failure = 0; failure < 6; failure++) {
        reset();
        privateAPIAvailable = YES;
        if (failure == 0) missingSymbol = "SLSSpaceGetType";
        if (failure == 1) reportedSpaceType = -1;
        if (failure == 2) missingSymbol = "SLSCopyManagedDisplaySpaces";
        managedDisplays = failure == 3 ? nil : failure == 4 ? @"bad" : @[@{ @"Spaces": @[
            @{ @"id64": @70, @"type": @4 }, @{ @"ManagedSpaceID": @71, @"type": @4 },
            @{ @"id64": @72, @"type": @3 }, @{ @"id64": @73, @"type": @"bad" }
        ] }];
        if (failure == 5) debugLogging = NO;
        assert(startWindowServerSpaceEvents());
        assert(managedDisplayReads == (failure == 2 ? 0u : 1u));
        assert(gFullscreenSpaces.count == (failure < 2 ? 2u : failure == 5 ? 4u : 0u));
        assert(!saves && !axCalls && !scheduledDelays.count);
    }
}

static void unknownOwnerFullscreenExits(void) {
    // Existing Spaces with no owner must use the frontmost app and the normal conservative exit rules.
    for (unsigned outcome = 0; outcome < 10; outcome++) {
        reset();
        privateAPIAvailable = YES;
        managedDisplays = @[@{ @"Spaces": @[@{ @"id64": @80 }, @{ @"id64": @81 }] }];
        assert(startWindowServerSpaceEvents());
        TestApplication *app = application(183, YES);
        TestApplication *other = application(184, YES);
        workspace.frontmostApplication = app;
        if (outcome == 1 || outcome == 2 || outcome == 3) windowsError = kAXErrorCannotComplete;
        if (outcome == 3 || outcome == 4) app.terminated = YES;
        if (outcome == 5) terminateDuringAttribute = kAXWindowsAttribute;
        if (outcome == 6) fullscreen = YES;
        if (outcome == 7) workspace.frontmostApplication = nil;
        if (outcome == 8) gProtected[@183] = app;
        if (outcome == 9) startRestore(app);
        unsigned reads = spaceTypeReads;
        notifySpace(1328, 80);
        assert(!gFullscreenSpaces[@80] && gFullscreenSpaces[@81] && !gSpaceChangePending);
        assert(spaceTypeReads == reads && managedDisplayReads == 1);
        if (outcome == 1 || outcome == 2) {
            assert(gSpaceChecks[@183] && preferences[app.bundleIdentifier]);
            if (outcome == 1) windowsError = kAXErrorSuccess;
            for (NSUInteger i = 0; i < 4 && gSpaceChecks[@183]; i++) runSpaceCheck(183, i);
        }
        BOOL removes = outcome == 0 || outcome == 1;
        assert((preferences[app.bundleIdentifier] == nil) == removes);
        assert(saves == (removes ? 1u : 0u) && preferences[other.bundleIdentifier]);
        if (outcome == 4 || outcome == 7) assert(!axCalls);
        if (outcome == 9) assert(gRestores[@183]);
        NSUInteger logCount = logs.count;
        unsigned queries = axCalls;
        notifySpace(1328, 80);  // Duplicate and never-seen IDs remain ignored.
        notifySpace(1328, 999);
        assert(axCalls == queries && logs.count == logCount);
    }

    // Capture the app at notification receipt, before queued work can see a different frontmost app.
    reset();
    privateAPIAvailable = YES;
    managedDisplays = @[@{ @"Spaces": @[@{ @"id64": @82 }] }];
    assert(startWindowServerSpaceEvents());
    TestApplication *app = application(185, YES);
    TestApplication *other = application(186, YES);
    workspace.frontmostApplication = app;
    deferMainQueue = YES;
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ notifySpace(1328, 82); });
    workspace.frontmostApplication = other;
    assert(mainQueueBlocks.count == 1 && !axCalls && !saves);
    mainQueueBlocks.lastObject();
    assert(queriedPIDs.lastObject.intValue == 185 && !preferences[app.bundleIdentifier]);
    assert(preferences[other.bundleIdentifier] && saves == 1 && !gFullscreenSpaces.count);
}

static void windowServerSpacePayloads(void) {
    // Copy an unaligned Space ID, reject short/NULL payloads, and never query a destroyed ID.
    for (size_t length = 0; length <= 17; length++) {
        reset();
        privateAPIAvailable = YES;
        assert(startWindowServerSpaceEvents());
        workspace.frontmostApplication = application(170, NO);
        fullscreen = YES;
        deferMainQueue = YES;
        unsigned char storage[18] = {0};
        unsigned char *payload = storage + 1;
        uint64_t sid = UINT64_C(0x123456789abcdef0);
        memcpy(payload, &sid, sizeof(sid));
        registeredNotify(1327, payload, length, NULL, connectionID);
        registeredNotify(1328, payload, length, NULL, connectionID);
        memset(storage, 0, sizeof(storage));  // WindowServer owns the payload, not the queued work.
        BOOL valid = length >= sizeof(sid);
        assert(mainQueueBlocks.count == (valid ? 2 : 0));
        assert(spaceTypeReads == (valid ? 1 : 0) && !axCalls && !saves && !delayedBlocks.count);
        for (dispatch_block_t block in mainQueueBlocks) block();
        assert(!gFullscreenSpaces.count && !gSpaceChangePending && !delayedBlocks.count);
        assert(saves == (valid ? 1 : 0));
        assert(matchingLogs(@"fullscreen create sid=1311768467463790320 pid=170 bundle=test.app.170").count == (valid ? 1 : 0));
        assert(matchingLogs(@"fullscreen destroy sid=1311768467463790320 pid=170 bundle=test.app.170").count == (valid ? 1 : 0));
        NSUInteger queued = mainQueueBlocks.count;
        registeredNotify(1327, NULL, 16, NULL, connectionID);
        registeredNotify(1328, NULL, 16, NULL, connectionID);
        assert(mainQueueBlocks.count == queued);
    }
}

static void spaceTypeRecording(void) {
    reset();
    privateAPIAvailable = YES;
    assert(startWindowServerSpaceEvents());
    TestApplication *app = application(171, NO);
    workspace.frontmostApplication = app;
    for (NSNumber *type in @[@(-1), @0, @1, @2, @3, @5, @6]) {
        reportedSpaceType = type.intValue;
        notifySpace(1327, type.unsignedLongLongValue);
        notifySpace(1328, type.unsignedLongLongValue);
    }
    assert(spaceTypeReads == 7 && !gFullscreenSpaces.count && !saves && !axCalls && !delayedBlocks.count);
    assert(!matchingLogs(@"fullscreen create").count && !matchingLogs(@"fullscreen destroy").count);
    reportedSpaceType = 4;
    // Eligibility is required even though no Accessibility query is needed.
    for (unsigned ineligible = 0; ineligible < 5; ineligible++) {
        workspace.frontmostApplication = app;
        app.terminated = ineligible == 0;
        app.activationPolicy = ineligible == 1 ? NSApplicationActivationPolicyAccessory : NSApplicationActivationPolicyRegular;
        app.bundleIdentifier = ineligible == 2 ? @"" : ineligible == 3 ? (__bridge NSString *)PREFS_DOMAIN : @"test.app.171";
        if (ineligible == 4) workspace.frontmostApplication = nil;
        notifySpace(1327, 10);
        assert(!gFullscreenSpaces.count && !saves && !axCalls);
    }
    workspace.frontmostApplication = app;
    windowsError = kAXErrorCannotComplete;
    deferMainQueue = YES;
    __block uint64_t sid = UINT64_C(0xfedcba9876543210);
    dispatch_sync(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        notifySpace(1327, sid);
    });
    assert(queriedSpaceID == sid && !axCalls && !saves && mainQueueBlocks.count == 1);
    workspace.frontmostApplication = application(174, NO);
    mainQueueBlocks.lastObject();
    assert(gFullscreenSpaces[@(sid)]->pid == 171 && [gFullscreenSpaces[@(sid)]->bundleID isEqualToString:app.bundleIdentifier]);
    assert(preferences[app.bundleIdentifier] && saves == 1 && !axCalls && !scheduledDelays.count);
    assert(matchingLogs(@"fullscreen create sid=18364758544493064720 pid=171 bundle=test.app.171").count == 1);
    deferMainQueue = NO;
    workspace.frontmostApplication = app;
    debugLogging = NO;  // Recording is independent of debug logging.
    notifySpace(1327, 20);
    assert(gFullscreenSpaces.count == 2 && saves == 1 && !axCalls);
    debugLogging = YES;
    notifySpace(1328, sid);
    assert(gFullscreenSpaces.count == 1 && !axCalls && saves == 1 && !delayedBlocks.count);
    assert(matchingLogs(@"fullscreen destroy sid=18364758544493064720 pid=171 bundle=test.app.171").count == 1);
    unsigned reads = spaceTypeReads;
    workspace.frontmostApplication = testApplications[@174];
    notifySpace(1328, 20);
    assert(spaceTypeReads == reads && !gFullscreenSpaces.count && gSpaceChecks[@171]);
    assert(queriedPIDs.lastObject.intValue == 171 && saves == 1);
    for (NSUInteger i = 0; i < 4; i++) runSpaceCheck(171, i);
    assert(preferences[app.bundleIdentifier] && saves == 1 && !gSpaceChecks.count);
    NSUInteger logCount = logs.count;
    unsigned queries = axCalls;
    notifySpace(1328, 20);  // Unknown IDs never query or log, including duplicate destruction.
    assert(axCalls == queries && logs.count == logCount);

    // A pending restore keeps its own read-back path; creation still tracks the Space.
    reset();
    privateAPIAvailable = YES;
    assert(startWindowServerSpaceEvents());
    app = application(175, YES);
    workspace.frontmostApplication = app;
    startRestore(app);
    queries = axCalls;
    NSUInteger timers = scheduledDelays.count;
    notifySpace(1327, 30);
    assert(gRestores[@175] && gFullscreenSpaces[@30] && axCalls == queries && !saves);
    assert(scheduledDelays.count == timers);
    finishRestore(gRestores[@175], NO, "test failure");
    assert(gProtected[@175]);
    notifySpace(1327, 31);
    assert(!gProtected[@175] && axCalls == queries && !saves);
}

static void fullscreenSpaceExits(void) {
    // Immediate and delayed windowed reads target the remembered app after switching apps.
    // Unknown reads and quitting, including quitting during an AX call, preserve the entry.
    for (unsigned outcome = 0; outcome < 6; outcome++) {
        reset();
        privateAPIAvailable = YES;
        assert(startWindowServerSpaceEvents());
        TestApplication *app = application(176, NO);
        workspace.frontmostApplication = app;
        notifySpace(1327, 40);
        assert(saves == 1 && !axCalls && preferences[app.bundleIdentifier]);
        if (outcome == 0) app.terminated = YES;
        if (outcome == 2 || outcome == 3 || outcome == 4) windowsError = kAXErrorCannotComplete;
        if (outcome == 5) terminateDuringAttribute = kAXWindowsAttribute;
        if (outcome != 5) workspace.frontmostApplication = application(177, NO);
        notifySpace(1328, 40);
        assert(!gFullscreenSpaces.count && !gSpaceChangePending);
        if (outcome == 0 || outcome == 5) {
            assert(preferences[app.bundleIdentifier] && saves == 1 && !gSpaceChecks.count);
            if (outcome == 0) assert(!axCalls);
        } else if (outcome == 1) {
            assert(!preferences[app.bundleIdentifier] && saves == 2 && !gSpaceChecks.count);
            assert(queriedPIDs.lastObject.intValue == 176);
        } else {
            assert(gSpaceChecks[@176] && preferences[app.bundleIdentifier] && saves == 1);
            if (outcome == 2) windowsError = kAXErrorSuccess;
            if (outcome == 3) app.terminated = YES;
            unsigned queries = axCalls;
            runSpaceCheck(176, 0);
            if (outcome == 3) assert(axCalls == queries);
            if (outcome == 4) for (NSUInteger i = 1; i < 4; i++) runSpaceCheck(176, i);
            assert(!gSpaceChecks.count && !gTerminationObserver);
            assert((preferences[app.bundleIdentifier] != nil) == (outcome != 2));
            assert(saves == (outcome == 2 ? 2 : 1));
        }
    }
    // A fresh full-screen creation cancels an earlier exit series before it can erase the save.
    reset();
    privateAPIAvailable = YES;
    assert(startWindowServerSpaceEvents());
    TestApplication *app = application(178, NO);
    workspace.frontmostApplication = app;
    notifySpace(1327, 50);
    windowsError = kAXErrorCannotComplete;
    notifySpace(1328, 50);
    SpaceSeries *series = gSpaceChecks[@178];
    NSArray *checks = [series->checks copy];
    unsigned queries = axCalls;
    notifySpace(1327, 51);
    assertStopped(series, checks);
    windowsError = kAXErrorSuccess;
    for (dispatch_block_t check in checks) check();
    assert(axCalls == queries && !gSpaceChecks.count && saves == 1 && preferences[app.bundleIdentifier]);
}

static void windowServerBursts(void) {
    for (unsigned transitions = 0; transitions < 2; transitions++) {
        reset();
        privateAPIAvailable = YES;
        if (!transitions) failedRegistrationType = 1328;
        else missingSymbol = "SLSSpaceGetType";
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        TestApplication *app = application(133, NO);
        workspace.frontmostApplication = application(136, NO);
        // Transitions start a series even when a different app handled the previous event.
        gPreviousSpacePID = transitions ? 999 : app.processIdentifier;
        nonstandard = YES;
        deferMainQueue = YES;
        unsigned before = axCalls;
        // Callbacks may arrive on a worker, with data gone before the main queue handles the event.
        dispatch_sync(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char payload[24] = {0};
            registeredNotify(transitions ? 1327 : 1401, payload, sizeof(payload), NULL, connectionID);
            registeredNotify(transitions ? 1328 : 1401, NULL, 0, NULL, connectionID);
            registeredNotify(transitions ? 1327 : 1401, NULL, 8, NULL, connectionID);
        });
        assert(axCalls == before && mainQueueBlocks.count == 3 && !delayedBlocks.count && !gSpaceChangePending);
        assert(matchingLogs(@"windowserver event type=").count == 3);
        assert(matchingLogs(@"length=24").count == 1 && matchingLogs(@"length=0").count == 1);
        for (dispatch_block_t block in mainQueueBlocks) block();
        [mainQueueBlocks removeAllObjects];
        assert(gSpaceChangePending && delayedBlocks.count == 1 && axCalls == before);
        double delay = transitions ? 0.1 : 0.05;
        assert(scheduledDelays.count == 1 && fabs(scheduledDelays[0].doubleValue - delay) < 0.000001);
        registeredNotify(transitions ? 1328 : 1401, NULL, 0, NULL, connectionID);
        mainQueueBlocks.lastObject();
        assert(delayedBlocks.count == 1 && scheduledDelays.count == 1);  // never postpone a pending burst
        workspace.frontmostApplication = app;  // choose the frontmost app when handling, not at receipt
        dispatch_block_t coalesced = delayedBlocks[0];
        coalesced();
        assert(!gSpaceChangePending && axCalls > before && gSpaceChecks[@133] && queriedPIDs.lastObject.intValue == 133);
        SpaceSeries *series = gSpaceChecks[@133];
        NSArray *checks = [series->checks copy];
        assert(checks.count == 4 && gTerminationObserver);
        const double offsets[] = {0.15, 0.35, 0.6, 1.0};
        for (NSUInteger i = 0; i < 4; i++)
            assert(fabs(scheduledDelays[i + 1].doubleValue - offsets[i]) < 0.01);

        registeredNotify(transitions ? 1328 : 1401, NULL, 0, NULL, connectionID);
        dispatch_block_t queued = mainQueueBlocks.lastObject;
        queued();
        assert(delayedBlocks.count == 6 && gSpaceChangePending);
        coalesced = delayedBlocks.lastObject;
        nonstandard = NO;
        fullscreen = YES;
        coalesced();
        assertStopped(series, checks);
        assert(!gSpaceChangePending && !gSpaceChecks.count && saves == 1);

        // Only the Space-change fallback skips a different remembered full-screen app.
        workspace.frontmostApplication = application(134, YES);
        fullscreen = NO;
        before = axCalls;
        registeredNotify(transitions ? 1328 : 1401, NULL, 0, NULL, connectionID);
        queued = mainQueueBlocks.lastObject;
        queued();
        coalesced = delayedBlocks.lastObject;
        coalesced();
        assert(!gSpaceChecks.count && gPreviousSpacePID == 134);
        if (transitions) assert(axCalls > before && saves == 2 && !preferences[workspace.frontmostApplication.bundleIdentifier]);
        else assert(axCalls == before && saves == 1 && preferences[workspace.frontmostApplication.bundleIdentifier]);
    }
}

static void independentFeatureChanges(void) {
    for (unsigned path = 0; path < 4; path++) {
        reset();
        privateAPIAvailable = path != 3;
        if (path == 1) missingSymbol = "SLSSpaceGetType";
        if (path == 2) failedRegistrationType = 1328;
        TestApplication *saved = application(230, YES);
        TestApplication *other = application(231, NO);
        workspace.runningApplications = @[saved, other];
        workspace.frontmostApplication = saved;
        forceFnFPreference = @YES;
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        settingsChanged();  // The test run loop returns, so reattach its shortcut taps.
        IOHIDManagerRef hid = gFnFHID;
        CFMachPortRef keyTap = gFnFKeyTap;
        unsigned creations = tapCreations;
        assert(gReopenRunning && gLaunchObserver && hid && keyTap);
        assert((gSpaceObserver != nil) == (path == 3));
        assert((gSpaceSource != NULL) == (path < 3));
        NSDictionary *before = preferences;
        startRestore(saved);
        RestoreSession *session = gRestores[@230];
        assert(session && session->readBack && writes == 1);
        NSMutableArray<dispatch_block_t> *stale = [session->checks mutableCopy];
        [stale addObject:session->expiry];
        [stale addObject:session->readBack];
        workspace.frontmostApplication = other;
        windowsError = kAXErrorCannotComplete;
        recordSpaceChange(YES);
        SpaceSeries *series = gSpaceChecks[@231];
        assert(series && gActivationObserver && gTerminationObserver);
        [stale addObjectsFromArray:series->checks];
        dispatch_block_t queued = nil, coalesced = nil;
        if (path < 3) {
            deferMainQueue = YES;
            notifySpace(path == 2 ? 1401 : 1327, 990);
            queued = mainQueueBlocks.lastObject;
            if (path > 0) { queued(); coalesced = delayedBlocks.lastObject; }
            deferMainQueue = NO;
        }
        unsigned queries = axCalls, previousWrites = writes;
        reopenPreference = @NO;
        [distributedCenter postNotificationName:SettingsChanged object:nil];
        assert(!gReopenRunning && !gLaunchObserver && !gSpaceObserver && !gActivationObserver && !gTerminationObserver);
        assert(!gRestores.count && !gSpaceChecks.count && !gProtected.count && !gFullscreenSpaces.count);
        assert(!gSpaceSource && !gSpacePort && !activeTypes.count && !gWindowServerSpaceEvents && !gSpaceChangePending);
        assert(gFnFHID == hid && gFnFKeyTap == keyTap && tapCreations == creations);
        assert(!spaceEventsPreference && [preferences isEqual:before] && !saves);
        for (dispatch_block_t check in stale) { assert(dispatch_block_testcancel(check)); check(); }
        if (queued) queued();
        if (coalesced) coalesced();
        windowChanged(NULL, NULL, NULL, (__bridge void *)session);
        [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                                 userInfo:@{ NSWorkspaceApplicationKey: saved }];
        [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
        assert(axCalls == queries && writes == previousWrites && !saves && !gRestores.count);
        assert(!session->element && !session->target && !series->checks);
        assert(removedSpaceSources == (path < 3 ? 1u : 0u));
        assert(unregistrations == (path == 0 || path == 1 ? 2u : path == 2 ? 2u : 0u));

        reopenPreference = @YES;
        windowsError = kAXErrorSuccess;
        [distributedCenter postNotificationName:SettingsChanged object:nil];
        assert(gReopenRunning && gLaunchObserver && (gSpaceObserver != nil) == (path == 3));
        assert(activeTypes.count == (path < 2 ? 2u : path == 2 ? 1u : 0u));
        assert(gFnFHID == hid && gFnFKeyTap == keyTap && tapCreations == creations);
        queries = axCalls;
        if (queued) queued();
        if (coalesced) coalesced();
        for (dispatch_block_t check in stale) check();
        assert(axCalls == queries && writes == previousWrites && !saves && !gFullscreenSpaces.count);
        assert(!gRestores.count && [preferences isEqual:before]);
        id launch = gLaunchObserver, spaceObserver = gSpaceObserver;
        CFRunLoopSourceRef source = gSpaceSource;
        unsigned registrationsBefore = registrations;
        forceFnFPreference = @NO;
        [distributedCenter postNotificationName:SettingsChanged object:nil];
        assert(!gFnFHID && !gFnFKeyTap && !gFnFLaunchObserver && !gFnFTerminationObserver);
        assert(gReopenRunning && gLaunchObserver == launch && gSpaceObserver == spaceObserver && gSpaceSource == source);
        assert(registrations == registrationsBefore && axCalls == queries);
        // Reopening still restores launches when the shortcut is off.
        workspace.frontmostApplication = saved;
        [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                                 userInfo:@{ NSWorkspaceApplicationKey: saved }];
        assert(gRestores[@230] && writes == previousWrites + 1 && !saves);
    }
}

static void lateReopenFallback(void) {
    reset();
    reopenPreference = @NO;
    char *arguments[] = { "fullscreenkeeperd", NULL };
    assert(agentMain(1, arguments) == 0 && !applicationCreations && runLoopRuns == 1);
    reopenPreference = @YES;
    [distributedCenter postNotificationName:SettingsChanged object:nil];
    assert(gReopenRunning && gSpaceObserver && applicationCreations == 1 && applicationRuns == 1);
    reopenPreference = @NO;
    [distributedCenter postNotificationName:SettingsChanged object:nil];
    assert(!gSpaceObserver && !gLaunchObserver);
    reopenPreference = @YES;
    [distributedCenter postNotificationName:SettingsChanged object:nil];
    assert(gSpaceObserver && applicationCreations == 1 && applicationRuns == 1);
}

static void windowDiagnostics(void) {
    reset();
    TestApplication *app = application(119, YES);
    workspace.frontmostApplication = app;
    gPreviousSpacePID = app.processIdentifier;
    nonstandard = YES;
    fullscreen = YES;
    reportedWindows = @[@"one", @"two", @"three", @"four", @"five", @"six"];
    spaceChanged();
    NSArray *details = matchingLogs(@"now pid=119 window=");
    assert(details.count == 4);
    for (NSString *line in details) {
        assert([line containsString:@"subrole=AXDialog"]);
        assert([line containsString:@"fullscreen=true minimized=false"]);
    }
    fullscreenError = kAXErrorCannotComplete;
    minimized = YES;
    runSpaceCheck(119, 0);
    details = matchingLogs(@"series pid=119 window=");
    assert(details.count == 4);
    for (NSString *line in details)
        assert(([line containsString:[NSString stringWithFormat:@"fullscreen=%d minimized=true", kAXErrorCannotComplete]]));
    nonstandard = NO;
    minimized = NO;
    fullscreenError = kAXErrorSuccess;
    fullscreen = NO;
    runSpaceCheck(119, 1);
    assert(matchingLogs(@"subrole=AXStandardWindow fullscreen=false minimized=false").count == 4);
    assert(!gSpaceChecks.count && saves == 1);
}

static void terminationDiagnostics(void) {
    reset();
    TestApplication *pending = application(120, YES);
    TestApplication *saved = application(121, YES);
    TestApplication *unrelated = application(122, NO);
    workspace.frontmostApplication = pending;
    gPreviousSpacePID = pending.processIdentifier;
    nonstandard = YES;
    spaceChanged();
    SpaceSeries *series = gSpaceChecks[@120];
    NSArray *checks = [series->checks copy];
    id token = gTerminationObserver;
    assert(token && !gActivationObserver);
    // The observer also reports saved apps, including the time of a skipped Space change.
    workspace.frontmostApplication = saved;
    spaceChanged();
    assert(gTerminationObserver == token && gLastSpaceChanges[@121]);
    gLastSpaceChanges[@121] = @(now() - 0.55);
    unsigned before = axCalls;
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: saved }];
    NSArray *entries = matchingLogs(@"terminate pid=121");
    assert(entries.count == 1 && [entries[0] containsString:@"series=0 saved=1 since-space=0.55"]);
    assert(!gLastSpaceChanges[@121] && gTerminationObserver == token && axCalls == before && saves == 0);
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: unrelated }];
    assert(matchingLogs(@"terminate pid=122").count == 0);

    pending.terminated = YES;  // Command-Q while the subrole still reports a nonstandard window
    gLastSpaceChanges[@120] = @(now() - 0.35);
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: pending }];
    entries = matchingLogs(@"terminate pid=120");
    assert(entries.count == 1 && [entries[0] containsString:@"series=1 saved=1 since-space=0.35"]);
    assertStopped(series, checks);
    assert(!gSpaceChecks.count && !gTerminationObserver && !gLastSpaceChanges[@120]);
    for (dispatch_block_t check in checks) check();
    assert(axCalls == before && saves == 0 && preferences[pending.bundleIdentifier]);

    // A restore keeps the termination observer alive after the last series finishes.
    reset();
    saved = application(123, YES);
    pending = application(124, NO);
    startRestore(saved);
    RestoreSession *restore = gRestores[@123];
    token = gTerminationObserver;
    assert(token && gActivationObserver);
    workspace.frontmostApplication = pending;
    gPreviousSpacePID = pending.processIdentifier;
    nonstandard = YES;
    spaceChanged();
    nonstandard = NO;
    runSpaceCheck(124, 0);
    assert(!gSpaceChecks.count && gTerminationObserver == token && gRestores[@123] == restore);
    saved.terminated = YES;
    before = axCalls;
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: saved }];
    entries = matchingLogs(@"terminate pid=123");
    assert(entries.count == 1 && [entries[0] containsString:@"since-space=-1.000"]);
    assert(gRestores[@123] == restore && gTerminationObserver == token && axCalls == before);
    // Restore cleanup still happens through its existing scheduled step.
    dispatch_block_t check = restore->checks.firstObject;
    check();
    assert(!gRestores.count && !gActivationObserver && !gTerminationObserver && saves == 0);

    // A series likewise keeps the observer alive after the last restore finishes.
    reset();
    saved = application(125, YES);
    pending = application(126, NO);
    startRestore(saved);
    workspace.frontmostApplication = pending;
    gPreviousSpacePID = pending.processIdentifier;
    nonstandard = YES;
    spaceChanged();
    token = gTerminationObserver;
    finishRestore(gRestores[@125], YES, "test stop");
    assert(!gRestores.count && !gActivationObserver && gTerminationObserver == token);
    for (NSUInteger i = 0; i < 4; i++) runSpaceCheck(126, i);
    assert(!gTerminationObserver);
}

static void permissionChangeChecks(void) {
    for (unsigned trusted = 0; trusted < 2; trusted++) {
        for (int status = 0; status < 3; status++) {
            reset();
            permission = trusted;
            char *arguments[] = { "fullscreenkeeperd", NULL };
            assert(agentMain(1, arguments) == 0);
            childStatus = status;
            [distributedCenter postNotificationName:@"com.apple.accessibility.api" object:nil];
            assert(childChecks == 1 && trustChecks == 1 && gTrusted == permission);
            assert(restartStatus == (status < 2 && (status == 0) != permission ? 1 : -1));
            restartStatus = -1;
            childReason = NSTaskTerminationReasonUncaughtSignal;
            [distributedCenter postNotificationName:@"com.apple.accessibility.api" object:nil];
            assert(childChecks == 2 && restartStatus == -1);
            childLaunches = NO;
            [distributedCenter postNotificationName:@"com.apple.accessibility.api" object:nil];
            assert(childChecks == 3 && restartStatus == -1);
        }
    }
}

static void terminatedRecording(void) {
    reset();
    TestApplication *app = application(104, YES);
    app.terminated = YES;
    unsigned before = axCalls;
    recordApplication(app, NO, "now");
    saveState(app, StateWindowed);
    assert(axCalls == before && saves == 0);
    assert(remembered(app.bundleIdentifier) == StateFullscreen);

    // Quitting during an AX read must not teach either Windowed or Fullscreen.
    for (unsigned saved = 0; saved < 2; saved++) {
        reset();
        app = application(105, saved);
        workspace.frontmostApplication = app;
        fullscreen = !saved;
        terminateDuringAttribute = CFSTR("AXFullScreen");
        recordApplication(app, NO, "now");
        assert(app.terminated && saves == 0);
        assert(remembered(app.bundleIdentifier) == (saved ? StateFullscreen : StateWindowed));
    }
}

static void terminatedRestoreSteps(void) {
    for (unsigned step = 0; step < 5; step++) {
        reset();
        TestApplication *app = application(106, YES);
        // Steps: fallback, expiry, pending read-back, quitting during focus checks, quitting during read-back.
        if (step >= 2) workspace.frontmostApplication = app;
        if (step == 3) terminateDuringSettable = YES;
        startRestore(app);
        RestoreSession *session = gRestores[@106];
        if (step != 3) {
            dispatch_block_t check = step == 0 ? session->checks.firstObject : step == 1 ? session->expiry : session->readBack;
            assert(check);
            if (step == 4) terminateDuringAttribute = CFSTR("AXFullScreen");
            else app.terminated = YES;
            unsigned before = axCalls;
            check();
            if (step != 4) assert(axCalls == before);
            assert(!session->element && !session->target && !session->checks && !session->readBack && !session->expiry);
        }
        assert(app.terminated && !gRestores.count && !gProtected.count && !gActivationObserver);
        assert(writes == (step == 2 || step == 4 ? 1u : 0u) && saves == 0 && trustChecks == 0);
        assert(remembered(app.bundleIdentifier) == StateFullscreen);
    }
}

static void ignoredSettingsCleanup(void) {
    reset();
    TestApplication *app = application(200, YES);
    TestApplication *other = application(201, YES);
    NSDictionary *otherEntry = preferences[other.bundleIdentifier];
    ignoredPreferences = @{ app.bundleIdentifier: @{ @"name": app.localizedName } };
    settingsChanged();
    assert(gIgnoredApplications == ignoredPreferences && gApplications == preferences);
    assert(!preferences[app.bundleIdentifier] && preferences.count == 1 && saves == 1);
    assert([preferences[other.bundleIdentifier] isEqual:otherEntry]);
    assert(remembered(app.bundleIdentifier) == StateWindowed && remembered(other.bundleIdentifier) == StateFullscreen);
    loadSettings();
    assert(saves == 1);

    // Even a stale remembered entry cannot bypass the ignore rule.
    gApplications = @{ app.bundleIdentifier: @{ @"name": app.localizedName, @"fullscreen": @YES } };
    workspace.frontmostApplication = app;
    fullscreen = YES;
    unsigned before = axCalls;
    assert(applicationState(app, "test") == StateUnknown);
    assert(recordApplication(app, NO, "now") == StateUnknown);
    assert(recordApplication(app, YES, "startup") == StateUnknown);
    recordSpaceChange(YES);
    spaceChanged();
    startRestore(app);
    saveState(app, StateFullscreen);
    assert(axCalls == before && writes == 0 && saves == 1 && !gRestores.count && !gSpaceChecks.count);
    assert(!preferences[app.bundleIdentifier]);

    // saveState reloads defaults before saving, including an ignore added since its last read.
    gIgnoredApplications = @{};
    saveState(app, StateFullscreen);
    assert(!preferences[app.bundleIdentifier] && saves == 1 && axCalls == before);

    // Removing an ignore does not resurrect its old remembered state; a new full-screen observation can add it.
    ignoredPreferences = @{};
    settingsChanged();
    startRestore(app);
    assert(!gRestores.count && axCalls == before && !preferences[app.bundleIdentifier]);
    recordApplication(app, NO, "now");
    assert(preferences[app.bundleIdentifier] && preferences[other.bundleIdentifier] && saves == 2);

    // Missing or malformed ignored defaults are treated as an empty list.
    for (id value in @[@"invalid", NSNull.null]) {
        ignoredPreferences = value == NSNull.null ? nil : value;
        loadSettings();
        assert(!gIgnoredApplications.count && saves == 2);
    }
}

static void ignoredEventPaths(void) {
    // Space handling never remembers or restores ignored apps. Force fn-F still toggles them.
    for (unsigned path = 0; path < 4; path++) {
        reset();
        privateAPIAvailable = path != 3;
        forceFnFPreference = @YES;
        if (path == 1) missingSymbol = "SLSSpaceGetType";
        if (path == 2) failedRegistrationType = 1327;
        TestApplication *app = application(202, YES);
        ignoredPreferences = @{ app.bundleIdentifier: @{ @"name": app.localizedName } };
        workspace.frontmostApplication = app;
        workspace.runningApplications = @[app];
        fullscreen = YES;
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        assert(([queriedPIDs isEqual:@[@0]]));  // startup only sets the system-wide messaging timeout
        assert(!preferences[app.bundleIdentifier] && saves == 1);
        unsigned before = axCalls;
        [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                                 userInfo:@{ NSWorkspaceApplicationKey: app }];
        if (path == 0) {
            notifySpace(1327, 900);
            notifySpace(1328, 900);
            assert(!gFullscreenSpaces.count);
        } else if (path < 3) {
            if (path == 1) {
                notifySpace(1327, 900);
                notifySpace(1328, 900);
            } else registeredNotify(1401, NULL, 0, NULL, connectionID);
            assert(delayedBlocks.count == 1);
            delayedBlocks[0]();
        } else {
            [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
            [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification object:nil];
        }
        assert(axCalls == before && writes == 0 && saves == 1 && !preferences.count);
        assert(!gRestores.count && !gSpaceChecks.count && !gActivationObserver && !gTerminationObserver);
        settingsChanged();  // The test run loop returns, so reattach its shortcut taps.
        fnInput(0xFF, 1);
        TestKeyEvent key = { kVK_ANSI_F, kCGEventFlagMaskSecondaryFn, NO, app.processIdentifier };
        for (unsigned exiting = 0; exiting < 2; exiting++) {
            fullscreen = exiting != 0;
            NSUInteger logCount = logs.count;
            assert(!fnFKeyEvent(NULL, kCGEventKeyDown, (CGEventRef)&key, NULL));
            assert(!fnFKeyEvent(NULL, kCGEventKeyUp, (CGEventRef)&key, NULL));
            assert(writes == exiting + 1 && lastWrittenFullscreen == !exiting && logs.count == logCount);
            unsigned afterToggle = axCalls;
            fullscreen = !exiting;
            if (path < 2) notifySpace(exiting ? 1328 : 1327, 901);
            else if (path == 2) {
                registeredNotify(1401, NULL, 0, NULL, connectionID);
                delayedBlocks.lastObject();
            } else {
                [workspace.notificationCenter postNotificationName:NSWorkspaceActiveSpaceDidChangeNotification
                                                          object:nil];
            }
            startRestore(app);
            assert(axCalls == afterToggle && writes == exiting + 1 && saves == 1 && !preferences.count);
            assert(!gRestores.count && !gSpaceChecks.count && !gFullscreenSpaces.count);
        }
    }
}

static void ignoringCancelsPendingWork(void) {
    // Ignore while waiting for focus, waiting for read-back, or waiting for an unknown Space exit.
    for (unsigned step = 0; step < 3; step++) {
        reset();
        privateAPIAvailable = YES;
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        TestApplication *app = application(203, YES);
        TestApplication *other = application(204, YES);
        RestoreSession *session = nil;
        SpaceSeries *series = nil;
        NSArray<dispatch_block_t> *checks;
        if (step < 2) {
            if (step == 1) workspace.frontmostApplication = app;
            startRestore(app);
            session = gRestores[@203];
            assert(session && (step == 0 ? !session->readBack : session->readBack != nil));
            NSMutableArray *callbacks = [session->checks mutableCopy];
            [callbacks addObject:session->expiry];
            if (session->readBack) [callbacks addObject:session->readBack];
            checks = callbacks;
        } else {
            workspace.frontmostApplication = app;
            nonstandard = YES;
            recordSpaceChange(YES);
            series = gSpaceChecks[@203];
            assert(series);
            checks = [series->checks copy];
        }
        unsigned before = axCalls, previousWrites = writes;
        ignoredPreferences = @{ app.bundleIdentifier: @{ @"name": app.localizedName } };
        [distributedCenter postNotificationName:SettingsChanged object:nil];
        assert(!gRestores.count && !gSpaceChecks.count && !gProtected.count);
        assert(!gActivationObserver && !gTerminationObserver);
        if (session) assert(!session->element && !session->target && !session->checks && !session->readBack && !session->expiry);
        if (series) assert(!series->checks);
        for (dispatch_block_t check in checks) check();
        if (session) windowChanged(NULL, NULL, NULL, (__bridge void *)session);
        fullscreen = YES;
        nonstandard = NO;
        recordApplication(app, NO, "now");
        startRestore(app);
        saveState(app, StateFullscreen);
        assert(axCalls == before && writes == previousWrites && saves == 1);
        assert(!preferences[app.bundleIdentifier] && preferences[other.bundleIdentifier]);
    }
}

static void ignoredSpaceOwners(void) {
    // Space exits must not remember or restore ignored owners. Force fn-F still works in them.
    for (unsigned startup = 0; startup < 2; startup++) {
        reset();
        privateAPIAvailable = YES;
        TestApplication *app = application(205, NO);
        TestApplication *other = application(206, NO);
        workspace.frontmostApplication = app;
        if (startup) {
            ignoredPreferences = @{ app.bundleIdentifier: @{ @"name": app.localizedName } };
            managedDisplays = @[@{ @"Spaces": @[@{ @"id64": @901, @"pid": @205 }] }];
        }
        char *arguments[] = { "fullscreenkeeperd", NULL };
        assert(agentMain(1, arguments) == 0);
        if (!startup) {
            notifySpace(1327, 901);
            assert(preferences[app.bundleIdentifier]);
            ignoredPreferences = @{ app.bundleIdentifier: @{ @"name": app.localizedName } };
            [distributedCenter postNotificationName:SettingsChanged object:nil];
        }
        assert(gFullscreenSpaces[@901]->app == app);
        unsigned before = axCalls, previousSaves = saves;
        workspace.frontmostApplication = other;
        fullscreen = YES;
        notifySpace(1328, 901);
        assert(axCalls == before && saves == previousSaves && !preferences.count && !gSpaceChecks.count);
        assert(!gFullscreenSpaces.count);
    }
}

static void fnFTapLifecycle(void) {
    reset();
    reopenPreference = @NO;
    settingsChanged();
    assert(!gForceFnF && !hidCreations && !tapCreations && !gFnFHID && !gFnFKeyTap);
    forceFnFPreference = @YES;
    gTrusted = NO;
    settingsChanged();
    assert(gForceFnF && !hidCreations && !tapCreations && !gFnFHID && !gFnFKeyTap);
    gTrusted = YES;
    inputPermission = NO;
    settingsChanged();
    assert(!gInputMonitoringGranted && !hidCreations && !tapCreations && !gFnFHID && !gFnFKeyTap);
    inputPermission = YES;
    settingsChanged();
    assert(tapCreations == 1 && hidCreations == 1 && hidOpen && !keyTapEnabled && tapSourceCreations == 1);
    assert(gFnFLaunchObserver && gFnFTerminationObserver && !axCalls);
    settingsChanged();
    assert(tapCreations == 1 && hidCreations == 1);
    inputPermission = NO;
    loadSettings();
    assert(!gFnFHID && !gFnFKeyTap && hidCloses == 1 && hidUnscheduled == 1);
    inputPermission = YES;
    loadSettings();
    forceFnFPreference = @NO;
    loadSettings();
    assert(!gFnFHID && !gFnFKeyTap && !gFnFLaunchObserver && !gFnFTerminationObserver);
    assert(!hidOpen && !keyTapEnabled && tapInvalidations == 2 && tapSourceRemovals == 2);
    forceFnFPreference = @YES;
    loadSettings();
    assert(tapCreations == 3);
    childStatus = 1;
    checkPermission();
    assert(restartStatus == 1 && !gFnFHID && !gFnFKeyTap && tapInvalidations == 3);

    for (unsigned failure = 1; failure <= 4; failure++) {
        reset();
        forceFnFPreference = @YES;
        reopenPreference = @NO;
        failTapCreation = failure == 1;
        failTapSourceCreation = failure == 2;
        failHIDCreation = failure == 3;
        failHIDOpen = failure == 4;
        settingsChanged();
        assert(!gFnFHID && !gFnFKeyTap && !gFnFBundleIDs && !gFnFLaunchObserver);
        assert(!hidOpen && !keyTapEnabled && tapInvalidations == (failure == 1 ? 0u : 1u));
        unsigned creations = tapCreations;
        failTapCreation = failTapSourceCreation = 0;
        failHIDCreation = failHIDOpen = NO;
        loadSettings();
        assert(tapCreations == creations + 1 && gFnFHID && gFnFKeyTap);
        loadSettings();
        assert(tapCreations == creations + 1);
    }
}

static TestApplication *startFnF(void) {
    reset();
    TestApplication *app = application(210, NO);
    workspace.runningApplications = @[app];
    workspace.frontmostApplication = app;
    reopenPreference = @NO;
    forceFnFPreference = @YES;
    settingsChanged();
    fnInput(0xFF, 1);
    [logs removeAllObjects];
    deferMainQueue = YES;
    return app;
}

static void fnFKeyFlow(void) {
    TestApplication *app = startFnF();
    TestKeyEvent key = { kVK_LeftArrow, kCGEventFlagMaskSecondaryFn, NO, app.processIdentifier };
    CGEventRef event = (CGEventRef)&key;
    assert(keyTapEnabled);
    assert(fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL) == event);
    key.keycode = kVK_ANSI_F;
    assert(!fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL) && gFnFSwallowedDown);
    assert(mainQueueBlocks.count == 1 && !axCalls && !writes && !saves);
    key.autorepeat = YES;
    assert(!fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL) && mainQueueBlocks.count == 1);
    key.flags |= kCGEventFlagMaskShift;
    key.autorepeat = NO;
    assert(!fnFKeyEvent(NULL, kCGEventKeyUp, event, NULL) && !gFnFSwallowedDown);
    assert(!axCalls && mainQueueBlocks.count == 1);
    mainQueueBlocks.lastObject();
    assert(writes == 1 && lastWrittenFullscreen && queriedPIDs.lastObject.intValue == app.processIdentifier && !saves);
    key.flags = kCGEventFlagMaskSecondaryFn;
    fullscreen = YES;
    assert(!fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL));
    assert(!fnFKeyEvent(NULL, kCGEventKeyUp, event, NULL));
    mainQueueBlocks.lastObject();
    assert(writes == 2 && !lastWrittenFullscreen && !saves);
    fnInput(0xFF, 0);
    assert(!keyTapEnabled && hidOpen && !gFnFSwallowedDown);
    assert(!logs.count);
}

static void fnFTargetCache(void) {
    TestApplication *app = startFnF();
    TestKeyEvent key = { kVK_ANSI_F, kCGEventFlagMaskSecondaryFn, NO, 999 };
    CGEventRef event = (CGEventRef)&key;
    assert(fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL) == event);
    TestApplication *self = application(211, NO);
    self.bundleIdentifier = (__bridge NSString *)PREFS_DOMAIN;
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: self }];
    key.pid = self.processIdentifier;
    assert(fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL) == event);
    ignoredPreferences = @{ app.bundleIdentifier: @{ @"name": @"Test App" } };
    settingsChanged();
    key.pid = app.processIdentifier;
    assert(!fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL));
    assert(!fnFKeyEvent(NULL, kCGEventKeyUp, event, NULL));
    assert(mainQueueBlocks.count == 1 && !axCalls && tapCreations == 1);
    mainQueueBlocks.lastObject();
    assert(writes == 1 && lastWrittenFullscreen && !saves && !logs.count);
    unsigned before = axCalls;
    TestApplication *launched = application(212, NO);
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidLaunchApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: launched }];
    assert([gFnFBundleIDs[@212] isEqual:launched.bundleIdentifier]);
    [workspace.notificationCenter postNotificationName:NSWorkspaceDidTerminateApplicationNotification object:nil
                                             userInfo:@{ NSWorkspaceApplicationKey: launched }];
    assert(!gFnFBundleIDs[@212]);
    key.pid = 212;
    assert(fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL) == event && axCalls == before);
}

static void fnFDisableNotifications(void) {
    startFnF();
    assert(keyTapEnableCalls == 2 && gFnFKeyTapEnabled && keyTapEnabled);
    fnInput(0xFF, 1);
    assert(keyTapEnableCalls == 2);
    fnInput(0xFF, 0);
    assert(!gFnFKeyTapEnabled && !keyTapEnabled && keyTapEnableCalls == 3);
    fnInput(0xFF, 0);
    for (unsigned i = 0; i < 10; i++) fnFKeyEvent(NULL, kCGEventTapDisabledByUserInput, NULL, NULL);
    assert(keyTapEnableCalls == 3 && !gFnFKeyTapEnabled && !keyTapEnabled);
    fnInput(0xFF00, 1);
    keyTapEnabled = NO;
    gFnFSwallowedDown = YES;
    fnFKeyEvent(NULL, kCGEventTapDisabledByUserInput, NULL, NULL);
    assert(keyTapEnableCalls == 4 && !keyTapEnabled && gFnFSwallowedDown && gFnFKeyTapEnabled);
    assert(!axCalls && !mainQueueBlocks.count && !logs.count);
}

static void fnFTimeoutRecovery(void) {
    startFnF();
    keyTapEnabled = NO;
    gFnFSwallowedDown = YES;
    double before = now();
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(keyTapEnabled && keyTapEnableCalls == 3 && gFnFKeyTapNextRecovery >= before + 1.0);
    assert(gFnFSwallowedDown && gFnFKeyTapEnabled);
    keyTapEnabled = NO;
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(!keyTapEnabled && keyTapEnableCalls == 3);
    gFnFKeyTapNextRecovery = now() - 1.0;
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(keyTapEnabled && keyTapEnableCalls == 4);
    gFnFSwallowedDown = NO;
    fnInput(0xFF00, 0);
    gFnFKeyTapNextRecovery = 0;
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(!gFnFKeyTapEnabled && !keyTapEnabled && keyTapEnableCalls == 5);
    fnInput(0xFF, 1);
    keyTapEnabled = NO;
    gForceFnF = NO;
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    gForceFnF = YES;
    gTrusted = NO;
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    gTrusted = YES;
    gInputMonitoringGranted = NO;
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(!keyTapEnabled && keyTapEnableCalls == 6);
    stopFnFTaps();
    assert(keyTapEnableCalls == 7 && !gFnFKeyTapNextRecovery);
    fnFKeyEvent(NULL, kCGEventTapDisabledByTimeout, NULL, NULL);
    assert(keyTapEnableCalls == 7 && !axCalls && !mainQueueBlocks.count && !logs.count);
}

static void fnFReleaseOrder(void) {
    TestApplication *app = startFnF();
    TestKeyEvent key = { kVK_ANSI_F, kCGEventFlagMaskSecondaryFn, NO, app.processIdentifier };
    CGEventRef event = (CGEventRef)&key;
    assert(!fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL));
    fnInput(0xFF, 0);
    assert(keyTapEnabled && gFnFSwallowedDown && gFnFReleaseTimeout && delayedBlocks.count == 1);
    assert(scheduledDelays.lastObject.doubleValue == 1.0);
    dispatch_block_t timeout = delayedBlocks.lastObject;
    fnInput(0xFF, 0);  // Duplicate values must not extend the timeout.
    assert(delayedBlocks.count == 1);
    key.flags = 0;
    assert(!fnFKeyEvent(NULL, kCGEventKeyUp, event, NULL));
    assert(!keyTapEnabled && !gFnFSwallowedDown && !gFnFReleaseTimeout);
    fnInput(0xFF00, 1);
    timeout();  // A stale timeout must not disable a later fn press.
    assert(keyTapEnabled);
    key.flags = kCGEventFlagMaskSecondaryFn;
    assert(!fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL));
    fnInput(0xFF00, 0);
    delayedBlocks.lastObject();
    assert(!keyTapEnabled && !gFnFSwallowedDown && !gFnFReleaseTimeout);
    assert(fnFKeyEvent(NULL, kCGEventKeyUp, event, NULL) == event);
    fnInput(0xFF, 1);
    assert(!fnFKeyEvent(NULL, kCGEventKeyDown, event, NULL));
    fnInput(0xFF, 0);
    timeout = delayedBlocks.lastObject;
    stopFnFTaps();
    timeout();
    assert(!gFnFHID && !keyTapEnabled && !gFnFSwallowedDown && !logs.count);
}

static void fnFDeferredToggle(void) {
    for (unsigned outcome = 0; outcome < 6; outcome++) {
        TestApplication *app = startFnF();
        TestKeyEvent key = { kVK_ANSI_F, kCGEventFlagMaskSecondaryFn, NO, app.processIdentifier };
        assert(!fnFKeyEvent(NULL, kCGEventKeyDown, (CGEventRef)&key, NULL) && !axCalls);
        if (outcome == 0) fullscreenUnwritable = YES;
        if (outcome == 1) fullscreenError = kAXErrorAttributeUnsupported;
        if (outcome == 2) { forceFnFPreference = @NO; settingsChanged(); }
        if (outcome == 3) gIgnoredApplications = @{ app.bundleIdentifier: @{} };
        if (outcome == 4) app.terminated = YES;
        if (outcome == 5) app.bundleIdentifier = @"test.reused.pid";
        mainQueueBlocks.lastObject();
        assert(writes == (outcome == 3 ? 1u : 0u) && !saves);
        assert(!logs.count);
        if (outcome >= 2 && outcome != 3) assert(!axCalls);
    }
}

static void updaterCommands(void) {
    reset();
    updaterCalls = 0;
    char *plain[] = { "fullscreenkeeperd", "--update-check", NULL };
    assert(agentMain(2, plain) == 0 && updaterCalls == 1 && !updaterForce && !updaterInstall);
    char *forced[] = { "fullscreenkeeperd", "--update-check", "--force", NULL };
    assert(agentMain(3, forced) == 0 && updaterCalls == 2 && updaterForce && !updaterInstall);
    char *install[] = { "fullscreenkeeperd", "--update-check", "--force", "--install", NULL };
    assert(agentMain(4, install) == 0 && updaterCalls == 3 && updaterForce && updaterInstall);
    char *invalid[] = { "fullscreenkeeperd", "--update-check", "--unknown", NULL };
    assert(agentMain(3, invalid) == 1 && updaterCalls == 3);
    assert(!trustChecks && !axCalls && !saves && !applicationCreations && !libraryLoads);
}

int main(void) {
    @autoreleasepool {
        updaterCommands();
        reopenDefaults();
        reopenOffAtStartup();
        legacySettingsCleanup();
        immediateExitRemovesEntry();
        startupKeepsEntries();
        failedRestoreKeepsEntry();
        startupObservers();
        settingsDuringStartup();
        statusUsesAgentReply();
        windowServerStartup();
        windowServerFallbacks();
        windowServerRegistrationFallbacks();
        existingFullscreenSpaces();
        unknownOwnerFullscreenExits();
        windowServerSpacePayloads();
        spaceTypeRecording();
        fullscreenSpaceExits();
        windowServerBursts();
        independentFeatureChanges();
        lateReopenFallback();
        spaceChangeQueries();
        twoAppsBothGetRead();
        quickExitThenQuit();
        differentAppImmediateOnly();
        boundedSpaceSeries();
        seriesEligibility();
        unknownWindowsKeepState();
        windowDiagnostics();
        terminationDiagnostics();
        launchAndObserverLifetime();
        permissionChangeChecks();
        terminatedRecording();
        terminatedRestoreSteps();
        ignoredSettingsCleanup();
        ignoredEventPaths();
        ignoringCancelsPendingWork();
        ignoredSpaceOwners();
        fnFTapLifecycle();
        fnFKeyFlow();
        fnFTargetCache();
        fnFDisableNotifications();
        fnFTimeoutRecovery();
        fnFReleaseOrder();
        fnFDeferredToggle();
        puts("Passed agent checks: legacy settings cleanup, immediate exits remove entries, startup keeps entries, failed restores keep entries,");
        puts("cached trust, WindowServer startup without NSApplication, event draining and release, private API fallback failures, transition registration fallbacks and Space ID decoding,");
        puts("type 4 creation saves without AX, non-full-screen types ignored, event-time frontmost apps, per-Space ownership,");
        puts("startup Space enumeration and owner lookup, unknown-owner exits check the event-time frontmost app, conservative exit rules,");
        puts("multiple full-screen Spaces, quit and Unknown reads preserve entries, Windowed exits remove entries, pending restores preserved,");
        puts("off-main Space callbacks, direct typed events, missing-type 100 ms and fallback 50 ms coalescing, permission changes, workspace wakeups,");
        puts("Space-change query filtering, different-app immediate-only reads, same-app bounded series reads, per-PID restarts, two apps both read, quick exit then quit,");
        puts("four-read timing and early stops, stale callback cancellation, window diagnostics, termination timing and observer lifetime,");
        puts("zero or no standard windows stay unknown, series eligibility, terminated recording, fallback, expiry, read-back and termination during AX calls,");
        puts("ignored apps never record or restore; ignoring removes entries and cancels pending restore work.");
        puts("Force fn-F still toggles ignored apps without recording them or logging key presses.");
        puts("Reopen defaults on; disabled startup does no Space or restore work and preserves preferences; independent runtime changes cancel stale work across all four Space paths.");
        puts("Updater command dispatch bypasses window and permission work; all three compatibility paths are saved.");
        puts("Force fn-F: permission gates, fn-only HID queues, creation failures, cached targets, deferred toggles, repeats, keyUp, release order, release timeout, tap recovery and cleanup.");
        puts("Startup settings notifications reconcile both features after initialization; repeated preference reads are idempotent; status replies report live tap state; status output uses agent permissions and features or unknown.");
    }
    return 0;
}
