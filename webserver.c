#include <stdint.h>
#include <stddef.h>

// ==========================================
// 0. USER-SPACE MEMORY HELPERS
// ==========================================
void* memcpy(void* dest, const void* src, size_t n) {
    uint8_t* d = (uint8_t*)dest;
    const uint8_t* s = (const uint8_t*)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dest;
}

void* memset(void* dest, int val, size_t count) {
    uint8_t* d = (uint8_t*)dest;
    for (size_t i = 0; i < count; i++) d[i] = (uint8_t)val;
    return dest;
}

// ==========================================
// 1. ARKM SYSCALL DEFINITIONS
// ==========================================
#define SYS_EXIT        7
#define SYS_DRAW_RECT   9
#define SYS_DRAW_TEXT   10
#define SYS_SOCKET      11
#define SYS_BIND        12
#define SYS_LISTEN      13
#define SYS_ACCEPT_NEXT 28
#define SYS_RECV_FD     29
#define SYS_SEND        19
#define SYS_CLOSE       23
#define SYS_YIELD       30

// ==========================================
// 2. USER-SPACE INTERFACES
// ==========================================
typedef struct { int x, y, w, h; uint32_t color; } ui_rect_t;
typedef struct { int x, y; uint32_t color; char text[64]; } ui_text_t;
typedef struct { int sockfd; const void* buf; size_t len; int flags; } sys_send_args_t;
typedef struct { int sockfd; void* buf; size_t len; int flags; } sys_recv_args_t;

typedef struct {
    int fd;
    uint8_t active;
    uint16_t used;
    char request[2048];
} worker_t;

#define MAX_WORKERS 8

uint64_t syscall(uint64_t sys_num, uint64_t param) {
    uint64_t ret;
    __asm__ volatile ("int $0x80" : "=a" (ret) : "D" (sys_num), "S" (param) : "memory");
    return ret;
}

void exit(uint64_t code) {
    syscall(SYS_EXIT, code);
    while (1) { }
}

uint64_t draw_rect(int x, int y, int w, int h, uint32_t color) {
    ui_rect_t rect = {x, y, w, h, color};
    return syscall(SYS_DRAW_RECT, (uint64_t)&rect);
}

void strcpy_custom(char* dest, const char* src) {
    while (*src) { *dest++ = *src++; }
    *dest = '\0';
}

void strcat_custom(char* dest, const char* src) {
    while (*dest) dest++;
    while (*src) { *dest++ = *src++; }
    *dest = '\0';
}

void itoa_custom(int val, char* buf) {
    if (val == 0) { buf[0] = '0'; buf[1] = '\0'; return; }
    int i = 0; char temp[16];
    while (val > 0) { temp[i++] = '0' + (val % 10); val /= 10; }
    int j = 0;
    while (i > 0) { buf[j++] = temp[--i]; }
    buf[j] = '\0';
}

uint64_t draw_text(int x, int y, uint32_t color, const char* str) {
    ui_text_t txt;
    txt.x = x; txt.y = y; txt.color = color;
    strcpy_custom(txt.text, str);
    return syscall(SYS_DRAW_TEXT, (uint64_t)&txt);
}

// ==========================================
// 3. NETWORK WRAPPERS
// ==========================================
int accept_next(void) {
    return (int)syscall(SYS_ACCEPT_NEXT, 0);
}

long recv_fd(int sockfd, void* buf, size_t len, int flags) {
    sys_recv_args_t args = {sockfd, buf, len, flags};
    return (long)syscall(SYS_RECV_FD, (uint64_t)&args);
}

long send_fd(int sockfd, const void* buf, size_t len, int flags) {
    sys_send_args_t args = {sockfd, buf, len, flags};
    return (long)syscall(SYS_SEND, (uint64_t)&args);
}

int close_fd(int fd) {
    return (int)syscall(SYS_CLOSE, (uint64_t)fd);
}

void yield_cpu(void) { syscall(SYS_YIELD, 0); }

int has_header_end(const char* buf, uint16_t len) {
    if (len < 4) return 0;
    for (uint16_t i = 0; i + 3 < len; i++) {
        if (buf[i] == '\r' && buf[i+1] == '\n' && buf[i+2] == '\r' && buf[i+3] == '\n') return 1;
    }
    return 0;
}

int send_all(int fd, const char* buf, int len) {
    int sent = 0;
    while (sent < len) {
        long n = send_fd(fd, buf + sent, (size_t)(len - sent), 0);
        if (n <= 0) return -1;
        sent += (int)n;
    }
    return sent;
}

void worker_reset(worker_t* w) {
    if (!w) return;
    w->fd = -1;
    w->active = 0;
    w->used = 0;
    memset(w->request, 0, sizeof(w->request));
}

