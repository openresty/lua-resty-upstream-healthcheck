local _M = {}
local shared_config = ngx.shared.healthcheck_config
local no_update_flag = 'config_no_update'
local config_flag = 'config_json_data'
local cjson = require("cjson")
cjson.encode_sparse_array(true)

function _M:refresh()
    local no_update,err = shared_config:get(no_update_flag .. ngx.worker.id())
    return not no_update
end

function _M:get()
    local v,err = shared_config:get(config_flag)

    if not v then
        ngx.log(ngx.ERR,err)
    end

    shared_config:set(no_update_flag,true)

    return cjson.decode(v)
end

function _M:set(conf)
    shared_config:set(config_flag,cjson.encode(conf))
    local worker_num = ngx.worker.count() - 1
    for i =0 , worker_num do
        shared_config:set(no_update_flag .. i , false)
    end
end

return _M
