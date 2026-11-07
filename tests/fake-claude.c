/* fake claude for the tests: registers like the CLI (~/.claude/sessions/<pid>.json, with a messaging socket), shows a ❯
 * prompt, leaves on /exit (clearing the screen, as the CLI does) and comes back under `--resume <uuid>` on that uuid.
 * Knobs (env, set on the tmux session): FAKE_SESSION_ID FAKE_NAME · FAKE_IGNORE_EXIT=1 (a /exit that never lands) ·
 * FAKE_STARTED_AT=<epoch s> (the registry row's startedAt; default now) · FAKE_RESUME_FAIL=1 (a --resume that dies at once) · FAKE_RESUME_DELAY=<ms> (a --resume runs that long before it refuses or
 * registers: a CLI's start-up) · FAKE_LOG=<file> (one "start|exit <uuid> <epoch.micros>" line per event) ·
 * FAKE_ENV_LOG=<file> (one "<uuid> <CLAUDE_CODE_PLUGIN_DIRS, or -> " line per start: the mod's folder on the launch line) ·
 * FAKE_SOCK_LOG=<file> (one "<uuid> <what arrived>" line per message pushed to its messaging socket, read by a thread of its
 * own, so no child process appears under it: what sala's session_push delivered, or that nothing was) ·
 * FAKE_TYPED_LOG=<file> (one "<uuid> <line>" line per line that reached its composer: what tui_send typed, marker and all,
 * Mon Oct 12th) · FAKE_LANE_LOG=<file> (one "<uuid> key=y|n hdr=y|n cfg=<CLAUDE_CONFIG_DIR or ->" line per start: the lane's
 * env on the launch line — the key's presence, never its value) · FAKE_CACHE_LOG=<file> (one "<uuid> cache1h=<value of ENABLE_PROMPT_CACHING_1H or -> cache1h_bedrock=<value of ENABLE_PROMPT_CACHING_1H_BEDROCK or ->" line per start) · FAKE_BEDROCK_LOG=<file> (one "<uuid> profile=… use=… region=… prefix=… opus=… sonnet=… haiku=… awskey=y|n" line per start — the bedrock lane's env on the launch line, "-" for a variable not set) · FAKE_AWSP_LOG=<file> (one "<uuid> profile=… use=… ws=… region=… opus=… sonnet=… haiku=… bedrock=… foundry=… apikey=y|n awskey=y|n" line per start — the aws-platform lane's env on the launch line, "-" for a variable not set; bedrock/foundry/apikey are the variables the line must have unset) · FAKE_EXIT_DIALOG="<row>;<row>…" (a
 * /exit opens the CLI's "Background work is running" dialog with those rows, as 2.1.299 draws it — the title, "The following
 * will stop when you exit:", one row per task, "❯ 1. Exit and stop tasks" selected, "2. Stay", "Esc to cancel" — and reads one
 * key: Enter exits, Esc dismisses it and the ❯ prompt is back) · FAKE_CHILD=1 (Linux: a child process named fakechild under
 * the fake for its life — work in flight to work_children; dies with the fake) · FAKE_PROMPT_FILE=<file> (whenever
 * the fake is about to show its ❯ prompt and that file exists and is not empty, it shows the file's text instead — a
 * permission dialog, a menu, as the test wrote it — and waits for ONE key, as the CLI's dialogs hold the pane; any key clears
 * the screen and the loop looks at the file again: rewritten, the new dialog shows; removed, the ❯ prompt is back) ·
 * FAKE_IDLE_AGE=<secs> (the registry row's statusUpdatedAt is that old at start; default 60) · FAKE_TURN_MS=<ms> (a typed
 * message that is not a slash command is a turn: the row says busy for that long, then idle with a fresh stamp; unset, a message changes
 * nothing, as before) · FAKE_NO_CLEAR=1 (a /clear is typed and logged and nothing changes) · `/clear` (probed on 2.1.312: the SAME registry row, same pid, name and nameSource kept, gets a NEW
 * sessionId and a fresh idle stamp; the screen is cleared; one "clear <new uuid> <epoch.micros>" line in FAKE_LOG). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <signal.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <pthread.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif
static pid_t child = 0;
static void child_start(void) {   /* FAKE_CHILD: a live child process under the fake (Linux: named, and gone with its parent) */
#ifdef __linux__
    if (!getenv("FAKE_CHILD")) return;
    child = fork();
    if (child == 0) { prctl(PR_SET_NAME, "fakechild", 0, 0, 0); prctl(PR_SET_PDEATHSIG, SIGTERM); for (;;) pause(); }
