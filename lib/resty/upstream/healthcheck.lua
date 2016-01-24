--[[== START ============= temporary debug code ============================]]--
-- with Lua 5.1 patch global xpcall to take function args (standard in 5.2+)
if _VERSION=="Lua 5.1" then
  local xp = xpcall
  xpcall = function(f, err, ...)
    local a = { n = select("#", ...), ...}
    return xp(function(...) return f(unpack(a,1,a.n)) end, err)
  end
end

-- error handler to attach stacktrack to error message
local ehandler = function(err)
  return debug.traceback(tostring(err))
end

-- patch global pcall to attach stacktrace to the error. 
pcall = function(fn, ...)
  return xpcall(fn, ehandler, ...)
end
--[[== END =============== temporary debug code ============================]]--

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
local debug_mode = true --ngx.config.debug
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
local KEY_DATA = "d:"          -- serialized healthcheck json data
local KEY_DATA_VERSION = "dv:" -- version of serialized healthcehck data
                               --   horizontal signal to other workers
local KEY_UPSTREAM_VERSION = "pv:" -- version flag for peer list change
                               --   (incoming signal, vertical)
--local KEY_AVAILABLE_VERSION = "av:"    -- version flag for list of available servers/
                               --   peers change (outgoing signal, vertical)


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

-- flags a new upstream version
-- used by upstream mananegr to flag an update
local function new_upstream_version(dict, upstream)
    local key = KEY_UPSTREAM_VERSION..upstream
    dict:add(key, 0)
    local newversion, err = dict:incr(key, 1)
    if err then
        errlog("failed to update upstream version; ", err)
        return nil, err
    end
    return newversion
end

-- returns the current upstream version
-- upstream manager will flag this if a peer is added or removed
local function get_upstream_version(dict, upstream)
    local version, err = dict:get(KEY_UPSTREAM_VERSION..upstream)
    if version == nil and err == nil then
        -- nothing was found, so initialize it
        version, err = new_upstream_version(dict, upstream)
        debug("no upstream version found, initialized it to ", version)
    end

    if err then
        errlog("failed to get upstream version; ", err)
        return nil, err
    end
    return version
end

-- returns the current healtcheck-data version
local function get_healthcheck_data_version(dict, upstream)
    local version, err = dict:get(KEY_DATA_VERSION..upstream)
    if err then
        errlog("failed to get healthcheck data version; ", err)
        return nil, err
    end
    return version or 0
end

-- flags a new healthcheck-data version
local function new_healthcheck_data_version(dict, upstream)
    local key = KEY_DATA_VERSION..upstream
    dict:add(key, 0)
    local newversion, err = dict:incr(key, 1)
    if err then
        errlog("failed to update healthcheck data version; ", err)
        return nil, err
    end
    return newversion
end

--[[ flags a new version of the available-peers 
local function new_available_peers_version(dict, upstream)
    local key = KEY_AVAILABLE_VERSION..upstream
    dict:add(key, 0)
    local newversion, err = dict:incr(key, 1)
    if err then
        errlog("failed to update available peers version; ", err)
        return nil, err
    end
    return newversion
end  --]]

-- Fetches the list of peers and their healthcheck data from the shm.
-- @param upstream Name of the upstream whose data to fetch
-- @return table with peer data and version numbers, empty if not found.
local function read_healthcheck_data(dict, upstream)
    local data, err = dict:get(KEY_DATA..upstream)

    if not data then
        if err then
            return errlog("failed fetching data from shm; ", err)
        end
        -- no error, so there was nothing in the shm
        debug("no healthcheck data found")
        return { 
            primary_peers = {},
            backup_peers = {},
            version = 0,
            upstream_version = 0,
        }
    end

    return cjson.decode(data)
end

-- Writes the list of peers and their healthcheck data to the shm.
-- @param upstream Name of the upstream whose data to fetch
-- @param peers table with 3 keys;primary_peers, backup_peers, and a version
-- @return true on success, nil+error on failure
local function write_healthcheck_data(ctx, peers)
    local data, err, success
    local dict = ctx.dict
    local u = ctx.upstream
    
    data, err = cjson.encode(peers)

    if not data then
        return nil, "failed encoding data; " .. tostring(err)
    end

    success, err = dict:set(KEY_DATA .. u, data)
    
    if not success then
        return nil, "failed writing data to shm; " .. tostring(err)
    end

    return true
