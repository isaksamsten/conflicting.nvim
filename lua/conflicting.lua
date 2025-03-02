--- @class conflicting.Tracker
--- @field attach fun(buf: integer):nil
--- @field detach fun(buf: integer):nil
--- @field is_enabled fun(buf: integer):nil
---
--- @alias conflicting.Position { ours_lnum: integer, delimiter_lnum: integer, theirs_lnum: integer}
--- @alias conflicting.Marker
--- | 0 our header
--- | 1 our
--- | 2 delimiter
--- | 3 their
--- | 4 their header
--- | 5 base delimiter
---
local M = {}

local OURS_PATTERN = "^<<<<<<< (%S+)"
local THEIRS_PATTERN = "^>>>>>>> (%S+)"
local DELIMITER_PATTERN = "^======="

local OURS_HEADER = 0
local OURS = 1
local DELIMITER = 2
local THEIRS = 3
local THEIRS_HEADER = 4
local BASE_DELIMITER = 5

local HL_GROUPS = {
  [OURS_HEADER] = "ConflictingOursHeader",
  [OURS] = "ConflictingOurs",
  [THEIRS] = "ConflictingTheirs",
  [THEIRS_HEADER] = "ConflictingTheirsHeader",
  [DELIMITER] = "ConflictingDelimiter",
  [BASE_DELIMITER] = "ConflictingBaseDelimiter",
}

local MARKER_NAMESPACE = vim.api.nvim_create_namespace("ConflictingMarkers")

local DIFF_WO = { "wrap", "linebreak", "breakindent", "breakindentopt", "showbreak" }

--- Highlight groups and their default links
local highlight_groups = {
  ConflictingOursHeader = { link = "DiffAdd" },
  ConflictingOurs = { link = "DiffAdd" },
  ConflictingTheirs = { link = "DiffChange" },
  ConflictingTheirsHeader = { link = "DiffChange" },
  ConflictingDelimiter = { link = "Normal" },
}

local buf_timer = vim.uv.new_timer()

--- @alias conflicting.MarkerHighlight {hl_group: conflicting.Marker, incoming_header: string?, current_header: string?}
--- @type table<integer, {markers: table<integer, conflicting.MarkerHighlight >,  positions: conflicting.Position[], trackers: conflicting.Tracker[], needs_clear: boolean?, augroup: integer?}?>
local cache = {}

--- @type table<integer, { fs_event : uv_fs_event_t?, timer: uv_timer_t?, is_conflict: boolean?}?>
local git_cache = {}

--- @type table<integer, boolean?>
local manual_tracker_bufs = {}

--- @type table<integer, boolean?>
local bufs_to_update = {}

--- @param buf integer
local redraw_buffer = function(buf)
  vim.api.nvim__buf_redraw_range(buf, 0, -1)
  vim.cmd("redrawstatus")
end

if vim.api.nvim__redraw ~= nil then
  redraw_buffer = function(buf)
    vim.api.nvim__redraw({ buf = buf, valid = true, statusline = true })
  end
end

