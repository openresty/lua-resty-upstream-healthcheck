# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 2);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/../lua-resty-lock/?.lua;$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
_EOC_

#no_diff();
no_long_string();
run_tests();

__DATA__

=== TEST 1: prometheus format status page (no peers)
--- http_config eval
"$::HttpConfig"
. q{
lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.config.debug = 1
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "not_found",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
	      valid_statuses = {200}
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
        return
    end
';
}
--- config
    location = /t {
        access_log off;
        content_by_lua '
            ngx.sleep(0.52)
            local hc = require "resty.upstream.healthcheck"
            local st , err = hc.prometheus_status_page()
            if not st then
                ngx.say(err)
                return
            end
            ngx.print(st)
        ';
    }
--- request
GET /t

--- response_body
# HELP nginx_upstream_status_info The running status of nginx upstream
# TYPE nginx_upstream_status_info gauge
