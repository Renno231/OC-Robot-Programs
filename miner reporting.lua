local component = require("component")
local event = require("event")
local serialization = require("serialization")
local fs = require("filesystem")
local miners = {}
local modem = component.modem
modem.open(1)
modem.setStrength(400)
local logFile = "/home/minerlog.lua"

local function writelogFile()
    local file = io.open(logFile, "w")
    --recordToOutput("miners file"..tostring(file))
    file:write("local miners = "..serialization.serialize(miners).."\n\nreturn miners")
    file:close()
end

local function readlogFile()
    local file = io.open(logFile, "r")
    if file == nil then
        writelogFile() 
        return 
    end
    file:close()
    local minersOverride = dofile(logFile)
    if type(minersOverride) == "table" then
        for setting, value in pairs (minersOverride) do
            if miners[setting]~=nil then
                if type(miners[setting]) == type(value) then
                    miners[setting] = value
                end
            end
        end
    end
end
readlogFile()
writelogFile()

local running = true 
while running do 
    local args = {event.pull(10)} 
    if args[1] == "modem_message" then
        local minerID, msg = args[3], args[6]
        --print(table.unpack(args))
        if not miners[minerID] or #miners[minerID] > 100 then
            miners[minerID] = {}
        end
        table.insert(miners[minerID], args[6])
        writelogFile()
        os.sleep()
        if msg then
            if msg:find("waiting for instructions") then
                print("     -> CONNECTING TO", minerID)
                modem.send(minerID, 1, "acknowledged")
            elseif msg:find("link established") then
                print("     -> ESTABLISHED CONNECTION TO", minerID)
                --reset log for this robot ? maybe do a proximity check too?
            else
                print(minerID:sub(1,8), msg)
            end
        end
    end    

    if args[1] == "interrupted" then
        running = false
    end
end