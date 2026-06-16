local tool = script.Parent
local barrel = tool:WaitForChild("Barrel")

local Type       = script:WaitForChild("Type").Value
local CoolDown   = script:WaitForChild("CoolDown").Value
local ReloadTime = script:WaitForChild("ReloadTime").Value
local MaxAmmo    = script:WaitForChild("Ammo").Value
local Range      = script:WaitForChild("Range").Value
local Damage     = script:WaitForChild("Damage").Value

local Sound1 = barrel:WaitForChild("Shoot")
local Sound2 = barrel:WaitForChild("Reload")
local Sound3 = barrel:WaitForChild("Headshot")
local remote = script:WaitForChild("RemoteEvent")

local SHOTGUN_PELLETS = 8
local SHOTGUN_SPREAD  = 6

local playerState = {}

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

print("[GunServer] Loaded | Type:", Type, "| MaxAmmo:", MaxAmmo, "| Damage:", Damage, "| Range:", Range)

local function getState(player)
	if not playerState[player] then
		playerState[player] = {
			ammo       = MaxAmmo,
			reloading  = false,
			shooting   = false,
			autoFiring = false,
			activating = false,
			lastShot   = 0,
			lastTarget = Vector3.new(0, 0, 0),
		}
	end
	return playerState[player]
end

local function spreadDirection(dir, spreadDeg)
	local angle = math.rad(spreadDeg)
	local rx = (math.random() - 0.5) * 2 * angle
	local ry = (math.random() - 0.5) * 2 * angle
	return (CFrame.Angles(rx, ry, 0) * dir).Unit
end

local function getFilterList(character)
	local filter = {character}
	for _, accessory in ipairs(workspace:GetDescendants()) do
		if accessory:IsA("Accessory") then
			local handle = accessory:FindFirstChild("Handle")
			if handle then
				table.insert(filter, handle)
			end
		end
	end
	return filter
end

local function fireRay(player, character, direction)
	local origin = barrel.WorldPosition
	rayParams.FilterDescendantsInstances = getFilterList(character)

	local rayDir = direction.Unit * Range
	local result = workspace:Raycast(origin, rayDir, rayParams)
	local endPos = result and result.Position or (origin + rayDir)

	remote:FireAllClients("trail", origin, endPos)

	if result and result.Instance then
		local hit = result.Instance
		local isHeadshot = hit.Name == "Head"

		local humanoid = hit.Parent:FindFirstChildOfClass("Humanoid")
			or hit.Parent.Parent:FindFirstChildOfClass("Humanoid")

		if humanoid and humanoid.Parent ~= character then
			local dmg = isHeadshot and (Damage * 2) or Damage
			humanoid:TakeDamage(dmg)
			print("[GunServer] Hit:", humanoid.Parent.Name, "| Damage:", dmg, "| Headshot:", isHeadshot)
			if isHeadshot then Sound3:Play() end
			return true, dmg, isHeadshot, endPos
		end
	end

	return false, 0, false, endPos
end

local function tryReload(state, player)
	if state.reloading or state.ammo > 0 then return end
	state.reloading = true
	print("[GunServer] Reloading for:", player.Name)
	Sound2:Play()
	remote:FireClient(player, "ammo", 0, MaxAmmo)
	task.delay(ReloadTime, function()
		state.ammo = MaxAmmo
		state.reloading = false
		print("[GunServer] Reload complete for:", player.Name)
		remote:FireClient(player, "ammo", MaxAmmo, MaxAmmo)
	end)
end

local function shoot(player, targetPos)
	local state = getState(player)
	if state.reloading then return end
	if state.ammo <= 0 then
		tryReload(state, player)
		return
	end

	local character = player.Character
	if not character then return end

	local origin = barrel.WorldPosition
	local baseDir = (targetPos - origin).Unit

	state.ammo -= 1
	state.lastShot = os.clock()
	Sound1:Play()
	print("[GunServer] Shot fired by:", player.Name, "| Ammo remaining:", state.ammo)
	remote:FireClient(player, "ammo", state.ammo, MaxAmmo)

	if Type == "Semi" or Type == "Auto" then
		local didHit, dmg, isHeadshot, endPos = fireRay(player, character, baseDir)
		if didHit then
			remote:FireClient(player, "hit", endPos, dmg, isHeadshot, false)
		end

	elseif Type == "Shotgun" then
		local totalDmg   = 0
		local anyHead    = false
		local lastEndPos = targetPos

		for _ = 1, SHOTGUN_PELLETS do
			local didHit, dmg, isHeadshot, endPos = fireRay(player, character, spreadDirection(baseDir, SHOTGUN_SPREAD))
			if didHit then
				totalDmg  += dmg
				anyHead    = anyHead or isHeadshot
				lastEndPos = endPos
			end
		end

		if totalDmg > 0 then
			remote:FireClient(player, "hit", lastEndPos, totalDmg, anyHead, true)
		end
	end

	tryReload(state, player)
end

local function startAuto(player)
	local state = getState(player)
	if state.autoFiring then
		print("[GunServer] Auto already firing, ignoring startAuto for:", player.Name)
		return
	end
	state.autoFiring = true
	print("[GunServer] Auto fire started for:", player.Name)
	task.spawn(function()
		while state.autoFiring do
			shoot(player, state.lastTarget)
			task.wait(CoolDown)
		end
		print("[GunServer] Auto fire stopped for:", player.Name)
	end)
end

local function stopAuto(player)
	getState(player).autoFiring = false
end

remote.OnServerEvent:Connect(function(player, targetPos, action)
	local state = getState(player)

	if action == "autohold" then
		state.lastTarget = targetPos
		return
	end

	print("[GunServer] RAW EVENT | Player:", player.Name, "| Action:", action)

	if action == "activate" then
		if state.activating then
			print("[GunServer] Blocked duplicate activate for:", player.Name)
			return
		end
		if (os.clock() - state.lastShot) < CoolDown then
			print("[GunServer] Blocked too-fast reactivate for:", player.Name)
			return
		end
		state.activating = true
		state.lastTarget = targetPos

		if Type == "Semi" or Type == "Shotgun" then
			if not state.shooting then
				state.shooting = true
				shoot(player, targetPos)
				task.delay(CoolDown, function()
					state.shooting = false
				end)
			end
		elseif Type == "Auto" then
			if not state.autoFiring then
				startAuto(player)
			else
				print("[GunServer] Blocked duplicate startAuto for:", player.Name)
			end
		end

	elseif action == "deactivate" then
		state.activating = false
		if Type == "Auto" then
			stopAuto(player)
		end
		state.shooting = false
	end
end)

tool.Unequipped:Connect(function()
	for _, state in pairs(playerState) do
		state.autoFiring = false
		state.shooting   = false
		state.activating = false
		state.lastShot   = 0
	end
end)

game.Players.PlayerRemoving:Connect(function(player)
	playerState[player] = nil
end)