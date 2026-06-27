--!strict
-- NpcBrain: PURE perception logic for the PvE NPC AI (roadmap #5) — no DataModel, no services, directly
-- unit-testable. decideState maps the distance to the nearest living target (+ the NPC's ranges) to one of
-- idle / chase / attack. The impure side (finding the target, MoveTo/TakeDamage, the loop) lives in the
-- generated NpcAI server Script in Tools/Npc. See docs/superpowers/specs/2026-06-26-pve-npc-ai-design.md.

local NpcBrain = {}

-- dist = distance to the nearest LIVING target (nil if none). attackRange wins over chase (closest behavior).
function NpcBrain.decideState(dist: number?, detectRange: number, attackRange: number): string
	if dist == nil then
		return "idle"
	end
	if dist <= attackRange then
		return "attack"
	end
	if dist <= detectRange then
		return "chase"
	end
	return "idle"
end

return NpcBrain
