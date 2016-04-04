local stream_sock = ngx.socket.tcp
local log = ngx.log
local ERR = ngx.ERR
local INFO = ngx.INFO
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local sub = string.sub
local re_find = ngx.re.find
local new_timer = ngx.timer.at
local shared = ngx.shared
local debug_mode = ngx.config.debug
local concat = table.concat
local insert = table.insert
local tonumber = tonumber
local tostring = tostring
local ipairs = ipairs
local ceil = math.ceil
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local pcall = pcall
local cjson = require("cjson.safe").new()

-- upstream keys (both get upstream name appended)
local KEY_LOCK = "resty-healthcheck:l:" -- lock
local KEY_DATA = "resty-healthcheck:d:" -- serialized healthcheck json data

-- will contain all generated checkers by upstream name
local checkers = {}

local events = require("resty.worker.events")


local _M = {
    _VERSION = '0.03',  --TODO: what version is minimum required?
    
    events = events.event_list(
        "resty-upstream-healthcheck", -- event source for own events
        "peer_status",                -- event for a changed peer down-status
        "peer_added",                 -- event for an added upstream peer
        "peer_removed"                -- event for a removed upstream peer
    )
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

-- Fetches the list of peers and their healthcheck data from the shm.
-- @param upstream Name of the upstream whose data to fetch
-- @return table with peer data, empty if not found.
local function read_healthcheck_data(dict, upstream)
    local data, err = dict:get(KEY_DATA..upstream)

    if not data then
        if err then
            return errlog("failed fetching data from shm; ", err)
        end
        -- no error, so there was nothing in the shm
        debug("no healthcheck data found")
        return {}
    end

    return cjson.decode(data)
end

-- Writes the list of peers and their healthcheck data to the shm.
-- @param upstream Name of the upstream whose data to write
-- @param peers table holding the data to write
-- @return true on success, nil+error on failure
local function write_healthcheck_data(checker, peers)
    local data, err, success
    local dict = checker.dict
    local u = checker.upstream
    
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

local function raise_event(event, data)
    debug(event,", ", data.name)
    return events.post(_M.events._source, event, data)
end

-- registers a single healthcheck failure for a peer, marks peer as
-- down if the threshold of failures is exceeded
local function peer_fail(checker, peer)
    debug("peer ", peer.name, " was checked to be not ok")

    peer.fails = math.min((peer.fails or 0) + 1, checker.fall)
    peer.successes = nil
    
    if not peer.down and peer.fails >= checker.fall then
        warn("peer ", peer.name, " is turned down after ", peer.fails,
                " failure(s)")
        peer.down = true

        raise_event(_M.events.peer_status, peer)
    end
end

-- registers a single healthcheck success for a peer, marks peer as
-- up if the threshold of successes is exceeded
local function peer_ok(checker, peer)
    debug("peer ", peer.name, " was checked to be ok")

    peer.successes = math.min((peer.successes or 0) + 1, checker.rise)
    peer.fails = nil

    if peer.down and peer.successes >= checker.rise then
        warn("peer ", peer.name, " is turned up after ", peer.successes,
                " success(es)")
        peer.down = nil

        raise_event(_M.events.peer_status, peer)
    end
end

-- check a single peer, and calls into the failure/success handlers
local function check_peer(checker, peer)
    local ok, err, sock
    local name = peer.name
    local statuses = checker.statuses
    local req = checker.http_req

    sock, err = stream_sock()
    if not sock then
        errlog("failed to create stream socket: ", err)
        return
    end

    sock:settimeout(checker.timeout)

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
        peer_fail(checker, peer)
    else
        local bytes, err = sock:send(req)
        if not bytes then
            if not peer.down then
                errlog("failed to send request to ", name, ": ", err)
            end
            peer_fail(checker, peer)
        else
            local status_line, err = sock:receive()
            if not status_line then
                if not peer.down then
                    errlog("failed to receive status line from ", name,
                           ": ", err)
                end
                peer_fail(checker, peer)
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
                        peer_fail(checker, peer)
                    else
                        local status = tonumber(sub(status_line, from, to))
                        if not statuses[status] then
                            if not peer.down then
                                errlog("bad status code from ",
                                       name, ": ", status)
                            end
                            peer_fail(checker, peer)
                        else
                            peer_ok(checker, peer)
                        end
                    end
                else
                    peer_ok(checker, peer)
                end
            end
            sock:close()
        end
    end
end

-- checks all peers in a list (plain)
local function check_peer_range(checker, peers)
    for _, peer in pairs(peers) do
        check_peer(checker, peer)
    end
end

-- checks all peers in a table (applying concurrency)
local function check_peers(checker, peers, count)
--TODO: refactor below if-thens, all do pretty much the same
    local concur = checker.concurrency
    if concur <= 1 then
        check_peer_range(checker, peers)
    else
        local threads
        local nthr

        if count <= concur then
            nthr = count - 1
            threads = new_tab(nthr, 0)
            local mine -- save this one for myself in this thread
            for _, peer in pairs(peers) do
                if mine then
                    if debug_mode then
                        debug("spawning thread ", #threads + 1)
                    end
                    insert(threads, spawn(check_peer, checker, peer))
                else
                    mine = peer
                end
            end
            -- use the current "light thread" to run the last task
            if debug_mode then
                debug("mainthread checking peer ", count)
            end
            check_peer(checker, mine)

        else
            local group_size = ceil(count / concur)
            nthr = ceil(count / group_size) - 1

            threads = new_tab(nthr, 0)
            local group = {}
            local gcount = 1
            for _, peer in pairs(peers) do
                insert(group, peer)
                --debug("group ",gcount, " peer ", peer.id)
                if #group == group_size and gcount <= nthr then
                    if debug_mode then
                        debug("spawn thread ",gcount," checking ", #group,
                              " peers")
                    end
                    insert(threads, spawn(check_peer_range, checker, group))
                    
                    -- reset group
                    group = {}
                    gcount = gcount + 1
                end
            end
            -- the last group is checked on this light thread
            if debug_mode then
                debug("mainthread checking ",#group," peers")
            end
            check_peer_range(checker, group)
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

-- handles the upstream updates for a list of peers
-- @return updated peers table, table of removed peers, and
-- table of new peers, and count. Otherwise nil+error
local function update_upstream(checker, peers)
    
    local new_peers = {}
    local upeers, err = checker:get_peers()
    if not upeers then
        return errlog("failed to get peers: ", err)
    end
    
    local count = 0
    for id, peer in pairs(upeers) do
        count = count + 1
        local op = peers[id]
        if not op then
            new_peers[peer.id] = peer
        end
        -- when we don't know the peer, copy the down status from the
        -- upstream_manager to prevent a peer being added as 'down' to
        -- be switched to 'up' immediately
        op = op or { down = peer.down }
        peer.fails = op.fails
        peer.successes = op.successes
        if peer.down ~= op.down then
            -- healthcheck data overrules the data from upstream_manager
            -- this to make sure that other workerprocesses follow the
            -- healthcheck data and switch up/down according to the process
            -- that executed the actual checks
            peer.down = op.down
            raise_event(_M.events.peer_status, peer)
        end
        -- remove from old list, whatever remains in that list was 
        -- apparently removed
        peers[id] = nil 
    end
    return upeers, peers, new_peers, count
end


-- loads the upstream manager.
-- @param upstream_manager, if a string, module name to load, if a table, 
-- the module table itself. If not provided, the default upstream manager
-- will be used.
local function load_upstream_manager(upstream_manager)
    upstream_manager = upstream_manager or 
                       "resty.upstream.healthcheck.hcu_wrapper"

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
    for _,fname in ipairs({"get_peers", "get_upstreams"}) do
        assert(type(upstream_manager[fname]) == "function",
               'expected the "upstream_manager" to have a "'..fname..
               '" function')
    end

    return upstream_manager
end

local function new_checker(checker)

    function checker:get_timer_lock()
        local dict = self.dict
        local key = KEY_LOCK..self.upstream
        -- the lock is held for the whole interval to prevent multiple
        -- worker processes from sending the test request simultaneously.
        -- here we substract the lock expiration time by 1ms to prevent
        -- a race condition with the next timer event.
        local ok, err = dict:add(key, true, self.interval-0.001)
        if not ok then
            if err == "exists" then
                return nil
            end
            errlog('failed to add key "', key, '": ', err)
            return nil
        end
        return true
    end

    -- handles the update; check and handle incoming signals from the
    -- upstream manager, executing healthcheck and storing updated data for other
    -- workers, and if necessary flagging changes in availability to loadbalancer
    function checker:update()
        local dict = self.dict
        local upstream = self.upstream
        local peers = read_healthcheck_data(dict, upstream)
        if not peers then 
            return errlog("update failed")
        end

        -- step 1; handle any upstream changes
        local upeers, removed, added, count = update_upstream(self, peers)
        if upeers then
            peers = upeers
            if next(removed) or next(added) then
                -- write healthcheck data before firing events so event handlers
                -- fetching that data based on an event can find it
                write_healthcheck_data(self, peers)
                for _, peer in pairs(added) do
                    raise_event(_M.events.peer_added, peer)
                end
                for _, peer in pairs(removed) do
                    raise_event(_M.events.peer_removed, peer)
                end
            end
        end

        -- step 2; execute the healthchecks
        if count > 0 then
            check_peers(self, peers, count)
        else
            debug("no peers to check")
        end

    -- TODO: check defaults, timer is 2 secs, timeout = 1 sec
    -- if number of peers is larger than concurrency setting,
    -- it might take even longer than timer, and second run starts in parallel
        
        -- step 3; store healthcheck data and flag update if required
        write_healthcheck_data(self, peers)

    end

    function checker:do_check()
        debug("run a check cycle")
        if self:get_timer_lock() then
            self:update()
        end
    end

    -- timer callback, so this one has no method signature
    function checker.check(premature, self)
        local ok, err
        if premature then
            return
        end

        ok, err = pcall(self.do_check, self)
        if not ok then
            return errlog("failed to run healthcheck cycle: ", err)
        end

        ok, err = new_timer(self.interval, self.check, self)
        if not ok then
            if err ~= "process exiting" then
                return errlog("failed to create timer: ", err)
            end
            return
        end
    end

    -- returns peer status. Table indexed by peer id.
    function checker:status()
        -- TODO: should we keep a local copy of the data? Then we would have
        -- to make a copy to return. Then current approach of decoding json 
        -- from shm is probably faster...
        return read_healthcheck_data(self.dict, self.upstream)
    end
    
    function checker:start()
        local ok, err
        
        if checkers[self.upstream] then
            return nil, "Checker for upstream "..tostring(self.upstream)..
                   " already exists"
        end
        
        checkers[self.upstream] = self
        
        ok, err = new_timer(0, self.check, self)
        if not ok then
            return nil, "failed to create timer: " .. err
        end

        return self
    end
    
    return checker
end


function _M.spawn_checker(opts)
    assert(events.configured(), "Please configure the 'lua-resty-worker-events' "..
          "module before using the healthchecker")

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

    local concurrency = opts.concurrency
    if not concurrency then
        concurrency = 1
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
    local set_peer_down = upstream_manager.set_peer_down
    local get_peers = upstream_manager.get_peers

    local checker = {
        upstream = u,
        http_req = http_req,
        timeout = timeout,
        interval = interval,
        dict = dict,
        fall = fall,
        rise = rise,
        statuses = statuses,
        concurrency = concurrency,

        -- create upstream manager wrappers
        set_peer_down = function(self, ...)
                return set_peer_down(self.upstream, ...)
            end,
        get_peers = function(self, ...) 
                return get_peers(self.upstream, ...) 
            end,

--TODO how to update options, like interval, etc.??  -> event
    }

    return new_checker(checker):start()
end

------------------------------------
-- Implement the upstream api
------------------------------------
function _M.get_upstreams()
  local upstreams = {}
  for name, checker in pairs(checkers) do
    upstreams[#upstreams + 1] = name
  end
  return upstreams
end

function _M.get_peers(upstream)
  local checker = checkers[upstream]
  if not checker then 
    return nil, "No healthchecker for upstream '"..tostring(upstream).."'"
  end
  return checker:status()
end

------------------------------------
-- Provide status pages
------------------------------------
local function gen_peers_status_info(peers, bits, idx)
    local p = {}
    for _, peer in pairs(peers) do insert(p, peer) end
    table.sort(p, function(a,b) return a.name < b.name end)
    
    for _, peer in pairs(p) do
        bits[idx] = "    "
        bits[idx + 1] = peer.id
        bits[idx + 2] = " "
        bits[idx + 3] = peer.name
        if peer.down then
            bits[idx + 4] = " DOWN\n"
        else
            bits[idx + 4] = " up\n"
        end
        idx = idx + 5
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
        bits[idx + 1] = u .. ((checkers[u] and "") or " (NO checkers)")
        bits[idx + 2] = "\n"
        idx = idx + 3

        local peers, err = upstream_manager.get_peers(u)
        if not peers then
            return "failed to get peers in upstream " .. u .. ": "
                   .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)

    end
    return concat(bits)
end

return _M
