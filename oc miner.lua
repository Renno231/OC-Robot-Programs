local chunks = 9 -- number of mining chunks
local hardness = {2.2, 40} -- minimum and maximum hardness
local port = 1 -- robot communication port
local X, Y, Z, D, border = 0, 0, 0, 0 -- local coordinate system variables
local steps, turns = 0, 0 -- debug
local WORLD = {x = {}, y = {}, z = {}} -- points table
local E_C, W_R = 0, 0 -- energy consumption per step and wear rate
local posData = {0, 0, 0, [0] = 1} -- table to store chunk coordinates, should store this at the top of the script to access the current chunk entry
local currentChunk, entryHeight = 1, -2
local chunkEntries = {{0,entryHeight,0}} --entry coordinates for chunks

local function arr2dict(tbl) -- converting a list into an associative array
    for i = #tbl, 1, -1 do
        tbl[tbl[i]], tbl[i] = true, nil
    end
end

local quads = {{-7, -7}, {-7, 1}, {1, -7}, {1, 1}}
local workbench = {1, 2, 3, 5, 6, 7, 9, 10, 11}
local returnHomeOrder = {3,2,1}
local wlist = {"enderstorage:ender_storage"}
local fragments = {"redstone", "coal", "dye", "diamond", "emerald", "electrotine"}
local fodder = {'deepslate','cobbleddeepslate','cobblestone','granite','diorite','andesite','marble','limestone','dirt','gravel','sand','stained_hardened_clay','sandstone','stone','grass','end_stone','hardened_clay','mossy_cobblestone','planks','fence','torch','nether_brick','nether_brick_fence','nether_brick_stairs','netherrack','soul_sand'}
arr2dict(wlist)
arr2dict(fragments)
arr2dict(fodder)

local function getComponent(name) -- obtaining a proxy component
    name = component.list(name)() -- get an address by name
    if name then -- "if address exists"
        return component.proxy(name) -- return proxy
    end
end

-- component load --
local controller = getComponent("inventory_controller")
local chunkloader = getComponent("chunkloader")
local generator = getComponent("generator")
local crafting = getComponent("crafting")
local geolyzer = getComponent("geolyzer")
local tunnel = getComponent("tunnel")
local modem = getComponent("modem")
local robot = getComponent("robot")
local inventory, currentSlot = robot.inventorySize(), robot.select()
local penpal, moveTo, energy_level, sleep, report, remove_point, check, step, turn, smart_turn, go, scan, calibration, sorter, home, main, solar, ignore_check, inv_check, dump

--to avoid extra component calls
local should = {invCheck = false, durCheck = false}
--so if it swung, and it didn't break anything, don't do a inventory check and thus save on component calls
swing = function(side) 
    local swung, obstacle = robot.swing(side)
    if swung then 
        should.invCheck = true
        should.durCheck = true 
    end
    return swung, obstacle
end

suck = function(side)
    local sucked = robot.suck(side)
    if sucked then
        should.invCheck = true
    end
    return sucked
end

energy_level = function()
    return computer.energy() / computer.maxEnergy()
end

sleep = function(timeout)
    local deadline = computer.uptime() + timeout
    repeat
        computer.pullSignal(deadline - computer.uptime())
    until computer.uptime() >= deadline
end

local reportStr = ""
report = function(message, stop) -- status report, needs to include current chunk number and formatted XYZ with %-5s
    message = message .. " |" .. X .. ", " .. Y .. ", " .. Z .. "| energy level: " .. math.floor(energy_level() * 100) .. "%" -- add coordinates and energy level to message
    if modem then -- "if modem installed"
    if not penpal then
        modem.broadcast(port, message) -- send message via modem
    else
        modem.send(penpal, port, message)
    end 
    elseif tunnel then -- "if tunnel card installed"
        tunnel.send(message) -- send message via tunnel card
    end
    computer.beep() -- beep
    if stop then -- if task is completed
        if chunkloader then
            chunkloader.setActive(false)
        end
        error(message, 0) -- stop programm
    end
