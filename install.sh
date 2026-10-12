#!/usr/bin/env bash
# Installs mac-free-whisper-transcription.
#   ./install.sh               dictation only
#   ./install.sh --with-calls  also call recording (adds BlackHole + SwitchAudioSource)
set -euo pipefail

WITH_CALLS=0
[[ "${1:-}" == "--with-calls" ]] && WITH_CALLS=1

HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="$HOME/.mac-whisper/venv"
HS_DIR="$HOME/.hammerspoon"
MODEL="mlx-community/whisper-large-v3-turbo"

say() { printf '\n==> %s\n' "$*"; }

[[ "$(uname -s)" == "Darwin" ]] || { echo "macOS only."; exit 1; }
[[ "$(uname -m)" == "arm64" ]]  || { echo "Needs an Apple Silicon Mac (M1 or later): mlx-whisper runs on the Apple GPU."; exit 1; }
command -v brew >/dev/null || { echo "Homebrew is required: https://brew.sh"; exit 1; }

say "Installing Hammerspoon and ffmpeg (Homebrew)"
brew list --cask hammerspoon >/dev/null 2>&1 || brew install --cask hammerspoon
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg
if [[ $WITH_CALLS == 1 ]]; then
  say "Installing BlackHole 2ch and SwitchAudioSource (call recording)"
  brew list --cask blackhole-2ch >/dev/null 2>&1 || brew install --cask blackhole-2ch
  brew list switchaudio-osx >/dev/null 2>&1 || brew install switchaudio-osx
fi

say "Creating Python environment with mlx-whisper in $VENV"
PY="$(command -v python3.12 || command -v python3.11 || command -v python3 || true)"
[[ -n "$PY" ]] || { echo "python3 not found. Run: brew install python@3.12"; exit 1; }
"$PY" -m venv "$VENV"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet mlx-whisper

say "Installing the Hammerspoon module into $HS_DIR/mac_whisper"
mkdir -p "$HS_DIR"
rm -rf "$HS_DIR/mac_whisper"
cp -R "$HERE/mac_whisper" "$HS_DIR/mac_whisper"
touch "$HS_DIR/init.lua"
if ! grep -q 'require("mac_whisper")' "$HS_DIR/init.lua"; then
  printf '\n-- mac-free-whisper-transcription (options: see ~/.hammerspoon/mac_whisper/init.lua)\nrequire("mac_whisper").setup({})\n' >> "$HS_DIR/init.lua"
  echo "Added setup line to $HS_DIR/init.lua"
else
  echo "$HS_DIR/init.lua already loads mac_whisper; left as is."
fi

say "Downloading the Whisper model ($MODEL, ~1.6 GB, one time)"
TMP="$(mktemp -d)"
"$(brew --prefix)/bin/ffmpeg" -loglevel error -f lavfi -i "sine=frequency=440:duration=1" "$TMP/warmup.wav"
MODEL_OK=1
if ! "$VENV/bin/mlx_whisper" "$TMP/warmup.wav" --model "$MODEL" --output-dir "$TMP" >"$TMP/log" 2>&1; then
  MODEL_OK=0
  echo "WARNING: model download/test run failed. Last lines:"; tail -5 "$TMP/log"
  echo "Dictation will try to download it again on first use. Check your network and re-run ./install.sh."
fi
rm -rf "$TMP"

if [[ $MODEL_OK == 1 ]]; then say "Done. Remaining manual steps:"; else say "Installed, but the model step FAILED (see above). Remaining manual steps:"; fi
cat <<STEPS
  1. Open Hammerspoon (Applications). Grant it Accessibility when asked
     (System Settings > Privacy & Security > Accessibility), so it can paste.
  2. Click the Hammerspoon menubar icon > Reload Config.
  3. Press Ctrl+Shift+D, speak, press Ctrl+Shift+D again. On the first try macOS
     asks for Microphone access for Hammerspoon: allow it, then try again.
STEPS
if [[ $WITH_CALLS == 1 ]]; then
cat <<STEPS
  4. Call recording needs one Audio MIDI Setup step: see "Call recording" in README.md.
STEPS
fi
