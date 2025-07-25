local M = {}


local vim = vim
local fn = vim.fn
local api = vim.api
local loop = vim.loop
local cmd = vim.cmd
local fmt = string.format
local json = vim.json

local VERSION = '0.0.1'

-- Constants
local EXIT_CODE_CONFIG_PARSE_ERROR = 103
local EXIT_CODE_API_KEY_ERROR = 104

--- @class eztracker.Config
--- @field heartbeat_frequency? number # Frequency in minutes to send heartbeats.
--- @field cli_path? string # Absolute path to eztracker-cli. Overrides auto-detection.
--- @field debug? boolean # Enable verbose logging. Defaults to false.
--- @field redraw_setting? "'auto'" | "'enabled'" | "'disabled'"
--- @field api_key_vault_cmd? string # Shell command to retrieve the API key.
--- @field plugin_name? string # Plugin name used in User Agent.

local state = {
  initialized = false,
  --- @type eztracker.Config
  config = {                 -- Default configuration
    heartbeat_frequency = 2, -- minutes
    cli_path = nil,          -- Auto-detect if nil
    debug = true,
    ignore = {               -- Default ignore patterns
      'COMMIT_EDITMSG$',
      'PULLREQ_EDITMSG$',
      'MERGE_MSG$',
      'TAG_EDITMSG$',
    },
    redraw_setting = 'auto', -- 'auto', 'enabled', 'disabled'
    api_key_vault_cmd = nil,
    plugin_name = 'eztracker.nvim',
  },
  home = '',
  plugin_root_folder = '',
  config_file = '',
  shared_state_parent_dir = '',
  shared_state_file = '',
  default_configs_content = {
    '[settings]',
    'debug = false',
    'hidefilenames = false',
    'ignore =',
    '    COMMIT_EDITMSG$',
    '    PULLREQ_EDITMSG$',
    '    MERGE_MSG$',
    '    TAG_EDITMSG$',
  },
  is_windows = fn.has('win32') == 1,
  has_reltime = fn.has('reltime') == 1
      and (fn.localtime() - 1 < tonumber(
        fn.split(fn.split(fn.reltimestr(fn.reltime()))[1], '\\.')[1])),
  config_file_already_setup = false,
  debug_mode_already_setup = false,
  cli_already_setup = false,
  is_debug_on = false,
  local_cache_expire = 10, -- seconds
  last_heartbeat = { last_activity_at = 0, last_heartbeat_at = 0, file = '' },
  heartbeats_buffer = {},
  send_buffer_seconds = 30, -- seconds
  last_sent = fn.localtime(),
  eztracker_cli = 'eztracker_cli',
  autoupdate_cli = false,
  nvim_async_output = {}, -- For collecting job output
  nvim_async_output_today = {},
  nvim_async_output_file_expert = {},
  nvim_async_output_version = {},
  async_callback_today = nil,
  async_callback_file_expert = nil,
  async_callback_version = nil,
}

-- Forward declarations for helper functions
local strip_whitespace
local chomp
local get_ini_setting
local set_ini_setting
local executable
local contains
local setup_debug_mode
local setup_config_file
local get_current_file
local sanitize_arg
local join_args
local current_time_str
local set_last_heartbeat_in_memory
local set_last_heartbeat
local get_last_heartbeat
local append_heartbeat
local send_heartbeats
local handle_activity
local init_and_handle_activity
local print_msg
local print_today
local print_file_expert

-- Helper Functions (Ported from Vimscript s: functions)

strip_whitespace = function(str)
  if not str then return '' end
  return str:match('^%s*(.-)%s*$') or ''
end

chomp = function(str)
  if not str then return '' end
  return str:gsub('\n+$', '')
end

executable = function(path)
  return path
      and path ~= '' and fn.executable(path) == 1
end

contains = function(str, substr)
  if not str or not substr or str == '' or substr == '' then return false end
  return str:find(substr, 1, true) ~= nil
end

get_ini_setting = function(section, key)
  if fn.filereadable(state.config_file) == 0 then return '' end
  local lines = fn.readfile(state.config_file)
  local current_section = ''
  for _, line in ipairs(lines) do
    local trimmed_line = strip_whitespace(line)
    if trimmed_line:match('^%[') and trimmed_line:match('%]$') then
      current_section = trimmed_line:match('^%[(.-)%]$')
    elseif current_section == section then
      local parts = fn.split(trimmed_line, '=', true) -- Keep empty parts
      if #parts >= 2 and strip_whitespace(parts[1]) == key then
        -- Join remaining parts in case value contains '='
        return strip_whitespace(table.concat(parts, '=', 2))
      end
    end
  end
  return ''
