#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>

#define KEY_APPLICATIONS CFSTR("Applications")
enum { KeysPerWorker = 200 };

static int lockSettings(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    for (unsigned attempt = 0; flock(fd, LOCK_EX | LOCK_NB) != 0; attempt++) {
        if (errno != EWOULDBLOCK || attempt == 40) { close(fd); return -1; }
        usleep(5000);
    }
    return fd;
}

static CFStringRef applicationKey(unsigned worker, unsigned index) {
    return CFStringCreateWithFormat(NULL, NULL, CFSTR("worker.%u.app.%u"), worker, index);
}

static int writeApplications(const char *path, CFStringRef domain, unsigned worker, int unlocked) {
    for (unsigned i = 0; i < KeysPerWorker; i++) {
        int fd = unlocked ? -1 : lockSettings(path);
        assert(unlocked || fd >= 0);
        assert(CFPreferencesAppSynchronize(domain));
        CFDictionaryRef saved = CFPreferencesCopyAppValue(KEY_APPLICATIONS, domain);
        CFMutableDictionaryRef records = saved ? CFDictionaryCreateMutableCopy(NULL, 0, saved)
            : CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (saved) CFRelease(saved);
        // Widen the race so the unlocked run exposes stale snapshots reliably.
        usleep(1000);
        CFStringRef key = applicationKey(worker, i);
        CFDictionarySetValue(records, key, kCFBooleanTrue);
        CFRelease(key);
        CFPreferencesSetAppValue(KEY_APPLICATIONS, records, domain);
        assert(CFPreferencesAppSynchronize(domain));
        CFRelease(records);
        if (fd >= 0) close(fd);
        usleep(1000);
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 6 && !strcmp(argv[1], "--writer")) {
        CFStringRef domain = CFStringCreateWithCString(NULL, argv[3], kCFStringEncodingUTF8);
        int result = writeApplications(argv[2], domain, (unsigned)atoi(argv[4]), atoi(argv[5]));
        CFRelease(domain);
        return result;
    }
    int unlocked = argc == 2 && !strcmp(argv[1], "--unlocked");
    assert(argc == 1 || unlocked);
    char directory[] = "/tmp/fullscreenkeeper-locktest.XXXXXX";
    assert(mkdtemp(directory));
    char path[sizeof(directory) + 16];
    snprintf(path, sizeof(path), "%s/Info.plist", directory);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0);
    close(fd);
    // A normal domain goes through cfprefsd, like the app and the agent.
    char domainName[96];
    snprintf(domainName, sizeof(domainName), "io.github.fratayaydn.fullscreenkeeper.locktest");
    CFStringRef domain = CFStringCreateWithCString(NULL, domainName, kCFStringEncodingUTF8);
    CFPreferencesSetAppValue(KEY_APPLICATIONS, NULL, domain);
    assert(CFPreferencesAppSynchronize(domain));
    pid_t workers[2];
    for (unsigned worker = 0; worker < 2; worker++) {
        workers[worker] = fork();
        assert(workers[worker] >= 0);
        if (!workers[worker]) {
            // Start CFPreferences in a fresh process after fork.
            execl(argv[0], argv[0], "--writer", path, domainName, worker ? "1" : "0", unlocked ? "1" : "0", NULL);
            _exit(127);
        }
    }
    int succeeded = 1;
    for (unsigned worker = 0; worker < 2; worker++) {
        int status;
        assert(waitpid(workers[worker], &status, 0) == workers[worker]);
        if (!WIFEXITED(status) || WEXITSTATUS(status)) succeeded = 0;
    }
    assert(CFPreferencesAppSynchronize(domain));
    CFDictionaryRef records = CFPreferencesCopyAppValue(KEY_APPLICATIONS, domain);
    unsigned present = 0;
    for (unsigned worker = 0; worker < 2; worker++) {
        for (unsigned i = 0; i < KeysPerWorker; i++) {
            CFStringRef key = applicationKey(worker, i);
            if (records && CFDictionaryContainsKey(records, key)) present++;
            CFRelease(key);
        }
    }
    if (records) CFRelease(records);
    CFPreferencesSetAppValue(KEY_APPLICATIONS, NULL, domain);
    assert(CFPreferencesAppSynchronize(domain));
    CFRelease(domain);
    // cfprefsd keeps an empty file for the scratch domain.
    char preferencesPath[1024];
    snprintf(preferencesPath, sizeof(preferencesPath), "%s/Library/Preferences/%s.plist", getenv("HOME"), domainName);
    unlink(preferencesPath);
    assert(unlink(path) == 0);
    assert(rmdir(directory) == 0);
    printf("Preferences stress test (%s): %u/%u keys present (2 workers, %u keys each).\n",
           unlocked ? "unlocked" : "locked", present, 2 * KeysPerWorker, KeysPerWorker);
    fflush(stdout);
    assert(succeeded && present == 2 * KeysPerWorker);
    return 0;
}