end

-- callback to the upstream_manager to inform about a status change
-- in a specific peer
local function update_upstream_status(ctx, is_backup, id, is_down)
    local ok, err = ctx.set_peer_down(ctx.upstream, is_backup, id-1, is_down)
    if not ok then
        errlog("failed to set peer status: ", err)
    end
end

-- registers a single healthcheck failure for a peer, marks peer as
-- down if the threshold of failures is exceeded
local function peer_fail(ctx, peer, is_backup, id)
    debug("peer ", peer.name, " was checked to be not ok")

    peer.fails = math.min((peer.fails or 0) + 1, ctx.fall)
    peer.successes = nil

    if not peer.down and peer.fails >= ctx.fall then
        warn("peer ", peer.name, " is turned down after ", peer.fails,
                " failure(s)")
        peer.down = true
        ctx.availability_update = true
        update_upstream_status(ctx, is_backup, id, true)
    end
end

-- registers a single healthcheck success for a peer, marks peer as
-- up if the threshold of successes is exceeded
local function peer_ok(ctx, peer, is_backup, id)
    debug("peer ", peer.name, " was checked to be ok")

    peer.successes = math.min((peer.successes or 0) + 1, ctx.rise)
    peer.fails = nil

    if peer.down and peer.successes >= ctx.rise then
        warn("peer ", peer.name, " is turned up after ", peer.successes,
                " success(es)")
        peer.down = nil
        ctx.availability_update = true
        update_upstream_status(ctx, is_backup, id, false)
    end
end

-- check a single peer, and calls into the failure/success handlers
local function check_peer(ctx, peer, is_backup, id)
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
        peer_fail(ctx, peer, is_backup, id)
    else
        local bytes, err = sock:send(req)
        if not bytes then
            if not peer.down then
                errlog("failed to send request to ", name, ": ", err)
            end
            peer_fail(ctx, peer, is_backup, id)
        else
            local status_line, err = sock:receive()
            if not status_line then
                if not peer.down then
                    errlog("failed to receive status line from ", name,
                           ": ", err)
                end
                peer_fail(ctx, peer, is_backup, id)
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
                        peer_fail(ctx, peer, is_backup, id)
                    else
                        local status = tonumber(sub(status_line, from, to))
                        if not statuses[status] then
                            if not peer.down then
                                errlog("bad status code from ",
                                       name, ": ", status)
                            end
                            peer_fail(ctx, peer, is_backup, id)
                        else
                            peer_ok(ctx, peer, is_backup, id)
                        end
                    end
                else
                    peer_ok(ctx, peer, is_backup, id)
                end
            end
            sock:close()
        end
    end
end

-- checks a range of peers from a list
local function check_peer_range(ctx, from, to, peers, is_backup)
    for i = from, to do
        check_peer(ctx, peers[i], is_backup, i)
    end
end

-- checks all peers in a list
local function check_peers(ctx, peers, is_backup)
    local n = #peers
    if n == 0 then
        return
    end

    local concur = ctx.concurrency
    if concur <= 1 then
        for i = 1, n do
            check_peer(ctx, peers[i], is_backup, i)
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

                threads[i] = spawn(check_peer, ctx, peers[i], is_backup, i)
            end
            -- use the current "light thread" to run the last task
            if debug_mode then
                debug("check ", is_backup and "backup" or "primary", " peer ",
                      n - 1)
            end
            check_peer(ctx, peers[n], is_backup, n)

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

                threads[i] = spawn(check_peer_range, ctx, from, to, peers, is_backup)
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

                check_peer_range(ctx, from, to, peers, is_backup)
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
    local key = KEY_LOCK..ctx.upstream
    -- the lock is held for the whole interval to prevent multiple
    -- worker processes from sending the test request simultaneously.
    -- here we substract the lock expiration time by 1ms to prevent
    -- a race condition with the next timer event.
    local ok, err = dict:add(key, true, ctx.interval-0.001)
    if not ok then
        if err == "exists" then
            return nil
        end
        errlog("failed to add key \"", key, "\": ", err)
        return nil
    end
    return true
