local uv = vim.uv or vim.loop

local M = {}
local unpack_fn = table.unpack or unpack

local cache = {}
local source_cache = {}
local config = {
  ui = "telescope",
  preview_cache_max_age = 60 * 60 * 24 * 7,
  stopinsert_on_open = true,
  toggle_source_key = "<C-t>",
  notify_source_toggle = true,
  snacks = {},
  telescope = {},
}
local cleaned_preview_cache = false
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

local function preview_cache_dir()
  return join(vim.fn.stdpath "cache", "icon-picker.nvim")
end

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

local function build_svg_command(root, item)
  return {
    "node",
    "-e",
    NODE_RENDER_SCRIPT,
    root,
    item.import_path,
    item.icon,
  }
end

local function preview_cache_file(item)
  local dir = preview_cache_dir()
  vim.fn.mkdir(dir, "p")
  local name = (item.source .. "-" .. item.icon):gsub("[^%w_.-]", "_")
  return join(dir, name .. ".svg")
end

local function cleanup_preview_cache()
  if cleaned_preview_cache then return end
  cleaned_preview_cache = true

  local max_age = tonumber(config.preview_cache_max_age)
  if not max_age or max_age <= 0 then return end

  local dir = preview_cache_dir()
  if not dir_exists(dir) then return end

  local cutoff = os.time() - max_age
  local req = uv.fs_scandir(dir)
  if not req then return end

  while true do
    local name, t = uv.fs_scandir_next(req)
    if not name then break end
    if t == "file" and (name:match "%.svg$" or name:match "%.png$") then
      local file = join(dir, name)
      local stat = uv.fs_stat(file)
      local mtime = stat and stat.mtime and stat.mtime.sec
      if mtime and mtime < cutoff then pcall(uv.fs_unlink, file) end
    end
  end
end

local function preview_image_file(svg_file)
  local png_file = svg_file:gsub("%.svg$", ".png")
  if file_exists(png_file) then return png_file end

  local commands = {
    { "magick", "-background", "none", svg_file, png_file },
    { "convert", "-background", "none", svg_file, png_file },
  }

  for _, command in ipairs(commands) do
    if vim.fn.executable(command[1]) == 1 then
      vim.fn.system(command)
      if vim.v.shell_error == 0 and file_exists(png_file) then return png_file end
    end
  end

  return svg_file
end

local function make_snacks_preview_lines(item)
  local import_name = item.import_name or item.icon
  return {
    "Source: " .. item.source,
    string.format('Import: import { %s } from "%s";', import_name, item.import_path),
    "Insert: " .. item.insert_text,
  }
end

local function show_snacks_image_preview(ctx, preview, item, svg_file)
  local snacks = rawget(_G, "Snacks")
  if
    snacks
    and snacks.image
    and snacks.image.config
    and snacks.image.config.enabled ~= false
    and snacks.image.supports_terminal
    and snacks.image.supports_terminal()
  then
    local image_file = preview_image_file(svg_file)
    if not snacks.image.supports_file or snacks.image.supports_file(image_file) then
      local buf = preview:scratch()
      preview:set_title(item.icon .. " [" .. item.source .. "]")
      snacks.image.buf.attach(buf, {
        src = image_file,
        max_width = 42,
        max_height = 16,
      })
      return
    end
  end

  local lines = make_snacks_preview_lines(item)
  vim.list_extend(lines, {
    "",
    "Image preview requires snacks.image enabled, a supported terminal, and ImageMagick.",
    "SVG: " .. svg_file,
  })
  preview:set_lines(lines)
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

local function build_snacks_items(entries)
  local items = {}
  for _, entry in ipairs(entries) do
    local item = entry_value(entry)
    table.insert(items, vim.tbl_extend("force", item, {
      text = item.source .. " " .. item.icon,
      item = item,
    }))
  end
  return items
end

local function stop_process(process)
  if type(process) == "number" then
    pcall(vim.fn.jobstop, process)
  elseif process and process.kill then
    pcall(function() process:kill(9) end)
  end
end

local function strip_ansi(text)
  return text
    :gsub("\27%][^\7]*\7", "")
    :gsub("\27%[[%d;?]*[ -/]*[@-~]", "")
    :gsub("\27%([%w]", "")
end

