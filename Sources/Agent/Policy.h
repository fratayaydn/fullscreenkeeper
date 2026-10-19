#ifndef FULLSCREENKEEPER_POLICY_H
#define FULLSCREENKEEPER_POLICY_H

#include <stdbool.h>

typedef enum { StateUnknown = -1, StateWindowed, StateFullscreen } WindowState;
typedef enum { RecordNothing, RecordFullscreen, RecordWindowed } RecordAction;
typedef enum { RestoreWait, RestoreWrite, RestoreComplete, RestoreGiveUp } RestoreAction;

typedef struct {
    bool pending;
    bool awaitingReadBack;
    unsigned attempts;  // AXFullScreen writes, including calls that return an error
    double deadline;
    double nextAttempt;
} RestorePolicy;

WindowState combineWindows(WindowState accumulated, WindowState window);
bool shouldQuerySpaceChange(int previousPID, int frontmostPID, WindowState saved);
RecordAction recordAction(WindowState saved, WindowState observed, bool restoring, bool protected);
RecordAction startupRecordAction(WindowState saved, WindowState observed);
RestorePolicy restorePolicy(WindowState saved, bool newlyLaunched, double now);
bool restoreDue(const RestorePolicy *policy, double now);
RestoreAction restoreAttempt(RestorePolicy *policy, double now, bool frontmost, WindowState focused, bool writable);
RestoreAction restoreReadBack(RestorePolicy *policy, double now, WindowState observed);

#endif
