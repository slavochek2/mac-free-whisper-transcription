-- Tests for mac_whisper/guards.lua. Run from the repo root: lua test/test_guards.lua
--
-- Every guard is tested on BOTH sides: inputs it must REJECT and inputs it must
-- ALLOW. A guard whose fixture contains only rejections has an unmeasured
-- false-positive rate: it can "correctly" block everything, including normal
-- recordings.

package.path = "./?.lua;./mac_whisper/?.lua;" .. package.path
local g = require("guards")

local pass, fail = 0, 0
local function check(name, got, want)
  if got == want then pass = pass + 1 else
    fail = fail + 1
    io.stderr:write(string.format("FAIL %s: got %s, want %s\n", name, tostring(got), tostring(want)))
  end
end

local root = "/Users/x/.cache/mac-whisper/dictation"
local dir  = root .. "/run.AbCdEfGh"

-- ── escapePattern ───────────────────────────────────────────────────────────
check("escapePattern: hyphenated root matches itself",
  dir:match("^" .. g.escapePattern(root)) ~= nil, true)
check("escapePattern: control — UNESCAPED hyphen does NOT match",
  dir:match("^" .. root) ~= nil, false)
check("escapePattern: does not match a different tree",
  ("/tmp/evil"):match("^" .. g.escapePattern(root)) ~= nil, false)

-- Table-driven over EVERY Lua pattern metacharacter. Without this, an
-- implementation that escapes only "-" would pass the whole suite.
for _, mc in ipairs({"^", "$", "(", ")", "%", ".", "[", "]", "*", "+", "-", "?"}) do
  local lit  = "/tmp/a" .. mc .. "b"
  check("escapePattern: literal '" .. mc .. "' matches itself",
    lit:match("^" .. g.escapePattern(lit) .. "$") ~= nil, true)
  -- "." is the one metachar that still matches its own literal, so skip its
  -- negative case; for the rest, a decoy differing only at that position must NOT match.
  if mc ~= "." then
    check("escapePattern: literal '" .. mc .. "' does not match a decoy",
      ("/tmp/aXb"):match("^" .. g.escapePattern(lit) .. "$") ~= nil, false)
  end
end

-- ── escapeERE ───────────────────────────────────────────────────────────────
check("escapeERE: dot is escaped", g.escapeERE("a.b"), "a\\.b")
check("escapeERE: hyphen stays literal (unlike Lua patterns)", g.escapeERE("a-b"), "a-b")
check("escapeERE: brace and pipe escaped", g.escapeERE("a{b|c}"), "a\\{b\\|c\\}")

-- ── shellQuote ──────────────────────────────────────────────────────────────
check("shellQuote: plain path", g.shellQuote("/tmp/a"), "'/tmp/a'")
check("shellQuote: dollar is inert inside single quotes", g.shellQuote("/tmp/$HOME"), "'/tmp/$HOME'")
check("shellQuote: backtick is inert", g.shellQuote("/tmp/`id`"), "'/tmp/`id`'")
check("shellQuote: embedded single quote is broken out and re-quoted",
  g.shellQuote("/tmp/it's"), "'/tmp/it'\\''s'")

-- ── shouldAbortAfterFfmpeg ──────────────────────────────────────────────────
-- ALLOW side: the normal stop path. ffmpeg is SIGTERMed and exits 255 while the
-- hotkey has already set state to "transcribing". MUST transcribe. Measured
-- Measured: `kill -TERM` on ffmpeg yields exit code 255.
check("normal stop (255, transcribing) -> transcribe", g.shouldAbortAfterFfmpeg(255, "transcribing"), false)
check("normal stop (143, transcribing) -> transcribe", g.shouldAbortAfterFfmpeg(143, "transcribing"), false)
check("clean exit (0, transcribing) -> transcribe",    g.shouldAbortAfterFfmpeg(0,   "transcribing"), false)
-- DELIBERATE, not an oversight: the hotkey's 1s `kill -9` fallback yields 137.
-- Partial audio beats no audio, and an unusable wav fails closed at the silence
-- guard downstream. Asserted so it cannot be silently "fixed".
check("hard kill on stop (137, transcribing) -> still transcribe, by design",
  g.shouldAbortAfterFfmpeg(137, "transcribing"), false)

-- REJECT side: ffmpeg died on its own while we still believed we were recording.
check("device failure (1, recording) -> abort",   g.shouldAbortAfterFfmpeg(1,   "recording"), true)
check("device failure (255, recording) -> abort", g.shouldAbortAfterFfmpeg(255, "recording"), true)
check("clean exit (0, recording) -> do not abort", g.shouldAbortAfterFfmpeg(0, "recording"), false)

-- ── runDirIsSafeToDelete ────────────────────────────────────────────────────
local yes = function(_) return true  end
local no  = function(_) return false end

