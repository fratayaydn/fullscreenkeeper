#include "Policy.h"

int restoreWindowIndex(const RestoreWindow *windows, unsigned count) {
    int first = -1, focused = -1;
    for (unsigned i = 0; i < count; i++) {
        if (!windows[i].standard || windows[i].minimized || !windows[i].hasChildren) continue;
        if (windows[i].main) return (int)i;
        if (focused < 0 && windows[i].focused) focused = (int)i;
        if (first < 0) first = (int)i;
    }
    return focused >= 0 ? focused : first;
}

FnFAction fnFAction(unsigned keycode, uint64_t flags, bool keyDown, bool autorepeat,
                    bool unknownOrSelf, bool swallowedDown) {
    if (keycode != 3) return FnFPass;  // kVK_ANSI_F
    if (swallowedDown) return FnFSwallow;
    if (!keyDown || autorepeat || unknownOrSelf || !(flags & FnFFunctionMask) ||
        (flags & (FnFShiftMask | FnFControlMask | FnFOptionMask | FnFCommandMask))) return FnFPass;
    return FnFToggle;
}

bool shouldQuerySpaceChange(int previousPID, int frontmostPID, WindowState saved) {
    return previousPID == frontmostPID || saved != StateFullscreen;
}

WindowState combineWindows(WindowState accumulated, WindowState window) {
    if (accumulated == StateFullscreen || window == StateFullscreen) return StateFullscreen;
    if (accumulated == StateUnknown || window == StateUnknown) return StateUnknown;
    return StateWindowed;
}

RecordAction recordAction(WindowState saved, WindowState observed, bool restoring, bool protected) {
    if (restoring || observed == StateUnknown || saved == observed) return RecordNothing;
    if (observed == StateFullscreen) return RecordFullscreen;
    if (protected) return RecordNothing;
    return saved == StateFullscreen ? RecordWindowed : RecordNothing;
}

RecordAction startupRecordAction(WindowState saved, WindowState observed) {
    return observed == StateFullscreen && saved != observed ? RecordFullscreen : RecordNothing;
}

RestorePolicy restorePolicy(WindowState saved, bool newlyLaunched, bool settle, double now) {
    return (RestorePolicy){ .pending = newlyLaunched && saved == StateFullscreen,
                            .settling = settle, .waitingForWindow = settle,
                            .deadline = now + 15, .nextAttempt = now };
}

bool restoreStandardWindow(RestorePolicy *policy, double now, bool standard) {
    if (!policy->pending || !policy->waitingForWindow || !standard || now >= policy->deadline) return false;
    policy->waitingForWindow = false;
    policy->nextAttempt = now + 1;
    return true;
}

bool restoreDue(const RestorePolicy *policy, double now) {
    return policy->pending && (now >= policy->deadline ||
                              (!policy->waitingForWindow && !policy->awaitingReadBack && now >= policy->nextAttempt));
}

RestoreAction restoreAttempt(RestorePolicy *policy, double now, bool frontmost, WindowState focused, bool writable) {
    if (!restoreDue(policy, now)) return RestoreWait;
    if (now >= policy->deadline || policy->attempts >= 5) {
        policy->pending = false;
        return RestoreGiveUp;
    }
    if (!frontmost || focused == StateUnknown) return RestoreWait;
    if (focused == StateFullscreen) {
        policy->pending = false;
        return RestoreComplete;
    }
    if (!writable) {
        policy->pending = false;
        return RestoreGiveUp;
    }
    policy->settling = false;
    policy->attempts++;
    policy->awaitingReadBack = true;
    policy->nextAttempt = now + 1.2;
    return RestoreWrite;
}

RestoreAction restoreReadBack(RestorePolicy *policy, double now, WindowState observed) {
    if (!policy->pending) return RestoreWait;
    if (now >= policy->deadline) {
        policy->pending = false;
        return RestoreGiveUp;
    }
    if (!policy->awaitingReadBack) return RestoreWait;
    policy->awaitingReadBack = false;
    policy->nextAttempt = now;
    if (observed == StateFullscreen) {
        policy->pending = false;
        return RestoreComplete;
    }
    if (policy->attempts >= 5) {
        policy->pending = false;
        return RestoreGiveUp;
    }
    policy->settling = true;
    policy->nextAttempt = now + 1;
    return RestoreSettle;
}

bool restoreWindowEvent(RestorePolicy *policy, double now, bool fullscreenDestroyed) {
    if (!policy->pending || (!policy->settling && !(fullscreenDestroyed && policy->attempts))) return false;
    policy->settling = true;
    policy->awaitingReadBack = false;
    policy->nextAttempt = now + 1;
    return true;
}
