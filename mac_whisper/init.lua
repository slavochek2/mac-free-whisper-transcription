-- mac-free-whisper-transcription
--
-- Local, private speech-to-text for macOS, driven by Hammerspoon:
--   ⌃⇧D  dictation: press, speak, press again; the text is pasted at your cursor
--   ⌃⇧C  call recording: records your mic + system audio, saves a .md transcript
--
-- Everything runs on your Mac (ffmpeg + mlx-whisper). No audio leaves the machine.
--
-- Usage, in ~/.hammerspoon/init.lua:
--   require("mac_whisper").setup({})            -- defaults
--   require("mac_whisper").setup({language = "de", callsDir = os.getenv("HOME") .. "/Calls"})
-- All options are listed in DEFAULTS below.

local guards   = require("mac_whisper.guards")
local recbadge = require("mac_whisper.recbadge")

local M = {}
local HOME = os.getenv("HOME")

local DEFAULTS = {
  dictationHotkey = {{"ctrl", "shift"}, "d"},
  callHotkey      = {{"ctrl", "shift"}, "c"},
  -- Any mlx-community Whisper model works. Dictation favours speed, calls accuracy.
  model           = "mlx-community/whisper-large-v3-turbo",
  callModel       = "mlx-community/whisper-large-v3-mlx",
  -- ISO code ("en", "de", "ru", ...) or "auto". A fixed language is safer than auto:
  -- auto-detect on accented speech can hallucinate whole passages in a wrong language.
  language        = "en",
  callsDir        = HOME .. "/Transcripts",
  mlxWhisper      = HOME .. "/.mac-whisper/venv/bin/mlx_whisper",
  -- Substring of the input device name to record from (see `ffmpeg -f avfoundation
  -- -list_devices true -i ""`). nil = the built-in microphone, else the system default.
  micName         = nil,
  -- Call recording only: the Audio MIDI Setup device that sends sound to both your
  -- speakers/headphones and BlackHole. See the README.
  multiOutputDevice = "Multi-Output Device",
  callWarnMinutes = 60,
  callMaxMinutes  = 90,
}

local cfg
local ENV_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

local function which(cmd)
  local p = hs.execute("PATH=" .. ENV_PATH .. " /usr/bin/which " .. cmd .. " 2>/dev/null"):gsub("%s+$", "")
  return p ~= "" and p or nil
end

local FFMPEG, FFPROBE, SWITCH_CMD

local function newTask(path, callback, args)
  local t = hs.task.new(path, callback, args)
  t:setEnvironment({HOME = HOME, PATH = ENV_PATH, LANG = "en_US.UTF-8"})
  return t
end

local function notify(title, text)
  hs.notify.new({title = title, informativeText = text}):send()
end

-- ── Dictation scratch paths ─────────────────────────────────────────────────
--
-- The transcript is pasted with ⌘V into the frontmost app, so whoever controls the
-- transcript file controls keystrokes. A fixed path in /tmp can be raced or
-- symlinked by any process running as you. Instead every recording gets a fresh
-- mktemp directory under a 0700 parent: a path nobody else can name or pre-plant.
local RUN_ROOT = HOME .. "/.cache/mac-whisper/dictation"
local TMPFILE, TEXTFILE, RUN_DIR

-- Refuse to read anything that is not a regular file. symlinkAttributes does NOT
-- follow links, so a planted symlink reports mode "link" here.
local function safeToRead(path)
  local a = hs.fs.symlinkAttributes(path)
  if not a then return false, "missing" end
  if a.mode ~= "file" then return false, "not a regular file (" .. tostring(a.mode) .. ")" end
  return true
end

-- The contract guards.runDirIsSafeToDelete demands: an existing, NON-EMPTY,
-- REGULAR file. A crashed transcriber can leave a 0-byte file, which must not
-- authorise deleting the only copy of the audio.
local function transcriptIsRealFile(path)
  local a = hs.fs.symlinkAttributes(path)
  return a ~= nil and a.mode == "file" and (a.size or 0) > 0
end