end

set_ini_setting = function(section, key, val)
  local output = {}
  local section_found = false
  local key_found = false
  local current_section = ''

  if fn.filereadable(state.config_file) == 1 then
    local lines = fn.readfile(state.config_file)
    for _, line in ipairs(lines) do
      local entry = strip_whitespace(line)
      if entry:match('^%[') and entry:match('%]$') then
        if current_section == section and not key_found then
          -- Add key if section ends before finding it
          table.insert(output, key .. '=' .. val)
          key_found = true
        end
        current_section = entry:match('^%[(.-)%]$')
        table.insert(output, line)
        if current_section == section then section_found = true end
      elseif current_section == section then
        local parts = fn.split(entry, '=', true)
        if #parts >= 2 and strip_whitespace(parts[1]) == key then
          table.insert(output, key .. '=' .. val)
          key_found = true
        else
          table.insert(output, line)
        end
      else
        table.insert(output, line)
      end
    end
  end

  if not section_found then
    table.insert(output, fmt('[%s]', section))
    table.insert(output, key .. '=' .. val)
  elseif not key_found then
    -- Find the section again and insert the key after it
    local inserted = false
    local final_output = {}
    local in_section = false
    for _, line in ipairs(output) do
      table.insert(final_output, line)
      local entry = strip_whitespace(line)
      if entry == fmt('[%s]', section) then
        in_section = true
      elseif in_section and entry:match('^%[') then -- Start of next section
        table.insert(final_output, key .. '=' .. val)
        inserted = true
        in_section = false
      elseif in_section
          and not entry:match('^%s*$')
          and not entry:match('^#')
          and not entry:match('^;') then
        -- Check if it's the last line of the section implicitly
      end
    end
    if not inserted then -- Add at the end if section was last or empty
      table.insert(final_output, key .. '=' .. val)
    end
    output = final_output
  end

  -- Ensure parent directory exists
  local dir = fn.fnamemodify(state.config_file, ':h')
  if fn.isdirectory(dir) == 0 then
    fn.mkdir(dir, 'p', '0o700') -- Use octal notation for permissions
  end

  local ok, err = pcall(fn.writefile, output, state.config_file)
  if not ok then
    vim.notify(fmt('[eztracker] Error writing config file %s: %s',
      state.config_file, err), vim.log.levels.ERROR)
  end
end

setup_debug_mode = function()
  if not state.debug_mode_already_setup then
    -- Prioritize config file setting if it exists
    local debug_setting = get_ini_setting('settings', 'debug')
    if debug_setting == 'true' or state.config.debug == 'true' then
      state.is_debug_on = true
    end
    state.debug_mode_already_setup = true
    if state.is_debug_on then vim.notify('[eztracker] Debug mode enabled.', vim.log.levels.INFO) end
  end
end

setup_config_file = function()
  if not state.config_file_already_setup then
    -- Create config file if it does not exist
    if fn.filereadable(state.config_file) == 0 then
      local dir = fn.fnamemodify(state.config_file, ':h')
      if fn.isdirectory(dir) == 0 then fn.mkdir(dir, 'p', '0o700') end
      local ok, err = pcall(fn.writefile,
        state.default_configs_content, state.config_file)
      if not ok then
        vim.notify(fmt('[eztracker] Error creating config file %s: %s',
          state.config_file, err), vim.log.levels.ERROR)
        return -- Don't proceed if config can't be created
      end
    end

    -- Check for API key
    local api_key = get_ini_setting('settings', 'api_key')
    -- Legacy key name
    if api_key == '' then api_key = get_ini_setting('settings', 'apikey') end

    local found_api_key = (api_key ~= '')

    -- Check vault command
    if not found_api_key then
      local vault_cmd = state.config.api_key_vault_cmd or get_ini_setting('settings',
        'api_key_vault_cmd')
      if vault_cmd and vault_cmd ~= '' then
        local handle = io.popen(vault_cmd)
        if handle then
          local vault_key = handle:read('*a')
          handle:close()
          if vault_key and chomp(vault_key) ~= '' then found_api_key = true end
        end
      end
    end

    -- Check environment variable
    if not found_api_key then
      local env_key = os.getenv('API_KEY')
      if env_key and env_key ~= '' then found_api_key = true end
    end

    if not found_api_key then
      vim.notify(
        '[eztracker] API Key not found. Use :eztrackerApiKey command or set API_KEY env var',
        vim.log.levels.WARN
      )
    else
      state.config_file_already_setup = true
    end
  end
