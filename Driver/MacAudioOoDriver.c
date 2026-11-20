// MacAudioOo virtual audio driver — an AudioServerPlugIn (user-space HAL plug-in,
// no kernel extension). It publishes one stereo output device, "MacAudioOo Mixer".
// Each application that plays to it is a separate HAL client; the driver copies every
// client's audio into its own ring buffer in shared memory (see MAOShared.h) so the
// MacAudioOo app can mix the applications independently. The driver itself produces
// no sound: with the app not running, audio sent to this device is discarded.
//
// Only documented AudioServerPlugIn API is used.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include "MAOShared.h"

#define kDeviceUID        "com.unupunct.MacAudioOo.Mixer"
#define kDeviceModelUID   "com.unupunct.MacAudioOo.Mixer.Model"
#define kDeviceName       "MacAudioOo Mixer"
#define kManufacturer     "MacAudioOo"
#define kPeriodFrames     16384   // zero-timestamp period

enum { kObjPlugIn = kAudioObjectPlugInObject, kObjDevice = 2, kObjStream = 3 };

static const Float64 kRates[] = { 44100.0, 48000.0 };
#define kRateCount 2

// ---- driver state --------------------------------------------------------------
static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static Float64 gSampleRate = 48000.0;
static UInt32 gStartCount = 0;
static UInt64 gAnchorHost = 0;
static Float64 gTicksPerFrame = 0;
static UInt64 gSeed = 1;

static void* gShm = NULL;
static MAOHeader* gHeader = NULL;

static MAOSlotHeader* slotHeader(int i) {
    return (MAOSlotHeader*)((uint8_t*)gShm + MAO_HEADER_SIZE + (size_t)i * MAO_SLOT_SIZE);
}
static float* slotRing(int i) { return (float*)((uint8_t*)slotHeader(i) + MAO_SLOT_HEADER); }

static void setupSharedMemory(void) {
    // MAO_SHM_NAME may be overridden for tests; inside coreaudiod it is never set.
    const char* shmName = getenv("MAO_SHM_NAME");
    int fd = shm_open(shmName ? shmName : MAO_SHM_NAME, O_CREAT | O_RDWR, 0666);
    if (fd < 0) return;
    fchmod(fd, 0666);   // readable by the logged-in user's app
    if (ftruncate(fd, MAO_TOTAL_SIZE) != 0) { close(fd); return; }
    void* p = mmap(NULL, MAO_TOTAL_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return;
    memset(p, 0, MAO_TOTAL_SIZE);
    gShm = p; gHeader = (MAOHeader*)p;
    gHeader->version = MAO_VERSION;
    gHeader->sampleRate = (uint32_t)gSampleRate;
    gHeader->slotCount = MAO_MAX_SLOTS;
    gHeader->ringFrames = MAO_RING_FRAMES;
    gHeader->running = 0;
    __atomic_store_n(&gHeader->magic, MAO_MAGIC, __ATOMIC_RELEASE);
}

// ---- helpers for property answers ---------------------------------------------------
#define PUT(type, value) do { *outSize = sizeof(type); if (outData) { \
    if (bufSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; \
    *(type*)outData = (value); } return kAudioHardwareNoError; } while (0)

#define PUTSTR(cstr) do { *outSize = sizeof(CFStringRef); if (outData) { \
    if (bufSize < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError; \
    *(CFStringRef*)outData = CFStringCreateWithCString(NULL, (cstr), kCFStringEncodingUTF8); } \
    return kAudioHardwareNoError; } while (0)

static OSStatus putIDList(const AudioObjectID* ids, UInt32 n, UInt32 bufSize, UInt32* outSize, void* outData) {
    UInt32 fit = bufSize / sizeof(AudioObjectID);
    if (outData == NULL) { *outSize = n * sizeof(AudioObjectID); return kAudioHardwareNoError; }
    if (fit < n) n = fit;
    for (UInt32 i = 0; i < n; i++) ((AudioObjectID*)outData)[i] = ids[i];
    *outSize = n * sizeof(AudioObjectID);
    return kAudioHardwareNoError;
}

static AudioStreamBasicDescription currentFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = gSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 8; f.mFramesPerPacket = 1; f.mBytesPerFrame = 8;
    f.mChannelsPerFrame = 2; f.mBitsPerChannel = 32;
    return f;
}

