-- Led4Vtx.lua
-- 独立したLED制御スクリプト
-- Betaflight 4.5+ でLED色を設定し、VTXはELRS VTX Admin経由で切り替えます。

local MSP_VERSION = bit32.lshift(1,5)
local MSP_STARTFLAG = bit32.lshift(1,4)

local mspSeq = 0
local mspRemoteSeq = 0
local mspRxBuf = {}
local mspRxSize = 0
local mspRxCRC = 0
local mspRxReq = 0
local mspStarted = false
local mspLastReq = 0
local mspTxBuf = {}
local mspTxIdx = 1
local mspTxCRC = 0

local maxTxBufferSize = 8
local maxRxBufferSize = 58

local CRSF_ADDRESS_BETAFLIGHT          = 0xC8
local CRSF_ADDRESS_RADIO_TRANSMITTER   = 0xEA
local CRSF_FRAMETYPE_MSP_REQ           = 0x7A
local CRSF_FRAMETYPE_MSP_RESP          = 0x7B
local CRSF_FRAMETYPE_MSP_WRITE         = 0x7C

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
local BAND_VALUES = { A = 1, B = 2, E = 3, F = 4, R = 5 }

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

local VTX_TIMEOUT_PING = 20
local VTX_TIMEOUT_ENUM = 100
local VTX_TIMEOUT_WRITE = 15
local VTX_TIMEOUT_SEND = 20
local VTX_RETRY_MAX = 10

local function mspSend(payload)
    local payloadOut = { CRSF_ADDRESS_BETAFLIGHT, CRSF_ADDRESS_RADIO_TRANSMITTER }
    for i=1, #(payload) do
        payloadOut[i+2] = payload[i]
    end
    return crossfireTelemetryPush(crsfMspCmd, payloadOut)
end

