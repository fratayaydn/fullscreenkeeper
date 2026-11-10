#include <assert.h>
#include <stdio.h>
#include "Policy.h"

static void settledWindowChoice(void) {
    RestoreWindow windows[] = {
        { .standard = true, .hasChildren = true },
        { .standard = true, .focused = true, .hasChildren = true },
        { .standard = true, .main = true, .hasChildren = true }
    };
    assert(restoreWindowIndex(windows, 3) == 2);
    windows[2].hasChildren = false;
    assert(restoreWindowIndex(windows, 3) == 1);
    windows[1].focused = false;
    assert(restoreWindowIndex(windows, 3) == 0);
    windows[0].minimized = true;
    assert(restoreWindowIndex(windows, 3) == 1);
    windows[1].standard = false;
    assert(restoreWindowIndex(windows, 3) == -1);
    windows[0].minimized = false;
    windows[0].hasChildren = false;
    windows[1].hasChildren = false;
    windows[1].standard = true;
    assert(restoreWindowIndex(windows, 3) == -1);
    assert(restoreWindowIndex(NULL, 0) == -1);
}

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
    RestorePolicy policy = restorePolicy(StateWindowed, true, false, 0);
    assert(!policy.pending);
    assert(restoreAttempt(&policy, 0, true, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 0);
}

static void exhaustedRestore(void) {
    WindowState saved = StateFullscreen;
    RestorePolicy policy = restorePolicy(saved, true, false, 0);
    for (unsigned i = 0; i < 5; i++) {
        double time = i * 2.25;
        assert(restoreAttempt(&policy, time, true, StateWindowed, true) == RestoreWrite);
        assert(policy.attempts == i + 1);
        assert(recordAction(saved, StateWindowed, policy.pending, false) == RecordNothing);
        for (unsigned event = 0; event < 10; event++)
            assert(restoreAttempt(&policy, time + event * 0.1, true, StateWindowed, true) == RestoreWait);
        assert(restoreAttempt(&policy, time + 1.25, true, StateWindowed, true) == RestoreWait);
        RestoreAction result = restoreReadBack(&policy, time + 1.25, StateWindowed);
        assert(result == (i == 4 ? RestoreGiveUp : RestoreSettle));
    }
    assert(!policy.pending && policy.attempts == 5);
    assert(restoreAttempt(&policy, 15, true, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 5);
    assert(recordAction(saved, StateWindowed, false, true) == RecordNothing);
    assert(saved == StateFullscreen);
}

static void alreadyFullscreen(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, false, 0);
    assert(restoreAttempt(&policy, 0, true, StateFullscreen, false) == RestoreComplete);
    assert(!policy.pending);
    assert(policy.attempts == 0);
    assert(restoreAttempt(&policy, 3, true, StateWindowed, true) == RestoreWait);
}