end

remove_point = function(point) -- remove points
    table.remove(WORLD.x, point) -- remove point from table
    table.remove(WORLD.y, point)
    table.remove(WORLD.z, point)
end

check = function(forcibly) -- tool and battery check, points remove
    if not ignore_check and (steps % 32 == 0 or forcibly) then -- if moved on 32seps or enabled "force mode"
        inv_check()
        local delta = math.abs(X) + math.abs(Y) + math.abs(Z) + 64 -- get distance
        if should.durCheck then
            should.durCheck = false
            if robot.durability() / W_R < delta then -- if tool is worn
                report("Tool is worn")
                ignore_check = true
                home(true) -- go home
            end
        end
        if delta * E_C > computer.energy() then -- check energy level
            report("Battery is low")
            ignore_check = true
            home(true) -- go home
        end
        if energy_level() < 0.3 then -- if the energy level is less than 30%
            local time = os.date("*t")
            if generator and generator.count() == 0 and not forcibly then -- if generator installed
                report("refueling solid fuel generators")
                for slot = 1, inventory do -- check inventory
                    currentSlot = robot.select(slot) -- select slot
                    for gen in component.list("generator") do -- check all generators
                        if component.proxy(gen).insert() then -- try to refuel
                            break
                        end
                    end
                end
            elseif
                solar and geolyzer.isSunVisible() and -- check the visibility of the sun
                    (time.hour > 4 and time.hour < 17)
             then -- check current time
                while not geolyzer.canSeeSky() do -- until can't see sky
                    moveTo(X, Y+1, Z, nil, true) -- move up without check
                end
                report("recharging in the sun")
                sorter(true)
                while (energy_level() < 0.98) and geolyzer.isSunVisible() do
                    time = os.date("*t") -- solar panel works 05:30 - 18:30
                    if time.hour >= 5 and time.hour < 19 then
                        sleep(60)
                    else
                        break
                    end
                end

                report("return to work in chunk "..tostring(currentChunk).." at coordinates "..tostring(chunkdata[1])..", "..tostring(chunkdata[2])..", "..tostring(chunkdata[3]))
            end
        end
    end
    if #WORLD.x ~= 0 then -- if point table isn't empty
        for i = 1, #WORLD.x do -- check all points
            if
                WORLD.y[i] == Y and
                    ((WORLD.x[i] == X and ((WORLD.z[i] == Z + 1 and D == 0) or (WORLD.z[i] == Z - 1 and D == 2))) or
                        (WORLD.z[i] == Z and ((WORLD.x[i] == X + 1 and D == 3) or (WORLD.x[i] == X - 1 and D == 1))))
             then
                swing(3)
                remove_point(i)
            end
            if X == WORLD.x[i] and (Y - 1 <= WORLD.y[i] and Y + 1 >= WORLD.y[i]) and Z == WORLD.z[i] then
                if WORLD.y[i] == Y + 1 then -- mine the block from above, if any
                    swing(1)
                elseif WORLD.y[i] == Y - 1 then -- mine the block from below
                    swing(0)
                end
                remove_point(i)
            end
        end
    end
end

step = function(side, ignore) -- function of moving by 1 block
    local barrier, whatsDetected = robot.detect(side)
    if barrier then -- if block is indestructible/unbreakable
        local swung, obstacle = swing(side) --maybe should do detect first and then swing
        if not swung then 
            if side == 0 then --unbreakable block
                border = Y --new boundary
            end
            return false
        else 
            while swing(side) do end
        end
    end
    local hasMoved = robot.move(side) 
    if hasMoved then -- if robot moves, change coordinates
        steps = steps + 1 -- debug
        if steps%10 == 0 then report("moved "..tostring(steps).." steps") end
        if side == 0 then
            Y = Y - 1
        elseif side == 1 then
            Y = Y + 1
        elseif side == 3 then
            if D == 0 then
                Z = Z + 1
            elseif D == 1 then
                X = X - 1
            elseif D == 2 then
                Z = Z - 1
            else
                X = X + 1
            end
        end
    end
    if not ignore then
        check()
    end
    return hasMoved
