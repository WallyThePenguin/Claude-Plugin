-- StudioAgentRuntime.GripMotorRuntime -- SERVER-side runtime grip motor (bind_grip_motor).
-- Humanoid:EquipTool welds the Tool into the hand with an UNSCRIPTABLE Weld named "RightGrip";
-- this module swaps that weld for a Motor6D ("AgentGripMotor", same Part0/Part1/C0/C1) the moment
-- it appears, turning the runtime grip into a drivable pose channel (the weapon-as-limb doctrine
-- at RUNTIME -- the Animator matches pose channels by Part1 name, so edit-authored Handle-channel
-- clips drive this joint too). Also implements the SPIN verb (the blocking mechanic): while the
-- Tool's GripSpin attribute is true, C0 rotates about GripSpinAxis at GripSpinSpeed deg/s per
-- Heartbeat; flipping it false restores the rest C0. GripMotorLive mirrors the swap state for
-- probes. Part of the git-versioned runtime library (bump runtime/VERSION on change).

local RunService = game:GetService("RunService")

local GripMotorRuntime = {}

-- Wire the swap + spin onto `Tool`. Non-blocking (connections only); per-tool state in closure.
function GripMotorRuntime.attach(Tool)
	local motor = nil
	local restC0 = nil
	local spinConn = nil

	local function stopSpin()
		if spinConn ~= nil then
			spinConn:Disconnect()
			spinConn = nil
		end
		if motor ~= nil and motor.Parent ~= nil and restC0 ~= nil then
			motor.C0 = restC0 -- return to the rest hold, exactly
		end
	end

	local function startSpin()
		if spinConn ~= nil or motor == nil or motor.Parent == nil then
			return
		end
		local axisName = Tool:GetAttribute("GripSpinAxis")
		local axis = Vector3.xAxis
		if axisName == "Y" then
			axis = Vector3.yAxis
		elseif axisName == "Z" then
			axis = Vector3.zAxis
		end
		spinConn = RunService.Heartbeat:Connect(function(dt)
			if motor == nil or motor.Parent == nil then
				stopSpin()
				return
			end
			local speed = tonumber(Tool:GetAttribute("GripSpinSpeed")) or 720
			motor.C0 = motor.C0 * CFrame.fromAxisAngle(axis, math.rad(speed * dt))
		end)
	end

	local function swapWeld(char)
		local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
		if hand == nil then
			return
		end
		local weld = hand:FindFirstChild("RightGrip") or hand:WaitForChild("RightGrip", 2)
		if weld == nil or not weld:IsA("JointInstance") then
			return -- no engine weld appeared (edit-mode equip or already swapped) -- nothing to do
		end
		local m = Instance.new("Motor6D")
		m.Name = "AgentGripMotor"
		m.Part0 = weld.Part0
		m.Part1 = weld.Part1
		m.C0 = weld.C0
		m.C1 = weld.C1
		weld:Destroy()
		m.Parent = hand
		motor = m
		restC0 = m.C0
		Tool:SetAttribute("GripMotorLive", true)
		if Tool:GetAttribute("GripSpin") == true then
			startSpin()
		end
	end

	Tool.Equipped:Connect(function()
		local char = Tool.Parent
		if char ~= nil then
			-- defer: the RightGrip weld is created around the same frame as Equipped fires
			task.defer(swapWeld, char)
		end
	end)

	Tool.Unequipped:Connect(function()
		stopSpin()
		if motor ~= nil then
			motor:Destroy()
			motor = nil
		end
		restC0 = nil
		Tool:SetAttribute("GripMotorLive", false)
	end)

	Tool:GetAttributeChangedSignal("GripSpin"):Connect(function()
		if Tool:GetAttribute("GripSpin") == true then
			startSpin()
		else
			stopSpin()
		end
	end)

	-- Heal a missed first equip (attached while the Tool is already in a character).
	local char = Tool.Parent
	if char ~= nil and char:FindFirstChildOfClass("Humanoid") ~= nil then
		task.defer(swapWeld, char)
	end
end

return GripMotorRuntime
