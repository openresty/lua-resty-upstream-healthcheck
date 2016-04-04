# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6 + 3);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_socket_log_errors off;
    lua_package_path "$pwd/../lua-resty-lock/?.lua;$pwd/lib/?.lua;$pwd/t/lib/?.lua;;";
_EOC_

#no_diff();
no_long_string();
run_tests();

__DATA__

=== TEST 1: healthcheck, all peers report ok
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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 up
    B:0 127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[error]
[alert]
[warn]
was checked to be not ok
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*?:12354 was checked .*|healthcheck: peer_.*?:12354/
--- grep_error_log_out eval
qr/^healthcheck: peer_added, 127\.0\.0\.1:12354
healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
){3,5}$/
--- timeout: 6



=== TEST 2: healthcheck, one backup server faulty, connection refused, turned down
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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 up
    B:0 127.0.0.1:12356 DOWN
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: failed to connect to 127.0.0.1:12356: connection refused
--- grep_error_log eval: qr/healthcheck: .*?:12356 .*|warn\(\): .*(?=,)|healthcheck: peer_.*?:12356/
--- grep_error_log_out eval
qr/^healthcheck: peer_added, 127\.0\.0\.1:12356
healthcheck: peer 127\.0\.0\.1:12356 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12356 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12356 is turned down after 2 failure\(s\)
healthcheck: peer_status, 127\.0\.0\.1:12356
healthcheck: setting backup peer 127\.0\.0\.1:12356 down
(?:healthcheck: peer 127\.0\.0\.1:12356 was checked to be not ok
){2,4}$/
--- timeout: 6



=== TEST 3: healthcheck, one primary server faulty, connection refused, turned down
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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 DOWN
    B:0 127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12354

--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: failed to connect to 127.0.0.1:12355: connection refused
--- grep_error_log eval: qr/healthcheck: .*?:12355 .*|warn\(\): .*(?=,)|healthcheck: peer_.*?:12355/
--- grep_error_log_out eval
qr/^healthcheck: peer_added, 127.0.0.1:12355
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned down after 2 failure\(s\)
healthcheck: peer_status, 127.0.0.1:12355
healthcheck: setting primary peer 127\.0\.0\.1:12355 down
(?:healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
){2,4}$/
--- timeout: 6



=== TEST 4: healthcheck, one primary server faulty, bad status code, turned down
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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 DOWN
    B:0 127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12354

--- no_error_log
[alert]
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*?:12355 .*|warn\(\): .*(?=,)|healthcheck: bad status code from .*(?=,)|healthcheck: peer_.*?:12355/
--- grep_error_log_out eval
qr/^healthcheck: peer_added, 127.0.0.1:12355
healthcheck: bad status code from 127\.0\.0\.1:12355: 404
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: bad status code from 127\.0\.0\.1:12355: 404
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned down after 2 failure\(s\)
healthcheck: peer_status, 127.0.0.1:12355
healthcheck: setting primary peer 127\.0\.0\.1:12355 down
(?:healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
){1,4}$/
--- timeout: 6



=== TEST 5: healthcheck, one primary server faulty, timeout, turned down
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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 DOWN
    P:1 127.0.0.1:12355 up
    B:0 127.0.0.1:12356 up
upstream addr: 127.0.0.1:12355
upstream addr: 127.0.0.1:12355

--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
healthcheck: failed to receive status line from 127.0.0.1:12354: timeout
--- grep_error_log eval: qr/healthcheck: .*?:12354 .*|warn\(\): .*(?=,)|healthcheck: bad status code from .*(?=,)|healthcheck: peer_.*?:12354/
--- grep_error_log_out eval
qr/^healthcheck: peer_added, 127.0.0.1:12354
healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12354 is turned down after 2 failure\(s\)
healthcheck: peer_status, 127.0.0.1:12354
healthcheck: setting primary peer 127\.0\.0\.1:12354 down
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be not ok
){0,2}$/



=== TEST 6: healthcheck, one primary server faulty, bad status recovery, turned down and up again
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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 up
    B:0 127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12355

--- no_error_log
[alert]
failed to run healthcheck cycle
--- grep_error_log eval: qr/healthcheck: .*?:12355 .*|warn\(\): .*(?=,)|healthcheck: bad status code from .*(?=,)|healthcheck: peer_.*?:12355/
--- grep_error_log_out eval
qr/^healthcheck: peer_added, 127.0.0.1:12355
healthcheck: bad status code from 127\.0\.0\.1:12355: 403
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned down after 1 failure\(s\)
healthcheck: peer_status, 127.0.0.1:12355
healthcheck: setting primary peer 127\.0\.0\.1:12355 down
healthcheck: peer 127\.0\.0\.1:12355 was checked to be not ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
warn\(\): healthcheck: peer 127\.0\.0\.1:12355 is turned up after 2 success\(es\)
healthcheck: peer_status, 127.0.0.1:12355
healthcheck: setting primary peer 127\.0\.0\.1:12355 up
(?:healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
){1,4}$/
--- timeout: 6



