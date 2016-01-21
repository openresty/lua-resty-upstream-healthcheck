local stream_sock = ngx.socket.tcp
local log = ngx.log
local ERR = ngx.ERR
local INFO = ngx.INFO
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local str_find = string.find
local sub = string.sub
local re_find = ngx.re.find
local new_timer = ngx.timer.at
local shared = ngx.shared
local debug_mode = ngx.config.debug
local concat = table.concat
local tonumber = tonumber
local tostring = tostring
local ipairs = ipairs
local ceil = math.ceil
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local pcall = pcall
local cjson = require("cjson.safe").new()

-- upstream keys
local KEY_LOCK = "l:"          -- lock
local KEY_DATA = "d:"          -- serialized json data
local KEY_PEER_VERSION = "pv:" -- version flag for peer list change
                               --   (incoming signal)
local KEY_AVAILABLE = "av:"    -- version flag for list of available servers/
                               --   peers change (outgoing signal)


local _M = {
    _VERSION = '0.03'
}

if not ngx.config
   or not ngx.config.ngx_lua_version
   or ngx.config.ngx_lua_version < 9005
then
    error("ngx_lua 0.9.5+ required")
end

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function() return {} end
end

local function info(...)
    log(INFO, "healthcheck: ", ...)
end

local function warn(...)
    log(WARN, "healthcheck: ", ...)
end

local function errlog(...)
    log(ERR, "healthcheck: ", ...)
end

local function debug(...)
    -- print("debug mode: ", debug_mode)
    if debug_mode then
        log(DEBUG, "healthcheck: ", ...)
    end
end

local function gen_upstream_key(prefix, u)
    return prefix .. u
end

local function peer_fail(ctx, peer)
    debug("peer ", peer.name, " was checked to be not ok")

    peer.fails = (peer.fails or 0) + 1

    if peer.fails == 1 then
        peer.successes = nil
    end

    if not peer.down and peer.fails >= ctx.fall then
        warn("peer ", peer.name, " is turned down after ", peer.fails,
                " failure(s)")
        peer.down = true
    end
end

local function peer_ok(ctx, peer)
    debug("peer ", peer.name, " was checked to be ok")

    peer.successes = (peer.successes or 0) + 1

    if peer.successes == 1 then
        peer.fails = nil
    end

    if peer.down and peer.successes >= ctx.rise then
        warn("peer ", peer.name, " is turned up after ", peer.successes,
                " success(es)")
        peer.down = nil
    end
end

local function check_peer(ctx, peer)
    local ok, err, sock
    local name = peer.name
    local statuses = ctx.statuses
    local req = ctx.http_req

    sock, err = stream_sock()
    if not sock then
        errlog("failed to create stream socket: ", err)
        return
    end

    sock:settimeout(ctx.timeout)

    if peer.host then
        -- print("peer port: ", peer.port)
        ok, err = sock:connect(peer.host, peer.port)
    else
        ok, err = sock:connect(name)
    end
    if not ok then
        if not peer.down then
            errlog("failed to connect to ", name, ": ", err)
        end
        peer_fail(ctx, peer)
    else
        local bytes, err = sock:send(req)
        if not bytes then
            if not peer.down then
                errlog("failed to send request to ", name, ": ", err)
            end
            peer_fail(ctx, peer)
        else
            local status_line, err = sock:receive()
            if not status_line then
                if not peer.down then
                    errlog("failed to receive status line from ", name,
                           ": ", err)
                end
                peer_fail(ctx, peer)
            else
                if statuses then
                    local from, to = re_find(status_line,
                                                  [[^HTTP/\d+\.\d+\s+(\d+)]],
                                                  "joi", nil, 1)
                    if not from then
                        if not peer.down then
                            errlog("bad status line from ", name, ": ",
                                   status_line)
                        end
                        peer_fail(ctx, peer)
                    else
                        local status = tonumber(sub(status_line, from, to))
                        if not statuses[status] then
                            if not peer.down then
                                errlog("bad status code from ",
                                       name, ": ", status)
                            end
                            peer_fail(ctx, peer)
                        else
                            peer_ok(ctx, peer)
                        end
                    end
                else
                    peer_ok(ctx, peer)
                end
            end
            sock:close()
        end
    end
end

local function check_peer_range(ctx, from, to, peers)
    for i = from, to do
        check_peer(ctx, peers[i])
    end