// ==========================================
// 4. APPLICATION ENTRY POINT
// ==========================================
void _start() {
    draw_rect(0, 0, 200, 200, 0x111111);
    draw_rect(0, 0, 200, 25, 0x0055AA);
    draw_text(10, 5, 0xFFFFFF, "ARKM HTTP DAEMON");
    draw_rect(10, 35, 180, 1, 0x555555);

    int cursor_y = 50;
    draw_text(10, cursor_y, 0xAAAAAA, "Allocating socket...");

    int fd = (int)syscall(SYS_SOCKET, 0);
    if (fd < 0) {
        draw_text(10, cursor_y + 15, 0xFF0000, "-> FAILED");
        exit(1);
    }

    char msg[64] = "-> SUCCESS [FD: ";
    char fd_str[8];
    itoa_custom(fd, fd_str);
    strcat_custom(msg, fd_str);
    strcat_custom(msg, "]");
    draw_text(10, cursor_y + 15, 0x00FF00, msg);
    cursor_y += 40;

    draw_text(10, cursor_y, 0xAAAAAA, "Binding Port 80...");
    if ((int)syscall(SYS_BIND, 80) != 0) {
        draw_text(10, cursor_y + 15, 0xFF0000, "-> BIND FAILED");
        exit(1);
    }
    draw_text(10, cursor_y + 15, 0x00FF00, "-> BOUND 0.0.0.0:80");
    cursor_y += 40;

    draw_text(10, cursor_y, 0xAAAAAA, "Initiating Listen...");
    if ((int)syscall(SYS_LISTEN, 0) != 0) {
        draw_text(10, cursor_y + 15, 0xFF0000, "-> LISTEN FAILED");
        exit(1);
    }
    draw_text(10, cursor_y + 15, 0x00FFFF, "-> SERVER ONLINE");
    cursor_y += 40;

    /* Safe concurrent worker pool. The workers are cooperative/polling from
       Ring 3; the kernel owns the actual scheduling and TCP state. */
    worker_t workers[MAX_WORKERS];
    for (int i = 0; i < MAX_WORKERS; i++) worker_reset(&workers[i]);

    const char* http_body =
        "<html><body style='background-color: #0d0d0d; color: #00ffcc; font-family: monospace; text-align: center; margin-top: 15%;'>"
        "<h1>ARKM Kernel Phase 7</h1>"
        "<h2>Ring 3 Web Server is Online!</h2>"
        "<p>This page was served from User-Space Memory over the custom E1000 Driver.</p>"
        "</body></html>";

    char http_response[2048];
    char body_len_str[16];
    int body_len = 0;
    while (http_body[body_len]) body_len++;
    itoa_custom(body_len, body_len_str);
    strcpy_custom(http_response, "HTTP/1.1 200 OK\r\n");
    strcat_custom(http_response, "Content-Type: text/html\r\n");
    strcat_custom(http_response, "Content-Length: ");
    strcat_custom(http_response, body_len_str);
    strcat_custom(http_response, "\r\nConnection: close\r\n\r\n");
    strcat_custom(http_response, http_body);

    int response_len = 0;
    while (http_response[response_len]) response_len++;

    while (1) {
        /* Accept every available connection into an idle worker slot. */
        for (int slot = 0; slot < MAX_WORKERS; slot++) {
            if (workers[slot].active) continue;
            int client_fd = accept_next();
            if (client_fd < 0) break;

            workers[slot].fd = client_fd;
            workers[slot].active = 1;
            workers[slot].used = 0;
            memset(workers[slot].request, 0, sizeof(workers[slot].request));

            draw_rect(0, cursor_y, 200, 30, 0x111111);
            draw_text(10, cursor_y, 0xFF00FF, "Client Connected!");
        }

        /* Poll each client without blocking other clients. */
        for (int slot = 0; slot < MAX_WORKERS; slot++) {
            worker_t* w = &workers[slot];
            if (!w->active) continue;

            if (w->used < sizeof(w->request) - 1) {
                long n = recv_fd(w->fd, w->request + w->used,
                                 sizeof(w->request) - 1 - w->used, 0);
                if (n > 0) w->used += (uint16_t)n;
            }

            if (has_header_end(w->request, w->used)) {
                if (send_all(w->fd, http_response, response_len) < 0) {
                    draw_text(10, cursor_y + 15, 0xFF0000, "Send failed.");
                } else {
                    draw_text(10, cursor_y + 15, 0x00FF00, "Payload Sent.");
                }

                /* Explicit close() is now part of the application protocol.
                   The kernel sends FIN|ACK and owns the TCP teardown. */
                close_fd(w->fd);
                worker_reset(w);
            }
        }

        yield_cpu();
    }
}