end

local function neovim_async_install_output_handler(job_id, data, event)
  if data then table.insert(state.nvim_async_output, table.concat(data, '\n')) end
end

local function neovim_async_install_exit_handler(job_id, exit_code, event)
  local output = strip_whitespace(table.concat(state.nvim_async_output, '\n'))
  state.nvim_async_output = {} -- Clear buffer
  if state.is_debug_on then
    if exit_code ~= 0 or output ~= '' then
      vim.notify(fmt('[eztracker] Install script exited with code %d:\n%s',
          exit_code, output),
        vim.log.levels.INFO)
    else
      vim.notify('[eztracker] Install script finished successfully.', vim.log.levels.INFO)
    end
  end
  if exit_code ~= 0 and not contains(output, 'eztracker-cli is up to date') then
    vim.notify('[eztracker] Background install failed. Attempting foreground install...',
      vim.log.levels.WARN)
    -- Maybe trigger a synchronous install attempt here if needed, or just notify user.
    -- For simplicity, we'll just notify for now. A foreground retry might block Neovim.
    -- install_cli(false) -- Avoid recursion for now
  end
end

get_current_file = function()
  return fn.expand('%:p') -- Get full path of the current buffer
end

sanitize_arg = function(arg)
  -- Basic sanitization for command line arguments
  -- Lua doesn't have a direct shellescape equivalent as robust as Vim's,
  -- but jobstart often handles arguments safely. We'll do minimal escaping.
  -- This might need refinement depending on edge cases.
  local sanitized = arg:gsub('"', '\\"') -- Escape double quotes
  -- Add more escapes if needed, e.g., for spaces if not using jobstart's list form
  return sanitized
end

join_args = function(args_table)
  -- This is primarily for debug printing the command.
  -- jobstart should be called with the table directly.
  local safe_args = {}
  for _, arg in ipairs(args_table) do
    -- Quote arguments containing spaces for printing
    if arg:find(' ', 1, true) then
      table.insert(safe_args, '"' .. sanitize_arg(arg) .. '"')
    else
      table.insert(safe_args, sanitize_arg(arg))
    end
  end
  return table.concat(safe_args, ' ')
end

current_time_str = function()
  if state.has_reltime then
    -- Extract seconds and fractional part
    local parts = fn.split(fn.reltimestr(fn.reltime()), '\\.')
    if #parts >= 2 then
      return parts[1] .. '.' .. parts[2]
    else
      return parts[1] .. '.0' -- Add fractional part if missing
    end
  end
  return tostring(fn.localtime()) -- Use standard epoch time
end

set_last_heartbeat_in_memory = function(last_activity_at, last_heartbeat_at, file)
  state.last_heartbeat = {
    last_activity_at = last_activity_at,
    last_heartbeat_at = last_heartbeat_at,
    file = file,
  }
end

set_last_heartbeat = function(last_activity_at, last_heartbeat_at, file)
  set_last_heartbeat_in_memory(last_activity_at, last_heartbeat_at, file)
  if fn.isdirectory(state.shared_state_parent_dir) == 0 then
    fn.mkdir(state.shared_state_parent_dir, 'p', '0o700')
  end
  local content = {
    tostring(last_activity_at),
    tostring(last_heartbeat_at),
    file,
  }
  local ok, err = pcall(fn.writefile, content, state.shared_state_file)
  if not ok then
    vim.notify(
      fmt('[eztracker] Error writing shared state file %s: %s',
        state.shared_state_file, err), vim.log.levels.ERROR
    )
  end
end