local function run_preview_command(command, on_stdout)
  if vim.system then
    return vim.system(command, { text = true }, function(out)
      if out.signal == 9 then return end
      on_stdout(out.stdout or "")
    end)
  end

  local stdout = {}
  local job_id
  job_id = vim.fn.jobstart(command, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      stdout = data or {}
    end,
    on_exit = function(_, code)
      if code == 143 then return end
      on_stdout(table.concat(stdout, "\n"))
    end,
  })

  return job_id > 0 and job_id or nil
end

local function make_snacks_preview(root)
  return function(ctx)
    local preview = ctx.preview
    local item = ctx.item and (ctx.item.item or ctx.item)
    if not (preview and item) then return end

    local state = preview.state
    local item_key = item.import_path .. "::" .. item.icon
    local svg_file = preview_cache_file(item)

    if state.item_key == item_key and state.process then return end
    if state.item_key == item_key and state.shown_key == item_key and state.shown_buf == preview.win.buf then return end

    state.preview_seq = (state.preview_seq or 0) + 1
    local preview_seq = state.preview_seq

    if state.item_key ~= item_key then
      stop_process(state.process)
      state.process = nil
      state.shown_key = nil
      state.shown_buf = nil
      preview:reset()
    end

    state.item_key = item_key
    preview:set_title(item.icon .. " [" .. item.source .. "]")

    if file_exists(svg_file) then
      show_snacks_image_preview(ctx, preview, item, svg_file)
      state.shown_key = item_key
      state.shown_buf = preview.win.buf
      return
    end

    local command = build_svg_command(root, item)

    preview:set_lines { "Loading preview..." }
    state.process = run_preview_command(command, function(stdout)
      vim.schedule(function()
        pcall(function()
          if state.preview_seq ~= preview_seq then return end
          state.process = nil

          stdout = strip_ansi(stdout or ""):gsub("\r", "")
          local lines = make_snacks_preview_lines(item)

          if stdout == "" then
            vim.list_extend(lines, { "", "Preview unavailable." })
            preview:set_lines(lines)
            return
          end

          local svg_file = preview_cache_file(item)
          local fd = io.open(svg_file, "w")
          if fd then
            fd:write(stdout)
            fd:close()
          end

          show_snacks_image_preview(ctx, preview, item, svg_file)
          state.shown_key = item_key
          state.shown_buf = preview.win.buf
        end)
      end)
    end)
  end
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

local function make_snacks_format()
  return function(item)
    item = entry_value(item)
    return {
      { string.format("%-18s", "[" .. item.source .. "]"), "Comment" },
      { " " .. item.icon },
    }
  end
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

local function bool_text(value)
  return value and "yes" or "no"
end

local function executable_text(name)
  return vim.fn.executable(name) == 1 and "yes" or "no"
end

local function find_debug_item(entries, icon)
  if icon and icon ~= "" then
    for _, entry in ipairs(entries) do
      if entry.icon == icon or entry.icon:lower() == icon:lower() then return entry end
    end
  end

  for _, entry in ipairs(entries) do
    if entry.source == "lucide" then return entry end
  end
  return entries[1]
end

