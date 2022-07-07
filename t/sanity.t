# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6 + 9);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/../lua-resty-lock/?.lua;$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
_EOC_

#no_diff();
no_long_string();
run_tests();

__DATA__

=== TEST 1: health check (good case), status ignored by default
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
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
        127.0.0.1:12354 up
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[error]
[alert]
[warn]
was checked to be not ok
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|publishing peers version \d+|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){3,5}$/
--- timeout: 6



=== TEST 2: health check (bad case), no listening port in the backup peer
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
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
        127.0.0.1:12354 up
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 DOWN
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: failed to connect to 127.0.0.1:12356: connection refused
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|warn\(\): .*(?=,)|publishing peers version \d+|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12356 is turned down after 2 failure\(s\)
publishing peers version 1
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be not ok
){2,4}$/
--- timeout: 6



=== TEST 3: health check (bad case), no listening port in a primary peer
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12356;
    location = /status {
        return 404;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
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
        127.0.0.1:12354 up
        127.0.0.1:12355 DOWN
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12354

--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: failed to connect to 127.0.0.1:12355: connection refused
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|warn\(\): .*(?=,)|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned down after 2 failure\(s\)
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){2,4}$/
--- timeout: 6



=== TEST 4: health check (bad case), bad status
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
        valid_statuses = {200, 503},
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
        127.0.0.1:12354 up
        127.0.0.1:12355 DOWN
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12354
--- no_error_log
[alert]
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|warn\(\): .*(?=,)|healthcheck: bad status code from .*(?=,)|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: bad status code from 127\.0\.0\.1:12355: 404
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: bad status code from 127\.0\.0\.1:12355: 404
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned down after 2 failure\(s\)
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){1,4}$/
--- timeout: 6



=== TEST 5: health check (bad case), timed out
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        echo_sleep 0.5;
        echo ok;
    }
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        timeout = 100,  -- 100ms
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
        127.0.0.1:12354 DOWN
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12355
upstream addr: 127.0.0.1:12355
--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: failed to receive status line from 127.0.0.1:12354: timeout
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|warn\(\): .*(?=,)|healthcheck: bad status code from .*(?=,)|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12354 is turned down after 2 failure\(s\)
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){0,2}$/



=== TEST 6: health check (bad case), bad status, and then rise again
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    location = /status {
        content_by_lua '
            local cnt = package.loaded.cnt
            if not cnt then
                cnt = 0
            end
            cnt = cnt + 1
            package.loaded.cnt = cnt
            if cnt >= 3 then
                return ngx.exit(200)
            end
            return ngx.exit(403)
        ';
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 1,
        rise = 2,
        valid_statuses = {200, 503},
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
        127.0.0.1:12354 up
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[alert]
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|warn\(\): .*(?=,)|healthcheck: bad status code from .*(?=,)|publishing peers version \d+|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: bad status code from 127\.0\.0\.1:12355: 403
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned down after 1 failure\(s\)
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
publishing peers version 1
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned up after 2 success\(es\)
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
publishing peers version 2
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){1,3}$/
--- timeout: 6



=== TEST 7: peers version upgrade (make up peers down)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    local dict = ngx.shared.healthcheck
    dict:flush_all()
    assert(dict:set("v:foo.com", 1))
    assert(dict:set("d:foo.com:b0", true))
    assert(dict:set("d:foo.com:p1", true))
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
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
        127.0.0.1:12354 up
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[error]
[alert]
was checked to be not ok
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|publishing peers version \d+|warn\(\): .*(?=,)|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^upgrading peers version to 1
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned up after 2 success\(es\)
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12356 is turned up after 2 success\(es\)
publishing peers version 2
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){2,4}$/



=== TEST 8: peers version upgrade (make down peers up)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354 down;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    local dict = ngx.shared.healthcheck
    dict:flush_all()
    assert(dict:set("v:foo.com", 1))
    -- assert(dict:set("d:foo.com:b0", true))
    -- assert(dict:set("d:foo.com:p1", true))
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
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
        127.0.0.1:12354 DOWN
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12355
upstream addr: 127.0.0.1:12355

--- error_log
failed to connect to 127.0.0.1:12354: connection refused
--- no_error_log
[alert]
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|publishing peers version \d+|warn\(\): .*(?=,)|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^upgrading peers version to 1
healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12354 is turned down after 2 failure\(s\)
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
publishing peers version 2
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be ok
){3,5}$/
--- timeout: 6



