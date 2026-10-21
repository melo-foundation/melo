#pragma once
#include <csignal>
#include <cstdio>
#include <sys/prctl.h>
#include <unistd.h>

// When the parent is also the tracer (sharun's old-kernel layer in the anylinux
// AppImage), melo gets SIGTERM when it dies: the tracer ends on TERM without
// passing it on. Returns whether it applies.
inline bool followTracingParent() {
    FILE* f = std::fopen("/proc/self/status", "re");
    if (!f) return false;
    char line[256];
    long tracer = 0;
    while (std::fgets(line, sizeof line, f))
        if (std::sscanf(line, "TracerPid: %ld", &tracer) == 1) break;
    std::fclose(f);
    if (tracer <= 0 || tracer != long(::getppid())) return false;
    ::prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (long(::getppid()) != tracer) ::raise(SIGTERM);   // it died before the prctl
    return true;
}
