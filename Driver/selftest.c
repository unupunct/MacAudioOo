// Host-side self test for the driver bundle: loads the built plug-in, drives it the way
// coreaudiod would (properties, two clients, StartIO, IO cycles) and keeps the shared
// memory alive so the Swift reader test can verify the audio. Needs no root and does not
// touch the system audio configuration.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>

#define CHECK(cond, msg) do { if (!(cond)) { printf("SELFTEST FAIL: %s\n", msg); exit(1); } } while (0)

static OSStatus hostNoop(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress* a) { return 0; }
static OSStatus hostChange(AudioServerPlugInHostRef h, AudioObjectID d, UInt64 act, void* i) { return 0; }
static AudioServerPlugInHostInterface gHost;

static double nowSec(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

int main(int argc, char** argv) {
    if (argc < 3) { printf("usage: selftest <driver-binary> <seconds>\n"); return 2; }
    void* lib = dlopen(argv[1], RTLD_NOW);
    CHECK(lib, "dlopen driver binary");
    void* (*create)(CFAllocatorRef, CFUUIDRef) = dlsym(lib, "MacAudioOoDriverCreate");
    CHECK(create, "factory symbol");
    CHECK(create(NULL, CFUUIDCreateFromString(NULL, CFSTR("00000000-0000-0000-0000-000000000000"))) == NULL, "factory rejects wrong type");
    AudioServerPlugInDriverRef drv = create(NULL, kAudioServerPlugInTypeUUID);
    CHECK(drv, "factory returns driver");
    AudioServerPlugInDriverInterface* i = *drv;

    gHost.PropertiesChanged = hostNoop; gHost.RequestDeviceConfigurationChange = hostChange;
    CHECK(i->Initialize(drv, &gHost) == 0, "Initialize");

    // Property sanity: plug-in lists exactly one device; device has our name/UID, 1 output stream, 2 rates.
    AudioObjectPropertyAddress a = { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 sz = 0; AudioObjectID devs[4];
    CHECK(i->GetPropertyDataSize(drv, kAudioObjectPlugInObject, 0, &a, 0, NULL, &sz) == 0 && sz == 4, "device list size");
    CHECK(i->GetPropertyData(drv, kAudioObjectPlugInObject, 0, &a, 0, NULL, sizeof devs, &sz, devs) == 0 && devs[0] == 2, "device list");
    a.mSelector = kAudioObjectPropertyName;
    CFStringRef name = NULL; sz = sizeof name;
    CHECK(i->GetPropertyData(drv, 2, 0, &a, 0, NULL, sizeof name, &sz, &name) == 0 && name, "device name");
    CHECK(CFStringCompare(name, CFSTR("MacAudioOo Mixer"), 0) == kCFCompareEqualTo, "device name value");
    a.mSelector = kAudioDevicePropertyStreams; a.mScope = kAudioObjectPropertyScopeOutput;
    CHECK(i->GetPropertyDataSize(drv, 2, 0, &a, 0, NULL, &sz) == 0 && sz == 4, "one output stream");
    a.mScope = kAudioObjectPropertyScopeInput;
    CHECK(i->GetPropertyDataSize(drv, 2, 0, &a, 0, NULL, &sz) == 0 && sz == 0, "no input streams");
    a.mSelector = kAudioDevicePropertyNominalSampleRate; a.mScope = kAudioObjectPropertyScopeGlobal;
    Float64 rate = 0; sz = sizeof rate;
    CHECK(i->GetPropertyData(drv, 2, 0, &a, 0, NULL, sizeof rate, &sz, &rate) == 0 && rate == 48000.0, "default rate 48000");
    Float64 bad = 12345;
    CHECK(i->SetPropertyData(drv, 2, 0, &a, 0, NULL, sizeof bad, &bad) != 0, "unsupported rate rejected");
    a.mSelector = kAudioStreamPropertyVirtualFormat;
    AudioStreamBasicDescription fmt; sz = sizeof fmt;
    CHECK(i->GetPropertyData(drv, 3, 0, &a, 0, NULL, sizeof fmt, &sz, &fmt) == 0 && fmt.mChannelsPerFrame == 2 && fmt.mBitsPerChannel == 32, "stream format");

    // Two clients (two "applications").
    AudioServerPlugInClientInfo c1 = { 101, 4001, false, CFSTR("com.example.appA") }, c2 = { 102, 4002, false, CFSTR("com.example.appB") },
                                c3 = { 103, 4003, false, CFSTR("com.apple.idlehelper") };   // connects but never plays (like macOS system helpers)
    CHECK(i->AddDeviceClient(drv, 2, &c1) == 0 && i->AddDeviceClient(drv, 2, &c2) == 0 && i->AddDeviceClient(drv, 2, &c3) == 0, "AddDeviceClient");
    CHECK(i->StartIO(drv, 2, 101) == 0, "StartIO");
    Boolean will = 0, inPlace = 0;
    CHECK(i->WillDoIOOperation(drv, 2, 101, kAudioServerPlugInIOOperationProcessOutput, &will, &inPlace) == 0 && will, "WillDo ProcessOutput");
    Float64 st; UInt64 ht, seed;
    CHECK(i->GetZeroTimeStamp(drv, 2, 101, &st, &ht, &seed) == 0, "GetZeroTimeStamp");

    const UInt32 frames = 512; const double sr = 48000.0;
    float bufA[512 * 2], bufB[512 * 2];
    double pa = 0, pb = 0;
    int cycles = (int)(atof(argv[2]) * sr / frames);
    double t0 = nowSec();
    printf("driver loaded; running %d IO cycles (A=440 Hz amp 0.5, B=660 Hz amp 0.25)\n", cycles); fflush(stdout);
    for (int n = 0; n < cycles; n++) {
        for (UInt32 f = 0; f < frames; f++) {
            float a = 0.5f * sinf((float)pa), b = 0.25f * sinf((float)pb);
            bufA[2 * f] = bufA[2 * f + 1] = a; bufB[2 * f] = bufB[2 * f + 1] = b;
            pa += 2 * M_PI * 440 / sr; pb += 2 * M_PI * 660 / sr;
        }
        AudioServerPlugInIOCycleInfo info; memset(&info, 0, sizeof info);
        i->DoIOOperation(drv, 2, 3, 101, kAudioServerPlugInIOOperationProcessOutput, frames, &info, bufA, NULL);
        i->DoIOOperation(drv, 2, 3, 102, kAudioServerPlugInIOOperationProcessOutput, frames, &info, bufB, NULL);
        // Deadline-based pacing so the producer runs at the nominal rate without cumulative drift.
        double deadline = t0 + (double)(n + 1) * frames / sr, d = deadline - nowSec();
        if (d > 0) usleep((useconds_t)(d * 1e6));
    }
    i->RemoveDeviceClient(drv, 2, &c1); i->RemoveDeviceClient(drv, 2, &c2); i->RemoveDeviceClient(drv, 2, &c3);
    i->StopIO(drv, 2, 101);
    printf("SELFTEST DRIVER OK\n");
    return 0;
}