check("transcribed run is deletable", g.runDirIsSafeToDelete(dir, root, yes), true)
check("ORPHAN run (wav, no txt) is NOT deletable", g.runDirIsSafeToDelete(dir, root, no), false)

-- Confinement. Each of these returns true against a naive prefix check.
check("traversal out of the cache tree is refused",
  g.runDirIsSafeToDelete(root .. "/run.good/../../../Documents", root, yes), false)
check("the root itself is refused",            g.runDirIsSafeToDelete(root, root, yes), false)
check("the root with a trailing slash is refused", g.runDirIsSafeToDelete(root .. "/", root, yes), false)
check("a nested path below a run dir is refused",
  g.runDirIsSafeToDelete(dir .. "/sub", root, yes), false)
check("a sibling tree sharing the prefix is refused",
  g.runDirIsSafeToDelete(root .. "-evil/run.AbCdEfGh", root, yes), false)
check("a non-mktemp basename is refused",
  g.runDirIsSafeToDelete(root .. "/Projects", root, yes), false)
check("a dotted basename is refused", g.runDirIsSafeToDelete(root .. "/..", root, yes), false)
check("dir outside the cache root is refused",
  g.runDirIsSafeToDelete("/Users/x/Projects", root, yes), false)

-- Degenerate inputs must fail closed, never throw.
check("nil dir is refused",   g.runDirIsSafeToDelete(nil, root, yes), false)
check("empty dir is refused", g.runDirIsSafeToDelete("", root, yes), false)
local okNilRoot = pcall(g.runDirIsSafeToDelete, dir, nil, yes)
check("nil root fails closed instead of throwing", okNilRoot, true)
check("nil root is refused", g.runDirIsSafeToDelete(dir, nil, yes), false)

-- ── isUnreportedOrphan ──────────────────────────────────────────────────────
local OLD, NEW = g.ORPHAN_GRACE_SECS + 1, g.ORPHAN_GRACE_SECS - 1

-- ALLOW side: the case the whole feature exists for — a reload killed a recorder,
-- audio is on disk, no transcript ever arrived, nobody has been told.
check("abandoned recording is announced",
  g.isUnreportedOrphan(true, true, false, false, OLD), true)

-- REJECT side, one per reason.
check("already announced -> silent (alarm must be clearable)",
  g.isUnreportedOrphan(true, true, false, true, OLD), false)
check("transcribed fine -> silent",
  g.isUnreportedOrphan(true, true, true, false, OLD), false)
check("no audio at all -> silent (nothing to recover)",
  g.isUnreportedOrphan(true, false, false, false, OLD), false)
check("not a directory (symlink/file) -> silent",
  g.isUnreportedOrphan(false, true, false, false, OLD), false)
check("audio still fresh -> silent (may be mid-transcription)",
  g.isUnreportedOrphan(true, true, false, false, NEW), false)
check("age exactly at the grace boundary -> silent",
  g.isUnreportedOrphan(true, true, false, false, g.ORPHAN_GRACE_SECS), false)

-- Degenerate inputs fail closed rather than throwing or defaulting to "announce".
check("nil age -> silent", g.isUnreportedOrphan(true, true, false, false, nil), false)
check("non-number age -> silent", g.isUnreportedOrphan(true, true, false, false, "old"), false)
check("nil isDir -> silent", g.isUnreportedOrphan(nil, true, false, false, OLD), false)
check("truthy-but-not-true isDir -> silent",
  g.isUnreportedOrphan("yes", true, false, false, OLD), false)

-- ── looksHallucinated ───────────────────────────────────────────────────────
check("halluc: 'I love you.' blocked", (g.looksHallucinated("I love you.", 120)), true)
check("halluc: 'Thank you.' over 30s blocked", (g.looksHallucinated("Thank you.", 30)), true)
check("halluc: deliberate short 'Okay.' allowed", (g.looksHallucinated("Okay.", 1)), false)
check("halluc: deliberate short 'Thanks!' allowed", (g.looksHallucinated("Thanks!", 0.8)), false)
check("halluc: halting 9 words in 20s allowed", (g.looksHallucinated("so um I think we should maybe fix that", 20)), false)
check("halluc: 3 words over 60s blocked", (g.looksHallucinated("so I think", 60)), true)
check("halluc: real 32s dictation allowed", (g.looksHallucinated(string.rep("word ", 60), 32)), false)
check("halluc: short real clip allowed", (g.looksHallucinated("1, 2, 3, 4, 5, works.", 2.7)), false)
check("halluc: sentence containing thank you allowed", (g.looksHallucinated("Thank you, now fix the bug please", 4)), false)

print(string.format("%d passed, %d failed", pass, fail))
os.exit(fail == 0 and 0 or 1)
