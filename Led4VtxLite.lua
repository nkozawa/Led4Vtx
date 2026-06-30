-- Led4VtxLite.lua
-- led4vtxlite.fav の全エントリをカラーブロックとして表示し、
-- タッチ or ダイヤルで選択 → LED色とVTXチャネルを機体に送信する。
-- 画面での登録・削除はなし (Led4Vtx.luaのお気に入り画面相当)。
--
-- led4vtxlite.fav フォーマット (各行 1エントリ):
--   VTXch,H,S,V
--   例: E2,0,0,255     (VTX=E2, H=0=Red)
--       E1,120,0,255   (VTX=E1, H=120=Green)
--       ,60,0,255      (VTXなし, H=60=Yellow)

-- MSPでLEDを制御し、VTXはELRS VTX Admin経由で切り替えます。
--
-- =====================================
-- MSP over CRSF
-- =====================================
local MSP_VERSION   = bit32.lshift(1, 5)
local MSP_STARTFLAG = bit32.lshift(1, 4)

local mspSeq       = 0
local mspRemoteSeq = 0
local mspRxBuf     = {}
local mspRxSize    = 0
local mspRxCRC     = 0
local mspRxReq     = 0
local mspStarted   = false
local mspLastReq   = 0
local mspTxBuf     = {}
local mspTxIdx     = 1
local mspTxCRC     = 0

local maxTxBufferSize = 8
local maxRxBufferSize = 58

local CRSF_ADDRESS_BETAFLIGHT        = 0xC8
local CRSF_ADDRESS_RADIO_TRANSMITTER = 0xEA
local CRSF_FRAMETYPE_MSP_REQ         = 0x7A
local CRSF_FRAMETYPE_MSP_RESP        = 0x7B
local CRSF_FRAMETYPE_MSP_WRITE       = 0x7C

local CRSF_ADDR_MODULE = 0xEE
local CRSF_ADDR_LUA    = 0xEF
local CRSF_ADDR_RADIO  = 0xEA

local CMD_PING        = 0x28
local CMD_DEVICE_INFO = 0x29
local CMD_PARAM_RESP  = 0x2B
local CMD_PARAM_READ  = 0x2C
local CMD_PARAM_WRITE = 0x2D

local TYPE_UINT8    = 0
local TYPE_TEXT_SEL = 9
local TYPE_FOLDER   = 11
local TYPE_COMMAND  = 13

local LCS_START     = 1
local LCS_CONFIRMED = 4

local crsfMspCmd = 0
local BAND_VALUES = { A=1, B=2, E=3, F=4, R=5 }

local VtxState = {
  IDLE         = 0,
  PINGING      = 1,
  ENUMERATING  = 2,
  READY        = 3,
  WRITING_BAND = 4,
  WRITING_CHAN = 5,
  WRITING_SEND = 6,
  CONFIRMING   = 7,
  ERROR        = 8,
}

local vtx = {
  state = VtxState.IDLE,
  deviceId = CRSF_ADDR_MODULE,
  handsetId = CRSF_ADDR_LUA,
  fieldCount = 0,
  fields = {},
  loadIdx = 0,
  chunkBuf = {},
  chunkIdx = 0,

  vtxFolderId = nil,
  bandFieldId = nil,
  channelFieldId = nil,
  sendFieldId = nil,

  currentBand = nil,
  currentChannel = nil,
  pendingBand = nil,
  pendingChannel = nil,

  timer = 0,
  retryCount = 0,
}

local VTX_TIMEOUT_PING  = 20
local VTX_TIMEOUT_ENUM  = 100
local VTX_TIMEOUT_WRITE = 15
local VTX_TIMEOUT_SEND  = 20
local VTX_RETRY_MAX     = 10

local function mspSend(payload)
  local payloadOut = { CRSF_ADDRESS_BETAFLIGHT, CRSF_ADDRESS_RADIO_TRANSMITTER }
  for i = 1, #payload do payloadOut[i + 2] = payload[i] end
  return crossfireTelemetryPush(crsfMspCmd, payloadOut)