get_last_heartbeat = function()
  local now = fn.localtime()
  -- Check cache expiry
  if
      state.last_heartbeat.last_activity_at == 0
      or (now - state.last_heartbeat.last_activity_at > state.local_cache_expire)
  then
    if fn.filereadable(state.shared_state_file) == 1 then
      local lines = fn.readfile(state.shared_state_file, '', 3) -- Read max 3 lines
      if #lines >= 3 then
        -- Update cache, keep existing activity time if file hasn't changed
        local current_activity = state.last_heartbeat.last_activity_at
        state.last_heartbeat = {
          -- Preserve last known activity time initially
          last_activity_at = current_activity,
          last_heartbeat_at = tonumber(lines[2]) or 0,
          file = lines[3] or '',
        }
        -- If the file read from disk is different, reset activity time too
        if state.last_heartbeat.file ~= get_current_file() then
          state.last_heartbeat.last_activity_at = tonumber(lines[1]) or 0
        end
      else
        -- File exists but invalid content, reset
        state.last_heartbeat = { last_activity_at = 0, last_heartbeat_at = 0, file = '' }
      end
    else
      -- File doesn't exist, reset
      state.last_heartbeat = { last_activity_at = 0, last_heartbeat_at = 0, file = '' }
    end
    -- Update activity time after reading, regardless of cache hit/miss for file content
    state.last_heartbeat.last_activity_at = now
  end
  return state.last_heartbeat
end

local function order_time(time_str, loop_count)
  -- Add microsecond precision based on loop count to ensure order
  if not time_str:find('%.') then time_str = time_str .. '.0' end
  -- Pad loop count to 6 digits for microseconds
  local micro = string.format('%06d', loop_count)
  return time_str .. micro
end

local function get_heartbeats_json()
  local arr = {}
  local loop_count = 1
  for _, heartbeat in ipairs(state.heartbeats_buffer) do
    local hb_data = {
      entity = heartbeat.entity,
      timestamp = tonumber(order_time(heartbeat.time, loop_count)), -- Send as number
      is_write = heartbeat.is_write,
      duration = heartbeat.duration,
    }
    if heartbeat.language then
      -- Handle 'forth' case sensitivity if needed, though eztracker-cli might handle it
      if string.lower(heartbeat.language) == 'forth' then
        hb_data.language = heartbeat.language
      else
        hb_data.alternate_language = heartbeat.language
      end
    end
    local ok, encoded = pcall(json.encode, hb_data)
    if ok then
      table.insert(arr, encoded)
    else
      vim.notify(fmt('[eztracker] Error encoding heartbeat: %s',
        encoded), vim.log.levels.ERROR)
    end
    loop_count = loop_count + 1
  end
  state.heartbeats_buffer = {} -- Clear buffer after encoding
  return '[' .. table.concat(arr, ',') .. ']'
end

local function neovim_async_output_handler(job_id, data, event)
  -- Collect output for potential debugging or error reporting
  if data then table.insert(state.nvim_async_output, table.concat(data, '\n')) end
end

local function neovim_async_exit_handler(job_id, exit_code, event, cmd_args_str)
  local output = strip_whitespace(table.concat(state.nvim_async_output, '\n'))
  state.nvim_async_output = {} -- Clear buffer

  local is_error = false
  local error_msg = output

  if exit_code == EXIT_CODE_API_KEY_ERROR then
    error_msg = error_msg .. (error_msg ~= '' and
      '\n' or '') .. 'Invalid API Key. Use :eztrackerApiKey'
    is_error = true
    -- Potentially disable future heartbeats until key is fixed?
    state.config_file_already_setup = false -- Force re-check on next event
  elseif exit_code == EXIT_CODE_CONFIG_PARSE_ERROR then
    error_msg = error_msg .. (error_msg ~= '' and
      '\n' or '') .. 'Error parsing config file: ' .. state.config_file
    is_error = true
  elseif exit_code ~= 0 then
    error_msg = error_msg .. (error_msg ~= '' and
      '\n' or '') .. fmt('CLI exited with code %d', exit_code)
    is_error = true
  end

  if is_error or (state.is_debug_on and output ~= '') then
    local level = is_error and vim.log.levels.ERROR or vim.log.levels.DEBUG
    -- Use saved command if available
    local cmd_str = cmd_args_str or join_args(state.last_sent_cmd or {})
    vim.notify(fmt('[eztracker] Command: %s\nOutput (Exit Code %d):\n%s',
      cmd_str, exit_code, error_msg), level)
  end
end