=== TEST 7: healthcheck, check 5 peers, using 2 threads (3,2)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12356;
    server 127.0.0.1:12357;
    server 127.0.0.1:12359 backup;
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
healthcheck: peer 127.0.0.1:12359 is turned down after 2 failure(s)
--- grep_error_log eval: qr/spawn thread .*|mainthread checking .*/
--- grep_error_log_out eval
qr/^(?:spawn thread 1 checking 3 peers
mainthread checking 2 peers
){4,6}$/



=== TEST 8: healthcheck, check 3 peers, using 3 threads (1,1,1)
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12359 backup;
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
healthcheck: peer 127.0.0.1:12359 is turned down after 2 failure(s)
--- grep_error_log eval: qr/spawning thread .*|mainthread checking .*/
--- grep_error_log_out eval
qr/^(?:spawning thread 1
spawning thread 2
mainthread checking peer 3
){4,6}$/



=== TEST 9: healthcheck, upstream manager; adds a peer
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12358 backup;
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
    local hc = require "resty.upstream.healthcheck"
    local check_count = 0
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
        concurrency = 5,
        upstream_manager = {
            get_peers = function(upstream)
                local peers = {
                    ["P:0"] = {
                        id = "P:0",
                        name = "127.0.0.1:12354",
                        host = "127.0.0.1",
                        port = 12354,
                        down = true,
                        upstream = upstream,
                    },
                    ["P:1"] = {
                        id = "P:1",
                        name = "127.0.0.1:12355",
                        host = "127.0.0.1",
                        port = 12355,
                        down = true,
                        upstream = upstream,
                    }
                }
                check_count = check_count + 1
                if check_count > 2 then
                  peers["B:0"] = {
                          id = "B:0",
                          name = "127.0.0.1:12358",
                          host = "127.0.0.1",
                          port = 12358,
                          down = true,
                          upstream = upstream,
                      }
                end
                return peers
            end,
            get_upstreams = function()
                return { "foo.com" }
            end,
        }
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
--- grep_error_log eval: qr/spawning thread .*|peer_.*, 127.0.0.1:1235.*|mainthread checking .*/
--- grep_error_log_out eval
qr/^peer_added, 127\.0\.0\.1:1235[\d]
peer_added, 127\.0\.0\.1:1235[\d]
spawning thread 1
mainthread checking peer 2
spawning thread 1
mainthread checking peer 2
peer_added, 127\.0\.0\.1:12358
(?:spawning thread 1
spawning thread 2
mainthread checking peer 3
){3,5}$/


=== TEST 10: healthcheck, upstream manager; removes a peer
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
    server 127.0.0.1:12358 backup;
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
    local hc = require "resty.upstream.healthcheck"
    local check_count = 0
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
        concurrency = 5,
        upstream_manager = {
            get_peers = function(upstream)
                local peers = {
                    ["P:0"] = {
                        id = "P:0",
                        name = "127.0.0.1:12354",
                        host = "127.0.0.1",
                        port = 12354,
                        down = true,
                        upstream = upstream,
                    },
                    ["P:1"] = {
                        id = "P:1",
                        name = "127.0.0.1:12355",
                        host = "127.0.0.1",
                        port = 12355,
                        down = true,
                        upstream = upstream,
                    }
                }
                check_count = check_count + 1
                if check_count > 2 then
                  peers["P:1"] = nil
                end
                return peers
            end,
            get_upstreams = function()
                return { "foo.com" }
            end,
        }
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
--- grep_error_log eval: qr/spawning thread .*|peer_.*, 127.0.0.1:1235.*|mainthread checking .*/
--- grep_error_log_out eval
qr/^peer_added, 127\.0\.0\.1:1235[\d]
peer_added, 127\.0\.0\.1:1235[\d]
spawning thread 1
mainthread checking peer 2
spawning thread 1
mainthread checking peer 2
peer_removed, 127\.0\.0\.1:12355
(?:mainthread checking peer 1
){3,5}$/


