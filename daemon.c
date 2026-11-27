// daemon.c - Ring 3 AI Intent Supervisor
#include <stdint.h>

typedef struct {
    uint32_t sender_id;
    uint32_t receiver_id;
    uint32_t type;
    char payload[128];
    int valid;
} ipc_message_t;

// Syscall 6: Receive IPC Message
uint64_t sys_ipc_recv(ipc_message_t* msg) {
    uint64_t ret;
    __asm__ volatile ("int $0x80" : "=a"(ret) : "D"(6), "S"((uint64_t)msg) : "memory");
    return ret;
}

// Syscall 5: Send IPC Message
uint64_t sys_ipc_send(ipc_message_t* msg) {
    uint64_t ret;
    __asm__ volatile ("int $0x80" : "=a"(ret) : "D"(5), "S"((uint64_t)msg) : "memory");
    return ret;
}

void _start() {
    // 1. Announce AI Daemon Online to Kernel (Syscall 2 -> Magenta UI)
    char msg[512];
    for(int i=0; i<512; i++) msg[i] = 0;
    msg[0] = 'A'; msg[1] = 'I'; msg[2] = ' '; msg[3] = 'O'; msg[4] = 'N';
    __asm__ volatile ("int $0x80" : : "D"(2), "S"((unsigned long)msg) : "memory");

    ipc_message_t inbox;
    
    while(1) {
        inbox.valid = 0;
        
        // 2. Poll the Kernel for new Intents/Telemetry
        uint64_t status = sys_ipc_recv(&inbox);
        
        if (status == 1 && inbox.valid == 1) {
            // We received an IPC message! 
            ipc_message_t outbox;
            outbox.receiver_id = inbox.sender_id; // Reply to sender
            outbox.type = 2; // AI Ack Type
            outbox.payload[0] = 'A'; outbox.payload[1] = 'I'; outbox.payload[2] = ' '; 
            outbox.payload[3] = 'O'; outbox.payload[4] = 'K'; outbox.payload[5] = '\0';
            
            sys_ipc_send(&outbox);
        }
        
        // 3. Yield CPU cycles back to Kernel Supervisor
        for(volatile int i = 0; i < 50000; i++) { __asm__ volatile("pause"); }
    }
}