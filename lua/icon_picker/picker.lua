local uv = vim.uv or vim.loop

local M = {}
local unpack_fn = table.unpack or unpack

local cache = {}
local source_cache = {}
local config = {
  stopinsert_on_open = true,
  toggle_source_key = "<C-t>",
  notify_source_toggle = true,
  telescope = {},
}
local NODE_RENDER_SCRIPT = [[
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = process.argv[1];
const modPath = process.argv[2];
const iconName = process.argv[3];

const esc = (s) =>
  String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");

const toKebab = (name) =>
  String(name)
    .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
    .replace(/([A-Z]+)([A-Z][a-z])/g, "$1-$2")
    .toLowerCase();

const renderFromIconNode = (iconNode) => {
  if (!Array.isArray(iconNode)) return "";
  const attrs =
    'xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
  const body = iconNode
    .map(([tag, tagAttrs]) => {
      const attrText = Object.entries(tagAttrs || {})
        .map(([k, v]) => `${k}="${esc(v)}"`)
        .join(" ");
      return `<${tag}${attrText ? " " + attrText : ""}></${tag}>`;
    })
    .join("");
  return `<svg ${attrs}>${body}</svg>`;
};

const renderWithReact = () => {
  const React = require(require.resolve("react", { paths: [root] }));
  const { renderToStaticMarkup } = require(require.resolve("react-dom/server", { paths: [root] }));
  const mod = require(require.resolve(modPath, { paths: [root] }));
  const Icon = mod[iconName];
  if (!Icon) throw new Error("Icon export not found: " + iconName);
  return renderToStaticMarkup(React.createElement(Icon, { size: 128, color: "#ffffff" }));
};

const renderLucideWithoutReact = () => {
  if (modPath !== "lucide-react") return "";
  const pkgJson = require.resolve("lucide-react/package.json", { paths: [root] });
  const pkgRoot = path.dirname(pkgJson);
  const kebab = toKebab(iconName);
  const iconFileCandidates = [
    path.join(pkgRoot, "dist", "esm", "icons", `${kebab}.js`),
    path.join(pkgRoot, "dist", "esm", "icons", `${kebab}.mjs`),
  ];

  let source = "";
  for (const file of iconFileCandidates) {
    if (fs.existsSync(file)) {
      source = fs.readFileSync(file, "utf8");
      break;
    }
  }
  if (!source) return "";

  const m = source.match(/createLucideIcon\([^,]+,\s*(\[[\s\S]*?\])\s*\)/m);
  if (!m || !m[1]) return "";

  const iconNode = vm.runInNewContext(m[1], Object.create(null));
  return renderFromIconNode(iconNode);
};

const mergeIconifyData = (parent, child) => ({
  ...parent,
  ...child,
  hFlip: Boolean(parent.hFlip) !== Boolean(child.hFlip),
  vFlip: Boolean(parent.vFlip) !== Boolean(child.vFlip),
  rotate: ((parent.rotate || 0) + (child.rotate || 0)) % 4,
});

const resolveIconifyIcon = (set, name, depth = 0) => {
  if (depth > 8) return null;
  const icon = set.icons && set.icons[name];
  if (icon) return mergeIconifyData(set, icon);

  const alias = set.aliases && set.aliases[name];
  if (!alias || !alias.parent) return null;

  const parent = resolveIconifyIcon(set, alias.parent, depth + 1);
  return parent ? mergeIconifyData(parent, alias) : null;
};

const iconifyTransform = (data) => {
  const left = data.left || 0;
  const top = data.top || 0;
  const width = data.width || 16;
  const height = data.height || 16;
  const transforms = [];

  if (data.hFlip) transforms.push(`translate(${left + width} ${top}) scale(-1 1) translate(${-left} ${-top})`);
  if (data.vFlip) transforms.push(`translate(${left} ${top + height}) scale(1 -1) translate(${-left} ${-top})`);
  if (data.rotate) transforms.push(`rotate(${data.rotate * 90} ${left + width / 2} ${top + height / 2})`);

  return transforms.join(" ");
};

const renderIconifyFromJson = () => {
  if (modPath !== "@iconify/react") return "";

  const [prefix, name] = String(iconName).split(/:(.+)/);
  if (!prefix || !name) return "";

  const iconSetPath = path.join(root, "node_modules", "@iconify-json", prefix, "icons.json");
  if (!fs.existsSync(iconSetPath)) return "";

  const set = JSON.parse(fs.readFileSync(iconSetPath, "utf8"));
  const data = resolveIconifyIcon(set, name);
  if (!data || !data.body) return "";

  const left = data.left || 0;
  const top = data.top || 0;
  const width = data.width || 16;
  const height = data.height || 16;
  const transform = iconifyTransform(data);
  const body = transform ? `<g transform="${esc(transform)}">${data.body}</g>` : data.body;

  return `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="${left} ${top} ${width} ${height}" color="#ffffff">${body}</svg>`;
};

try {
  process.chdir(root);
  let svg = "";

  try {
    svg = renderWithReact();
  } catch (_) {
    svg = renderIconifyFromJson() || renderLucideWithoutReact();
  }

  if (!svg) {
    process.stderr.write("Preview render failed");
    process.exit(2);
  }

  process.stdout.write(svg);
} catch (err) {
  process.stderr.write((err && err.message) || String(err));
  process.exit(2);
}
]]

