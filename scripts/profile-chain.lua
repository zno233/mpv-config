local mp = require "mp"
local msg = require "mp.msg"

local M = {}

-- ======================== Utilities ========================

local function trim(s) return s:match("^%s*(.-)%s*$") end

local function prop_val(key)
    local v = mp.get_property(key)
    if v == nil then return 0 end
    local n = tonumber(v)
    if n then return n end
    if v == "yes" then return true end
    if v == "no" then return false end
    return v
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local lines = {}
    for line in f:lines() do lines[#lines + 1] = line end
    f:close()
    return lines
end

local function get_list(tbl, key)
    local v = tbl[key]
    if not v then return {} end
    if type(v) == "table" then return v end
    return { v }
end

local function split(str, sep)
    local out = {}
    if not str or str == "" then return out end
    for m in (str .. sep):gmatch("(.-)" .. sep) do
        local t = trim(m)
        if t ~= "" then out[#out + 1] = t:lower() end
    end
    return out
end

-- ======================== Config Parser ========================

function M.parse_conf(path)
    local lines = read_file(path)
    if not lines then return {} end
    local sections = {}
    local cur = "_root"
    sections[cur] = {}
    for _, raw in ipairs(lines) do
        local line = trim(raw)
        if line ~= "" and not line:match("^#") then
            local sec = line:match("^%[(.+)%]$")
            if sec then
                cur = sec
                sections[cur] = sections[cur] or {}
            else
                local k, v = line:match("^(%S+)%s*=%s*(.-)%s*$")
                if k then
                    local existing = sections[cur][k]
                    if existing then
                        if type(existing) == "table" then
                            existing[#existing + 1] = v
                        else
                            sections[cur][k] = { existing, v }
                        end
                    else
                        sections[cur][k] = v
                    end
                end
            end
        end
    end
    return sections
end

-- ======================== Keyword Matching ========================

local SEP = "[%._%-%[%] ]"

local function pattern_escape(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local function compile_keywords(list)
    local out = {}
    for i, kw in ipairs(list) do
        local regex = kw:sub(1, 3) == "re:"
        local raw = regex and kw:sub(4) or kw
        out[i] = {
            raw = raw,
            esc = regex and raw or pattern_escape(raw),
            regex = regex,
            word = not regex and kw:match("^[%w_]+$") ~= nil,
        }
    end
    return out
end

local function word_match(s, kw)
    return s == kw.raw
        or s:find("^" .. kw.esc .. SEP) ~= nil
        or s:find(SEP .. kw.esc .. "$") ~= nil
        or s:find(SEP .. kw.esc .. SEP) ~= nil
end

local function match_keywords(text, keywords, depth)
    if not text or text == "" or #keywords == 0 then return false end
    local lower = text:lower()
    if depth then
        local segs = {}
        for seg in lower:gmatch("[^/]+") do segs[#segs + 1] = seg end
        local start = 1
        if depth > 0 and #segs > depth then start = #segs - depth + 1 end
        for i = start, #segs do
            for _, kw in ipairs(keywords) do
                if kw.regex then
                    if segs[i]:find(kw.esc) then return true end
                elseif kw.word then
                    if word_match(segs[i], kw) then return true end
                else
                    if segs[i]:find(kw.raw, 1, true) then return true end
                end
            end
        end
        return false
    end
    for _, kw in ipairs(keywords) do
        if kw.regex then
            if lower:find(kw.esc) then return true end
        elseif kw.word then
            if word_match(lower, kw) then return true end
        else
            if lower:find(kw.raw, 1, true) then return true end
        end
    end
    return false
end

local function match_lang(lang, list)
    if not lang or lang == "" or #list == 0 then return false end
    local lower = lang:lower()
    for _, l in ipairs(list) do
        if lower == l then return true end
    end
    return false
end

-- ======================== Expression AST ========================

local Expr = {}
Expr.__index = Expr

function Expr.var(n) return setmetatable({ type = "var", name = n }, Expr) end
function Expr.const(v) return setmetatable({ type = "const", value = v }, Expr) end
function Expr.not_(c) return setmetatable({ type = "not", child = c }, Expr) end
function Expr.and_(l, r) return setmetatable({ type = "and", left = l, right = r }, Expr) end
function Expr.or_(l, r) return setmetatable({ type = "or", left = l, right = r }, Expr) end

function Expr:eval(ctx)
    local t = self.type
    if t == "var" then return ctx[self.name] end
    if t == "const" then return self.value end
    if t == "not" then return not self.child:eval(ctx) end
    if t == "and" then return self.left:eval(ctx) and self.right:eval(ctx) end
    if t == "or" then return self.left:eval(ctx) or self.right:eval(ctx) end
    return false
end

function Expr:collect_vars(out)
    if self.type == "var" then out[self.name] = true
    elseif self.type == "and" or self.type == "or" then
        self.left:collect_vars(out)
        self.right:collect_vars(out)
    elseif self.type == "not" then
        self.child:collect_vars(out)
    end
end

local function parse_expr(expr)
    if not expr or expr == "" then return Expr.const(false), false end
    local pos, fail = { i = 1 }, false
    local function skip()
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == " " do pos.i = pos.i + 1 end
    end
    local parse_or, parse_and, parse_unary, parse_atom
    parse_atom = function()
        skip()
        if pos.i <= #expr and expr:sub(pos.i, pos.i) == "(" then
            pos.i = pos.i + 1
            local node = parse_or()
            skip()
            if pos.i <= #expr and expr:sub(pos.i, pos.i) == ")" then pos.i = pos.i + 1
            else msg.warn("expr: missing ')'"); fail = true end
            return node
        end
        local w = ""
        while pos.i <= #expr do
            local c = expr:sub(pos.i, pos.i)
            if c == " " or c == ")" or c == "&" or c == "|" or c == "!" then break end
            w = w .. c; pos.i = pos.i + 1
        end
        w = w:lower()
        if w == "" then fail = true; return Expr.const(false) end
        if w == "title" or w == "name" or w == "path" or w == "audio" then return Expr.var(w) end
        return Expr.const(false)
    end
    parse_unary = function()
        skip()
        if pos.i <= #expr and expr:sub(pos.i, pos.i) == "!" then
            pos.i = pos.i + 1; return Expr.not_(parse_unary())
        end
        return parse_atom()
    end
    parse_and = function()
        local left = parse_unary(); skip()
        while pos.i <= #expr and expr:sub(pos.i, pos.i) == "&" do
            pos.i = pos.i + 1; skip()
            if pos.i > #expr or expr:sub(pos.i, pos.i) == "&" or expr:sub(pos.i, pos.i + 1) == "||" then
                fail = true; break
            end
            left = Expr.and_(left, parse_unary()); skip()
        end
        return left
    end
    parse_or = function()
        local left = parse_and(); skip()
        while pos.i <= #expr - 1 and expr:sub(pos.i, pos.i + 1) == "||" do
            pos.i = pos.i + 2; skip()
            if pos.i > #expr or expr:sub(pos.i, pos.i) == "&" or expr:sub(pos.i, pos.i + 1) == "||" then
                fail = true; break
            end
            left = Expr.or_(left, parse_and()); skip()
        end
        return left
    end
    local ast = parse_or(); skip()
    if pos.i <= #expr then fail = true end
    return ast, fail
end

-- ======================== Profile-Cond Evaluator ========================

local COND_PROPS = {
    "width", "height", "video-aspect", "video-params/par",
    "display-fps", "container-fps", "estimated-vf-fps", "current-vo",
}
local BOOL_PROPS = {
    "pause", "idle-active", "window-maximized", "window-minimized",
}
local cond_cache = {}
local cond_env = nil

local function build_cond_env()
    local e = {}
    e.get = prop_val
    e.p = setmetatable({}, { __index = function(_, k) return prop_val("p." .. k) end })
    e.path = mp.get_property("path") or ""
    e.filename = mp.get_property("filename") or ""
    e.vid = prop_val("vid")
    e.aid = prop_val("aid")
    e.sid = prop_val("sid")
    e.platform = mp.get_property("platform") or ""
    for _, p in ipairs(COND_PROPS) do e[p] = prop_val(p) end
    for _, p in ipairs(BOOL_PROPS) do e[p] = (mp.get_property(p) == "yes") end
    setmetatable(e, { __index = function(_, k) return prop_val(k) end })
    return e
end

function M.eval_cond(cond)
    if not cond or cond == "" then return true end
    if cond_cache[cond] ~= nil then return cond_cache[cond] end
    if not cond_env then cond_env = build_cond_env() end
    local func, err = load("return " .. cond, "profile-cond", "t", cond_env)
    if not func then cond_cache[cond] = false; return false end
    local ok, result = pcall(func)
    if not ok then cond_cache[cond] = false; return false end
    cond_cache[cond] = (result == true)
    return cond_cache[cond]
end

function M.reset_cond() cond_cache = {}; cond_env = nil end

function M.load_profile_conds()
    local out = {}
    local conf_path = mp.command_native({ "expand-path", "~~/profiles.conf" })
    local lines = read_file(conf_path)
    if not lines then msg.warn("load_profile_conds: cannot read " .. conf_path); return out end
    local cur = nil
    for _, raw in ipairs(lines) do
        local line = trim(raw)
        local name = line:match("^%[(.+)%]$")
        if name then cur = name end
        if cur then
            local c = line:match("^profile%-cond%=(.+)$")
            if c then out[cur] = c end
        end
    end
    local count = 0
    for _ in pairs(out) do count = count + 1 end
    msg.info("load_profile_conds: loaded " .. count .. " conditions from " .. conf_path)
    return out
end

-- ======================== Chain System ========================

function M.trigger_chain(head, chains, conds)
    local chain = chains[head]
    if not chain then return end
    local vid = mp.get_property("vid")
    if not vid or vid == "0" then
        msg.info("trigger_chain: " .. head .. " skipped (no video)")
        return
    end
    msg.info("trigger_chain: " .. head .. " (vid=" .. vid .. ")")
    for _, name in ipairs(chain) do
        local c = conds[name]
        if c then
            msg.info("  " .. name .. " has cond: " .. c)
            if M.eval_cond(c) then
                mp.commandv("apply-profile", name)
                msg.info("  " .. name .. " applied (cond=true)")
            else
                msg.info("  " .. name .. " skipped (cond=false)")
            end
        else
            msg.info("  " .. name .. " applied (no cond)")
            mp.commandv("apply-profile", name)
        end
    end
end

local function make_debounced(fn)
    local timers = {}
    return function(key)
        if timers[key] then timers[key]:kill() end
        timers[key] = mp.add_timeout(0.1, function()
            timers[key] = nil; fn(key)
        end)
    end
end

-- ======================== Detect Module ========================

local Detect = {}

function Detect.load(conf)
    local rules, needs = {}, {}
    local function add(name, prefix)
        local chain_head = conf[prefix .. "profile"]
        if not chain_head or chain_head == "" then
            if name ~= "" then msg.warn("detect: '" .. name .. "' no profile, skip") end
            return
        end
        local expr_str = conf[prefix .. "match"] or "path"
        local ast, fail = parse_expr(expr_str)
        if fail then msg.warn("detect: '" .. name .. "' expr fail, skip"); return end
        local r = {
            name = name or "unnamed",
            keywords = compile_keywords(split(conf[prefix .. "keywords"], ",")),
            languages = split(conf[prefix .. "languages"], ","),
            chain_head = chain_head,
            ast = ast,
            needs = {},
        }
        ast:collect_vars(r.needs)
        for k in pairs(r.needs) do needs[k] = true end
        rules[#rules + 1] = r
    end
    local max_rules = tonumber(conf.max_rules) or 10
    for i = 1, max_rules do
        local p = "rule" .. i .. "_"
        local n = conf[p .. "name"]
        if n and n ~= "" then add(n, p) end
    end
    for _, key in ipairs({
        "anime", "movie", "live", "drama", "doc", "news", "variety",
    }) do
        if conf[key .. "_keywords"] then add(key, key .. "_") end
    end
    return rules, needs
end

function Detect.run(rules, needs, path_depth)
    if #rules == 0 then return nil end
    local path = needs.path and (mp.get_property("path") or "") or ""
    local name = needs.name and (mp.get_property("filename") or "") or ""
    local title = needs.title and (mp.get_property("metadata/title") or "") or ""
    local lang = needs.audio and (mp.get_property("current-tracks/audio/lang") or "") or ""
    for _, rule in ipairs(rules) do
        local n = rule.needs.name and match_keywords(name, rule.keywords) or false
        local t = rule.needs.title and match_keywords(title, rule.keywords) or false
        local p = rule.needs.path and match_keywords(path, rule.keywords, path_depth) or false
        local l = rule.needs.audio and match_lang(lang, rule.languages) or false
        if rule.ast:eval({ title = t, name = n, path = p, audio = l }) then
            return rule
        end
    end
    return nil
end

-- ======================== Trigger Parser ========================

local function parse_trigger(str)
    str = trim(str)
    if str == "file" then
        return { type = "file" }
    elseif str:match("^property:") then
        local props = {}
        for p in str:sub(10):gmatch("[^,]+") do
            p = trim(p)
            if p ~= "" then props[#props + 1] = p end
        end
        return { type = "property", props = props }
    elseif str:match("^detect:") then
        return { type = "detect", mode = str:sub(8) }
    else
        msg.warn("unknown trigger: " .. str)
        return nil
    end
end

local function parse_triggers(values)
    local out = {}
    for _, v in ipairs(get_list(values)) do
        for t in v:gmatch("[^;]+") do
            local trigger = parse_trigger(t)
            if trigger then out[#out + 1] = trigger end
        end
    end
    return out
end

-- ======================== Main ========================

function M.setup()
    local conf_path = mp.command_native({ "expand-path", "~~/script-opts/profile-chain.conf" })
    local sections = M.parse_conf(conf_path)
    local root = sections["_root"] or {}
    local detect_sec = sections["detect"] or {}

    local chains, triggers_map = {}, {}
    for k, v in pairs(root) do
        if k:match("%.on$") then
            local head = k:match("^(.+)%.on$")
            triggers_map[head] = parse_triggers(v)
        else
            local chain = {}
            for name in (type(v) == "table" and v[1] or v):gmatch("[^,]+") do
                name = trim(name)
                if name ~= "" then chain[#chain + 1] = name end
            end
            chains[k] = chain
        end
    end

    local conds = M.load_profile_conds()
    local trigger = make_debounced(function(head)
        M.trigger_chain(head, chains, conds)
    end)

    local detect_rules, detect_needs = Detect.load(detect_sec)
    local path_depth = tonumber(detect_sec.path_depth) or 0
    local show_osd = detect_sec.show_osd == "yes"
    local osd_dur = (tonumber(detect_sec.osd_duration) or 1500) / 1000
    local show_nomatch = detect_sec.show_no_match == "yes"
    local detected = false
    local detect_timer = nil

    local function fire_all_detect()
        if detected or #detect_rules == 0 then return end
        local rule = Detect.run(detect_rules, detect_needs, path_depth)
        detected = true
        if rule then
            M.trigger_chain(rule.chain_head, chains, conds)
            msg.info("detect: " .. rule.chain_head .. " (" .. rule.name .. ")")
            if show_osd then mp.osd_message("auto: " .. rule.name, osd_dur) end
        elseif show_nomatch then
            mp.osd_message("no match", osd_dur)
        end
    end

    for head, _ in pairs(chains) do
        for _, t in ipairs(triggers_map[head] or {}) do
            if t.type == "property" then
                for _, prop in ipairs(t.props) do
                    mp.observe_property(prop, "native", function() trigger(head) end)
                end
            end
        end
    end

    mp.register_event("file-loaded", function()
        detected = false
        if detect_timer then detect_timer:kill(); detect_timer = nil end
        M.reset_cond()
        local vid = mp.get_property("vid")
        if not vid or vid == "0" then return end
        for head, tlist in pairs(triggers_map) do
            for _, t in ipairs(tlist) do
                if t.type == "file" then
                    M.trigger_chain(head, chains, conds)
                end
            end
        end
        local has_detect = false
        for _, tlist in pairs(triggers_map) do
            for _, t in ipairs(tlist) do
                if t.type == "detect" then has_detect = true; break end
            end
            if has_detect then break end
        end
        if has_detect and #detect_rules > 0 then
            if not detect_needs.audio then
                fire_all_detect()
            else
                detect_timer = mp.add_timeout(0.2, function()
                    detect_timer = nil; fire_all_detect()
                end)
            end
        end
    end)

    mp.register_event("playback-restart", function()
        if not detected then fire_all_detect() end
    end)

    mp.register_script_message("profile-chain", function(head)
        M.trigger_chain(head, chains, conds)
    end)
end

M.setup()
return M
