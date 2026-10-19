#include <assert.h>
#include <stdio.h>
#include "Policy.h"

static void switchingFullscreenApps(void) {
    assert(!shouldQuerySpaceChange(100, 101, StateFullscreen));
    assert(!shouldQuerySpaceChange(101, 100, StateFullscreen));
}

static void sameAppChangesSpace(void) {
    for (WindowState saved = StateUnknown; saved <= StateFullscreen; saved++)
        assert(shouldQuerySpaceChange(100, 100, saved));
}

static void switchingWindowedOrUnknown(void) {
    assert(shouldQuerySpaceChange(100, 101, StateWindowed));
    assert(shouldQuerySpaceChange(100, 101, StateUnknown));
}

static void secondWindow(void) {
    WindowState windows = combineWindows(StateWindowed, StateFullscreen);
    windows = combineWindows(windows, StateWindowed);
    assert(windows == StateFullscreen);
    assert(recordAction(StateFullscreen, windows, false, false) == RecordNothing);
    assert(combineWindows(StateWindowed, StateUnknown) == StateUnknown);
    assert(combineWindows(StateUnknown, StateFullscreen) == StateFullscreen);
    assert(combineWindows(StateFullscreen, StateUnknown) == StateFullscreen);
}

static void immediateExit(void) {
    // A successful windowed observation removes the entry before a quick quit.
    assert(recordAction(StateFullscreen, StateWindowed, false, false) == RecordWindowed);
    assert(recordAction(StateWindowed, StateWindowed, false, false) == RecordNothing);
    assert(recordAction(StateFullscreen, StateUnknown, false, false) == RecordNothing);
    assert(recordAction(StateFullscreen, StateFullscreen, false, false) == RecordNothing);
    assert(recordAction(StateFullscreen, StateWindowed, true, false) == RecordNothing);
    assert(recordAction(StateFullscreen, StateWindowed, false, true) == RecordNothing);
    assert(recordAction(StateUnknown, StateWindowed, false, false) == RecordNothing);
}

