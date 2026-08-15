#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t draining;
static volatile sig_atomic_t last_signal;

static void on_signal(int sig)
{
    last_signal = sig;
    draining = 1;
}

static void iso_now(char *buf, size_t n)
{
    time_t t = time(NULL);
    struct tm tm;
    gmtime_r(&t, &tm);
    strftime(buf, n, "%Y-%m-%dT%H:%M:%SZ", &tm);
}

static void job_name(char *buf, size_t n)
{
    if (gethostname(buf, n) != 0 || buf[0] == '\0')
        snprintf(buf, n, "task");
    buf[n - 1] = '\0';
}

static const char *signal_name(int sig)
{
    if (sig == SIGQUIT)
        return "QUIT";
    if (sig == SIGTERM)
        return "TERM";
    if (sig == SIGINT)
        return "INT";
    return "unknown";
}

static void emit(const char *job, const char *event, const char *extra)
{
    char now[32];
    iso_now(now, sizeof now);
    if (extra != NULL)
        printf("job=%s provider=gitlab event=%s %s at=%s\n", job, event, extra, now);
    else
        printf("job=%s provider=gitlab event=%s at=%s\n", job, event, now);
    fflush(stdout);
}

static int run_job(void)
{
    const char *raw = getenv("SIMULATED_JOB_SECONDS");
    int duration = raw ? atoi(raw) : 60;
    char job[256];
    pid_t child;
    int status;

    if (duration < 1)
        duration = 60;
    job_name(job, sizeof job);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGQUIT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT, &sa, NULL);

    emit(job, "started", NULL);
    child = fork();
    if (child < 0)
        return 1;
    if (child == 0) {
        signal(SIGQUIT, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        signal(SIGINT, SIG_IGN);
        sleep((unsigned)duration);
        _exit(0);
    }

    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        if (draining)
            break;
    }
    if (!draining)
        emit(job, "completed", NULL);

    while (!draining)
        pause();

    {
        char extra[32];
        snprintf(extra, sizeof extra, "signal=%s", signal_name(last_signal));
        emit(job, "drain-signal", extra);
    }
    if (waitpid(child, &status, WNOHANG) == 0)
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {
        }
    emit(job, "completed-after-drain", NULL);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    if (strcmp(argv[1], "register") == 0) {
        fprintf(stderr, "register\n");
        return 0;
    }
    if (strcmp(argv[1], "unregister") == 0) {
        fprintf(stderr, "cleanup\n");
        return 0;
    }
    if (strcmp(argv[1], "run") == 0)
        return run_job();
    return 2;
}