end

local function check_peers(ctx, peers, is_backup)
    local n = #peers
    if n == 0 then
        return
    end

    local concur = ctx.concurrency
    if concur <= 1 then
        for i = 1, n do
            check_peer(ctx, peers[i])
        end
    else
        local threads
        local nthr

        if n <= concur then
            nthr = n - 1
            threads = new_tab(nthr, 0)
            for i = 1, nthr do

                if debug_mode then
                    debug("spawn a thread checking ",
                          is_backup and "backup" or "primary", " peer ", i - 1)
                end

                threads[i] = spawn(check_peer, ctx, i - 1, peers[i], is_backup)
            end
            -- use the current "light thread" to run the last task
            if debug_mode then
                debug("check ", is_backup and "backup" or "primary", " peer ",
                      n - 1)
            end
            check_peer(ctx, peers[n])

        else
            local group_size = ceil(n / concur)
            local nthr = ceil(n / group_size) - 1

            threads = new_tab(nthr, 0)
            local from = 1
            local rest = n
            for i = 1, nthr do
                local to
                if rest >= group_size then
                    rest = rest - group_size
                    to = from + group_size - 1
                else
                    rest = 0
                    to = from + rest - 1
                end

                if debug_mode then
                    debug("spawn a thread checking ",
                          is_backup and "backup" or "primary", " peers ",
                          from - 1, " to ", to - 1)
                end

                threads[i] = spawn(check_peer_range, ctx, from, to, peers)
                from = from + group_size
                if rest == 0 then
                    break
                end
            end
            if rest > 0 then
                local to = from + rest - 1

                if debug_mode then
                    debug("check ", is_backup and "backup" or "primary",
                          " peers ", from - 1, " to ", to - 1)
                end

                check_peer_range(ctx, from, to, peers)
            end
        end

        if nthr and nthr > 0 then
            for i = 1, nthr do
                local t = threads[i]
                if t then
                    wait(t)
                end
            end
        end
    end
end

local function get_timer_lock(ctx)
    local dict = ctx.dict
    local key = gen_upstream_key(KEY_LOCK, ctx.upstream)

    -- the lock is held for the whole interval to prevent multiple
    -- worker processes from sending the test request simultaneously.
    -- here we substract the lock expiration time by 1ms to prevent
    -- a race condition with the next timer event.
    local ok, err = dict:add(key, true, ctx.interval - 0.001)
    if not ok then
        if err == "exists" then
            return nil
        end
        errlog("failed to add key \"", key, "\": ", err)
        return nil
    end
    return true
end

-- Fetches the list of peers and its data from the shm.
-- @param upstream Name of the upstream whose data to fetch
-- @return table with 3 keys;primary_peers, backup_peers, both lists with peers,
-- and a version number
local function read_peer_data(ctx)
    local data, err = ctx.dict:get(gen_upstream_key(KEY_DATA, ctx.u))

    if not data then
        return nil, "failed fetching data from shm; " .. tostring(err)
    end

    return cjson.decode(data)
end

-- Writes the list of peers and its data to the shm.
-- @param upstream Name of the upstream whose data to fetch
-- @param peers table with 3 keys;primary_peers, backup_peers, both lists with
-- peers, and a version number
-- @return true on success, nil+error on failure
local function write_peer_data(ctx, peers)
    local data, err, success
    data, err = cjson.encode(peers)

    if not data then
        return nil, "failed encoding data; " .. tostring(err)
    end

    success, err = ctx.dict:set(gen_upstream_key(KEY_DATA, ctx.u), data)

    if not success then
        return nil, "failed writing data to shm; " .. tostring(err)
    end

    return true
end

local function preprocess_peers(peers)
    local n = #peers
    for i = 1, n do
        local p = peers[i]
        local name = p.name
        if name then
            local idx = str_find(name, ":", 1, true)
            if idx then
                p.host = sub(name, 1, idx - 1)
                p.port = tonumber(sub(name, idx + 1))
            end
        end
    end
    return peers
end

