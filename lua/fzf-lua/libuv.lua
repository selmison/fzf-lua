---@diagnostic disable-next-line: deprecated
local uv = vim.uv or vim.loop

local sysname = uv.os_uname().sysname
local _is_win = sysname:match("Windows") and true or false

local M = {}

local base64 = require("fzf-lua.lib.base64")
local serpent = require("fzf-lua.lib.serpent")

---@param pid integer
---@param signal integer|string?
---@return boolean
M.process_kill = function(pid, signal)
  if not pid or not tonumber(pid) then return false end
  if type(uv.os_getpriority(pid)) == "number" then
    uv.kill(pid, signal or 9)
    return true
  end
  return false
end

local function coroutine_callback(fn)
  local co = coroutine.running()
  local callback = function(...)
    -- not sure what happened here...
    -- if not M or not co then return end
    if coroutine.status(co) == "suspended" then
      coroutine.resume(co, ...)
    else
      local pid = unpack({ ... }) ---@cast pid integer
      M.process_kill(pid)
    end
  end
  fn(callback)
  return coroutine.yield()
end

local function coroutinify(fn)
  return function(...)
    local args = { ... }
    return coroutine.wrap(function()
      return coroutine_callback(function(cb)
        table.insert(args, cb)
        fn(unpack(args))
      end)
    end)()
  end
end

