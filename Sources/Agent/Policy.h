#ifndef FULLSCREENKEEPER_POLICY_H
#define FULLSCREENKEEPER_POLICY_H

#include <stdbool.h>
#include <stdint.h>

typedef enum { StateUnknown = -1, StateWindowed, StateFullscreen } WindowState;
typedef enum { RecordNothing, RecordFullscreen, RecordWindowed } RecordAction;
typedef enum { RestoreWait, RestoreWrite, RestoreComplete, RestoreGiveUp } RestoreAction;
typedef enum { FnFPass, FnFSwallow, FnFToggle } FnFAction;
enum {
    FnFShiftMask = 1 << 17, FnFControlMask = 1 << 18, FnFOptionMask = 1 << 19,
    FnFCommandMask = 1 << 20, FnFFunctionMask = 1 << 23
};

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
FnFAction fnFAction(unsigned keycode, uint64_t flags, bool keyDown, bool autorepeat,
                    bool unknownOrSelf, bool swallowedDown);

#endif
