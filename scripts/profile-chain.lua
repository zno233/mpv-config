-- profile-chain.lua
-- 模块化、健壮、支持 DSL + Lua 双引擎的 Profile Chain 管理器
--
-- ============================================================
-- 变更记录 (Changelog)
-- ============================================================
-- #1  profile-cond 不缓存结果：每次应用都重新求值属性，确保属性变化后行为正确
--     （但编译结果会缓存，见 #13，二者不冲突：缓存"编译后的函数"是安全的，
--       缓存"求值结果"才是不安全的）
-- #2  trigger 段支持真正的 lua 类型规则（rule{N}_type=lua）
-- #3  DSL 规则支持 path/name/title/audio 布尔变量 + !/&/||/() 逻辑表达式
-- #4  未匹配任何 trigger 规则时，可显示 OSD 提示
-- #5  keywords 支持 depth 参数，仅匹配路径末尾若干级目录
-- #6  file-loaded 时重置 rule_evaluated 状态，避免跨文件误判为"已评估"
-- #7  profile-cond 求值环境按属性懒加载，避免不必要的属性读取
-- #8  keywords 支持 "re:" 前缀启用 Lua pattern 匹配
-- #9  property 触发器带防抖（debounce），避免属性抖动导致重复应用
-- #10 无视频轨（audio-only 等）时，默认不触发任何链（可用 require_video=no 关闭），
--     手动 script-message 触发不受此限制
-- #11 profile-cond 保护机制：链中某 profile 的 profile-cond 为 false 时，
--     视为后续 profile 与当前内容不兼容，链执行到此中断。
--     可在 profile 名前加 "*" 强制执行并无视该保护（例如 Base=*SD,Deband,HDR）
-- #12 修复 lua 类型 trigger 规则的属性"冻结"问题：原实现只在脚本启动时编译一次
--     环境，path/filename 及懒加载属性此后永不刷新，导致切换文件后规则失效。
--     现在改为共享的 SandboxEnv，每次求值前重置，编译结果仍只做一次。
-- #13 profile-cond 表达式编译结果缓存（按表达式字符串），避免每次求值都重新
--     load()，同时通过重置环境表保证属性值依旧是实时读取的
-- #14 修复 file-loaded 时机过早导致的误判：file-loaded 触发时 vid/video-params
--     等属性可能仍是上一个文件的残留值（尚未针对新文件完成轨道选择/属性刷新），
--     导致 profile-cond 用旧值算出错误结果（例如新文件明明不该匹配 SD 却先
--     被误判为 true，随后才被 property 触发器纠正）。现在 file 类型链的应用与
--     trigger 规则求值统一推迟到该文件加载后的第一次 playback-restart 事件
--     （mpv 保证此时 vid/current-tracks/video-params 等均已就绪），同时移除了
--     原先"等待音频轨最多 2 秒"的 observe+timeout 兜底逻辑（不再需要）。
-- #15 同一条 chain 若同时挂了多种触发方式（如 file + property），文件加载过程中
--     属性从旧文件的值变为新文件的值这件事本身就会让 property 触发器再独立触发
--     一次，导致短时间内重复应用同一条链。现在在 apply_chain 里加入一个可配置的
--     冷却时间（chain_reapply_cooldown，默认 0.3s），把这种"同一事件、不同触发源"
--     的重复调用合并为一次；script-message 手动触发不受此限制。
-- #16 修复 video-reconfig 先于 playback-restart 触发导致的误判：
--     video-reconfig 可能在 playback-restart 之前触发，此时直接调用
--     run_initial_chain_logic() 会导致链在视频参数就绪前就被应用。
--     现在 video-reconfig 仅设置标志，由 playback-restart 统一消费。
-- #17 trigger 触发方式支持指定规则编号：on=trigger:N 或 on=trigger:N,M,...
--     仅匹配指定的 ruleN，而非所有规则。未指定编号时保持原有行为（匹配所有规则）。
-- #18 支持 phase 属性：ChainName.phase=early 让链在 file-loaded 时立即执行（在 mpv
--     auto_profiles 之前），默认 phase=normal 在 playback-restart 时执行。
--     early 和 normal 阶段各自有独立的 .order 排序。
-- #19 .on= 留空表示链仅手动触发（script-message），不进入自动执行队列。
-- ============================================================