=== TEST 9: concurrency == 2 (odd number of peers)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356;
    server 127.0.0.1:12357;
    server 127.0.0.1:12358;
    server 127.0.0.1:12359 backup;
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
        concurrency = 2,
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
            ngx.say("ok")
        ';
    }
--- request
GET /t

--- response_body
ok
--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: peer 127.0.0.1:12354 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12355 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12356 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12357 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12358 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12359 is turned down after 2 failure(s)
--- grep_error_log eval: qr/spawn a thread checking .* peer.*|check .*? peer.*/
--- grep_error_log_out eval
qr/^(?:spawn a thread checking primary peers 0 to 2
check primary peers 3 to 4
check backup peer 0
){4,6}$/



=== TEST 10: concurrency == 3 (odd number of peers)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356;
    server 127.0.0.1:12359 backup;
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
        concurrency = 3,
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
            ngx.say("ok")
        ';
    }
--- request
GET /t

--- response_body
ok
--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: peer 127.0.0.1:12354 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12355 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12356 is turned down after 2 failure(s)
healthcheck: peer 127.0.0.1:12359 is turned down after 2 failure(s)
--- grep_error_log eval: qr/spawn a thread checking .* peer.*|check .*? peer.*/
--- grep_error_log_out eval
qr/^(?:spawn a thread checking primary peer 0
spawn a thread checking primary peer 1
check primary peer 2
check backup peer 0
){4,6}$/



=== TEST 11: health check (good case), status ignored by default
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:7983;
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 1,
        valid_statuses = {200},
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
            ngx.sleep(0.12)

            local hc = require "resty.upstream.healthcheck"
            ngx.print(hc.status_page())
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

--- tcp_listen: 7983
--- tcp_query eval: "GET /status HTTP/1.0\r\nHost: localhost\r\n\r\n"
--- tcp_reply
<html>
--- response_body
Upstream foo.com
    Primary Peers
        127.0.0.1:7983 DOWN
    Backup Peers

--- no_error_log
[alert]
bad argument #2 to 'sub' (number expected, got nil)



=== TEST 12: health check (bad case), bad status, multiple upstreams
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

upstream bar.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12357;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    listen 12357;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 2m;
init_worker_by_lua_block {
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    for i, upstream in ipairs{'foo.com', 'bar.com'} do
        local ok, err = hc.spawn_checker{
            shm = "healthcheck",
            upstream = upstream,
            type = "http",
            http_req = "GET /status HTTP/1.0\r\nHost: localhost\r\n\r\n",
            interval = 50,  -- ms
            fall = 1,
            valid_statuses = {200, 503},
        }
        if not ok then
            ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
            return
        end
    end
}

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
        127.0.0.1:12354 up
        127.0.0.1:12355 DOWN
    Backup Peers
        127.0.0.1:12356 up

Upstream bar.com
    Primary Peers
        127.0.0.1:12354 up
        127.0.0.1:12355 DOWN
        127.0.0.1:12357 DOWN
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12354
--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: bad status code from 127.0.0.1:12355
healthcheck: bad status code from 127.0.0.1:12357
--- timeout: 6



=== TEST 13: crashes in init_by_lua_worker*
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen 12355;
    location = /status {
        return 404;
    }
}

server {
    listen 12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua_block {
    error("bad thing!")
}
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
Upstream foo.com (NO checkers)
    Primary Peers
        127.0.0.1:12354 up
        127.0.0.1:12355 up
    Backup Peers
        127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355
--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
bad thing!
--- timeout: 4



=== TEST 14: health check with ipv6 backend (good case), status ignored by default
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server [::1]:12355;
    server [0:0::1]:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
    }
}

server {
    listen [::1]:12355;
    location = /status {
        return 404;
    }
}

server {
    listen [0:0::1]:12356;
    location = /status {
        return 503;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua_block {
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\r\nHost: localhost\r\n\r\n",
        interval = 100,  -- 100ms
        fall = 2,
    }
    if not ok then
        ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
        return
    end
}
}
--- config
    location = /t {
        access_log off;
        content_by_lua_block {
            ngx.sleep(0.52)

            local hc = require "resty.upstream.healthcheck"
            ngx.print(hc.status_page())

            for i = 1, 2 do
                local res = ngx.location.capture("/proxy")
                ngx.say("upstream addr: ", res.header["X-Foo"])
            end
        }
    }

    location = /proxy {
        proxy_pass http://foo.com/;
        header_filter_by_lua_block {
            ngx.header["X-Foo"] = ngx.var.upstream_addr;
        }
    }
