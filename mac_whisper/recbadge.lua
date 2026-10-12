-- Floating recording badge with a live level wave.
-- The wave is read from the tail of the wav ffmpeg is writing, so it shows what
-- is ACTUALLY being recorded, not what the OS thinks the mic is doing. After a
-- few seconds of no signal the badge turns amber and says "no sound".
local M = {}

local BARS, W, H = 32, 240, 40
local NO_SOUND_DB, NO_SOUND_SECS = -45, 4
local canvas, timer, levels, startedAt, quietSince, path, label

local function tailPeakDb(p)
  local f = io.open(p, "rb"); if not f then return nil end
  local size = f:seek("end")
  if size < 44 + 9600 then f:close(); return nil end
  local n = 4800                       -- ~25 ms of 48k stereo s16
  local pos = size - n; pos = pos - (pos % 2)
  f:seek("set", pos); local data = f:read(n); f:close()
  if not data then return nil end
  local sum, cnt = 0, 0
  -- Every 2nd stereo frame, BOTH channels: a mic that only feeds one side
  -- must not read as "no sound". (Assumes s16 stereo 48k, the format ffmpeg
  -- records from most Mac inputs; mono just samples twice as densely.)
  for i = 1, #data - 3, 8 do
    local l, r = string.unpack("<i2i2", data, i)
    sum = sum + math.max(l * l, r * r); cnt = cnt + 1
  end
  local rms = math.sqrt(sum / math.max(cnt, 1))
  if rms < 1 then return -120 end
  return 20 * math.log(rms / 32768, 10)
end

local function draw()
  local db = tailPeakDb(path) or -120
  -- Ease toward the new level: fast rise, slow fall, so it breathes instead of flickering.
  -- RMS speech sits around -40..-15 dB; map that span to the full bar height.
  local target = math.max(0, math.min(1, (db + 50) / 35)) ^ 0.8
  local prev = levels[BARS]
  local v = target > prev and target or math.max(target, prev * 0.7)  -- instant rise
  table.remove(levels, 1); table.insert(levels, v)
  local now = hs.timer.secondsSinceEpoch()
  if db > NO_SOUND_DB then quietSince = nil elseif not quietSince then quietSince = now end
  local dead = quietSince and (now - quietSince) >= NO_SOUND_SECS and (now - startedAt) >= NO_SOUND_SECS

  local el = math.floor(now - startedAt)
  canvas[1].fillColor = dead and {red=0.7, green=0.5, blue=0, alpha=0.7} or {white=0.08, alpha=0.72}
  canvas[2].text = string.format("%d:%02d", el // 60, el % 60)
  canvas[3].text = ""
  if dead then canvas[2].text = "no sound" end
  for i = 1, BARS do
    local h = math.max(3, levels[i] * 30)
    canvas[3 + i].frame = {x = 66 + (i - 1) * 5.2, y = (H - h) / 2, w = 3, h = h}
  end
end

function M.start(wavPath, micName)
  M.stop()
  path, label = wavPath, micName or "mic"
  levels = {}; for i = 1, BARS do levels[i] = 0 end
  startedAt = hs.timer.secondsSinceEpoch(); quietSince = nil
  local scr = hs.screen.mainScreen() or hs.screen.primaryScreen()
  if not scr then return end
  local sf = scr:frame()
  canvas = hs.canvas.new({x = sf.x + (sf.w - W) / 2, y = sf.y + sf.h - H - 14, w = W, h = H})
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({"canJoinAllSpaces", "stationary"})
  canvas[1] = {type = "rectangle", roundedRectRadii = {xRadius = 20, yRadius = 20}, action = "fill"}
  canvas[2] = {type = "text", frame = {x = 14, y = 12, w = 52, h = 16},
    textColor = {white = 1, alpha = 0.85}, textSize = 11, textFont = ".AppleSystemUIFontMonospaced-Regular"}
  canvas[3] = {type = "text", frame = {x = 52, y = 8, w = 50, h = 16},
    textColor = {white = 1, alpha = 0.9}, textSize = 10}
  for i = 1, BARS do
    -- older samples (left) fade out, newest (right) is brightest
    canvas[3 + i] = {type = "rectangle", action = "fill",
      fillColor = {white = 1, alpha = 0.25 + 0.65 * (i / BARS)},
      roundedRectRadii = {xRadius = 1.5, yRadius = 1.5}, frame = {x = 0, y = 0, w = 3, h = 3}}
  end
  draw(); canvas:show()
  timer = hs.timer.doEvery(0.04, draw)
end

function M.stop()
  if timer then timer:stop(); timer = nil end
  if canvas then canvas:delete(); canvas = nil end
end

return M