local mp = require("mp")
local msg = require("mp.msg")
local utils = require("mp.utils")

-- ======================== [Module] Utils ========================
local Utils = {}

function Utils.trim(s) return (s:match("^%s*(.-)%s*$")) end

function Utils.split(str, sep)
    local out = {}
    if not str or str == "" then return out end
    for m in (str .. sep):gmatch("(.-)" .. sep) do
        local t = Utils.trim(m)
        if t ~= "" then out[#out + 1] = t end
    end
    return out
end

function Utils.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

-- 安全获取属性，数值型返回 number，布尔型返回 boolean，其余返回 string
-- default 显式传入时（包括 false/""）总是被尊重，不会被强制转换成 0
function Utils.prop(key, default)
    local v = mp.get_property(key)
    if v == nil then
        if default == nil then return 0 end
        return default
    end
    local n = tonumber(v)
    if n then return n end
    if v == "yes" then return true end
    if v == "no" then return false end
    return v
end

-- 是否存在已选中的视频轨。mpv 中未选中视频轨时 "vid" 属性通常为 "no"，
-- 但也兼容历史实现里出现过的 "0"。
function Utils.has_video()
    local vid = mp.get_property("vid")
    return vid ~= nil and vid ~= "0" and vid ~= "no"
end

-- ======================== [Module] Config Parser ========================
local ConfParser = {}

-- 解析 INI 风格配置，支持多值 key（自动转为 table）
function ConfParser.parse(path)
    local content = Utils.read_file(path)
    if not content then return {} end

    local sections = { _root = {} }
    local cur = "_root"

    for raw in content:gmatch("[^\n]+") do
        local line = Utils.trim(raw)
        if line ~= "" and not line:match("^#") then
            local sec = line:match("^%[(.+)%]$")
            if sec then
                cur = sec
                sections[cur] = sections[cur] or {}
            else
                local k, v = line:match("^(%S+)%s*=%s*(.-)%s*$")
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
    return sections
end

-- ======================== [Module] DSL Engine ========================
-- 轻量级表达式解析器: path, name, title, audio + ! & || ()
local DSL = {}

local function dsl_tokenize(expr)
    local tokens = {}
    local i = 1
    while i <= #expr do
        local c = expr:sub(i, i)
        if c == " " then
            i = i + 1
        elseif c == "(" or c == ")" or c == "!" then
            tokens[#tokens + 1] = c; i = i + 1
        elseif c == "&" then
            tokens[#tokens + 1] = "&"; i = i + 1
        elseif c == "|" and expr:sub(i + 1, i + 1) == "|" then
            tokens[#tokens + 1] = "||"; i = i + 2
        else
            local w = expr:match("^([%w_]+)", i)
            if w then
                tokens[#tokens + 1] = w; i = i + #w
            else
                msg.warn("DSL: unexpected char '" .. c .. "' at pos " .. i); i = i + 1
            end
        end
    end
    return tokens
end

-- 递归下降解析器，返回 AST 函数
function DSL.compile(expr_str)
    if not expr_str or expr_str == "" then return function() return false end end
    local tokens = dsl_tokenize(expr_str:lower())
    local pos = 1

    local function peek() return tokens[pos] end
    local function consume(expected)
        local t = tokens[pos]
        if expected and t ~= expected then
            msg.warn("DSL: expected '" .. expected .. "' got '" .. tostring(t) .. "'")
            return nil
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
        -- 变量节点：从 context 中取值
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

    local ast_fn = parse_or()
    if pos <= #tokens then msg.warn("DSL: trailing tokens in: " .. expr_str) end
    return ast_fn
end

-- ======================== [Module] Keyword Matcher ========================
local Keywords = {}

local SEP_PAT = "[%._%-%[%] ]"

function Keywords.compile(list)
    local out = {}
    for _, kw in ipairs(list) do
        kw = kw:lower()
        local is_re = kw:sub(1, 3) == "re:"
        local raw = is_re and kw:sub(4) or kw
        out[#out + 1] = { raw = raw, regex = is_re }
    end
    return out
end

function Keywords.match(text, compiled, depth)
    if not text or text == "" or #compiled == 0 then return false end
    local lower = text:lower()

    -- depth 处理：仅匹配目录部分，排除文件名
    if depth and depth > 0 then
        local segments = {}
        for seg in lower:gmatch("[^/\\]+") do segments[#segments + 1] = seg end
        -- 最后一段是文件名，depth=1 表示只匹配当前目录(倒数第二段)
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
            -- 单词边界匹配
            local esc = kw.raw:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
            if lower == kw.raw
                or lower:find("^" .. esc .. SEP_PAT)
                or lower:find(SEP_PAT .. esc .. "$")
                or lower:find(SEP_PAT .. esc .. SEP_PAT) then
                return true
            end
        end
    end
    return false
end

-- ======================== [Module] Sandbox Env ========================
-- 供 CondEval / TriggerEngine(lua 规则) 共用的懒加载属性环境。
-- 设计要点：
--   - 变量按需懒加载并在表内缓存（rawset），避免同一次求值内重复读取同一属性
--   - 但环境表在每次"求值前"都会被 SandboxEnv.reset() 清空，
--     从而保证跨多次求值时属性值始终是最新的（不会永久冻结）
local SandboxEnv = {}

-- string_defaults: 哪些变量在属性不存在时应默认返回空字符串而不是 0
local STRING_DEFAULT_KEYS = { path = true, filename = true, platform = true }

function SandboxEnv.new(aliases)
    aliases = aliases or {}
    local env = {}
    local mt = {
        __index = function(tbl, k)
            if k == "get" then
                rawset(tbl, k, Utils.prop)
                return Utils.prop
            end
            if k == "p" then
                local pt = setmetatable({}, { __index = function(_, kk) return Utils.prop(kk) end })
                rawset(tbl, k, pt)
                return pt
            end
            local prop_key = aliases[k] or k
            local default = STRING_DEFAULT_KEYS[k] and "" or nil
            local v = Utils.prop(prop_key, default)
            rawset(tbl, k, v)
            return v
        end
    }
    return setmetatable(env, mt)
end

-- 清空已缓存的属性值，使下一次访问重新从 mpv 读取最新值
function SandboxEnv.reset(env)
    for k in pairs(env) do rawset(env, k, nil) end
end

-- ======================== [Module] Cond Evaluator ========================
-- profile-cond 表达式：编译结果按表达式字符串缓存以避免重复 load()，
-- 但属性值绝不缓存 —— 每次求值前都会重置环境，确保属性变化后行为正确。
local CondEval = {}

local cond_cache = {} -- cond_str -> { fn = <function>, env = <table> } | false(编译失败)

function CondEval.eval(cond_str)
    if not cond_str or cond_str == "" then return true end

    local entry = cond_cache[cond_str]
    if entry == false then
        return false -- 之前已编译失败过，避免重复报错刷屏
    end

    if not entry then
        local env = SandboxEnv.new()
        local fn, err = load("return " .. cond_str, "profile-cond", "t", env)
        if not fn then
            msg.error("profile-cond compile error: " .. tostring(err) .. " | expr: " .. cond_str)
            cond_cache[cond_str] = false
            return false
        end
        entry = { fn = fn, env = env }
        cond_cache[cond_str] = entry
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
    local content = Utils.read_file(path)
    if not content then
        msg.warn("Cannot read profiles.conf at: " .. path)
        return {}
    end

    local conds = {}
    local cur_name = nil
    for line in content:gmatch("[^\n]+") do
        line = Utils.trim(line)
        local name = line:match("^%[(.+)%]$")
        if name then
            cur_name = name
        elseif cur_name then
            local c = line:match("^profile%-cond%s*=%s*(.+)$")
            if c then conds[cur_name] = Utils.trim(c) end
        end
    end

    local count = 0
    for _ in pairs(conds) do count = count + 1 end
    msg.info("Loaded " .. count .. " profile-cond(s) from " .. path)
    return conds
end

-- ======================== [Module] Chain Executor ========================
local Chain = {}

-- 解析形如 "SD,Deband,HDR" 或 "*SD,Deband,HDR" 的链定义字符串。
-- 名称前的 "*" 表示强制执行：无视其 profile-cond（如果有的话），
-- 并且不会因自身条件失败而触发链中断保护机制。
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

-- 依次应用一条链上的 profile。
--   - forced（"*" 前缀）：总是应用，忽略 profile-cond，不会中断链
--   - 有 profile-cond 且求值为 false：不应用，且中断（break）本次链的后续执行 —— 这是
--     针对不兼容场景的保护机制，避免继续应用假设了该条件成立的下游 profile
--   - 有 profile-cond 且求值为 true：应用，链继续
--   - 无 profile-cond：无条件应用，链继续
function Chain.apply(profile_entries, conds)
    if not Utils.has_video() then
        msg.debug("Chain.apply skipped: no video track")
        return
    end

    for _, entry in ipairs(profile_entries) do
        local name, forced = entry.name, entry.forced
        local cond = conds[name]

        if forced then
            mp.commandv("apply-profile", name)
            msg.info("  ✓ " .. name .. " (forced)")
        elseif cond then
            if CondEval.eval(cond) then
                mp.commandv("apply-profile", name)
                msg.info("  ✓ " .. name .. " (cond=true)")
            else
                msg.info("  ✗ " .. name .. " (cond=false, chain broken here)")
                break
            end
        else
            mp.commandv("apply-profile", name)
            msg.info("  ✓ " .. name .. " (unconditional)")
        end
    end
end

-- ======================== [Module] Trigger Rule Engine ========================
local TriggerEngine = {}

-- 常用属性别名映射（供 lua 类型规则使用）
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
    local rules = {}
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
                    -- lua 类型规则：编译一次，但环境在每次求值前都会重置，
                    -- 因此 path/filename/属性值始终是当次求值时的最新值
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
                    -- DSL 规则：预先计算好会用到哪些上下文变量与小写语言表，
                    -- 避免每次求值都重新扫描 match_str / 重新 lower() 语言列表
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

                    evaluator        = function()
                        local ctx = {}
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
                            ctx.audio = false
                            for _, l in ipairs(languages_lower) do
                                if lang == l then
                                    ctx.audio = true
                                    break
                                end
                            end
                        end
                        return dsl_fn(ctx)
                    end
                end

                if evaluator then
                    rules[#rules + 1] = { name = name, profile = profile, eval = evaluator }
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
            local rule = rules[idx]
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

-- ======================== [Main] Setup ========================
local function setup()
    local conf_path = mp.command_native({ "expand-path", "~~/script-opts/profile-chain.conf" })
    local sections = ConfParser.parse(conf_path)
    local root = sections._root or {}
    local trigger_sec = root

    -- 无视频轨（音频文件等）时是否默认不触发任何链；默认 yes，可显式关闭
    local require_video = root.require_video ~= "no"

    -- 解析 Chains
    local chain_map = {}    -- name -> profile entries ({name, forced}[])
    local triggers_map = {} -- chain_name -> trigger configs

    -- 解析所有 chain 定义（按文件出现顺序）
    local chain_order = {}
    local chain_orders = {}  -- name → order number

    for k, v in pairs(root) do
        if not k:match("%.on$") and not k:match("%.order$") and not k:match("^rule%d+_")
            and not k:match("^require_video$")
            and not k:match("^chain_reapply_cooldown$")
            and not k:match("^show_osd$")
            and not k:match("^osd_duration$")
            and not k:match("^show_no_match$")
            and not k:match("^max_rules$")
            and not k:match("^path_depth$")
            and not k:match("^profile_order$")
            and not k:match("^manage_auto_profiles$")
            and not k:match("%.phase$") then
            chain_order[#chain_order + 1] = k
            chain_orders[k] = tonumber(root[k .. ".order"]) or 100
        end
    end

    local all_items = {}
    for name, order in pairs(chain_orders) do
        all_items[#all_items + 1] = { name = name, order = order }
    end

    local early_chains = {}
    local normal_chains = {}

    for _, item in ipairs(all_items) do
        local v = root[item.name]
        local raw = type(v) == "table" and v[1] or v
        local profiles = Chain.parse_profiles(raw)
        local phase = root[item.name .. ".phase"] or "normal"
        local entry = { name = item.name, profiles = profiles, order = item.order, phase = phase }
        chain_map[item.name] = profiles

        -- .on= 留空表示仅手动触发（script-message），不进入自动执行队列
        local on_val = root[item.name .. ".on"]
        if on_val ~= "" then
            if phase == "early" then
                early_chains[#early_chains + 1] = entry
            else
                normal_chains[#normal_chains + 1] = entry
            end
        end
    end

    table.sort(early_chains, function(a, b) return a.order < b.order end)
    table.sort(normal_chains, function(a, b) return a.order < b.order end)

    -- 解析 trigger 绑定
    for k, v in pairs(root) do
        local head = k:match("^(.+)%.on$")
        if head and chain_map[head] then
            local raw_list = type(v) == "table" and v or { v }
            local parsed = {}
            for _, entry in ipairs(raw_list) do
                for t in entry:gmatch("[^;]+") do
                    t = Utils.trim(t)
                    if t == "file" then
                        parsed[#parsed + 1] = { type = "file" }
                    elseif t:match("^trigger:") then
                        local indices = {}
                        for idx in t:sub(9):gmatch("[^,]+") do
                            idx = tonumber(Utils.trim(idx))
                            if idx then indices[#indices + 1] = idx end
                        end
                        parsed[#parsed + 1] = { type = "trigger", rules = indices }
                    elseif t == "trigger" then
                        parsed[#parsed + 1] = { type = "trigger" }
                    elseif t:match("^property:") then
                        local props = {}
                        for p in t:sub(10):gmatch("[^,]+") do
                            p = Utils.trim(p)
                            if p ~= "" then props[#props + 1] = p end
                        end
                        parsed[#parsed + 1] = { type = "property", props = props }
                    else
                        msg.warn("Unknown trigger type: " .. t)
                    end
                end
            end
            triggers_map[head] = parsed
        end
    end

    -- 加载 profile-cond
    local conds = CondLoader.load()

    -- 加载 trigger rules
    local trigger_rules = TriggerEngine.load_rules(trigger_sec)

    -- OSD 设置
    local show_osd = trigger_sec.show_osd == "yes"
    local osd_dur = (tonumber(trigger_sec.osd_duration) or 1500) / 1000
    local show_nomatch = trigger_sec.show_no_match == "yes"

    -- 一个 chain 可以同时挂多种触发方式（如 Base.on=file 且 Base.on=property:...）。
    -- 文件加载过程中，video-params/current-tracks 等属性本身也会从"上一个文件的值"
    -- 变为"新文件的值"，这会让 property 触发器把"同一次加载事件"当成一次独立的
    -- 属性变化再触发一遍，导致同一条链在极短时间内被重复应用。下面这个冷却时间
    -- 用于把这种"同一事件、不同触发源"的重复调用合并为一次。
    local chain_cooldown = tonumber(root.chain_reapply_cooldown) or 0.3

    -- 状态管理
    local rule_evaluated = false
    local debounce_timers = {}
    local last_apply_time = {} -- chain name -> mp.get_time() of last successful apply
    local osd_pending = {}     -- 短时间内累积的链名，合并显示
    local osd_timer = nil

    -- Debounce helper
    local function debounced(key, fn, delay)
        if debounce_timers[key] then debounce_timers[key]:kill() end
        debounce_timers[key] = mp.add_timeout(delay or 0.1, function()
            debounce_timers[key] = nil
            fn()
        end)
    end

    -- 执行指定 chain。这是所有链应用路径（file/property/trigger/default/手动）的
    -- 唯一入口，因此"无视频轨默认不触发"和"同一事件重复触发合并"的判断都统一放在这里。
    -- opts.skip_video_check: 手动 script-message 触发时传 true，无视"无视频轨不触发"限制。
    -- opts.skip_cooldown:    手动 script-message 触发时传 true，无视重复触发合并冷却。
    local function apply_chain(name, opts)
        opts = opts or {}
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
            msg.info("Applying chain: " .. name)
            Chain.apply(profiles, conds)
            last_apply_time[name] = mp.get_time()
            if show_osd then
                osd_pending[#osd_pending + 1] = name
                if not osd_timer then
                    osd_timer = mp.add_timeout(0.15, function()
                        local max_display = 4
                        local items = osd_pending
                        if #items > max_display then
                            local trimmed = {}
                            for i = #items - max_display + 1, #items do
                                trimmed[#trimmed + 1] = items[i]
                            end
                            items = trimmed
                        end
                        local txt = "chain: " .. table.concat(items, " → ")
                        osd_pending = {}
                        osd_timer = nil
                        mp.osd_message(txt, osd_dur)
                    end)
                end
            end
        else
            msg.warn("Chain not found: " .. name)
        end
    end

    -- 执行所有 trigger 规则
    local function evaluate_trigger_rules()
        if rule_evaluated or #trigger_rules == 0 then return end

        if require_video and not Utils.has_video() then
            msg.debug("evaluate_trigger_rules skipped: no video track")
            rule_evaluated = true
            return
        end

        rule_evaluated = true

        -- 优先检查指定了规则编号的链（trigger:N）
        for _, chain_def in ipairs(normal_chains) do
            local trig_list = triggers_map[chain_def.name]
            if trig_list then
                for _, t in ipairs(trig_list) do
                    if t.type == "trigger" and t.rules then
                        local matched = TriggerEngine.run(trigger_rules, t.rules)
                        if matched then
                            apply_chain(chain_def.name)
                            msg.info("Trigger matched: " .. matched.name .. " -> " .. chain_def.name)
                            return
                        end
                    end
                end
            end
        end

        -- 未匹配指定规则的链，按原有逻辑评估所有规则
        local matched = TriggerEngine.run(trigger_rules)
        if matched then
            apply_chain(matched.profile)
            msg.info("Trigger matched: " .. matched.name .. " -> " .. matched.profile)
        else
            if show_nomatch then
                mp.osd_message("no match", osd_dur)
            end
        end
    end

    -- 标记"文件刚加载、尚未跑过首次链应用逻辑"，在下一次 playback-restart 时消费。
    -- 之所以不在 file-loaded 里直接跑，是因为此时 vid / video-params /
    -- current-tracks 等属性可能仍是上一个文件的残留值，过早求值会得到错误结果
    -- （见文件头 Changelog #14）。playback-restart 是 mpv 保证这些属性对新文件
    -- 已经就绪的时机，因此把 file 类型链的应用和 trigger 规则求值都放在这里。
    -- 此外，首次 playback-restart 时 video-params/w 和 video-params/h 可能仍是旧文件
    -- 的残留值（> 0 但非当前文件的值），因此还需要等待 video-reconfig 事件确认
    -- 视频输出已针对当前文件完成配置后，才真正执行链。
    local pending_initial_restart = false
    local video_reconfigured = false
    local pending_prop_triggers = {}
    local file_loaded = false

    -- 注册 property 触发器（带防抖）
        for _, chain_def in ipairs(normal_chains) do
            local trig_list = triggers_map[chain_def.name]
        if trig_list then
            for _, t in ipairs(trig_list) do
                if t.type == "property" then
                    for _, prop in ipairs(t.props) do
                        mp.observe_property(prop, "native", function()
                            if require_video and not Utils.has_video() then
                                return
                            end
                            if require_video and not video_reconfigured then
                                pending_prop_triggers[chain_def.name] = true
                                return
                            end
                            debounced("prop_" .. chain_def.name, function()
                                apply_chain(chain_def.name)
                            end, 0.15)
                        end)
                    end
                end
            end
        end
    end

    -- 是否存在挂了 "trigger" 触发方式的 chain（预先算好，避免每次都重新扫描）
    local has_trigger_type_chain = false
    for _, trig_list in pairs(triggers_map) do
        for _, t in ipairs(trig_list) do
            if t.type == "trigger" then
                has_trigger_type_chain = true; break
            end
        end
        if has_trigger_type_chain then break end
    end

    local function run_initial_chain_logic()
        if not file_loaded then
            msg.debug("run_initial_chain_logic: no file loaded yet, skipped")
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

        local applied = {}

        for _, chain_def in ipairs(normal_chains) do
            local trig_list = triggers_map[chain_def.name]
            if trig_list then
                for _, t in ipairs(trig_list) do
                    if t.type == "file" then
                        applied[#applied + 1] = chain_def.name
                    elseif t.type == "property" then
                        applied[#applied + 1] = chain_def.name
                    elseif t.type == "trigger" then
                        local matched = TriggerEngine.run(trigger_rules, t.rules)
                        if matched then
                            applied[#applied + 1] = chain_def.name
                        end
                    end
                end
            else
                applied[#applied + 1] = chain_def.name
            end
        end

        for _, name in ipairs(applied) do
            apply_chain(name)
        end

        rule_evaluated = true
    end

    -- file-loaded 事件：立即执行 phase=early 的链（在 mpv auto_profiles 之前），
    -- 然后重置状态，等待 playback-restart 处理剩余链。
    mp.register_event("file-loaded", function()
        rule_evaluated = false
        pending_initial_restart = true
        video_reconfigured = false
        pending_prop_triggers = {}
        file_loaded = true

        for _, chain_def in ipairs(early_chains) do
            apply_chain(chain_def.name, { skip_video_check = true })
        end

        for k, timer in pairs(debounce_timers) do
            if k:match("^trigger_") then
                timer:kill(); debounce_timers[k] = nil
            end
        end
    end)

    -- video-reconfig：仅标记视频输出已配置完毕，由 playback-restart 消费。
    -- 不在此处直接调用 run_initial_chain_logic()，因为 video-reconfig 可能
    -- 先于 playback-restart 触发，此时视频参数可能尚未就绪。
    mp.register_event("video-reconfig", function()
        if Utils.has_video() then
            video_reconfigured = true
        end
    end)

    -- playback-restart：文件加载后的第一次 playback-restart 触发真正的链应用逻辑；
    -- 之后（例如用户 seek 导致的 playback-restart）仅作为兜底，若规则还没跑过则补跑一次
    mp.register_event("playback-restart", function()
        if pending_initial_restart then
            pending_initial_restart = false
            run_initial_chain_logic()
        elseif not rule_evaluated then
            evaluate_trigger_rules()
        end
    end)

    -- 手动触发接口：显式调用，既不受"无视频轨默认不触发"限制，也不受重复触发合并冷却限制
    mp.register_script_message("profile-chain", function(name)
        apply_chain(name, { skip_video_check = true, skip_cooldown = true })
    end)

    msg.info("profile-chain loaded: " .. #early_chains .. " early + " .. #normal_chains .. " normal chain(s), " .. #trigger_rules .. " rule(s), require_video="
        .. tostring(require_video))
end

setup()
