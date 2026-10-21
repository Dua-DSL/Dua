local Dua = { _VERSION = "Dua 1.1" }

local type, tostring, tonumber, pairs, ipairs = type, tostring, tonumber, pairs, ipairs
local select, error, pcall, next = select, error, pcall, next
local rawget, rawset, rawequal = rawget, rawset, rawequal
local setmetatable, getmetatable = setmetatable, getmetatable
local sfmt, ssub, sfind, smatch, sgsub, srep =
  string.format, string.sub, string.find, string.match, string.gsub, string.rep
local tconcat, tsort = table.concat, table.sort
local unpack = unpack or table.unpack
local dgetinfo = debug.getinfo

local HOST = _G
local SELF_SOURCE = dgetinfo(1, "S").source

local STATES = {}
local SYMBOL_NAME = setmetatable({}, { __mode = "k" })
local NodeMT = {}
local current = nil
local as_type, word_candidates

local LUA_KEYWORDS = {}
for _, k in ipairs { "and", "break", "do", "else", "elseif", "end", "false", "for",
                     "function", "if", "in", "local", "nil", "not", "or", "repeat",
                     "return", "then", "true", "until", "while" } do
  LUA_KEYWORDS[k] = true
end

local function trim(s) return (smatch(s, "^%s*(.-)%s*$")) end