end

turn = function(side) -- turn
    side = side or false
    if robot.turn(side) and D then -- if the robot has turned, update the direction variable
        turns = turns + 1 -- debug
        D = (D + (side and 1 or -1)) % 4
        check()
    end
end

smart_turn = function(side) -- turn in a certain direction
    while D ~= side do
        turn((side - D) % 4 == 1)
    end
end

local moveDirFuncs = {
    function(newY) local succ = true while succ and Y ~= newY do if Y < newY then succ = step(1) elseif Y > newY then succ = step(0) end end return succ end,
    function(newX) local succ = true if X < newX then smart_turn(3) elseif X > newX then smart_turn(1) end while succ and X ~= newX do succ = step(3) end return succ end,
    function(newZ) local succ = true if Z < newZ then smart_turn(0) elseif Z > newZ then smart_turn(2) end while succ and Z ~= newZ do succ = step(3) end return succ end
}
moveTo = function(x, y, z, order, disableAutocorrect) -- move to exact coordinates
    if border and y < border then
        y = border
    end
    local validOrder = order and #order == 3
    local dirsMoved = {}
    local moved, funcIndex
    for i=1,3 do
        funcIndex = validOrder and order[i] or i
        moved = moveDirFuncs[funcIndex]( (funcIndex == 1 and y) or (funcIndex == 2 and x) or (funcIndex == 3 and z))
        if moved then
            table.insert(dirsMoved, funcIndex)
        else
            break    
        end
    end
    --[=[local tdirsMoved = #dirsMoved --total directions moved
    if disableAutocorrect~=true and not moved and tdirsMoved < 3 then --if movement failed, try again, funcIndex is the direction it failed on
        local original_ignore_check, ignore_check = ignore_check, true
        if funcIndex == 1 then
            --failed to move vertically in the desired direction, if up could try down, if down could try up
            --if can't do up or down, try side to side on X and if that doesn't work, try side to side on Z, if that doesn't work then report failure (5 or so times)
            report("failed to "..tostring(x)..", "..tostring(y)..", "..tostring(z).." faulted on Y axis, attempting to compensate.")
            local wiggle = {1,0,0, -1,0,0, 0,0,1, 0,0,-1, 0,y < Y and 1 or 0,0 ,0,-1,0}
            if wiggle[14] == 1 then wiggle[17] = 0 end
            local attemptCount = 0
            --alternative
            --[[
                moved = step(opposite of the failed directionup)
                if not moved then
                    for i=1,6 do --if not moved
                        --turn manually here
                        moved = step(1) -- try to move forward, I think 1 is forward
                        if moved then break end
                    end
                end
            ]]
            repeat --try to wiggle out
                local wiggleIndex = attemptCount * 3 + 1
                attemptCount = attemptCount + 1
                local xOff,yOff,zOff = wiggle[wiggleIndex], wiggle[wiggleIndex+1], wiggle[wiggleIndex+2]
                if math.abs(xOff)+math.abs(yOff)+math.abs(zOff) > 0 then
                    local returnstr = "attempt number "..tostring(attemptCount).." coordinates: "..tostring(X + xOff)..", "..tostring(Y + yOff)..", "..tostring(Z + zOff)
                    moved = moveTo(X + xOff, Y + yOff, Z + zOff, nil, true)
                    report(returnstr.. " = "..tostring(moved))
                end
            until attemptCount == 6 or moved
            
            --fails if it tries to move down without changing X or Z, need to do +- on x and z until one of them works
            --if all fail, try to move up, and if that fails report the robot is completely stuck (idk how this could happen)
        elseif (funcIndex == 2 or funcIndex == 3) then --if failed on x or z 
            --and didn't try to move up, then move up
            local unstuckAttempt = moveTo(x,y+1,z,nil,true) --try up and down first
            local returnstr = "failed to move on "..(funcIndex == 2 and "X" or "Z").." axis, attempting to autocorrect by moving up.."
            if not unstuckAttempt then
                unstuckAttempt = moveTo(x,y-1,z,nil,true)
                if not unstuckAttempt then
                    returnstr = returnstr.." tried to move down and failed, autocorrect failed."
                else
                    returnstr = returnstr.." autocorrect successful."
                end
            else
                returnstr = returnstr.." successfully moved upwards."
            end
            moved = unstuckAttempt
            report(returnstr)
        end
        ignore_check = original_ignore_check
    end]=]
    if not disableAutocorrect and not moved then --still hasn't moved
        report("failed to move from ("..tostring(X)..", "..tostring(Y)..", "..tostring(Z)..") to ("..tostring(x)..", "..tostring(y)..", "..tostring(z)..") on funcIndex "..tostring(funcIndex))
    end
    return moved
