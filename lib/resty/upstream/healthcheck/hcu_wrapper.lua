-- Provides a wrapper for the lua-upstream-nginx-module
-- to match the interface for the upstream healthchecker.

local hc = require "resty.upstream.healthcheck"
local ev = require "resty.worker.events"

local upstream = require "ngx.upstream"
local spd = upstream.set_peer_down
local re_find = ngx.re.find

local debug_mode = true --ngx.config.debug
local log = ngx.log
--local ERR = ngx.ERR
--local INFO = ngx.INFO
--local WARN = ngx.WARN
local DEBUG = ngx.DEBUG

local PRIMARY = "P:"
local BACKUP = "B:"

local function debug(...)
    -- print("debug mode: ", debug_mode)
    if debug_mode then
        log(DEBUG, "healthcheck: ", ...)
    end
end

local status_handler = function(peer)
    local peer_id = peer.id
    local is_backup = (peer_id:sub(1,2) == BACKUP)
    peer_id = peer_id:sub(3,-1)
    debug("setting ", is_backup and "backup" or "primary", " peer ",
          peer.name," ", peer.down and "down" or "up")
    spd(peer.upstream, is_backup, peer_id, peer.down)
end

ev.register(status_handler, hc.events._source, hc.events.peer_status)

local _M = {

    -- return a peer table, indexed by id, containing values;
    --    id, name, host, port (number), down (boolean)
    -- "name" is being split in host and port
    get_peers = function(upstream_name)
        local peers = {}
        local get_peers = upstream.get_primary_peers
        local prefix = PRIMARY
        
        for n = 1,2 do
            if n == 2 then 
                get_peers = upstream.get_backup_peers
                prefix = BACKUP
            end
            
            for _, data in pairs(get_peers(upstream_name) or {}) do
                local peer = {
                    name = data.name,
                    down = data.down,
                    id = prefix..data.id,
                    host = data.host,
                    port = data.port,
                    upstream = upstream_name,
                }
                local from, to = re_find(peer.name, [[^(.*):\d+$]], "jo", nil, 1)
                if from then
                    peer.host = peer.name:sub(1, to)
                    peer.port = tonumber(peer.name:sub(to + 2))
                end
                peers[peer.id] = peer
            end
        end
        return peers
    end,
    
    -- no modification required for get_upstream
    get_upstreams = upstream.get_upstreams,
}

return _M