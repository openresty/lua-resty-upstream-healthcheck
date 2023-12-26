# vim:set ft= ts=4 sw=4 t fdm=marker:
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

=== TEST 1: https health check (good case), status ignored by default
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354 ssl;

    server_name localhost;

    ssl_certificate     ../../cert/localhost.crt;
    ssl_certificate_key ../../cert/localhost.key;

    location /status {
        return 200;
    }
}

server {
    listen 12355 ssl;

    server_name localhost;

    ssl_certificate     ../../cert/localhost.crt;
    ssl_certificate_key ../../cert/localhost.key;

    location /status {
        return 200;
    }
}

server {
    listen 12356 ssl;

    server_name localhost;

    ssl_certificate     ../../cert/localhost.crt;
    ssl_certificate_key ../../cert/localhost.key;

    location /status {
        return 200;
    }
}

lua_shared_dict healthcheck 1m;

init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "https",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        ssl_verify = false,
        host = "localhost",
        interval = 100,  -- 100ms
        fall = 2,
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
            ngx.print(hc.status_page())

            for i = 1, 2 do
                local res = ngx.location.capture("/proxy")
                ngx.say("upstream addr: ", res.header["X-Foo"])
            end
        ';
    }

    location = /proxy {
        proxy_pass http://foo.com/;
        header_filter_by_lua '
            ngx.header["X-Foo"] = ngx.var.upstream_addr;
        ';
    }

--- request
GET /t

--- response_body
Upstream foo.com
    Primary Peers
        127.0.0.1:12354 UP
        127.0.0.1:12355 UP
    Backup Peers
        127.0.0.1:12356 UP
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355
--- timeout: 6