end

scan = function(xx, zz) -- scan square 8*8 relative to robot
    local raw, index = geolyzer.scan(xx, zz, -1, 8, 8, 1), 1 -- get raw data, set the index to the beginning of the table
    for z = zz, zz + 7 do -- z-data sweep
        for x = xx, xx + 7 do -- x-data sweep
            if raw[index] >= hardness[1] and raw[index] <= hardness[2] then -- if a block with a suitable hardness is found
                table.insert(WORLD.x, X + x) --| write mark to the list
                table.insert(WORLD.y, Y - 1) --| with correction of local
                table.insert(WORLD.z, Z + z) --| coordinates of geoscanner
            elseif raw[index] < -0.31 then -- if a negative hardness block is detected
                border = Y -- write mark
            end
            index = index + 1 -- mowe to next raw data index
        end
    end
end

calibration = function()
    -- calibrate on startup
    if not controller then -- check for inventory controller
        report("inventory controller not detected", true)
    elseif not geolyzer then -- check for geoscanner
        report("geolyzer not detected", true)
    elseif not robot.detect(0) then
        report("bottom solid block is not detected", true)
    elseif not robot.durability() then
        report("there is no suitable tool in the manipulator", true)
    end
    local clist = computer.getDeviceInfo()
    for i, j in pairs(clist) do
        if j.description == "Solar panel" then
            solar = true
            break
        end
    end
    if chunkloader then -- check the chunkloader
        chunkloader.setActive(true) -- turn on
    end
    if modem then -- check modem
        modem.open(port)
        modem.setWakeMessage("") -- set wake message
        modem.setStrength(400) -- set signal strength
        report("waiting for instructions")
        for i=1,3 do computer.beep() end
        local e = {computer.pullSignal(1)}
        if e[1] == "modem_message" then --6: wake, 7: code, 8:newport
            penpal = e[3]
            sleep(0.1)
            report("link established "..penpal)
            for i=1,3 do computer.beep() end
        end
        ----broadcast waiting for orders, pull for a couple seconds, listener for command to dig, then set penpal to the sender
    elseif tunnel then -- check tunnel card
        tunnel.setWakeMessage("") -- set wake message
    end
    for slot = 1, inventory do -- check inventory
        if robot.count(slot) == 0 then -- if slot is empty
            currentSlot = robot.select(slot) -- select slot
            break
        end
    end
    local energy = computer.energy() -- check energy level
    moveTo(0,-1,0) -- сделать шаг
    E_C = math.ceil(energy - computer.energy()) -- write consumption level
    energy = robot.durability() -- get the wear/discharge rate of the tool
    while energy == robot.durability() do -- while is no difference
        robot.place(3) -- place block
        swing(3) -- mine block
    end
    W_R = energy - robot.durability() -- write result
    local sides = {2, 1, 3, 0} -- link sides, for raw data
    D = nil -- direction reset
    for s = 1, #sides do -- check all directions
        if robot.detect(3) or robot.place(3) then -- check block before mine
            local A = geolyzer.scan(-1, -1, 0, 3, 3, 1) -- do first scan
            swing(3) -- mine block
            local B = geolyzer.scan(-1, -1, 0, 3, 3, 1) -- do second scan
            for n = 2, 8, 2 do -- check adjacent blocks in the table
                if math.ceil(B[n]) - math.ceil(A[n]) < 0 then -- if block is gone
                    D = sides[n / 2] -- set new direction
                    break -- break cycle
                end
            end
        else
            turn() -- make simple rotation
        end
    end
    if not D then
        report("calibration error", true)
    else
        report("calibration finished.")
    end