local function split(s, sep)
  local out, pos = {}, 1
  while true do
    local a, b = sfind(s, sep, pos, true)
    if not a then
      out[#out + 1] = ssub(s, pos)
      break
    end
    out[#out + 1] = ssub(s, pos, a - 1)
    pos = b + 1
  end
  return out
end

local function maxn(t)
  local m = 0
  for k in pairs(t) do
    if type(k) == "number" and k > m and k % 1 == 0 then m = k end
  end
  return m
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  tsort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    if ta == "number" or ta == "string" then return a < b end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function is_array_key(k, n)
  return type(k) == "number" and k >= 1 and k <= n and k % 1 == 0
end

local function distance(a, b)
  local la, lb = #a, #b
  if la == 0 then return lb end
  if lb == 0 then return la end
  local d = {}
  for i = 0, la do d[i] = { [0] = i } end
  for j = 0, lb do d[0][j] = j end
  for i = 1, la do
    local ca = ssub(a, i, i)
    for j = 1, lb do
      local cb = ssub(b, j, j)
      local v = d[i - 1][j] + 1
      local ins = d[i][j - 1] + 1
      if ins < v then v = ins end
      local sub = d[i - 1][j - 1] + ((ca == cb) and 0 or 1)
      if sub < v then v = sub end
      if i > 1 and j > 1 and ca == ssub(b, j - 1, j - 1) and ssub(a, i - 1, i - 1) == cb then
        local tr = d[i - 2][j - 2] + 1
        if tr < v then v = tr end
      end
      d[i][j] = v
    end
  end
  return d[la][lb]
end

local function suggest(name, candidates)
  if type(name) ~= "string" or #name == 0 then return nil end
  local limit = (#name <= 4) and 1 or ((#name <= 8) and 2 or 3)
  local lname = name:lower()
  local best, bestd
  for _, c in ipairs(candidates) do
    if type(c) == "string" and c ~= name then
      local d = distance(lname, c:lower())
      if d <= limit and (not bestd or d < bestd) then best, bestd = c, d end
    end
  end
  return best
end

local function hint(name, candidates)
  local s = suggest(name, candidates)
  return s and (" (did you mean '" .. s .. "'?)") or ""
end

local ESC = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function quote(s, max)
  if max and #s > max then s = ssub(s, 1, max - 3) .. "..." end
  return '"' .. (sgsub(s, '[\\"\n\r\t]', ESC)) .. '"'
end

local function fmt_number(n)
  if math.type and math.type(n) == "integer" then return sfmt("%d", n) end
  return sfmt("%.14g", n)
end

local function got(v)
  local t = type(v)
  if v == nil then return "nil" end
  if t == "string" then return "string (" .. quote(v, 40) .. ")" end
  if t == "number" then return "number (" .. fmt_number(v) .. ")" end
  if t == "boolean" then return "boolean (" .. tostring(v) .. ")" end
  if t == "table" then
    if SYMBOL_NAME[v] then return "symbol '" .. SYMBOL_NAME[v] .. "'" end
    if getmetatable(v) == NodeMT then return "node '" .. rawget(v, "kind") .. "'" end
    if STATES[v] then return "node '" .. STATES[v].entry.name .. "'" end
  end
  return t
end

local function inline(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "string" then return quote(v)
  elseif t == "number" then return fmt_number(v)
  elseif t == "function" then return "<function>"
  elseif t == "table" then
    if SYMBOL_NAME[v] then return SYMBOL_NAME[v] end
    if getmetatable(v) == NodeMT then return "<" .. rawget(v, "kind") .. ">" end
    if STATES[v] then return "<" .. STATES[v].entry.name .. ">" end
    if depth >= 3 then return "{...}" end
    local parts, n = {}, #v
    for i = 1, n do parts[#parts + 1] = inline(v[i], depth + 1) end
    for _, k in ipairs(sorted_keys(v)) do
      if not is_array_key(k, n) then
        local ks = (type(k) == "string" and smatch(k, "^[%a_][%w_]*$")) and k
                   or ("[" .. inline(k, depth + 1) .. "]")
        parts[#parts + 1] = ks .. "=" .. inline(v[k], depth + 1)
      end
    end
    return "{" .. tconcat(parts, ", ") .. "}"
  end
  return tostring(v)
end

local function copy_value(v, seen)
  if type(v) ~= "table" or SYMBOL_NAME[v] or getmetatable(v) == NodeMT then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[copy_value(k, seen)] = copy_value(x, seen) end
  return out
end

local function is_plain_table(v)
  return type(v) == "table" and not SYMBOL_NAME[v] and not STATES[v] and getmetatable(v) ~= NodeMT
end

local native_setfenv, native_getfenv = setfenv, getfenv

local function env_upvalue(fn)
  for i = 1, 255 do
    local name = debug.getupvalue(fn, i)
    if name == nil then return nil end
    if name == "_ENV" then return i end
  end
end

local function noop() end

local function swap_env(fn, env)
  if native_setfenv then
    local old = native_getfenv(fn)
    if old == env then return noop end
    native_setfenv(fn, env)
    return function() native_setfenv(fn, old) end
  end
  local i = env_upvalue(fn)
  if not i then return nil end
  local _, old = debug.getupvalue(fn, i)
  if old == env then return noop end
  local keep
  local holder = function() return keep end
  debug.upvaluejoin(holder, 1, fn, i)
  debug.upvaluejoin(fn, i, function() return env end, 1)
  return function() debug.upvaluejoin(fn, i, holder, 1) end
end

local function finish_call(restore, ok, ...)
  restore()
  if not ok then error((...), 0) end
  return ...
end

local function call_in_env(fn, env, ...)
  if dgetinfo(fn, "S").what == "C" then return fn(...) end
  local restore = swap_env(fn, env)
  if not restore then return fn(...) end
  return finish_call(restore, pcall(fn, ...))
end

local function load_chunk(src, chunkname)
  if ssub(src, 1, 1) == "\27" then return nil, chunkname .. ":0: binary chunks are not allowed" end
  if loadstring then return loadstring(src, chunkname) end
  return load(src, chunkname, "t")
end

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
  if e.source and e.line then return sfmt("%s:%d: %s", e.source, e.line, e.message) end
  if e.source then return e.source .. ": " .. e.message end
  return e.message
end

local function make_error(kind, message, source, line)
  return setmetatable({ kind = kind, message = message, source = source, line = line }, Error)
end

local function callsite()
  for level = 1, 80 do
    local info = dgetinfo(level, "Sl")
    if not info then return nil end
    if info.what ~= "C" and info.source ~= SELF_SOURCE and info.currentline and info.currentline > 0 then
      return info.short_src, info.currentline
    end
  end
end

local function fail(kind, message, source, line)
  if source == nil then source, line = callsite() end
  error(make_error(kind, message, source, line), 0)
end

local function limit_fail(ctx, message, source, line)
  if source == nil then source, line = callsite() end
  local e = make_error("limit", message, source, line)
  if not ctx.limit_error then ctx.limit_error = e end
  error(e, 0)
end

local function normalize_error(e, source)
  if getmetatable(e) == Error then return e end
  if type(e) == "string" then
    local src, line, msg = smatch(e, "^(.-):(%d+): (.*)$")
    if src then return make_error("runtime", msg, src, tonumber(line)) end
    return make_error("runtime", e, source)
  end
  return make_error("runtime", tostring(e), source)
end

Dua.Error = Error
function Dua.is_error(e) return getmetatable(e) == Error end

local symbol_pool = setmetatable({}, { __mode = "v" })
local SymbolMT = {}
SymbolMT.__tostring = function(s) return SYMBOL_NAME[s] end
SymbolMT.__concat = function(a, b) return tostring(a) .. tostring(b) end
SymbolMT.__call = function(s)
  local name = SYMBOL_NAME[s]
  local extra = ""
  if current then extra = hint(name, word_candidates(current.lang)) end
  fail("unknown", "unknown word '" .. name .. "'" .. extra)
end

function Dua.symbol(name)
  local s = symbol_pool[name]
  if not s then
    s = setmetatable({}, SymbolMT)
    SYMBOL_NAME[s] = name
    symbol_pool[name] = s
  end
  return s
end

function Dua.is_symbol(v) return SYMBOL_NAME[v] ~= nil end
function Dua.symbol_name(v) return SYMBOL_NAME[v] end

local TypeMT = {}
TypeMT.__index = TypeMT
TypeMT.__tostring = function(t) return t.name end

local T = {}

local function new_type(name, check)
  return setmetatable({ name = name, check = check }, TypeMT)
end

local function clone_type(t)
  local c = setmetatable({}, TypeMT)
  for k, v in pairs(t) do c[k] = v end
  return c
end

function TypeMT:opt()
  local c = clone_type(self); c.optional = true; return c
end
function TypeMT:default(v)
  local c = clone_type(self); c.has_default = true; c.default_value = v; return c
end
function TypeMT:desc(text)
  local c = clone_type(self); c.doc = text; return c
end
function TypeMT:coerce()
  local c = clone_type(self); c.coercing = true; return c
end
function TypeMT:where(fn, label)
  local base = self.check
  local c = clone_type(self)
  label = label or "a valid value"
  c.check = function(tp, v)
    local ok, r = base(tp, v)
    if not ok then return false, r end
    if not fn(r) then return false, "expected " .. label .. ", got " .. got(v) end
    return true, r
  end
  return c
end
function TypeMT:range(min, max)
  local label
  if min ~= nil and max ~= nil then label = "a value between " .. min .. " and " .. max
  elseif min ~= nil then label = "a value >= " .. min
  else label = "a value <= " .. tostring(max) end
  return self:where(function(n)
    return type(n) == "number" and (min == nil or n >= min) and (max == nil or n <= max)
  end, label)
end
function TypeMT:matches(pattern, label)
  return self:where(function(s)
    return type(s) == "string" and sfind(s, pattern) ~= nil
  end, label or ("a string matching " .. pattern))
end

T.any = new_type("any", function(_, v) return true, v end)

T.string = new_type("string", function(self, v)
  local t = type(v)
  if t == "string" then return true, v end
  if self.coercing then
    if t == "number" or t == "boolean" then return true, tostring(v) end
    if SYMBOL_NAME[v] then return true, SYMBOL_NAME[v] end
  end
  return false, "expected string, got " .. got(v)
end)

T.number = new_type("number", function(self, v)
  if type(v) == "number" then return true, v end
  if self.coercing and type(v) == "string" then
    local n = tonumber(v)
    if n then return true, n end
  end
  return false, "expected number, got " .. got(v)
end)

T.integer = new_type("integer", function(self, v)
  local ok, n = T.number.check(self, v)
  if ok and n % 1 == 0 then return true, n end
  return false, "expected integer, got " .. got(v)
end)

T.boolean = new_type("boolean", function(self, v)
  if type(v) == "boolean" then return true, v end
  if self.coercing and type(v) == "string" then
    if v == "true" then return true, true end
    if v == "false" then return true, false end
  end
  return false, "expected boolean, got " .. got(v)
end)

T.table = new_type("table", function(_, v)
  if is_plain_table(v) then return true, v end
  return false, "expected table, got " .. got(v)
end)

T.func = new_type("function", function(_, v)
  if type(v) == "function" then return true, v end
  return false, "expected function, got " .. got(v)
end)

T.symbol = new_type("symbol", function(_, v)
  if SYMBOL_NAME[v] then return true, v end
  return false, "expected symbol, got " .. got(v)
end)

function T.node(kind)
  local label = kind and ("node:" .. kind) or "node"
  return new_type(label, function(_, v)
    if getmetatable(v) == NodeMT and (kind == nil or rawget(v, "kind") == kind) then
      return true, v
    end
    return false, "expected " .. label .. ", got " .. got(v)
  end)
end

function T.enum(...)
  local values = { ... }
  if type(values[1]) == "table" and #values == 1 then values = values[1] end
  local set, names = {}, {}
  for i, v in ipairs(values) do
    set[v] = true
    names[i] = tostring(v)
  end
  local label = tconcat(names, "|")
  return new_type(label, function(_, v)
    if SYMBOL_NAME[v] then v = SYMBOL_NAME[v] end
    if set[v] then return true, v end
    return false, "expected one of " .. label .. ", got " .. got(v) .. hint(v, names)
  end)
end

function T.literal(value)
  return new_type(inline(value), function(_, v)
    if v == value then return true, v end
    return false, "expected " .. inline(value) .. ", got " .. got(v)
  end)
end

function T.oneof(...)
  local alts, names = { ... }, {}
  for i, a in ipairs(alts) do
    alts[i] = as_type(a)
    names[i] = alts[i].name
  end
  local label = tconcat(names, "|")
  return new_type(label, function(_, v)
    for _, a in ipairs(alts) do
      local ok, r = a:check(v)
      if ok then return true, r end
    end
    return false, "expected " .. label .. ", got " .. got(v)
  end)
end

function T.list(item)
  item = as_type(item)
  return new_type("[" .. item.name .. "]", function(self, v)
    if not is_plain_table(v) then
      if self.coercing and v ~= nil then
        local ok, r = item:check(v)
        if ok then return true, { r } end
      end
      return false, "expected " .. self.name .. ", got " .. got(v)
    end
    local n, count = #v, 0
    for _ in pairs(v) do count = count + 1 end
    if count ~= n then return false, "expected " .. self.name .. ", got a table that is not a list" end
    local out = {}
    for i = 1, n do
      local ok, r = item:check(v[i])
      if not ok then return false, sfmt("item %d: %s", i, r) end
      out[i] = r
    end
    return true, out
  end)
end

function T.map(value_type)
  value_type = as_type(value_type)
  return new_type("{string=" .. value_type.name .. "}", function(self, v)
    if not is_plain_table(v) then return false, "expected " .. self.name .. ", got " .. got(v) end
    local out = {}
    for _, k in ipairs(sorted_keys(v)) do
      local ok, r = value_type:check(v[k])
      if not ok then return false, sfmt("key '%s': %s", tostring(k), r) end
      out[k] = r
    end
    return true, out
  end)
end

local function build_decls(spec)
  local d = { order = {}, map = {} }
  for _, k in ipairs(sorted_keys(spec)) do
    if type(k) ~= "string" then error("Dua: field names must be strings, got " .. tostring(k), 4) end
    d.order[#d.order + 1] = k
    d.map[k] = as_type(spec[k])
  end
  return d
end

local function check_fields(d, raw, open)
  local out = {}
  for _, k in ipairs(d.order) do
    local tp, v = d.map[k], raw[k]
    if v == nil then
      if tp.has_default then
        out[k] = copy_value(tp.default_value)
      elseif not tp.optional then
        return false, sfmt("missing required field '%s' (%s)", k, tp.name)
      end
    else
      local ok, r = tp:check(v)
      if not ok then return false, sfmt("field '%s': %s", k, r) end
      out[k] = r
    end
  end
  for _, k in ipairs(sorted_keys(raw)) do
    if not d.map[k] then
      if open then
        out[k] = raw[k]
      else
        return false, sfmt("unknown field '%s'%s", tostring(k), hint(k, d.order))
      end
    end
  end
  return true, out
end

function T.shape(spec, open)
  local d = build_decls(spec)
  local names = {}
  for _, k in ipairs(d.order) do names[#names + 1] = k .. ":" .. d.map[k].name end
  return new_type("{" .. tconcat(names, ", ") .. "}", function(self, v)
    if not is_plain_table(v) then return false, "expected " .. self.name .. ", got " .. got(v) end
    return check_fields(d, v, open)
  end)
end

function T.custom(name, fn)
  return new_type(name, function(_, v)
    local r1, r2 = fn(v)
    if r1 then
      if r2 == nil then return true, v end
      return true, r2
    end
    return false, r2 ~= nil and tostring(r2) or ("expected " .. name .. ", got " .. got(v))
  end)
end

local BUILTIN = {
  any = T.any, string = T.string, str = T.string,
  number = T.number, num = T.number, integer = T.integer, int = T.integer,
  boolean = T.boolean, bool = T.boolean, table = T.table,
  ["function"] = T.func, func = T.func, fn = T.func,
  symbol = T.symbol, node = T.node(),
}

local BUILTIN_NAMES = sorted_keys(BUILTIN)

local parse_cache = {}

function T.parse(src)
  local cached = parse_cache[src]
  if cached then return cached end
  local s, default_str = src, nil
  local eq = sfind(s, "=", 1, true)
  if eq then
    default_str = trim(ssub(s, eq + 1))
    s = ssub(s, 1, eq - 1)
  end
  s = trim(s)
  local optional = false
  if ssub(s, -1) == "?" then
    optional = true
    s = trim(ssub(s, 1, -2))
  end

  local tp
  if s == "" then
    tp = T.any
  elseif ssub(s, 1, 1) == "[" and ssub(s, -1) == "]" then
    tp = T.list(T.parse(ssub(s, 2, -2)))
  else
    local alts = split(s, "|")
    local types, unknown = {}, {}
    for i, a in ipairs(alts) do
      a = trim(a)
      alts[i] = a
      local bt = BUILTIN[a]
      if not bt and smatch(a, "^node:[%w_%-]+$") then bt = T.node(ssub(a, 6)) end
      types[i] = bt or false
      if not bt then unknown[#unknown + 1] = a end
    end
    if #unknown == 0 then
      if #types == 1 then tp = types[1] else tp = T.oneof(unpack(types)) end
    elseif #unknown == #alts and #alts > 1 then
      for _, a in ipairs(alts) do
        for _, name in ipairs(BUILTIN_NAMES) do
          if #a >= 4 and distance(a:lower(), name) <= 1 then
            error("Dua: unknown type '" .. a .. "' in '" .. src .. "' (did you mean '" .. name .. "'?)", 3)
          end
        end
      end
      tp = T.enum(alts)
    else
      local bad = unknown[1]
      error("Dua: unknown type '" .. bad .. "' in '" .. src .. "'" .. hint(bad, BUILTIN_NAMES)
            .. "; use Dua.t.enum(...) for literal values", 3)
    end
  end

  if default_str ~= nil then
    local value = default_str
    if tp == T.number or tp == T.integer then
      value = tonumber(default_str)
      if value == nil then error("Dua: bad numeric default in type '" .. src .. "'", 3) end
    elseif tp == T.boolean then
      value = (default_str == "true")
    elseif default_str == "[]" or default_str == "{}" then
      value = {}
    end
    tp = tp:default(value)
  end
  if optional then tp = tp:opt() end
  parse_cache[src] = tp
  return tp
end

function T.from_table(spec)
  local base = T.any
  local ty = spec.type
  if ty == nil and type(spec[1]) == "string" then ty = spec[1] end
  if ty ~= nil then base = as_type(ty) end
  if spec.choices then base = T.enum(spec.choices) end
  if spec.min ~= nil or spec.max ~= nil then base = base:range(spec.min, spec.max) end
  if spec.pattern then base = base:matches(spec.pattern) end
  if spec.coerce then base = base:coerce() end
  if spec.check then base = base:where(spec.check, spec.message) end
  if spec.doc then base = base:desc(spec.doc) end
  if spec.default ~= nil then base = base:default(spec.default) end
  if spec.optional or spec.required == false then base = base:opt() end
  return base
end

as_type = function(spec)
  if spec == nil then return T.any end
  if getmetatable(spec) == TypeMT then return spec end
  local ts = type(spec)
  if ts == "string" then return T.parse(spec) end
  if ts == "function" then return T.custom("custom", spec) end
  if ts == "table" then return T.from_table(spec) end
  error("Dua: invalid type specification: " .. tostring(spec), 3)
end

T.as = as_type
function T.opt(tp) return as_type(tp):opt() end
function T.default(tp, v) return as_type(tp):default(v) end
Dua.t = T

local NodeMethods = {}

NodeMT.__index = function(n, k)
  local m = NodeMethods[k]
  if m ~= nil then return m end
  local f = rawget(n, "fields")
  if f ~= nil then return f[k] end
  return nil
end

local function node_label(kind, args)
  local parts = { kind }
  for i = 1, maxn(args) do
    if args[i] ~= nil then parts[#parts + 1] = inline(args[i]) end
  end
  return tconcat(parts, " ")
end

NodeMT.__tostring = function(n) return node_label(rawget(n, "kind"), rawget(n, "args")) end

local function walk_node(node, fn, depth, parent)
  if fn(node, depth, parent) == false then return end
  for _, c in ipairs(node.children) do walk_node(c, fn, depth + 1, node) end
end

function NodeMethods.get(self, name, default)
  local v = self.fields[name]
  if v == nil then return default end
  return v
end
function NodeMethods.is(self, kind) return self.kind == kind end
function NodeMethods.child(self, kind)
  for _, c in ipairs(self.children) do
    if kind == nil or c.kind == kind then return c end
  end
end
function NodeMethods.all(self, kind)
  local out = {}
  for _, c in ipairs(self.children) do
    if kind == nil or c.kind == kind then out[#out + 1] = c end
  end
  return out
end
function NodeMethods.each(self, kind)
  local list, i = NodeMethods.all(self, kind), 0
  return function()
    i = i + 1
    return list[i]
  end
end
function NodeMethods.find(self, kind)
  local out = {}
  for _, c in ipairs(self.children) do
    walk_node(c, function(n)
      if kind == nil or n.kind == kind then out[#out + 1] = n end
    end, 1, self)
  end
  return out
end
function NodeMethods.walk(self, fn)
  walk_node(self, fn, 0, rawget(self, "parent"))
  return self
end
function NodeMethods.path(self)
  local parts, n = {}, self
  while n do
    local name = rawget(n, "name")
    if name == nil then name = rawget(n, "args")[1] end
    parts[#parts + 1] = rawget(n, "kind") .. (name ~= nil and ("[" .. tostring(name) .. "]") or "")
    n = rawget(n, "parent")
  end
  local rev = {}
  for i = #parts, 1, -1 do rev[#rev + 1] = parts[i] end
  return tconcat(rev, "/")
end

local function plain(v, seen)
  if type(v) ~= "table" then return v end
  if SYMBOL_NAME[v] then return SYMBOL_NAME[v] end
  if getmetatable(v) == NodeMT then return NodeMethods.to_table(v) end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[plain(k, seen)] = plain(x, seen) end
  return out
end

function NodeMethods.to_table(self)
  local t = { kind = rawget(self, "kind") }
  local args = {}
  for i = 1, maxn(self.args) do args[i] = plain(self.args[i]) end
  if next(args) ~= nil then t.args = args end
  if next(self.fields) ~= nil then t.fields = plain(self.fields) end
  if #self.items > 0 then t.items = plain(self.items) end
  if #self.children > 0 then
    t.children = {}
    for i, c in ipairs(self.children) do t.children[i] = NodeMethods.to_table(c) end
  end
  return t
end

local function dump_node(node, indent, out)
  local line = srep("  ", indent) .. node_label(node.kind, node.args)
  for _, k in ipairs(sorted_keys(node.fields)) do
    line = line .. " " .. tostring(k) .. "=" .. inline(node.fields[k])
  end
  if #node.items > 0 then
    local parts = {}
    for i, v in ipairs(node.items) do parts[i] = inline(v) end
    line = line .. " [" .. tconcat(parts, ", ") .. "]"
  end
  out[#out + 1] = line
  for _, c in ipairs(node.children) do dump_node(c, indent + 1, out) end
end

function NodeMethods.dump(self)
  local out = {}
  dump_node(self, 0, out)
  return tconcat(out, "\n")
end

local DocMethods = {}
local DocMT = {}
DocMT.__index = function(d, k)
  local m = DocMethods[k]
  if m ~= nil then return m end
  local s = rawget(d, "settings")
  if s ~= nil then return s[k] end
end
DocMT.__tostring = function(d) return "<dua document: " .. #d.roots .. " root node(s)>" end

function DocMethods.get(self, name, default)
  local v = self.settings[name]
  if v == nil then return default end
  return v
end
function DocMethods.walk(self, fn)
  for _, r in ipairs(self.roots) do walk_node(r, fn, 0, nil) end
  return self
end
function DocMethods.all(self, kind)
  local out = {}
  DocMethods.walk(self, function(n)
    if kind == nil or n.kind == kind then out[#out + 1] = n end
  end)
  return out
end
DocMethods.find = DocMethods.all
function DocMethods.first(self, kind) return DocMethods.all(self, kind)[1] end
function DocMethods.dump(self)
  local out = {}
  for _, k in ipairs(sorted_keys(self.settings)) do
    out[#out + 1] = "@" .. tostring(k) .. " = " .. inline(self.settings[k])
  end
  for _, r in ipairs(self.roots) do dump_node(r, 0, out) end
  return tconcat(out, "\n")
end
function DocMethods.to_table(self)
  local t = { settings = plain(self.settings), roots = {} }
  for i, r in ipairs(self.roots) do t.roots[i] = NodeMethods.to_table(r) end
  return t
end

function Dua.is_node(v) return getmetatable(v) == NodeMT end
function Dua.is_document(v) return getmetatable(v) == DocMT end
function Dua.dump(v)
  if getmetatable(v) == NodeMT then return NodeMethods.dump(v) end
  if getmetatable(v) == DocMT then return DocMethods.dump(v) end
  return inline(v)
end

function Dua.serialize(value, opts)
  opts = opts or {}
  local unit = opts.indent or "  "
  local active = {}
  local function ser(v, level)
    local t = type(v)
    if t == "string" then return sfmt("%q", v)
    elseif t == "number" then
      if v ~= v then return "0/0" end
      if v == math.huge then return "math.huge" end
      if v == -math.huge then return "-math.huge" end
      if math.type then
        if math.type(v) == "integer" then
          if v == math.mininteger then return "math.mininteger" end
          return sfmt("%d", v)
        end
        local num = sfmt("%.17g", v)
        if not sfind(num, "[%.eEn]") then num = num .. ".0" end
        return num
      end
      return sfmt("%.17g", v)
    elseif t == "boolean" or t == "nil" then return tostring(v)
    elseif t == "function" then
      if opts.skip_functions then return "nil" end
      error("Dua.serialize: cannot serialize a function", 3)
    elseif t == "table" then
      if SYMBOL_NAME[v] then return sfmt("%q", SYMBOL_NAME[v]) end
      if getmetatable(v) == NodeMT then v = NodeMethods.to_table(v) end
      if active[v] then error("Dua.serialize: cyclic table", 3) end
      active[v] = true
      local pad, inner = srep(unit, level + 1), srep(unit, level)
      local parts, n = {}, #v
      for i = 1, n do parts[#parts + 1] = pad .. ser(v[i], level + 1) end
      for _, k in ipairs(sorted_keys(v)) do
        if not is_array_key(k, n) then
          local ks
          if type(k) == "string" and smatch(k, "^[%a_][%w_]*$") and not LUA_KEYWORDS[k] then ks = k
          else ks = "[" .. ser(k, level + 1) .. "]" end
          parts[#parts + 1] = pad .. ks .. " = " .. ser(v[k], level + 1)
        end
      end
      active[v] = nil
      if #parts == 0 then return "{}" end
      return "{\n" .. tconcat(parts, ",\n") .. "\n" .. inner .. "}"
    end
    return "nil"
  end
  local body = ser(value, 0)
  if opts.expression then return body end
  return "return " .. body
end

local Language = {}
Language.__index = Language
Language.__tostring = function(L) return "<dua language '" .. L.name .. "'>" end

local function guard_result(ok, ...)
  if not ok then
    local e = ...
    if getmetatable(e) == Error and e.kind == "limit" then error(e, 0) end
  end
  return ok, ...
end

local GUARDED = {
  pcall = function(f, ...) return guard_result(pcall(f, ...)) end,
  xpcall = function(f, handler, ...)
    local n, args = select("#", ...), { ... }
    return guard_result(xpcall(function() return f(unpack(args, 1, n)) end, function(e)
      if getmetatable(e) == Error and e.kind == "limit" then return e end
      return handler(e)
    end))
  end,
}

local function copy_lib(lib, skip)
  local c = {}
  for k, v in pairs(lib) do
    if not (skip and skip[k]) then c[k] = v end
  end
  return c
end

local REAL_LIBS = {
  math = copy_lib(math),
  table = copy_lib(table),
  string = copy_lib(string, { dump = true }),
  os = { time = os.time, clock = os.clock, date = os.date, difftime = os.difftime },
}

local SAFE = {}
for _, n in ipairs { "assert", "error", "ipairs", "next", "pairs",
                     "select", "tonumber", "tostring", "type", "_VERSION" } do
  SAFE[n] = HOST[n]
end
SAFE.unpack = unpack
SAFE.pcall = GUARDED.pcall

local function pattern_exponent(p)
  local q, i, n = 0, 1, #p
  while i <= n do
    local c = ssub(p, i, i)
    if c == "%" then
      i = i + 2
    elseif c == "[" then
      i = i + 1
      if ssub(p, i, i) == "^" then i = i + 1 end
      if ssub(p, i, i) == "]" then i = i + 1 end
      while i <= n and ssub(p, i, i) ~= "]" do
        if ssub(p, i, i) == "%" then i = i + 1 end
        i = i + 1
      end
      i = i + 1
    else
      if c == "*" or c == "+" or c == "-" then q = q + 1 end
      i = i + 1
    end
  end
  if ssub(p, 1, 1) ~= "^" then q = q + 1 end
  return q
end

local function check_pattern(ctx, s, p, plain)
  local max_s = ctx.limits.string
  if max_s and #s > max_s then
    limit_fail(ctx, "string size limit exceeded (" .. fmt_number(max_s) .. " bytes)")
  end
  local max_cost = ctx.limits.pattern
  if not max_cost or plain then return end
  local e = pattern_exponent(p)
  if e > 1 and (#s) ^ e > max_cost then
    limit_fail(ctx, "pattern is too expensive for a subject of " .. #s .. " bytes")
  end
end

local function make_string_lib(ctx)
  local lib = copy_lib(REAL_LIBS.string)
  local real_rep = REAL_LIBS.string.rep
  lib.rep = function(s, n, sep)
    local max_s = ctx.limits.string
    if max_s and type(n) == "number" and (type(s) == "string" or type(s) == "number") then
      local unit = #tostring(s) + ((type(sep) == "string") and #sep or 0)
      if unit * n > max_s then
        limit_fail(ctx, "string size limit exceeded (" .. fmt_number(max_s) .. " bytes)")
      end
    end
    return real_rep(s, n, sep)
  end
  for _, name in ipairs { "find", "match", "gmatch", "gsub" } do
    local real = REAL_LIBS.string[name]
    lib[name] = function(s, p, ...)
      if (type(s) == "string" or type(s) == "number") and type(p) == "string" then
        local plain = false
        if name == "find" then plain = (select(2, ...)) == true end
        check_pattern(ctx, tostring(s), p, plain)
      end
      return real(s, p, ...)
    end
  end
  return lib
end

local FRESH = {
  math = function() return copy_lib(REAL_LIBS.math) end,
  table = function() return copy_lib(REAL_LIBS.table) end,
  os = function() return copy_lib(REAL_LIBS.os) end,
  string = make_string_lib,
}

local function get_lib(ctx, name)
  local lib = ctx.libs[name]
  if not lib then
    lib = FRESH[name](ctx)
    ctx.libs[name] = lib
  end
  return lib
end

local OPERATORS = { add = "__add", sub = "__sub", mul = "__mul", div = "__div", mod = "__mod",
                    pow = "__pow", unm = "__unm", concat = "__concat", eq = "__eq",
                    lt = "__lt", le = "__le" }
local EVENTS = { node = true, document = true }

local function new_language(name, parent)
  local L = setmetatable({
    name = name or "dsl", parent = parent,
    words = {}, order = {}, host = {}, operators = {}, hooks = {},
  }, Language)
  if not parent then
    for k, v in pairs(SAFE) do L.host[k] = { v } end
    for k in pairs(FRESH) do L.host[k] = { fresh = k } end
  end
  return L
end

local function chain(L)
  local list = {}
  while L do
    table.insert(list, 1, L)
    L = L.parent
  end
  return list
end

local function chain_get(L, key)
  while L do
    local v = rawget(L, key)
    if v ~= nil then return v, L end
    L = L.parent
  end
end

local function lookup_word(L, name)
  local depth = 0
  while true do
    local C, w = L, nil
    while C do
      w = C.words[name]
      if w then break end
      C = C.parent
    end
    if not w then return nil end
    if w.kind ~= "alias" then return w end
    name = w.target
    depth = depth + 1
    if depth > 8 then return nil end
  end
end

local function lookup_host(ctx, L, name)
  while L do
    local h = L.host[name]
    if h == false then return false end
    if h then
      if h.fresh then return true, get_lib(ctx, h.fresh) end
      return true, h[1]
    end
    if rawget(L, "host_all") then
      if name == "string" then return true, get_lib(ctx, "string") end
      if GUARDED[name] then return true, GUARDED[name] end
      local v = rawget(HOST, name)
      if v ~= nil then return true, v end
    end
    L = L.parent
  end
  return false
end

word_candidates = function(L)
  local list, seen = {}, {}
  local function add(n)
    if not seen[n] then
      seen[n] = true
      list[#list + 1] = n
    end
  end
  local C = L
  while C do
    for name in pairs(C.words) do add(name) end
    for name, h in pairs(C.host) do
      if h then add(name) end
    end
    C = C.parent
  end
  tsort(list)
  return list
end

local function register(L, name, entry)
  if type(name) ~= "string" or not smatch(name, "^[%a_][%w_]*$") then
    error("Dua: invalid word name " .. tostring(name), 3)
  end
  if LUA_KEYWORDS[name] then
    error("Dua: '" .. name .. "' is a Lua keyword and cannot be used as a DSL word", 3)
  end
  if L.words[name] then
    error("Dua: word '" .. name .. "' is already defined in language '" .. L.name .. "'", 3)
  end
  if entry.name == nil then entry.name = name end
  L.words[name] = entry
  L.order[#L.order + 1] = name
  return entry
end

local function parse_arg_decl(item)
  if type(item) == "table" then
    if type(item.name) ~= "string" then error("Dua: argument declaration needs a name", 4) end
    return { name = item.name, type = T.from_table(item), variadic = item.variadic and true or false }
  end
  if type(item) ~= "string" then error("Dua: bad argument declaration " .. tostring(item), 4) end
  local nm, dots, rest = smatch(item, "^%s*([%a_][%w_]*)(%.*)%s*(.-)%s*$")
  if not nm then error("Dua: bad argument declaration '" .. item .. "'", 4) end
  rest = sgsub(rest, "^:%s*", "")
  local tp = (rest == "") and T.any or T.parse(rest)
  return { name = nm, type = tp, variadic = dots ~= "" }
end

local function compile_args(list)
  local out, seen = {}, {}
  for i, item in ipairs(list) do
    local d = parse_arg_decl(item)
    if seen[d.name] then error("Dua: duplicate argument '" .. d.name .. "'", 4) end
    seen[d.name] = true
    if d.variadic and i ~= #list then error("Dua: variadic argument '" .. d.name .. "' must be last", 4) end
    out[i] = d
  end
  return out
end

local function compile_children(c)
  if c == nil or c == true or c == "*" then return nil end
  local spec = { rules = {}, by = {}, wildcard = false, none = false }
  if c == false then
    spec.none = true
    return spec
  end
  for _, item in ipairs(c) do
    if item == "*" then
      spec.wildcard = true
    else
      local kind, min, max
      if type(item) == "table" then
        kind, min, max = item.kind, item.min or 0, item.max
      else
        local k, suffix = smatch(item, "^([%w_]+)([%?%*%+!]?)$")
        if not k then error("Dua: bad children declaration '" .. tostring(item) .. "'", 4) end
        kind = k
        if suffix == "?" then min, max = 0, 1
        elseif suffix == "+" then min, max = 1, nil
        elseif suffix == "!" then min, max = 1, 1
        else min, max = 0, nil end
      end
      local rule = { kind = kind, min = min, max = max }
      spec.rules[#spec.rules + 1] = rule
      spec.by[kind] = rule
    end
  end
  return spec
end

local function normalize_fields(f)
  local map = {}
  for k, v in pairs(f) do
    if type(k) == "number" then
      if type(v) ~= "string" then error("Dua: field names must be strings", 4) end
      map[v] = map[v] or "any?"
    else
      map[k] = v
    end
  end
  return map
end

local NODE_RAW = { kind = true, args = true, fields = true, items = true, children = true,
                   parent = true, source = true, line = true, lang = true }
local DOC_RAW = { roots = true, settings = true, vars = true, lang = true, source = true }

local function compile_node_spec(owner, name, spec)
  if type(spec) == "string" then spec = { args = { spec } } end
  spec = spec or {}
  if type(spec) ~= "table" then error("Dua: node spec must be a table, got " .. type(spec), 4) end
  local e = { kind = "node", name = name, doc = spec.doc }
  if spec.args ~= nil then e.args = compile_args(spec.args) end
  if spec.fields ~= nil then
    local fmap = normalize_fields(spec.fields)
    for k in pairs(fmap) do
      local reserved = NODE_RAW[k] or NodeMethods[k] ~= nil
      if not reserved and k == "name" and e.args then
        for _, d in ipairs(e.args) do
          if d.name == "name" then reserved = true end
        end
      end
      if not reserved and k == "value" and spec.build then reserved = true end
      if reserved then
        error("Dua: field '" .. tostring(k) .. "' of node '" .. name
              .. "' collides with a built-in node property; pick another name", 4)
      end
    end
    e.fields = build_decls(fmap)
    e.open = spec.open and true or false
  end
  e.children = compile_children(spec.children)
  if spec.items == false then e.items = false
  elseif spec.items ~= nil then e.items = as_type(spec.items) end
  e.validate, e.build = spec.validate, spec.build
  if spec.scope then
    if type(spec.scope) ~= "function" then error("Dua: 'scope' must be a function(sub_language)", 4) end
    local sub = new_language(owner.name .. "." .. name, owner)
    spec.scope(sub)
    e.scope_lang = sub
  end
  return e
end

function Language:node(name, spec)
  local entry = compile_node_spec(self, name, spec)
  register(self, name, entry)
  if type(spec) == "table" and spec.alias then
    local aliases = type(spec.alias) == "string" and { spec.alias } or spec.alias
    for _, a in ipairs(aliases) do register(self, a, { kind = "alias", target = name }) end
  end
  return self
end

function Language:nodes(map)
  for _, v in ipairs(map) do
    if type(v) == "string" then self:node(v) end
  end
  for _, k in ipairs(sorted_keys(map)) do
    if type(k) == "string" then
      local v = map[k]
      if v == true then v = nil end
      self:node(k, v)
    end
  end
  return self
end

function Language:tags(...)
  local names = { ... }
  if type(names[1]) == "table" then names = names[1] end
  for _, n in ipairs(names) do self:node(n) end
  return self
end

local function define_setting(self, kind, name, spec, doc)
  if DOC_RAW[name] or DocMethods[name] ~= nil then
    error("Dua: setting '" .. tostring(name) .. "' collides with a built-in document property", 3)
  end
  local tp = as_type(spec)
  if type(doc) == "string" then tp = tp:desc(doc) end
  register(self, name, { kind = kind, type = tp })
  return self
end

function Language:setting(name, spec, doc) return define_setting(self, "setting", name, spec, doc) end
function Language:property(name, spec, doc) return define_setting(self, "property", name, spec, doc) end
function Language:settings(map)
  for _, k in ipairs(sorted_keys(map)) do self:setting(k, map[k]) end
  return self
end
function Language:properties(map)
  for _, k in ipairs(sorted_keys(map)) do self:property(k, map[k]) end
  return self
end

function Language:const(name, value)
  register(self, name, { kind = "const", value = value })
  return self
end
function Language:consts(map)
  for _, k in ipairs(sorted_keys(map)) do self:const(k, map[k]) end
  return self
end

function Language:func(name, fn)
  if type(fn) ~= "function" then error("Dua: func '" .. tostring(name) .. "' needs a function", 2) end
  register(self, name, { kind = "func", fn = fn })
  return self
end
function Language:funcs(map)
  for _, k in ipairs(sorted_keys(map)) do self:func(k, map[k]) end
  return self
end

function Language:symbols(...)
  local names = { ... }
  if type(names[1]) == "table" then names = names[1] end
  for _, n in ipairs(names) do register(self, n, { kind = "symbol" }) end
  return self
end

function Language:alias(new, old)
  register(self, new, { kind = "alias", target = old })
  return self
end

function Language:allow(...)
  for _, name in ipairs { ... } do
    if FRESH[name] then
      self.host[name] = { fresh = name }
    elseif GUARDED[name] then
      self.host[name] = { GUARDED[name] }
    else
      local v = HOST[name]
      if v == nil then error("Dua: unknown host global '" .. tostring(name) .. "'", 2) end
      self.host[name] = { v }
    end
  end
  return self
end
function Language:allow_all()
  self.host_all = true
  return self
end
function Language:deny(...)
  for _, name in ipairs { ... } do self.host[name] = false end
  return self
end

function Language:unknown(policy, spec)
  local ok = policy == "error" or policy == "nil" or policy == "symbol"
             or policy == "node" or type(policy) == "function"
  if not ok then error("Dua: bad unknown-word policy " .. tostring(policy), 2) end
  self.unknown_policy = policy
  if policy == "node" then
    self.open_spec = spec or {}
    self.open_cache = {}
  end
  return self
end

function Language:assignments(policy)
  if policy ~= "error" and policy ~= "vars" then
    error("Dua: assignments policy must be 'error' or 'vars'", 2)
  end
  self.assign_policy = policy
  return self
end

function Language:limit(limits)
  self.limits_cfg = self.limits_cfg or {}
  for k, v in pairs(limits) do self.limits_cfg[k] = v end
  return self
end

function Language:operator(op, fn)
  if not OPERATORS[op] then error("Dua: unknown operator '" .. tostring(op) .. "'", 2) end
  self.operators[op] = fn
  return self
end

function Language:hook(event, fn)
  if not EVENTS[event] then error("Dua: unknown hook event '" .. tostring(event) .. "'", 2) end
  self.hooks[event] = self.hooks[event] or {}
  table.insert(self.hooks[event], fn)
  return self
end

function Language:extend(name)
  return new_language(name or (self.name .. "+"), self)
end

local function collect_hooks(L, event)
  local list = {}
  for _, C in ipairs(chain(L)) do
    for _, fn in ipairs(C.hooks[event] or {}) do list[#list + 1] = fn end
  end
  return list
end

local function find_operator(L, op)
  while L do
    if L.operators[op] then return L.operators[op] end
    L = L.parent
  end
end

local function collect_settings(L, defs, seen)
  defs, seen = defs or {}, seen or {}
  for _, C in ipairs(chain(L)) do
    for name, w in pairs(C.words) do
      if w.kind == "setting" or w.kind == "property" then defs[name] = w
      elseif defs[name] then defs[name] = nil end
      if w.scope_lang and not seen[w.scope_lang] then
        seen[w.scope_lang] = true
        collect_settings(w.scope_lang, defs, seen)
      end
    end
  end
  return defs
end

local CtxMethods = {}
local CtxMT = { __index = CtxMethods }
local HandleMT = {}

local function label_of(st)
  local e = st.entry
  local a = st.args[1]
  if type(a) == "string" or type(a) == "number" then return e.name .. " " .. inline(a) end
  return e.name
end

local function new_handle(ctx, entry)
  ctx.nodes = ctx.nodes + 1
  local lim = ctx.limits.nodes
  if lim and ctx.nodes > lim then limit_fail(ctx, "node limit exceeded (" .. fmt_number(lim) .. ")") end
  local src, line = callsite()
  local h = setmetatable({}, HandleMT)
  local st = {
    entry = entry, ctx = ctx, handle = h, args = {}, nargs = 0,
    fields = {}, field_lines = {}, children = {}, items = {},
    source = src, line = line, adopted = false,
  }
  STATES[h] = st
  ctx.handles[#ctx.handles + 1] = h
  local frame = ctx.frames[#ctx.frames]
  frame[#frame + 1] = st
  return h
end

local function contains_handle(v, seen)
  if type(v) ~= "table" then return false end
  if STATES[v] then return true end
  if SYMBOL_NAME[v] or getmetatable(v) == NodeMT then return false end
  seen = seen or {}
  if seen[v] then return false end
  seen[v] = true
  for _, x in pairs(v) do
    if contains_handle(x, seen) then return true end
  end
  return false
end

local function deep_adopt(v, seen)
  if type(v) ~= "table" then return end
  local st = STATES[v]
  if st then
    st.adopted = true
    return
  end
  if SYMBOL_NAME[v] or getmetatable(v) == NodeMT then return end
  seen = seen or {}
  if seen[v] then return end
  seen[v] = true
  for k, x in pairs(v) do
    deep_adopt(k, seen)
    deep_adopt(x, seen)
  end
end

local function add_child(st, child, src, line)
  local cs = STATES[child]
  if cs == st then fail("syntax", "a node cannot contain itself", src, line) end
  if cs.ctx ~= st.ctx then fail("syntax", "node belongs to a different run", src, line) end
  cs.adopted = true
  st.children[#st.children + 1] = child
end

local function set_field(st, key, value, src, line)
  local e = st.entry
  if e.fields and not e.open and not e.fields.map[key] then
    fail("unknown", label_of(st) .. ": unknown field '" .. key .. "'" .. hint(key, e.fields.order), src, line)
  end
  deep_adopt(value)
  st.fields[key] = value
  st.field_lines[key] = line
end

local function add_body(st, tbl, src, line)
  local n = #tbl
  for i = 1, n do
    local v = tbl[i]
    if STATES[v] then
      add_child(st, v, src, line)
    else
      deep_adopt(v)
      st.items[#st.items + 1] = v
    end
  end
  for k, v in pairs(tbl) do
    if not is_array_key(k, n) then
      if type(k) ~= "string" then
        fail("syntax", label_of(st) .. ": field names must be strings, got " .. got(k), src, line)
      end
      set_field(st, k, v, src, line)
    end
  end
end

local function scope_env_for(ctx, entry)
  local env = ctx.scope_envs[entry]
  if not env then
    env = ctx.make_env(entry.scope_lang)
    ctx.scope_envs[entry] = env
  end
  return env
end

local function run_body_fn(st, fn, src, line)
  local ctx = st.ctx
  local max_depth = ctx.limits.depth
  if max_depth and ctx.depth >= max_depth then
    limit_fail(ctx, "block nesting limit exceeded (" .. fmt_number(max_depth) .. ")", src, line)
  end
  ctx.depth = ctx.depth + 1
  local frame = {}
  ctx.frames[#ctx.frames + 1] = frame
  local env = ctx.env
  if st.entry.scope_lang then env = scope_env_for(ctx, st.entry) end
  local ok, err = pcall(call_in_env, fn, env, st.handle)
  ctx.frames[#ctx.frames] = nil
  ctx.depth = ctx.depth - 1
  if not ok then error(err, 0) end
  for _, cs in ipairs(frame) do
    if not cs.adopted then
      cs.adopted = true
      st.children[#st.children + 1] = cs.handle
    end
  end
end

local function apply_call(h, ...)
  local st = STATES[h]
  local src, line = callsite()
  for i = 1, select("#", ...) do
    local v = (select(i, ...))
    local t = type(v)
    if t == "table" then
      if STATES[v] then
        add_child(st, v, src, line)
      elseif SYMBOL_NAME[v] then
        st.nargs = st.nargs + 1
        st.args[st.nargs] = v
      elseif getmetatable(v) == NodeMT then
        fail("syntax", label_of(st) .. ": an already built node cannot be used here", src, line)
      else
        add_body(st, v, src, line)
      end
    elseif t == "function" then
      run_body_fn(st, v, src, line)
    else
      st.nargs = st.nargs + 1
      st.args[st.nargs] = v
    end
  end
end

HandleMT.__call = function(h, ...)
  apply_call(h, ...)
  return h
end

HandleMT.__tostring = function(h)
  local st = STATES[h]
  if not st then return "<dua node (finished)>" end
  return "<dua " .. label_of(st) .. ">"
end

local function assign_from_call(h, key, ...)
  local st = STATES[h]
  local src, line = callsite()
  local total = select("#", ...)
  local skip = (total >= 1 and rawequal((...), h)) and 1 or 0
  local count = total - skip
  local value
  if count == 0 then
    local decl = st.entry.fields and st.entry.fields.map[key]
    if decl and decl.name ~= "boolean" and decl.name ~= "any" then
      fail("syntax", label_of(st) .. ": field '" .. key .. "' needs a value (" .. decl.name .. ")", src, line)
    end
    value = true
  elseif count == 1 then
    value = (select(skip + 1, ...))
  else
    value = { select(skip + 1, ...) }
  end
  set_field(st, key, value, src, line)
end

HandleMT.__index = function(h, key)
  local st = STATES[h]
  if not st or type(key) ~= "string" then return nil end
  local e = st.entry
  if e.fields and not e.open and not e.fields.map[key] then
    fail("unknown", label_of(st) .. ": no field or modifier '" .. key .. "'" .. hint(key, e.fields.order))
  end
  return function(...)
    assign_from_call(h, key, ...)
    return h
  end
end

HandleMT.__newindex = function(h, key, value)
  local st = STATES[h]
  if type(key) ~= "string" then fail("syntax", "field names must be strings, got " .. got(key)) end
  local src, line = callsite()
  set_field(st, key, value, src, line)
end

for op, mm in pairs(OPERATORS) do
  HandleMT[mm] = function(a, b)
    local h = STATES[a] and a or b
    local ctx = STATES[h].ctx
    local fn = find_operator(ctx.lang, op)
    if not fn then
      if op == "eq" then return false end
      fail("syntax", "operator '" .. op .. "' is not defined in language '" .. ctx.lang.name .. "'")
    end
    return fn(a, b, ctx)
  end
end

local function assign_setting(ctx, w, value)
  local src, line = callsite()
  local name = w.name
  ctx.explicit[name] = true
  if contains_handle(value) then
    deep_adopt(value)
    ctx.deferred[name] = { value = value, source = src, line = line }
    ctx.settings[name] = value
    return
  end
  local ok, r = w.type:check(value)
  if not ok then fail("validation", "setting '" .. name .. "': " .. r, src, line) end
  ctx.deferred[name] = nil
  ctx.settings[name] = r
end

local function property_setter(ctx, w)
  return function(...)
    local n = select("#", ...)
    local v
    if n == 0 then
      if w.type.name ~= "boolean" then
        fail("syntax", "property '" .. w.name .. "' needs a value (" .. w.type.name .. ")")
      end
      v = true
    elseif n == 1 then
      v = (...)
    else
      v = { ... }
    end
    assign_setting(ctx, w, v)
  end
end

local function eval_word(ctx, w)
  local k = w.kind
  if k == "node" then return new_handle(ctx, w)
  elseif k == "const" then return w.value
  elseif k == "func" then return w.fn
  elseif k == "setting" then return ctx.settings[w.name]
  elseif k == "property" then return property_setter(ctx, w)
  elseif k == "symbol" then return Dua.symbol(w.name)
  end
end

local function open_entry(owner, name)
  local e = owner.open_cache[name]
  if not e then
    e = compile_node_spec(owner, name, owner.open_spec)
    owner.open_cache[name] = e
  end
  return e
end

local function unknown_word(ctx, L, name)
  local policy, owner = chain_get(L, "unknown_policy")
  policy = policy or "error"
  if policy == "nil" then return nil
  elseif policy == "symbol" then return Dua.symbol(name)
  elseif policy == "node" then return new_handle(ctx, open_entry(owner, name))
  elseif type(policy) == "function" then return policy(name, ctx)
  end
  local candidates = word_candidates(L)
  for k in pairs(ctx.vars) do candidates[#candidates + 1] = k end
  tsort(candidates)
  fail("unknown", "unknown word '" .. name .. "'" .. hint(name, candidates))
end

local function env_get(ctx, L, name)
  local w = lookup_word(L, name)
  if w then return eval_word(ctx, w) end
  local found, v = lookup_host(ctx, L, name)
  if found then return v end
  if ctx.extra and ctx.extra[name] ~= nil then return ctx.extra[name] end
  local var = ctx.vars[name]
  if var ~= nil then return var end
  return unknown_word(ctx, L, name)
end

local function env_set(ctx, L, name, value)
  local w = lookup_word(L, name)
  if w then
    if w.kind == "setting" or w.kind == "property" then return assign_setting(ctx, w, value) end
    fail("assign", "cannot assign to '" .. name .. "': it is a " .. w.kind .. " word")
  end
  if lookup_host(ctx, L, name) then fail("assign", "cannot assign to host global '" .. name .. "'") end
  local policy = chain_get(L, "assign_policy") or "error"
  if policy == "vars" then
    ctx.vars[name] = value
    return
  end
  local names = {}
  for k, d in pairs(collect_settings(L)) do names[#names + 1] = k end
  tsort(names)
  fail("unknown", "unknown setting '" .. name .. "'" .. hint(name, names))
end

local function make_env(ctx, L)
  local env = {}
  setmetatable(env, {
    __index = function(_, name)
      if name == "_G" then return env end
      return env_get(ctx, L, name)
    end,
    __newindex = function(_, name, value) env_set(ctx, L, name, value) end,
    __metatable = "dua-sandbox",
  })
  return env
end

function CtxMethods.make(ctx, kind, ...)
  local w = lookup_word(ctx.lang, kind)
  if not w or w.kind ~= "node" then
    fail("unknown", "ctx:make: '" .. tostring(kind) .. "' is not a node word of language '" .. ctx.lang.name .. "'")
  end
  local h = new_handle(ctx, w)
  if select("#", ...) > 0 then apply_call(h, ...) end
  return h
end

function CtxMethods.get(ctx, name) return ctx.settings[name] end

function Dua.current() return current end

local realize

local function realize_value(ctx, v, seen)
  if type(v) ~= "table" then return v end
  local st = STATES[v]
  if st then return realize(ctx, st) end
  if SYMBOL_NAME[v] or getmetatable(v) == NodeMT then return v end
  seen = seen or {}
  if seen[v] then return seen[v] end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do out[k] = realize_value(ctx, x, seen) end
  return out
end

local function bind_args(st, bad)
  local e = st.entry
  local args = {}
  if not e.args then
    for i = 1, st.nargs do args[i] = st.args[i] end
    return args
  end
  local decl = e.args
  local last = decl[#decl]
  local variadic = last and last.variadic
  local fixed = variadic and (#decl - 1) or #decl
  if st.nargs > fixed and not variadic then
    bad(sfmt("takes at most %d argument%s, got %d", fixed, fixed == 1 and "" or "s", st.nargs))
  end
  for i = 1, fixed do
    local d = decl[i]
    local v = st.args[i]
    if v == nil then
      if d.type.has_default then v = copy_value(d.type.default_value)
      elseif not d.type.optional then
        bad(sfmt("missing argument '%s' (%s)", d.name, d.type.name))
      end
    else
      local ok, r = d.type:check(v)
      if not ok then bad(sfmt("argument '%s': %s", d.name, r)) end
      v = r
    end
    args[i] = v
    args[d.name] = v
  end
  if variadic then
    local list = {}
    for i = fixed + 1, st.nargs do
      local ok, r = last.type:check(st.args[i])
      if not ok then bad(sfmt("argument '%s' #%d: %s", last.name, i - fixed, r)) end
      list[#list + 1] = r
    end
    if #list == 0 and not last.type.optional then
      bad(sfmt("missing argument '%s' (at least one %s)", last.name, last.type.name))
    end
    args[last.name] = list
    for i, v in ipairs(list) do args[fixed + i] = v end
  end
  return args
end

local function check_children(e, nodes, bad)
  local c = e.children
  if c == nil then return end
  if c.none then
    if #nodes > 0 then bad("does not accept children (got '" .. nodes[1].kind .. "')") end
    return
  end
  local counts = {}
  for _, n in ipairs(nodes) do
    local k = n.kind
    if not c.by[k] and not c.wildcard then
      local allowed = {}
      for _, r in ipairs(c.rules) do allowed[#allowed + 1] = r.kind end
      bad("does not accept child '" .. k .. "' (allowed: " .. tconcat(allowed, ", ") .. ")" .. hint(k, allowed))
    end
    counts[k] = (counts[k] or 0) + 1
  end
  for _, r in ipairs(c.rules) do
    local n = counts[r.kind] or 0
    if n < r.min then
      bad(sfmt("requires at least %d '%s' child%s, got %d", r.min, r.kind, r.min == 1 and "" or "ren", n))
    end
    if r.max and n > r.max then
      bad(sfmt("accepts at most %d '%s' child%s, got %d", r.max, r.kind, r.max == 1 and "" or "ren", n))
    end
  end
end

realize = function(ctx, st)
  if st.node then return st.node end
  if st.busy then fail("syntax", label_of(st) .. ": cyclic node reference", st.source, st.line) end
  st.busy = true
  local e = st.entry
  local label = label_of(st)

  local function bad(msg, line)
    fail("validation", label .. ": " .. msg, st.source, line or st.line)
  end

  local children = {}
  for i, ch in ipairs(st.children) do children[i] = realize(ctx, STATES[ch]) end

  local args = bind_args(st, bad)

  local raw = {}
  for k, v in pairs(st.fields) do raw[k] = realize_value(ctx, v) end
  local fields
  if e.fields then
    local ok, r = check_fields(e.fields, raw, e.open)
    if not ok then
      local fname = smatch(r, "^field '([^']+)'")
      bad(r, fname and st.field_lines[fname] or nil)
    end
    fields = r
  else
    fields = raw
  end

  local items = {}
  for i, v in ipairs(st.items) do items[i] = realize_value(ctx, v) end
  if e.items == false then
    if #items > 0 then bad("does not accept positional items") end
  elseif e.items then
    for i, v in ipairs(items) do
      local ok, r = e.items:check(v)
      if not ok then bad(sfmt("item %d: %s", i, r)) end
      items[i] = r
    end
  end

  check_children(e, children, bad)

  local node = setmetatable({
    kind = e.name, args = args, fields = fields, items = items, children = children,
    source = st.source, line = st.line, lang = ctx.lang.name,
  }, NodeMT)
  local nm = args.name
  if nm == nil and not e.args and type(args[1]) == "string" then nm = args[1] end
  if nm ~= nil then rawset(node, "name", nm) end
  for _, c in ipairs(children) do rawset(c, "parent", node) end

  if e.validate then
    local ok, a, b = pcall(e.validate, node, ctx)
    if not ok then
      if getmetatable(a) == Error then error(a, 0) end
      bad(tostring(a))
    elseif a == false then
      bad(b or "validation failed")
    end
  end
  if e.build then
    local ok, r = pcall(e.build, node, ctx)
    if not ok then
      if getmetatable(r) == Error then error(r, 0) end
      bad(tostring(r))
    end
    rawset(node, "value", r)
  end
  for _, fn in ipairs(ctx.node_hooks) do fn(node, ctx) end

  st.node = node
  st.busy = false
  return node
end

local function finalize(ctx)
  local lang = ctx.lang
  local defs = collect_settings(lang)
  local settings = {}
  for _, name in ipairs(sorted_keys(defs)) do
    local w = defs[name]
    local d = ctx.deferred[name]
    if d then
      local v = realize_value(ctx, d.value)
      local ok, r = w.type:check(v)
      if not ok then fail("validation", "setting '" .. name .. "': " .. r, d.source, d.line) end
      settings[name] = r
    elseif ctx.explicit[name] or w.type.has_default then
      settings[name] = ctx.settings[name]
    elseif not w.type.optional then
      fail("validation", "missing required setting '" .. name .. "' (" .. w.type.name .. ")", ctx.source)
    end
  end

  local roots = {}
  for _, st in ipairs(ctx.frames[1]) do
    if not st.adopted then roots[#roots + 1] = realize(ctx, st) end
  end

  local doc = setmetatable({
    roots = roots, settings = settings, vars = ctx.vars, lang = lang, source = ctx.source,
  }, DocMT)
  for _, fn in ipairs(collect_hooks(lang, "document")) do
    local r = fn(doc, ctx)
    if r ~= nil then doc = r end
  end
  return doc
end

local function display_name(chunkname)
  return (sgsub(chunkname, "^[=@]", ""))
end

local DEFAULT_LIMITS = {
  instructions = 5e7, memory = 65536, nodes = 100000, depth = 200,
  string = 1e6, pattern = 1e9, interval = 1000,
}

local function merged_limits(lang, extra)
  local out = {}
  for k, v in pairs(DEFAULT_LIMITS) do out[k] = v end
  for _, C in ipairs(chain(lang)) do
    for k, v in pairs(C.limits_cfg or {}) do out[k] = v end
  end
  for k, v in pairs(extra or {}) do out[k] = v end
  for k, v in pairs(out) do
    if v == false then out[k] = nil end
  end
  return out
end

local function new_ctx(lang, opts)
  local ctx = setmetatable({
    lang = lang, frames = { {} }, nodes = 0, depth = 0, handles = {},
    settings = {}, explicit = {}, deferred = {}, vars = {},
    extra = opts.env, source = display_name(opts.name or ("=" .. lang.name)),
    limits = merged_limits(lang, opts.limits), scope_envs = {}, libs = {},
    node_hooks = collect_hooks(lang, "node"),
  }, CtxMT)
  ctx.make_env = function(L) return make_env(ctx, L) end
  ctx.env = make_env(ctx, lang)
  for name, w in pairs(collect_settings(lang)) do
    if w.type.has_default then ctx.settings[name] = copy_value(w.type.default_value) end
  end
  return ctx
end

local function install_limits(ctx)
  local max_instr, max_mem = ctx.limits.instructions, ctx.limits.memory
  if not (max_instr or max_mem) then return nil end
  local old_hook, old_mask, old_count = debug.gethook()
  local step, used = ctx.limits.interval or 1000, 0
  local base_mem = collectgarbage("count")
  debug.sethook(function()
    if ctx.finished then return end
    used = used + step
    if max_instr and used > max_instr then
      limit_fail(ctx, "instruction limit exceeded (" .. fmt_number(max_instr) .. ")")
    end
    if max_mem and collectgarbage("count") - base_mem > max_mem then
      collectgarbage()
      if collectgarbage("count") - base_mem > max_mem then
        limit_fail(ctx, "memory limit exceeded (" .. fmt_number(max_mem) .. " KB)")
      end
    end
  end, "", step)
  return { old_hook, old_mask, old_count }
end

local function restore_limits(saved)
  if not saved then return end
  if saved[1] then debug.sethook(saved[1], saved[2], saved[3]) else debug.sethook() end
end

local string_meta = getmetatable("")

local function execute(lang, fn, opts)
  opts = opts or {}
  local ctx = new_ctx(lang, opts)
  local previous = current
  current = ctx
  local saved_index = string_meta and string_meta.__index
  if string_meta then string_meta.__index = get_lib(ctx, "string") end
  local saved = install_limits(ctx)
  local ok, res = pcall(function()
    call_in_env(fn, ctx.env)
    return finalize(ctx)
  end)
  ctx.finished = true
  restore_limits(saved)
  if string_meta then string_meta.__index = saved_index end
  current = previous
  for _, h in ipairs(ctx.handles) do STATES[h] = nil end
  if ctx.limit_error then return nil, ctx.limit_error end
  if ok then return res end
  return nil, normalize_error(res, ctx.source)
end

local ScriptMethods = {}
local ScriptMT = { __index = ScriptMethods }

function ScriptMethods.run(self, opts)
  opts = opts or {}
  if not opts.name then
    opts = setmetatable({ name = self.name }, { __index = opts })
  end
  return execute(self.lang, self.fn, opts)
end

local function chunkname_of(name, default)
  name = name or default
  local c = ssub(name, 1, 1)
  if c == "=" or c == "@" then return name end
  return "=" .. name
end

function Language:compile(src, name)
  local chunkname = chunkname_of(name, self.name)
  if type(src) == "function" then
    return setmetatable({ lang = self, fn = src, name = chunkname }, ScriptMT)
  end
  if type(src) ~= "string" then
    error("Dua: expected a source string or a function, got " .. type(src), 2)
  end
  local fn, err = load_chunk(src, chunkname)
  if not fn then
    local source, line, msg = smatch(err, "^(.-):(%d+): (.*)$")
    return nil, make_error("syntax", msg or err, source or display_name(chunkname),
                           line and tonumber(line) or nil)
  end
  return setmetatable({ lang = self, fn = fn, name = chunkname }, ScriptMT)
end

function Language:run(src, opts)
  local script, err = self:compile(src, opts and opts.name)
  if not script then return nil, err end
  return script:run(opts)
end

local function read_file(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, make_error("io", tostring(err), path) end
  local data = f:read("*a")
  f:close()
  return data
end

function Language:compile_file(path)
  local src, err = read_file(path)
  if not src then return nil, err end
  return self:compile(src, "@" .. path)
end

function Language:run_file(path, opts)
  local script, err = self:compile_file(path)
  if not script then return nil, err end
  return script:run(opts)
end

local function type_label(tp)
  local s = tp.name
  if tp.optional then s = s .. "?" end
  if tp.has_default then s = s .. " = " .. inline(tp.default_value) end
  return s
end

local function describe_word(w)
  local doc = w.doc and ("  -- " .. w.doc) or ""
  if w.kind == "node" then
    local sig = {}
    for _, d in ipairs(w.args or {}) do
      sig[#sig + 1] = d.name .. (d.variadic and "..." or "") .. ":" .. type_label(d.type)
    end
    local s = "node " .. w.name .. "(" .. tconcat(sig, ", ") .. ")"
    if w.fields then
      local f = {}
      for _, k in ipairs(w.fields.order) do f[#f + 1] = k .. ": " .. type_label(w.fields.map[k]) end
      s = s .. " fields{" .. tconcat(f, ", ") .. (w.open and ", ..." or "") .. "}"
    end
    if w.children then
      local c = {}
      if w.children.none then c[1] = "none" end
      for _, r in ipairs(w.children.rules) do
        local suffix = (r.min == 0 and r.max == 1 and "?") or (r.min == 1 and r.max == 1 and "!")
                       or (r.min >= 1 and "+") or "*"
        c[#c + 1] = r.kind .. suffix
      end
      if w.children.wildcard then c[#c + 1] = "*" end
      s = s .. " children{" .. tconcat(c, ", ") .. "}"
    end
    if w.scope_lang then s = s .. " scope[" .. tconcat(w.scope_lang.order, ", ") .. "]" end
    return s .. doc
  elseif w.kind == "setting" then
    return "setting " .. w.name .. " = <" .. type_label(w.type) .. ">" .. (w.type.doc and ("  -- " .. w.type.doc) or "")
  elseif w.kind == "property" then
    return "property " .. w.name .. "(<" .. type_label(w.type) .. ">)" .. (w.type.doc and ("  -- " .. w.type.doc) or "")
  elseif w.kind == "const" then return "const " .. w.name .. " = " .. inline(w.value)
  elseif w.kind == "func" then return "function " .. w.name .. "(...)"
  elseif w.kind == "symbol" then return "symbol " .. w.name
  elseif w.kind == "alias" then return "alias " .. w.name .. " -> " .. w.target
  end
  return w.kind .. " " .. tostring(w.name)
end

function Language:describe()
  local out = { sfmt("Language '%s' (%s)", self.name, Dua._VERSION) }
  for _, C in ipairs(chain(self)) do
    for _, name in ipairs(C.order) do
      local w = C.words[name]
      if w.kind == "alias" then
        out[#out + 1] = "  alias " .. name .. " -> " .. w.target
      else
        out[#out + 1] = "  " .. describe_word(w)
      end
    end
  end
  return tconcat(out, "\n")
end

Dua.Language = Language
Dua.new = new_language

function Dua.define(def)
  if type(def) == "string" then return new_language(def) end
  if type(def) ~= "table" then error("Dua.define: expected a name or a table", 2) end
  local L = new_language(def.name or "dsl", def.extends)
  if def.allow then L:allow(unpack(def.allow)) end
  if def.allow_all then L:allow_all() end
  if def.deny then L:deny(unpack(def.deny)) end
  if def.consts then L:consts(def.consts) end
  if def.symbols then L:symbols(def.symbols) end
  if def.funcs then L:funcs(def.funcs) end
  if def.settings then L:settings(def.settings) end
  if def.properties then L:properties(def.properties) end
  if def.tags then L:tags(def.tags) end
  if def.nodes then L:nodes(def.nodes) end
  for _, a in ipairs(def.aliases or {}) do L:alias(a[1], a[2]) end
  for op, fn in pairs(def.operators or {}) do L:operator(op, fn) end
  for ev, fn in pairs(def.hooks or {}) do L:hook(ev, fn) end
  if def.unknown ~= nil then L:unknown(def.unknown, def.unknown_spec) end
  if def.assignments then L:assignments(def.assignments) end
  if def.limits then L:limit(def.limits) end
  return L
end

return Dua