-- fix environ for uv.spawn
---@param cmd string
---@param opts uv.spawn.options
---@param on_exit fun(code: integer, signal: integer)
---@return uv.uv_process_t handle
---@return integer pid
M.uv_spawn = function(cmd, opts, on_exit)
  opts.env = (function()
    -- uv.spawn will override all env when table provided?
    -- steal from $VIMRUNTIME/lua/vim/_system.lua
    local env = vim.fn.environ() --- @type table<string,string>
    env["NVIM"] = vim.v.servername
    env["NVIM_LISTEN_ADDRESS"] = nil
    env = vim.tbl_extend("keep", opts.env or {}, env or {})
    local renv = {} --- @type string[]
    for k, v in pairs(env) do
      renv[#renv + 1] = string.format("%s=%s", k, tostring(v))
    end
    return renv
  end)() ---@diagnostic disable-next-line: unnecessary-assert, return-type-mismatch
  return assert(uv.spawn(cmd, opts, on_exit))
end


---@class fzf-lua.SpawnOpts
---@field cwd? string
---@field cmd string|table
---@field env? table
---@field cb_finish fun(code: integer, sig: integer, from: string, pid: integer)
---@field cb_write fun(data: string, cb: fun(err: any): nil): nil
---@field cb_err fun(data: string)
---@field cb_pid? fun(pid: integer)
---@field fn_transform? fun()
---@field EOL? string
---@field EOL_data? string
---@field process1? boolean
---@field profiler? boolean

-- or table address
local gen_uuid = function()
  -- return uv.random(10)
  return uv.hrtime()
end

---@param opts fzf-lua.SpawnOpts
---@return uv.uv_process_t proc
---@return integer         pid
M.spawn = function(opts)
  local EOL = opts.EOL or "\n"
  local EOL_data = type(opts.cmd) == "string"
      -- fd -0|--print0
      -- rg -0|--null
      -- grep -Z|--null
      -- find . -print0
      and (opts.cmd:match("%s%-0")
        or opts.cmd:match("%s%-?%-print0") -- -print0|--print0
        or opts.cmd:match("%s%-%-null")
        or opts.cmd:match("%s%-Z"))
      and "\0" or "\n"
  local EOL_byte = EOL_data:byte()
  local output_pipe = assert(uv.new_pipe(false))
  local error_pipe = assert(uv.new_pipe(false))
  local write_cb_count = 0
  local handle, pid ---@type uv.uv_process_t, integer
  -- TODO: puc lua won't work here
  local strbuf = (vim.F.nil_wrap(require)("vim._core.stringbuffer") or
    require("fzf-lua.lib.stringbuffer")).new()
  local work_ctx

  local can_finish = function()
    return not output_pipe:is_active() -- EOF signalled or process is aborting
        and write_cb_count == 0        -- no outstanding write callbacks
        and #strbuf == 0
  end

  ---@diagnostic disable-next-line: redefined-local
  local finish = function(code, sig, from, pid)
    -- Uncomment to debug pipe closure timing issues (#1521)
    -- output_pipe:close(function() print("closed o") end)
    -- error_pipe:close(function() print("closed e") end)
    if not output_pipe:is_closing() then output_pipe:close() end
    if not error_pipe:is_closing() then error_pipe:close() end
    if opts.cb_finish then
      opts.cb_finish(code, sig, from, pid)
    end
    strbuf:reset()
    if not handle:is_closing() then
      handle:kill("sigterm")
      vim.defer_fn(function()
        if not handle:is_closing() then
          handle:kill("sigkill")
        end
      end, 200)
    end
  end

  -- https://github.com/luvit/luv/blob/master/docs.md
  -- uv.spawn returns tuple: handle, pid
  local shell = _is_win and "cmd.exe" or "sh"
  local args = _is_win and { "/d", "/e:off", "/f:off", "/v:on", "/c" } or { "-c" }
  if type(opts.cmd) == "table" then
    if _is_win then
      vim.list_extend(args, opts.cmd)
    else
      table.insert(args, table.concat(opts.cmd, " "))
    end
  else
    table.insert(args, tostring(opts.cmd))
  end

  handle, pid = M.uv_spawn(shell, {
    args = args,
    stdio = { nil, output_pipe, error_pipe },
    cwd = opts.cwd,
    env = opts.env,
    verbatim = _is_win,
  }, function(code, signal)
    if can_finish() or code ~= 0 then
      -- Do not call `:read_stop` or `:close` here as we may have data
      -- reads outstanding on slower Windows machines (#1521), only call
      -- `finish` if all our `uv.write` calls are completed and the pipe
      -- is no longer active (i.e. no more read cb's expected)
      finish(code, signal, "[on_exit]", pid)
    end
    handle:close()
  end)

  -- save current process pid
  if opts.cb_pid then opts.cb_pid(pid) end

  local function write_cb(data)
    -- write_cb_count = write_cb_count + 1
    opts.cb_write(data, function(err)
      write_cb_count = write_cb_count - 1
      if err then
        -- can fail with premature process kill
        -- assert(not err)
        finish(130, 0, "[write_cb: err]", pid)
      elseif can_finish() then
        -- on_exit callback already called and did not close the
        -- pipe due to write_cb_count>0, since this is the last
        -- call we can close the fzf pipe
        finish(0, 0, "[write_cb: finish]", pid)
      end
    end)
  end

  local uuid = gen_uuid() -- distinguish two call when use worker pool
  local optstr = require("fzf-lua.libuv").serialize(opts.opts, false)
  -- TODO: not correct for live_grep multiprocess=false? uuid?
  ---@param data string data stream
  ---@return string, string? line array, partial last line (no EOL)
  local function split_lines(data, o, id)
    -- io.stderr:write("[DEBUG] worker init")
    if not _G.uuid then
      -- TODO: we can pass serialize opts to first queue...
      local __FILE__ = assert(debug.getinfo(1, "S")).source:gsub("^@", "")
      local lua = vim.fs.dirname(vim.fs.dirname(__FILE__))
      package.path = ("%s/?.lua;"):format(lua) .. package.path
      package.path = ("%s/?/init.lua;"):format(lua) .. package.path
      vim.fn = {}
      -- TODO: serialize a necessary helper module to access vim state
      vim.fn.has = function(feature)
        if feature:match("nvim%-0.12") then return 1 end
        if feature:match("nvim%-0.11") then return 1 end
        if feature:match("nvim%-0.10") then return 1 end
        if feature:match("nvim%-0.9") then return 1 end
        return 0
      end
      require("fzf-lua.make_entry")
      local devicons = vim.fs.normalize("~/lazy/nvim-web-devicons/lua")
      package.path = ("%s/?.lua;"):format(devicons) .. package.path
      package.path = ("%s/?/init.lua;"):format(devicons) .. package.path
      vim.F = require("vim.F")
      vim.o = {}
      setmetatable(vim.api, { __index = function() return function() end end })
    end
    -- TODO: deserialize to string then eval here, otherwise we cannot use upvalue
    -- TODO: on buf? swtich gitsigns/diff_int.lua:32: bad argument #1 to 'decode' (string expected, got nil)
    if id ~= _G.uuid then -- refresh opts
      _G.opts = FzfLua.libuv.deserialize(o, false)
      local opts = _G.opts
      local load_fn = FzfLua.libuv.load_fn
      if not _G.uuid then
        local fn_preprocess = load_fn(opts.fn_preprocess) or opts.fn_preprocess
        if fn_preprocess then fn_preprocess(opts) end
      end
      if opts.fn_transform then _G.trans = load_fn(opts.fn_transform) end
      _G.uuid = id
    end

    -- local trans = require("fzf-lua.make_entry").file
    -- local worker_opts = assert(_G.fzf_lua_worker_opts, "no opts")
    local trans = _G.trans
    local opts = _G.opts
    local ret = {}
    local start_idx = 1
    repeat
      local nl_idx = data:find(EOL_data or "\n", start_idx, true)
      if nl_idx then
        local cr = data:byte(nl_idx - 1, nl_idx - 1) == 13 -- \r
        local line = data:sub(start_idx, nl_idx - (cr and 2 or 1))
        -- line = trans(line, worker_opts)
        if trans then line = trans(line, opts) end
        if line then ret[#ret + 1] = line end
        start_idx = nl_idx + 1
      end
    until not nl_idx or start_idx > #data
    ret[#ret + 1] = ""
    return table.concat(ret, "\n")
  end

  work_ctx = uv.new_work(split_lines, write_cb)

  local co = coroutine.create(function()
    local stop = 0
    while true do
      local len = #strbuf
      local ref = strbuf:ref()
      if output_pipe:is_closing() then
        if len == 0 then return end
        if ref[len - 1] ~= EOL_byte then strbuf:put(EOL_byte) end -- make split_lines happy
        write_cb_count = write_cb_count + 1
        return work_ctx:queue(strbuf:get(), optstr, uuid)
      end
      local eol = len
      for i = len - 1, stop, -1 do
        if ref[i] == EOL_byte then
          eol = i
          break
        end
      end
      if eol == len then
        stop = len -- no EOL found, wait for more data
        coroutine.yield()
      else
        local data = strbuf:get(eol + 1)
        stop = #strbuf
        write_cb_count = write_cb_count + 1
        work_ctx:queue(data, optstr, uuid)
      end
    end
    if can_finish() then finish(0, 0, "[EOF]", pid) end
  end)

  local read_cb = function(err, data)
    if err then
      return finish(130, 0, "[read_cb: err]", pid)
    elseif data then
      strbuf:put(data)
    else -- EOF signalled, we can close the pipe
      output_pipe:close()
    end
    if #strbuf > 100000 or output_pipe:is_closing() then
      assert(coroutine.resume(co))
    end
  end

  local err_cb = function(err, data)
    if err then
      finish(130, 0, "[err_cb]", pid)
    end
    if not data then
      return
    end
    if opts.cb_err then
      opts.cb_err(data)
    else
      write_cb(data)
    end
  end

  if not handle then
    -- uv.spawn failed, error will be in 'pid'
    -- call once to output the error message
    -- and second time to signal EOF (data=nil)
    err_cb(nil, pid .. EOL)
    err_cb(pid, nil)
  else
    output_pipe:read_start(read_cb)
    error_pipe:read_start(err_cb)
  end

  return handle, pid
end

-- Coroutine version of spawn so we can use queue
M.async_spawn = coroutinify(M.spawn)

---@param obj table
---@param b64? boolean
---@return string, boolean -- boolean used for ./scripts/headless_fd.sh
M.serialize = function(obj, b64)
  local str = serpent.line(obj, { comment = false, sortkeys = false })
  str = b64 ~= false and base64.encode(str) or str
  return "return [==[" .. str .. "]==]", (b64 ~= false and true or false)
end

---@param str string
---@param b64? boolean
---@return table
M.deserialize = function(str, b64)
  local res = assert(loadstring(str))()
  if type(res) == "table" then return res --[[@as table]] end -- ./scripts/headless_fd.sh
  res = b64 ~= false and base64.decode(res) or res
  -- safe=false enable call function
  local _, obj = serpent.load(res, { safe = false })
  assert(type(obj) == "table", vim.inspect(obj))
  return obj
end

---@param fn_str any
---@return function?
M.load_fn = function(fn_str)
  if type(fn_str) ~= "string" then return end
  local fn_loaded = nil
  local fn = loadstring(fn_str)
  if fn then fn_loaded = fn() end
  if type(fn_loaded) ~= "function" then
    fn_loaded = nil
  end
  return fn_loaded
end

---no return
local posix_exec = function(cmd)
  if type(cmd) ~= "string" or _is_win or not pcall(require, "ffi") then return end
  require("ffi").cdef([[int execl(const char *, const char *, ...);]])
  require("ffi").C.execl("/bin/sh", "sh", "-c", cmd, nil)
end

---@param opts fzf-lua.SpawnStdioOpts
---@return uv.uv_process_t?, integer?
M.spawn_stdio = function(opts)
  -- stdin/stdout are already buffered, not stderr. This means
  -- that every character is flushed immediately which caused
  -- rendering issues on Mac (#316, #287) and Linux (#414)
  -- switch 'stderr' stream to 'line' buffering
  -- https://www.lua.org/manual/5.2/manual.html#pdf-file%3asetvbuf
  io.stderr:setvbuf "line"

  -- redirect 'stderr' to 'stdout' on Macs by default
  -- only takes effect if 'opts.stderr' was not set
  if opts.stderr_to_stdout == nil and sysname == "Darwin" then
    opts.stderr_to_stdout = true
  end

  -- setup global vars
  for k, v in pairs(opts.g or {}) do _G[k] = v end

  ---@diagnostic disable-next-line: undefined-field
  local EOL = _G._EOL or opts.multiline and "\0" or "\n"

  -- Requiring make_entry will create the pseudo `_G.FzfLua` global
  -- Must be called after global vars are created or devicons will
  -- err with "fzf-lua fatal: '_G._fzf_lua_server', '_G._devicons_path' both nil"
  require("fzf-lua.make_entry")

  -- still need load_fn from str val? now deserialize do all the thing automatically
  -- or because we want to debugprint them, so we still make a string?
  local fn_transform = M.load_fn(opts.fn_transform) or opts.fn_transform
  local fn_preprocess = M.load_fn(opts.fn_preprocess) or opts.fn_preprocess
  local fn_postprocess = M.load_fn(opts.fn_postprocess) or opts.fn_postprocess

  local argv = function(i)
    local idx = tonumber(i) or #_G.arg
    local arg = _G.arg[idx]
    if opts.debug == "v" or opts.debug == 2 then
      io.stdout:write(("[DEBUG] raw_argv(%d) = %s" .. EOL):format(idx, arg))
    end
    -- TODO: maybe not needed anymore? since we're not using v:argv
    if _is_win then
      arg = M.unescape_fzf(arg, FzfLua.utils.has(opts, "fzf", { 0, 52 }) and 0.52 or 0)
    end
    if opts.debug == "v" or opts.debug == 2 then
      io.stdout:write(("[DEBUG] esc_argv(%d) = %s" .. EOL):format(idx, M.shellescape(arg)))
    end
    return arg
  end

  -- Since the `rg` command will be wrapped inside the shell escaped
  -- 'nvim -l ...', we won't be able to search single quotes
  -- NOTE: since we cannot guarantee the positional index
  -- of arguments (#291), we use the last argument instead
  if opts.is_live and type(opts.contents) == "string" then
    opts.contents = FzfLua.make_entry.expand_query(opts, assert(argv()), opts.contents)
  end

  -- run the preprocessing fn
  if fn_preprocess then fn_preprocess(opts) end

  ---@type fzf-lua.content|fzf-lua.shell.data2?
  local content = opts.contents
  if type(content) == "string" and content:match("%-%-color[=%s]+never") then
    -- perf: skip stripping ansi coloring in `make_file.entry`
    opts.no_ansi_colors = true
  end

  if opts.debug == "v" or opts.debug == 2 then
    for k, v in vim.spairs(opts) do
      io.stdout:write(string.format("[DEBUG] %s=%s" .. EOL, k, vim.inspect(v)))
    end
  elseif opts.debug then
    io.stdout:write("[DEBUG] [mt] " .. tostring(content) .. EOL)
  end

  local stderr, stdout = nil, nil

  local function stderr_write(msg)
    -- prioritize writing errors to stderr
    if stderr then
      stderr:write(msg)
    else
      io.stderr:write(msg)
    end
  end

  local function exit(exit_code, msg)
    if msg then stderr_write(msg) end
    os.exit(exit_code)
  end

  local function pipe_open(pipename)
    if not pipename then return end
    local fd = assert(uv.fs_open(pipename, "w", -1))
    if type(fd) ~= "number" then
      exit(1, ("error opening '%s': %s" .. EOL):format(pipename, fd))
    end
    local pipe = assert(uv.new_pipe(false))
    pipe:open(fd)
    return pipe
  end

  local function pipe_close(pipe)
    if pipe and not pipe:is_closing() then
      pipe:close()
    end
  end

  local function pipe_write(pipe, data, cb)
    if not pipe or pipe:is_closing() then return end
    pipe:write(data,
      function(err)
        -- if the user cancels the call prematurely with
        -- <C-c>, err will be either EPIPE or ECANCELED
        -- don't really need to do anything since the
        -- processes will be killed anyways with os.exit()
        if err then
          stderr_write(("pipe:write error: %s" .. EOL):format(err))
        end
        if cb then cb(err) end
      end)
  end

  if type(opts.stderr) == "string" then
    stderr = pipe_open(opts.stderr)
  end
  if type(opts.stdout) == "string" then
    stdout = pipe_open(opts.stdout)
  end

  local on_finish = function(code)
    pipe_close(stdout)
    pipe_close(stderr)
    if vim.in_fast_event() and fn_postprocess then
      vim.schedule(function()
        fn_postprocess(opts)
        exit(code)
      end)
    else
      if fn_postprocess then fn_postprocess(opts) end
      exit(code)
    end
  end

  local on_write = function(data, cb)
    if stdout then
      pipe_write(stdout, data, cb)
    elseif data then
      -- on success: rc=true, err=nil
      -- on failure: rc=nil, err="Broken pipe"
      -- cb with an err ends the process
      local rc, err = io.stdout:write(data)
      if not rc then
        stderr_write(("io.stdout:write error: %s" .. EOL):format(err))
        cb(err or true)
      else
        cb(nil)
      end
    end
  end

  local on_err = function(data)
    if stderr then
      pipe_write(stderr, data)
    elseif opts.stderr ~= false then
      if opts.stderr_to_stdout then
        io.stdout:write(data)
      else
        io.stderr:write(data)
      end
    end
  end

  local args = function()
    local items = vim.deepcopy(_G.arg)
    items[0] = nil
    table.remove(items, 1)
    return items
  end

  local cmd ---@type string
  if type(content) == "string" then
    cmd = content
  else
    local f = fn_transform or function(x) return x end
    local w = function(s) if s then io.stdout:write(f(s) .. EOL) else on_finish(0) end end
    local wn = function(s) if s then return io.stdout:write(f(s)) else on_finish(0) end end
    if opts.is_live then ---@cast content fzf-lua.shell.data2
      local res = content(args(), opts)
      if not res then return on_finish(0), nil end ---@cast res-?
      content = res
    end
    if type(content) == "function" then content(w, wn) end
    if type(content) == "table" then for _, v in ipairs(content) do w(v) end end
    -- Table/function content was already written to stdout above, the only
    -- content type that requires spawning a child process is a string command.
    -- Without this guard, when `fn_postprocess` is set, `on_finish` defers
    -- `os.exit` via `vim.schedule` and the code falls through to `M.spawn`
    -- which would attempt to execute the table content as a shell command,
    -- resulting in errors like "sh: 1: 1:: not found" appearing as fzf items.
    if type(content) ~= "string" then return on_finish(0), nil end ---@cast content string
    cmd = content
    if opts.debug then
      io.stdout:write(("[DEBUG] [mt] %s" .. EOL):format(content))
    end
  end

  if not fn_transform and not fn_postprocess then return posix_exec(content) end

  return M.spawn({
    cwd = opts.cwd,
    cmd = cmd,
    cb_finish = on_finish,
    cb_write = on_write,
    cb_err = on_err,
    EOL = EOL,
    opts = opts,
  })
end


M.is_escaped = function(s, is_win)
  local m
  -- test spec override
  if is_win == nil then is_win = _is_win end
  if is_win then
    m = s:match([[^".*"$]]) or s:match([[^%^".*%^"$]])
  else
    m = s:match([[^'.*'$]]) or s:match([[^".*"$]])
  end
  return m ~= nil
end

-- our own version of vim.fn.shellescape compatible with fish shells
--   * don't double-escape '\' (#340)
--   * if possible, replace surrounding single quote with double
-- from ':help shellescape':
--    If 'shell' contains "fish" in the tail, the "\" character will
--    be escaped because in fish it is used as an escape character
--    inside single quotes.
--
-- for windows, we assume we want to keep all quotes as literals
-- to avoid the quotes being stripped when run from fzf actions
-- we therefore have to escape the quotes with backslashes and
-- for nested quotes we double the backslashes due to windows
-- quirks, further reading:
-- https://stackoverflow.com/questions/6714165/powershell-stripping-double-quotes-from-command-line-arguments
-- https://learn.microsoft.com/en-us/archive/blogs/twistylittlepassagesallalike/everyone-quotes-command-line-arguments-the-wrong-way
--
-- this function is a better fit for utils but we're
-- trying to avoid having any 'require' in this file
---@param s string
---@param win_style integer|string? 1=classic, 2=caret
---@return string
M.shellescape = function(s, win_style)
  if _is_win or win_style then
    if tonumber(win_style) == 1 then
      --
      -- "classic" CommandLineToArgvW backslash escape
      --
      s = s:gsub([[\-"]], function(x)
        -- Quotes found in string. From the above stackoverflow link:
        --
        -- (2n) + 1 backslashes followed by a quotation mark again produce n backslashes
        -- followed by a quotation mark literal ("). This does not toggle the "in quotes"
        -- mode.
        --
        -- to produce (2n)+1 backslashes we use the following `string.rep` calc:
        -- (#x-1) * 2 + 1 - (#x-1) == #x
        -- which translates to prepending the string with number of escape chars
        -- (\) equal to its own length, this in turn is an **always odd** number
        --
        -- "     ->  \"          (0->1)
        -- \"    ->  \\\"        (1->3)
        -- \\"   ->  \\\\\"      (2->5)
        -- \\\"  ->  \\\\\\\"    (3->7)
        -- \\\\" ->  \\\\\\\\\"  (4->9)
        --
        x = string.rep([[\]], #x) .. x
        return x
      end)
      s = s:gsub([[\+$]], function(x)
        -- String ends with backslashes. From the above stackoverflow link:
        --
        -- 2n backslashes followed by a quotation mark again produce n backslashes
        -- followed by a begin/end quote. This does not become part of the parsed
        -- argument but toggles the "in quotes" mode.
        --
        --   c:\foo\  -> "c:\foo\"    // WRONG
        --   c:\foo\  -> "c:\foo\\"   // RIGHT
        --   c:\foo\\ -> "c:\foo\\"   // WRONG
        --   c:\foo\\ -> "c:\foo\\\\" // RIGHT
        --
        -- To produce equal number of backslashes without converting the ending quote
        -- to a quote literal, double the backslashes (2n), **always even** number
        x = string.rep([[\]], #x * 2)
        return x
      end)
      return [["]] .. s .. [["]]
    else
      --
      -- CMD.exe caret+backslash escape, after lot of trial and error
      -- this seems to be the winning logic, a combination of v1 above
      -- and caret escaping special chars
      --
      -- The logic is as follows
      --   (1) all escaped quotes end up the same \^"
      --   (1) if quote was prepended with backslash or backslash+caret
      --       the resulting number of backslashes will be 2n + 1
      --   (2) if caret exists between the backslash/quote combo, move it
      --       before the backslash(s)
      --   (4) all cmd special chars are escaped with ^
      --
      --   NOTE: explore "tests/libuv_spec.lua" to see examples of quoted
      --      combinations and their expecetd results
      --
      local escape_inner = function(inner)
        inner = inner:gsub([[\-%^?"]], function(x)
          -- although we currently only transfer 1 caret, the below
          -- can handle any number of carets with the regex [[\-%^-"]]
          local carets = x:match("%^+") or ""
          x = carets .. string.rep([[\]], #x - #(carets)) .. x:gsub("%^+", "")
          return x
        end)
        -- escape all windows metacharacters but quotes
        -- ( ) % ! ^ < > & | ; "
        -- TODO: should % be escaped with ^ or %?
        inner = inner:gsub('[%(%)%%!%^<>&|;%s"]', function(x)
          return "^" .. x
        end)
        -- escape backslashes at the end of the string
        inner = inner:gsub([[\+$]], function(x)
          x = string.rep([[\]], #x * 2)
          return x
        end)
        return inner
      end
      s = escape_inner(s)
      if s:match("!") and tonumber(win_style) == 2 then
        --
        -- https://ss64.com/nt/syntax-esc.html
        -- This changes slightly if you are running with DelayedExpansion of variables:
        -- if any part of the command line includes an '!' then CMD will escape a second
        -- time, so ^^^^ will become ^
        --
        -- NOTE: we only do this on demand (currently only used in "libuv_spec.lua")
        --
        s = escape_inner(s)
      end
      s = [[^"]] .. s .. [[^"]]
      return s
    end
  end
  local shell = vim.o.shell
  if not shell or not shell:match("fish$") then
    return vim.fn.shellescape(s)
  else
    local ret = nil
    vim.o.shell = "sh"
    if s and not s:match([["]]) and not s:match([[\]]) then
      -- if the original string does not contain double quotes,
      -- replace surrounding single quote with double quotes,
      -- temporarily replace all single quotes with double
      -- quotes and restore after the call to shellescape.
      -- NOTE: we use '({s:gsub(...)})[1]' to extract the
      -- modified string without the multival # of changes,
      -- otherwise the number will be sent to shellescape
      -- as {special}, triggering an escape for ! % and #
      ret = vim.fn.shellescape(({ s:gsub([[']], [["]]) })[1])
      ret = [["]] .. ret:gsub([["]], [[']]):sub(2, #ret - 1) .. [["]]
    else
      ret = vim.fn.shellescape(s)
    end
    vim.o.shell = shell
    return ret
  end
end

-- Windows fzf oddities, fzf's {q} will send escaped blackslahes,
-- but only when the backslash prefixes another character which
-- isn't a backslash, test with:
-- fzf --disabled --height 30% --preview-window up --preview "echo {q}"
M.unescape_fzf = function(s, fzf_version, is_win)
  if is_win == nil then is_win = _is_win end
  if not is_win then return s end
  if tonumber(fzf_version) and tonumber(fzf_version) >= 0.52 then return s end
  local ret = s:gsub("\\+[^\\]", function(x)
    local bslash_num = #x:match([[\+]])
    return string.rep([[\]],
      bslash_num == 1 and bslash_num or math.floor(bslash_num / 2)) .. x:sub(-1)
  end)
  return ret
end

-- with live_grep, we use a modified "reload" command as our
-- FZF_DEFAULT_COMMAND and due to the above oddity with fzf
-- doing weird extra escaping with {q},  we use this to simulate
-- {q} being sent via the reload action as the initial command
-- TODO: better solution for these stupid hacks (upstream issues?)
M.escape_fzf = function(s, fzf_version, is_win)
  if is_win == nil then is_win = _is_win end
  if not is_win then return s end
  if tonumber(fzf_version) and tonumber(fzf_version) >= 0.52 then return s end
  local ret = s:gsub("\\+[^\\]", function(x)
    local bslash_num = #x:match([[\+]])
    return string.rep([[\]], bslash_num * 2) .. x:sub(-1)
  end)
  return ret
end

-- `vim.fn.escape`
-- (1) On *NIX: double the backslashes as they will be reduced by expand
-- (2) ... other issues we will surely find with special chars
M.expand = function(s)
  if not _is_win then
    s = s:gsub([[\]], [[\\]])
  end
  return vim.fn.expand(s)
end

return M
