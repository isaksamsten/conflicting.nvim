local commands = {
	incoming = function()
		require("conflicting").accept_incoming()
	end,
	current = function()
		require("conflicting").accept_current()
	end,
	both = function()
		require("conflicting").accept_both()
	end,
	reject = function()
		require("conflicting").reject()
	end,
	diff = function()
		require("conflicting").diff()
	end,
	track = function()
		require("conflicting").track()
	end,
	untrack = function()
		require("conflicting").untrack()
	end,
}

vim.api.nvim_create_user_command("Conflicting", function(args)
	local command = commands[args.args]
	if command then
		command()
	else
		vim.notify(string.format("Conflicting: %s is not a command", args.args))
	end
end, {
	nargs = 1,
	complete = function(arg_lead)
		local complete = {}
		for command, _ in pairs(commands) do
			if vim.startswith(command, arg_lead) then
				complete[#complete + 1] = command
			end
		end
		return complete
	end,
})
