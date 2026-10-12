-- Pure predicates for the dictation / call pipeline.
--
-- No Hammerspoon API may be used in this file. These are the decisions that gate
-- whether audio gets transcribed, pasted or deleted, so they must be runnable
-- without a mic or Hammerspoon itself, and both their accept and reject paths
-- are tested. Run:  lua test/test_guards.lua

local M = {}

-- ── Escaping ────────────────────────────────────────────────────────────────

-- Escape a literal string for use inside a Lua PATTERN. In Lua patterns "-" is
-- the lazy quantifier, so a path such as ".../mac-whisper" interpolated
-- unescaped silently never matches.
function M.escapePattern(s)
  return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Escape a literal string for use inside a POSIX extended regex (pkill -f).
-- A different metacharacter set: "-" is literal here, but "{}|\" are not.
function M.escapeERE(s)
  return (s:gsub("([%^%$%.%[%]%*%+%?%(%)%{%}%|\\])", "\\%1"))
end

-- Quote a literal string for /bin/sh. Lua's %q quotes for the Lua parser (double
-- quotes, inside which sh still expands $ and backticks); single quotes are the
-- only sh construct with no interior expansion.
function M.shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- ── ffmpeg exit decision ────────────────────────────────────────────────────

-- Should the ffmpeg exit callback abort instead of transcribing?
--
-- ffmpeg exits 255 on the SIGTERM a normal stop sends, so a non-zero exit alone
-- means nothing. On a normal stop the hotkey has already moved state to
-- "transcribing"; a non-zero exit while state is still "recording" is a device
-- failure. A hard kill during stop (137) deliberately still transcribes: partial
-- text beats discarding audio, and an unusable wav fails closed at the silence
-- guard one step later.
function M.shouldAbortAfterFfmpeg(exitCode, state)
  return exitCode ~= 0 and state == "recording"
end

-- ── Run-directory deletion ──────────────────────────────────────────────────

-- The exact shape mktemp produces for RUN_ROOT/run.XXXXXXXX. Matching the whole
-- remainder against ONE component makes this a real confinement boundary rather
-- than a string prefix: "run.good/../../x" contains "/" and cannot match.
local RUN_DIR_COMPONENT = "^run%.[A-Za-z0-9]+$"

-- Is this run directory safe to `rm -rf`? Only once its audio has produced a
-- transcript: a wav with no transcript is the only copy of that audio.
--
-- `transcriptIsRealFile` is injected. Contract: true only for an existing,
-- non-empty, REGULAR file (a crashed transcriber can leave a 0-byte file).
function M.runDirIsSafeToDelete(runDir, runRoot, transcriptIsRealFile)
  if type(runDir) ~= "string" or runDir == "" then return false end
  if type(runRoot) ~= "string" or runRoot == "" then return false end

  local rest = runDir:match("^" .. M.escapePattern(runRoot) .. "/(.*)$")
  if not rest then return false end
  if not rest:match(RUN_DIR_COMPONENT) then return false end

  return transcriptIsRealFile(runDir .. "/rec.txt") == true
end

-- ── Orphan reporting ────────────────────────────────────────────────────────

-- How old the audio must be before a run dir counts as abandoned, so a reload
-- that lands while Whisper is still working does not raise a false alarm.
M.ORPHAN_GRACE_SECS = 90

-- Should this run directory be announced as a recording that never transcribed?
-- Inputs are plain booleans/numbers; the caller does the (symlink-safe) file work.
function M.isUnreportedOrphan(isDir, hasWav, transcriptOk, hasMarker, wavAgeSecs)
  if isDir ~= true then return false end
  if hasWav ~= true then return false end
  if transcriptOk == true then return false end
  if hasMarker == true then return false end
  if type(wavAgeSecs) ~= "number" then return false end
  return wavAgeSecs > M.ORPHAN_GRACE_SECS
end

-- ── Hallucination check ─────────────────────────────────────────────────────
-- A live-but-dead mic (wireless mic off or out of range) records hiss above the
-- silence gate, and Whisper answers hiss with a short stock phrase. Two signals,
-- either blocks: a known stock phrase, or far too few words for the audio length.
M.STOCK_PHRASES = {
  "thank you", "thanks", "thank you very much", "thanks for watching",
  "thank you for watching", "i love you", "bye", "you", "okay", "ok",
  "please subscribe", "subtitles by the amara.org community",
}
M.MIN_WORDS_PER_SEC = 0.25  -- normal speech ~2-3 w/s; halting thinking-aloud can dip near 0.5
M.RATE_CHECK_MIN_SECS = 10  -- short clips legitimately carry few words
M.PHRASE_CHECK_MIN_SECS = 4 -- a real "ok"/"thanks" reply is a short press; a dead-mic run is not

function M.looksHallucinated(text, durationSecs)
  if type(text) ~= "string" then return true, "no text" end
  local norm = text:lower():gsub("[%p]", ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  for _, p in ipairs(M.STOCK_PHRASES) do
    if norm == p and type(durationSecs) == "number" and durationSecs >= M.PHRASE_CHECK_MIN_SECS then return true, "stock phrase \"" .. text .. "\"" end
  end
  local words = select(2, norm:gsub("%S+", ""))
  if type(durationSecs) == "number" and durationSecs >= M.RATE_CHECK_MIN_SECS
     and words / durationSecs < M.MIN_WORDS_PER_SEC then
    return true, string.format("%d words for %.0fs of audio", words, durationSecs)
  end
  return false
end

-- Keep dictation run dirs for this long so any transcript can be redone from its audio.
M.KEEP_RUN_SECS = 7 * 24 * 3600

return M