end

inv_check = function()
    -- inventory check
    if ignore_check or not should.invCheck then
        return
    end
    should.invCheck = false --already done
    local items = 0
    for slot = 1, inventory do
        if robot.count(slot) > 0 then
            items = items + 1
        end
    end
    if inventory - items < 10 or items / inventory > 0.9 then
        dump()
        items = 0
        for slot = 1, inventory do
            if robot.count(slot) > 0 then
                items = items + 1
            end
        end
        --while suck(1) do end --why?
        if inventory - items < 10 or items / inventory > 0.9 then
            home(true)
        end
    end
end

dump = function(available) --available is table
    local empty = 0
    for slot = 1, inventory do -- check inventory
        local item = controller.getStackInInternalSlot(slot) -- get item info
        if item then -- if item exists
            local name = item.name:gsub("%g+:", "")
            if fodder[name] then -- check for a match on the trash list
                currentSlot = robot.select(slot) -- select slot
                robot.drop(0) -- drop to trash
                empty = empty + 1 -- update counter
            elseif fragments[name] and available then -- if there is a match in the fragment list
                if available[name] then -- if a counter has already been created
                    available[name] = available[name] + item.size -- update count
                else
                    available[name] = item.size -- create counter for name
                end
            end
        else -- get empty slot
            empty = empty + 1 -- update counter
        end
    end
    return empty
end

sorter = function(pack) -- sort inventory
    swing(0) -- make room for trash
    swing(1) -- make room for buffer
    ------- clear trash -------
    local empty, available = 0, {} -- create a counter of empty slots and available for packing
    empty = dump(available)
    -- packing --
    if crafting and (empty < 12 or pack) then -- if there is a workbench and less than 12 free slots or forced packing is true
        -- transferring unnecessary items to the buffer --
        if empty < 10 then -- if less than 10 free slots
            empty = 10 - empty -- increase the number of empty countdown slots
            for slot = 1, inventory do -- check inventory
                local item = controller.getStackInInternalSlot(slot)
                if item then -- if slot is not empty
                    if not wlist[item.name] then -- name-checking to make sure don't drop an important item into the lava.
                        local name = item.name:gsub("%g+:", "") -- format name
                        if available[name] then -- if there's one in the counter
                            available[name] = available[name] - item.size -- update counter
                        end
                        currentSlot = robot.select(slot) -- select slot
                        robot.drop(1) -- buffer
                        empty = empty - 1 -- update counter
                    end
                end
                if empty == 0 then -- if slot is free
                    break
                end
            end
        end
        ------- main craft cycle -------
        for o, m in pairs(available) do
            if m > 8 then
                for l = 1, math.ceil(m / 576) do
                    inv_check()
                    -- clear working zone --
                    for i = 1, 9 do -- check workbench slots
                        if robot.count(workbench[i]) > 0 then -- if not empty
                            currentSlot = robot.select(workbench[i]) -- select slot
                            for slot = 4, inventory do -- inventory overrun
                                if slot == 4 or slot == 8 or slot > 11 then -- exclude workbench slots
                                    robot.transferTo(slot) -- try to move items
                                    if robot.count(slot) == 0 then -- if slot freed
                                        break
                                    end
                                end
                            end
                            if robot.count() > 0 then -- if an overload is detected
                                while suck(1) do
                                end -- take items from buffer
                                return -- stop packing
                            end
                        end
                    end
                    for slot = 4, inventory do -- fragment search loop
                        local item = controller.getStackInInternalSlot(slot) -- get item info
                        if item and (slot == 4 or slot == 8 or slot > 11) then -- if item outside working zone is exists
                            if o == item.name:gsub("%g+:", "") then -- if item is same
                                currentSlot = robot.select(slot) -- select slot when get match
                                for n = 1, 10 do -- workbench filling cycle
                                    robot.transferTo(workbench[n % 9 + 1], item.size / 9) -- divide the current stack into 9 pieces and move it to the workbench.
                                end
                                if robot.count(1) == 64 then -- reset when workbench is full
                                    break
                                end
                            end
                        end
                    end
                    currentSlot = robot.select(inventory) -- select last inventory slot
                    crafting.craft() -- craft block
                    -- leftover sort cycle
                    for A = 1, inventory do -- main cycle
                        local size = robot.count(A) -- get item count
                        if size > 0 and size < 64 then -- if the slot is neither empty nor full.
                            for B = A + 1, inventory do -- match cycle
                                if robot.compareTo(B) then -- if items the same
                                    currentSlot = robot.select(A) -- select slot
                                    robot.transferTo(B, 64 - robot.count(B)) -- move until fill
                                end
                                if robot.count() == 0 then -- when a slot is free
                                    break -- stop match
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    while suck(1) do
    end --- get items from buffer
    inv_check()
