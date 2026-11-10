// Exercise the bounded memory log and command reply using a private notification center.
#include <assert.h>
#include <unistd.h>
#import <Foundation/Foundation.h>

#define CFNotificationCenterGetDistributedCenter CFNotificationCenterGetLocalCenter
#import "../Sources/Agent/DiagnosticLog.h"

static void resetLog(void) {
    for (NSUInteger i = 0; i < 500; i++) gDiagnosticEntries[i] = nil;
    gDiagnosticHead = gDiagnosticCount = 0;
}

static void testRing(void) {
    resetLog();
    for (int i = 0; i < 750; i++) DIAG(@"event %d", i);
    NSArray *entries = diagnosticRead();
    assert(entries.count == 500);
    assert([entries.firstObject[@"text"] isEqual:@"event 250"]);
    assert([entries.lastObject[@"text"] isEqual:@"event 749"]);
    for (NSUInteger i = 1; i < entries.count; i++)
        assert([entries[i - 1][@"timestamp"] doubleValue] <= [entries[i][@"timestamp"] doubleValue]);
    for (NSDictionary *entry in entries)
        assert(entry.count == 2 && entry[@"timestamp"] && entry[@"text"]);

    // Expired entries are removed on read without another event.
    gDiagnosticEntries[gDiagnosticHead] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 301), @"text": @"expired"};
    assert(diagnosticRead().count == 499);
    assert(gDiagnosticEntries[(gDiagnosticHead + 499) % 500] == nil);

    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @(CFAbsoluteTimeGetCurrent() - 301), @"text": @"expired"};
    gDiagnosticCount = 1;
    DIAG(@"fresh");
    entries = diagnosticRead();
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"fresh"]);
    assert(gDiagnosticEntries[0] == nil);

    resetLog();
    gDiagnosticEntries[0] = @{@"timestamp": @700, @"text": @"boundary"};
    gDiagnosticCount = 1;
    diagnosticPrune(999.999);
    assert(gDiagnosticCount == 1);
    diagnosticPrune(1000);
    assert(gDiagnosticCount == 0 && gDiagnosticEntries[0] == nil);
}

static NSString *commandOutput(void) {
    int descriptors[2];
    assert(pipe(descriptors) == 0);
    fflush(stdout);
    int saved = dup(STDOUT_FILENO);
    assert(saved >= 0 && dup2(descriptors[1], STDOUT_FILENO) >= 0);
    close(descriptors[1]);
    int result = diagnosticPrint();
    fflush(stdout);
    assert(dup2(saved, STDOUT_FILENO) >= 0);
    close(saved);
    assert(result == 0);
    char output[4096];
    ssize_t length = read(descriptors[0], output, sizeof(output));
    close(descriptors[0]);
    assert(length > 0);
    return [[NSString alloc] initWithBytes:output length:(NSUInteger)length encoding:NSUTF8StringEncoding];
}

static void testReply(void) {
    resetLog();
    DIAG(@"agent start");
    CFNotificationCenterRef center = CFNotificationCenterGetLocalCenter();
    NSArray *entries = nil;
    CFNotificationCenterAddObserver(center, NULL, diagnosticRequested, LOG_REQUEST, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, &entries, diagnosticReceived, LOG_REPLY, CFSTR("test-token"),
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("different-token"), NULL, true);
    assert(entries == nil);
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries.count == 1 && [entries.firstObject[@"text"] isEqual:@"agent start"]);
    NSString *output = commandOutput();
    assert([output containsString:@"agent start"]);
    resetLog();
    entries = nil;
    CFNotificationCenterPostNotification(center, LOG_REQUEST, CFSTR("test-token"), NULL, true);
    assert(entries != nil && entries.count == 0);
    output = commandOutput();
    assert([output containsString:@"No entries in the last 5 minutes.\n"]);
    CFNotificationCenterRemoveEveryObserver(center, NULL);
    CFNotificationCenterRemoveEveryObserver(center, &entries);
}

int main(void) {
    @autoreleasepool {
        testRing();
        testReply();
        puts("Passed diagnostic checks: 300 second expiry, 500 entry cap, request/reply, command output and empty reply.");
    }
    return 0;
}
