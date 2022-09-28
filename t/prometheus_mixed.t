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

=== TEST 1: prometheus format status page (mixed down and up)
--- http_config eval
"$::HttpConfig"
. q{
upstream unknown.com {
    server 127.0.0.1:12366;
}

upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
    server 127.0.0.1:12357;
}

server {
    listen 12354;
    location = /status {
        return 500;
    }
}

server {
    listen 12355;
    location = /status {
        return 200;
    }
}

server {
    listen 12356;
    location = /status {
        return 500;
    }
}

server {
    listen 12357;
    location = /status {
        return 200;
    }
}

server {
    listen 12366;
    location = /status {
        return 200;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.config.debug = 1
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
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
            local st, err = hc.prometheus_status_page()
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
nginx_upstream_status_info{name="unknown.com",status="UP"} 0
nginx_upstream_status_info{name="unknown.com",status="DOWN"} 0
nginx_upstream_status_info{name="unknown.com",status="UNKNOWN"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12354",status="UP",role="PRIMARY"} 0
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12354",status="DOWN",role="PRIMARY"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12355",status="UP",role="PRIMARY"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12355",status="DOWN",role="PRIMARY"} 0
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12357",status="UP",role="PRIMARY"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12357",status="DOWN",role="PRIMARY"} 0
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12356",status="UP",role="BACKUP"} 0
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12356",status="DOWN",role="BACKUP"} 1
nginx_upstream_status_info{name="foo.com",status="UP"} 1
nginx_upstream_status_info{name="foo.com",status="DOWN"} 0
nginx_upstream_status_info{name="foo.com",status="UNKNOWN"} 0
