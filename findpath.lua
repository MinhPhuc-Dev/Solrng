local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local player = Players.LocalPlayer

-- Guard: this file must run as a LocalScript on the client
if not player then
    warn("[Check_hinder] LocalPlayer is nil. Make sure this code runs in a LocalScript (StarterPlayerScripts, StarterCharacterScripts, PlayerGui, etc.). Stopping.")
    return
end

-- Khởi tạo các biến cơ bản, đợi nhân vật sẵn sàng
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local root = character:WaitForChild("HumanoidRootPart")
local mouse = player:GetMouse()

local function Check_hinder()
    -- Kiểm tra xem có chướng ngại vật giữa hai điểm không
    --
    -- Tính năng chính:
    -- 1) Khi được gọi với một Path (waypoints), hàm sẽ giả lập 1 "hitbox" di chuyển dọc theo đường
    --    (sử dụng sampling + Workspace:GetPartBoundsInBox) để kiểm tra có part nào chắn đường không.
    -- 2) Nếu gặp chướng ngại (impassable) sẽ thử tính phương án nhảy (so sánh chiều cao) hoặc
    --    thử tính lại đường đi bằng cách né phần chướng ngại (offset points). Lặp tối đa một số lần.
    -- 3) Trả về một path hợp lệ (waypoints) hoặc nil nếu không tìm được đường.

    -- NOTE: Một số check là xấp xỉ / best-effort vì Roblox không expose mọi thông tin (Debris list,
    -- collision group không-trực-tiếp). Tôi cố gắng xử lý CollisionFidelity, CanCollide, mesh parts, v.v.

    local RunService = game:GetService("RunService")
    local PathfindingService = game:GetService("PathfindingService")
    local Workspace = game:GetService("Workspace")
    local PhysicsService = pcall(function() return game:GetService("PhysicsService") end) and game:GetService("PhysicsService") or nil

    local character = player.Character or player.CharacterAdded:Wait()
    local humanoid = character:WaitForChild("Humanoid")
    local hrp = character:WaitForChild("HumanoidRootPart")

    local AGENT_RADIUS = 2 -- radius for pathfinding sampling and offset tries
    local SAMPLE_STEP = 1 -- studs between sampling points on path
    local MAX_ATTEMPTS = 6 -- max reroute attempts

    -- LOGGING / DEBUG
    local VERBOSE = true -- set to true to enable detailed logs
    local LOG_PREFIX = "[Check_hinder]"
    local function ts()
        return os.date("%H:%M:%S")
    end
    local function logInfo(...)
        if VERBOSE then
            local args = {...}
            -- build message manually because table.concat on mixed types is tricky
            -- build message manually because table.concat on mixed types is tricky
            local parts = {}
            for i = 1, #args do
                parts[#parts + 1] = tostring(args[i])
            end
            print(LOG_PREFIX .. " " .. ts() .. " [INFO] " .. table.concat(parts, " "))
        end
    end
    local function logWarn(...)
        local args = {...}
        local parts = {}
        for i = 1, #args do parts[#parts + 1] = tostring(args[i]) end
        warn(LOG_PREFIX .. " " .. ts() .. " [WARN] " .. table.concat(parts, " "))
    end

    -- HUD logger so client can see messages without opening the Developer Console
    local function makeHud()
        local playerGui = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui", 5)
        if not playerGui then return nil end
        local g = playerGui:FindFirstChild("CheckHinder_HUD")
        if g then return g end
        local screen = Instance.new("ScreenGui")
        screen.Name = "CheckHinder_HUD"
        screen.ResetOnSpawn = false
        screen.Parent = playerGui

        local frame = Instance.new("Frame")
        frame.Size = UDim2.new(0, 420, 0, 140)
        frame.Position = UDim2.new(0, 10, 0, 10)
        frame.BackgroundTransparency = 0.35
        frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
        frame.BorderSizePixel = 0
        frame.Parent = screen

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -12, 0, 22)
        title.Position = UDim2.new(0, 6, 0, 6)
        title.BackgroundTransparency = 1
        title.Text = "Check_hinder logs"
        title.Font = Enum.Font.SourceSansSemibold
        title.TextSize = 14
        title.TextColor3 = Color3.fromRGB(240,240,240)
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = frame

        local logLabel = Instance.new("TextLabel")
        logLabel.Name = "LogBox"
        logLabel.Size = UDim2.new(1, -12, 1, -36)
        logLabel.Position = UDim2.new(0, 6, 0, 30)
        logLabel.BackgroundTransparency = 1
        logLabel.Text = ""
        logLabel.ClipsDescendants = true
        logLabel.TextWrapped = true
        logLabel.TextYAlignment = Enum.TextYAlignment.Top
        logLabel.Font = Enum.Font.SourceSans
        logLabel.TextSize = 12
        logLabel.TextColor3 = Color3.fromRGB(210,210,210)
        logLabel.Parent = frame

        return screen
    end

    local HUD = makeHud()
    local function hudLog(line)
        if not HUD then return end
        local frame = HUD:FindFirstChildWhichIsA("Frame") or HUD:FindFirstChild("Frame")
        if not frame then frame = HUD:FindFirstChild("Check_hinder_HUD") end
        if not frame then return end
        local box = frame:FindFirstChild("LogBox")
        if not box then return end
        local text = tostring(box.Text)
        -- prepend new message
        box.Text = line .. "\n" .. text
    end

    -- extend log handlers to write to HUD as well
    local _logInfo = logInfo
    logInfo = function(...)
        _logInfo(...)
        local parts = {}
        local args = {...}
        for i = 1, #args do parts[#parts + 1] = tostring(args[i]) end
        hudLog(LOG_PREFIX .. " " .. ts() .. " [I] " .. table.concat(parts, " "))
    end
    local _logWarn = logWarn
    logWarn = function(...)
        _logWarn(...)
        local parts = {}
        local args = {...}
        for i = 1, #args do parts[#parts + 1] = tostring(args[i]) end
        hudLog(LOG_PREFIX .. " " .. ts() .. " [W] " .. table.concat(parts, " "))
    end


    -- internal helper: draw debug markers for a path (small neon parts)
    local debugParts = {}
    local function clearDebug()
        for _, p in ipairs(debugParts) do p:Destroy() end
        debugParts = {}
    end
    local function drawDebugPath(points, color)
        clearDebug()
        for i, v in ipairs(points) do
            local part = Instance.new("Part")
            part.Anchored = true
            part.CanCollide = false
            part.Size = Vector3.new(0.4, 0.4, 0.4)
            part.Material = Enum.Material.Neon
            part.Color = color or Color3.fromRGB(0, 255, 0)
            part.CFrame = CFrame.new(v) * CFrame.new(0, 0.2, 0)
            part.Parent = Workspace
            table.insert(debugParts, part)
        end
    end

    -- Tạo một hitbox theo dõi nhân vật (dùng Heartbeat để update) — để debug hoặc dùng làm cơ sở tính toán
    local followHitbox = Instance.new("Part")
    followHitbox.Name = "CheckHinder_Hitbox"
    followHitbox.Anchored = true
    followHitbox.CanCollide = false
    followHitbox.Transparency = 0.8
    followHitbox.Size = Vector3.new(2, 2, 2)
    followHitbox.Material = Enum.Material.ForceField
    followHitbox.Color = Color3.fromRGB(255, 200, 50)
    followHitbox.Parent = Workspace

    local hbConn
    hbConn = RunService.Heartbeat:Connect(function()
        if followHitbox and followHitbox.Parent and hrp and hrp.Parent then
            local s = hrp.Size
            followHitbox.Size = Vector3.new(math.max(1.2, s.X), math.max(1.6, s.Y), math.max(1.2, s.Z))
            followHitbox.CFrame = hrp.CFrame
        else
            if hbConn then hbConn:Disconnect() end
        end
    end)

    -- startup message
    logInfo("Check_hinder initialized. VERBOSE=", VERBOSE)

    -- utility: take a Path object and return a flat table of Vector3 waypoints
    local function pathToPoints(path)
        local pts = {}
        if not path then return pts end
        for _, w in ipairs(path:GetWaypoints()) do
            table.insert(pts, w.Position)
        end
        return pts
    end

    -- utility: sample points along sequence of waypoints (returns table of Vector3)
    local function sampleAlongWaypoints(points, step)
        step = step or SAMPLE_STEP
        local samples = {}
        for i = 1, #points - 1 do
            local a = points[i]
            local b = points[i+1]
            local dir = (b - a)
            local dist = dir.Magnitude
            local unit = dir.Unit
            local s = 0
            while s < dist do
                table.insert(samples, a + unit * s)
                s = s + step
            end
        end
        table.insert(samples, points[#points])
        return samples
    end

    -- check if a part is considered passable/unsafe and return reason
    local function analyzePart(part)
        if not part or not part:IsA("BasePart") then
            return false, "not_basepart"
        end

        if part:IsDescendantOf(character) then
            return false, "self"
        end

        -- If CanCollide false, treat as passable (but may still be visual only)
        if not part.CanCollide then
            return false, "not_collidable"
        end

        -- Mesh/Collision fidelity heuristics
        if part:IsA("MeshPart") and part.CollisionFidelity ~= Enum.CollisionFidelity.PreciseConvexDecomposition then
            -- If collision hull is Box/Hull the real shape may have holes -> mark uncertain
            return true, "uncertain_collision_fidelity"
        end

        -- Check for transparency or other visual-only parts (still may collide if CanCollide true)
        if part.Transparency >= 0.95 then
            -- extremely transparent parts are often decorative, but still might have CanCollide true - we handle via CanCollide above
            return true, "transparent_but_collidable"
        end

        -- A general 'solid' part blocking path
        return true, "solid_block"
    end

    -- uses GetPartBoundsInBox to see which parts overlap a centered box
    local function partsTouchingBox(cframe, size, ignoreList)
        ignoreList = ignoreList or {character}
        local ok, result = pcall(function()
            return Workspace:GetPartBoundsInBox(cframe, size, ignoreList)
        end)
        if not ok then return {} end
        return result
    end

    -- estimate if player can jump over a part by comparing top heights
    local function canJumpOver(part)
        -- top Y of part
        local topY = part.Position.Y + (part.Size.Y / 2)
        -- estimate player's feet y from HumanoidRootPart center (approx)
        local playerFeetY = hrp.Position.Y - (hrp.Size.Y / 2) - (humanoid.HipHeight or 1)
        -- maximum jump height
        local maxJumpHeight = humanoid.JumpHeight or ( (humanoid.JumpPower and humanoid.JumpPower^2 / (2 * workspace.Gravity)) or 5 )
        local requiredClear = topY - playerFeetY
        -- small buffer
        return requiredClear <= (maxJumpHeight + 0.6), requiredClear
    end

    -- Try to compute and verify a path; return verified points or nil.
    local function computeAndVerify(startPos, targetPos)
            logInfo("computeAndVerify start ->", tostring(startPos), tostring(targetPos))
        local path = PathfindingService:CreatePath({AgentRadius = AGENT_RADIUS, AgentHeight = 5, AgentCanJump = true})
        path:ComputeAsync(startPos, targetPos)
        if path.Status ~= Enum.PathStatus.Success then
                        logWarn("path compute failed: status=", tostring(path.Status))
            return nil, "path_failed"
        end

        local points = pathToPoints(path)
        if #points < 2 then
            logWarn("path produced too few waypoints (#" .. tostring(#points) .. ")")
            return nil, "no_waypoints"
        end

        -- debug draw
        drawDebugPath(points, Color3.fromRGB(0, 150, 255))
    logInfo("path computed ok, waypoints=", #points)

        -- create a virtual hitbox size roughly player footprint
        local hbSize = Vector3.new(hrp.Size.X * 1.1, hrp.Size.Y * 0.9, hrp.Size.X * 1.4)
        local samples = sampleAlongWaypoints(points, SAMPLE_STEP)
        for _, spos in ipairs(samples) do
            local cframe = CFrame.new(spos)
            local touching = partsTouchingBox(cframe, hbSize)
            for _, p in ipairs(touching) do
                if not p:IsDescendantOf(character) then
                    local blocked, reason = analyzePart(p)
                    if blocked then
                        logWarn("blocked at sample=" .. tostring(spos) .. " by part=" .. p:GetFullName() .. " reason=" .. tostring(reason) .. " CanCollide=" .. tostring(p.CanCollide) .. " Transparency=" .. tostring(p.Transparency))
                        if p:IsA("MeshPart") and p.CollisionFidelity then
                            logInfo("meshpart collision fidelity=" .. tostring(p.CollisionFidelity))
                        end
                        return false, {part = p, at = spos, reason = reason}
                    end
                end
            end
        end

        return points, "ok"
    end

    -- reroute by sampling offset points around blocking location (circle)
    local function tryReroute(startPos, targetPos, blocker)
        -- candidate offsets: vary radii and angles
        local radii = {AGENT_RADIUS * 1.2, AGENT_RADIUS * 2.0, AGENT_RADIUS * 3.0}
        local angles = {0, math.pi/4, -math.pi/4, math.pi/2, -math.pi/2, math.pi * 3/4, -math.pi * 3/4}
        local attempts = {}
        for _, r in ipairs(radii) do
            for _, a in ipairs(angles) do
                -- compute candidate around blocker
                local dir = Vector3.new(math.cos(a), 0, math.sin(a))
                local candidate = blocker + dir * r
                candidate = Vector3.new(candidate.X, targetPos.Y, candidate.Z) -- keep Y workable
                table.insert(attempts, candidate)
            end
        end

            for idx, candidate in ipairs(attempts) do
                logInfo("tryReroute: candidate #" .. tostring(idx) .. " -> " .. tostring(candidate))
            -- attempt two-phase route: start -> candidate -> target
            local p1, s1 = computeAndVerify(startPos, candidate)
            if p1 then
                local p2, s2 = computeAndVerify(candidate, targetPos)
                if p2 then
                    -- combine
                    local combined = {}
                    for _, v in ipairs(p1) do table.insert(combined, v) end
                    for _, v in ipairs(p2) do table.insert(combined, v) end
                    return combined
                end
            end
        end

        return nil
    end

    -- The main algorithm: try basic path and iterative rerouting when we hit blockers
    local function findBestPath(startPos, targetPos)
        local attempts = 0
        local currentStart = startPos
        while attempts < MAX_ATTEMPTS do
            logInfo("findBestPath attempt " .. tostring(attempts + 1))
            local pts, reason = computeAndVerify(currentStart, targetPos)
            if pts and type(pts) == "table" then
                logInfo("findBestPath: verified path found (#" .. tostring(#pts) .. ")")
                return pts
            else
                if type(reason) == "table" and reason.part then
                    logWarn("findBestPath blocked by part=" .. reason.part:GetFullName() .. " reason=" .. tostring(reason.reason or reason))
                    -- check if can jump
                    local mayJump, req = canJumpOver(reason.part)
                    if mayJump then
                        logInfo("blocker looks jumpable (requiredClear=" .. tostring(req) .. ") - will try fallback path or allow mover to jump")
                        -- in many cases MoveTo + humanoid.Jump will let player cross it
                        -- We'll still return the original path points and let the mover handle the jump
                        local fallbackPath = PathfindingService:CreatePath({AgentRadius = AGENT_RADIUS})
                        fallbackPath:ComputeAsync(startPos, targetPos)
                        if fallbackPath.Status == Enum.PathStatus.Success then
                            return pathToPoints(fallbackPath)
                        end
                    end

                    -- try reroute avoiding detected part
                    logInfo("Attempting reroute around blocker at " .. tostring(reason.at or reason.part.Position))
                    local reroute = tryReroute(currentStart, targetPos, reason.at or reason.part.Position)
                    if reroute then
                        logInfo("findBestPath: reroute produced path (#" .. tostring(#reroute) .. ")")
                        return reroute
                    end
                end
            end
            attempts = attempts + 1
        end
        logWarn("findBestPath: exhausted attempts, no valid path")
        return nil
    end

    -- public usage: click handler will call findBestPath and then optionally move the player
    -- We'll listen for mouse clicks and demonstrate the behavior.
    local ALLOW_AUTO_MOVE = true

    -- helper: move the character along computed points (supports small jumps if needed)
    local function followPoints(points)
        if not points or #points == 0 then
            logWarn("followPoints called with empty points")
            return
        end
        logInfo("followPoints start -> " .. tostring(#points) .. " points")
        drawDebugPath(points, Color3.fromRGB(60,255,60))
        for i = 1, #points do
            local pos = points[i]
            logInfo("followPoints: moving to #" .. tostring(i) .. " -> " .. tostring(pos))
            -- check vertical delta
            local dy = pos.Y - hrp.Position.Y
            if dy > 1.5 then
                logInfo("followPoints: vertical delta=" .. tostring(dy) .. " -> jump")
                humanoid.Jump = true
            end
            humanoid:MoveTo(pos)
            local moved = humanoid.MoveToFinished:Wait()
            logInfo("followPoints: MoveToFinished -> " .. tostring(moved))
            -- short wait, allow small physics
            wait(0.05)
        end
        logInfo("followPoints finished")
    end

    -- Example: on mouse click compute path, run checks, then move player if possible.
    mouse.Button1Down:Connect(function()
        local target = mouse.Hit.Position
        local start = hrp.Position
        logInfo("mouse click -> start=" .. tostring(start) .. " target=" .. tostring(target))
        local best = findBestPath(start, target)
        if best then
            logInfo("Found safe path with " .. tostring(#best) .. " points")
            if ALLOW_AUTO_MOVE then
                followPoints(best)
            end
        else
            logWarn("Could not find a safe path to target")
        end
    end)

    -- cleanup when script ends
    -- note: debugParts will be cleared next time drawDebugPath called or on destroy

-- Run with pcall to catch errors and produce a visible message
local ok, err = pcall(function()
    Check_hinder()
end)
if not ok then
    warn("[Check_hinder] startup error: " .. tostring(err))
    -- attempt to show in HUD if present
    local ok2, _ = pcall(function()
        local plr = Players.LocalPlayer
        if plr and plr:FindFirstChild("PlayerGui") then
            local gui = plr.PlayerGui:FindFirstChild("CheckHinder_HUD")
            if gui then
                local frame = gui:FindFirstChildWhichIsA("Frame") or gui:FindFirstChild("Frame")
                if frame and frame:FindFirstChild("LogBox") then
                    frame.LogBox.Text = "[Check_hinder] startup error: " .. tostring(err)
                end
            end
        end
    end)
end
