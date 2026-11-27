// libc.c – minimal standard library for Arkm OS
#include <stdint.h>
#include <stddef.h>

#define SYS_READ   0
#define SYS_WRITE  1
#define SYS_OPEN   2
#define SYS_CLOSE  3
#define SYS_MMAP   4
#define SYS_EXIT   5
#define SYS_CREAT  11
#define SYS_LSEEK  14

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR   2
#define O_CREAT  0100
#define O_TRUNC  01000

#define STDIN  0
#define STDOUT 1
#define STDERR 2

static inline long syscall(long num, long a1, long a2, long a3, long a4, long a5) {
    long ret;
    __asm__ volatile (
        "int $0x80"
        : "=a"(ret)
        : "a"(num), "D"(a1), "S"(a2), "d"(a3), "r"(a4), "r"(a5)
        : "memory"
    );
    return ret;
}

void* malloc(size_t size) {
    static void* heap = 0;
    if (!heap) heap = (void*)syscall(SYS_MMAP, 0x100000, 0x200000, 0, 0, 0);
    void* ptr = heap;
    heap += (size + 15) & ~15;
    return ptr;
}

void free(void* ptr) { /* not implemented */ }

int open(const char* path, int flags) {
    return syscall(SYS_OPEN, (long)path, flags, 0, 0, 0);
}

int creat(const char* path) {
    return syscall(SYS_CREAT, (long)path, 0, 0, 0, 0);
}

int close(int fd) {
    return syscall(SYS_CLOSE, fd, 0, 0, 0, 0);
}

ssize_t read(int fd, void* buf, size_t count) {
    return syscall(SYS_READ, fd, (long)buf, count, 0, 0);
}

ssize_t write(int fd, const void* buf, size_t count) {
    return syscall(SYS_WRITE, fd, (long)buf, count, 0, 0);
}

off_t lseek(int fd, off_t offset, int whence) {
    return syscall(SYS_LSEEK, fd, offset, whence, 0, 0);
}

void putchar(char c) {
    write(STDOUT, &c, 1);
}

void puts(const char* str) {
    while (*str) putchar(*str++);
    putchar('\n');
}

void printf(const char* fmt, ...) {
    // Simplified: only prints strings
    while (*fmt) {
        if (*fmt == '%') {
            fmt++;
            if (*fmt == 's') {
                // We would need varargs to fetch the argument; for now just print "(string)"
                puts("(string)");
            } else if (*fmt == 'd') {
                puts("(int)");
            }
            fmt++;
        } else {
            putchar(*fmt++);
        }
    }
}

void exit(int status) {
    syscall(SYS_EXIT, status, 0, 0, 0, 0);
    while(1);
}