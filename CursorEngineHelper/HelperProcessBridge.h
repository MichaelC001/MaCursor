#pragma once

#include <crt_externs.h>
#include <sys/wait.h>

static inline int MACProcessDidExit(int status) {
    return WIFEXITED(status);
}

static inline int MACProcessExitStatus(int status) {
    return WEXITSTATUS(status);
}