-- Will fetch the updated peer list, and update our local lists (in place)
-- @return peers table on success, nil+error otherwise
local function update_peers_version(ctx, peers)
    local ppeers, bpeers, err
    ppeers, err = ctx.get_primary_peers(ctx.u)
    if not ppeers then
        return nil, "failed to get primary peers: " .. err
    end

    bpeers, err = ctx.get_backup_peers(ctx.u)
    if not bpeers then
        return nil, "failed to get backup peers: " .. err
    end

    ppeers = preprocess_peers(ppeers)
    bpeers = preprocess_peers(bpeers)

    -- preserve failure and success numbers
    local p = peers.primary_peers
    for _, peer in ipairs(p) do
        p[peer.name] = peer
    end

    local b = peers.backup_peers
    for _, peer in ipairs(b) do
        b[peer.name] = peer
    end

    for _, peer in ipairs(ppeers) do
        local op = p[peer.name] or {} -- old-peer table
        peer.fails = peer.down and op.fails
        peer.successes = (not peer.down) and op.successes
    end

    for _, peer in ipairs(bpeers) do
        local op = b[peer.name] or {} -- old-peer table
        peer.fails = peer.down and op.fails
        peer.successes = (not peer.down) and op.successes
    end

    peers.primary_peers = ppeers
    peers.backup_peers = bpeers
    return peers
end

local function do_check(ctx)
    debug("healthcheck: run a check cycle")
    local success
    local dict = ctx.dict

    if get_timer_lock(ctx) then

        local peers, err = read_peer_data(ctx)
        if not peers then
            return errlog("failed to fetch the peer data; " .. tostring(err))
        end

        local key = gen_upstream_key(KEY_PEER_VERSION, ctx.upstream)
        local peers_version = dict:get(key)

        if peers_version ~= peers.version then
            if debug_mode then
                debug("New peer list was flagged, updating to version ",
                      peers_version)
            end

            success, err = update_peers_version(ctx, peers)
            if not success then
                return errlog("error updating peers list; " .. tostring(err))
            end
            ctx.new_version = true
        end

        check_peers(ctx, peers.primary_peers, false)
        check_peers(ctx, peers.backup_peers, true)
--TODO: check defaults, timer is 2 secs, timeout = 1 sec
-- we do 2 updates; primary and backup, if each has a timeout, then the lock
-- will be released before we are done.
-- note: if number of peers in either list is larger than concurrency setting,
-- it might take even longer
        if ctx.new_version then
            success, err = write_peer_data(ctx, peers)
            if not success then
                return errlog("error storing updated peers list; " ..
                              tostring(err))
            end

            local key = gen_upstream_key(KEY_AVAILABLE, ctx.upstream)
            dict:add(key, 0)
            success, err = dict:incr(key, 1)
            if not success then
                return errlog("error publishing available peers version; " ..
                              tostring(err))
            end

            if debug_mode then
                debug("published available peers version ", success)
            end
        end
    end

end

local check
check = function (premature, ctx)
    local ok, err
    if premature then
        return
    end

    ok, err = pcall(do_check, ctx)
    if not ok then
        errlog("failed to run healthcheck cycle: ", err)
    end

    ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            errlog("failed to create timer: ", err)
        end
        return
    end
end

local function load_upstream_manager(upstream_manager)
    upstream_manager = upstream_manager or "ngx.upstreams"

    assert(type(upstream_manager) == "string" or
           type(upstream_manager == "table"),
           "the upstream_manager option must be a string (module name) or " ..
           "table (actual module)")

    if type(upstream_manager) == string then
        local ok, upstream = pcall(require, upstream_manager)
        if not ok then
            error('Could not load the required "'..upstream_manager..'" module')
        end
        upstream_manager = upstream
    end

    for _,fname in ipairs({"set_peer_down", "get_primary_peers",
                          "get_backup_peers", "get_upstreams"}) do
        assert(type(upstream_manager[fname]) == "function",
               'expected the "upstream_manager" to have a "'..fname..
               '" function')
    end

    return upstream_manager
end