--- request
GET /t

--- response_body
Upstream foo.com
    Primary Peers
        127.0.0.1:12354 up
        [::1]:12355 up
    Backup Peers
        [::1]:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: [::1]:12355

--- no_error_log
[error]
[alert]
[warn]
was checked to be not ok
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|publishing peers version \d+|upgrading peers version to \d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer \[::1\]:12355 was checked to be ok
healthcheck: peer \[::1\]:12356 was checked to be ok
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer \[::1\]:12355 was checked to be ok
healthcheck: peer \[::1\]:12356 was checked to be ok
){3,7}$/
--- wait: 0.2
--- timeout: 6
--- skip_eval: 8: system("ping6 -c 1 ::1 >/dev/null 2>&1") ne 0



=== TEST 15: peers > concurrency
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356;
    server 127.0.0.1:12357;
    server 127.0.0.1:12358;
    server 127.0.0.1:12359 backup;
}

server {
    listen 12354;

    location /status {
        content_by_lua_block {
            ngx.sleep(0.2)
        }
    }
}

lua_shared_dict healthcheck 1m;
}
--- config
    location = /t {
        content_by_lua_block {
            local hc = require "resty.upstream.healthcheck"

            local ok, err = hc.spawn_checker{
                shm = "healthcheck",
                upstream = "foo.com",
                type = "http",
                http_req = "GET /status HTTP/1.0\r\nHost: localhost\r\n\r\n",
                timeout = 100,
                fall = 1,
                concurrency = 2,
                no_timer = true,
            }
            if not ok then
                ngx.log(ngx.ERR, "failed to spawn health checker: ", err)
                return
            end

            ngx.print(hc.status_page())
        }
    }
--- request
GET /t
--- response_body_like
Upstream foo.com
    Primary Peers
        127.0.0.1:12354 DOWN
        127.0.0.1:12355 \S+
        127.0.0.1:12356 \S+
        127.0.0.1:12357 \S+
        127.0.0.1:12358 \S+
    Backup Peers
        127.0.0.1:12359 \S+
--- no_error_log
[alert]
[emerg]
failed to run healthcheck cycle
--- wait: 0.3
--- grep_error_log eval: qr/healthcheck: .*? was checked .*|healthcheck: failed to receive status line from .*?:\d+/
--- grep_error_log_out eval
qr/^healthcheck: peer 127\.0\.0\.1:12357 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12358 was checked to be not ok
healthcheck: failed to receive status line from 127\.0\.0\.1:12354
healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12359 was checked to be not ok
$/

=== TEST 16: prometheus format status page (everything is healthy)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
}

server {
    listen 12354;
    location = /status {
        return 200;
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
            st , err = hc.prometheus_status_page()
            if not st then
                ngx.say(err)
                return
            end
            ngx.say(st)
        ';
    }
--- request
GET /t

--- response_body
# HELP nginx_upstream_status_info The running staus of nginx upstream
# TYPE nginx_upstream_status_info gauge
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12354",status="UP",role="PRIMARY"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12355",status="UP",role="PRIMARY"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12356",status="UP",role="BACKUP"} 1

=== TEST 17: prometheus format status page (everything is down)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356 backup;
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
        return 500;
    }
}

server {
    listen 12356;
    location = /status {
        return 500;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
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
            st , err = hc.prometheus_status_page()
            if not st then
                ngx.say(err)
                return
            end
            ngx.say(st)
        ';
    }
--- request
GET /t

--- response_body
# HELP nginx_upstream_status_info The running staus of nginx upstream
# TYPE nginx_upstream_status_info gauge
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12354",status="DOWN",role="PRIMARY"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12355",status="DOWN",role="PRIMARY"} 1
nginx_upstream_status_info{name="foo.com",endpoint="127.0.0.1:12356",status="DOWN",role="BACKUP"} 1

=== TEST 18: prometheus format status page (no peers)
--- http_config eval
"$::HttpConfig"
. q{
lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "no_found",
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
            st , err = hc.prometheus_status_page()
            if not st then
                ngx.say(err)
                return
            end
            ngx.say(st)
        ';
    }
--- request
GET /t

--- response_body
# HELP nginx_upstream_status_info The running staus of nginx upstream
# TYPE nginx_upstream_status_info gauge
nginx_upstream_status_info{name="not_found",endpoint="",status="UNKNOWN",role=""} 1
