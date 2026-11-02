// Runs one EasyTier child and stops it when this launcher exits or disappears.
// No daemon, privileged service or process-name based termination is used.
#include <sys/event.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <time.h>
static volatile sig_atomic_t stopping = 0;
static void request_stop(int sig) { (void)sig; stopping = 1; }
int main(int argc, char **argv) {
    if (argc < 2 || getppid() <= 1) return 64;
    int queue = kqueue();
    if (queue < 0) return 71;
    struct kevent watch;
    EV_SET(&watch, getppid(), EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &watch, 1, NULL, 0, NULL) < 0) { close(queue); return 71; }
    signal(SIGTERM, request_stop); signal(SIGINT, request_stop); signal(SIGHUP, request_stop);
    pid_t child = fork();
    if (child < 0) { close(queue); return 71; }
    if (child == 0) {
        close(queue);
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
        execv(argv[1], argv + 1);
        perror("EasyTier exec"); _exit(127);
    }
    int status = 0;
    struct timespec timeout = {0, 100000000};
    while (!stopping) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) { close(queue); return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status); }
        if (result < 0 && errno != EINTR) { close(queue); return 71; }
        struct kevent event;
        int count = kevent(queue, NULL, 0, &event, 1, &timeout);
        if (count > 0 && (event.fflags & NOTE_EXIT)) stopping = 1;
        else if (count < 0 && errno != EINTR) stopping = 1;
    }
    kill(child, SIGTERM);
    for (int i = 0; i < 20; i++) {
        if (waitpid(child, &status, WNOHANG) == child) { close(queue); return 0; }
        nanosleep(&timeout, NULL);
    }
    kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    close(queue); return 0;
}
