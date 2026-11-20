# Installing MacAudioOo

## Choose the right installer

| Your macOS | Installer | What you get |
|---|---|---|
| 12 Monterey (or later, if you want the driver route) | `MacAudioOo-<version>-Monterey.dmg` | App + optional audio driver |
| 13 Ventura and later | `MacAudioOo-<version>-macOS13plus.dmg` | App with native capture, no driver |

Both are universal (Intel and Apple silicon).

## Install the app

1. Open the DMG and drag **MacAudioOo** into **Applications**.
2. First launch: if macOS says the developer cannot be verified (builds that are not yet notarized), right-click the app and
   choose **Open**, then confirm. Notarized builds open normally.
3. The app needs no account and never connects to the internet.

## macOS 14.2 and later (native capture)

macOS asks for audio-capture permission the first time MacAudioOo taps an application. Allow it in
System Settings > Privacy & Security if the prompt was dismissed. *(This path is written but has not yet been tested on real
hardware; see Documentation/TEST_RESULTS.md.)*

## macOS 12 - 14.1: the optional audio driver

Without the driver MacAudioOo still works as a mixer for its own sources (DJ decks, recording, test tones) but cannot capture
other applications. The driver is a standard macOS audio plug-in (no kernel extension).

1. In the Monterey DMG open **Audio Driver (optional)** and double-click **Install Audio Driver.command**.
2. Read what it prints. It asks for your administrator password, copies the driver to
   `/Library/Audio/Plug-Ins/HAL`, and asks before restarting the audio system (all audio pauses for a second or two).
3. In **System Settings > Sound > Output** choose **MacAudioOo Mixer**. MacAudioOo never changes this for you.
4. Open MacAudioOo (Settings > Audio shows the driver status). Applications that play to the system output now appear as channels.

Important behaviour: the driver itself makes no sound. **If MacAudioOo is not running, audio sent to "MacAudioOo Mixer" is
silent.** Choose your normal output again in Sound settings if you quit the app for good. Applications that let you pick their
own output device are only captured if you point them at "MacAudioOo Mixer". Hardware volume keys do not control the virtual
device; use MacAudioOo's master volume.

### Remove the driver

Double-click **Remove Audio Driver.command** (or run `sudo scripts/uninstall-driver.sh`), choose another output in Sound
settings first, and let it restart the audio system.

## Uninstall the app

Quit MacAudioOo, delete it from Applications. Optional leftovers: `~/Library/Application Support/MacAudioOo`
(scenes, library), `~/Library/Logs/MacAudioOo`, and `~/Library/LaunchAgents/com.unupunct.MacAudioOo.login.plist`
(only exists if you enabled *Launch at login*; switching the setting off removes it). Recordings stay where you saved them.

## Troubleshooting

- *"The driver is installed but not loaded"*: restart the audio system (`sudo killall coreaudiod`) or log out and in.
- *No applications appear*: check Settings > Audio (backend status) and that the system output is "MacAudioOo Mixer".
- *Crackling*: raise the buffer size in Settings > Audio; the status pill turns yellow/orange when the engine is struggling.
- *Display asleep, no sound from a remote session*: macOS can refuse to start audio hardware while the display is asleep.