end

home = function(forcibly, interrupt) -- return to the starting point and drop the loot
    local x, y, z, d
    local currentChunkEntry = chunkEntries[currentChunk]
    --print("currentChunk",currentChunk, currentChunkEntry)
    report("Returning home for ore unloading.")
    ignore_check = true
    local enderchest  -- reset enderchest slot
    for slot = 1, inventory do -- scan inventory
        local item = controller.getStackInInternalSlot(slot) -- get slot info
        if item then -- if item exists
            if item.name == "enderstorage:ender_storage" then -- if this is enderchest
                enderchest = slot -- specify slot
                break -- stop search
            end
        end
    end
    if enderchest and not forcibly then -- if there's a enderchest and no forced return home.
        -- step(1) -- move up
        swing(3) -- make room for the chest
        currentSlot = robot.select(enderchest) -- select chest
        robot.place(3) -- place chest
    else
        x, y, z, d = X, Y, Z, D
        if currentChunk~=1 then
            moveTo(currentChunkEntry[1], currentChunkEntry[2], currentChunkEntry[3], returnHomeOrder) 
        end
        moveTo(0,entryHeight,0, returnHomeOrder) 
        moveTo(0,0,0)
    end
    --sorter() -- inventory slot
    local size = nil -- reset container size
    while true do -- go to endless loop
        for side = 1, 4 do -- container search
            size = controller.getInventorySize(3) -- get inventory size
            if size and size > 26 then -- if container found
                break -- stop search
            end
            turn() -- rotate
        end
        if not size or size < 26 then -- if container not found
            report("container not found") -- send message
            sleep(30)
        else
            break -- continue work
        end
    end
    for slot = 1, inventory do -- check whole inventory
        local item = controller.getStackInInternalSlot(slot)
        if item then -- если слот не пуст
            if not wlist[item.name] then -- if item is not in white list
                currentSlot = robot.select(slot) -- select slot
                local a, b = robot.drop(3) -- drop to container
                if not a and b == "inventory full" then -- if container is full
                    while not robot.drop(3) do -- wait until he's free
                        report(b) -- send message
                        sleep(30) -- wait
                    end
                end
            end
        end
    end
    if crafting then -- if there is a workbench, take the items from the chest and pack them up
        for slot = 1, size do -- container slot traversal
            local item = controller.getStackInSlot(3, slot) -- get item info
            if item then -- if item exists
                if fragments[item.name:gsub("%g+:", "")] then -- if match
                    controller.suckFromSlot(3, slot) -- take items
                end
            end
        end
        sorter(true) -- pack
        for slot = 1, inventory do -- check whole inventory
            local item = controller.getStackInInternalSlot(slot)
            if item then -- если слот не пуст
                if not wlist[item.name] then -- if item is not in white list
                    currentSlot = robot.select(slot) -- select slot
                    robot.drop(3) -- drop to container
                end
            end
        end
    end
    if generator and not forcibly then -- if generator exists
        for slot = 1, size do -- scan container
            local item = controller.getStackInSlot(3, slot) -- get item info
            if item then -- if item exists
                if item.name:sub(11, 15) == "coal" then -- if item is coal
                    controller.suckFromSlot(3, slot) -- get
                    break -- break cycle
                end
            end
        end
    end
    if forcibly then
        report("Tool search in container")
        local toolDurability, toolDesc = robot.durability() --fix later
        if robot.durability() < 0.3 then -- if the strength of the tool is less than 30%
            currentSlot = robot.select(1) -- select 1 slot
            controller.equip() -- move tool to inventory
            local tool = controller.getStackInInternalSlot(1) -- get tool info
            for slot = 1, size do
                local item = controller.getStackInSlot(3, slot)
                if item then
                    if item.name == tool.name and item.damage < tool.damage then
                        robot.drop(3)
                        controller.suckFromSlot(3, slot)
                        break
                    end
                end
            end
            controller.equip() -- equip
        end
        if robot.durability() < 0.3 then -- if the instrument has not been replaced by a better one
            report("Attempting to repair tool...")
            for side = 1, 3 do -- check all sides
                local name = controller.getInventoryName(3) -- gei invenory name
                if name == "opencomputers:charger" or name == "tile.oc.charger" then -- check name
                    currentSlot = robot.select(1) -- select slot
                    controller.equip() -- equip
                    if robot.drop(3) then -- if can get the tool into the charger
                        local charge = controller.getStackInSlot(3, 1).charge
                        local max_charge = controller.getStackInSlot(3, 1).maxCharge
                        while true do
                            sleep(30)
                            local n_charge = controller.getStackInSlot(3, 1).charge -- get charge info
                            if charge then
                                if n_charge == max_charge then
                                    suck(3) -- get item
                                    controller.equip() -- equip
                                    break -- stop charging
                                else
                                    report("tool is " .. math.floor((n_charge + 1) / max_charge * 100) .. "% charged")
                                end
                            else -- if the tool is not repairable
                                report("tool could not be charged", true) -- stop
                            end
                        end
                    else
                        report("tool could not be repaired", true) -- stop
                    end
                else
                    turn() -- rotate
                end
            end
            while robot.durability() < 0.3 do
                report("need a new tool")
                sleep(30)
            end
        end
    end
    if enderchest and not forcibly then
        swing(3) -- get chest
    else
        while energy_level() < 0.98 do -- wait until battery is full
            report("charging")
            sleep(30)
        end
    end
    ignore_check = nil
    if not interrupt then --return to previous
        report("return to work in chunk "..tostring(currentChunk).." at coordinates "..tostring(x)..", "..tostring(y)..", "..tostring(z))
        --adjust for chunk entry
        moveTo(0,entryHeight,0) 
        if currentChunk~=1 then
            moveTo(currentChunkEntry[1], currentChunkEntry[2], currentChunkEntry[3])
        end
        moveTo(x, y, z)
        smart_turn(d)
    end