local function mspProcessTxQ()
    if (#(mspTxBuf) == 0) then return false end
    if not crossfireTelemetryPush() then return true end
    
    local payload = {}
    payload[1] = mspSeq + MSP_VERSION
    mspSeq = bit32.band(mspSeq + 1, 0x0F)
    if mspTxIdx == 1 then
        payload[1] = payload[1] + MSP_STARTFLAG
    end
    
    local i = 2
    while (i <= maxTxBufferSize) and mspTxIdx <= #mspTxBuf do
        payload[i] = mspTxBuf[mspTxIdx]
        mspTxIdx = mspTxIdx + 1
        mspTxCRC = bit32.bxor(mspTxCRC,payload[i])  
        i = i + 1
    end
    
    if i <= maxTxBufferSize then
        payload[i] = mspTxCRC
        mspSend(payload)
        mspTxBuf = {}
        mspTxIdx = 1
        mspTxCRC = 0
        return false
    end
    
    mspSend(payload)
    return true
end

local function mspSendRequest(cmd, payload)
    if #(mspTxBuf) ~= 0 or not cmd then return nil end
    mspTxBuf[1] = #(payload)
    mspTxBuf[2] = bit32.band(cmd,0xFF)
    for i=1,#(payload) do
        mspTxBuf[i+2] = bit32.band(payload[i],0xFF)
    end
    mspLastReq = cmd
    return mspProcessTxQ()
end

local function mspReceivedReply(payload)
    local idx = 1
    local status = payload[idx]
    local err = bit32.btest(status, 0x80)
    local version = bit32.rshift(bit32.band(status, 0x60), 5)
    local start = bit32.btest(status, 0x10)
    local seq = bit32.band(status, 0x0F)
    idx = idx + 1
    
    if err then
        mspStarted = false
        return nil
    end
    
    if start then
        mspRxBuf = {}
        mspRxSize = payload[idx]
        mspRxReq = mspLastReq
        idx = idx + 1
        if version == 1 then
            mspRxReq = payload[idx]
            idx = idx + 1
        end
        mspRxCRC = bit32.bxor(mspRxSize, mspRxReq)
        if mspRxReq == mspLastReq then
            mspStarted = true
        end
    elseif not mspStarted then
        return nil
    elseif bit32.band(mspRemoteSeq + 1, 0x0F) ~= seq then
        mspStarted = false
        return nil
    end
    
    while (idx <= maxRxBufferSize) and (#mspRxBuf < mspRxSize) do
        mspRxBuf[#mspRxBuf + 1] = payload[idx]
        mspRxCRC = bit32.bxor(mspRxCRC, payload[idx])
        idx = idx + 1
    end
    
    if idx > maxRxBufferSize then
        mspRemoteSeq = seq
        return true
    end
    
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
                for i = 3, #data do
                    mspData[i - 2] = data[i]
                end
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


local MSP_EEPROM_WRITE = 250
local MSP_SET_LED_COLORS = 47

local isBusy = false
local isCommandInTxBuf = false
local retryCount = 0
local lastSendTime = 0
local SEND_DELAY = 2 

local commandSequence = {}
local commandPointer = 0
local currentCommand = nil
local state = "READY" -- READY, SENDING, DONE, FAIL

-- 虹の7色定義 (BetaflightではS=0が最も鮮やか)
local rainbowColors = {
  { name="Red",    h=0,   s=0, v=255, rgb={255, 0, 0} },
  { name="Orange", h=30,  s=0, v=255, rgb={255, 128, 0} },
  { name="Yellow", h=60,  s=0, v=255, rgb={255, 255, 0} },
  { name="Green",  h=120, s=0, v=255, rgb={0, 255, 0} },
  { name="Cyan",   h=180, s=0, v=255, rgb={0, 255, 255} },
  { name="Blue",   h=240, s=0, v=255, rgb={0, 0, 255} },
  { name="Violet", h=300, s=0, v=255, rgb={128, 0, 255} }
}

local favorites = {}
local vtxFavorites = {}
local vtxFavExists = false  -- tracks whether easyvtxch.fav was found
local selectedSection = 2 -- 1: Favorites, 2: Rainbow
local selectedIndex = 1

local function loadFavorites()
  favorites = {}
  vtxFavorites = {}
  local file = io.open("led4vtx.fav", "r")
  if file then
    local content = io.read(file, 128)
    if content then
      for id in string.gmatch(content, "%d+") do
        favorites[#favorites + 1] = tonumber(id)
      end
    end
    io.close(file)
  end
  
  vtxFavExists = false
  local vtxFile = io.open("/SCRIPTS/TOOLS/easyvtxch.fav", "r")
  if vtxFile then
    vtxFavExists = true
    local content = io.read(vtxFile, 256)
    if content then
      for line in string.gmatch(content, "[^\r\n]+") do
        if string.match(line, "^[A-Z]%d") then
          vtxFavorites[#vtxFavorites + 1] = string.sub(line, 1, 2)
        end
      end
    end
    io.close(vtxFile)
  end
end

local function saveFavorites()
  local file = io.open("led4vtx.fav", "w")
  if file then
    local content = ""
    for _, id in ipairs(favorites) do
      content = content .. tostring(id) .. ","
    end
    io.write(file, content)
    io.close(file)
  end
end

local function prepareVtxCommand(vtxStr)
  if not vtxStr then return nil end
  local b_str = string.sub(vtxStr, 1, 1)
  local c_str = string.sub(vtxStr, 2, 2)
  local band = string.upper(b_str)
  local channel = tonumber(c_str)
  
  if BAND_VALUES[band] and channel and channel >= 1 and channel <= 8 then
    local cmd = {}
    cmd.kind = "vtx"
    cmd.band = band
    cmd.channel = channel
    cmd.text = "Set VTX " .. vtxStr
    return cmd
  end
  return nil
end

local function prepareSaveCommand()
  local cmd = {}
  cmd.kind = "msp_read"
  cmd.header = MSP_EEPROM_WRITE
  cmd.payload = nil
  cmd.write = false
  cmd.text = "Saving to FC"
  return cmd
end

local function preparePaletteCommand(colorObj)
  local cmd = {}
  cmd.kind = "msp_write"
  cmd.header = MSP_SET_LED_COLORS
  cmd.payload = {}
  for i = 1, 16 do
    cmd.payload[#cmd.payload + 1] = bit32.band(colorObj.h, 0xFF)
    cmd.payload[#cmd.payload + 1] = bit32.band(bit32.rshift(colorObj.h, 8), 0xFF)
    cmd.payload[#cmd.payload + 1] = bit32.band(colorObj.s, 0xFF)
    cmd.payload[#cmd.payload + 1] = bit32.band(colorObj.v, 0xFF)
  end
  cmd.text = "Setting " .. colorObj.name
  return cmd
end

local function gotoNextCommand()
  commandPointer = commandPointer + 1
  if commandPointer <= #commandSequence then
    currentCommand = commandSequence[commandPointer]
  else
    state = "DONE"
    currentCommand = nil
    isBusy = false
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
      local currentTime = getTime()
      if currentTime < lastSendTime + SEND_DELAY then return end

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

local function startTransmission(colorObj, vtxStr)
  commandSequence = {}
  commandSequence[#commandSequence + 1] = preparePaletteCommand(colorObj)
  
  if vtxStr then
    local vtxCmd = prepareVtxCommand(vtxStr)
    if vtxCmd then
      commandSequence[#commandSequence + 1] = vtxCmd
    end
  end
  
  commandSequence[#commandSequence + 1] = prepareSaveCommand()
  
  commandPointer = 0
  isBusy = true
  isCommandInTxBuf = false
  state = "SENDING"
  gotoNextCommand()
end


-- =====================================
-- EdgeTX UI & Controls
-- =====================================
local isColor = lcd.RGB ~= nil
local isSmall = LCD_H < 100

local fav_y = isSmall and 12 or 25
local fav_h = isSmall and 15 or 50
local rainbow_y = fav_y + fav_h + (isSmall and 4 or 15)
local rainbow_h = isSmall and 15 or 50
local text_y = rainbow_y + rainbow_h + (isSmall and 2 or 15)

local function getTouchedItem(x, y)
  if y >= fav_y and y <= fav_y + fav_h and #favorites > 0 then
    local block_w = LCD_W / #favorites
    local idx = math.floor(x / block_w) + 1
    if idx >= 1 and idx <= #favorites then return 1, idx, block_w end
  elseif y >= rainbow_y and y <= rainbow_y + rainbow_h then
    local block_w = LCD_W / #rainbowColors
    local idx = math.floor(x / block_w) + 1
    if idx >= 1 and idx <= #rainbowColors then return 2, idx, block_w end
  end
  return nil, nil, nil
end

local function toggleFavorite(colorId)
  local found = nil
  for i, f in ipairs(favorites) do
    if f == colorId then found = i; break end
  end
  if found then
    table.remove(favorites, found)
  else
    favorites[#favorites + 1] = colorId
  end
  saveFavorites()
  if selectedSection == 1 and selectedIndex > #favorites then
    if #favorites > 0 then
      selectedIndex = #favorites
    else
      selectedSection = 2
      selectedIndex = 1
    end
  end
end

local function handleShortPress(sec, idx)
  selectedSection = sec
  selectedIndex = idx
  local colorId = (sec == 1) and favorites[idx] or idx
  local vtxStr = (sec == 1) and vtxFavorites[idx] or nil
  if state == "READY" or state == "DONE" or string.sub(state, 1, 4) == "FAIL" then
    startTransmission(rainbowColors[colorId], vtxStr)
  end
end

local function handleLongPress(sec, idx, x, y)
  -- secとidxはgetTouchedItemから既に正しい値が渡されている
  -- xとyは無視してsec/idxを使う（タッチ位置の浮動小数点誤差でずれるのを防ぐ）
  local colorId = (sec == 1) and favorites[idx] or idx
  toggleFavorite(colorId)
end

local touchStartTime = 0
local touchStartX = 0
local touchStartY = 0
local isTouching = false
local touchCancelled = false  -- スライドなどでキャンセルされた
local lastEnterLongTime = 0
local LONG_PRESS_TICKS = 50  -- 50 * 10ms = 500ms

local function init_func()
  state = "READY"
  loadFavorites()
  vtx.retryCount = 0
  vtxSendPing()
end

local function run_func(event, touchState)
  -- ダイヤル操作
  if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_INC or event == EVT_VIRTUAL_INC_REPT then
    selectedIndex = selectedIndex + 1
    local maxIdx = (selectedSection == 1) and #favorites or #rainbowColors
    if selectedIndex > maxIdx then
      if selectedSection == 1 then
        selectedSection = 2
      else
        selectedSection = (#favorites > 0) and 1 or 2
      end
      selectedIndex = 1
    end
  elseif event == EVT_VIRTUAL_PREV or event == EVT_VIRTUAL_DEC or event == EVT_VIRTUAL_DEC_REPT then
    selectedIndex = selectedIndex - 1
    if selectedIndex < 1 then
      if selectedSection == 2 and #favorites > 0 then
        selectedSection = 1
        selectedIndex = #favorites
      else
        selectedSection = (#favorites > 0 and selectedSection == 1) and 2 or 2
        selectedIndex = #rainbowColors
      end
    end
  end

  -- エンターキー
  if event == EVT_ENTER_BREAK then
    handleShortPress(selectedSection, selectedIndex)
  elseif event == EVT_ENTER_LONG then
    local now = getTime()
    if now > lastEnterLongTime + 50 then
      handleLongPress(selectedSection, selectedIndex)
      lastEnterLongTime = now
    end
  end

  -- タッチ操作
  -- EVT_TOUCH_FIRST/TAP/BREAK/SLIDE を event で判定する (EasyVTXch.lua参考)
  -- getTime() は 10ms 単位: LONG_PRESS_TICKS=50 が 500ms
  if event == EVT_TOUCH_FIRST then
    -- 指が触れた瞬間
    isTouching = true
    touchCancelled = false
    touchStartTime = getTime()
    touchStartX = touchState.x
    touchStartY = touchState.y
  elseif event == EVT_TOUCH_SLIDE then
    -- スライド開始 → 長押しをキャンセル
    touchCancelled = true
    isTouching = false
  elseif event == EVT_TOUCH_TAP then
    -- 短いタップ (システムが "短押し" と判定した)
    if not touchCancelled then
      local sec, idx = getTouchedItem(touchState.x, touchState.y)
      if sec and idx then
        handleShortPress(sec, idx)
      end
    end
    isTouching = false
    touchCancelled = false
  elseif event == EVT_TOUCH_BREAK then
    -- 指が離れた (TAP より長い)
    if isTouching and not touchCancelled then
      local duration = getTime() - touchStartTime
      local sec, idx = getTouchedItem(touchStartX, touchStartY)
      if sec and idx then
        if duration >= LONG_PRESS_TICKS then
          handleLongPress(sec, idx, touchStartX, touchStartY)
        else
          handleShortPress(sec, idx)
        end
      end
    end
    isTouching = false
    touchCancelled = false
  end

  pumpQueue()
  mspProcessTxQ()
  processIncomingTelemetry()
  vtxTick()

  -- 描画処理
  lcd.clear()
  lcd.drawText(2, 0, "Led4Vtx - Color & VTX", 0)

  -- タッチ中の長押し進行状況を計算 (0.0〜1.0)
  local longPressProgress = 0
  local touchSec, touchIdx = nil, nil
  if isTouching then
    local elapsed = getTime() - touchStartTime
    longPressProgress = math.min(elapsed / LONG_PRESS_TICKS, 1.0)
    touchSec, touchIdx = getTouchedItem(touchStartX, touchStartY)
  end

  local function drawBlocks(sec, items, y, h)
    if #items == 0 then return end
    local block_w = LCD_W / #items
    for i, item in ipairs(items) do
      local colorId = (sec == 1) and item or i
      local c = rainbowColors[colorId]
      local x = math.floor((i-1) * block_w)
      local w = math.floor(block_w)
      local isSelected = (selectedSection == sec and selectedIndex == i)
      local isTouchTarget = (touchSec == sec and touchIdx == i)

      if isColor then
        lcd.drawFilledRectangle(x, y, w, h, lcd.RGB(c.rgb[1], c.rgb[2], c.rgb[3]))
        if isSelected then
          lcd.drawRectangle(x, y, w, h, 0)
          lcd.drawRectangle(x+1, y+1, w-2, h-2, 0)
        end
        -- 長押し進行バー: タッチ中の対象ブロック下部に白いバーを表示
        if isTouchTarget and longPressProgress > 0 then
          local barW = math.floor(w * longPressProgress)
          lcd.drawFilledRectangle(x, y + h - 4, barW, 4, lcd.RGB(255, 255, 255))
        end
      else
        lcd.drawRectangle(x, y, w, h, 0)
        if isSelected then
          lcd.drawFilledRectangle(x, y, w, h, 0)
        end
        -- 白黒LCDでの長押し進行バー
        if isTouchTarget and not isSelected and longPressProgress > 0 then
          local barW = math.floor(w * longPressProgress)
          lcd.drawFilledRectangle(x, y + h - 3, barW, 3, 0)
        end
      end

      -- If it's favorites section, draw the associated VTX string below it
      if sec == 1 and vtxFavorites[i] then
        if isColor then
          -- Fixed-width black background: 2-char VTX strings (e.g. "E2")
          -- ~7px per char + 2px padding = 16
          local textW = 16
          local tx = x + 2
          local ty = y + 2
          lcd.drawFilledRectangle(tx - 1, ty - 1, textW + 2, 13, 0x000000)
          lcd.drawText(tx, ty, vtxFavorites[i], INVERS)
        else
          lcd.drawText(x + 2, y + 2, vtxFavorites[i], (selectedSection == sec and selectedIndex == i) and INVERS or 0)
        end
      end
    end
  end

  -- お気に入り表示
  if #favorites > 0 then
    drawBlocks(1, favorites, fav_y, fav_h)
    if not vtxFavExists then
      lcd.drawText(5, fav_y + fav_h - 12, "No VTX data!", SMLSIZE)
    end
  else
    local noFavMsg = "No Favs (Long press below)"
    if not vtxFavExists then
      noFavMsg = "No easyvtxch.fav!"
    end
    lcd.drawText(5, fav_y + (isSmall and 0 or 15), noFavMsg, 0)
  end

  -- 虹の7色表示
  drawBlocks(2, rainbowColors, rainbow_y, rainbow_h)
  
  -- ステータス等
  local selColorId = (selectedSection == 1) and favorites[selectedIndex] or selectedIndex
  local selName = selColorId and rainbowColors[selColorId].name or ""
  local selVtx = (selectedSection == 1) and vtxFavorites[selectedIndex] or ""
  
  local displayStr = "Select: " .. selName
  if selVtx ~= "" then displayStr = displayStr .. " (" .. selVtx .. ")" end
  if selectedSection == 1 then displayStr = displayStr .. " (*)" end
  
  lcd.drawText(2, text_y, displayStr, 0)
  lcd.drawText(LCD_W - 60, text_y, state, 0)
  
  if currentCommand and currentCommand.text then
    lcd.drawText(2, text_y + (isSmall and 10 or 20), "> " .. currentCommand.text, 0)
  end
  
  if event == EVT_EXIT_BREAK then
    return -1
  end
  
  return 0
end

return { run = run_func, init = init_func }
