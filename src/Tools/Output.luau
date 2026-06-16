--!strict
-- Output: the get_output tool — lets the agent read recent Studio Output (incl. runtime errors,
-- incl. during a playtest) so it can VERIFY its work instead of assuming success. Exports a
-- descriptor list that Tools/init.luau concatenates into the registry.

local HttpService = game:GetService("HttpService")
local Logs = require(script.Parent.Parent.Logs)

local Output = {}

export type Descriptor = {
	name: string,
	description: string,
	inputSchema: { [string]: any },
	destructive: boolean,
	run: (input: any) -> (string, boolean),
}

Output.descriptors = {
	{
		name = "get_output",
		description = "Read recent Studio Output captured from LogService — print/warn AND runtime "
			.. "SCRIPT ERRORS (with messages), including during a playtest. Use this to VERIFY a script "
			.. "you created or edited actually ran without errors before claiming success, and to read "
			.. "its printed output. Set errorsOnly=true for just warnings and errors.",
		inputSchema = {
			type = "object",
			properties = {
				limit = { type = "integer", description = "Max lines to return (default 50)." },
				errorsOnly = {
					type = "boolean",
					description = "Only warnings/errors (default false).",
				},
			},
		},
		destructive = false,
		run = function(input: any): (string, boolean)
			local args = if type(input) == "table" then input else {}
			local limit = if type(args.limit) == "number" then args.limit else 50
			local entries = Logs.recent(limit, args.errorsOnly == true)
			local ok, encoded = pcall(function(): string
				return HttpService:JSONEncode({ ok = true, count = #entries, entries = entries })
			end)
			if ok then
				return encoded, false
			end
			return '{"ok":false,"error":"output not JSON-encodable"}', true
		end,
	},
} :: { Descriptor }

return Output