end
--(?) need to make it move to the top of the chunks when starting a new chunk, and return to the top of each one, and then return to the top of the center chunk 
main = function()
    if currentChunk == 1 or (X == chunkdata[1] and Y == chunkdata[2] and Z == chunkdata[3]) then --at the chunk entry point
        border = nil
        while not border do --seems to sometimes prematurely conclude and move to next chunk
            moveTo(X, Y-1, Z) --kind of an issue, if it finds something it can't handle, it just quits before it starts
            for q = 1, 4 do
                scan(table.unpack(quads[q]))
            end
            check(true)
        end
    end
    while #WORLD.x ~= 0 do
        local n_delta, c_delta, current = math.huge, math.huge
        for index = 1, #WORLD.x do
            n_delta =
                math.abs(X - WORLD.x[index]) + math.abs(Y - WORLD.y[index]) + math.abs(Z - WORLD.z[index]) - border +
                WORLD.y[index]
            if
                (WORLD.x[index] > X and D ~= 3) or (WORLD.x[index] < X and D ~= 1) or (WORLD.z[index] > Z and D ~= 0) or
                    (WORLD.z[index] < Z and D ~= 2)
             then
                n_delta = n_delta + 1
            end
            if n_delta < c_delta then
                c_delta, current = n_delta, index
            end
        end
        if WORLD.x[current] == X and WORLD.y[current] == Y and WORLD.z[current] == Z then
            remove_point(current)
        else
            local yc = WORLD.y[current]
            if yc - 1 > Y then
                yc = yc - 1
            elseif yc + 1 < Y then
                yc = yc + 1
            end
            moveTo(WORLD.x[current], yc, WORLD.z[current])
        end
    end
    sorter()
