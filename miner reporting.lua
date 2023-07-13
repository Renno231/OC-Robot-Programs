local component = require("component")
local event = require("event")
local modem = component.modem
modem.open(1)
modem.setStrength(400)
local running = true 
while running do 
    local args = {event.pull(10)} 
    if args[1] == "modem_message" then
        print(table.unpack(args))
        os.sleep()
        local msg = args[6]
        if msg then
            if msg:find("waiting for instructions") then
                print("     -> CONNECTING TO", args[3])
                modem.send(args[3], 1, "acknowledged")
            elseif msg:find("link established") then
                print("     -> ESTABLISHED CONNECTION TO", args[3])
            end
        end
    end    

    if args[1] == "interrupted" then
        running = false
    end
end