end

local function mspProcessTxQ()
  if #mspTxBuf == 0 then return false end
  if not crossfireTelemetryPush() then return true end

  local payload = {}
  payload[1] = mspSeq + MSP_VERSION
  mspSeq = bit32.band(mspSeq + 1, 0x0F)
  if mspTxIdx == 1 then payload[1] = payload[1] + MSP_STARTFLAG end

  local i = 2
  while i <= maxTxBufferSize and mspTxIdx <= #mspTxBuf do
    payload[i] = mspTxBuf[mspTxIdx]
    mspTxIdx   = mspTxIdx + 1
    mspTxCRC   = bit32.bxor(mspTxCRC, payload[i])
    i = i + 1
  end

  if i <= maxTxBufferSize then
    payload[i] = mspTxCRC
    mspSend(payload)
    mspTxBuf = {}; mspTxIdx = 1; mspTxCRC = 0
    return false
  end

  mspSend(payload)
  return true
end

local function mspSendRequest(cmd, payload)
  if #mspTxBuf ~= 0 or not cmd then return nil end
  mspTxBuf[1] = #payload
  mspTxBuf[2] = bit32.band(cmd, 0xFF)
  for i = 1, #payload do mspTxBuf[i + 2] = bit32.band(payload[i], 0xFF) end
  mspLastReq = cmd
  return mspProcessTxQ()
end