static void windowedLaunch(void) {
    RestorePolicy policy = restorePolicy(StateWindowed, true, 0);
    assert(!policy.pending);
    assert(restoreAttempt(&policy, 0, true, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 0);
}

static void exhaustedRestore(void) {
    WindowState saved = StateFullscreen;
    RestorePolicy policy = restorePolicy(saved, true, 0);
    for (unsigned i = 0; i < 5; i++) {
        double time = i * 1.25;
        assert(restoreAttempt(&policy, time, true, StateWindowed, true) == RestoreWrite);
        assert(policy.attempts == i + 1);
        assert(recordAction(saved, StateWindowed, policy.pending, false) == RecordNothing);
        for (unsigned event = 0; event < 10; event++)
            assert(restoreAttempt(&policy, time + event * 0.1, true, StateWindowed, true) == RestoreWait);
        assert(restoreAttempt(&policy, time + 1.25, true, StateWindowed, true) == RestoreWait);
        RestoreAction result = restoreReadBack(&policy, time + 1.25, StateWindowed);
        assert(result == (i == 4 ? RestoreGiveUp : RestoreWait));
    }
    assert(!policy.pending && policy.attempts == 5);
    assert(restoreAttempt(&policy, 15, true, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 5);
    assert(recordAction(saved, StateWindowed, false, true) == RecordNothing);
    assert(saved == StateFullscreen);
}

static void alreadyFullscreen(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, 0);
    assert(restoreAttempt(&policy, 0, true, StateFullscreen, false) == RestoreComplete);
    assert(!policy.pending);
    assert(policy.attempts == 0);
    assert(restoreAttempt(&policy, 3, true, StateWindowed, true) == RestoreWait);
}

static void startup(void) {
    for (WindowState saved = StateUnknown; saved <= StateFullscreen; saved++) {
        RestorePolicy policy = restorePolicy(saved, false, 0);
        assert(!policy.pending);
        assert(restoreAttempt(&policy, 0, true, StateWindowed, true) == RestoreWait);
        assert(policy.attempts == 0);
    }
    assert(recordAction(StateUnknown, StateFullscreen, false, false) == RecordFullscreen);
    assert(recordAction(StateUnknown, StateWindowed, false, false) == RecordNothing);
    assert(recordAction(StateWindowed, StateWindowed, false, false) == RecordNothing);
}

static void startupPreservesMemory(void) {
    for (WindowState saved = StateUnknown; saved <= StateFullscreen; saved++) {
        assert(startupRecordAction(saved, StateWindowed) == RecordNothing);
        assert(startupRecordAction(saved, StateUnknown) == RecordNothing);
        assert(startupRecordAction(saved, StateFullscreen) ==
               (saved == StateFullscreen ? RecordNothing : RecordFullscreen));
    }
}

static void deadlinesAndReadBack(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, 10);
    assert(restoreAttempt(&policy, 10, false, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 0);
    assert(restoreAttempt(&policy, 10.4, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 1);
    assert(restoreAttempt(&policy, 11, true, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 1);
    assert(restoreReadBack(&policy, 11, StateWindowed) == RestoreWait);
    assert(!policy.awaitingReadBack);
    assert(policy.nextAttempt == 11);
    assert(restoreDue(&policy, 11));
    assert(restoreReadBack(&policy, 11.7, StateUnknown) == RestoreWait);
    assert(!policy.awaitingReadBack);
    assert(policy.pending);
    assert(restoreAttempt(&policy, 11.7, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 2);
    assert(restoreReadBack(&policy, 13, StateFullscreen) == RestoreComplete);
    assert(!policy.pending);
    policy = restorePolicy(StateFullscreen, true, 0);
    assert(restoreAttempt(&policy, 15, true, StateWindowed, true) == RestoreGiveUp);
    assert(policy.attempts == 0);
    policy = restorePolicy(StateFullscreen, true, 0);
    assert(restoreAttempt(&policy, 14, true, StateWindowed, true) == RestoreWrite);
    assert(restoreReadBack(&policy, 15.2, StateFullscreen) == RestoreGiveUp);
    assert(!policy.pending);
}

static void earlyReadBack(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, 0);
    assert(restoreAttempt(&policy, 0, true, StateWindowed, true) == RestoreWrite);
    double now = policy.nextAttempt - 0.001;
    assert(policy.awaitingReadBack);
    assert(restoreReadBack(&policy, now, StateFullscreen) == RestoreComplete);
    assert(!policy.awaitingReadBack);
    assert(policy.nextAttempt == now);
    assert(!policy.pending);
    assert(policy.attempts == 1);
}

static void eventAfterLaunch(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, 0);
    assert(restoreAttempt(&policy, 0, false, StateUnknown, false) == RestoreWait);
    assert(restoreDue(&policy, 0.01));
    assert(restoreAttempt(&policy, 0.01, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 1);
}

static void waitsPreserveAttempts(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, 0);
    for (unsigned event = 0; event < 1400; event++) {
        double time = event * 0.01;
        assert(restoreAttempt(&policy, time, false, StateWindowed, true) == RestoreWait);
        assert(restoreAttempt(&policy, time, true, StateUnknown, false) == RestoreWait);
        assert(policy.attempts == 0 && policy.nextAttempt == 0 && policy.pending);
    }
    assert(restoreAttempt(&policy, 14, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 1);
}

static void unsupportedAndUnknown(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, 0);
    assert(restoreAttempt(&policy, 0, true, StateWindowed, false) == RestoreGiveUp);
    assert(policy.attempts == 0);
    assert(recordAction(StateFullscreen, StateWindowed, false, true) == RecordNothing);
    assert(recordAction(StateFullscreen, StateUnknown, false, false) == RecordNothing);
    policy = restorePolicy(StateFullscreen, true, 0);
    for (unsigned i = 0; i < 5; i++)
        assert(restoreAttempt(&policy, i * 3, true, StateUnknown, false) == RestoreWait);
    assert(restoreAttempt(&policy, 15, true, StateUnknown, false) == RestoreGiveUp);
    assert(policy.attempts == 0 && !policy.pending);
}

int main(void) {
    switchingFullscreenApps();
    sameAppChangesSpace();
    switchingWindowedOrUnknown();
    secondWindow();
    immediateExit();
    windowedLaunch();
    exhaustedRestore();
    alreadyFullscreen();
    startup();
    startupPreservesMemory();
    deadlinesAndReadBack();
    earlyReadBack();
    eventAfterLaunch();
    waitsPreserveAttempts();
    unsupportedAndUnknown();
    puts("Passed 15 policy tests: full-screen app switches skip queries, same-app Space changes query, windowed or unknown apps query,");
    puts("multiple windows, immediate exit, windowed launch, at most five writes,");
    puts("already full screen, startup, startup preserves memory, deadlines and read back, early read back, immediate launch event,");
    puts("waits preserve attempts, unsupported windows and AX errors.");
    return 0;
}