#endif
}
static void child_stop(void) { if (child > 0) { kill(child, SIGTERM); waitpid(child, NULL, 0); child = 0; } }
static int exit_dialog(void) {   /* FAKE_EXIT_DIALOG: the dialog, then one key; 1 = exit (Enter on the selected choice), 0 = stay (Esc) */
    const char *rows = getenv("FAKE_EXIT_DIALOG"); if (!rows || !*rows) return 1;
    struct termios old, raw; int have = tcgetattr(0, &old) == 0;
    printf("\n Background work is running\n The following will stop when you exit:\n");
    char buf[2048]; snprintf(buf, sizeof buf, "%s", rows);
    for (char *p = strtok(buf, ";"); p; p = strtok(NULL, ";")) printf("   %s\n", p);
    printf(" \xe2\x9d\xaf 1. Exit and stop tasks\n   2. Stay\n Enter to select \xc2\xb7 Esc to cancel\n"); fflush(stdout);
    if (have) { raw = old; raw.c_lflag &= ~(ICANON | ECHO); raw.c_cc[VMIN] = 1; raw.c_cc[VTIME] = 0; tcsetattr(0, TCSANOW, &raw); }
    int r = 0; unsigned char c;
    for (;;) { if (read(0, &c, 1) != 1) break; if (c == '\r' || c == '\n') { r = 1; break; } if (c == 0x1b) break; }
    if (have) tcsetattr(0, TCSANOW, &old);
    if (!r) { fputs("\033[2J\033[H", stdout); fflush(stdout); }
    return r;
}
static int prompt_file(void) {   /* FAKE_PROMPT_FILE: the file's text as a dialog holding the pane until one key; 1 = shown (and dismissed), 0 = no file */
    const char *pf = getenv("FAKE_PROMPT_FILE"); if (!pf || !*pf) return 0;
    FILE *f = fopen(pf, "r"); if (!f) return 0;
    char buf[8192]; size_t n = fread(buf, 1, sizeof buf - 1, f); fclose(f); buf[n] = 0;
    if (!n) return 0;
    struct termios old, raw; int have = tcgetattr(0, &old) == 0;
    struct winsize ws; int rows = ioctl(0, TIOCGWINSZ, &ws) == 0 ? ws.ws_row : 24, nl = 0;   /* the dialog at the BOTTOM of the screen, as the CLI draws it */
    for (size_t i = 0; i < n; i++) if (buf[i] == '\n') nl++;
    fputs("\033[2J\033[H", stdout); for (int i = nl + 1; i < rows; i++) fputc('\n', stdout);
    fputs(buf, stdout); fflush(stdout);
    if (have) { raw = old; raw.c_lflag &= ~(ICANON | ECHO); raw.c_cc[VMIN] = 1; raw.c_cc[VTIME] = 0; tcsetattr(0, TCSANOW, &raw); }
    unsigned char c; if (read(0, &c, 1) != 1) { for (;;) pause(); }
    if (have) tcsetattr(0, TCSANOW, &old);
    fputs("\033[2J\033[H", stdout); fflush(stdout);
    return 1;
}
/* FAKE_MODEL_MODE (tests/modelinplace.sh): the pane answers `/model <value>` and `/effort <level>` typed into its composer as
 * Claude Code 2.1.310 does, probed: ok (a "Switch model?" dialog when the value differs from the current model: text typed into it is
 * swallowed, Enter confirms, Esc keeps the model; then a "Set model to <value>" line, and the value saved as the lane's default in
 * settings.json: the top-level `model`), nodialog (no dialog), silent (the line is taken and nothing happens), writeonly (the default
 * is saved, no "Set …" line), weird (an unexpected dialog, "Do you want to apply this change?", which Esc dismisses and Enter would
 * apply), effortfail (/model as ok; /effort prints a refusal and no "Set effort level to" line). `/effort <level>` prints "Set effort
 * level to <level>" and saves modelSettings.<current model>.effortLevel. FAKE_MODEL_START: the model it starts on (opus).
 * FAKE_SETTINGS_PY names the script that edits settings.json (CLAUDE_CONFIG_DIR, else $HOME/.claude). FAKE_KEY_LOG=<file>: one
 * "<uuid> <dialog> enter|esc|other" line per key a dialog received. Unset: a typed /model is just a line, as before. */
