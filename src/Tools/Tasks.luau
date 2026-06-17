--!strict
-- Tasks: the update_tasks tool. The agent maintains a VISIBLE build checklist in the panel by sending
-- the WHOLE list every call (declarative replace, like TodoWrite). The tool is a thin wrapper over the
-- TaskList state held in context.taskList; the agent loop emits the new snapshot to the UI after a
-- batch that ran this tool. Parent-only: it is NOT in the subagent allowlist, and a subagent context
-- carries no taskList, so it no-ops gracefully for a child (defence in depth).

local TaskList = require(script.Parent.Parent.TaskList)

local Tasks = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any, context: any) -> (string, boolean),
}

local function run(input: any, context: any): (string, boolean)
	local taskList = if type(context) == "table" then context.taskList else nil
	if taskList == nil then
		return "update_tasks is not available here (no checklist in this context)", true
	end
	local summary = taskList:set(input)
	local listText = TaskList.render(taskList:snapshot())
	return listText .. "\n" .. summary, false
end

Tasks.descriptors = {
	{
		name = "update_tasks",
		description = "Maintain a VISIBLE build checklist shown to the user in the panel. Send the "
			.. "ENTIRE task list every call (declarative replace, NOT incremental): pass `tasks` as the "
			.. "full ordered list, each { content, status } where status is 'pending', 'in_progress', "
			.. "or 'completed'. Use this for any build of ~3+ steps so the user sees your plan and live "
			.. "progress; skip it for a trivial single step. Mark exactly ONE task 'in_progress' at a "
			.. "time and flip a task to 'completed' the moment its step is done (don't batch). Sending "
			.. "an empty list clears the checklist. This is a visibility aid — it does NOT build "
			.. "anything; you still do the work with the other tools.",
		inputSchema = {
			type = "object",
			properties = {
				tasks = {
					type = "array",
					description = "The full ordered checklist (send ALL tasks every call).",
					items = {
						type = "object",
						properties = {
							content = {
								type = "string",
								description = "Short, outcome-shaped step, e.g. 'Build the inventory grid'.",
							},
							status = {
								type = "string",
								enum = { "pending", "in_progress", "completed" },
								description = "One of pending, in_progress, completed.",
							},
						},
						required = { "content", "status" },
					},
				},
			},
			required = { "tasks" },
		},
		destructive = false,
		run = run,
	},
} :: { Descriptor }

return Tasks