send_heartbeats = function()
  local start_time = loop.hrtime() -- Use high-resolution timer
  local now = fn.localtime()

  if #state.heartbeats_buffer == 0 then
    state.last_sent = now
    return
  end

  if not executable(state.eztracker_cli) then
    if state.is_debug_on then
      vim.notify(
        fmt('[eztracker] Cannot send heartbeats, CLI not executable: %s',
          state.eztracker_cli), vim.log.levels.WARN
      )
    end
    -- Consider clearing buffer or retrying install? For now, just drop them.
    state.heartbeats_buffer = {}
    return
  end

  -- Take the first heartbeat for main args, rest go via stdin
  local heartbeat = table.remove(state.heartbeats_buffer, 1)
  local extra_heartbeats_json = ''

  if #state.heartbeats_buffer > 0 then
    extra_heartbeats_json = get_heartbeats_json() -- This also clears the buffer
  end

  if heartbeat.duration == 0 then
    if state.debug_on then
      vim.notify("Duration is 0, not sending heartbeat", vim.log.levels.DEBUG)
    end
    return
  end

  local cmd_args = { state.eztracker_cli, '--entity', heartbeat.entity }
  table.insert(cmd_args, '--time')
  table.insert(cmd_args, heartbeat.time)

  local plugin_id =
      fmt('%s/%s %s/%s', 'neovim',
        vim.version().major .. '.' .. vim.version().minor,
        state.config.plugin_name, VERSION)

  table.insert(cmd_args, '--plugin')
  table.insert(cmd_args, plugin_id)

  if heartbeat.duration ~= 0 then
    table.insert(cmd_args, '--duration')
    table.insert(cmd_args, tostring(heartbeat.duration))
  end
  if heartbeat.is_write then
    table.insert(cmd_args, '--write')
  end
  if heartbeat.language then
    if string.lower(heartbeat.language) == 'forth' then
      table.insert(cmd_args, '--language')
      table.insert(cmd_args, heartbeat.language)
    else
      table.insert(cmd_args, '--alternate-language')
      table.insert(cmd_args, heartbeat.language)
    end
  end
  if extra_heartbeats_json ~= '' then
    table.insert(cmd_args, '--extra-heartbeats')
    table.insert(cmd_args, extra_heartbeats_json)
  end

  -- Debugging category support (Example using a hypothetical global flag)
  -- if vim.g.is_debugging_session_active then
  --   table.insert(cmd_args, '--category')
  --   table.insert(cmd_args, 'debugging')
  -- end
  -- Or check dap status if available:
  local dap_ok, dap = pcall(require, 'dap')
  if dap_ok and dap.session() then
    table.insert(cmd_args, '--category')
    table.insert(cmd_args, 'debugging')
  end

  if state.is_debug_on then
    vim.notify(fmt('[eztracker] Sending heartbeat(s). Command: %s',
      join_args(cmd_args)), vim.log.levels.DEBUG)
    if extra_heartbeats_json ~= '' then
      vim.notify(fmt('[eztracker] Extra heartbeats JSON: %s', extra_heartbeats_json),
        vim.log.levels.DEBUG)
    end
  end

  state.nvim_async_output = {}   -- Clear output buffer for this job
  state.last_sent_cmd = cmd_args -- Store for potential error reporting

  local job_id = fn.jobstart(cmd_args, {
    on_stdout = neovim_async_output_handler,
    on_stderr = neovim_async_output_handler,
    on_exit = function(j_id, code, event)
      -- Pass command string for context
      neovim_async_exit_handler(j_id, code, event, join_args(cmd_args))
    end,
    stdin = 'pipe', -- Enable stdin pipe
    pty = false,
    -- Detach is generally not needed here as we want to handle exit code/output
  })

  if job_id and job_id > 0 then
    if extra_heartbeats_json ~= '' then fn.chansend(job_id, extra_heartbeats_json .. '\n') end
    fn.chanclose(job_id, 'stdin') -- Close stdin after sending data
  elseif job_id == 0 then
    vim.notify('[eztracker] Failed to start eztracker-cli job (job_id=0).',
      vim.log.levels.ERROR)
  elseif job_id == -1 then
    vim.notify('[eztracker] Failed to start eztracker-cli job (invalid arguments).',
      vim.log.levels.ERROR)
  else
    vim.notify(
      fmt('[eztracker] Failed to start eztracker-cli job (unknown error: %s).',
        tostring(job_id)),
      vim.log.levels.ERROR
    )
  end

  state.last_sent = now

  -- Redraw logic (less critical with async, but kept for parity)

  local end_time = loop.hrtime()
  local duration_ms = (end_time - start_time) / 1e6
  if state.config.redraw_setting ~= 'disabled' then
    if state.config.redraw_setting == 'auto' then
      if duration_ms > 50 then -- Redraw if sending took > 50ms (arbitrary threshold)
        cmd('redraw!')
      end
    elseif state.config.redraw_setting == 'enabled' then
      cmd('redraw!')
    end
  end
end

