#include <stdint.h>
#include <stddef.h>

// ==========================================
// 1. CONSTANTS & STRUCTURES
// ==========================================
#define SYS_ALLOC_PAGES 1
#define SYS_DISK_WRITE  2
#define SYS_DISK_READ   3
#define SYS_RUN_APP     4
#define SYS_IPC_SEND    5
#define SYS_IPC_RECV    6
#define SYS_EXIT        7
#define SYS_NET_SEND    8
#define SYS_DRAW_RECT   9
#define SYS_DRAW_TEXT   10

// ---> ARKM IPC MESSAGE STRUCTURE <---
typedef struct {
    uint32_t sender_id;
    uint32_t receiver_id;
    uint32_t type;       
    char payload[128];
    int valid;
} ipc_message_t;

// ---> NEW: RING 3 NETWORK & UI STRUCTURES <---
typedef struct { uint64_t ptr; uint16_t len; } net_packet_t;
typedef struct { int x, y, w, h; uint32_t color; } ui_rect_t;
typedef struct { int x, y; uint32_t color; char text[64]; } ui_text_t;

// ==========================================
// 2. ARKM SYSCALL INTERFACE & WRAPPERS
// ==========================================
uint64_t syscall(uint64_t sys_num, uint64_t param) {
    uint64_t ret;
    // Trigger interrupt 0x80 to trap into Ring 0
    __asm__ volatile ("int $0x80" : "=a" (ret) : "D" (sys_num), "S" (param) : "memory");
    return ret;
}

void exit(uint64_t code) {
    syscall(SYS_EXIT, code);
    while(1); // Should never be reached
}

uint64_t disk_write(void* buffer) {
    return syscall(SYS_DISK_WRITE, (uint64_t)buffer);
}

uint64_t disk_read(void* buffer) {
    return syscall(SYS_DISK_READ, (uint64_t)buffer);
}

uint64_t ipc_recv(ipc_message_t* msg) {
    return syscall(SYS_IPC_RECV, (uint64_t)msg);
}

uint64_t ipc_send(ipc_message_t* msg) {
    return syscall(SYS_IPC_SEND, (uint64_t)msg);
}

// UI System Calls
uint64_t draw_rect(int x, int y, int w, int h, uint32_t color) {
    ui_rect_t rect = {x, y, w, h, color};
    return syscall(SYS_DRAW_RECT, (uint64_t)&rect);
}

void strcpy_custom(char* dest, const char* src) {
    while (*src) { *dest++ = *src++; }
    *dest = '\0';
}

uint64_t draw_text(int x, int y, uint32_t color, const char* str) {
    ui_text_t txt;
    txt.x = x; 
    txt.y = y; 
    txt.color = color;
    strcpy_custom(txt.text, str);
    return syscall(SYS_DRAW_TEXT, (uint64_t)&txt);
}

// Network System Call
uint64_t net_send(const uint8_t* payload, uint16_t len) {
    net_packet_t pkt = {(uint64_t)payload, len};
    return syscall(SYS_NET_SEND, (uint64_t)&pkt);
}

// Standard 'memset' to satisfy Clang's aggressive optimizer
void* memset(void* dest, int val, uint64_t count) {
    uint8_t* d = (uint8_t*)dest;
    for (uint64_t i = 0; i < count; i++) d[i] = (uint8_t)val;
    return dest;
}

// Pseudo-print that triggers the disk proxy to register a telemetry event
static void sys_print(const char* msg) {
    char buf[512]; // Uninitialized array
    memset(buf, 0, 512); // Manually clear it to avoid compiler-generated standard lib calls
    int i = 0;
    while (msg[i] != '\0' && i < 500) { buf[i] = msg[i]; i++; }
    disk_write(buf);
}

// ==========================================
// 3. TEST VYOM: MANUAL MODULES
// ==========================================

/* [KEY 1] Module 1: The Null Pointer & Kernel Memory Probe */
void vyom_aegis_breach(void) {
    sys_print("VYOM [1/9]: Testing Aegis Pointer Security...");
    syscall(SYS_DISK_WRITE, 0x0); // NULL
    syscall(SYS_DISK_WRITE, 0x00080000); // Kernel Space
    syscall(SYS_DISK_READ, 0x00100000); // Page Tables
}

/* [KEY 2] Module 2: Physical Memory Exhaustion Rampage */
void vyom_ram_blast(void) {
    sys_print("VYOM [2/9]: Testing Physical Memory Guardrails...");
    syscall(SYS_ALLOC_PAGES, 0);
    syscall(SYS_ALLOC_PAGES, 0xFFFFFFFFFFFFFFFFULL); // Massive overflow request
    
    // Rapid Page Drain
    for (int i = 0; i < 10000; i++) {
        uint64_t res = syscall(SYS_ALLOC_PAGES, 1);
        if (res != 1) break; // Should successfully hit 95% guardrail cutoff
    }
}

/* [KEY 3] Module 3: Cross-Core Race Condition & IPC Stress */
void vyom_apic_storm(void) {
    sys_print("VYOM [3/9]: Stress-testing IPC Bus...");
    ipc_message_t msg;
    msg.receiver_id = 1; 
    msg.type = 0xAA;
    for (int i = 0; i < 100; i++) { msg.payload[i] = 'V'; }
    msg.valid = 1;

    for (int i = 0; i < 200; i++) {
        ipc_send(&msg); // Flood the bus without deadlocking
    }
}

