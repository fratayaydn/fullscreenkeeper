#include "Policy.h"

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

RestorePolicy restorePolicy(WindowState saved, bool newlyLaunched, double now) {
    return (RestorePolicy){ .pending = newlyLaunched && saved == StateFullscreen,
                            .deadline = now + 15, .nextAttempt = now };
}

bool restoreDue(const RestorePolicy *policy, double now) {
    return policy->pending && (now >= policy->deadline ||
                              (!policy->awaitingReadBack && now >= policy->nextAttempt));
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
    return RestoreWait;
}
