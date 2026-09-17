-- profile-chain.lua
-- 模块化 Profile Chain 管理器，支持 DSL + Lua 双引擎触发
--
-- 功能概览：
--   1. 链条定义（profile-chain.conf）：定义链条名、包含的 profile 和触发方式
--   2. 规则定义（[trigger] 段）：高级规则（keywords+languages+DSL）和简单规则（Lua 表达式）
--   3. 执行阶段：early（start-file 时执行）/ normal（playback-restart 时执行）
--   4. 触发方式：file / property / trigger:N / script-message 手动触发

local mp = require("mp")
local msg = require("mp.msg")

-- ======================== [Module] Utils ========================
local Utils = {}

function Utils.trim(s) return (s:match("^%s*(.-)%s*$")) end

-- 缓存每个分隔符转义后的 pattern，避免相同 sep 反复 gsub 转义
local _split_esc_cache = {}
function Utils.split(str, sep)
    local out = {}
    if not str or str == "" then return out end
    local esc_sep = _split_esc_cache[sep]
    if not esc_sep then
        esc_sep = sep:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
        _split_esc_cache[sep] = esc_sep
    end
    for m in (str .. sep):gmatch("(.-)" .. esc_sep) do
        local t = Utils.trim(m)
        if t ~= "" then out[#out + 1] = t end
    end
    return out
end

function Utils.read_file(path)
    local f, err = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- 安全获取属性，返回 mpv 原生类型（number/boolean/string）。
-- property 不存在时返回 default；未传 default 时返回 0。
function Utils.prop(key, default)
    local v = mp.get_property_native(key)
    if v == nil then
        if default == nil then return 0 end
        return default
    end
    return v
end

-- 是否存在已选中的视频轨
function Utils.has_video()
    local vid = mp.get_property("vid")
    return vid ~= nil and vid ~= "0" and vid ~= "no"
end

-- ======================== [Module] Config Parser ========================
local ConfParser = {}

function ConfParser.parse(path)
    local content = Utils.read_file(path)
    if not content then return {} end
    content = content:gsub("^\239\187\191", ""):gsub("\r\n", "\n")

    local sections = { _root = {} }
    local cur = "_root"

    for raw in content:gmatch("[^\n]+") do
        local line = Utils.trim(raw)
        if line ~= "" and not line:match("^#") then
            -- 先剥离行内注释
            local clean = Utils.trim(line:gsub("[ \t]+#.*$", ""))
            if clean ~= "" then
                local sec = clean:match("^%[(.+)%]$")
                if sec then
                    cur = Utils.trim(sec)
                    sections[cur] = sections[cur] or {}
                else
                    local k, v = clean:match("^(%S+)%s*=%s*(.-)%s*$")
                    if k and v then
                        local tbl = sections[cur]
                        if tbl[k] then
                            if type(tbl[k]) ~= "table" then tbl[k] = { tbl[k] } end
                            tbl[k][#tbl[k] + 1] = v
                        else
                            tbl[k] = v
                        end
                    end
                end
            end
        end
    end
    return sections
end

-- ======================== [Module] DSL Engine ========================
local DSL = {}

function DSL.tokenize(expr)
    local tokens = {}
    local i = 1
    while i <= #expr do
        local c = expr:sub(i, i)
        if c:match("%s") then
            i = i + 1
        elseif c == "(" or c == ")" or c == "!" then
            tokens[#tokens + 1] = c; i = i + 1
        elseif c == "&" then
            tokens[#tokens + 1] = "&"
            i = i + (expr:sub(i + 1, i + 1) == "&" and 2 or 1)
        elseif c == "|" then
            tokens[#tokens + 1] = "||"
            i = i + (expr:sub(i + 1, i + 1) == "|" and 2 or 1)
        else
            local w = expr:sub(i):match("^([%w_]+)")
            if w then
                tokens[#tokens + 1] = w; i = i + #w
            else
                msg.warn("DSL: unexpected char '" .. c .. "' at pos " .. i); i = i + 1
            end
        end
    end
    return tokens
end

function DSL.compile(expr_str)
    if not expr_str or expr_str == "" then return function() return false end end
    local ok, ast_fn = pcall(function()
        local tokens = DSL.tokenize(expr_str:lower())
        local pos = 1

        local function peek() return tokens[pos] end
        local function consume(expected)
            local t = tokens[pos]
            if expected and t ~= expected then
                error("DSL: expected '" .. expected .. "' got '" .. tostring(t) .. "'")
            end
            pos = pos + 1
            return t
        end

        local parse_or, parse_and, parse_unary, parse_atom

        parse_atom = function()
            if peek() == "(" then
                consume("(")
                local node = parse_or()
                consume(")")
                return node
            end
            local name = consume()
            if not name then return function() return false end end
            return function(ctx) return ctx[name] == true end
        end

        parse_unary = function()
            if peek() == "!" then
                consume("!")
                local child = parse_unary()
                return function(ctx) return not child(ctx) end
            end
            return parse_atom()
        end

        parse_and = function()
            local left = parse_unary()
            while peek() == "&" do
                consume("&")
                local right = parse_unary()
                local l, r = left, right
                left = function(ctx) return l(ctx) and r(ctx) end
            end
            return left
        end

        parse_or = function()
            local left = parse_and()
            while peek() == "||" do
                consume("||")
                local right = parse_and()
                local l, r = left, right
                left = function(ctx) return l(ctx) or r(ctx) end
            end
            return left
        end

        local fn = parse_or()
        if pos <= #tokens then msg.warn("DSL: trailing tokens in: " .. expr_str) end
        return fn
    end)
    if not ok then
        msg.error("DSL compile error: " .. tostring(ast_fn) .. " | expr: " .. expr_str)
        return function() return false end
    end
    return ast_fn
end

-- ======================== [Module] Keyword Matcher ========================
local Keywords = {}
local SEP_PAT = "[%._%-%[%] ]"

-- 提前拼好三种匹配 pattern，match 阶段只做 find，不再现场拼字符串
function Keywords.compile(list)
    local out = {}
    for _, kw in ipairs(list) do
        kw = kw:lower():gsub("\\", "/")
        local is_re = kw:sub(1, 3) == "re:"
        local raw = is_re and kw:sub(4) or kw
        if is_re then
            out[#out + 1] = { raw = raw, regex = true }
        else
            local esc = raw:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
            out[#out + 1] = {
                raw = raw,
                regex = false,
                esc = esc,
                pat_start = "^" .. esc .. SEP_PAT,
                pat_end = SEP_PAT .. esc .. "$",
                pat_mid = SEP_PAT .. esc .. SEP_PAT,
            }
        end
    end
    return out
end

function Keywords.match(text, compiled, depth)
    if not text or text == "" or #compiled == 0 then return false end
    local lower = text:lower():gsub("\\", "/")
    lower = lower:gsub("%?.*$", "") -- 剥离网络 URL 查询参数

    if depth and depth > 0 then
        local segments = {}
        for seg in lower:gmatch("[^/]+") do segments[#segments + 1] = seg end
        local dir_count = #segments - 1
        local start = math.max(1, dir_count - depth + 1)
        local rebuilt = {}
        for i = start, dir_count do rebuilt[#rebuilt + 1] = segments[i] end
        lower = table.concat(rebuilt, "/")
        if lower == "" then return false end
    end

    for _, kw in ipairs(compiled) do
        if kw.regex then
            if lower:find(kw.raw) then return true end
        else
            if lower == kw.raw
                or lower:find(kw.pat_start)
                or lower:find(kw.pat_end)
                or lower:find(kw.pat_mid) then
                return true
            end
        end
    end
    return false
end

-- ======================== [Module] Sandbox Env ========================
local SandboxEnv = {}

-- 包含所有已知字符串类型的属性名与别名，未就绪时默认返回 "" 而非 0
local STRING_DEFAULT_KEYS = {
    path = true,
    filename = true,
    platform = true,
    title = true,
    media_title = true,
    current_vo = true,
    primaries = true,
    gamma = true,
    vid = true,
    aid = true,
    sid = true
}

local LUA_GLOBALS = {
    math = math,
    string = string,
    table = table,
    utf8 = utf8 or nil,
    tonumber = tonumber,
    tostring = tostring,
    type = type,
    pcall = pcall,
    xpcall = xpcall,
    error = error,
    assert = assert,
    select = select,
    pairs = pairs,
    ipairs = ipairs,
    next = next,
    rawget = rawget,
    rawequal = rawequal,
    getmetatable = getmetatable,
    print = print,
    _VERSION = _VERSION,
}

function SandboxEnv.new(aliases)
    aliases = aliases or {}
    local env = {}
    local touched = {}
    local mt = {
        __index = function(tbl, k)
            if k == "get" then
                rawset(tbl, k, Utils.prop)
                touched[#touched + 1] = k
                return Utils.prop
            end
            if k == "p" then
                local pt = setmetatable({}, { __index = function(_, kk) return Utils.prop(kk) end })
                rawset(tbl, k, pt)
                touched[#touched + 1] = k
                return pt
            end
            local g = LUA_GLOBALS[k]
            if g ~= nil then return g end
            local prop_key = aliases[k] or k
            local default = STRING_DEFAULT_KEYS[k] and "" or nil
            local v = Utils.prop(prop_key, default)
            rawset(tbl, k, v)
            touched[#touched + 1] = k
            return v
        end
    }
    env._touched = touched
    return setmetatable(env, mt)
end

function SandboxEnv.reset(env)
    local touched = env._touched
    if touched then
        for i = #touched, 1, -1 do
            rawset(env, touched[i], nil)
            touched[i] = nil
        end
    end
end

-- ======================== [Module] Cond Evaluator ========================
-- Security boundary: CondEval.eval and TriggerEngine use load("return "..expr)
-- to execute user-defined Lua expressions from profiles.conf / profile-chain.conf.
-- The SandboxEnv restricts the execution environment to safe standard library
-- functions (math, string, table, pcall, etc.) and mpv property access only.
-- Dangerous globals (os, io, loadstring, require, dofile, etc.) are NOT available.
-- This is safe for local personal config files; do not use with untrusted input.
local CondEval = {}
local cond_cache = {}

-- 缓存命中逻辑合并为一次分支判断（nil = 未缓存，false = 缓存的编译失败，
-- table = 缓存的可执行条目），语义与之前完全一致
function CondEval.eval(cond_str)
    if not cond_str or cond_str == "" then return true end

    local entry = cond_cache[cond_str]
    if entry == nil then
        local env = SandboxEnv.new()
        local fn, err = load("return " .. cond_str, "profile-cond", "t", env)
        if not fn then
            msg.error("profile-cond compile error: " .. tostring(err) .. " | expr: " .. cond_str)
            cond_cache[cond_str] = false
            return false
        end
        entry = { fn = fn, env = env }
        cond_cache[cond_str] = entry
    elseif entry == false then
        return false
    end

    SandboxEnv.reset(entry.env)
    local ok, result = pcall(entry.fn)
    if not ok then
        msg.error("profile-cond runtime error: " .. tostring(result) .. " | expr: " .. cond_str)
        return false
    end

    return result == true
end

-- ======================== [Module] Profile Cond Loader ========================
local CondLoader = {}

function CondLoader.load()
    local path = mp.command_native({ "expand-path", "~~/profiles.conf" })
    local sections = ConfParser.parse(path)
    local conds = {}
    for name, data in pairs(sections) do
        if name ~= "_root" and data["profile-cond"] then
            conds[name] = data["profile-cond"]
        end
    end
    local count = 0
    for _ in pairs(conds) do count = count + 1 end
    msg.info("Loaded " .. count .. " profile-cond(s) from " .. path)
    return conds
end

-- ======================== [Module] Chain Executor ========================
local Chain = {}

function Chain.parse_profiles(raw)
    local profiles = {}
    for p in (raw or ""):gmatch("[^,]+") do
        p = Utils.trim(p)
        if p ~= "" then
            local forced = false
            if p:sub(1, 1) == "*" then
                forced = true
                p = Utils.trim(p:sub(2))
            end
            if p ~= "" then
                profiles[#profiles + 1] = { name = p, forced = forced }
            end
        end
    end
    return profiles
end

function Chain.apply(profile_entries, conds)
    for _, entry in ipairs(profile_entries) do
        local name, forced = entry.name, entry.forced
        local cond = conds[name]

        local should_apply, reason
        if forced then
            should_apply, reason = true, "forced"
        elseif cond then
            if CondEval.eval(cond) then
                should_apply, reason = true, "cond=true"
            else
                msg.info("  ✗ " .. name .. " (cond=false, chain broken here)")
                break
            end
        else
            should_apply, reason = true, "unconditional"
        end

        if should_apply then
            local ok, err = pcall(mp.commandv, "apply-profile", name)
            if ok then
                msg.info("  ✓ " .. name .. " (" .. reason .. ")")
            else
                msg.error("  apply-profile '" .. name .. "' failed: " .. tostring(err))
            end
        end
    end
end

-- ======================== [Module] Trigger Rule Engine ========================
local TriggerEngine = {}

local LUA_RULE_ALIASES = {
    video_width = "video-params/w",
    video_height = "video-params/h",
    max_luma = "video-params/max-luma",
    average_bpp = "video-params/average-bpp",
    video_aspect = "video-aspect",
    video_par = "video-params/par",
    display_fps = "display-fps",
    container_fps = "container-fps",
    estimated_vf_fps = "estimated-vf-fps",
    current_vo = "current-vo",
    primaries = "video-params/primaries",
    gamma = "video-params/gamma",
    vid = "vid",
    aid = "aid",
    sid = "sid",
}

function TriggerEngine.load_rules(trigger_sec)
    local rules = { by_idx = {} }
    local max = tonumber(trigger_sec.max_rules) or 10
    local path_depth = tonumber(trigger_sec.path_depth) or 0

    for i = 1, max do
        local pfx = "rule" .. i .. "_"
        local name = trigger_sec[pfx .. "name"]
        if name and name ~= "" then
            local rule_type = trigger_sec[pfx .. "type"] or "dsl"
            local match_str = trigger_sec[pfx .. "match"] or ""
            local profile = trigger_sec[pfx .. "profile"]

            if not profile or profile == "" then
                msg.warn("Rule '" .. name .. "': missing profile, skipped")
            else
                local evaluator

                if rule_type == "lua" then
                    local env = SandboxEnv.new(LUA_RULE_ALIASES)
                    local fn, err = load("return " .. match_str, "trigger-rule-" .. name, "t", env)

                    if not fn then
                        msg.error("Lua rule '" .. name .. "' compile error: " .. tostring(err))
                    else
                        evaluator = function()
                            SandboxEnv.reset(env)
                            local ok, res = pcall(fn)
                            if not ok then
                                msg.error("Lua rule '" .. name .. "' runtime error: " .. tostring(res))
                                return false
                            end
                            return res == true
                        end
                    end
                else
                    local keywords = Keywords.compile(Utils.split(trigger_sec[pfx .. "keywords"], ","))
                    local languages_lower = {}
                    for _, l in ipairs(Utils.split(trigger_sec[pfx .. "languages"], ",")) do
                        languages_lower[#languages_lower + 1] = l:lower()
                    end
                    local dsl_fn     = DSL.compile(match_str)

                    local uses_path  = match_str:find("path") ~= nil
                    local uses_name  = match_str:find("name") ~= nil
                    local uses_title = match_str:find("title") ~= nil
                    local uses_audio = match_str:find("audio") ~= nil

                    -- 复用同一张 ctx 表，避免每次求值都新建/丢弃一张表；
                    -- 每次求值前只清空本规则实际会用到的字段，语义与"每次新建空表"完全一致
                    local ctx        = {}

                    evaluator        = function()
                        if uses_path then
                            ctx.path = Keywords.match(mp.get_property("path") or "", keywords, path_depth)
                        end
                        if uses_name then
                            ctx.name = Keywords.match(mp.get_property("filename") or "", keywords, nil)
                        end
                        if uses_title then
                            ctx.title = Keywords.match(mp.get_property("metadata/title") or "", keywords, nil)
                        end
                        if uses_audio then
                            local lang = (mp.get_property("current-tracks/audio/lang") or ""):lower()
                            local matched_audio = false
                            for _, l in ipairs(languages_lower) do
                                if lang == l then
                                    matched_audio = true
                                    break
                                end
                            end
                            ctx.audio = matched_audio
                        end
                        return dsl_fn(ctx)
                    end
                end

                if evaluator then
                    local item = { name = name, profile = profile, eval = evaluator, idx = i }
                    rules[#rules + 1] = item
                    rules.by_idx[i] = item
                    msg.debug("Loaded rule: " .. name .. " (" .. rule_type .. ") -> " .. profile)
                end
            end
        end
    end
    return rules
end

function TriggerEngine.run(rules, indices)
    if indices then
        for _, idx in ipairs(indices) do
            local rule = rules.by_idx[idx]
            if rule then
                local ok, matched = pcall(rule.eval)
                if ok and matched then
                    return rule
                end
            end
        end
        return nil
    end
    for _, rule in ipairs(rules) do
        local ok, matched = pcall(rule.eval)
        if ok and matched then
            return rule
        end
    end
    return nil
end

-- ======================== [Module] Trigger Config Parser ========================
local TriggerConfig = {}

local TRIGGER_TYPE_PATTERN = {
    { pat = "^file$",    parse = function() return { type = "file" } end },
    { pat = "^trigger$", parse = function() return { type = "trigger" } end },
    {
        pat = "^trigger:(.+)$",
        parse = function(t)
            local indices = {}
            for idx in t:match("^trigger:(.+)$"):gmatch("[^,]+") do
                idx = tonumber(Utils.trim(idx))
                if idx then indices[#indices + 1] = idx end
            end
            return { type = "trigger", rules = indices }
        end
    },
    {
        pat = "^property:(.+)$",
        parse = function(t)
            local props = {}
            for p in t:match("^property:(.+)$"):gmatch("[^,]+") do
                p = Utils.trim(p)
                if p ~= "" then props[#props + 1] = p end
            end
            return { type = "property", props = props }
        end
    },
}

function TriggerConfig.parse_on_value(raw_val)
    local raw_list = type(raw_val) == "table" and raw_val or { raw_val }
    local parsed = {}
    for _, entry in ipairs(raw_list) do
        for t in entry:gmatch("[^;]+") do
            t = Utils.trim(t)
            local matched = false
            for _, rule in ipairs(TRIGGER_TYPE_PATTERN) do
                if t:match(rule.pat) then
                    parsed[#parsed + 1] = rule.parse(t)
                    matched = true
                    break
                end
            end
            if not matched then
                msg.warn("Unknown trigger type: " .. t)
            end
        end
    end
    return parsed
end

function TriggerConfig.build_map(root, chain_map)
    local triggers_map = {}
    for k, v in pairs(root) do
        local head = k:match("^(.+)%.on$")
        if head and chain_map[head] then
            triggers_map[head] = TriggerConfig.parse_on_value(v)
        end
    end
    return triggers_map
end

-- ======================== [Main] Setup ========================
-- 链条名判断：不含 .、不在排除表、不匹配 rule\d+_ 前缀
-- 支持无 .on 的纯 script-message 手动触发链条
local EXCLUDE_SET = {
    -- 全局配置项
    require_video = true,
    chain_reapply_cooldown = true,
    show_osd = true,
    osd_duration = true,
    show_no_match = true,
    max_rules = true,
    path_depth = true,
    snapshot_enabled = true,
    snapshot_exclude = true,
    snapshot_exclude_props = true,
    snapshot_include_props = true,
}

local function is_chain_name(k)
    if k:find("%.") then return false end
    if EXCLUDE_SET[k] then return false end
    if k:match("^rule%d+_") then return false end
    return true
end

local function chain_sort_cmp(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.seq < b.seq
end

local function mark_applied(name, applied, seen)
    if not seen[name] then
        applied[#applied + 1] = name
        seen[name] = true
        return true
    end
    return false
end

local function evaluate_chains(normal_chains, triggers_map, trigger_rules)
    local applied = {}
    local seen = {}
    local evaluated_indices = {}
    local normal_set = {}
    for _, c in ipairs(normal_chains) do normal_set[c.name] = true end

    for _, chain_def in ipairs(normal_chains) do
        local trig_list = triggers_map[chain_def.name]
        if not trig_list then
            mark_applied(chain_def.name, applied, seen)
        else
            for _, t in ipairs(trig_list) do
                if seen[chain_def.name] then
                    break
                elseif t.type == "file" or t.type == "property" then
                    mark_applied(chain_def.name, applied, seen)
                elseif t.type == "trigger" and t.rules then
                    for _, idx in ipairs(t.rules) do evaluated_indices[idx] = true end
                    local matched = TriggerEngine.run(trigger_rules, t.rules)
                    if matched then
                        mark_applied(chain_def.name, applied, seen)
                        msg.info("Trigger matched: " .. matched.name .. " -> " .. chain_def.name)
                    end
                end
            end
        end
    end

    for _, rule in ipairs(trigger_rules) do
        if not evaluated_indices[rule.idx] and normal_set[rule.profile] then
            local ok, matched = pcall(rule.eval)
            if ok and matched then
                mark_applied(rule.profile, applied, seen)
                msg.info("Trigger matched: " .. rule.name .. " -> " .. rule.profile)
                break
            end
        end
    end

    return applied, #applied == 0
end

local function build_chain_lists(root)
    local chain_map = {}
    local chain_orders = {}
    local chain_seq = {}
    local seq_counter = 0

    for k, _ in pairs(root) do
        if is_chain_name(k) then
            chain_orders[k] = tonumber(root[k .. ".order"]) or 100
            seq_counter = seq_counter + 1
            chain_seq[k] = seq_counter
        end
    end

    local early_chains = {}
    local normal_chains = {}

    for name, order in pairs(chain_orders) do
        local v = root[name]
        local raw = type(v) == "table" and v[1] or v
        local profiles = Chain.parse_profiles(raw)
        local phase = root[name .. ".phase"] or "normal"
        local entry = { name = name, profiles = profiles, order = order, phase = phase, seq = chain_seq[name] }
        chain_map[name] = profiles

        local on_val = root[name .. ".on"]
        if on_val and on_val ~= "" then
            if phase == "early" then
                early_chains[#early_chains + 1] = entry
            else
                normal_chains[#normal_chains + 1] = entry
            end
        end
    end

    table.sort(early_chains, chain_sort_cmp)
    table.sort(normal_chains, chain_sort_cmp)

    return chain_map, early_chains, normal_chains
end

-- ======================== [Module] Snapshot ========================
local PROFILE_META_PROPS = {
    ["profile"] = true,
    ["profile-desc"] = true,
    ["profile-cond"] = true,
    ["profile-restore"] = true,
}

local function collect_snapshot_keys(profiles_path, exclude_list, exclude_props, include_props)
    local sections = ConfParser.parse(profiles_path)

    local exclude_set = {}
    for _, name in ipairs(exclude_list) do exclude_set[name] = true end

    local exclude_prop_set = {}
    for _, prop in ipairs(exclude_props) do exclude_prop_set[prop] = true end

    local keys = {}
    local seen = {}
    for name, data in pairs(sections) do
        if name ~= "_root" and not exclude_set[name] then
            for prop, _ in pairs(data) do
                if not PROFILE_META_PROPS[prop] and not exclude_prop_set[prop] and not seen[prop] then
                    seen[prop] = true
                    keys[#keys + 1] = prop
                end
            end
        end
    end

    for _, prop in ipairs(include_props) do
        if not seen[prop] then
            seen[prop] = true
            keys[#keys + 1] = prop
        end
    end

    return keys
end

local Snapshot = {
    data = nil,
    ready = false,
    first_loaded = false,
}

function Snapshot.capture(keys)
    local snap = {}
    for _, prop in ipairs(keys) do
        local v = mp.get_property_native(prop)
        if v ~= nil then snap[prop] = v end
    end
    Snapshot.data = snap
    Snapshot.ready = true
end

function Snapshot.restore()
    if not Snapshot.data or not Snapshot.ready then return end
    if not Snapshot.first_loaded then
        Snapshot.first_loaded = true
        return
    end
    local count = 0
    for prop, value in pairs(Snapshot.data) do
        local current = mp.get_property_native(prop)
        if current ~= value then
            mp.set_property_native(prop, value)
            count = count + 1
        end
    end
    if count > 0 then
        msg.info("Property snapshot restored: " .. count .. " properties")
    end
end

local function setup()
    local conf_path = mp.command_native({ "expand-path", "~~/script-opts/profile-chain.conf" })
    local sections = ConfParser.parse(conf_path)
    local root = sections._root or {}
    local trigger_sec = root

    local require_video = root.require_video ~= "no"

    local chain_map, early_chains, normal_chains = build_chain_lists(root)
    local triggers_map = TriggerConfig.build_map(root, chain_map)

    local conds = CondLoader.load()
    local trigger_rules = TriggerEngine.load_rules(trigger_sec)

    local show_osd = trigger_sec.show_osd == "yes"
    local osd_dur = (tonumber(trigger_sec.osd_duration) or 1500) / 1000
    local show_nomatch = trigger_sec.show_no_match == "yes"
    local chain_cooldown = tonumber(root.chain_reapply_cooldown) or 0.3

    local rule_evaluated = false
    local debounce_timers = {}
    local last_apply_time = {}
    local osd_pending = {}
    local osd_timer = nil

    -- 每条链条的"正在应用中"标记，以及应用期间被推迟的那次触发的 opts
    local chain_busy = {}
    local chain_pending = {}
    local early_applied = {}
    local early_set = {}
    for _, c in ipairs(early_chains) do early_set[c.name] = true end

    local function debounced(key, fn, delay)
        if debounce_timers[key] then debounce_timers[key]:kill() end
        debounce_timers[key] = mp.add_timeout(delay or 0.1, function()
            debounce_timers[key] = nil
            local ok, err = pcall(fn)
            if not ok then
                msg.error("debounced callback error: " .. tostring(err))
            end
        end)
    end

    local function apply_chain(name, opts)
        opts = opts or {}

        -- 该链条正在应用中（Chain.apply 还没返回）——不允许重入，
        -- 记下这次触发的 opts，等当前这次应用结束后立即补跑一次，
        -- 而不是直接丢弃，也不是并发/嵌套执行。
        if chain_busy[name] then
            chain_pending[name] = opts
            msg.debug("apply_chain('" .. name .. "') deferred: chain is still applying, will retry once it finishes")
            return
        end

        if require_video and not opts.skip_video_check and not Utils.has_video() then
            msg.debug("apply_chain('" .. name .. "') skipped: no video track")
            return
        end

        if not opts.skip_cooldown and chain_cooldown > 0 then
            local now = mp.get_time()
            local last = last_apply_time[name]
            if last and (now - last) < chain_cooldown then
                msg.debug(string.format(
                    "apply_chain('%s') skipped: within reapply cooldown (%.2fs < %.2fs)",
                    name, now - last, chain_cooldown))
                return
            end
        end

        local profiles = chain_map[name]
        if profiles then
            chain_busy[name] = true
            local phase_tag = early_set[name] and " (early)" or ""
            msg.info("Applying chain: " .. name .. phase_tag)
            local ok, err = pcall(Chain.apply, profiles, conds)
            chain_busy[name] = false
            if not ok then
                msg.error("Chain.apply('" .. name .. "') error: " .. tostring(err))
            end
            last_apply_time[name] = mp.get_time()
            if show_osd then
                osd_pending[#osd_pending + 1] = name
                if not osd_timer then
                    osd_timer = mp.add_timeout(0.15, function()
                        local ok, err = pcall(function()
                            local max_display = 4
                            local items = osd_pending
                            local start = math.max(1, #items - max_display + 1)
                            local txt = "chain: " .. table.concat(items, " → ", start)
                            osd_pending = {}
                            osd_timer = nil
                            mp.osd_message(txt, osd_dur)
                        end)
                        if not ok then
                            msg.error("OSD timer error: " .. tostring(err))
                            osd_pending = {}
                            osd_timer = nil
                        end
                    end)
                end
            end

            -- 应用期间如果被推迟过一次触发，现在补跑；用 add_timeout(0) 放到
            -- 下一个 tick 执行，避免在当前调用栈里直接递归。
            local pending_opts = chain_pending[name]
            if pending_opts then
                chain_pending[name] = nil
                mp.add_timeout(0, function()
                    local ok, err = pcall(apply_chain, name, pending_opts)
                    if not ok then
                        msg.error("pending retry error: " .. tostring(err))
                    end
                end)
            end
        else
            msg.warn("Chain not found: " .. name)
        end
    end

    local pending_initial_restart = false
    local video_reconfigured = false
    local file_loaded = false

    local function run_initial_chain_logic()
        if not file_loaded then
            msg.debug("run_initial_chain_logic: no file loaded yet, deferring")
            pending_initial_restart = true
            return
        end

        if require_video and not Utils.has_video() then
            msg.debug("run_initial_chain_logic: no video track, all chain triggers skipped")
            rule_evaluated = true
            return
        end

        if require_video and Utils.has_video() and not video_reconfigured then
            msg.debug("run_initial_chain_logic: video track exists but video-reconfig not yet fired, deferring")
            pending_initial_restart = true
            return
        end

        rule_evaluated = true

        local applied, no_match = evaluate_chains(normal_chains, triggers_map, trigger_rules)

        for _, name in ipairs(applied) do
            apply_chain(name)
        end

        if show_nomatch and no_match then
            mp.osd_message("no match", osd_dur)
        end
    end

    -- prop_chains 现在同时收纳 normal_chains 和 early_chains 里
    -- .on=property:xxx 的链条，每条记录带 early 标记，交给下面同一个
    -- observe_property 回调按各自规则处理（early 的不再被无条件跳过）。
    local prop_chains = {}
    local function register_prop_chain(prop, name, early)
        if not prop_chains[prop] then prop_chains[prop] = {} end
        prop_chains[prop][#prop_chains[prop] + 1] = { name = name, early = early }
    end

    local function register_chains_prop_triggers(chains, early)
        for _, chain_def in ipairs(chains) do
            local trig_list = triggers_map[chain_def.name]
            if trig_list then
                for _, t in ipairs(trig_list) do
                    if t.type == "property" then
                        for _, prop in ipairs(t.props) do
                            register_prop_chain(prop, chain_def.name, early)
                        end
                    end
                end
            end
        end
    end

    register_chains_prop_triggers(normal_chains, false)
    register_chains_prop_triggers(early_chains, true)

    for prop, entries in pairs(prop_chains) do
        mp.observe_property(prop, "native", function()
            for _, entry in ipairs(entries) do
                if entry.early then
                    if file_loaded and not pending_initial_restart and not early_applied[entry.name] then
                        early_applied[entry.name] = true
                        apply_chain(entry.name, { skip_video_check = true })
                    end
                else
                    local ready = (not require_video) or (Utils.has_video() and video_reconfigured)
                    if ready then
                        debounced("prop_" .. entry.name, function()
                            apply_chain(entry.name)
                        end, 0.15)
                    end
                end
            end
        end)
    end

    -- early 链条的触发时机：
    --   .on=property:xxx → start-file 时由 apply_early_chain_on_start 统一 apply，
    --                     之后由 observer 处理（pending_initial_restart 期间已跳过）；
    --   .on=file / .on=trigger:N → start-file 时求值一次；
    --   无 .on 类型 → 无条件 apply 一次（兜底）。
    local function apply_early_chain_on_start(chain_def)
        local trig_list = triggers_map[chain_def.name]
        if not trig_list then
            apply_chain(chain_def.name, { skip_video_check = true })
            return
        end

        for _, t in ipairs(trig_list) do
            local should_apply = false
            if t.type == "file" or t.type == "property" then
                should_apply = true
            elseif t.type == "trigger" then
                local matched = TriggerEngine.run(trigger_rules, t.rules)
                if matched then
                    msg.info("Trigger matched: " .. matched.name .. " -> " .. chain_def.name .. " (early)")
                    should_apply = true
                end
            end
            if should_apply then
                apply_chain(chain_def.name, { skip_video_check = true })
            end
        end
    end

    mp.register_event("start-file", function()
        rule_evaluated = false
        pending_initial_restart = true
        video_reconfigured = false
        file_loaded = false
        early_applied = {}

        for _, chain_def in ipairs(early_chains) do
            apply_early_chain_on_start(chain_def)
        end

        for k, timer in pairs(debounce_timers) do
            if k:match("^prop_") then
                timer:kill(); debounce_timers[k] = nil
            end
        end

        if osd_timer then
            osd_timer:kill(); osd_timer = nil
        end
        osd_pending = {}
    end)

    mp.register_event("file-loaded", function()
        file_loaded = true
        if pending_initial_restart then
            pending_initial_restart = false
            run_initial_chain_logic()
        end
        Snapshot.restore()
    end)

    mp.register_event("video-reconfig", function()
        if Utils.has_video() then
            video_reconfigured = true
            if pending_initial_restart and file_loaded then
                pending_initial_restart = false
                run_initial_chain_logic()
            end
        end
    end)

    mp.register_event("playback-restart", function()
        if pending_initial_restart then
            pending_initial_restart = false
            run_initial_chain_logic()
        end
    end)

    mp.register_script_message("profile-chain", function(name)
        if name == "restore" then
            Snapshot.restore()
        else
            apply_chain(name, { skip_video_check = true, skip_cooldown = true })
        end
    end)

    msg.info("profile-chain loaded: " ..
        #early_chains ..
        " early + " .. #normal_chains .. " normal chain(s), " .. #trigger_rules .. " rule(s), require_video="
        .. tostring(require_video))

    -- 启动时校验：链引用的 profile 是否在 profiles.conf 中存在
    local profiles_path = mp.command_native({ "expand-path", "~~/profiles.conf" })
    local known_sections = ConfParser.parse(profiles_path)
    for name, profiles in pairs(chain_map) do
        for _, entry in ipairs(profiles) do
            if not known_sections[entry.name] then
                msg.warn("Chain '" .. name .. "' references unknown profile: " .. entry.name)
            end
        end
    end

    for _, rule in ipairs(trigger_rules) do
        if not known_sections[rule.profile] then
            msg.warn("Rule '" .. rule.name .. "' references unknown profile: " .. rule.profile)
        end
    end

    local snapshot_enabled = root.snapshot_enabled
    if snapshot_enabled == "yes" then
        local exclude_raw = root.snapshot_exclude or ""
        local exclude_list = Utils.split(exclude_raw, ",")
        local exclude_props_raw = root.snapshot_exclude_props or ""
        local exclude_props = Utils.split(exclude_props_raw, ",")
        local include_props_raw = root.snapshot_include_props or ""
        local include_props = Utils.split(include_props_raw, ",")
        local keys = collect_snapshot_keys(profiles_path, exclude_list, exclude_props, include_props)
        Snapshot.capture(keys)
        msg.info("Property snapshot captured: " .. #keys .. " properties")
    end
end

setup()
