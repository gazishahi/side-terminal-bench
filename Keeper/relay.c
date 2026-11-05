// keeper-relay: puts Side's session keeper between a terminal and the program it runs, for the
// "keeper in the loop" benchmarks (Side's terminal engine RFC, Phase 0).
//
//   keeper-relay <SideSessionKeeper> <run dir> -- <command> [args…]
//
// It starts a keeper for <command> (as Side does: a LaunchSpec file, a keeper in a session of
// its own), attaches to its socket, and relays: the terminal's input (this process's stdin, a
// PTY slave, put in raw mode) becomes input frames, and the keeper's snapshot and output frames
// are written to stdout. A window size change (SIGWINCH) becomes a resize frame. It exits with
// the program.
//
// Full libghostty (setup D) runs commands in a PTY of its own and can't be fed bytes from a
// socket at the pinned commit, so this is the only way to put the keeper in front of it. The
// relay's own PTY is a hop Side's real client doesn't have; the same relay can run under every
// setup, so all of them pay it alike.
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

extern char **environ;
static volatile sig_atomic_t resized = 0;
static void on_winch(int sig) { (void)sig; resized = 1; }

static void write_all(int fd, const void *p, size_t n) {
    const char *c = p;
    while (n > 0) {
        ssize_t w = write(fd, c, n);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) exit(1);
        c += w; n -= (size_t)w;
    }
}

static void send_frame(int fd, uint8_t kind, const void *payload, uint32_t len) {
    uint8_t head[5] = { kind, (uint8_t)len, (uint8_t)(len >> 8), (uint8_t)(len >> 16), (uint8_t)(len >> 24) };
    write_all(fd, head, 5);
    if (len) write_all(fd, payload, len);
}

// A JSON string, escaped.
static void json_string(FILE *f, const char *s) {
    fputc('"', f);
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
        else if (c < 0x20) fprintf(f, "\\u%04x", c);
        else fputc(c, f);
    }
    fputc('"', f);
}

