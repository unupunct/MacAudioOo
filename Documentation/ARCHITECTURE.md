# Architecture

```
App/            MacAudioOoApp (scenes, menu commands), AppState (owns every subsystem), SnapshotTool (dev-only: window
                screenshots and hardware self-tests)
AudioEngine/    AudioEngine (device following, channels, groups, taps) / AudioOutput (AUHAL, render-time health)
                AudioMixer (real-time render) / AudioChannel, ChannelDSP, ChannelSource / RingBuffer / AudioDeviceManager
                AudioProcessManager / DuckingController / BackendCapability / backends: VirtualDriverBackend,
                CoreAudioTapBackend (14.2+), DriverSharedMemory, RingResamplerSource
DSP/            Biquad, Equalizer (10-band + tone), Compressor, Reverb, Delay, Limiter
Recording/      WAVWriter, RecordingTrackWriter, RecordingEngine, RecordingLibrary, RecordingPlayer
DJ/             DJEngine + DJDeck (AVAudioEngine graph), BPMAnalyzer, BeatGrid, WaveformData, Crossfader
Library/        MusicLibrary, TrackMetadata, Playlist
Scenes/         MixerSnapshot, SceneManager, MixerHistory (undo/redo)
Settings/       AppSettings, LoginItem, AppLog, ConfigBackup
MenuBar/        MenuBarController
Views/          SwiftUI screens and custom controls (faders, knobs, meters, waveforms)
Driver/         MacAudioOoDriver.c (AudioServerPlugIn), MAOShared.h, selftest.c
```

## Real-time rules

The render callback (`AudioMixer.render`) allocates nothing and takes no locks. UI threads write parameters into fixed,
engine-owned memory (`AudioMixer.Storage`) that survives mixer restarts; render-owned fields (meters, smoothed gains) are never
overwritten from the UI. Gain changes are smoothed (10 ms). EQ coefficients are computed off the audio thread and swapped in by
flag. Recording and capture use single-producer/single-consumer ring buffers; file I/O happens on a background queue.

## Signal flow

capture (driver / process tap / test tone) -> ring -> per-channel EQ -> compressor -> [stem tap: dry, pre-fader] ->
volume/balance/mute/solo/group/duck -> sends -> reverb/delay returns -> master EQ -> master volume/DIM/MONO -> limiter ->
[mix tap] -> output device.

The DJ section is a separate AVAudioEngine (decks -> time-pitch -> EQ -> filter -> crossfader -> master) that plays through the
same output device as the mixer; its audio is not routed through the mixer.

## UI note

Deeply nested standard AppKit-backed controls (buttons, sliders, pop-ups) made SwiftUI layout take minutes on the DJ screen, so
that screen (and the Console) use lightweight custom controls (`PlainButton`, `ConsoleButton`, `LinearHSlider`, faders, knobs).

## Health

`AudioOutput` measures how much of each block's time the render callback uses; the status pill is green (keeping up), yellow
(blocks above 80 %) or orange (overloaded or not running).