=== TEST 11: healthcheck, upstream manager; removes all peers
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12355;
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
    local hc = require "resty.upstream.healthcheck"
    local check_count = 0
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "foo.com",
        type = "http",
        http_req = "GET /status HTTP/1.0\\\\r\\\\nHost: localhost\\\\r\\\\n\\\\r\\\\n",
        interval = 100,  -- 100ms
        fall = 2,
        concurrency = 5,
        upstream_manager = {
            get_peers = function(upstream)
                local peers = {
                    ["P:0"] = {
                        id = "P:0",
                        name = "127.0.0.1:12354",
                        host = "127.0.0.1",
                        port = 12354,
                        down = true,
                        upstream = upstream,
                    },
                    ["P:1"] = {
                        id = "P:1",
                        name = "127.0.0.1:12355",
                        host = "127.0.0.1",
                        port = 12355,
                        down = true,
                        upstream = upstream,
                    }
                }
                check_count = check_count + 1
                if check_count > 2 then
                  peers["P:1"] = nil
                end
                if check_count > 3 then
                  peers["P:0"] = nil
                end
                return peers
            end,
            get_upstreams = function()
                return { "foo.com" }
            end,
        }
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
--- grep_error_log eval: qr/no peers to check.*|spawning thread .*|peer_.*, 127.0.0.1:1235.*|mainthread checking .*/
--- grep_error_log_out eval
qr/^peer_added, 127\.0\.0\.1:1235[\d]
peer_added, 127\.0\.0\.1:1235[\d]
spawning thread 1
mainthread checking peer 2
spawning thread 1
mainthread checking peer 2
peer_removed, 127\.0\.0\.1:12355
mainthread checking peer 1
peer_removed, 127\.0\.0\.1:12354
(?:no peers to check
){2,4}$/



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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 DOWN
    B:0 127.0.0.1:12356 up

Upstream bar.com
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 DOWN
    B:0 127.0.0.1:12356 up
    P:2 127.0.0.1:12357 DOWN
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
    P:0 127.0.0.1:12354 up
    P:1 127.0.0.1:12355 up
    B:0 127.0.0.1:12356 up
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
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
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
    P:0 127.0.0.1:12354 up
    B:0 [0:0::1]:12356 up
    P:1 [::1]:12355 up
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
healthcheck: peer \[0:0::1\]:12356 was checked to be ok
(?:healthcheck: peer 127\.0\.0\.1:12354 was checked to be ok
healthcheck: peer \[::1\]:12355 was checked to be ok
healthcheck: peer \[0:0::1\]:12356 was checked to be ok
){3,7}$/
--- timeout: 6

=== TEST 15: healthcheck, test upstream api implementation
--- http_config eval
"$::HttpConfig"
. q{
upstream foo.com {
    server 127.0.0.1:12354;
    server 127.0.0.1:12356 backup;
    server 127.0.0.1:12357 backup;
}

upstream bar.com {
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

server {
    listen 12357;
    location = /status {
        return 200;
    }
}

lua_shared_dict healthcheck 1m;
init_worker_by_lua '
    ngx.shared.healthcheck:flush_all()
    local ev = require "resty.worker.events"
    ev.configure{
        shm = "healthcheck",
        interval = 0.01,
    }
    local hc = require "resty.upstream.healthcheck"
    local ok, err = hc.spawn_checker{
        shm = "healthcheck",
        upstream = "bar.com",
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
            for i,name in ipairs(hc.get_upstreams()) do
              ngx.print(tostring(i).." "..name.."\\n")
              local peers = hc.get_peers(name)
              local ppeer = function(peer)
                if not peer then return end
                ngx.print("    - "..peer.id.." "..peer.name.."\\n")
              end
              ppeer(peers["P:0"])
              ppeer(peers["B:0"])
              for id, peer in pairs(peers) do
                if id ~= "P:0" and id ~= "B:0" then
                  ppeer(peer)
                end
              end
            end
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
1 bar.com
    - P:0 127.0.0.1:12355
    - B:0 127.0.0.1:12356
Upstream foo.com (NO checkers)
    P:0 127.0.0.1:12354 up
    B:0 127.0.0.1:12356 up
    B:1 127.0.0.1:12357 up

Upstream bar.com
    P:0 127.0.0.1:12355 up
    B:0 127.0.0.1:12356 up
upstream addr: 127.0.0.1:12354
upstream addr: 127.0.0.1:12354

--- no_error_log
[alert]
failed to run healthcheck cycle
--- error_log
--- grep_error_log eval: qr/healthcheck: .*?:12355 .*|warn\(\): .*(?=,)|healthcheck: peer_.*?:12355/
--- grep_error_log_out eval
qr/^healthcheck: peer_added, 127.0.0.1:12355
(?:healthcheck: peer 127\.0\.0\.1:12355 was checked to be ok
){4,6}$/
--- timeout: 6