-- Fresh 0700 dir per recording. Old runs are kept KEEP_RUN_SECS so any dictation
-- can be re-transcribed from its audio; runs that never produced a transcript,
-- or were rejected as hallucinated, are never deleted automatically.
local function newRunDir()
  hs.timer.doAfter(5, function()
    local now = os.time()
    local okIter, iter, dirObj, _, closer = pcall(hs.fs.dir, RUN_ROOT)
    if okIter and iter then for name in iter, dirObj, nil, closer do
      local d = RUN_ROOT .. "/" .. name
      local a = hs.fs.attributes(d)
      if a and a.mode == "directory" and (now - a.modification) > guards.KEEP_RUN_SECS
         and not hs.fs.attributes(d .. "/.rejected")
         and guards.runDirIsSafeToDelete(d, RUN_ROOT, transcriptIsRealFile) then
        hs.execute("/bin/rm -rf " .. guards.shellQuote(d))
      end
    end end
  end)
  hs.execute("/bin/mkdir -p " .. guards.shellQuote(RUN_ROOT) .. " && /bin/chmod 700 " .. guards.shellQuote(RUN_ROOT))
  local d = hs.execute("/usr/bin/mktemp -d " .. guards.shellQuote(RUN_ROOT .. "/run.XXXXXXXX")):gsub("%s+$", "")
  if d == "" then return false end
  RUN_DIR  = d
  -- mlx_whisper names its output after the input's basename: rec.wav -> rec.txt.
  TMPFILE  = RUN_DIR .. "/rec.wav"
  TEXTFILE = RUN_DIR .. "/rec.txt"
  return true
end