// ---- COM-style plumbing --------------------------------------------------------------
static AudioServerPlugInDriverInterface gInterface;
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

static HRESULT QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT r = E_NOINTERFACE;
    if (CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex); gRefCount++; pthread_mutex_unlock(&gMutex);
        *outInterface = gDriverRef; r = S_OK;
    }
    CFRelease(req);
    return r;
}
static ULONG AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex); ULONG n = ++gRefCount; pthread_mutex_unlock(&gMutex); return n;
}
static ULONG Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG n = gRefCount;
    pthread_mutex_unlock(&gMutex);
    return n;
}

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1.0e9 * (Float64)tb.denom / (Float64)tb.numer;
    gTicksPerFrame = ticksPerSecond / gSampleRate;
    setupSharedMemory();
    return kAudioHardwareNoError;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID dev) { return kAudioHardwareUnsupportedOperationError; }

// Each HAL client (one per application audio connection) gets its own shared-memory slot.
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* info) {
    if (d != gDriverRef || dev != kObjDevice) return kAudioHardwareBadObjectError;
    if (!gShm) return kAudioHardwareNoError;
    pthread_mutex_lock(&gMutex);
    for (int i = 0; i < MAO_MAX_SLOTS; i++) {
        MAOSlotHeader* s = slotHeader(i);
        if (!s->active) {
            memset(s->bundleID, 0, sizeof s->bundleID);
            if (info->mBundleID) CFStringGetCString(info->mBundleID, s->bundleID, sizeof s->bundleID, kCFStringEncodingUTF8);
            s->pid = info->mProcessID;
            s->clientID = info->mClientID;
            __atomic_store_n(&s->writeIndex, 0, __ATOMIC_RELEASE);
            __atomic_add_fetch(&s->generation, 1, __ATOMIC_RELEASE);
            __atomic_store_n(&s->active, 1, __ATOMIC_RELEASE);
            break;
        }
    }
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID dev, const AudioServerPlugInClientInfo* info) {
    if (d != gDriverRef || dev != kObjDevice) return kAudioHardwareBadObjectError;
    if (!gShm) return kAudioHardwareNoError;
    pthread_mutex_lock(&gMutex);
    for (int i = 0; i < MAO_MAX_SLOTS; i++) {
        MAOSlotHeader* s = slotHeader(i);
        if (s->active && s->clientID == info->mClientID) { __atomic_store_n(&s->active, 0, __ATOMIC_RELEASE); break; }
    }
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    if (d != gDriverRef || dev != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    gSampleRate = (Float64)action;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    gTicksPerFrame = (1.0e9 * (Float64)tb.denom / (Float64)tb.numer) / gSampleRate;
    if (gHeader) gHeader->sampleRate = (uint32_t)gSampleRate;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt64 action, void* info) {
    return kAudioHardwareNoError;
}

// ---- properties ------------------------------------------------------------------------
static bool isSupportedRate(Float64 r) { for (int i = 0; i < kRateCount; i++) if (kRates[i] == r) return true; return false; }

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a);
static OSStatus GetProp(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual,
                        UInt32 bufSize, UInt32* outSize, void* outData);

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a) {
    UInt32 sz = 0;
    return GetProp(obj, a, 0, NULL, 0, &sz, NULL) == kAudioHardwareNoError;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    UInt32 sz = 0;
    if (GetProp(obj, a, 0, NULL, 0, &sz, NULL) != kAudioHardwareNoError) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (obj == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;
    if (obj == kObjStream && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) *out = true;
    return kAudioHardwareNoError;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                    UInt32 qualSize, const void* qual, UInt32* outSize) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return GetProp(obj, a, qualSize, qual, 0, outSize, NULL);
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qualSize, const void* qual, UInt32 bufSize, UInt32* outSize, void* outData) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    return GetProp(obj, a, qualSize, qual, bufSize, outSize, outData);
}