static void winsize_of(int fd, int *cols, int *rows) {
    struct winsize ws = {0};
    if (ioctl(fd, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) { *cols = ws.ws_col; *rows = ws.ws_row; }
    else { *cols = 80; *rows = 24; }
}

int main(int argc, char **argv) {
    if (argc < 5 || strcmp(argv[3], "--")) { fprintf(stderr, "usage: keeper-relay <keeper> <run dir> -- <command> [args…]\n"); return 2; }
    const char *keeper = argv[1], *dir = argv[2];
    char **command = argv + 4;
    int cols, rows;
    winsize_of(STDIN_FILENO, &cols, &rows);

    char id[17];
    arc4random_buf(id, 8);
    for (int i = 7; i >= 0; i--) { static const char hex[] = "0123456789abcdef"; unsigned char b = (unsigned char)id[i]; id[2 * i] = hex[b >> 4]; id[2 * i + 1] = hex[b & 15]; }
    id[16] = 0;
    char spec_path[1024], sock_path[1024], cwd[1024];
    snprintf(spec_path, sizeof spec_path, "%s/%s.launch.json", dir, id);
    snprintf(sock_path, sizeof sock_path, "%s/%s.sock", dir, id);
    if (!getcwd(cwd, sizeof cwd)) strcpy(cwd, "/");

    FILE *spec = fopen(spec_path, "w");
    if (!spec) { perror(spec_path); return 1; }
    fprintf(spec, "{\"id\":\"%s\",\"executable\":", id); json_string(spec, command[0]);
    fprintf(spec, ",\"arguments\":[");
    for (int i = 1; command[i]; i++) { if (i > 1) fputc(',', spec); json_string(spec, command[i]); }
    fprintf(spec, "],\"environment\":[\"TERM=xterm-256color\",\"LANG=en_US.UTF-8\",\"PATH=/usr/bin:/bin\"],\"directory\":");
    json_string(spec, cwd);
    fprintf(spec, ",\"cols\":%d,\"rows\":%d,\"scrollbackLines\":10000,\"client\":{}}", cols, rows);
    fclose(spec);

    // The keeper, in a session of its own, as KeeperLauncher starts it.
    char env_dir[1100];
    snprintf(env_dir, sizeof env_dir, "SIDE_SESSIONS_DIR=%s", dir);
    char *kenv[] = { "PATH=/usr/bin:/bin", env_dir, NULL };
    char *kargv[] = { "SideSessionKeeper", "--launch", spec_path, NULL };
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0);
    posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attrs; posix_spawnattr_init(&attrs);
    posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t kpid;
    if (posix_spawn(&kpid, keeper, &actions, &attrs, kargv, kenv) != 0) { perror("spawn keeper"); return 1; }

    int sock = -1;
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, sock_path, sizeof addr.sun_path - 1);
    for (int tries = 0; tries < 600; tries++) {
        sock = socket(AF_UNIX, SOCK_STREAM, 0);
        if (connect(sock, (struct sockaddr *)&addr, sizeof addr) == 0) break;
        close(sock); sock = -1; usleep(5000);
    }
    if (sock < 0) { fprintf(stderr, "keeper-relay: no keeper socket at %s\n", sock_path); return 1; }
    int big = 1 << 20;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, &big, sizeof big);
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, &big, sizeof big);

    char json[128];
    int n = snprintf(json, sizeof json, "{\"protocolVersion\":1,\"build\":\"relay\"}");
    send_frame(sock, 1, json, (uint32_t)n);
    n = snprintf(json, sizeof json, "{\"cols\":%d,\"rows\":%d}", cols, rows);
    send_frame(sock, 2, json, (uint32_t)n);

    struct termios saved, raw;
    int is_tty = tcgetattr(STDIN_FILENO, &saved) == 0;
    if (is_tty) { raw = saved; cfmakeraw(&raw); tcsetattr(STDIN_FILENO, TCSANOW, &raw); }
    signal(SIGWINCH, on_winch);
    signal(SIGPIPE, SIG_IGN);

    size_t cap = 1 << 20, have = 0;
    uint8_t *buf = malloc(cap);
    uint8_t in[65536];
    int status = 0;
    for (;;) {
        if (resized) {
            resized = 0;
            winsize_of(STDIN_FILENO, &cols, &rows);
            n = snprintf(json, sizeof json, "{\"cols\":%d,\"rows\":%d}", cols, rows);
            send_frame(sock, 5, json, (uint32_t)n);
        }
        struct pollfd fds[2] = { { STDIN_FILENO, POLLIN, 0 }, { sock, POLLIN, 0 } };
        if (poll(fds, 2, -1) < 0) { if (errno == EINTR) continue; break; }
        if (fds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
            ssize_t r = read(STDIN_FILENO, in, sizeof in);
            if (r > 0) send_frame(sock, 4, in, (uint32_t)r);
            else if (r == 0 || errno != EINTR) {
                // The terminal went away (the benchmark ended): end the program behind the keeper.
                n = snprintf(json, sizeof json, "{\"signal\":%d,\"wholeTree\":true}", SIGKILL);
                send_frame(sock, 6, json, (uint32_t)n);
                break;
            }
        }
        if (fds[1].revents & (POLLIN | POLLHUP)) {
            if (have == cap) { cap *= 2; buf = realloc(buf, cap); }
            ssize_t r = read(sock, buf + have, cap - have);
            if (r <= 0) break;
            have += (size_t)r;
            size_t at = 0;
            while (have - at >= 5) {
                uint32_t len = buf[at + 1] | buf[at + 2] << 8 | buf[at + 3] << 16 | (uint32_t)buf[at + 4] << 24;
                if (have - at - 5 < len) {
                    if (len + 5 > cap) { cap = len + 5; buf = realloc(buf, cap); }
                    break;
                }
                uint8_t kind = buf[at];
                if (kind == 17 || kind == 18) write_all(STDOUT_FILENO, buf + at + 5, len);  // snapshot, output
                if (kind == 21) {  // exited: {"status":N} or {"signal":N}
                    const char *s = memmem(buf + at + 5, len, "\"status\":", 9);
                    status = s ? atoi(s + 9) : 1;
                    goto done;
                }
                at += 5 + len;
            }
            memmove(buf, buf + at, have - at);
            have -= at;
        }
    }
done:
    if (is_tty) tcsetattr(STDIN_FILENO, TCSANOW, &saved);
    close(sock);
    waitpid(kpid, NULL, WNOHANG);
    return status;
}