-- ── Report recordings that died without a transcript ────────────────────────
-- A Hammerspoon reload destroys the Lua state, so an in-flight recording's own
-- callback can never fire. Startup is where we notice. Each orphan is announced
-- once (a marker file in its dir), and the audio is never deleted.
local function reportOrphanRecordings()
  local fresh = {}
  local allOrphans, allBytes = 0, 0
  if not hs.fs.attributes(RUN_ROOT) then return end
  for entry in hs.fs.dir(RUN_ROOT) do
    if entry:match("^run%.") then
      local dir = RUN_ROOT .. "/" .. entry
      local dirAttr = hs.fs.symlinkAttributes(dir)
      local wavAttr = hs.fs.symlinkAttributes(dir .. "/rec.wav")
      local age = wavAttr and (os.time() - (wavAttr.modification or 0)) or nil
      local orphan = wavAttr and wavAttr.mode == "file" and not transcriptIsRealFile(dir .. "/rec.txt")
      if orphan then
        allOrphans = allOrphans + 1
        allBytes = allBytes + (wavAttr.size or 0)
      end
      if guards.isUnreportedOrphan(
           dirAttr ~= nil and dirAttr.mode == "directory",
           wavAttr ~= nil and wavAttr.mode == "file",
           transcriptIsRealFile(dir .. "/rec.txt"),
           hs.fs.symlinkAttributes(dir .. "/.reported") ~= nil,
           age) then
        -- Announce only if the marker was written, or it would re-announce forever.
        local f = io.open(dir .. "/.reported", "w")
        if f then
          f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\n")
          f:close()
          table.insert(fresh, {dir = dir, mtime = wavAttr.modification or 0})
        end
      end
    end
  end
  if #fresh == 0 then return end
  table.sort(fresh, function(a, b) return a.mtime > b.mtime end)
  local msg = string.format("%d new, %d total never transcribed (%.0f MB kept)",
    #fresh, allOrphans, allBytes / 1048576)
  -- hs.alert draws on screen even when notifications are silenced by Focus/DND.
  hs.alert.show("Whisper — " .. msg, 4)
  hs.notify.new({title = "Whisper — " .. msg, informativeText = fresh[1].dir, withdrawAfter = 0}):send()
end

-- ── State ───────────────────────────────────────────────────────────────────

local state        = "idle"  -- idle | recording | transcribing | done
local ffmpegTask   = nil
local doneTimer    = nil
local recordingApp = nil

local callState      = "idle"  -- idle | recording | transcribing
local callFfmpegTask = nil
local callTimerObj   = nil
local callStartTime  = nil
local callAudioFile  = nil
local savedOutput    = nil
local callWarnFired  = false
local stopCallRecording  -- forward declaration (used by the auto-stop timer)

-- ── Audio cues + menubar indicator ──────────────────────────────────────────

local function playSound(name)
  local s = hs.sound.getByName(name)
  if s then s:play() end
end

local recMenubar = nil

local function setMenubarTitle(title)
  if title then
    if not recMenubar then recMenubar = hs.menubar.new() end
    if recMenubar then recMenubar:setTitle(title) end
  else
    if recMenubar then recMenubar:delete(); recMenubar = nil end
  end
end

-- ── Dictation ───────────────────────────────────────────────────────────────

local function setState(newState)
  state = newState
  if newState ~= "recording" then recbadge.stop() end
  if doneTimer then doneTimer:stop(); doneTimer = nil end

  if newState == "recording" then
    playSound("Tink"); setMenubarTitle("🔴")
  elseif newState == "transcribing" then
    playSound("Pop"); setMenubarTitle("⏳")
  elseif newState == "done" then
    playSound("Glass"); setMenubarTitle("✓")
    doneTimer = hs.timer.doAfter(1.5, function()
      setMenubarTitle(nil)
      state = "idle"
    end)
  elseif newState == "idle" then
    setMenubarTitle(nil)
  end
end

-- A blind ⌘V pastes whatever was on the clipboard before if the write silently
-- failed (or a clipboard manager restored old contents), which could be a
-- password. So: verify the clipboard holds the transcript immediately before the
-- keystroke, and abort loudly rather than paste something unknown.
local function pasteResult()
  if not TEXTFILE then return false end
  local ok, why = safeToRead(TEXTFILE)
  if not ok then
    notify("Whisper — refusing to paste", "Transcript path is " .. why .. ". Nothing pasted.")
    recordingApp = nil
    return false
  end
  local file = io.open(TEXTFILE, "r")
  if not file then recordingApp = nil; return false end
  local content = file:read("*a"):gsub("%s+$", "")
  file:close()
  if content == "" then recordingApp = nil; return false end

  local dur = tonumber((hs.execute(string.format(
    "%s -v error -show_entries format=duration -of csv=p=0 %s",
    guards.shellQuote(FFPROBE), guards.shellQuote(TMPFILE))):gsub("%s+$", "")))
  local bad, reason = guards.looksHallucinated(content, dur)
  if bad then
    -- Mark so the cleanup never deletes it, and put the text on the clipboard
    -- (NOT pasted) so a real dictation blocked by mistake is one ⌘V away.
    local m = io.open(RUN_DIR .. "/.rejected", "w"); if m then m:write(reason); m:close() end
    hs.pasteboard.setContents(content)
    hs.notify.new({title = "Whisper — looks like a dead mic, NOT pasted",
      informativeText = reason .. ". Text is on the clipboard if it was real. Audio: " .. TMPFILE,
      withdrawAfter = 0}):send()
    recordingApp = nil
    return false
  end

  local wrote = hs.pasteboard.setContents(content)
  if not wrote or hs.pasteboard.getContents() ~= content then
    hs.timer.usleep(80000)
    hs.pasteboard.setContents(content)
  end
  if hs.pasteboard.getContents() ~= content then
    notify("Whisper", "Clipboard write failed — NOT pasting. Transcript: " .. TEXTFILE)
    recordingApp = nil
    return false
  end

  if recordingApp then
    local target = recordingApp
    recordingApp = nil
    target:activate()
    hs.timer.usleep(120000)  -- activate() is async; let focus settle
    -- Never type into an app the user did not dictate into: if focus did not land
    -- back on the original app, leave the text on the clipboard instead.
    local front = hs.application.frontmostApplication()
    if not front or front:pid() ~= target:pid() then
      notify("Whisper — NOT pasted", "Focus moved to another app. The text is on the clipboard.")
      return false
    end
  end

  -- Re-verify after activation: that window is where a clipboard manager's restore lands.
  if hs.pasteboard.getContents() ~= content then
    notify("Whisper", "Clipboard changed before paste — NOT pasting. Transcript: " .. TEXTFILE)
    return false
  end
  hs.eventtap.keyStroke({"cmd"}, "v")
end

-- ── Silence guard ───────────────────────────────────────────────────────────
-- Whisper does not error on silence; it hallucinates a short confident phrase
-- ("Thank you.") which would then be pasted as if it were speech. This gate is
-- narrow by design: it catches true digital silence (a dead or muted input).
-- Room tone from a live-but-unused mic passes it; guards.looksHallucinated is the
-- second line for that case. Fails closed: an unmeasurable level blocks.
local SILENCE_DBFS = -60.0

local function peakDbfs(path)
  local out = hs.execute(string.format(
    "%s -hide_banner -i %s -af volumedetect -f null - 2>&1 | grep max_volume",
    guards.shellQuote(FFMPEG), guards.shellQuote(path)))
  local db = out:match("max_volume:%s*(%-?[%d%.]+)%s*dB")
  return db and tonumber(db) or nil
end

local function whisperArgs(input, model, outDir)
  local args = {input, "--model", model, "--output-format", "txt", "--output-dir", outDir,
                "--condition-on-previous-text", "False"}
  if cfg.language ~= "auto" then
    table.insert(args, "--language")
    table.insert(args, cfg.language)
  end
  return args
end

local function runTranscription()
  local peak = peakDbfs(TMPFILE)
  if peak == nil then
    notify("Whisper — level unreadable", "Could not measure " .. TMPFILE .. ". Nothing pasted.")
    recordingApp = nil
    setState("idle")
    return
  end
  if peak < SILENCE_DBFS then
    notify("Whisper — digital silence", string.format(
      "Recording peaked at %.1f dBFS — no signal at all. Nothing pasted.", peak))
    recordingApp = nil
    setState("idle")
    return
  end

  local task = newTask(cfg.mlxWhisper, function(exitCode, _, _)
    if exitCode == 0 then
      if pasteResult() == false then setState("idle") else setState("done") end
    else
      notify("Whisper", "Transcription failed (audio kept in " .. tostring(RUN_DIR) .. ")")
      setState("idle")
    end
  end, whisperArgs(TMPFILE, cfg.model, RUN_DIR))
  if not task:start() then
    notify("Whisper", "Could not launch " .. cfg.mlxWhisper .. ". Audio kept in " .. tostring(RUN_DIR))
    recordingApp = nil
    setState("idle")
  end
end

-- ── Audio devices ───────────────────────────────────────────────────────────

-- Returns {mic = index-or-"default", micName = ..., blackhole = index-or-nil}.
local function getAudioDevices()
  local output = hs.execute(guards.shellQuote(FFMPEG) .. " -f avfoundation -list_devices true -i '' 2>&1")
  local inAudio = false
  local result = {}
  for line in output:gmatch("[^\n]+") do
    if line:find("AVFoundation audio devices") then
      inAudio = true
    elseif inAudio then
      local idx, name = line:match("%[(%d+)%]%s*(.-)%s*$")
      if idx then
        local lower = name:lower()
        if lower:find("blackhole") then
          result.blackhole = idx
        elseif cfg.micName then
          if not result.mic and lower:find(cfg.micName:lower(), 1, true) then
            result.mic, result.micName = idx, name
          end
        elseif not result.mic and (lower:find("microphone") or lower:find("built%-in")) then
          result.mic, result.micName = idx, name
        end
      end
    end
  end
  if not result.mic then result.mic, result.micName = "default", "default input" end
  return result
end

-- ── Dictation hotkey ────────────────────────────────────────────────────────

function M.toggleDictation()
  if state == "transcribing" then return end

  if state == "idle" or state == "done" then
    recordingApp = hs.application.frontmostApplication()
    setState("recording")

    -- A fresh, empty run directory per recording means a stale wav or transcript
    -- from a previous run can never be re-pasted.
    if not newRunDir() then
      notify("Whisper — cannot start", "Could not create a private scratch directory under " .. RUN_ROOT)
      recordingApp = nil
      setState("idle")
      return
    end

    local dev = getAudioDevices()

    ffmpegTask = newTask(FFMPEG, function(exitCode, _, _)
      ffmpegTask = nil
      -- exitCode MUST gate transcription: when the input device fails to open,
      -- transcribing would measure and paste a recording that does not exist.
      if guards.shouldAbortAfterFfmpeg(exitCode, state) then
        notify("Whisper — recording failed", string.format(
          "ffmpeg exited %d while still recording (mic/device unavailable). " ..
          "Audio kept in %s. Nothing pasted.", exitCode, tostring(RUN_DIR)))
        recordingApp = nil
        setState("idle")
        return
      end
      if state == "transcribing" then
        runTranscription()
      elseif state == "recording" then
        notify("Whisper", "Recording stopped unexpectedly")
        setState("idle")
      end
    end, {"-f", "avfoundation", "-i", ":" .. dev.mic, "-flush_packets", "1", "-y", TMPFILE})

    if ffmpegTask:start() then
      recbadge.start(TMPFILE, dev.micName)
    else
      notify("Whisper", "ffmpeg failed to start — check microphone permission for Hammerspoon")
      ffmpegTask = nil
      setState("idle")
    end

  elseif state == "recording" then
    setState("transcribing")
    if ffmpegTask then
      ffmpegTask:terminate()
      -- ffmpeg sometimes ignores SIGTERM; force-kill after 1s
      hs.timer.doAfter(1, function()
        if ffmpegTask and ffmpegTask:isRunning() then
          hs.execute("kill -9 " .. tostring(ffmpegTask:pid()))
        end
      end)
    end
  end
end

-- ── Call recording ──────────────────────────────────────────────────────────

local function switchAudio(deviceName)
  if SWITCH_CMD then
    hs.execute(guards.shellQuote(SWITCH_CMD) .. " -s " .. guards.shellQuote(deviceName) .. " -t output 2>/dev/null")
  end
end

local function getCurrentOutput()
  if not SWITCH_CMD then return nil end
  local out = hs.execute(guards.shellQuote(SWITCH_CMD) .. " -c -t output 2>/dev/null"):gsub("%s+$", "")
  return (out ~= "") and out or nil
end

local function formatDuration(secs)
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

local function finishCall(msg)
  if msg then notify("Call Recording", msg) end
  setMenubarTitle(nil)
  callState = "idle"
end

local function saveCallTranscript(transcript, durationSecs, audioFile)
  local mdFile = audioFile:match("(.+)%.wav$") .. ".md"
  local f = io.open(mdFile, "w")
  if not f then return nil end
  f:write(string.format(
    "---\ndate: %s\nstarted_at: %s\nduration_min: %d\naudio_file: %s\nmodel: %s\nlanguage: %s\n---\n\n%s\n",
    os.date("%Y-%m-%d", callStartTime),
    os.date("%Y-%m-%dT%H:%M:%S", callStartTime),
    math.floor(durationSecs / 60 + 0.5),
    audioFile:match("[^/]+$"),
    cfg.callModel,
    cfg.language,
    transcript))
  f:close()
  return mdFile
end

local function startWhisperOnFile(audioFile, durationSecs, recordingFile)
  -- audioFile is what gets transcribed (possibly a trimmed copy); recordingFile is
  -- the untouched original the transcript is saved next to.
  recordingFile = recordingFile or audioFile
  -- Same silence guard as dictation: a silent call would otherwise produce a
  -- hallucinated transcript that looks like a record of a real conversation.
  local peak = peakDbfs(audioFile)
  if peak == nil or peak < SILENCE_DBFS then
    finishCall(string.format("%s NOT transcribed — %s. Audio kept.",
      recordingFile:match("[^/]+$"),
      peak and string.format("peaked at %.1f dBFS, no signal", peak) or "level unreadable"))
    return
  end

  local txtFile = cfg.callsDir .. "/" .. audioFile:match("([^/]+)%.wav$") .. ".txt"
  local task = newTask(cfg.mlxWhisper, function(exitCode, _, _)
    if audioFile ~= recordingFile then os.remove(audioFile) end
    if exitCode ~= 0 then return finishCall("Transcription failed. Audio kept: " .. recordingFile) end
    local f = io.open(txtFile, "r")
    if not f then return finishCall("Transcript file missing: " .. txtFile) end
    local transcript = f:read("*a"):gsub("%s+$", "")
    f:close()
    local mdFile = saveCallTranscript(transcript, durationSecs, recordingFile)
    if not mdFile then return finishCall("Failed to write transcript next to " .. recordingFile) end
    os.remove(txtFile)  -- the .md carries the same text plus metadata
    playSound("Glass"); setMenubarTitle("✓")
    hs.timer.doAfter(3.0, function() finishCall(nil) end)
    hs.notify.new({title = "Call saved", informativeText = mdFile}):send()
  end, whisperArgs(audioFile, cfg.callModel, cfg.callsDir))
  if not task:start() then
    if audioFile ~= recordingFile then os.remove(audioFile) end
    finishCall("Could not launch " .. cfg.mlxWhisper .. ". Audio kept: " .. recordingFile)
  end
end

local function runCallTranscription(durationSecs)
  playSound("Pop"); setMenubarTitle("⏳")

  -- Whisper can stall on a long silent tail (a call left recording after hang-up),
  -- so a TRAILING silence of 10s+ is cut from a copy before transcription. Only a
  -- silence that runs to the end of the file counts: a quiet stretch mid-call is
  -- followed by speech and must not be cut. The original .wav is never modified.
  local original = callAudioFile
  local trimmedFile = original:gsub("%.wav$", "_trimmed.wav")
  local probe = newTask("/bin/bash", function(exitCode, stdout, _)
    local total = tonumber((stdout:match("DURATION=([%d%.]+)")))
    local lastStart, lastEnd
    for kind, t in stdout:gmatch("silence_(%a+): ([%d%.]+)") do
      if kind == "start" then lastStart, lastEnd = tonumber(t), nil
      elseif kind == "end" then lastEnd = tonumber(t) end
    end
    local trailing = exitCode == 0 and total and lastStart and lastStart > 10
      and (lastEnd == nil or lastEnd >= total - 0.5)
    if not trailing then return startWhisperOnFile(original, durationSecs) end
    local ff = newTask(FFMPEG, function(ffExit, _, _)
      if ffExit == 0 then
        startWhisperOnFile(trimmedFile, durationSecs, original)
      else
        os.remove(trimmedFile)
        startWhisperOnFile(original, durationSecs)
      end
    end, {"-i", original, "-t", tostring(lastStart + 2), "-c", "copy", "-y", trimmedFile})
    if not ff:start() then startWhisperOnFile(original, durationSecs) end
  end, {"-c", "echo DURATION=$(" .. guards.shellQuote(FFPROBE) ..
    " -v error -show_entries format=duration -of csv=p=0 " .. guards.shellQuote(original) .. "); " ..
    guards.shellQuote(FFMPEG) .. " -i " .. guards.shellQuote(original) ..
    " -af silencedetect=noise=-30dB:d=10 -f null - 2>&1 | grep -E 'silence_(start|end)'"})
  if not probe:start() then startWhisperOnFile(original, durationSecs) end
end

local function startCallRecording()
  hs.execute("/bin/mkdir -p " .. guards.shellQuote(cfg.callsDir))
  if hs.fs.attributes(cfg.callsDir, "mode") ~= "directory" then
    return notify("Call Recording NOT started", "Cannot create " .. cfg.callsDir)
  end
  local dev = getAudioDevices()
  if not SWITCH_CMD then
    return notify("Call Recording NOT started",
      "SwitchAudioSource not found. Run ./install.sh --with-calls.")
  end
  if not dev.blackhole then
    return notify("Call Recording NOT started",
      "BlackHole 2ch not found. Run ./install.sh --with-calls, then see the README for the Multi-Output Device step.")
  end

  savedOutput = getCurrentOutput()
  switchAudio(cfg.multiOutputDevice)
  -- Without the switch the recorder hears only your mic, which looks like a
  -- successful recording until you read the transcript. Refuse instead.
  if getCurrentOutput() ~= cfg.multiOutputDevice then
    if savedOutput then switchAudio(savedOutput); savedOutput = nil end
    return notify("Call Recording NOT started", string.format(
      "Could not switch sound output to %q. Create it in Audio MIDI Setup (see README).",
      cfg.multiOutputDevice))
  end

  callAudioFile = cfg.callsDir .. "/" .. os.date("%Y-%m-%d_%H%M%S") .. ".wav"
  callStartTime = os.time()
  callState = "recording"
  playSound("Blow"); setMenubarTitle("🔵 0:00")

  callWarnFired = false
  callTimerObj = hs.timer.doEvery(1, function()
    if callState ~= "recording" then return end
    local elapsed = os.time() - callStartTime
    setMenubarTitle("🔵 " .. formatDuration(elapsed))
    if elapsed >= cfg.callWarnMinutes * 60 and not callWarnFired then
      callWarnFired = true
      playSound("Sosumi")
      notify("Call Recording — " .. cfg.callWarnMinutes .. " min",
        string.format("Auto-stop at %d min. Press the call hotkey to stop now.", cfg.callMaxMinutes))
    end
    if elapsed >= cfg.callMaxMinutes * 60 then
      notify("Call Recording — auto-stopped", cfg.callMaxMinutes .. " min limit reached. Transcribing now.")
      stopCallRecording()
    end
  end)

  callFfmpegTask = newTask(FFMPEG, function(_, _, _)
    callFfmpegTask = nil
    if savedOutput then switchAudio(savedOutput); savedOutput = nil end
    if callState == "transcribing" then
      runCallTranscription(os.time() - callStartTime)
    elseif callState == "recording" then
      if callTimerObj then callTimerObj:stop(); callTimerObj = nil end
      finishCall("Recording stopped unexpectedly. Audio kept: " .. callAudioFile)
    end
  end, {
    "-f", "avfoundation", "-i", ":" .. dev.mic,
    "-f", "avfoundation", "-i", ":" .. dev.blackhole,
    "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest",
    "-y", callAudioFile,
  })

  if not callFfmpegTask:start() then
    if savedOutput then switchAudio(savedOutput); savedOutput = nil end
    if callTimerObj then callTimerObj:stop(); callTimerObj = nil end
    finishCall("ffmpeg failed to start — check microphone permission for Hammerspoon")
  end
end

stopCallRecording = function()
  callState = "transcribing"
  if callTimerObj then callTimerObj:stop(); callTimerObj = nil end
  if callFfmpegTask then
    callFfmpegTask:terminate()
    hs.timer.doAfter(1, function()
      if callFfmpegTask and callFfmpegTask:isRunning() then
        hs.execute("kill -9 " .. tostring(callFfmpegTask:pid()))
      end
    end)
  end
end

function M.toggleCall()
  if callState == "idle" then startCallRecording()
  elseif callState == "recording" then stopCallRecording() end
end

-- ── Secure-input watchdog ───────────────────────────────────────────────────
-- While any app holds macOS Secure Input (password fields, some terminals), global
-- hotkeys never arrive, so dictation fails with no signal. Warn once when it has
-- been held for over 60s, naming the app holding it.
local function startSecureInputWatchdog()
  local since, warned = nil, false
  M._secureInputTimer = hs.timer.doEvery(30, function()
    if not hs.eventtap.isSecureInputEnabled() then
      since, warned = nil, false
      return
    end
    since = since or os.time()
    if warned or os.time() - since < 60 then return end
    warned = true
    local pid = hs.execute("ioreg -l -w 0 | grep -o '\"kCGSSessionSecureInputPID\"=[0-9]*' | head -1 | cut -d= -f2"):gsub("%s+$", "")
    local app = pid ~= "" and hs.application.applicationForPID(tonumber(pid))
    local name = app and app:name() or ("PID " .. (pid ~= "" and pid or "?"))
    notify("Dictation blocked by " .. name,
      "Secure Keyboard Entry is stuck on, so hotkeys may not work. Quit and reopen " .. name .. ".")
  end)
end

-- ── Setup ───────────────────────────────────────────────────────────────────

function M.setup(opts)
  cfg = {}
  for k, v in pairs(DEFAULTS) do cfg[k] = v end
  for k, v in pairs(opts or {}) do
    if DEFAULTS[k] == nil and k ~= "micName" then
      hs.printf("mac_whisper: unknown option %q ignored", tostring(k))
    end
    cfg[k] = v
  end

  FFMPEG     = which("ffmpeg")
  FFPROBE    = which("ffprobe")
  SWITCH_CMD = which("SwitchAudioSource")

  local missing = {}
  if not FFMPEG then table.insert(missing, "ffmpeg") end
  if not FFPROBE then table.insert(missing, "ffprobe") end
  if not hs.fs.attributes(cfg.mlxWhisper) then table.insert(missing, "mlx_whisper (" .. cfg.mlxWhisper .. ")") end
  if #missing > 0 then
    notify("Whisper — missing tools", table.concat(missing, ", ") .. "\nRun ./install.sh from the repo.")
    return M
  end

  -- A reload loses the handle to a running recorder; kill it so state starts clean.
  hs.execute("/usr/bin/pkill -9 -f " ..
    guards.shellQuote(guards.escapeERE(RUN_ROOT) .. "/run\\..*/rec\\.wav") .. " 2>/dev/null")

  M._dictKey = hs.hotkey.bind(cfg.dictationHotkey[1], cfg.dictationHotkey[2], M.toggleDictation)
  if cfg.callHotkey then
    M._callKey = hs.hotkey.bind(cfg.callHotkey[1], cfg.callHotkey[2], M.toggleCall)
  end
  startSecureInputWatchdog()

  -- Last, and inside pcall: a failure in a notification must not cost the hotkeys.
  local ok, err = pcall(reportOrphanRecordings)
  if not ok then hs.printf("mac_whisper: orphan report failed (non-fatal): %s", tostring(err)) end
  -- Recordings younger than the grace period are skipped above (they may still be
  -- transcribing), so look again once they are old enough.
  M._orphanRecheck = hs.timer.doAfter(guards.ORPHAN_GRACE_SECS + 10, function()
    pcall(reportOrphanRecordings)
  end)
  return M
end

return M
