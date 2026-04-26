local picker = require("icon_picker.picker")

local M = {}

local defaults = {
  command = "IconPicker",
  keymaps = {
    normal = nil,
    insert = nil,
  },
  picker = {
    stopinsert_on_open = true,
    toggle_source_key = "<C-t>",
    notify_source_toggle = false,
    telescope = {},
  },
}

local function set_keymap(mode, lhs, rhs, desc)
  if not lhs or lhs == "" then return end
  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true })
end

function M.open(opts)
  picker.open(opts)
end

function M.setup(opts)
  local cfg = vim.tbl_deep_extend("force", defaults, opts or {})

  picker.setup(cfg.picker or {})

  if cfg.command and cfg.command ~= "" then
    pcall(vim.api.nvim_del_user_command, cfg.command)
    vim.api.nvim_create_user_command(cfg.command, function(command_opts)
      picker.open(command_opts.args ~= "" and { default_text = command_opts.args } or nil)
    end, { nargs = "?", desc = "Pick Lucide/React Icons" })
  end

  if cfg.command and cfg.command ~= "" then
    local command_call = string.format("<cmd>%s<CR>", cfg.command)
    set_keymap("n", cfg.keymaps and cfg.keymaps.normal, command_call, "Icon picker")
    set_keymap("i", cfg.keymaps and cfg.keymaps.insert, "<Esc>" .. command_call, "Icon picker (insert)")
  end
end

return M
