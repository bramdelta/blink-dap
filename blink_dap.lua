local dap = require("dap")
local dap_repl = require("dap.repl")
local async = require("blink.cmp.lib.async")

local kinds = vim.lsp.protocol.CompletionItemKind

-- Map to convert DAP's returned kinds to LSP kinds
local kind_map = {
	method = kinds.Method,
	["function"] = kinds.Function,
	constructor = kinds.Constructor,
	field = kinds.Field,
	variable = kinds.Variable,
	class = kinds.Class,
	interface = kinds.Interface,
	module = kinds.Module,
	property = kinds.Property,
	unit = kinds.Unit,
	value = kinds.Value,
	enum = kinds.Enum,
	keyword = kinds.Keyword,
	snippet = kinds.Snippet,
	text = kinds.Text,
	color = kinds.Color,
	file = kinds.File,
	reference = kinds.Reference,
	customcolor = kinds.Color,
}

---@class blink.cmp.Source
local M = {}

---@class DapFileTypeConfig
---@field trigger_characters string[] Which characters to trigger a completion in the buffer

---Configuration for the module.
---@class BlinkDapConfig
---@field include_repl boolean Whether to include repl (default: true)
---@field filetypes table<string, DapFileTypeConfig> A map of filetype names to their settings
---@field dap_filetypes string[] List of filetypes for DAP integration, use :&filetype to deduce
M.config = {
	include_repl = true,
	filetypes = {
		python = {
			trigger_characters = { "." },
		},
	},
	dap_filetypes = { "dap-repl", "dapui_watches" },
}

---Determine if bufnr's filetype is in allowed_buf_types.
---@param bufnr number The buffer number, provided by Blink's context
---@param allowed_buf_types string[] The allowed buffer types, as per the config.
---@return boolean is_allowed If the bufnr provided is an allowed buffer.
local function is_allowed_filetype(bufnr, allowed_buf_types)
	local buftype = vim.bo[bufnr].filetype

	for _, v in ipairs(allowed_buf_types) do
		if v == buftype then
			return true
		end
	end

	return false
end

---Get the trigger characters for the current debug adapter
---@return string[] trigger_characters The characters to trigger a completion
local function get_dap_trigger_characters(filetypes)
	local dap_session = dap.session()
	assert(dap_session)

	local config_type = dap_session.config.type
	-- Return (by priority) the user-defined trigger characters, the adapter's, or assume '.'
	return filetypes[config_type].trigger_characters or dap_session.capabilities.completionTriggerCharacters or { "." }
end

---Initialize the plugin
---@param opts BlinkDapConfig The configuration to use for the module.
function M.new(opts)
	local self = setmetatable({}, { __index = M })

	-- Merge user options on top of defaults for this instance
	self.config = vim.tbl_deep_extend("force", M.config, opts or {})

	---Only enable completion for the configuration-specified filetypes
	self.enabled = function()
		local current_bufnr = vim.api.nvim_get_current_buf()
		if is_allowed_filetype(current_bufnr, self.config.dap_filetypes) then
			---It's documented here: https://github.com/Saghen/blink.cmp/issues/1492
			---...But it doesn't seem to work. Nice.
			---@diagnostic disable-next-line: return-type-mismatch
			return "force"
		end
		return false
	end

	---Determine which trigger_characters to use for completion based on user config
	self.get_trigger_characters = function()
		return get_dap_trigger_characters(self.config.filetypes)
	end

	return self
end

---Get REPL completions from DAP, to include in Blink's completions.
---@param add_func fun(val: string) The callback to add the completion to Blink
---@param typed string The currently typed string.
local function add_repl_completions(add_func, typed)
	-- Add repl commands (like .scope), including user-defined commands
	if vim.startswith(typed, ".") then
		for _, values in pairs(dap_repl.commands) do
			for _, directive in pairs(values) do
				if type(directive) == "string" and vim.startswith(directive, typed) then
					add_func(directive)
				end
			end
		end

		-- Include user's custom-defined commands
		for command, _ in pairs(dap_repl.commands.custom_commands or {}) do
			if vim.startswith(command, typed) then
				add_func(command)
			end
		end
	end
end

local function determine_dap_offset(line)
	if vim.startswith(line, "dap> ") then
		return 5 -- So we don't include the terminal prefix in dap-repl
	end
	if vim.startswith(line, "> ") then
		return 2 -- For dapui's watches
	end

	return 0 -- In case we don't have anything leading
end

---Get completions to feed into Blink
---@param context blink.cmp.Context The context provided by Blink
---@param callback fun(response?: blink.cmp.CompletionResponse) Function called with the completion response; may be nil
---@return nil
function M:get_completions(context, callback)
	local task = async.task.empty():map(function()
		-- Only do completions if the buffer type is specified
		if not is_allowed_filetype(context.bufnr, self.config.dap_filetypes) then
			return nil
		end

		local session = assert(dap.session())
		local col = context.cursor[2] -- Since .cursor returns [row, col] (undocumented)
		local line = context.line
		local offset = determine_dap_offset(line)
		local typed = line:sub(offset + 1, col)

		---@type lsp.CompletionItem[]
		local completions = {}

		-- Helper function to add the item to the list of completions
		local _add = function(val)
			table.insert(completions, { insertText = val, label = val, kind = kinds.Keyword })
		end

		-- Include REPL completions
		if self.config.include_repl then
			add_repl_completions(_add, typed)
		end

		-- Ask the DAP session for completions, providing the currently stopped frame as context
		session:request("completions", {
			frameId = (session.current_frame or {}).id,
			text = typed,
			column = col + 1 - offset,
		}, function(err, response)
			if err then
				return
			end

			-- Get the completion items from DAP and add them to the completions
			for _, item in pairs(response.targets) do
				if item.type then
					item.kind = kind_map[item.type]
				end
				item.insertText = item.text or item.label
				table.insert(completions, item)
			end

			-- Provide the completions to Blink via the callback
			callback({
				is_incomplete_forward = true,
				is_incomplete_backward = true,
				items = completions,
				context = context,
			})
		end)
	end)

	return function()
		task:cancel()
	end
end

return M
