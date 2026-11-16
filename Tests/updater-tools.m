// Exercise subprocesses and update decisions with private fixtures and no network or saved preferences.
#include <assert.h>
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>

static NSMutableDictionary *preferences;
static NSString *executablePath;
static NSDictionary *testRelease;
static unsigned releaseRequests, cancelledSessions;

static CFPropertyListRef testPreference(CFStringRef key, CFStringRef application) {
    (void)application;
    return CFBridgingRetain(preferences[(__bridge NSString *)key]);
}

static void testSetPreference(CFStringRef key, CFPropertyListRef value, CFStringRef application) {
    (void)application;
    preferences[(__bridge NSString *)key] = (__bridge id)value;
}

static Boolean testSynchronize(CFStringRef application) { (void)application; return true; }

static int testExecutablePath(char *buffer, uint32_t *size) {
    uint32_t needed = (uint32_t)strlen(executablePath.fileSystemRepresentation) + 1;
    if (*size < needed) { *size = needed; return -1; }
    strlcpy(buffer, executablePath.fileSystemRepresentation, *size);
    return 0;
}

@interface TestReleaseTask : NSObject
@property(copy) void (^completion)(NSData *, NSURLResponse *, NSError *);
- (void)resume;
@end

@implementation TestReleaseTask
- (void)resume {
    releaseRequests++;
    NSURL *url = [NSURL URLWithString:@"https://api.github.com/repos/fratayaydn/fullscreenkeeper/releases/latest"];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
    self.completion([NSJSONSerialization dataWithJSONObject:testRelease options:0 error:NULL], response, nil);
}
@end

@interface TestReleaseSession : NSObject
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration;
- (TestReleaseTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion;
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completion;
- (void)invalidateAndCancel;
@end

@implementation TestReleaseSession
+ (instancetype)sessionWithConfiguration:(NSURLSessionConfiguration *)configuration { (void)configuration; return [self new]; }
- (TestReleaseTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completion {
    (void)request;
    TestReleaseTask *task = [TestReleaseTask new];
    task.completion = completion;
    return task;
}
- (NSURLSessionDownloadTask *)downloadTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURL *, NSURLResponse *, NSError *))completion {
    (void)request; (void)completion;
    assert(!"Unexpected download");
    return nil;
}
- (void)invalidateAndCancel { cancelledSessions++; }
@end

#define CFPreferencesCopyAppValue testPreference
#define CFPreferencesSetAppValue testSetPreference
#define CFPreferencesAppSynchronize testSynchronize
#define _NSGetExecutablePath testExecutablePath
#define NSURLSession TestReleaseSession
#import "../Sources/Agent/Updater.m"
#undef NSURLSession
#undef _NSGetExecutablePath
#undef CFPreferencesAppSynchronize
#undef CFPreferencesSetAppValue
#undef CFPreferencesCopyAppValue

static void updateNotifications(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *bundle = [fm.currentDirectoryPath stringByAppendingPathComponent:
        [@".build/updater-" stringByAppendingString:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"app"]]];
    NSString *macOS = [bundle stringByAppendingPathComponent:@"Contents/MacOS"];
    assert([fm createDirectoryAtPath:macOS withIntermediateDirectories:YES attributes:nil error:NULL]);
    @try {
        executablePath = [macOS stringByAppendingPathComponent:@"fullscreenkeeperd"];
        assert([fm createFileAtPath:executablePath contents:NSData.data attributes:nil]);
        assert([@{@"CFBundleShortVersionString": @"1.0.0"} writeToFile:
            [bundle stringByAppendingPathComponent:@"Contents/Info.plist"] atomically:YES]);
        NSString *notifier = [macOS stringByAppendingPathComponent:@"FullscreenKeeper"];
        assert([@"#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$0.arguments\"\nexit 1\n"
            writeToFile:notifier atomically:YES encoding:NSUTF8StringEncoding error:NULL]);
        assert(chmod(notifier.fileSystemRepresentation, 0700) == 0);
        NSString *arguments = [notifier stringByAppendingString:@".arguments"];
        for (NSNumber *automatic in @[@NO, @YES]) for (NSNumber *install in @[@NO, @YES]) {
            preferences = [@{@"AutomaticallyInstallUpdates": automatic} mutableCopy];
            testRelease = @{@"tag_name": @"v1.2.3", @"draft": @NO, @"prerelease": @NO, @"assets": @[]};
            releaseRequests = cancelledSessions = 0;
            assert(updaterRun(YES, install.boolValue) == (automatic.boolValue || install.boolValue ? 1 : 0));
            assert(releaseRequests == 1 && cancelledSessions == 1);
            assert([preferences[@"LatestVersion"] isEqual:@"1.2.3"]);
            assert([[NSString stringWithContentsOfFile:arguments encoding:NSUTF8StringEncoding error:NULL]
                isEqual:@"--notify-update\n1.2.3\n--available\n"]);
            assert([fm removeItemAtPath:arguments error:NULL]);
        }
        for (NSString *version in @[@"1.0.0", @"0.9.0"]) {
            testRelease = @{@"tag_name": version, @"draft": @NO, @"prerelease": @NO};
            assert(updaterRun(YES, NO) == 0);
            assert(![fm fileExistsAtPath:arguments]);
        }
    } @finally {
        assert([fm removeItemAtPath:bundle error:NULL]);
    }
    puts("Passed updater notification checks: available updates, failed automatic and explicit installs, unchanged and older versions; no network or real install.");
}

int main(void) {
    @autoreleasepool {
        assert(runTool(@"/usr/bin/true", @[], 2));
        assert(!runTool(@"/usr/bin/false", @[], 2));
        assert(runTool(@"/bin/test", @[@"two words", @"=", @"two words"], 2));
        NSString *missing = [NSFileManager.defaultManager.currentDirectoryPath
            stringByAppendingPathComponent:[@".build/missing-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        assert(!runTool(missing, @[], 2));
        NSString *pidFile = [missing stringByAppendingString:@".pid"];
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        assert(!runTool(@"/bin/sh", @[@"-c", @"printf '%s' \"$$\" > \"$1\"; exec /bin/sleep 10",
                                     @"notification-test", pidFile], 1));
        assert(NSProcessInfo.processInfo.systemUptime - start < 5);
        pid_t pid = [[NSString stringWithContentsOfFile:pidFile encoding:NSUTF8StringEncoding error:NULL] intValue];
        assert(pid > 0);
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
        while (kill(pid, 0) == 0 && NSProcessInfo.processInfo.systemUptime < deadline) usleep(10000);
        assert(kill(pid, 0) == -1 && errno == ESRCH);
        assert([NSFileManager.defaultManager removeItemAtPath:pidFile error:NULL]);
        puts("Passed updater subprocess checks: success, failure, arguments, launch error and bounded timeout.");
        updateNotifications();
    }
    return 0;
}
