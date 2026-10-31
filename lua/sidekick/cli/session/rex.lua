local Config = require("sidekick.config")
local Util = require("sidekick.util")

---@class sidekick.cli.muxer.Rex: sidekick.cli.Session
---@field rex_block_id string
---@field rex_session_id string
---@field rex_pid number
local M = {}
M.__index = M
M.priority = 10
M.external = true

-- Lists terminal blocks across all sessions (or just `rex.args.block`) in one round trip
local LIST_BLOCKS = [[
local term, ret = "com.superlogical.terminal", {}
for _, s in ipairs(rex.call("session.list").sessions or {}) do
  rex.session.attach{ session_id = s.session_id } -- calls on a session need an attachment
  for _, b in ipairs((rex.session.list_blocks{ session_id = s.session_id } or {}).blocks or {}) do
    if b.creator_name == term and (not rex.args.block or rex.args.block == b.block_id) then
      local p = rex.block.call(term, "process", { session_id = s.session_id, block_id = b.block_id })
      if p and p.child then
        ret[#ret + 1] = {
          session_id = s.session_id,
          session_label = s.label or s.session_id,
          block_id = b.block_id,
          pid = p.child.pid,
          cwd = (p.foreground and p.foreground.cwd) or p.child.cwd or "",
        }
      end
    end
  end
end
return ret
]]

---@return sidekick.cli.terminal.Cmd?
function M:start()
  if Config.cli.mux.create == "terminal" then
    Util.warn({
      ("Rex does not support `opts.cli.mux.create = %q`."):format("terminal"),
      ("Falling back to `%q`."):format("split"),
      "Please update your config.",
    })
  end
  local cmd = { "rex", vim.env.REX_SESSION and "split" or "run", "--json", "--focus=false", "-c", self.cwd }
  if vim.env.REX_BLOCK then
    vim.list_extend(cmd, { "-b", vim.env.REX_BLOCK })
  end
  if Config.cli.mux.create ~= "window" then
    local vertical = Config.cli.mux.split.vertical
    local size = Config.cli.mux.split.size
    if size > 1 then -- absolute cells, as a share of this Neovim's pane
      size = size / (vertical and vim.o.columns or vim.o.lines)
    end
    vim.list_extend(cmd, { "--split", vertical and "right" or "below" })
    vim.list_extend(cmd, { "--ratio", tostring(math.floor(math.min(size, 1) * 100 + 0.5)) })
  end
  self:add_cmd(cmd)
  local lines = Util.exec(cmd)
  local ok, created = pcall(vim.json.decode, table.concat(lines or {}, "\n"))
  local block_id = ok and type(created) == "table" and created.block_ids and created.block_ids[1]
  if not block_id then
    return
  end
  local pane = M.panes(block_id)[1]
  if pane then
    self.id = pane.skid
    self.rex_block_id = pane.block_id
    self.rex_session_id = pane.session_id
    self.rex_pid = pane.pid
    self.mux_session = pane.session_label
    self.started = true
  end
  local where = Config.cli.mux.create == "window" and "tab" or "split"
  Util.info(("Started **%s** in a new rex %s"):format(self.tool.name, where))
end

--- Close the rex block (used when detaching).
function M:close()
  if self.rex_block_id then
    Util.exec({ "rex", "block", "close", "-s", self.rex_session_id, self.rex_block_id }, { notify = false })
  end
end

function M:is_running()
  return self.rex_pid and vim.api.nvim_get_proc(self.rex_pid) ~= nil
end

---@param ret string[]
function M:add_cmd(ret)
  ret[#ret + 1] = "--"
  if self.tool.env and next(self.tool.env) then
    ret[#ret + 1] = "env"
    for key, value in pairs(self.tool.env) do
      if value == false then
        vim.list_extend(ret, { "-u", key }) -- unset
      else
        ret[#ret + 1] = ("%s=%s"):format(key, tostring(value))
      end
    end
  end
  vim.list_extend(ret, self.tool.cmd)
end

---@param block_id? string only return this block
function M.panes(block_id)
  local cmd = { "rex", "do", "-e", LIST_BLOCKS }
  if block_id then
    cmd[#cmd + 1] = "block=" .. block_id
  end
  local lines = Util.exec(cmd, { notify = false })
  local ok, blocks = pcall(vim.json.decode, table.concat(lines or {}, "\n"))
  local panes = {} ---@type sidekick.rex.Pane[]
  for _, b in ipairs(ok and vim.islist(blocks) and blocks or {}) do
    ---@class sidekick.rex.Pane
    panes[#panes + 1] = {
      skid = ("rex %s"):format(b.block_id), -- unique id for the pane
      pid = b.pid, -- process id of the terminal's child
      block_id = b.block_id,
      session_id = b.session_id,
      session_label = b.session_label,
      cwd = b.cwd,
    }
  end
  return panes
end

function M.sessions()
  local ret = {} ---@type sidekick.cli.session.State[]
  local tools = Config.tools()

  local Procs = require("sidekick.cli.procs")
  local procs = Procs.new()
  for _, pane in ipairs(M.panes()) do
    procs:walk(pane.pid, function(proc)
      for _, tool in pairs(tools) do
        if tool:is_proc(proc) then
          ret[#ret + 1] = {
            id = pane.skid,
            cwd = proc.cwd or pane.cwd,
            tool = tool,
            rex_block_id = pane.block_id,
            rex_session_id = pane.session_id,
            rex_pid = pane.pid,
            mux_session = pane.session_label,
            pids = Procs.pids(pane.pid),
          }
          return true
        end
      end
    end)
  end

  return ret
end

---@param event table
function M:event(event)
  local args = { session_id = self.rex_session_id, block_id = self.rex_block_id, event = event }
  Util.exec({ "rex", "api", "call", "block.event", "-" }, { stdin = vim.json.encode(args) })
end

---Send text to a rex block
function M:send(text)
  local function send()
    self:event({ type = "paste", payload = { text = text } })
  end

  if self.tool.mux_focus then
    -- Send focus-in event first (some TUI apps like qwen ignore input when unfocused)
    self:event({ type = "focus", payload = { action = "in" } })
    vim.defer_fn(send, 50) -- slight delay to ensure focus event is processed first
  else
    send()
  end
end

---Submit the current input in a rex block
function M:submit()
  Util.exec({ "rex", "send-key", "-s", self.rex_session_id, "-b", self.rex_block_id, "enter" })
end

function M:dump()
  if not self.rex_block_id then
    return
  end
  local _, out =
    Util.exec({ "rex", "capture", "-s", self.rex_session_id, "-b", self.rex_block_id, "--format", "vt", "--trim" })
  if not out then
    return
  end
  local lines = vim.split(out, "\n", { plain = true })
  return table.concat(vim.list_slice(lines, math.max(1, #lines - Config.cli.mux.dump + 1)), "\n")
end

return M