append_heartbeat = function(file, now, is_write, last)
  local current_file = file
  if not current_file or current_file == '' then current_file = last.file end

  if current_file and current_file ~= '' then
    local heartbeat = {}
    heartbeat.entity = current_file
    heartbeat.time = current_time_str()
    heartbeat.is_write = is_write

    -- Calculate duration since last heartbeat for the same file
    local duration = 0
    if last.file == current_file and last.last_heartbeat_at > 0 then
      duration = now - last.last_heartbeat_at
    end
    heartbeat.duration = duration

    local ft = api.nvim_buf_get_option(0, 'filetype') -- Get filetype for current buffer
    local syn = api.nvim_buf_get_option(0, 'syntax')  -- Get syntax
    if syn and syn ~= '' and syn ~= 'ON' then
      heartbeat.language = syn
    elseif ft and ft ~= '' then
      heartbeat.language = ft
    end

    table.insert(state.heartbeats_buffer, heartbeat)
    set_last_heartbeat(now, now, current_file) -- Update last heartbeat time

    -- No explicit check for buffering enabled, Neovim always supports async.
    -- Sending logic is handled in handle_activity based on time.
    if state.is_debug_on then
      vim.notify(
        fmt('[eztracker] Appended heartbeat for %s (write: %s, duration: %d)', current_file,
          tostring(is_write), duration), vim.log.levels.DEBUG
      )
    end
  end
end

