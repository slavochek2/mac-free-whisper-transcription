# mac-free-whisper-transcription

Free, private speech-to-text for your Mac. Press a hotkey, talk, press it again, and the text appears wherever your cursor is: email, Slack, a doc, a terminal. It can also record a whole call (your voice plus the other side) and save a transcript.

Everything runs **on your Mac**: no account, no subscription, and no audio sent anywhere. It uses OpenAI's open Whisper model through Apple's [MLX](https://github.com/ml-explore/mlx), driven by [Hammerspoon](https://www.hammerspoon.org/).

| Hotkey | What it does |
|---|---|
| **⌃⇧D** (Ctrl+Shift+D) | Dictation: press, speak, press again. The text is pasted at your cursor. |
| **⌃⇧C** (Ctrl+Shift+C) | Call recording: records your mic and system audio, then saves `~/Transcripts/<date>.md` with the transcript. Press again to stop. |

While you dictate, a small floating badge shows a live sound wave, so you can see the mic is actually hearing you. If it hears nothing for a few seconds it turns amber and says "no sound".

## Requirements

- A Mac with **Apple Silicon** (M1 or later). Intel Macs and other operating systems are not supported.
- [Homebrew](https://brew.sh)
- About 2 GB of disk space for the dictation model, plus about 3 GB more if you use call recording (it downloads a larger model on first use). Call recordings are kept as `.wav` files, roughly 10 MB per minute.

## Install

```bash
git clone https://github.com/slavochek2/mac-free-whisper-transcription.git
cd mac-free-whisper-transcription
./install.sh                # dictation only
./install.sh --with-calls   # dictation + call recording
```

The installer:
- installs Hammerspoon and ffmpeg with Homebrew
- installs mlx-whisper in its own Python environment (`~/.mac-whisper/venv`)
- copies the module to `~/.hammerspoon/mac_whisper/`
- adds one line to `~/.hammerspoon/init.lua`, leaving your existing Hammerspoon config alone
- downloads the Whisper model once

Then:
1. Open **Hammerspoon** and give it **Accessibility** permission (System Settings › Privacy & Security › Accessibility). It needs this to paste.
2. Hammerspoon menubar icon › **Reload Config**.
3. Press **⌃⇧D**, say something, press **⌃⇧D** again. The first time, macOS asks for **Microphone** access for Hammerspoon. Allow it, then try again.

The first transcription after a restart takes a few extra seconds while the model loads.

## Configuration

Pass options in `~/.hammerspoon/init.lua`, then Reload Config:

```lua
require("mac_whisper").setup({
  language  = "de",                              -- "en" (default), "de", "ru", ... or "auto"
  model     = "mlx-community/whisper-large-v3-turbo",  -- dictation model
  callModel = "mlx-community/whisper-large-v3-mlx",    -- call model (slower, more accurate)
  callsDir  = os.getenv("HOME") .. "/Transcripts",
  micName   = "AirPods",                         -- part of an input device name; default is the built-in mic
  dictationHotkey = {{"ctrl", "shift"}, "d"},
  callHotkey      = {{"ctrl", "shift"}, "c"},    -- set to false to disable
})
```

Smaller models are faster but less accurate: `whisper-small-mlx`, `whisper-medium-mlx`, or anything else from [mlx-community](https://huggingface.co/mlx-community?search_models=whisper).

Set a fixed `language` if you can. With `"auto"`, accented speech is sometimes "detected" as another language and transcribed as gibberish.

To list your input devices for `micName`:
```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

## Call recording

To capture the other side of a call this tool uses [BlackHole](https://github.com/ExistentialAudio/BlackHole), a virtual audio device. `./install.sh --with-calls` installs it, and then you do one manual step:

1. Open **Audio MIDI Setup** (in Applications › Utilities).
2. Click **+** at the bottom left › **Create Multi-Output Device**.
3. Tick **BlackHole 2ch** and your speakers or headphones. Leave its name as `Multi-Output Device`, or set `multiOutputDevice` in the config to match.

When you press ⌃⇧C, sound output switches to that device (if it can't, recording does not start) so the recorder hears the call. When you stop, output switches back to what it was. The recording mixes your mic with the call audio. The `.wav` and a `.md` transcript are saved to `callsDir`. Recording warns at 60 minutes and stops at 90 (`callWarnMinutes`, `callMaxMinutes`).

**Recording calls may require everyone's consent where you live. Ask first.**

## Safety features

Whisper never says "I heard nothing". On silence or hiss it makes up a confident phrase like "Thank you." or "I love you.", and a dictation tool would then type that into your chat. This tool guards against that:

- **Silence guard:** a recording with no signal at all is never transcribed.
- **Hallucination guard:** a stock phrase from a long recording, or far too few words for the length of the audio, is *not* pasted. The text goes on the clipboard instead, in case it was real.
- **Clipboard check:** the clipboard is checked right before ⌘V, so if the copy failed it never pastes what was there before (which could be a password).
- **Private scratch space:** audio and transcripts go in a fresh `0700` directory for each recording (`~/.cache/mac-whisper/`), never a fixed path in `/tmp` that another process could tamper with.
- **Right app only:** if focus has moved to a different app by the time the text is ready, it is not pasted; it stays on the clipboard.
- **No silent loss:** dictation audio is kept for 7 days. A recording that never got transcribed (for example because Hammerspoon reloaded) is never deleted automatically, and you're told about it shortly after the next startup. The original call `.wav` is never modified.

## Troubleshooting

- **Nothing happens on the hotkey:** open the Hammerspoon console (menubar icon › Console) and look for errors. Check Accessibility permission. Some apps (password prompts, terminals with "Secure Keyboard Entry") block global hotkeys; if one holds that lock for more than a minute, you get a notification naming the app.
- **"Missing tools" notification:** run `./install.sh` again.
- **Wrong microphone:** set `micName`.
- **Updating:** `git pull && ./install.sh`, then Reload Config.

## Uninstall

```bash
rm -rf ~/.hammerspoon/mac_whisper ~/.mac-whisper ~/.cache/mac-whisper
# remove the require("mac_whisper") line from ~/.hammerspoon/init.lua
# optional: brew uninstall --cask hammerspoon blackhole-2ch; brew uninstall ffmpeg switchaudio-osx
# the model cache is in ~/.cache/huggingface
```

## Development

The decisions that gate pasting and deleting live in `mac_whisper/guards.lua`, which is plain Lua with no Hammerspoon calls, so they can be tested without a mic:

```bash
lua test/test_guards.lua
```

## License

MIT, see [LICENSE](LICENSE). Hammerspoon, mlx-whisper and the Whisper weights are MIT-licensed. ffmpeg and BlackHole (GPL) are installed separately by Homebrew and not distributed here.