function _M.spawn_checker(opts)
    local ok, err, bpeers, ppeers
    local typ = opts.type
    if not typ then
        return nil, "\"type\" option required"
    end

    if typ ~= "http" then
        return nil, "only \"http\" type is supported right now"
    end

    local http_req = opts.http_req
    if not http_req then
        return nil, "\"http_req\" option required"
    end

    local timeout = opts.timeout
    if not timeout then
        timeout = 1000
    end

    local interval = opts.interval
    if not interval then
        interval = 1

    else
        interval = interval / 1000
        if interval < 0.002 then  -- minimum 2ms
            interval = 0.002
        end
    end

    local valid_statuses = opts.valid_statuses
    local statuses
    if valid_statuses then
        statuses = new_tab(0, #valid_statuses)
        for _, status in ipairs(valid_statuses) do
            -- print("found good status ", status)
            statuses[status] = true
        end
    end

    -- debug("interval: ", interval)

    local concur = opts.concurrency
    if not concur then
        concur = 1
    end

    local fall = opts.fall
    if not fall then
        fall = 5
    end

    local rise = opts.rise
    if not rise then
        rise = 2
    end

    local shm = opts.shm
    if not shm then
        return nil, "\"shm\" option required"
    end

    local dict = shared[shm]
    if not dict then
        return nil, "shm \"" .. tostring(shm) .. "\" not found"
    end

    local u = opts.upstream
    if not u then
        return nil, "no upstream specified"
    end

    local upstream_manager = load_upstream_manager(opts.upstream_manager)

    ppeers, err = upstream_manager.get_primary_peers(u)
    if not ppeers then
        return nil, "failed to get primary peers: " .. err
    end

    bpeers, err = upstream_manager.get_backup_peers(u)
    if not bpeers then
        return nil, "failed to get backup peers: " .. err
    end

    local ctx = {
        upstream = u,
        primary_peers = preprocess_peers(ppeers),
        backup_peers = preprocess_peers(bpeers),
        http_req = http_req,
        timeout = timeout,
        interval = interval,
        dict = dict,
        fall = fall,
        rise = rise,
        statuses = statuses,
        version = 0,
        concurrency = concur,
        set_peer_down = upstream_manager.set_peer_down,
        get_primary_peers = upstream_manager.get_primary_peers,
        get_backup_peers = upstream_manager.get_backup_peers,
--TODO how to update options, like interval, etc.??
    }

    ok, err = new_timer(0, check, ctx)
    if not ok then
        return nil, "failed to create timer: " .. err
    end

    return true
end

-- Will signal the healthchecker for `upstream` to reload its peer lists.
-- Call this when a peer has been added or removed from the upstream peer list.
-- @param shm Name of the shm object to use
-- @param upstream Name of the upstream block to use
-- @return `true` on success, `nil+error`  otherwise
function _M.signal_reload_peers(shm, upstream)
    -- TODO: question; should we accept the same `opts` table as `spawn`? so
    --                 calling code can reuse it???
    local dict = shared[shm or ""]

    if not dict then
        return nil, "shm \"" .. tostring(shm) .. "\" not found"
    end

    if not type(upstream) == "string" then
        return nil, "upstream name must be a string"
    end

    local key = gen_upstream_key(KEY_PEER_VERSION, upstream)

    local success, err = dict:incr(key, 1)
    if not success then
        return nil, "failed to update the version flag: "..tostring(err)
    end

    return true
end

local function gen_peers_status_info(peers, bits, idx)
    local npeers = #peers
    for i = 1, npeers do
        local peer = peers[i]
        bits[idx] = "        "
        bits[idx + 1] = peer.name
        if peer.down then
            bits[idx + 2] = " DOWN\n"
        else
            bits[idx + 2] = " up\n"
        end
        idx = idx + 3
    end
    return idx
end

function _M.status_page(opts)
    -- generate an HTML page
    local upstream_manager = load_upstream_manager(opts.upstream_manager)
    local us, err = upstream_manager.get_upstreams()
    if not us then
        return "failed to get upstream names: " .. err
    end

    local n = #us
    local bits = new_tab(n * 20, 0)
    local idx = 1
    for i = 1, n do
        if i > 1 then
            bits[idx] = "\n"
            idx = idx + 1
        end

        local u = us[i]
        bits[idx] = "Upstream "
        bits[idx + 1] = u
        bits[idx + 2] = "\n    Primary Peers\n"
        idx = idx + 3

        local peers, err = upstream_manager.get_primary_peers(u)
        if not peers then
            return "failed to get primary peers in upstream " .. u .. ": "
                   .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)

        bits[idx] = "    Backup Peers\n"
        idx = idx + 1

        peers, err = upstream_manager.get_backup_peers(u)
        if not peers then
            return "failed to get backup peers in upstream " .. u .. ": "
                   .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)
    end
    return concat(bits)
end

return _M
