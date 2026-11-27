#include <stdint.h>
#include <stddef.h>

// ==========================================
// 1. ARKM SYSTEM CALL INTERFACE (LIBC STUBS)
// ==========================================
static inline uint64_t arkm_syscall(uint64_t sys_num, uint64_t param) {
    uint64_t ret;
    __asm__ volatile ("int $0x80" : "=a" (ret) : "D" (sys_num), "S" (param) : "memory");
    return ret;
}

typedef struct { 
    int x, y; 
    uint32_t color; 
    char text[64]; 
} ui_text_t;

typedef struct { 
    int fd; 
    void* buf; 
    size_t count; 
} sys_read_args_t;

typedef struct { 
    int sockfd; 
    const void* buf; 
    size_t len; 
    int flags; 
} sys_send_args_t;

// POSIX Wrappers
int socket(int domain, int type, int protocol) { return (int)arkm_syscall(11, 0); }
int bind(int sockfd, uint16_t port)            { return (int)arkm_syscall(12, (uint64_t)port); }
int listen(int sockfd, int backlog)            { return (int)arkm_syscall(13, (uint64_t)backlog); }
int accept(int sockfd)                         { return (int)arkm_syscall(16, (uint64_t)sockfd); }
long recv(int sockfd, void *buf, size_t len, int flags) { return (long)arkm_syscall(17, (uint64_t)buf); }
long send(int sockfd, const void *buf, size_t len, int flags) {
    sys_send_args_t args = {sockfd, buf, len, flags};
    return (long)arkm_syscall(19, (uint64_t)&args);
}
void exit(int code) { arkm_syscall(7, (uint64_t)code); while(1); }

void printf(const char* format) {
    ui_text_t txt;
    txt.x = 20; 
    txt.y = 40; 
    txt.color = 0x00FF00; // Neon Green text for the web server
    int i = 0;
    while(format[i] && i < 63) { txt.text[i] = format[i]; i++; }
    txt.text[i] = '\0';
    arkm_syscall(10, (uint64_t)&txt);
}

// ==========================================
// 2. RING 3 HTTP SERVER APPLICATION
// ==========================================

int main() {
    printf("WEB.ELF: Booting POSIX HTTP Server...");
    
    // 1. Create a TCP Socket
    int server_fd = socket(2, 1, 6); // AF_INET, SOCK_STREAM, TCP
    if (server_fd < 0) {
        printf("WEB.ELF ERROR: Failed to create socket.");
        return 1;
    }
    
    // 2. Bind to Port 80
    bind(server_fd, 80);
    
    // 3. Listen for incoming connections
    listen(server_fd, 10);
    printf("WEB.ELF: Server Listening on Port 80...");
    
    // 4. Main Server Loop
    while (1) {
        // Accept blocks safely using our non-busy wait queue
        int client_fd = accept(server_fd);
        
        if (client_fd >= 0) {
            printf("WEB.ELF: Client connected! Sending Payload...");
            
            // Receive the incoming HTTP GET request
            char rx_buffer[1024];
            recv(client_fd, rx_buffer, 1024, 0);
            
            // The HTML Payload we want to serve
            const char* http_response = 
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/html\r\n"
                "Connection: close\r\n\r\n"
                "<html><body style='background-color: #1a1a1a; color: #00ff00; font-family: monospace; text-align: center; margin-top: 20%;'>"
                "<h1>ARKM Microkernel</h1>"
                "<h2>Ring 3 Web Server is Online!</h2>"
                "<p>Served directly from user-space memory via custom POSIX syscalls.</p>"
                "</body></html>";
            
            // Calculate length manually (no stdlib allowed)
            int len = 0;
            while(http_response[len]) len++;
            
            // Send the HTTP packet through the E1000 driver
            send(client_fd, http_response, len, 0);
            
            printf("WEB.ELF: Payload sent. Awaiting next client.");
        }
    }
    
    return 0;
}

// ==========================================
// 3. ELF ENTRY POINT
// ==========================================
// This is where the kernel jumps to when load_elf_from_vfs finishes.
void _start() {
    int ret = main();
    exit(ret);
}