static OSStatus GetProp(AudioObjectID obj, const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual,
                        UInt32 bufSize, UInt32* outSize, void* outData) {
    if (obj == kObjPlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUTSTR(kManufacturer);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: { AudioObjectID ids[1] = { kObjDevice }; return putIDList(ids, 1, bufSize, outSize, outData); }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            if (!outData) { *outSize = sizeof(AudioObjectID); return kAudioHardwareNoError; }
            if (qualSize != sizeof(CFStringRef) || !qual) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(CFStringRef*)qual;
            CFStringRef mine = CFStringCreateWithCString(NULL, kDeviceUID, kCFStringEncodingUTF8);
            bool match = uid && CFStringCompare(uid, mine, 0) == kCFCompareEqualTo;
            CFRelease(mine);
            PUT(AudioObjectID, match ? kObjDevice : kAudioObjectUnknown);
        }
        case kAudioPlugInPropertyResourceBundle: PUTSTR("");
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    if (obj == kObjDevice) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjPlugIn);
        case kAudioObjectPropertyName:      PUTSTR(kDeviceName);
        case kAudioObjectPropertyManufacturer: PUTSTR(kManufacturer);
        case kAudioObjectPropertyOwnedObjects: {
            AudioObjectID ids[1] = { kObjStream };
            bool out = a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput;
            return putIDList(ids, out ? 1 : 0, bufSize, outSize, outData);
        }
        case kAudioDevicePropertyDeviceUID: PUTSTR(kDeviceUID);
        case kAudioDevicePropertyModelUID:  PUTSTR(kDeviceModelUID);
        case kAudioDevicePropertyTransportType: PUT(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: { AudioObjectID ids[1] = { kObjDevice }; return putIDList(ids, 1, bufSize, outSize, outData); }
        case kAudioDevicePropertyClockDomain: PUT(UInt32, 0);
        case kAudioDevicePropertyDeviceIsAlive: PUT(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: PUT(UInt32, gStartCount > 0 ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT(UInt32, a->mScope == kAudioObjectPropertyScopeOutput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT(UInt32, a->mScope == kAudioObjectPropertyScopeOutput ? 1 : 0);
        case kAudioDevicePropertyLatency: PUT(UInt32, 0);
        case kAudioDevicePropertyStreams: {
            AudioObjectID ids[1] = { kObjStream };
            bool out = a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == kAudioObjectPropertyScopeOutput;
            return putIDList(ids, out ? 1 : 0, bufSize, outSize, outData);
        }
        case kAudioObjectPropertyControlList: *outSize = 0; return kAudioHardwareNoError;
        case kAudioDevicePropertySafetyOffset: PUT(UInt32, 0);
        case kAudioDevicePropertyNominalSampleRate: PUT(Float64, gSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            *outSize = kRateCount * sizeof(AudioValueRange);
            if (outData) {
                if (bufSize < *outSize) return kAudioHardwareBadPropertySizeError;
                for (int i = 0; i < kRateCount; i++) { ((AudioValueRange*)outData)[i].mMinimum = kRates[i]; ((AudioValueRange*)outData)[i].mMaximum = kRates[i]; }
            }
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyIsHidden: PUT(UInt32, 0);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            *outSize = 2 * sizeof(UInt32);
            if (outData) { if (bufSize < *outSize) return kAudioHardwareBadPropertySizeError; ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 2; }
            return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT(UInt32, kPeriodFrames);
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    if (obj == kObjStream) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass:     PUT(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:     PUT(AudioObjectID, kObjDevice);
        case kAudioObjectPropertyOwnedObjects: *outSize = 0; return kAudioHardwareNoError;
        case kAudioStreamPropertyIsActive:  PUT(UInt32, 1);
        case kAudioStreamPropertyDirection: PUT(UInt32, 0);   // 0 = output
        case kAudioStreamPropertyTerminalType: PUT(UInt32, kAudioStreamTerminalTypeLine);
        case kAudioStreamPropertyStartingChannel: PUT(UInt32, 1);
        case kAudioStreamPropertyLatency: PUT(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: PUT(AudioStreamBasicDescription, currentFormat());
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            *outSize = kRateCount * sizeof(AudioStreamRangedDescription);
            if (outData) {
                if (bufSize < *outSize) return kAudioHardwareBadPropertySizeError;
                for (int i = 0; i < kRateCount; i++) {
                    AudioStreamRangedDescription* r = &((AudioStreamRangedDescription*)outData)[i];
                    Float64 save = gSampleRate; gSampleRate = kRates[i];
                    r->mFormat = currentFormat(); gSampleRate = save;
                    r->mSampleRateRange.mMinimum = kRates[i]; r->mSampleRateRange.mMaximum = kRates[i];
                }
            }
            return kAudioHardwareNoError;
        }
        default: return kAudioHardwareUnknownPropertyError;
        }
    }
    return kAudioHardwareBadObjectError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID obj, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qualSize, const void* qual, UInt32 size, const void* data) {
    if (d != gDriverRef) return kAudioHardwareBadObjectError;
    Float64 rate = 0;
    if (obj == kObjDevice && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        rate = *(const Float64*)data;
    } else if (obj == kObjStream && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)data;
        if (f->mFormatID != kAudioFormatLinearPCM || f->mChannelsPerFrame != 2 || f->mBitsPerChannel != 32 ||
            !(f->mFormatFlags & kAudioFormatFlagIsFloat)) return kAudioDeviceUnsupportedFormatError;
        rate = f->mSampleRate;
    } else {
        return kAudioHardwareUnknownPropertyError;
    }
    if (!isSupportedRate(rate)) return kAudioHardwareIllegalOperationError;
    if (rate != gSampleRate && gHost) {
        gHost->RequestDeviceConfigurationChange(gHost, kObjDevice, (UInt64)rate, NULL);
    }
    return kAudioHardwareNoError;
}

// ---- IO --------------------------------------------------------------------------------
static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID) {
    if (d != gDriverRef || dev != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gStartCount == 0) { gAnchorHost = mach_absolute_time(); gSeed++; if (gHeader) gHeader->running = 1; }
    gStartCount++;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}
static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID) {
    if (d != gDriverRef || dev != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gStartCount > 0) gStartCount--;
    if (gStartCount == 0 && gHeader) gHeader->running = 0;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID,
                                 Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    if (d != gDriverRef || dev != kObjDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gTicksPerFrame * (Float64)kPeriodFrames;
    UInt64 periods = (UInt64)((Float64)(now - gAnchorHost) / ticksPerPeriod);
    *outSampleTime = (Float64)(periods * (UInt64)kPeriodFrames);
    *outHostTime = gAnchorHost + (UInt64)((Float64)periods * ticksPerPeriod);
    *outSeed = gSeed;
    pthread_mutex_unlock(&gMutex);
    return kAudioHardwareNoError;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 op, Boolean* willDo, Boolean* inPlace) {
    if (d != gDriverRef || dev != kObjDevice) return kAudioHardwareBadObjectError;
    *willDo = (op == kAudioServerPlugInIOOperationProcessOutput || op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return kAudioHardwareNoError;
}
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info) { return kAudioHardwareNoError; }
static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 clientID, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* info) { return kAudioHardwareNoError; }

