// Shared-memory layout between the MacAudioOo virtual audio driver (runs inside
// coreaudiod) and the MacAudioOo app. The Swift side mirrors these offsets in
// Sources/MacAudioOo/AudioEngine/DriverSharedMemory.swift — keep both in sync.
//
// The driver is the only writer. The app maps the segment read-only and keeps its
// own read positions, so a crashed app can never stall or corrupt the driver.
#ifndef MAO_SHARED_H
#define MAO_SHARED_H

#include <stdint.h>

#define MAO_SHM_NAME      "/MacAudioOo.mix"   // POSIX shm names are limited to 31 chars
#define MAO_MAGIC         0x4D414F6F          // 'MAOo'
#define MAO_VERSION       1
#define MAO_MAX_SLOTS     32
#define MAO_RING_FRAMES   16384               // per client, power of two, stereo float32

// Header: 64 bytes
typedef struct {
    uint32_t magic;        // MAO_MAGIC
    uint32_t version;      // MAO_VERSION
    uint32_t sampleRate;   // current device nominal rate
    uint32_t slotCount;    // MAO_MAX_SLOTS
    uint32_t ringFrames;   // MAO_RING_FRAMES
    uint32_t running;      // 1 while the device has IO running
    uint32_t reserved[10];
} MAOHeader;

// Slot header: 128 bytes, followed by ringFrames * 2 floats (interleaved L,R).
typedef struct {
    volatile uint32_t active;        // 1 while the client exists
    int32_t           pid;
    uint32_t          clientID;
    volatile uint32_t generation;    // bumped whenever the slot is (re)assigned
    volatile uint64_t writeIndex;    // monotonic frame count written so far
    volatile uint64_t lastWriteHost; // mach_absolute_time of last write
    char              bundleID[64];
    uint8_t           reserved[128 - 32 - 64];
} MAOSlotHeader;

#define MAO_HEADER_SIZE   64
#define MAO_SLOT_HEADER   128
#define MAO_SLOT_SIZE     (MAO_SLOT_HEADER + MAO_RING_FRAMES * 2 * 4)
#define MAO_TOTAL_SIZE    (MAO_HEADER_SIZE + MAO_MAX_SLOTS * MAO_SLOT_SIZE)

#endif