local function join(...) return table.concat({ ... }, "/") end

local function file_exists(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "file"
end

local function dir_exists(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory"
end

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local content = fd:read "*a"
  fd:close()
  return content
end

local function decode_json(content)
  if vim.json and vim.json.decode then
    local ok, decoded = pcall(vim.json.decode, content)
    if ok then return decoded end
  end

  local ok, decoded = pcall(vim.fn.json_decode, content)
  if ok then return decoded end
  return nil
end

local function dedupe(entries)
  local out = {}
  local seen = {}

  for _, entry in ipairs(entries) do
    local key = entry.import_path .. "::" .. entry.icon
    if not seen[key] then
      seen[key] = true
      table.insert(out, entry)
    end
  end

  return out
end

local function find_project_root(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local start = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
  local pkg = vim.fs.find("package.json", { path = start, upward = true })[1]

  if pkg then return vim.fs.dirname(pkg) end
  return vim.fn.getcwd()
end

local function parse_lucide(root)
  local entries = {}
  local seen = {}
  local function normalize_lucide_icon(icon)
    if not icon or icon == "" then return nil end
    if icon:match "^[A-Z]" then return icon end

    local s = icon:gsub("^%l", string.upper)
    if s:find "[%-_]" then s = s:gsub("[%-%_]+([%w])", function(c) return c:upper() end) end
    return s
  end

  local function add_icon(icon)
    icon = normalize_lucide_icon(icon)
    if not icon or icon == "" or seen[icon] then return end
    seen[icon] = true
    table.insert(entries, {
      icon = icon,
      source = "lucide",
      import_path = "lucide-react",
      insert_text = "<" .. icon .. " />",
    })
  end

  local dts_candidates = {
    join(root, "node_modules", "lucide-react", "dist", "lucide-react.d.ts"),
    join(root, "node_modules", "lucide-react", "dist", "lucide-react.suffixed.d.ts"),
    join(root, "node_modules", "lucide-react", "dist", "lucide-react.prefixed.d.ts"),
    join(root, "node_modules", "lucide-react", "dist", "dynamicIconImports.d.ts"),
  }

  for _, lucide_file in ipairs(dts_candidates) do
    if file_exists(lucide_file) then
      local content = read_file(lucide_file)
      if content then
        for icon in content:gmatch "default as ([%w_]+)" do
          add_icon(icon)
        end
        for icon in content:gmatch "export declare const ([%w_]+):" do
          add_icon(icon)
        end
        for icon in content:gmatch "export%s*{%s*([%w_]+)%s*}%s*from" do
          add_icon(icon)
        end
      end
    end
  end

  if #entries == 0 then
    local icons_dir = join(root, "node_modules", "lucide-react", "dist", "esm", "icons")
    if dir_exists(icons_dir) then
      local req = uv.fs_scandir(icons_dir)
      if req then
        while true do
          local name, t = uv.fs_scandir_next(req)
          if not name then break end
          if t == "file" and (name:match "%.js$" or name:match "%.mjs$") then
            local base = name:gsub("%.m?js$", "")
            local icon = base:gsub("(^%l)", string.upper):gsub("%-([%w])", function(c) return c:upper() end)
            add_icon(icon)
          end
        end
      end
    end
  end

  return entries
end

local function parse_react_icons(root)
  local entries = {}
  local ri_root = join(root, "node_modules", "react-icons")

  if not dir_exists(ri_root) then return entries end

  local req = uv.fs_scandir(ri_root)
  if not req then return entries end

  while true do
    local name, t = uv.fs_scandir_next(req)
    if not name then break end

    if t == "directory" then
      local dts_path = join(ri_root, name, "index.d.ts")

      if file_exists(dts_path) then
        local content = read_file(dts_path)
        if content then
          for icon in content:gmatch "export declare const ([%w_]+): IconType;" do
            table.insert(entries, {
              icon = icon,
              source = "react-icons/" .. name,
              import_path = "react-icons/" .. name,
              insert_text = "<" .. icon .. " />",
            })
          end
        end
      end
    end
  end

  return entries
end

local function parse_iconify(root)
  local entries = {}
  local iconify_root = join(root, "node_modules", "@iconify-json")

  if not file_exists(join(root, "node_modules", "@iconify", "react", "package.json")) then return entries end
  if not dir_exists(iconify_root) then return entries end

  local req = uv.fs_scandir(iconify_root)
  if not req then return entries end

  while true do
    local dir_name, t = uv.fs_scandir_next(req)
    if not dir_name then break end

    if t == "directory" then
      local icons_path = join(iconify_root, dir_name, "icons.json")
      if file_exists(icons_path) then
        local icon_set = decode_json(read_file(icons_path) or "")
        local prefix = icon_set and icon_set.prefix or dir_name

        local function add_icon(icon)
          if not icon or icon == "" then return end
          local icon_name = prefix .. ":" .. icon
          table.insert(entries, {
            icon = icon_name,
            source = "iconify/" .. prefix,
            import_path = "@iconify/react",
            import_name = "Icon",
            insert_text = '<Icon icon="' .. icon_name .. '" />',
          })
        end

        if type(icon_set) == "table" then
          if type(icon_set.icons) == "table" then
            for icon in pairs(icon_set.icons) do
              add_icon(icon)
            end
          end
          if type(icon_set.aliases) == "table" then
            for icon in pairs(icon_set.aliases) do
              add_icon(icon)
            end
          end
        end
      end
    end
  end

  return entries
end

local function build_entries(root)
  if cache[root] then return cache[root] end

  local entries = {}
  local lucide_entries = parse_lucide(root)
  local react_entries = parse_react_icons(root)
  local iconify_entries = parse_iconify(root)

  vim.list_extend(entries, lucide_entries)
  vim.list_extend(entries, react_entries)
  vim.list_extend(entries, iconify_entries)

  entries = dedupe(entries)
  table.sort(entries, function(a, b)
    if a.source == b.source then return a.icon < b.icon end
    return a.source < b.source
  end)

  cache[root] = entries
  source_cache[root] = {
    lucide = #lucide_entries > 0,
    react = #react_entries > 0,
    iconify = #iconify_entries > 0,
  }
  return entries
end

local function pascal_to_kebab(name)
  local s = name:gsub("(%u+)(%u%l)", "%1-%2")
  s = s:gsub("(%l%d)(%u)", "%1-%2")
  s = s:gsub("(%a)(%d)", "%1-%2")
  s = s:gsub("(%d)(%a)", "%1-%2")
  return s:lower()
end

local function build_preview_command(root, item)
  local shellescape = vim.fn.shellescape
  local import_name = item.import_name or item.icon
  local details = {
    "Source: " .. item.source,
    string.format('Import: import { %s } from "%s";', import_name, item.import_path),
    "Insert: " .. item.insert_text,
  }

  if item.source == "lucide" then
    table.insert(details, "URL: https://lucide.dev/icons/" .. pascal_to_kebab(item.icon))
  elseif item.source:match "^iconify/" then
    local prefix, name = item.icon:match "^([^:]+):(.+)$"
    if prefix and name then table.insert(details, "URL: https://icon-sets.iconify.design/" .. prefix .. "/" .. name .. "/") end
  end

  local detail_text = table.concat(details, "\\n"):gsub("%%", "%%%%")

  local command = string.format(
    [[svg="$(node -e %s %s %s %s 2>/dev/null)";
if [ -n "$svg" ] && command -v chafa >/dev/null 2>&1; then
  printf "%%s" "$svg" | chafa -f symbols -s 36x12 -;
else
  printf "Preview unavailable (requires chafa; react/react-dom needed for react-icons).\n";
fi
printf "\n%s\n";]],
    shellescape(NODE_RENDER_SCRIPT),
    shellescape(root),
    shellescape(item.import_path),
    shellescape(item.icon),
    detail_text
  )

  return { "bash", "-lc", command }
end

local function make_previewer(root, previewers)
  return previewers.new_termopen_previewer {
    title = " Icon Preview",
    get_command = function(entry) return build_preview_command(root, entry.value) end,
  }
end

local function entry_value(entry)
  return entry and (entry.value or entry)
end

local function filter_entries(entries, mode)
  if mode == "all" then return entries end

  local out = {}
  for _, entry in ipairs(entries) do
    local item = entry_value(entry)
    local source = item and item.source or ""
    if mode == "lucide" and source == "lucide" then table.insert(out, item) end
    if mode == "react" and source:match "^react%-icons/" then table.insert(out, item) end
    if mode == "iconify" and source:match "^iconify/" then table.insert(out, item) end
  end
  return out
end

local function available_from_entries(entries)
  local available = {
    lucide = false,
    react = false,
    iconify = false,
  }

  for _, entry in ipairs(entries) do
    local item = entry_value(entry)
    local source = item and item.source or ""

    if source == "lucide" then available.lucide = true end
    if source:match "^react%-icons/" then available.react = true end
    if source:match "^iconify/" then available.iconify = true end
  end

  return available
end

local function build_modes_from_available(available)
  local modes = {}

  if available.lucide then table.insert(modes, "lucide") end
  if available.react then table.insert(modes, "react") end
  if available.iconify then table.insert(modes, "iconify") end

  if #modes > 1 then table.insert(modes, 1, "all") end
  if #modes == 1 then return modes end
  return { "all" }
end

local function source_display(mode)
  if mode == "all" then return "All sources" end
  if mode == "lucide" then return "Lucide" end
  if mode == "react" then return "React Icons" end
  if mode == "iconify" then return "Iconify" end
  return mode
end

local function make_finder(finders, entries)
  local results = {}
  for _, entry in ipairs(entries) do
    table.insert(results, entry_value(entry))
  end

  return finders.new_table {
    results = results,
    entry_maker = function(entry)
      return {
        value = entry,
        display = string.format("%-18s %s", "[" .. entry.source .. "]", entry.icon),
        ordinal = entry.source .. " " .. entry.icon,
      }
    end,
  }
end

local function is_use_client(line)
  local trimmed = vim.trim(line)
  return trimmed:match '^"use client";?$' or trimmed:match "^'use client';?$"
end

local function collect_import_blocks(lines)
  local blocks = {}
  local i = 1

  while i <= #lines do
    if lines[i]:match "^%s*import%s+" then
      local start_i = i
      local j = i

      while j <= #lines do
        local line = lines[j]
        if line:match "from%s+[\"'].-[\"']%s*;?%s*$" or line:match ";%s*$" then break end
        j = j + 1
      end

      if j > #lines then j = start_i end

      table.insert(blocks, {
        start_line = start_i,
        end_line = j,
        text = table.concat(vim.list_slice(lines, start_i, j), "\n"),
      })

      i = j + 1
    else
      i = i + 1
    end
  end

  return blocks
end

local function ensure_import(bufnr, import_path, icon)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local escaped_module = vim.pesc(import_path)
  local blocks = collect_import_blocks(lines)

  for _, block in ipairs(blocks) do
    if
      block.text:match("from%s+[\"']" .. escaped_module .. "[\"']")
      and block.text:match("%f[%w_]" .. vim.pesc(icon) .. "%f[^%w_]")
    then
      return
    end
  end

  -- Merge only when the import is a simple named import list.
  -- For complex imports (aliases/type/default/multiline), insert a new import
  -- instead of rewriting existing lines to avoid breaking user code.
  for _, block in ipairs(blocks) do
    if
      block.start_line == block.end_line
      and lines[block.start_line]:match(
        "^%s*import%s+{%s*[%w_,%s]+%s*}%s+from%s+[\"']" .. escaped_module .. "[\"'];?%s*$"
      )
    then
      local i = block.start_line
      local line = lines[i]
      local inside = line:match "{(.*)}" or ""
      local names = {}
      local seen = {}
      local simple = true

      for raw in inside:gmatch "[^,]+" do
        local name = vim.trim(raw)
        if not name:match "^[%a_][%w_]*$" then
          simple = false
          break
        end
        seen[name] = true
        table.insert(names, name)
      end

      if simple and not seen[icon] then
        table.insert(names, icon)
        table.sort(names)
        lines[i] = "import { " .. table.concat(names, ", ") .. ' } from "' .. import_path .. '";'
        vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { lines[i] })
        return
      end
    end
  end

  local insert_at = 0
  local i = 1
  while i <= #lines and lines[i]:match "^%s*$" do
    insert_at = i
    i = i + 1
  end

  if i <= #lines and is_use_client(lines[i]) then
    insert_at = i
    i = i + 1
    while i <= #lines and lines[i]:match "^%s*$" do
      insert_at = i
      i = i + 1
    end
  end

  while i <= #lines do
    if lines[i]:match "^%s*$" then
      insert_at = i
      i = i + 1
    elseif lines[i]:match "^%s*import%s+" then
      local j = i
      while j <= #lines do
        local line = lines[j]
        if line:match "from%s+[\"'].-[\"']%s*;?%s*$" or line:match ";%s*$" then break end
        j = j + 1
      end
      if j > #lines then j = i end
      insert_at = j
      i = j + 1
    else
      break
    end
  end

  local import_line = "import { " .. icon .. ' } from "' .. import_path .. '";'
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { import_line })
end

local function insert_at_cursor(text)
  local row, col = unpack_fn(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local before = line:sub(1, col)
  local after = line:sub(col + 1)

  vim.api.nvim_set_current_line(before .. text .. after)
  vim.api.nvim_win_set_cursor(0, { row, col + #text })
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
end

function M.open(opts)
  opts = opts or {}

  -- Keep picker UI consistent when triggered from insert mode mappings.
  local mode = vim.api.nvim_get_mode().mode
  if config.stopinsert_on_open and (mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R") then vim.cmd "stopinsert" end

  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then lazy.load { plugins = { "telescope.nvim" } } end

  local ok_pickers, pickers = pcall(require, "telescope.pickers")
  local ok_finders, finders = pcall(require, "telescope.finders")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_action_state, action_state = pcall(require, "telescope.actions.state")
  local ok_conf, conf_mod = pcall(require, "telescope.config")
  local ok_previewers, previewers = pcall(require, "telescope.previewers")

  if not (ok_pickers and ok_finders and ok_actions and ok_action_state and ok_conf and ok_previewers) then
    vim.notify("Telescope is not available.", vim.log.levels.ERROR)
    return
  end

  local conf = conf_mod.values

  local bufnr = vim.api.nvim_get_current_buf()
  local root = find_project_root(bufnr)
  local entries = build_entries(root)
  if #entries == 0 then
    vim.notify("No Lucide/React/Iconify icons found. Make sure node_modules is installed.", vim.log.levels.WARN)
    return
  end

  local modes = { "all", "lucide", "react", "iconify" }

  local open_icon_picker
  local open_source_picker

  open_icon_picker = function(source_mode)
    local filtered_entries = filter_entries(entries, source_mode)
    if #filtered_entries == 0 then
      vim.notify("No icons found for source: " .. source_display(source_mode), vim.log.levels.WARN, { title = "IconPicker" })
      return
    end

    local picker_opts = vim.tbl_extend("force", {
      prompt_title = " Icons (" .. source_display(source_mode) .. ")",
      prompt_prefix = "   ",
      selection_caret = "  ",
      sorting_strategy = "ascending",
      layout_strategy = "horizontal",
      border = true,
      layout_config = {
        prompt_position = "top",
        width = 0.95,
        height = 0.85,
        preview_width = 0.55,
      },
      previewer = make_previewer(root, previewers),
    }, config.telescope or {}, opts)

    pickers
      .new(picker_opts, {
        finder = make_finder(finders, filtered_entries),
        sorter = conf.generic_sorter(picker_opts),
        attach_mappings = function(prompt_bufnr, map)
          local function reopen_source_picker()
            actions.close(prompt_bufnr)
            vim.defer_fn(function() open_source_picker(source_mode) end, 20)
          end

          map("i", config.toggle_source_key, reopen_source_picker)
          map("n", config.toggle_source_key, reopen_source_picker)

          actions.select_default:replace(function()
            actions.close(prompt_bufnr)
            local selected = action_state.get_selected_entry()
            if not selected then return end

            local item = selected.value
            ensure_import(bufnr, item.import_path, item.import_name or item.icon)
            insert_at_cursor(item.insert_text)
          end)

          return true
        end,
      })
      :find()
  end

  open_source_picker = function(default_mode)
    if #modes <= 1 then
      open_icon_picker(modes[1])
      return
    end

    local source_opts = {
      prompt_title = " Icon Source",
      prompt_prefix = "   ",
      selection_caret = "  ",
      sorting_strategy = "ascending",
      layout_strategy = "center",
      border = true,
      previewer = false,
      layout_config = {
        width = 0.35,
        height = 0.35,
      },
    }

    pickers
      .new(source_opts, {
        finder = finders.new_table {
          results = modes,
          entry_maker = function(mode)
            return {
              value = mode,
              display = (mode == default_mode and "* " or "  ") .. source_display(mode),
              ordinal = source_display(mode),
            }
          end,
        },
        sorter = conf.generic_sorter(source_opts),
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local selected = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not selected then return end
            vim.defer_fn(function() open_icon_picker(selected.value) end, 20)
          end)

          return true
        end,
      })
      :find()
  end

  vim.defer_fn(function() open_source_picker(modes[1]) end, 20)
end

return M