end

-- handles the upstream updates for a list of peers
-- @return new updated peers list, or nil on error
local function update_upstream(ctx, peers, is_backup)
  
    local fetch = is_backup and ctx.get_backup_peers or ctx.get_primary_peers
    local upeers, err = fetch(ctx.upstream)
    if not upeers then
        return errlog("failed to get ", is_backup and "backup" or "primary",
                      " peers: ", err)
    end
    
    local reverse = {}
    for _, peer in ipairs(peers) do
        reverse[peer.name] = peer
    end

    for i, peer in ipairs(upeers) do
        -- when we don't know the peer, copy the down status from the
        -- upstream_manager to prevent a peer being added as 'down' to
        -- be switched to 'up' immediately
        local op = reverse[peer.name] or { down = peer.down } -- old-peer table
        peer.fails = op.fails
        peer.successes = op.successes
        if peer.down ~= op.down then
            -- healthcheck data overrules the data from upstream_manager
            -- this to make sure that other workerprocesses follow the
            -- healthcheck data and switch up/down according to the process
            -- that executed the actual checks
            peer.down = op.down
            update_upstream_status(ctx, is_backup, i-1, not (not peer.down))
        end
    end
    return upeers
end

-- handles the vertical update; check and handle incoming signals from the
-- upstream manager, executing healthcheck and storing updated data for other
-- workers, and if necessary flagging changes in availability to loadbalancer
local function vertical_update(ctx)
    local dict = ctx.dict
    local upstream = ctx.upstream
    local peers = read_healthcheck_data(dict, upstream)
    if not peers then 
        return errlog("vertical update failed")
    end
    
    -- step 1; handle any upstream changes
    local upstream_version = get_upstream_version(dict, upstream)
    if not upstream_version then return end
    
    if peers.upstream_version ~= upstream_version then
        -- version was updated, so we must update our peer lists
        local upeers
        upeers = update_upstream(ctx, peers.primary_peers, false)
        if upeers then
            peers.primary_peers = upeers
        end
        upeers = update_upstream(ctx, peers.backup_peers, true)
        if upeers then
            peers.backup_peers = upeers
        end
        peers.upstream_version = upstream_version
        ctx.availability_update = true
    end
    
    -- step 2; execute the healthchecks
    check_peers(ctx, peers.primary_peers, false)
    check_peers(ctx, peers.backup_peers, true)
-- TODO: check defaults, timer is 2 secs, timeout = 1 sec
-- we do 2 updates; primary and backup, if each has a timeout, then the lock
-- will be released before we are done.
-- note: if number of peers in either list is larger than concurrency setting,
-- it might take even longer
    
    -- step 3; store healthcheck data and flag update if required
    write_healthcheck_data(ctx, peers)
    
    if ctx.availability_update then        
        local version
        version = new_healthcheck_data_version(dict, upstream)
        if version then ctx.version = version end
        debug("publishing peers version ", version)
        
--[[        -- step 4; flag availability update to loadbalancer
        version = new_available_peers_version(dict, upstream)
        debug("published new peer availability version ", version) --]]
        ctx.availability_update = nil
    end
end