end

local _O, _I, _A, finished = 1,1,1, false --keeps track in case of error
result = {xpcall(calibration, debug.traceback)}
if #result > 0 and result[1]~=true then
    for i,v in ipairs (result) do result[i] = tostring(v) end
    report("Calibration failure: "..table.concat(result, ", "))
    return
end

calibration = nil -- free the memory from the calibration function
local Tau = computer.uptime() -- get current time

function digOperation()
    for o = _O, 10 do -- spiral boundary cycle
        _O = o
        if finished then break end
        for i = _I, 2 do -- coordinate update cycle
            _I = i
            if finished then break end
            for a = _A, o do -- spiral cycle
                _A = a
                if finished then break end
                chunkdata = chunkEntries[currentChunk]
                report("Started working on chunk "..tostring(currentChunk).." at coordinates "..tostring(chunkdata[1])..", "..tostring(chunkdata[2])..", "..tostring(chunkdata[3]))
                main() -- start the scanning and mining function
                posData[i], posData[3] = posData[i] + posData[0], posData[3] + 1 -- update coordinates
                if posData[3] == chunks then -- if the last chunk is reached, should be if posData[3] > chunks I think
                    finished = true
                    home(true, true) -- go home
                    report(computer.uptime() - Tau .. " seconds\npath length: " .. steps .. "\nmade turns: " .. turns, true) -- report the completion of work
                else
                    WORLD = {x = {}, y = {}, z = {}}
                    moveTo(chunkdata[1], chunkdata[2], chunkdata[3], returnHomeOrder)
                    currentChunk = posData[3] + 1
                    chunkdata = {posData[1] * 16, entryHeight, posData[2] * 16} --needs fixing, seems to be busted
                    chunkEntries[currentChunk] = chunkdata
                    --print("set current chunk data of chunk "..tostring(posData[3]).." to ",chunkEntries[posData[3]])
                    --sleep(10)
                    moveTo(chunkdata[1], chunkdata[2], chunkdata[3], returnHomeOrder) -- go to next chunk
                end
            end
            _A = 1
        end
        _I = 1
        posData[0] = 0 - posData[0] -- update spiral rotation direction
    end
    if finished then _O = 1 end
end

while not finished do
    result = {xpcall(digOperation, debug.traceback)}
    for i,v in ipairs (result) do result[i] = tostring(v) end
    report("Dig Operation error: "..table.concat(result, ", "))
end