static void startup(void) {
    for (WindowState saved = StateUnknown; saved <= StateFullscreen; saved++) {
        RestorePolicy policy = restorePolicy(saved, false, false, 0);
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
    RestorePolicy policy = restorePolicy(StateFullscreen, true, false, 10);
    assert(restoreAttempt(&policy, 10, false, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 0);
    assert(restoreAttempt(&policy, 10.4, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 1);
    assert(restoreAttempt(&policy, 11, true, StateWindowed, true) == RestoreWait);
    assert(policy.attempts == 1);
    assert(restoreReadBack(&policy, 11, StateWindowed) == RestoreSettle);
    assert(!policy.awaitingReadBack);
    assert(policy.nextAttempt == 12);
    assert(!restoreDue(&policy, 11));
    assert(restoreReadBack(&policy, 11.7, StateUnknown) == RestoreWait);
    assert(!policy.awaitingReadBack);
    assert(policy.pending);
    assert(restoreAttempt(&policy, 12, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 2);
    assert(restoreReadBack(&policy, 13, StateFullscreen) == RestoreComplete);
    assert(!policy.pending);
    policy = restorePolicy(StateFullscreen, true, false, 0);
    assert(restoreAttempt(&policy, 15, true, StateWindowed, true) == RestoreGiveUp);
    assert(policy.attempts == 0);
    policy = restorePolicy(StateFullscreen, true, false, 0);
    assert(restoreAttempt(&policy, 14, true, StateWindowed, true) == RestoreWrite);
    assert(restoreReadBack(&policy, 15.2, StateFullscreen) == RestoreGiveUp);
    assert(!policy.pending);
}

static void earlyReadBack(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, false, 0);
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
    RestorePolicy policy = restorePolicy(StateFullscreen, true, false, 0);
    assert(restoreAttempt(&policy, 0, false, StateUnknown, false) == RestoreWait);
    assert(restoreDue(&policy, 0.01));
    assert(restoreAttempt(&policy, 0.01, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 1);
}

static void waitsPreserveAttempts(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, false, 0);
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
    RestorePolicy policy = restorePolicy(StateFullscreen, true, false, 0);
    assert(restoreAttempt(&policy, 0, true, StateWindowed, false) == RestoreGiveUp);
    assert(policy.attempts == 0);
    assert(recordAction(StateFullscreen, StateWindowed, false, true) == RecordNothing);
    assert(recordAction(StateFullscreen, StateUnknown, false, false) == RecordNothing);
    policy = restorePolicy(StateFullscreen, true, false, 0);
    for (unsigned i = 0; i < 5; i++)
        assert(restoreAttempt(&policy, i * 3, true, StateUnknown, false) == RestoreWait);
    assert(restoreAttempt(&policy, 15, true, StateUnknown, false) == RestoreGiveUp);
    assert(policy.attempts == 0 && !policy.pending);
}

static void rememberedSettling(void) {
    for (unsigned settle = 0; settle < 2; settle++) {
        RestorePolicy removed = restorePolicy(StateWindowed, true, settle, 0);
        assert(!removed.pending && !restoreDue(&removed, 0));
        assert(!restoreWindowEvent(&removed, 0, true));
        RestorePolicy added = restorePolicy(StateFullscreen, true, settle, 1);
        assert(added.pending && added.settling == settle && added.waitingForWindow == settle);
        assert(restoreDue(&added, 1) == !settle);
    }

    RestorePolicy policy = restorePolicy(StateFullscreen, true, true, 0);
    assert(policy.settling && policy.waitingForWindow);
    for (unsigned i = 0; i < 15; i++) {
        assert(!restoreStandardWindow(&policy, i, false));
        assert(restoreAttempt(&policy, i, true, StateUnknown, false) == RestoreWait);
        assert(restoreWindowEvent(&policy, i, false));
        assert(!restoreDue(&policy, i));
    }
    assert(restoreAttempt(&policy, 15, true, StateUnknown, false) == RestoreGiveUp);
    assert(policy.attempts == 0);

    policy = restorePolicy(StateFullscreen, true, true, 0);
    assert(restoreStandardWindow(&policy, 5, true));
    assert(!restoreStandardWindow(&policy, 5.5, true));
    assert(restoreAttempt(&policy, 5.999, true, StateWindowed, true) == RestoreWait);
    assert(restoreWindowEvent(&policy, 5.9, false));
    assert(restoreAttempt(&policy, 6, true, StateWindowed, true) == RestoreWait);
    assert(restoreAttempt(&policy, 6.9, false, StateWindowed, true) == RestoreWait);
    assert(restoreAttempt(&policy, 6.9, true, StateWindowed, true) == RestoreWrite);
    assert(policy.attempts == 1 && !policy.settling);
    assert(restoreReadBack(&policy, 8.1, StateWindowed) == RestoreSettle);
    assert(restoreAttempt(&policy, 9.1, true, StateWindowed, true) == RestoreWrite);
}

static void restoreSettling(void) {
    RestorePolicy policy = restorePolicy(StateFullscreen, true, false, 0);
    assert(!restoreWindowEvent(&policy, 0, true));
    assert(restoreAttempt(&policy, 0, true, StateWindowed, true) == RestoreWrite);
    assert(!restoreWindowEvent(&policy, 0.5, false));
    assert(restoreReadBack(&policy, 1.2, StateFullscreen) == RestoreComplete);
    assert(!policy.settling && policy.attempts == 1);

    policy = restorePolicy(StateFullscreen, true, false, 0);
    assert(restoreAttempt(&policy, 0, true, StateWindowed, true) == RestoreWrite);
    assert(restoreReadBack(&policy, 1.2, StateUnknown) == RestoreSettle);
    assert(policy.settling && !restoreDue(&policy, 2.199));
    assert(restoreWindowEvent(&policy, 2, false));
    assert(policy.nextAttempt == 3 && !restoreDue(&policy, 2.999));
    assert(restoreWindowEvent(&policy, 2.5, true));
    assert(policy.nextAttempt == 3.5);
    assert(restoreAttempt(&policy, 3.5, false, StateWindowed, true) == RestoreWait);
    assert(restoreAttempt(&policy, 3.5, true, StateWindowed, true) == RestoreWrite);
    assert(!policy.settling && policy.attempts == 2);

    assert(restoreWindowEvent(&policy, 14.5, true));
    assert(!policy.awaitingReadBack && policy.nextAttempt == 15.5);
    assert(restoreAttempt(&policy, 15, true, StateWindowed, true) == RestoreGiveUp);
    assert(!policy.pending && policy.attempts == 2);
}

static void fnFModifiers(void) {
    assert(fnFAction(3, FnFFunctionMask, true, false, false, false) == FnFToggle);
    uint64_t modifiers[] = { FnFShiftMask, FnFCommandMask, FnFControlMask, FnFOptionMask };
    for (unsigned i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); i++)
        assert(fnFAction(3, FnFFunctionMask | modifiers[i], true, false, false, false) == FnFPass);
    assert(fnFAction(3, 0, true, false, false, false) == FnFPass);
}

static void fnFExcludedTarget(void) {
    assert(fnFAction(3, FnFFunctionMask, true, false, true, false) == FnFPass);
    assert(fnFAction(3, FnFFunctionMask, false, false, true, false) == FnFPass);
}

static void fnFIgnoredTarget(void) {
    // Ignored Apps only applies to remembering and restoring, so this is a known target.
    assert(fnFAction(3, FnFFunctionMask, true, false, false, false) == FnFToggle);
    assert(fnFAction(3, FnFFunctionMask, true, true, false, true) == FnFSwallow);
    assert(fnFAction(3, FnFFunctionMask, false, false, false, true) == FnFSwallow);
}

static void fnFRepeats(void) {
    assert(fnFAction(3, FnFFunctionMask, true, true, false, true) == FnFSwallow);
    assert(fnFAction(3, FnFFunctionMask, true, false, false, true) == FnFSwallow);
    assert(fnFAction(3, FnFFunctionMask, true, true, false, false) == FnFPass);
    assert(fnFAction(3, FnFFunctionMask | FnFShiftMask, true, true, true, true) == FnFSwallow);
}

static void fnFKeyUp(void) {
    assert(fnFAction(3, FnFFunctionMask, false, false, false, true) == FnFSwallow);
    assert(fnFAction(3, 0, false, false, true, true) == FnFSwallow);
    assert(fnFAction(3, FnFFunctionMask, false, false, false, false) == FnFPass);
}

static void fnFOtherKeys(void) {
    for (unsigned keycode = 0; keycode < 128; keycode++) {
        if (keycode == 3) continue;
        assert(fnFAction(keycode, FnFFunctionMask, true, false, false, false) == FnFPass);
        assert(fnFAction(keycode, FnFFunctionMask, false, false, false, true) == FnFPass);
    }
}

int main(void) {
    settledWindowChoice();
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
    restoreSettling();
    rememberedSettling();
    fnFModifiers();
    fnFExcludedTarget();
    fnFIgnoredTarget();
    fnFRepeats();
    fnFKeyUp();
    fnFOtherKeys();
    puts("Passed 24 policy tests: settled window choice, full-screen app switches skip queries, same-app Space changes query,");
    puts("windowed or unknown apps query,");
    puts("multiple windows, immediate exit, windowed launch, at most five writes,");
    puts("already full screen, startup, startup preserves memory, deadlines and read back, early read back, immediate launch event,");
    puts("waits preserve attempts, unsupported windows and AX errors, restore settling, remembered settling, fn-F modifiers, unknown and self targets,");
    puts("ignored targets, repeats, keyUp and other keys.");
    return 0;
}