local function append_source_counts(lines, root, entries)
  local counts = {
    lucide = 0,
    react = 0,
    iconify = 0,
  }

  for _, entry in ipairs(entries) do
    if entry.source == "lucide" then counts.lucide = counts.lucide + 1 end
    if entry.source:match "^react%-icons/" then counts.react = counts.react + 1 end
    if entry.source:match "^iconify/" then counts.iconify = counts.iconify + 1 end
  end

  table.insert(lines, "Project")
  table.insert(lines, "  root: " .. root)
  table.insert(lines, "  package.json: " .. bool_text(file_exists(join(root, "package.json"))))
  table.insert(lines, "  node_modules: " .. bool_text(dir_exists(join(root, "node_modules"))))
  table.insert(lines, "")
  table.insert(lines, "Sources")
  table.insert(lines, "  total: " .. #entries)
  table.insert(lines, "  lucide: " .. counts.lucide)
  table.insert(lines, "  react-icons: " .. counts.react)
  table.insert(lines, "  iconify: " .. counts.iconify)
end

local function append_dependency_report(lines)
  local snacks = rawget(_G, "Snacks")
  if not snacks then
    local ok_snacks, snacks_mod = pcall(require, "snacks")
    if ok_snacks then snacks = snacks_mod end
  end

  table.insert(lines, "")
  table.insert(lines, "Executables")
  table.insert(lines, "  node: " .. executable_text "node")
  table.insert(lines, "  chafa: " .. executable_text "chafa")
  table.insert(lines, "  magick: " .. executable_text "magick")
  table.insert(lines, "  convert: " .. executable_text "convert")
  table.insert(lines, "")
  table.insert(lines, "Picker UI")
  table.insert(lines, "  configured ui: " .. tostring(config.ui))
  table.insert(lines, "  telescope available: " .. bool_text(pcall(require, "telescope.pickers")))
  table.insert(lines, "  snacks available: " .. bool_text(snacks and snacks.picker and snacks.picker.pick))
  table.insert(lines, "  snacks.image available: " .. bool_text(snacks and snacks.image and snacks.image.buf))

  if snacks and snacks.image then
    table.insert(lines, "  snacks.image enabled: " .. bool_text(snacks.image.config and snacks.image.config.enabled ~= false))
    local ok_terminal, terminal_supported = pcall(snacks.image.supports_terminal)
    table.insert(lines, "  snacks image terminal supported: " .. bool_text(ok_terminal and terminal_supported))
    local ok_terminal_mod, terminal = pcall(require, "snacks.image.terminal")
    if ok_terminal_mod and terminal then
      local ok_env, env = pcall(terminal.env)
      if ok_env and env then
        table.insert(lines, "  snacks image env: " .. tostring(env.name))
        table.insert(lines, "  snacks image placeholders: " .. bool_text(env.placeholders))
        table.insert(lines, "  snacks image remote: " .. bool_text(env.remote))
      end
    end
  end

  table.insert(lines, "")
  table.insert(lines, "Terminal Env")
  for _, name in ipairs({ "TERM", "TERM_PROGRAM", "WEZTERM_EXECUTABLE", "TMUX", "SSH_CONNECTION", "SNACKS_WEZTERM" }) do
    table.insert(lines, "  " .. name .. ": " .. tostring(vim.env[name] or ""))
  end
end

local function append_render_report(lines, root, item)
  table.insert(lines, "")
  table.insert(lines, "Preview Render Test")
  if not item then
    table.insert(lines, "  item: none")
    return
  end

  table.insert(lines, "  item: " .. item.icon .. " [" .. item.source .. "]")
  table.insert(lines, "  import_path: " .. item.import_path)

  local svg_file = preview_cache_file(item)
  local png_file = svg_file:gsub("%.svg$", ".png")
  table.insert(lines, "  cache dir: " .. preview_cache_dir())
  table.insert(lines, "  svg file: " .. svg_file)
  table.insert(lines, "  png file: " .. png_file)

  local svg = vim.fn.system(build_svg_command(root, item))
  table.insert(lines, "  node render exit: " .. vim.v.shell_error)

  if vim.v.shell_error ~= 0 or svg == "" then
    table.insert(lines, "  node render output:")
    for _, line in ipairs(vim.split(svg, "\n", { plain = true })) do
      table.insert(lines, "    " .. line)
    end
    return
  end

  local fd = io.open(svg_file, "w")
  if fd then
    fd:write(svg)
    fd:close()
  end
  table.insert(lines, "  svg written: " .. bool_text(file_exists(svg_file)))

  local image_file = preview_image_file(svg_file)
  table.insert(lines, "  image file used: " .. image_file)
  table.insert(lines, "  png exists: " .. bool_text(file_exists(png_file)))

  local snacks = rawget(_G, "Snacks")
  if snacks and snacks.image and snacks.image.supports_file then
    local ok_file, supported = pcall(snacks.image.supports_file, image_file)
    table.insert(lines, "  snacks supports image file: " .. bool_text(ok_file and supported))
    table.insert(lines, "  snacks image enabled: " .. bool_text(snacks.image.config and snacks.image.config.enabled ~= false))
  end
end

function M.debug(opts)
  opts = opts or {}

  local bufnr = vim.api.nvim_get_current_buf()
  local root = find_project_root(bufnr)
  local entries = build_entries(root)
  local item = find_debug_item(entries, opts.icon)
  local lines = {
    "icon-picker.nvim debug",
    "generated: " .. os.date "%Y-%m-%d %H:%M:%S",
    "",
  }

  append_source_counts(lines, root, entries)
  append_dependency_report(lines)
  append_render_report(lines, root, item)

  vim.cmd "new"
  local debug_buf = vim.api.nvim_get_current_buf()
  vim.bo[debug_buf].buftype = "nofile"
  vim.bo[debug_buf].bufhidden = "wipe"
  vim.bo[debug_buf].swapfile = false
  vim.bo[debug_buf].filetype = "text"
  vim.api.nvim_buf_set_name(debug_buf, "icon-picker-debug")
  vim.api.nvim_buf_set_lines(debug_buf, 0, -1, false, lines)
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  vim.defer_fn(cleanup_preview_cache, 1000)
end

local function open_telescope(opts, bufnr, root, entries, modes)
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

local function open_snacks(opts, bufnr, root, entries, modes)
  local snacks = rawget(_G, "Snacks")
  if not (snacks and snacks.picker and snacks.picker.pick) then
    local ok_snacks, snacks_mod = pcall(require, "snacks")
    if ok_snacks then snacks = snacks_mod end
  end

  if not (snacks and snacks.picker and snacks.picker.pick) then
    vim.notify("snacks.nvim picker is not available.", vim.log.levels.ERROR)
    return
  end

  local open_icon_picker
  local open_source_picker

  open_icon_picker = function(source_mode)
    local filtered_entries = filter_entries(entries, source_mode)
    if #filtered_entries == 0 then
      vim.notify("No icons found for source: " .. source_display(source_mode), vim.log.levels.WARN, { title = "IconPicker" })
      return
    end

    local picker_opts = vim.tbl_deep_extend("force", {
      source = "icon_picker",
      title = "Icons (" .. source_display(source_mode) .. ")",
      prompt = " ",
      pattern = opts.default_text or opts.pattern,
      items = build_snacks_items(filtered_entries),
      format = make_snacks_format(),
      preview = make_snacks_preview(root),
      confirm = function(picker, item)
        if picker then picker:close() end
        item = item and (item.item or item)
        if not item then return end
        ensure_import(bufnr, item.import_path, item.import_name or item.icon)
        insert_at_cursor(item.insert_text)
      end,
      win = {
        input = {
          keys = {
            [config.toggle_source_key] = {
              function(picker)
                picker:close()
                vim.defer_fn(function() open_source_picker(source_mode) end, 20)
              end,
              mode = { "i", "n" },
              desc = "Select source",
            },
          },
        },
        list = {
          keys = {
            [config.toggle_source_key] = {
              function(picker)
                picker:close()
                vim.defer_fn(function() open_source_picker(source_mode) end, 20)
              end,
              desc = "Select source",
            },
          },
        },
        preview = {
          wo = {
            number = false,
            relativenumber = false,
            signcolumn = "no",
            wrap = true,
            linebreak = true,
          },
        },
      },
      layout = {
        preset = "default",
      },
    }, config.snacks or {}, opts)

    snacks.picker.pick(picker_opts)
  end

  open_source_picker = function(default_mode)
    if #modes <= 1 then
      open_icon_picker(modes[1])
      return
    end

    snacks.picker.pick(vim.tbl_deep_extend("force", {
      source = "icon_picker_sources",
      title = "Icon Source",
      prompt = " ",
      items = vim.tbl_map(function(mode)
        return {
          mode = mode,
          text = source_display(mode),
        }
      end, modes),
      format = function(item)
        return {
          { item.mode == default_mode and "* " or "  ", "Comment" },
          { item.text },
        }
      end,
      confirm = function(picker, item)
        if picker then picker:close() end
        if not item then return end
        vim.defer_fn(function() open_icon_picker(item.mode) end, 20)
      end,
      layout = {
        preset = "select",
        preview = false,
      },
    }, {}))
  end

  vim.defer_fn(function() open_source_picker(modes[1]) end, 20)
end

function M.open(opts)
  opts = opts or {}

  -- Keep picker UI consistent when triggered from insert mode mappings.
  local mode = vim.api.nvim_get_mode().mode
  if config.stopinsert_on_open and (mode:sub(1, 1) == "i" or mode:sub(1, 1) == "R") then vim.cmd "stopinsert" end

  local ui = config.ui or "telescope"
  local ok_lazy, lazy = pcall(require, "lazy")
  if ok_lazy then
    local plugin = ui == "snacks" and "snacks.nvim" or "telescope.nvim"
    lazy.load { plugins = { plugin } }
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local root = find_project_root(bufnr)
  local entries = build_entries(root)
  if #entries == 0 then
    vim.notify("No Lucide/React/Iconify icons found. Make sure node_modules is installed.", vim.log.levels.WARN)
    return
  end

  local modes = { "all", "lucide", "react", "iconify" }

  if ui == "snacks" then
    open_snacks(opts, bufnr, root, entries, modes)
  else
    open_telescope(opts, bufnr, root, entries, modes)
  end
end

return M