static char cur_model[128] = "opus";
/* stdin_gone: the fake's input ended or failed and it will idle for good ("no tty: idle forever"). It says why on stderr, which is the pane's
 * screen when it runs in tmux, so a failed check that captures the pane shows it (on a CI runner the fake had its row and never
 * read a line; typed_diag in tests/lib.sh also prints /proc/<pid>/fdinfo/0's flags — O_NONBLOCK makes fgets fail at once with EAGAIN). */
static void stdin_gone(const char *where) {
    int e = feof(stdin) ? 0 : errno, fl = fcntl(0, F_GETFL);   /* errno means something only when the stream failed, not at its end */
    fprintf(stderr, "\nfake claude: stdin ended in %s: errno=%d (%s) feof=%d isatty=%d flags=%o\n", where, e, e ? strerror(e) : "none", feof(stdin), isatty(0), fl);
}
/* composer_line: with FAKE_MODEL_MODE set the fake edits its line itself, as the CLI's composer does (the kernel's line discipline
 * would take an Escape into the text and echo "^["): Esc is ignored, Ctrl-U clears the line, Backspace erases one character, Enter
 * ends it. 1 = a line in buf (with its newline), 0 = the input is gone. */
static int composer_line(char *buf, size_t sz) {
    struct termios old, raw; int have = tcgetattr(0, &old) == 0; size_t n = 0; unsigned char c;
    if (have) { raw = old; raw.c_lflag &= ~(ICANON | ECHO); raw.c_cc[VMIN] = 1; raw.c_cc[VTIME] = 0; tcsetattr(0, TCSANOW, &raw); }
    for (;;) {
        if (read(0, &c, 1) != 1) { stdin_gone("the composer"); if (have) tcsetattr(0, TCSANOW, &old); return 0; }
        if (c == '\r' || c == '\n') { fputs("\n", stdout); fflush(stdout); buf[n++] = '\n'; buf[n] = 0; break; }
        if (c == 0x1b) continue;
        if (c == 0x15) { n = 0; fputs("\r\033[K\xe2\x9d\xaf ", stdout); fflush(stdout); continue; }
        if ((c == 0x7f || c == 8) && n) { n--; fputs("\b \b", stdout); fflush(stdout); continue; }
        if (c >= 0x20 && n + 2 < sz) { buf[n++] = (char)c; fputc(c, stdout); fflush(stdout); }
    }
    if (have) tcsetattr(0, TCSANOW, &old);
    return 1;
}
static int safe_word(const char *w) { if (!w || !*w) return 0; for (; *w; w++) if (!(isalnum((unsigned char)*w) || *w == '.' || *w == '-' || *w == '_')) return 0; return 1; }
static void fake_setting(const char *what, const char *a, const char *b) {
    const char *py = getenv("FAKE_SETTINGS_PY"), *cd = getenv("CLAUDE_CONFIG_DIR"), *home = getenv("HOME");
    char dir[1024], cmd[4096]; if (!py || !safe_word(a) || (b && !safe_word(b))) return;
    if (cd && *cd) snprintf(dir, sizeof dir, "%s", cd); else snprintf(dir, sizeof dir, "%s/.claude", home ? home : ".");
    snprintf(cmd, sizeof cmd, "python3 -I '%s' '%s' %s '%s' %s%s%s", py, dir, what, a, b ? "'" : "", b ? b : "", b ? "'" : "");
    if (system(cmd) != 0) { /* the test sees the missing key */ }
}
static int model_dialog(const char *sid, const char *name, const char *l1, const char *l2, const char *l3) {   /* 1 = Enter, 0 = Esc; any other key is swallowed */
    struct termios old, raw; int have = tcgetattr(0, &old) == 0, r = 0; unsigned char c; const char *kl = getenv("FAKE_KEY_LOG");
    printf("\n%s\n%s\n \xe2\x9d\xaf 1. %s\n   2. %s\n Enter to confirm \xc2\xb7 Esc to cancel\n", name, l1, l2, l3); fflush(stdout);
    if (have) { raw = old; raw.c_lflag &= ~(ICANON | ECHO); raw.c_cc[VMIN] = 1; raw.c_cc[VTIME] = 0; tcsetattr(0, TCSANOW, &raw); }
    for (;;) {
        if (read(0, &c, 1) != 1) { for (;;) pause(); }
        const char *k = (c == '\r' || c == '\n') ? "enter" : c == 0x1b ? "esc" : "other";
        { FILE *f = kl ? fopen(kl, "a") : NULL; if (f) { fprintf(f, "%s %s %s\n", sid, name, k); fclose(f); } }
        if (c == '\r' || c == '\n') { r = 1; break; }
        if (c == 0x1b) break;
    }
    if (have) tcsetattr(0, TCSANOW, &old);
    fputs("\033[6A\r\033[J", stdout); fflush(stdout);    /* the dialog's six lines (a blank one first) erased, as the CLI repaints */
    return r;
}
static void slash(const char *sid, const char *mode, char *line) {   /* "/model x\n" or "/effort x\n" */
    int isModel = !strncmp(line, "/model ", 7); char *arg = line + (isModel ? 7 : 8); size_t n = strlen(arg);
    while (n && (arg[n - 1] == '\n' || arg[n - 1] == ' ')) arg[--n] = 0;
    if (!strcmp(mode, "silent") || !safe_word(arg)) return;
    if (isModel) {
        if (!strcmp(mode, "weird")) { model_dialog(sid, "Do you want to apply this change?", "This is not the model dialog.", "Yes", "No"); return; }
        if (!strcmp(mode, "ok") || !strcmp(mode, "effortfail")) {
            if (strcmp(arg, cur_model) && !model_dialog(sid, "Switch model?", "Switching mid-conversation re-reads the context without the prompt cache.", "Yes, switch", "No, keep the current model")) { printf("  \xe2\x8e\xbf  Kept model as %s\n", cur_model); return; }
        }
        snprintf(cur_model, sizeof cur_model, "%s", arg); fake_setting("model", arg, NULL);
        if (strcmp(mode, "writeonly")) printf("  \xe2\x8e\xbf  Set model to %s\n", arg);
    } else {
        if (!strcmp(mode, "effortfail")) { printf("  \xe2\x8e\xbf  %s is not an effort level this model takes\n", arg); return; }
        fake_setting("effort", cur_model, arg);
        if (strcmp(mode, "writeonly")) printf("  \xe2\x8e\xbf  Set effort level to %s\n", arg);
    }
}
static void note(const char *ev, const char *sid) {
    const char *l = getenv("FAKE_LOG"); if (!l) return;
    struct timeval tv; gettimeofday(&tv, NULL);
    FILE *f = fopen(l, "a"); if (!f) return;
    fprintf(f, "%s %s %ld.%06ld\n", ev, sid, (long)tv.tv_sec, (long)tv.tv_usec); fclose(f);
}
static int sock_fd = -1; static const char *sock_sid = "";
static void *sock_logger(void *unused) {   /* FAKE_SOCK_LOG: every connection's bytes, newlines folded, one line per message */
    (void)unused; const char *l = getenv("FAKE_SOCK_LOG");
    for (;;) {
        int c = accept(sock_fd, NULL, NULL); if (c < 0) continue;
        char buf[65536]; size_t n = 0; ssize_t r;
        while (n < sizeof buf - 1 && (r = read(c, buf + n, sizeof buf - 1 - n)) > 0) n += (size_t)r;
        close(c); buf[n] = 0; while (n > 0 && buf[n - 1] == '\n') buf[--n] = 0;
        for (size_t i = 0; i < n; i++) if (buf[i] == '\n') buf[i] = ' ';
        FILE *f = fopen(l, "a"); if (f) { fprintf(f, "%s %s\n", sock_sid, buf); fclose(f); }
    }
    return NULL;
}
static char g_path[1024], g_sock[1024], g_sess[256], g_cwd[1024], g_sidbuf[64]; static const char *g_name, *g_tmux; static long g_started_s;
static void write_row(const char *sid, const char *status, long stamp_s) {   /* the registry row again (a /clear, a turn): temp file and rename, so a reader never sees half a row */
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.tmp", g_path);
    FILE *f = fopen(tmp, "w"); if (!f) return;
    fprintf(f, "{\"pid\":%d,\"sessionId\":\"%s\",\"name\":\"%s\",\"status\":\"%s\",\"startedAt\":%ld000,\"statusUpdatedAt\":%ld000,\"tmux\":\"%s:@%s.%s\",\"cwd\":\"%s\",\"bridgeSessionId\":\"session_01FAKE\",\"messagingSocketPath\":\"%s\",\"version\":\"9.9.9\"}\n",
        (int)getpid(), sid, g_name ? g_name : "fake", status, g_started_s, stamp_s, g_sess, g_tmux ? g_tmux + 1 : "0", g_tmux ? g_tmux : "%0", g_cwd, g_sock);
    fclose(f); rename(tmp, g_path);
}
int main(int argc, char **argv) {
    const char *sid = getenv("FAKE_SESSION_ID"); int resume = 0;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--version")) { puts("9.9.9 (Claude Code)"); return 0; }
        if (!strcmp(argv[i], "--resume") && i + 1 < argc) { sid = argv[++i]; resume = 1; }
    }
    if (!sid) sid = "00000000-0000-4000-8000-000000000001";
    /* FAKE_RESUME_DELAY=<ms>: a --resume runs that long before it refuses or registers, as the CLI starts up for seconds
     * (the pane's foreground command reads `claude` the whole time, its registry row not yet written) */
    const char *dl = getenv("FAKE_RESUME_DELAY");
    if (resume && dl && atol(dl) > 0) { struct timespec ts = { atol(dl) / 1000, (atol(dl) % 1000) * 1000000L }; nanosleep(&ts, NULL); }
    if (resume && getenv("FAKE_RESUME_FAIL")) { fprintf(stderr, "fake claude: resume refused (FAKE_RESUME_FAIL)\n"); return 1; }
    const char *home = getenv("HOME"), *tmux = getenv("TMUX_PANE"), *name = getenv("FAKE_NAME");
    char *path = g_path, *sock = g_sock, *sess = g_sess; g_name = name; g_tmux = tmux; sock[0] = 0; sess[0] = 0;
    snprintf(g_path, sizeof g_path, "%s/.claude/sessions/%d.json", home, (int)getpid());
    if (tmux) { FILE *p = popen("tmux display -p '#{session_name}:@#{window_id}' 2>/dev/null | tr -d '@\\n'", "r"); if (p) { if (fgets(sess, sizeof g_sess, p)) {} pclose(p); } }
    /* a messaging socket, as the CLI owns one: revive's inbox release waits for the resumed process to have it */
    int s = socket(AF_UNIX, SOCK_STREAM, 0);
    if (s >= 0) {
        struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
        snprintf(a.sun_path, sizeof a.sun_path, "%s/.claude/fake-%d.sock", home, (int)getpid()); unlink(a.sun_path);
        if (bind(s, (struct sockaddr *)&a, sizeof a) == 0 && listen(s, 1) == 0) snprintf(sock, sizeof g_sock, "%s", a.sun_path);
        if (sock[0] && getenv("FAKE_SOCK_LOG")) { pthread_t t; sock_fd = s; sock_sid = sid; pthread_create(&t, NULL, sock_logger, NULL); }
    }
    char *cwd = g_cwd; if (!getcwd(cwd, sizeof g_cwd)) cwd[0] = 0;        /* the real registry row carries cwd (2026-10-06: the pane map's 4th column) */
    FILE *f = fopen(path, "w"); if (!f) return 1;
    /* startedAt, as the CLI's row carries it (the process's start, epoch ms); FAKE_STARTED_AT=<epoch s> places it elsewhere (the flag rule's suites) */
    long started_s = (long)time(NULL); { const char *fs = getenv("FAKE_STARTED_AT"); if (fs && *fs) started_s = atol(fs); }
    g_started_s = started_s; long idle_age = 60; { const char *ia = getenv("FAKE_IDLE_AGE"); if (ia && *ia) idle_age = atol(ia); }
    fprintf(f, "{\"pid\":%d,\"sessionId\":\"%s\",\"name\":\"%s\",\"status\":\"idle\",\"startedAt\":%ld000,\"statusUpdatedAt\":%ld000,\"tmux\":\"%s:@%s.%s\",\"cwd\":\"%s\",\"bridgeSessionId\":\"session_01FAKE\",\"messagingSocketPath\":\"%s\",\"version\":\"9.9.9\"}\n",
        (int)getpid(), sid, name ? name : "fake", started_s, (long)time(NULL) - idle_age, sess, tmux ? tmux + 1 : "0", tmux ? tmux : "%0", cwd, sock);
    fclose(f);
    note("start", sid); child_start();
    { const char *el = getenv("FAKE_ENV_LOG"), *pd = getenv("CLAUDE_CODE_PLUGIN_DIRS");
      FILE *e = el ? fopen(el, "a") : NULL; if (e) { fprintf(e, "%s %s\n", sid, pd && *pd ? pd : "-"); fclose(e); } }
    { const char *ll = getenv("FAKE_LANE_LOG"), *k = getenv("ANTHROPIC_API_KEY"), *h = getenv("ANTHROPIC_CUSTOM_HEADERS"), *cd = getenv("CLAUDE_CONFIG_DIR");
      FILE *e = ll ? fopen(ll, "a") : NULL;   /* the lane's env: the key's presence only, never its value */
      if (e) { fprintf(e, "%s key=%s hdr=%s cfg=%s\n", sid, k && *k ? "y" : "n", h && *h ? "y" : "n", cd && *cd ? cd : "-"); fclose(e); } }
    { const char *bl = getenv("FAKE_BEDROCK_LOG"); FILE *e = bl ? fopen(bl, "a") : NULL;   /* the bedrock lane's env: the values of the names, none a secret; the AWS key's presence only */
#define BV(n) (getenv(n) && *getenv(n) ? getenv(n) : "-")
      if (e) { fprintf(e, "%s profile=%s use=%s region=%s prefix=%s opus=%s sonnet=%s haiku=%s awskey=%s\n", sid, BV("AWS_PROFILE"), BV("CLAUDE_CODE_USE_BEDROCK"), BV("AWS_REGION"),
          BV("ANTHROPIC_BEDROCK_REGION_PREFIX"), BV("ANTHROPIC_DEFAULT_OPUS_MODEL"), BV("ANTHROPIC_DEFAULT_SONNET_MODEL"), BV("ANTHROPIC_DEFAULT_HAIKU_MODEL"), getenv("AWS_ACCESS_KEY_ID") ? "y" : "n"); fclose(e); } }
    { const char *cl = getenv("FAKE_CACHE_LOG"); FILE *e = cl ? fopen(cl, "a") : NULL;   /* the 1-hour prompt cache switches on the launch line: their values or "-" (a bedrock pane has the _BEDROCK one, an api or aws-platform pane the plain one; a job and a max or team pane neither) */
      if (e) { fprintf(e, "%s cache1h=%s cache1h_bedrock=%s\n", sid, BV("ENABLE_PROMPT_CACHING_1H"), BV("ENABLE_PROMPT_CACHING_1H_BEDROCK")); fclose(e); } }
    { const char *al = getenv("FAKE_AWSP_LOG"); FILE *e = al ? fopen(al, "a") : NULL;   /* the aws-platform lane's env: the values of the names, none a secret; the keys' presence only */
      if (e) { fprintf(e, "%s profile=%s use=%s ws=%s region=%s opus=%s sonnet=%s haiku=%s bedrock=%s foundry=%s apikey=%s awskey=%s\n", sid, BV("AWS_PROFILE"), BV("CLAUDE_CODE_USE_ANTHROPIC_AWS"),
          BV("ANTHROPIC_AWS_WORKSPACE_ID"), BV("AWS_REGION"), BV("ANTHROPIC_DEFAULT_OPUS_MODEL"), BV("ANTHROPIC_DEFAULT_SONNET_MODEL"), BV("ANTHROPIC_DEFAULT_HAIKU_MODEL"),
          BV("CLAUDE_CODE_USE_BEDROCK"), BV("CLAUDE_CODE_USE_FOUNDRY"), getenv("ANTHROPIC_AWS_API_KEY") ? "y" : "n", getenv("AWS_ACCESS_KEY_ID") ? "y" : "n"); fclose(e); } }
    char line[4096];   /* longer than any line sala types: spawn's brief line runs past 256 */
    { const char *ms = getenv("FAKE_MODEL_START"); if (ms && safe_word(ms)) snprintf(cur_model, sizeof cur_model, "%s", ms); }
    for (;;) {
        if (prompt_file()) continue;                                          /* FAKE_PROMPT_FILE: a dialog held the pane; look again */
        /* the composer's ❯, on a row of its own: the row is erased from the cursor on first. A launch line typed into a shell that was not
         * ready yet is echoed twice, and when the shell's second echo ends so that its cursor is back at the row's first column (the
         * line's length and the prompt's together a whole number of 80-column rows: the CI box's runners 2 and 4) the ❯ lands
         * on the echo's last row, "❯ /salamander/salamander/mod" /tmp/…/claude", which tui_send reads as someone's unsent draft and
         * refuses to type onto. The real CLI draws its own box; it never shares a row with what the shell left. */
        fputs("\r\033[K\xe2\x9d\xaf ", stdout); fflush(stdout);
        if (getenv("FAKE_MODEL_MODE")) { if (!composer_line(line, sizeof line)) { for (;;) pause(); } }   /* a composer of its own (above) */
        else if (!fgets(line, sizeof line, stdin)) { stdin_gone("fgets"); for (;;) pause(); }   /* no tty: idle forever, as before (saying why on stderr) */
        { const char *tl = getenv("FAKE_TYPED_LOG"); FILE *t = tl ? fopen(tl, "a") : NULL;   /* FAKE_TYPED_LOG: the line as typed */
          if (t) { size_t n = strlen(line); if (n && line[n - 1] == '\n') n--; fprintf(t, "%s %.*s\n", sid, (int)n, line); fclose(t); } }
        { const char *mm = getenv("FAKE_MODEL_MODE");                          /* FAKE_MODEL_MODE: /model and /effort answered (above) */
          if (mm && *mm && (!strncmp(line, "/model ", 7) || !strncmp(line, "/effort ", 8))) { slash(sid, mm, line); continue; } }
        if (!strcmp(line, "/clear\n") && getenv("FAKE_NO_CLEAR")) continue;    /* FAKE_NO_CLEAR: a CLI that does not take /clear (typed and logged above, nothing else changes) */
        if (!strcmp(line, "/clear\n")) {                                       /* /clear: same row and pid, a new sessionId, a fresh idle stamp, a cleared screen */
            static int seeded = 0; if (!seeded) { srand((unsigned)getpid() ^ (unsigned)time(NULL)); seeded = 1; }
            snprintf(g_sidbuf, sizeof g_sidbuf, "c1ea%04x-%04x-4000-8000-%08x%04x", (unsigned)getpid() & 0xffff, (unsigned)rand() & 0xffff, (unsigned)rand(), (unsigned)rand() & 0xffff);
            sid = g_sidbuf; note("clear", sid);
            fputs("\033[2J\033[H", stdout); fflush(stdout);
            write_row(sid, "idle", (long)time(NULL));
            continue;
        }
        { const char *tm = getenv("FAKE_TURN_MS");                             /* FAKE_TURN_MS: a message is a turn (busy for that long, then idle with a new stamp) */
          if (tm && atol(tm) > 0 && line[0] != '/' && line[0] != '\n') {
              long ms = atol(tm); struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
              write_row(sid, "busy", (long)time(NULL)); nanosleep(&ts, NULL); write_row(sid, "idle", (long)time(NULL));
              continue;
          } }
        if (!strcmp(line, "/exit\n") && !getenv("FAKE_IGNORE_EXIT")) {
            if (!exit_dialog()) continue;                                      /* the dialog dismissed: the session stays */
            note("exit", sid); fputs("\033[2J\033[H", stdout); fflush(stdout);
            child_stop(); unlink(path); if (sock[0]) unlink(sock); return 0;
        }
    }
}