--- Parse contents and return
--- @param content string[]
--- @param opts {ours_pattern: string, delimiter_pattern: string, theirs_pattern: string }?
--- @return { lnum: integer, lnum_end: integer, ours:string[], theirs:string[], ours_tag: string?, theirs_tag: string?}[]
local function find_conflict_markers(content, opts)
  opts = opts or {}

  local ours_pattern = opts.ours_pattern or "^<<<<<<?<?<?<?"
  local theirs_pattern = opts.theirs_pattern or "^>>>>>>?>?>?>?>"
  local delimiter_pattern = opts.delimiter_pattern or "^======?=?=?=?"

  local IN_OURS = 1
  local IN_THEIRS = 2
  local SEARCHING = 3

  local ours = {}
  local theirs = {}
  local ours_tag = nil
  local conflicts = {}
  local state = SEARCHING
  local lnum = -1
  local match

  for l, line in pairs(content) do
    if state == SEARCHING then
      match = string.match(line, ours_pattern)
      if match then
        state = IN_OURS
        ours_tag = match
        lnum = l
      else
        goto continue
      end
    else
      if state == IN_OURS then
        if string.match(line, delimiter_pattern) then
          state = IN_THEIRS
        else
          ours[#ours + 1] = line
        end
      elseif state == IN_THEIRS then
        match = string.match(line, theirs_pattern)
        if match then
          conflicts[#conflicts + 1] = {
            ours_tag = ours_tag,
            theirs_tag = match,
            lnum = lnum,
            lnum_end = l,
            ours = ours,
            theirs = theirs,
          }
          ours = {}
          theirs = {}
          ours_tag = nil
          state = SEARCHING
        else
          theirs[#theirs + 1] = line
        end
      end
    end
    ::continue::
  end

  return conflicts
end

--- @param positions conflicting.Position[]
local function find_conflict_under_cursor(positions)
  local pos = vim.fn.getpos(".")[2]
  for _, marker in pairs(positions) do
    if pos <= marker.theirs_lnum and pos >= marker.ours_lnum then
      return marker
    end
  end
  return nil
end

--- Update buffer cache
--- @param buf integer
local function update_buf_cache(buf)
  local buf_cache = cache[buf] or {}
  buf_cache.markers = buf_cache.markers or {}
  buf_cache.positions = buf_cache.positions or {}
  buf_cache.trackers = buf_cache.trackers or M.config.trackers

  cache[buf] = buf_cache
end

--- Update buffer caches with marker data if any of the trackers has annotated
--- the buffer as tracked.
--- @param buf integer
local update_buf = vim.schedule_wrap(function(buf)
  local buf_cache = cache[buf]
  if buf_cache == nil then
    return
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    cache[buf] = nil
    return
  end

  local is_enabled = false
  for _, tracker in pairs(buf_cache.trackers) do
    if tracker.is_enabled(buf) then
      is_enabled = true
    end
  end

  -- Reset all markers and positions
  buf_cache.markers = {}
  buf_cache.positions = {}

  -- If the tracker is no longer enabled we need to clear existing extmarks
  if is_enabled then
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local markers = find_conflict_markers(content, {
      ours_pattern = OURS_PATTERN,
      theirs_pattern = THEIRS_PATTERN,
      delimiter_pattern = DELIMITER_PATTERN,
    })

    for _, marker in ipairs(markers) do
      local delimiter = marker.lnum + #marker.ours + 1
      for i = marker.lnum, marker.lnum_end do
        buf_cache.markers[i] = {}
        if i == delimiter then
          buf_cache.markers[i].hl_group = DELIMITER
        elseif i < delimiter then
          buf_cache.markers[i].hl_group = OURS
        else
          buf_cache.markers[i].hl_group = THEIRS
        end
      end
      buf_cache.markers[marker.lnum] = { hl_group = OURS_HEADER, current_header = marker.ours_tag }
      buf_cache.markers[marker.lnum_end] = { hl_group = THEIRS_HEADER, incoming_header = marker.theirs_tag }

      buf_cache.positions[#buf_cache.positions + 1] =
        { ours_lnum = marker.lnum, theirs_lnum = marker.lnum_end, delimiter_lnum = delimiter }
    end
  end
  buf_cache.needs_clear = true
  redraw_buffer(buf)
end)

--- Process updates for all scheduled buffers.
local process_scheduled_buffers = vim.schedule_wrap(function()
  for buf, _ in pairs(bufs_to_update) do
    update_buf(buf)
  end
  bufs_to_update = {}
end)

--- Schedule marker updates to a given buffer, optionally debounced by a delay.
--- Every buffer scheduled inside the debounce is updated.
--- @param buf integer
--- @param delay integer number of milliseconds to wait for updates
local schedule_marker_updates = vim.schedule_wrap(function(buf, delay)
  bufs_to_update[buf] = true
  buf_timer:stop()
  buf_timer:start(delay or 0, 0, process_scheduled_buffers)
end)

--- Setup buffer local auto commands to schedule conflict marker updates.
--- @param buf integer
local function setup_autocommand(buf)
  local augroup = vim.api.nvim_create_augroup("Conflicting" .. buf, { clear = true })
  local buf_update = vim.schedule_wrap(function()
    update_buf_cache(buf)
  end)
  cache[buf].augroup = augroup
  vim.api.nvim_create_autocmd("BufWinEnter", {
    buffer = buf,
    group = augroup,
    callback = buf_update,
  })

  vim.api.nvim_create_autocmd("BufFilePost", {
    group = augroup,
    buffer = buf,
    callback = function(args)
      if cache[args.buf] ~= nil then
        M.disable(args.buf)
        M.enable(args.buf)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = augroup,
    buffer = buf,
    callback = function(args)
      M.disable(args.buf)
    end,
  })
end

--- Clear all extmarks set for MARKER_NAMESPACE
local function clear_all_extarks(buf)
  pcall(vim.api.nvim_buf_clear_namespace, buf, MARKER_NAMESPACE, 0, -1)
end

--- Get the real path for buf
--- @param buf integer
--- @return string
local function get_buf_real_path(buf)
  return vim.uv.fs_realpath(vim.api.nvim_buf_get_name(buf)) or ""
end

--- Read the stdout-stream into data[1]
--- @param stream uv_pipe_t
--- @param data string[]
local function git_read_stream(stream, data)
  local callback = function(err, out)
    if data ~= nil then
      table.insert(data, out)
      return
    end
    if err then
      data[1] = nil
    end
    stream:close()
  end
  stream:read_start(callback)
end

--- When rebase or merge is detected check if the given buffer contains any
--- conflicts and set git_cache[buf].is_conflict to true. If the conflict status
--- is changed, we schedule a marker update request.
---
--- @param buf integer
local git_find_conflicting_files = vim.schedule_wrap(function(buf)
  local path = get_buf_real_path(buf)
  if path == "" then
    return
  end
  local stdout = vim.loop.new_pipe()
  local process
  local stdout_data = {}

  local cwd = vim.fn.fnamemodify(path, ":h")
  local args = { "diff", "--name-only", "--diff-filter=U" }
  local spawn_opts = { args = args, cwd = cwd, stdio = { nil, stdout, nil } }
  local on_exit = function(exit_code)
    process:close()
    local was_conflict = git_cache[buf].is_conflict
    if exit_code ~= 0 or stdout_data[1] == nil then
      git_cache[buf].is_conflict = nil
    else
      local found = nil
      for file in string.gmatch(stdout_data[1], "([^\n]*)\n?") do
        local cpath = vim.fs.joinpath(cwd, file)
        if cpath == path then
          found = true
          break
        end
      end
      if found then
        git_cache[buf].is_conflict = true
      end
    end
    if was_conflict ~= git_cache[buf].is_conflict then
      schedule_marker_updates(buf, 0)
    end
  end

  process = vim.uv.spawn("git", spawn_opts, on_exit)
  git_read_stream(stdout, stdout_data)
end)

local WATCH_FILES = {
  MERGE_HEAD = true,
  REBASE_HEAD = true,
  AUTO_MERGE = true,
  CHERRY_PICK_HEAD = true,
  BISECT_HEAD = true,
  REVERT_HEAD = true,
}
--- Sets up a file system watcher and timer to monitor Git merge and rebase events.
--- When a WATCH_FILES-file is detected, schedules a check for conflicting files.
--- @param buf integer
--- @param path string The file system path to be monitored.
local function git_setup_watcher(buf, path)
  local fs_event = vim.uv.new_fs_event()
  local timer = vim.uv.new_timer()
  local watch_merge_rebase = function(_, filename, _)
    if not WATCH_FILES[filename] then
      return
    end
    timer:stop()
    timer:start(50, 0, function()
      git_find_conflicting_files(buf)
    end)
  end
  git_cache[buf] = { fs_event = fs_event, timer = timer }
  if fs_event then
    fs_event:start(path, { recursive = false, timer = timer }, watch_merge_rebase)
  end
end

--- Start watching a Git repository for merge/rebase changes.
---
--- @param buf integer
--- @param path string the path of the file in the buffer
local function git_start_watch(buf, path)
  local stdout = vim.uv.new_pipe()
  local args = { "rev-parse", "--path-format=absolute", "--git-dir" }
  local spawn_opts = { args = args, cwd = vim.fn.fnamemodify(path, ":h"), stdio = { nil, stdout, nil } }

  local not_in_git = vim.schedule_wrap(function()
    if vim.api.nvim_buf_is_valid(buf) then
      cache[buf] = nil
      return false
    end
    M.disable(buf)
    git_cache[buf] = {}
  end)

  local process
  local stdout_data = {}
  local on_exit = function(exit_code)
    process:close()
    if exit_code ~= 0 or stdout_data[1] == nil then
      not_in_git()
      return
    end

    local git_path = table.concat(stdout_data, ""):gsub("\n+$", "")
    git_setup_watcher(buf, git_path)
    git_find_conflicting_files(buf)
  end
  process = vim.uv.spawn("git", spawn_opts, on_exit)
  git_read_stream(stdout, stdout_data)
end

--- Setup the decoration provider to draw decorations for conflicts.
local function set_decoration_provider()
  vim.api.nvim_set_decoration_provider(MARKER_NAMESPACE, {
    on_win = function(_, _, buf, toprow, botrow)
      local buf_cache = cache[buf]
      if buf_cache == nil then
        return false
      end
      if buf_cache.needs_clear then
        buf_cache.needs_clear = nil
        clear_all_extarks(buf)
      end
      if vim.wo.diff then
        clear_all_extarks(buf)
        return
      end

      local markers = buf_cache.markers
      for i = toprow + 1, botrow + 1 do
        if markers[i] ~= nil then
          local extmark_opts = {
            hl_eol = true,
            hl_mode = "combine",
            end_row = i,
            hl_group = HL_GROUPS[markers[i].hl_group],
          }
          vim.api.nvim_buf_set_extmark(buf, MARKER_NAMESPACE, i - 1, 0, extmark_opts)

          if markers[i].current_header then
            vim.api.nvim_buf_set_extmark(buf, MARKER_NAMESPACE, i - 1, 0, {
              hl_eol = true,
              end_row = i,
              virt_text_pos = "overlay",
              virt_text = {
                {
                  string.format("<<<<<<< %s (Current change)", markers[i].current_header),
                  "ConflictingOursHeader",
                },
              },
            })
          elseif markers[i].incoming_header then
            vim.api.nvim_buf_set_extmark(buf, MARKER_NAMESPACE, i - 1, 0, {
              hl_eol = true,
              end_row = i,
              virt_text_pos = "overlay",
              virt_text = {
                {
                  string.format(">>>>>>> %s (Incoming change)", markers[i].incoming_header),
                  "ConflictingTheirsHeader",
                },
              },
            })
          end
          markers[i] = nil
        end
      end
    end,
  })
end

--- Automatically enable conflicting for buffers.
--- @param data { buf: integer }
local auto_enable = vim.schedule_wrap(function(data)
  local buf = data.buf

  -- The buffer has already been enabled.
  if cache[buf] ~= nil then
    return
  end

  if not (vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "" and vim.bo[buf].buflisted) then
    return
  end
  M.enable(buf)
end)

--- Set highlight groups to their default links if they are unset by the user.
local function set_highlight_groups()
  for group, attr in pairs(highlight_groups) do
    local existing = vim.api.nvim_get_hl(0, { name = group })
    if vim.tbl_isempty(existing) then
      vim.api.nvim_set_hl(0, group, attr)
    end
  end
end

--- @type table<string, conflicting.Tracker>
M.trackers = {}

--- Track conflicts in Git merge/rebase
--- @type conflicting.Tracker
M.trackers.git = {
  --- Attach the current buffer to the watcher.
  attach = function(buf)
    local path = get_buf_real_path(buf)
    if path == "" then
      return
    end
    git_start_watch(buf, path)
  end,
  --- Detach the current buffer from the
  detach = function(buf)
    local gc = git_cache[buf]
    if gc == nil then
      return
    end
    git_cache[buf] = nil
    pcall(vim.uv.fs_event_stop, gc.fs_event)
    pcall(vim.uv.timer_stop, gc.timer)
  end,
  --- @returns boolean is_enabled if the current buffer enabled
  is_enabled = function(buf)
    local gc = git_cache[buf]
    if gc == nil then
      return false
    end
    return gc.is_conflict
  end,
}

--- Manual tracker
--- @type conflicting.Tracker
M.trackers.manual = {
  attach = function(_) end,
  detach = function(buf)
    manual_tracker_bufs[buf] = nil
  end,
  is_enabled = function(buf)
    return manual_tracker_bufs[buf] ~= nil
  end,
}

--- Manually track buffer
--- @param buf integer?
function M.track(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local buf_cache = cache[buf]
  if buf_cache == nil then
    return
  end
  manual_tracker_bufs[buf] = true
  schedule_marker_updates(buf, 0)
end

--- Manually untrack buffer
--- @param buf integer?
function M.untrack(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local buf_cache = cache[buf]
  if buf_cache == nil then
    return
  end
  manual_tracker_bufs[buf] = nil
  schedule_marker_updates(buf, 0)
end

--- Accept current changes
--- @param buf integer?
function M.accept_current(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    local current_change = vim.api.nvim_buf_get_lines(buf, pos.ours_lnum, pos.delimiter_lnum - 1, false)
    vim.api.nvim_buf_set_lines(buf, pos.ours_lnum - 1, pos.theirs_lnum, false, current_change)
    schedule_marker_updates(buf)
  end
end

--- Accept incoming changes.
--- @param buf integer?
function M.accept_incoming(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    local incoming_change = vim.api.nvim_buf_get_lines(buf, pos.delimiter_lnum, pos.theirs_lnum - 1, false)
    vim.api.nvim_buf_set_lines(buf, pos.ours_lnum - 1, pos.theirs_lnum, false, incoming_change)
    schedule_marker_updates(buf)
  end
end

--- Accept both current and incoming changes.
--- @param buf integer?
function M.accept_both(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    local current_change = vim.api.nvim_buf_get_lines(buf, pos.ours_lnum, pos.delimiter_lnum - 1, false)
    local incoming_change = vim.api.nvim_buf_get_lines(buf, pos.delimiter_lnum, pos.theirs_lnum - 1, false)

    local changes = vim.iter({ current_change, incoming_change }):flatten():totable()
    vim.api.nvim_buf_set_lines(buf, pos.ours_lnum - 1, pos.theirs_lnum, false, changes)
    schedule_marker_updates(buf)
  end
end

--- Reject the conflict
--- @param buf integer?
function M.reject(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    vim.api.nvim_buf_set_lines(buf, pos.ours_lnum - 1, pos.theirs_lnum, false, {})
    schedule_marker_updates(buf)
  end
end

--- Open a vertical split diffing the current and incoming changes.
---
--- @param buf integer?
--- @param opts table?
function M.diff(buf, opts)
  buf = buf or vim.api.nvim_get_current_buf()
  local buf_cache = cache[buf]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local pos = find_conflict_under_cursor(buf_cache.positions)
  if pos then
    opts = opts or {}
    local win = vim.api.nvim_get_current_win()
    local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local current = vim.api.nvim_buf_get_lines(buf, pos.ours_lnum, pos.delimiter_lnum - 1, false)
    local suggested = vim.api.nvim_buf_get_lines(buf, pos.delimiter_lnum, pos.theirs_lnum - 1, false)
    vim.cmd(opts.split or "vsplit")
    local diffwin = vim.api.nvim_get_current_win()
    local diffbuf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(diffwin, diffbuf)
    for _, opt in pairs(DIFF_WO) do
      vim.wo[diffwin][opt] = vim.wo[win][opt]
    end
    vim.bo[diffbuf].ft = vim.bo[buf].ft

    vim.api.nvim_buf_set_lines(buf, pos.ours_lnum - 1, pos.theirs_lnum, false, current)
    vim.api.nvim_buf_set_lines(diffbuf, 0, -1, false, content)
    vim.api.nvim_buf_set_lines(diffbuf, pos.ours_lnum - 1, pos.theirs_lnum, false, suggested)
    vim.api.nvim_set_current_win(diffwin)
    vim.cmd("diffthis")
    vim.api.nvim_set_current_win(win)
    vim.cmd("diffthis")
    schedule_marker_updates(buf)
  end
end

--- Go to the next conflict marker.
function M.next()
  local buf_cache = cache[vim.api.nvim_get_current_buf()]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end

  local current_lnum = vim.fn.getpos(".")[2]
  local closest = nil
  local min_positive_dist = nil
  local dist
  for _, marker in pairs(buf_cache.positions) do
    dist = marker.delimiter_lnum - current_lnum
    if
      (dist > 0 and min_positive_dist == nil) or (min_positive_dist ~= nil and dist < min_positive_dist and dist > 0)
    then
      min_positive_dist = dist
      closest = marker.delimiter_lnum
    end
  end

  if closest ~= nil then
    vim.fn.cursor(closest, 0)
  end
end

--- Go to previous conflict marker
function M.previous()
  local buf_cache = cache[vim.api.nvim_get_current_buf()]
  if buf_cache == nil or #buf_cache.positions == 0 then
    return
  end
  local current_lnum = vim.fn.getpos(".")[2]
  local closest = nil
  local max_negative_dist = nil
  local dist
  for _, marker in pairs(buf_cache.positions) do
    dist = marker.delimiter_lnum - current_lnum
    if
      (dist < 0 and max_negative_dist == nil) or (max_negative_dist ~= nil and dist > max_negative_dist and dist < 0)
    then
      max_negative_dist = dist
      closest = marker.delimiter_lnum
    end
  end

  if closest ~= nil then
    vim.fn.cursor(closest, 0)
  end
end

--- Disable markers
--- @param buf integer
function M.disable(buf)
  local buf_cache = cache[buf]
  if buf_cache == nil then
    return
  end
  for _, tracker in pairs(cache[buf].trackers) do
    tracker.detach(buf)
  end

  cache[buf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, buf_cache.augroup)
  clear_all_extarks(buf)
end

--- Enable conflict markers for a given buffer.
---
--- Even if enabled, unless a tracker is active for the current buffer markers
--- will not be rendered.
---
--- Enabling attaches all active trackers.
---
--- @param buf integer
function M.enable(buf)
  if vim.api.nvim_buf_is_loaded(buf) then
    update_buf_cache(buf)

    for _, tracker in pairs(cache[buf].trackers) do
      tracker.attach(buf)
    end

    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function(_, _, _, _, _, _, _, _, _)
        local buf_cache = cache[buf]
        if buf_cache == nil then
          return true
        end
        schedule_marker_updates(buf, 200)
      end,
      on_reload = function()
        schedule_marker_updates(buf)
      end,
      on_detach = function()
        M.disable(buf)
      end,
    })

    setup_autocommand(buf)
    schedule_marker_updates(buf, 200)
  end
end

local default_config = {
  trackers = { M.trackers.git, M.trackers.manual },
  auto_enable = true,
}

M.config = {}

function M.setup(config)
  M.config = vim.tbl_deep_extend("force", default_config, config)
  set_highlight_groups()
  set_decoration_provider()

  local augroup = vim.api.nvim_create_augroup("Conflicting", { clear = true })
  if M.config.auto_enable then
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      auto_enable({ buf = bufnr })
    end

    vim.api.nvim_create_autocmd("BufEnter", {
      group = augroup,
      callback = auto_enable,
    })
  end

  vim.api.nvim_create_autocmd("VimResized", {
    group = augroup,
    callback = function(_)
      for buf, _ in pairs(cache) do
        if vim.api.nvim_buf_is_valid(buf) then
          clear_all_extarks(buf)
          schedule_marker_updates(buf, 0)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = augroup,
    pattern = "*",
    callback = set_highlight_groups,
  })
end

return M