/* [KEY 4] Module 4: Privilege Escalation & Segment Hijack */
void vyom_ring_break(void) { 
    sys_print("VYOM [4/9]: Executing 'cli' instruction inside Ring 3...");
    __asm__ volatile ("cli"); 
}

/* [KEY 5] Module 5: Microkernel Supervision & Recovery Loop */
void vyom_micro_supervisor(void) { 
    sys_print("VYOM [5/9]: Testing Microkernel Recovery Engine...");
    volatile uint64_t* bad = (uint64_t*)0xDEADBEEF0000ULL; 
    (void)*bad; 
}

/* [KEY 6] Module 6: Stack Overflow & IST Stack Thrashing */
void vyom_infinite_recursion(int depth) {
    volatile char stack_data[1024]; 
    for (int i = 0; i < 1024; i++) stack_data[i] = (char)depth;
    if (depth < 100) vyom_infinite_recursion(depth + 1);
}

void vyom_stack_hammer(void) { 
    sys_print("VYOM [6/9]: Overflown User Stack into Unmapped Virtual Space...");
    vyom_infinite_recursion(1); 
}

/* [KEY 7] Module 7: Storage Buffer Overrun & Garbage Fuzzing */
void vyom_disk_fuzzer(void) {
    sys_print("VYOM [7/9]: Fuzzing Storage Drivers with Unaligned Buffers...");
    char unaligned_buffer[512 + 7];
    char* target_ptr = &unaligned_buffer[3]; // Fuzz Unaligned boundary
    for (int i = 0; i < 500; i++) { target_ptr[i] = (char)(i & 0xFF); }
    syscall(SYS_DISK_WRITE, (uint64_t)target_ptr);
}

/* [KEY 8] Module 8: Graphical Sandbox & Custom UI */
void vyom_ui_test(void) {
    sys_print("VYOM [8/9]: Drawing custom UI from Ring 3 Sandbox...");
    
    // Draw Application Background
    draw_rect(0, 0, 200, 200, 0x1A1A2E); 
    
    // Draw Header Bar
    draw_rect(0, 0, 200, 30, 0x0F3460); 
    draw_text(10, 8, 0xE94560, "ARKM APP RUNTIME"); 
    
    // Draw Content
    draw_rect(20, 50, 160, 2, 0xE94560); // Divider Line
    draw_text(20, 70, 0x00FF00, "SYSTEM ONLINE");
    draw_text(20, 90, 0x00FFFF, "AEGIS PAGING OK");
    draw_text(20, 110, 0xFFFF00, "UI ENGINE OK");
    
    // Draw Footer Button
    draw_rect(40, 150, 120, 30, 0xE94560);
    draw_text(55, 158, 0xFFFFFF, "PRESS ESC");
}

/* [KEY 9] Module 9: E1000 Network Card Fuzzing */
void vyom_net_test(void) {
    sys_print("VYOM [9/9]: Firing raw broadcast packet to E1000 NIC...");
    // Craft a dummy raw Ethernet packet
    uint8_t packet[64];
    memset(packet, 0xFF, 6); // Destination MAC (Broadcast)
    memset(packet + 6, 0xAA, 6); // Source MAC (Dummy)
    packet[12] = 0x08; packet[13] = 0x00; // EtherType IPv4
    strcpy_custom((char*)&packet[14], "ARKM KERNEL SAYS HELLO");
    
    net_send(packet, 64);
}

// ==========================================
// 4. APPLICATION ENTRY POINT
// ==========================================
void _start() {
    ipc_message_t msg;
    char app_state[512];
    memset(app_state, 0, 512);
    
    // Inject ARKM Magic Bytes for the Kernel to recognize (Paints window Magenta on disk write)
    app_state[0] = 'A';
    app_state[1] = 'I';
    app_state[2] = ':';
    app_state[3] = ' ';
    int cursor = 4;

    // Enter polling loop to allow user to trigger tests manually or type
    while(1) {
        if (ipc_recv(&msg)) {
            if (msg.type == 1) { 
                char c = msg.payload[0];
                
                // ESC Key (ASCII 27): Trap to Ring 0 and kill sandbox
                if (c == 27) {
                    exit(0);
                }
                // Tilde (~): Trigger physical disk write to paint window
                else if (c == '~') {
                    disk_write(app_state);
                }
                // MANUAL TEST VYOM TRIGGERS (Keys 1-9)
                else if (c == '1') vyom_aegis_breach();
                else if (c == '2') vyom_ram_blast();
                else if (c == '3') vyom_apic_storm();
                else if (c == '4') vyom_ring_break();
                else if (c == '5') vyom_micro_supervisor();
                else if (c == '6') vyom_stack_hammer();
                else if (c == '7') vyom_disk_fuzzer();
                else if (c == '8') vyom_ui_test();
                else if (c == '9') vyom_net_test();
                
                // Standard character buffering
                else if (cursor < 511 && c >= 32 && c <= 126) {
                    app_state[cursor++] = c;
                }
            }
        }
        
        // Ring 3 CPU yield to prevent lockup
        for(volatile int i = 0; i < 50000; i++) {
            __asm__ volatile("pause");
        }
    }
}