handle_activity = function(is_write)
  if not state.config_file_already_setup then
    if state.is_debug_on then
      vim.notify('[eztracker] Skipping activity: config file not ready.',
        vim.log.levels.DEBUG)
    end
    return
  end

  local file = get_current_file()
  -- Ignore transient buffers or special schemes
  if
      file
      and file ~= ''
      and not file:match('^-MiniBufExplorer-')
      and not file:match('^term:')
      and not file:match('--NO NAME--')
  then
    local last = get_last_heartbeat() -- This also updates last_activity_at in cache
    local now = fn.localtime()

    local enough_time_passed = (now - last.last_heartbeat_at)
        > (state.config.heartbeat_frequency * 60)

    if is_write or enough_time_passed or file ~= last.file then
      append_heartbeat(file, now, is_write, last)
    else
      -- No heartbeat needed, but update activity time in memory if cache expired
      -- get_last_heartbeat() already updates the activity time in the cache now.
      -- We only need to ensure the in-memory representation is consistent
      -- if needed elsewhere immediately.
      -- set_last_heartbeat_in_memory(now, last.last_heartbeat_at, last.file)
      -- Usually not necessary
    end

    -- Check if it's time to send the buffer
    if now - state.last_sent > state.send_buffer_seconds then
      if #state.heartbeats_buffer > 0 then
        if state.is_debug_on then
          vim.notify(fmt('[eztracker] Sending buffered heartbeats (%d)',
            #state.heartbeats_buffer), vim.log.levels.DEBUG)
        end
        send_heartbeats()
      else
        state.last_sent = now -- Update last_sent time even if buffer was empty
      end
    end
  end
end

init_and_handle_activity = function(is_write)
  -- Ensure basic setup runs first
  setup_debug_mode()
  setup_config_file()
  -- Then handle the activity
  handle_activity(is_write)
end

-- User Commands Functions

local function prompt_for_api_key()
  local current_key = get_ini_setting('settings', 'api_key')
  if current_key == '' then current_key = get_ini_setting('settings', 'apikey') end

  local new_key = fn.inputsecret('eztracker API Key: ', current_key)
  if new_key and new_key ~= '' then
    set_ini_setting('settings', 'api_key', new_key)
    state.config_file_already_setup = true -- Assume setup is now complete
    vim.notify('[eztracker] API Key saved.', vim.log.levels.INFO)
  else
    vim.notify('[eztracker] API Key not changed.', vim.log.levels.INFO)
  end
end

local function set_debug_mode(enable)
  local val = enable and 'true' or 'false'
  set_ini_setting('settings', 'debug', val)
  state.is_debug_on = enable
  state.debug_mode_already_setup = true -- Mark as setup
  vim.notify(fmt('[eztracker] Debug mode %s.',
      enable and 'enabled' or 'disabled'),
    vim.log.levels.INFO)
end

local function set_redraw_setting(setting)
  if setting == 'enabled' or setting == 'disabled' or setting == 'auto' then
    set_ini_setting('settings', 'vi_redraw', setting)
    state.config.redraw_setting = setting -- Update runtime state too
    vim.notify(fmt('[eztracker] Screen redraw setting set to: %s', setting),
      vim.log.levels.INFO)
  else
    vim.notify(fmt('[eztracker] Invalid redraw setting: %s', setting), vim.log.levels.ERROR)
  end
end

-- Generic Async Command Runner
local function run_cli_command(args, output_buffer_key, callback_key, exit_handler)
  if not executable(state.eztracker_cli) then
    vim.notify(fmt('[eztracker] Cannot run command, CLI not executable: %s',
      state.eztracker_cli), vim.log.levels.ERROR)

    local cb = state[callback_key] or print_msg
    pcall(cb, 'Error: eztracker-cli not found or not executable.')
    return
  end

  local cmd_args = { state.eztracker_cli }
  for _, arg in ipairs(args) do
    table.insert(cmd_args, arg)
  end

  state[output_buffer_key] = {}                  -- Clear specific output buffer

  local cmd_str_for_notify = join_args(cmd_args) -- For notifications

  if state.is_debug_on then
    vim.notify(fmt('[eztracker] Running command: %s', cmd_str_for_notify),
      vim.log.levels.DEBUG)
  end

  fn.jobstart(cmd_args, {
    on_stdout = function(job_id, data, event)
      if data then table.insert(state[output_buffer_key], table.concat(data)) end
    end,
    on_stderr = function(job_id, data, event)
      -- Mix stderr for simplicity
      if data then table.insert(state[output_buffer_key], table.concat(data)) end
    end,
    on_exit = function(job_id, exit_code, event)
      local output = strip_whitespace(table.concat(state[output_buffer_key], '\n'))
      state[output_buffer_key] = {} -- Clear buffer after use

      if exit_code ~= 0 then
        local err_msg = fmt('Command failed (Exit Code %d)', exit_code)
        if exit_code == EXIT_CODE_API_KEY_ERROR then
          err_msg = err_msg .. ': Invalid API Key'
        end
        output = output .. (output ~= '' and '\n' or '') .. err_msg
        vim.notify(
          fmt('[eztracker] %s\nCommand: %s\nOutput:\n%s', err_msg, cmd_str_for_notify, output),
          vim.log.levels.ERROR
        )
      elseif state.is_debug_on then
        vim.notify(
          fmt('[eztracker] Command finished: %s\nOutput:\n%s', cmd_str_for_notify, output),
          vim.log.levels.DEBUG
        )
      end

      local cb = state[callback_key] or print_msg
      pcall(cb, output) -- Use pcall to prevent callback errors from crashing plugin
    end,
    pty = false,
  })
end

-- Public API Functions (callable via require('eztracker').<func>)

function M.get_today_summary(callback)
  state.async_callback_today = callback or print_today
  run_cli_command({ '--today' }, 'nvim_async_output_today', 'async_callback_today')
end

function M.get_file_experts(callback)
  local file = get_current_file()
  if not file or file == '' then
    file = get_last_heartbeat().file -- Use last known file if current is empty
  end
  if not file or file == '' then
    vim.notify('[eztracker] No file specified or found for file experts.',
      vim.log.levels.WARN)
    if callback then
      pcall(callback, 'No file specified.')
    else
      print_file_expert('No file specified.')
    end
    return
  end
  state.async_callback_file_expert = callback or print_file_expert
  run_cli_command({ '--file-experts', '--entity', file },
    'nvim_async_output_file_expert',
    'async_callback_file_expert')
end

function M.get_cli_location(callback)
  local cb = callback or print_msg
  pcall(cb, state.eztracker_cli or 'Not configured')
end

function M.get_cli_version(callback)
  state.async_callback_version = callback or print_msg
  run_cli_command({ '--version' }, 'nvim_async_output_version', 'async_callback_version')
end

-- Default print functions
print_msg = function(msg) vim.notify(msg, vim.log.levels.INFO) end
print_today = function(msg)
  vim.notify('Today: ' .. (msg or 'No data'),
    vim.log.levels.INFO)
end
print_file_expert = function(msg)
  local output = msg or ''
  if output == '' then output = 'No expert data found for this file.' end
  vim.notify(output, vim.log.levels.INFO)
end

-- Setup Function (Main entry point)

function M.setup(user_config)
  if state.initialized then
    vim.notify('[eztracker] Already initialized.', vim.log.levels.WARN)
    return
  end

  -- Merge user config with defaults
  state.config = vim.tbl_deep_extend('force', state.config, user_config or {})

  -- Determine home directory
  local eztracker_home_env = os.getenv('EZTRACKER_HOME')
  if eztracker_home_env and eztracker_home_env ~= '' then
    state.home = fn.expand(eztracker_home_env)
  else
    state.home = fn.expand('~')           -- Use ~ expansion, reliable on most systems
  end
  state.home = state.home:gsub('\\', '/') -- Normalize path separators

  -- Determine plugin root folder
  -- This relies on debug info, might be fragile if file structure changes.
  local script_path = debug.getinfo(1, 'S').source:sub(2) -- Remove leading '@'
  state.plugin_root_folder = fn.fnamemodify(script_path, ':h:h:h')
  state.plugin_root_folder = state.plugin_root_folder:gsub('\\', '/')

  -- Define paths based on home dir
  state.config_file = state.home .. '/.eztracker.cfg'
  state.shared_state_parent_dir = state.home .. '/.eztracker'
  -- Use different state file than Vim
  state.shared_state_file = state.shared_state_parent_dir .. '/nvim_shared_state'

  -- Apply settings from config file if they exist (e.g., vi_redraw)
  local vi_redraw = get_ini_setting('settings', 'vi_redraw')
  if vi_redraw == 'enabled' or vi_redraw == 'auto' or vi_redraw == 'disabled' then
    state.config.redraw_setting = vi_redraw
  end
  -- Apply debug from config file (will be re-checked in setup_debug_mode)
  local debug_setting = get_ini_setting('settings', 'debug')
  if debug_setting == 'true' then state.config.debug = true end

  -- Initial setup steps
  setup_debug_mode()
  setup_config_file()

  -- Create Autocommands
  local group = api.nvim_create_augroup('eztracker', { clear = true })
  api.nvim_create_autocmd({ 'BufEnter', 'VimEnter' }, {
    group = group,
    pattern = '*',
    callback = function() init_and_handle_activity(false) end,
  })
  api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
    group = group,
    pattern = '*',
    -- Don't re-run full init on cursor hold
    callback = function() handle_activity(false) end,
  })
  api.nvim_create_autocmd({ 'BufWritePost' }, {
    group = group,
    pattern = '*',
    callback = function() handle_activity(true) end, -- Send write event
  })
  api.nvim_create_autocmd({ 'QuitPre' }, {
    group = group,
    pattern = '*',
    callback = function()
      if #state.heartbeats_buffer > 0 then
        if state.is_debug_on then
          vim.notify('[eztracker] Sending final heartbeats before quitting...',
            vim.log.levels.INFO)
        end

        send_heartbeats()
        -- NOTE: Neovim might quit before the async send completes fully.
        -- Consider a synchronous send here if absolutely critical, but it will block exit.
      end
    end,
  })

  -- Create User Commands
  api.nvim_create_user_command('EztrackerApiKey', prompt_for_api_key, { nargs = 0 })
  api.nvim_create_user_command('EztrackerDebugEnable',
    function() set_debug_mode(true) end,
    { nargs = 0 })
  api.nvim_create_user_command('EztrackerDebugDisable',
    function() set_debug_mode(false) end, { nargs = 0 })
  api.nvim_create_user_command(
    'EztrackerScreenRedrawDisable',
    function() set_redraw_setting('disabled') end, { nargs = 0 }
  )
  api.nvim_create_user_command(
    'EztrackerScreenRedrawEnable',
    function() set_redraw_setting('enabled') end, { nargs = 0 }
  )
  api.nvim_create_user_command(
    'EztrackerScreenRedrawEnableAuto',
    function() set_redraw_setting('auto') end,
    { nargs = 0 }
  )
  api.nvim_create_user_command('EztrackerToday',
    function() M.get_today_summary() end, { nargs = 0 })
  api.nvim_create_user_command('EztrackerFileExpert',
    function() M.get_file_experts() end, { nargs = 0 })
  api.nvim_create_user_command('EztrackerCliLocation',
    function() M.get_cli_location() end, { nargs = 0 })
  api.nvim_create_user_command('EztrackerCliVersion',
    function() M.get_cli_version() end, { nargs = 0 })

  state.initialized = true
  vim.notify('[eztracker] Initialized.', vim.log.levels.INFO)

  -- Trigger initial check in case VimEnter already fired before setup completed
  vim.defer_fn(function() init_and_handle_activity(false) end, 100)
end

return M