-- executes a horizontal synchronization between workerprocesses.
-- No updating, just applying the changes
local function horizontal_update(ctx)
    local dict = ctx.dict
    local upstream = ctx.upstream
    local hc_version = get_healthcheck_data_version(dict, upstream)
  
    if hc_version == ctx.version then return end

    local peers = read_healthcheck_data(dict, upstream)
    if not peers then 
        return errlog("horizontal update failed")
    end
    debug("New peer data was flagged, version ",
          tostring(peers.version), 
          " (ours; "..tostring(ctx.version)..")")
    
    -- we fetch the latest peers from the upstream_manager, because
    -- the peer indices might have changed. It reduces the possibility
    -- of accidentally enabling/disabling the wrong peer, but does not
    -- eliminate it. In case it is wrong, the next iteration over the updated
    -- versions will correct it
    
    -- NOTE: horizontal is readonly, so despite fetching the latest upstream
    -- data, we do not update the healthcheck data. We only apply changes
    -- made by previous healthchecks by other workerprocesses.
    
    local ppeers, bpeers, err, reverse
    ppeers, err = ctx.get_primary_peers(upstream)
    reverse = {}
    for _, peer in ipairs(peers.primary_peers) do
        reverse[peer.name] = peer
    end
    for i, peer in ipairs(ppeers) do
        local op = reverse[peer.name]
        if op and (op.down ~= peer.down) then
            -- upstream status is different than the last healthcheck, so go
            -- update the upstream status
            debug("Peer "..peer.name.." was changed to "..
                  (op.down and "DOWN" or "UP").. 
                  " based on previous healthcheck")
            update_upstream_status(ctx, false, i, not (not op.down))
        end
    end
    
    bpeers, err = ctx.get_backup_peers(upstream)
    reverse = {}
    for _, peer in ipairs(peers.backup_peers) do
        reverse[peer.name] = peer
    end
    for i, peer in ipairs(ppeers) do
        local op = reverse[peer.name]
        if op and (op.down ~= peer.down) then
            -- upstream status is different than the last healthcheck, so go
            -- update the upstream status
            debug("Peer "..peer.name.." was changed to "..
                  (op.down and "DOWN" or "UP").. 
                  " based on previous healthcheck")
            update_upstream_status(ctx, true, i, not (not op.down))
        end
    end
    
    ctx.version = peers.version
end

local function do_check(ctx)
    debug("run a check cycle")

    -- Each workerprocess should do a horizontal update;
    --  1 - check for updated healthcheck data
    --  2 - if changed, apply them within its workerprocess
    -- considering multiple workerprocesses, the one that gets the lock will
    -- be responsible for the vertical update;
    --  1 - checking for upstream changes (peers added/removed) and handle them
    --  2 - executing the healthcheck on all known peers
    --  3 - in case of any changes, store the data and flag an update

    horizontal_update(ctx)    
    if get_timer_lock(ctx) then
        vertical_update(ctx)
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
        return errlog("failed to run healthcheck cycle: ", err)
    end

    ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            return errlog("failed to create timer: ", err)
        end
        return
    end
end

local function load_upstream_manager(upstream_manager)
    upstream_manager = upstream_manager or "ngx.upstream"

    assert(type(upstream_manager) == "string" or
           type(upstream_manager == "table"),
           "the upstream_manager option must be a string (module name) or " ..
           "table (actual module)")

    if type(upstream_manager) == "string" then
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

-- splits peer name into hostname and port
local function preprocess_peers(peers, ...)
    if not peers then return peers, ... end
    
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

function _M.spawn_checker(opts)
    local ok, err
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

    local get_primary_peers = upstream_manager.get_primary_peers
    local get_backup_peers = upstream_manager.get_backup_peers

    local ctx = {
        upstream = u,
        http_req = http_req,
        timeout = timeout,
        interval = interval,
        dict = dict,
        fall = fall,
        rise = rise,
        statuses = statuses,
        concurrency = concur,
        set_peer_down = upstream_manager.set_peer_down,
        get_primary_peers = function(...) 
              return preprocess_peers(get_primary_peers(...)) 
            end,
        get_backup_peers = function(...) 
              return preprocess_peers(get_backup_peers(...))
            end,
        version = 0,
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
-- @param opts table, with `shm` Name of the shm object to use, and `upstream`
-- Name of the upstream block to use
-- @return `true` on success, `nil+error`  otherwise
function _M.signal_upstream_change(opts)
    
    local dict = shared[opts.shm or ""]
    if not dict then
        return nil, "shm \"" .. tostring(opts.shm) .. "\" not found"
    end

    return new_upstream_version(dict, opts.upstream or "")
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

-- opts supports;
--  opts.upstream_manager
--  opts.upstream
function _M.status_page(opts)
    -- generate an HTML page
    opts = opts or {}
    local upstream_manager = load_upstream_manager(opts.upstream_manager)
    local us, err
    if opts.upstream then
        us = { opts.upstream }
    else
        us, err = upstream_manager.get_upstreams()
        if not us then
            return "failed to get upstream names: " .. err
        end
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