// Real-time thread: no locks, no allocation. Copies this client's audio into its ring.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 clientID, UInt32 op,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo* info, void* mainBuf, void* secondaryBuf) {
    if (op != kAudioServerPlugInIOOperationProcessOutput || !gShm || !mainBuf) return kAudioHardwareNoError;
    for (int i = 0; i < MAO_MAX_SLOTS; i++) {
        MAOSlotHeader* s = slotHeader(i);
        if (__atomic_load_n(&s->active, __ATOMIC_ACQUIRE) && s->clientID == clientID) {
            float* ring = slotRing(i);
            const float* in = (const float*)mainBuf;
            UInt64 w = s->writeIndex;
            for (UInt32 f = 0; f < frames; f++) {
                size_t pos = (size_t)((w + f) & (MAO_RING_FRAMES - 1)) * 2;
                ring[pos] = in[f * 2]; ring[pos + 1] = in[f * 2 + 1];
            }
            s->lastWriteHost = mach_absolute_time();
            __atomic_store_n(&s->writeIndex, w + frames, __ATOMIC_RELEASE);
            break;
        }
    }
    return kAudioHardwareNoError;
}

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice,
    AddDeviceClient, RemoveDeviceClient, PerformDeviceConfigurationChange, AbortDeviceConfigurationChange,
    HasProperty, IsPropertySettable, GetPropertyDataSize, GetPropertyData, SetPropertyData,
    StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation, EndIOOperation
};

// Factory named in Info.plist (CFPlugInFactories).
void* MacAudioOoDriverCreate(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    gInterfacePtr = &gInterface;
    gDriverRef = &gInterfacePtr;
    gRefCount = 1;
    return gDriverRef;
}