local function mspReceivedReply(payload)
  local idx     = 1
  local status  = payload[idx]
  local err     = bit32.btest(status, 0x80)
  local version = bit32.rshift(bit32.band(status, 0x60), 5)
  local start   = bit32.btest(status, 0x10)
  local seq     = bit32.band(status, 0x0F)
  idx = idx + 1

  if err then mspStarted = false; return nil end

  if start then
    mspRxBuf  = {}
    mspRxSize = payload[idx]; mspRxReq = mspLastReq
    idx = idx + 1
    if version == 1 then mspRxReq = payload[idx]; idx = idx + 1 end
    mspRxCRC = bit32.bxor(mspRxSize, mspRxReq)
    if mspRxReq == mspLastReq then mspStarted = true end
  elseif not mspStarted then
    return nil
  elseif bit32.band(mspRemoteSeq + 1, 0x0F) ~= seq then
    mspStarted = false; return nil
  end

  while idx <= maxRxBufferSize and #mspRxBuf < mspRxSize do
    mspRxBuf[#mspRxBuf + 1] = payload[idx]
    mspRxCRC = bit32.bxor(mspRxCRC, payload[idx])
    idx = idx + 1
  end

  if idx > maxRxBufferSize then mspRemoteSeq = seq; return true end
  mspStarted = false
  if mspRxCRC ~= payload[idx] and version == 0 then return nil end
  return mspRxBuf
end

local function mspRead(cmd)
  crsfMspCmd = CRSF_FRAMETYPE_MSP_REQ
  return mspSendRequest(cmd, {})
end

local function mspWrite(cmd, payload)
  crsfMspCmd = CRSF_FRAMETYPE_MSP_WRITE
  return mspSendRequest(cmd, payload)
end

local function vtxFieldGetString(data, offset)
  local s = ""
  local i = offset
  while data[i] and data[i] ~= 0 do
    s = s .. string.char(data[i])
    i = i + 1
  end
  return s, i + 1
end

local function vtxSetCurrentFromDynName(dynName)
  if type(dynName) ~= "string" then return end
  local band, channel = string.match(dynName, "%((%a):(%d+)")
  if band and channel then
    vtx.currentBand = string.upper(band)
    vtx.currentChannel = tonumber(channel)
  end
end

local function vtxSetCurrentFromBandField(field)
  if type(field) ~= "table" or type(field.value) ~= "number" then return end
  local names = { "A", "B", "E", "F", "R" }
  vtx.currentBand = names[field.value]
end

local function vtxSetCurrentFromChannelField(field)
  if type(field) ~= "table" or type(field.value) ~= "number" then return end
  local min = type(field.min) == "number" and field.min or 1
  local channel = field.value - min + 1
  if channel >= 1 and channel <= 8 then
    vtx.currentChannel = channel
  end
end

local function vtxSendPing()
  crossfireTelemetryPush(CMD_PING, { 0x00, CRSF_ADDR_RADIO })
  vtx.timer = getTime()
  vtx.state = VtxState.PINGING
end

local function vtxRequestField(fieldId)
  vtx.loadIdx = fieldId
  vtx.chunkBuf = {}
  vtx.chunkIdx = 0
  crossfireTelemetryPush(CMD_PARAM_READ, {
    vtx.deviceId, vtx.handsetId, fieldId, 0
  })
  vtx.timer = getTime()
end

local function vtxStartEnumeration()
  vtx.vtxFolderId = nil
  vtx.bandFieldId = nil
  vtx.channelFieldId = nil
  vtx.sendFieldId = nil
  vtx.currentBand = nil
  vtx.currentChannel = nil
  vtx.loadIdx = 0
  vtx.fields = {}
  vtx.state = VtxState.ENUMERATING
  vtxRequestField(1)
end

local function vtxFinishDiscovery()
  if not vtx.vtxFolderId then
    vtx.state = VtxState.ERROR
    return false
  end

  for id, field in pairs(vtx.fields) do
    if type(field) == "table" and field.parent == vtx.vtxFolderId then
      local name = type(field.name) == "string" and string.lower(field.name) or ""
      if name == "band" then
        vtx.bandFieldId = id
        vtxSetCurrentFromBandField(field)
      elseif name == "channel" then
        vtx.channelFieldId = id
        vtxSetCurrentFromChannelField(field)
      elseif string.find(name, "send") then
        vtx.sendFieldId = id
      end
    end
  end

  if not (vtx.bandFieldId and vtx.channelFieldId and vtx.sendFieldId) then
    vtx.state = VtxState.ERROR
    return false
  end

  vtx.state = VtxState.READY
  return true
end

local function vtxRequestNextField()
  if vtx.loadIdx >= vtx.fieldCount then
    for id, field in pairs(vtx.fields) do
      if type(field) == "table"
         and field.type == TYPE_FOLDER
         and type(field.name) == "string"
         and string.find(field.name, "VTX") then
        vtx.vtxFolderId = id
        vtxSetCurrentFromDynName(field.dynName)
        break
      end
    end
    vtxFinishDiscovery()
    return
  end

  vtxRequestField(vtx.loadIdx + 1)
end

local function vtxParseDeviceInfo(data)
  if not data or #data < 3 then return end
  local srcId = data[2]
  if srcId ~= CRSF_ADDR_MODULE then return end
  vtx.deviceId = srcId

  local _, offset = vtxFieldGetString(data, 3)
  if offset + 12 <= #data then
    vtx.fieldCount = data[offset + 12]
  else
    vtx.fieldCount = 0
  end

  if vtx.fieldCount == 0 then
    vtx.state = VtxState.ERROR
    return
  end

  vtxStartEnumeration()
end

local function vtxParseFieldData(fieldId, data)
  if type(data) ~= "table" or #data < 3 then return end

  local field = { id = fieldId }
  local i = 1
  field.parent = data[i]
  i = i + 1
  if field.parent == 0 then field.parent = nil end

  local rawType = data[i]
  i = i + 1
  field.type = rawType % 128
  field.hidden = rawType >= 128
  field.name, i = vtxFieldGetString(data, i)

  if field.type == TYPE_TEXT_SEL then
    field.options, i = vtxFieldGetString(data, i)
  end

  if field.type == TYPE_TEXT_SEL or field.type == TYPE_UINT8 then
    if i <= #data then field.value = data[i]; i = i + 1 end
    if i <= #data then field.min = data[i]; i = i + 1 end
    if i <= #data then field.max = data[i]; i = i + 1 end
  elseif field.type == TYPE_FOLDER then
    if i <= #data and data[i] ~= 0 then
      field.dynName, i = vtxFieldGetString(data, i)
    end
  elseif field.type == TYPE_COMMAND then
    if i <= #data then field.status = data[i]; i = i + 1 end
    if i <= #data then field.timeout = data[i]; i = i + 1 end
    if i <= #data then field.info, i = vtxFieldGetString(data, i) end
  end

  vtx.fields[fieldId] = field
end

local function vtxParseParamInfo(data)
  if not data or #data < 5 then return end
  if data[2] ~= vtx.deviceId then return end

  local fieldId = data[3]
  local chunksRemain = data[4]

  for i = 5, #data do
    vtx.chunkBuf[#vtx.chunkBuf + 1] = data[i]
  end

  if chunksRemain > 0 then
    vtx.chunkIdx = vtx.chunkIdx + 1
    crossfireTelemetryPush(CMD_PARAM_READ, {
      vtx.deviceId, vtx.handsetId, fieldId, vtx.chunkIdx
    })
    vtx.timer = getTime()
    return
  end

  vtxParseFieldData(fieldId, vtx.chunkBuf)
  vtxRequestNextField()
end

local function vtxWriteParam(fieldId, value, nextState)
  crossfireTelemetryPush(CMD_PARAM_WRITE, {
    vtx.deviceId, vtx.handsetId, fieldId, value
  })
  vtx.state = nextState
  vtx.timer = getTime()
end

local function vtxSendChannel(band, channel)
  if vtx.state ~= VtxState.READY then return false end
  local bandValue = BAND_VALUES[band]
  if not bandValue then return false end

  vtx.pendingBand = band
  vtx.pendingChannel = channel
  vtxWriteParam(vtx.bandFieldId, bandValue, VtxState.WRITING_BAND)
  return true
end

local function vtxContinueApply()
  if vtx.state == VtxState.WRITING_BAND then
    local chanField = vtx.fields[vtx.channelFieldId]
    local chanMin = (chanField and chanField.min) or 0
    vtxWriteParam(vtx.channelFieldId, chanMin + (vtx.pendingChannel - 1), VtxState.WRITING_CHAN)
  elseif vtx.state == VtxState.WRITING_CHAN then
    vtxWriteParam(vtx.sendFieldId, LCS_START, VtxState.WRITING_SEND)
  elseif vtx.state == VtxState.WRITING_SEND then
    vtxWriteParam(vtx.sendFieldId, LCS_CONFIRMED, VtxState.CONFIRMING)
  elseif vtx.state == VtxState.CONFIRMING then
    vtx.currentBand = vtx.pendingBand
    vtx.currentChannel = vtx.pendingChannel
    vtx.pendingBand = nil
    vtx.pendingChannel = nil
    vtx.state = VtxState.READY
  end
end

local function vtxProcessIncoming(command, data)
  if command == CMD_DEVICE_INFO and vtx.state == VtxState.PINGING then
    vtxParseDeviceInfo(data)
  elseif command == CMD_PARAM_RESP then
    if vtx.state == VtxState.ENUMERATING then
      vtxParseParamInfo(data)
    elseif vtx.state >= VtxState.WRITING_BAND and vtx.state <= VtxState.CONFIRMING then
      local respFieldId = data and data[3]
      local expectedId =
        (vtx.state == VtxState.WRITING_BAND and vtx.bandFieldId) or
        (vtx.state == VtxState.WRITING_CHAN and vtx.channelFieldId) or
        vtx.sendFieldId
      if respFieldId == expectedId then
        vtxContinueApply()
      end
    end
  end
end

local function vtxTick()
  local elapsed = getTime() - vtx.timer

  if vtx.state == VtxState.PINGING and elapsed > VTX_TIMEOUT_PING then
    if vtx.retryCount < VTX_RETRY_MAX then
      vtx.retryCount = vtx.retryCount + 1
      vtxSendPing()
    else
      vtx.state = VtxState.ERROR
    end
  elseif vtx.state == VtxState.ENUMERATING and elapsed > VTX_TIMEOUT_ENUM then
    vtxRequestField(vtx.loadIdx)
  elseif vtx.state >= VtxState.WRITING_BAND and vtx.state <= VtxState.CONFIRMING then
    local timeout = (vtx.state <= VtxState.WRITING_CHAN) and VTX_TIMEOUT_WRITE or VTX_TIMEOUT_SEND
    if elapsed > timeout then
      vtxContinueApply()
    end
  end
end

local function processIncomingTelemetry()
  for _ = 1, 20 do
    local command, data = crossfireTelemetryPop()
    if not command then break end

    if command == CRSF_FRAMETYPE_MSP_RESP then
      if data and data[1] == CRSF_ADDRESS_RADIO_TRANSMITTER and data[2] == CRSF_ADDRESS_BETAFLIGHT then
        local mspData = {}
        for i = 3, #data do mspData[i - 2] = data[i] end
        local ret = mspReceivedReply(mspData)
        if type(ret) == "table" then
          mspLastReq = 0
        end
      end
    elseif command == CMD_DEVICE_INFO or command == CMD_PARAM_RESP then
      vtxProcessIncoming(command, data)
    end
  end
end

-- =====================================
-- MSP コマンド定数
-- =====================================
local MSP_EEPROM_WRITE   = 250
local MSP_SET_LED_COLORS = 47

-- =====================================
-- コマンドキュー
-- =====================================
local isBusy           = false
local isCommandInTxBuf = false
local lastSendTime     = 0
local SEND_DELAY       = 2

local commandSequence = {}
local commandPointer  = 0
local currentCommand  = nil
local state           = "READY"  -- READY, SENDING, DONE, NO_FAV

local function preparePaletteCommand(entry)
  local cmd = { kind = "msp_write", header = MSP_SET_LED_COLORS, payload = {} }
  cmd.text = "LED: " .. entry.name
  for i = 1, 16 do
    cmd.payload[#cmd.payload + 1] = bit32.band(entry.h, 0xFF)
    cmd.payload[#cmd.payload + 1] = bit32.band(bit32.rshift(entry.h, 8), 0xFF)
    cmd.payload[#cmd.payload + 1] = bit32.band(entry.s, 0xFF)
    cmd.payload[#cmd.payload + 1] = bit32.band(entry.v, 0xFF)
  end
  return cmd
end

local function prepareVtxCommand(vtxStr)
  if not vtxStr or vtxStr == "" then return nil end
  local band = string.upper(string.sub(vtxStr, 1, 1))
  local channel = tonumber(string.sub(vtxStr, 2, 2))
  if BAND_VALUES[band] and channel and channel >= 1 and channel <= 8 then
    return {
      kind    = "vtx",
      band    = band,
      channel = channel,
      text    = "VTX: " .. string.upper(vtxStr),
    }
  end
  return nil
end

local function prepareSaveCommand()
  return { kind = "msp_read", header = MSP_EEPROM_WRITE, payload = nil, text = "Saving..." }
end

local function gotoNextCommand()
  commandPointer = commandPointer + 1
  if commandPointer <= #commandSequence then
    currentCommand = commandSequence[commandPointer]
  else
    state = "DONE"; currentCommand = nil; isBusy = false
  end
end

local function failTransmission(reason)
  state = "FAIL: " .. reason
  currentCommand = nil
  isBusy = false
  isCommandInTxBuf = false
end

local function pumpQueue()
  if not isBusy or not currentCommand then return end

  if currentCommand.kind == "vtx" then
    if vtx.state == VtxState.ERROR then
      if not currentCommand.retried then
        currentCommand.retried = true
        vtx.retryCount = 0
        vtxSendPing()
        return
      end
      failTransmission("VTX")
      return
    end

    if not currentCommand.started then
      currentCommand.started = true
      if vtx.state == VtxState.IDLE then
        vtx.retryCount = 0
        vtxSendPing()
      end
    end

    if not currentCommand.sent then
      if vtx.state == VtxState.READY then
        if not vtxSendChannel(currentCommand.band, currentCommand.channel) then
          failTransmission("VTX")
          return
        end
        currentCommand.sent = true
      end
      return
    end

    if vtx.state == VtxState.READY
       and vtx.currentBand == currentCommand.band
       and vtx.currentChannel == currentCommand.channel then
      gotoNextCommand()
    end
  else
    if not isCommandInTxBuf then
      local t = getTime()
      if t < lastSendTime + SEND_DELAY then return end
      local res
      if currentCommand.kind == "msp_write" then
        res = mspWrite(currentCommand.header, currentCommand.payload)
      else
        res = mspRead(currentCommand.header)
      end
      if res == false then
        lastSendTime = getTime()
        gotoNextCommand()
      elseif res == true then
        isCommandInTxBuf = true
      end
    else
      local res = mspProcessTxQ()
      if res == false then
        isCommandInTxBuf = false
        lastSendTime = getTime()
        gotoNextCommand()
      end
    end
  end
end

local function startTransmission(entry)
  commandSequence = {}
  commandSequence[#commandSequence + 1] = preparePaletteCommand(entry)
  local vtxCmd = prepareVtxCommand(entry.vtx)
  if vtxCmd then commandSequence[#commandSequence + 1] = vtxCmd end
  commandSequence[#commandSequence + 1] = prepareSaveCommand()
  commandPointer = 0; isBusy = true; isCommandInTxBuf = false
  state = "SENDING"
  gotoNextCommand()
end

-- =====================================
-- エントリのHSVからRGBを近似 (表示用)
-- rainbowColorsの定義値に一致すれば正確、それ以外は近似
-- =====================================
local knownColors = {
  [0]   = {255, 0,   0},    -- Red
  [30]  = {255, 128, 0},    -- Orange
  [60]  = {255, 255, 0},    -- Yellow
  [120] = {0,   255, 0},    -- Green
  [180] = {0,   255, 255},  -- Cyan
  [240] = {0,   0,   255},  -- Blue
  [300] = {128, 0,   255},  -- Violet
}

local knownNames = {
  [0]   = "Red",    [30]  = "Orange", [60]  = "Yellow",
  [120] = "Green",  [180] = "Cyan",   [240] = "Blue",
  [300] = "Violet",
}

local function hsvToRgbApprox(h, s, v)
  -- まず既知の色から探す
  if knownColors[h] and s == 0 then
    local r, g, b = knownColors[h][1], knownColors[h][2], knownColors[h][3]
    -- v=255以外はスケール調整
    if v ~= 255 then
      r = math.floor(r * v / 255)
      g = math.floor(g * v / 255)
      b = math.floor(b * v / 255)
    end
    return r, g, b
  end
  -- 一般的なHSV→RGB変換
  local r, g, b
  if s == 0 then
    r = v; g = v; b = v
  else
    local hi = math.floor(h / 60) % 6
    local f  = (h / 60) - math.floor(h / 60)
    local p  = math.floor(v * (255 - s) / 255)
    local q  = math.floor(v * (255 - f * s) / 255)
    local t  = math.floor(v * (255 - (1 - f) * s) / 255)
    if     hi == 0 then r, g, b = v, t, p
    elseif hi == 1 then r, g, b = q, v, p
    elseif hi == 2 then r, g, b = p, v, t
    elseif hi == 3 then r, g, b = p, q, v
    elseif hi == 4 then r, g, b = t, p, v
    else                r, g, b = v, p, q
    end
  end
  return r, g, b
end

-- =====================================
-- led4vtxlite.fav の読み込み
-- =====================================
-- フォーマット (各行): VTXch,H,S,V
--   例: E2,0,0,255  /  ,120,0,255 (VTXなし)

local entries = {}   -- { name, vtx, h, s, v, rgb={r,g,b} }

local function loadFav()
  entries = {}
  local file = io.open("led4vtxlite.fav", "r")
  if not file then
    state = "NO_FAV"
    return
  end
  local content = io.read(file, 512)
  io.close(file)
  if not content then state = "NO_FAV"; return end

  for line in string.gmatch(content, "[^\r\n]+") do
    -- trim
    line = string.match(line, "^%s*(.-)%s*$")
    if line ~= "" then
      local vtxStr, hStr, sStr, vStr

      -- パターン1: "Xn,H,S,V" (VTXch付き: アルファベット+数字)
      vtxStr, hStr, sStr, vStr = string.match(line, "^([A-Za-z]%d),(%d+),(%d+),(%d+)$")

      if not hStr then
        -- パターン2: ",H,S,V" (VTXなし)
        hStr, sStr, vStr = string.match(line, "^,(%d+),(%d+),(%d+)$")
        vtxStr = nil
      end

      if hStr then
        local h = tonumber(hStr)
        local s = tonumber(sStr)
        local v = tonumber(vStr)
        if h and s and v then
          local r, g, b = hsvToRgbApprox(h, s, v)
          local name = knownNames[h] or ("H=" .. h)
          local vtxU = vtxStr and string.upper(vtxStr) or nil
          entries[#entries + 1] = {
            name = name,
            vtx  = vtxU,
            h = h, s = s, v = v,
            rgb = { r, g, b },
          }
        end
      end
    end
  end

  if #entries == 0 then state = "NO_FAV" end
end

-- =====================================
-- UI レイアウト (Led4Vtx.lua のお気に入り部分に準拠)
-- =====================================
local isColor = lcd.RGB ~= nil
local isSmall = LCD_H < 100

local btn_y = isSmall and 12 or 25
local btn_h = isSmall and 15 or 50
local text_y = btn_y + btn_h + (isSmall and 4 or 10)

local selectedIndex = 1

local function getTouchedEntry(x, y)
  if #entries == 0 then return nil end
  if y >= btn_y and y <= btn_y + btn_h then
    local block_w = LCD_W / #entries
    local idx = math.floor(x / block_w) + 1
    if idx >= 1 and idx <= #entries then return idx end
  end
  return nil
end

local function sendEntry(idx)
  local entry = entries[idx]
  if not entry then return end
  if state == "READY" or state == "DONE" or string.sub(state, 1, 4) == "FAIL" then
    selectedIndex = idx
    startTransmission(entry)
  end
end

-- =====================================
-- タッチ状態
-- =====================================
local touchStartTime = 0
local touchStartX    = 0
local touchStartY    = 0
local isTouching     = false
local touchCancelled = false

-- =====================================
-- init / run
-- =====================================
local function init_func()
  state = "READY"
  loadFav()
  if #entries > 0 then selectedIndex = 1 end
  vtx.retryCount = 0
  vtxSendPing()
end

local function run_func(event, touchState)
  -- EXIT
  if event == EVT_EXIT_BREAK or event == EVT_VIRTUAL_EXIT then
    return -1
  end

  -- ダイヤル操作
  if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_INC or event == EVT_VIRTUAL_INC_REPT then
    selectedIndex = selectedIndex + 1
    if selectedIndex > #entries then selectedIndex = 1 end
  elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_DEC or event == EVT_VIRTUAL_DEC_REPT then
    selectedIndex = selectedIndex - 1
    if selectedIndex < 1 then selectedIndex = #entries end
  end

  -- エンターキー
  if event == EVT_ENTER_BREAK then
    sendEntry(selectedIndex)
  end

  -- タッチ操作 (EVT_TOUCH_* イベントで判定)
  if event == EVT_TOUCH_FIRST then
    isTouching    = true
    touchCancelled = false
    touchStartTime = getTime()
    touchStartX   = touchState.x
    touchStartY   = touchState.y
  elseif event == EVT_TOUCH_SLIDE then
    touchCancelled = true
    isTouching    = false
  elseif event == EVT_TOUCH_TAP then
    if not touchCancelled then
      local idx = getTouchedEntry(touchState.x, touchState.y)
      if idx then sendEntry(idx) end
    end
    isTouching = false; touchCancelled = false
  elseif event == EVT_TOUCH_BREAK then
    if isTouching and not touchCancelled then
      local idx = getTouchedEntry(touchStartX, touchStartY)
      if idx then sendEntry(idx) end
    end
    isTouching = false; touchCancelled = false
  end

  pumpQueue()
  mspProcessTxQ()
  processIncomingTelemetry()
  vtxTick()

  -- =====================================
  -- 描画
  -- =====================================
  lcd.clear()
  lcd.drawText(2, 0, "Led4VtxLite", BOLD or 0)

  if state == "NO_FAV" then
    -- エラー表示
    lcd.drawText(2, btn_y, "ERROR: led4vtxlite.fav", 0)
    lcd.drawText(2, btn_y + (isSmall and 10 or 20), "not found or empty", SMLSIZE or 0)
    return 0
  end

  -- ----------------------------------------
  -- カラーブロック (Led4Vtx.lua のお気に入りと同じ構造)
  -- ----------------------------------------
  local n = #entries
  local block_w = LCD_W / n

  for i, entry in ipairs(entries) do
    local x = math.floor((i - 1) * block_w)
    local w = math.floor(block_w)
    local isSelected = (selectedIndex == i)

    if isColor then
      -- カラー塗りつぶし
      local r, g, b = entry.rgb[1], entry.rgb[2], entry.rgb[3]
      lcd.drawFilledRectangle(x, btn_y, w, btn_h, lcd.RGB(r, g, b))
      -- 選択枠 (二重枠)
      if isSelected then
        lcd.drawRectangle(x,     btn_y,     w,     btn_h,     lcd.RGB(0, 0, 0))
        lcd.drawRectangle(x + 1, btn_y + 1, w - 2, btn_h - 2, lcd.RGB(0, 0, 0))
      end
    else
      -- 白黒LCD
      lcd.drawRectangle(x, btn_y, w, btn_h, 0)
      if isSelected then
        lcd.drawFilledRectangle(x, btn_y, w, btn_h, 0)
      end
    end

    -- VTXラベル (左上に小さく表示)
    if entry.vtx then
      if isColor then
        local tx = x + 2
        local ty = btn_y + 2
        -- 黒背景で視認性確保
        lcd.drawFilledRectangle(tx - 1, ty - 1, 18, 13, lcd.RGB(0, 0, 0))
        lcd.drawText(tx, ty, entry.vtx, INVERS)
      else
        local attr = isSelected and INVERS or 0
        lcd.drawText(x + 2, btn_y + 2, entry.vtx, attr)
      end
    end
  end

  -- ----------------------------------------
  -- ステータス行 (選択中の色名 + VTX + 送信状態)
  -- ----------------------------------------
  local entry = entries[selectedIndex]
  local selName = entry and entry.name or ""
  local selVtx  = entry and entry.vtx  or ""

  local infoStr = selName
  if selVtx ~= "" then infoStr = infoStr .. " (" .. selVtx .. ")" end

  lcd.drawText(2, text_y, infoStr, 0)

  -- 送信状態 (右寄せ)
  local stateStr = state
  if state == "SENDING" and currentCommand then
    stateStr = currentCommand.text
  end
  lcd.drawText(LCD_W - 60, text_y, stateStr, 0)

  -- 送信完了メッセージ (1行下)
  if state == "DONE" then
    lcd.drawText(2, text_y + (isSmall and 10 or 18), "Done!", SMLSIZE or 0)
  end

  return 0
end

return { run = run_func, init = init_func }
