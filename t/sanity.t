# vim:set ft= ts=4 sw=4 et fdm=marker:
use lib 'lib';
use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

#worker_connections(1014);
#master_process_enabled(1);
#log_level('warn');

#repeat_each(2);

plan tests => repeat_each() * (blocks() * 6 + 1);

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"
            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"
            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"down":true,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"

            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"down":true,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
        interval = 100,  -- 100ms
        fall = 2,
        good_statuses = {200, 503},
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"
            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"down":true,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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
){2,4}$/



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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"
            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"down":true,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
        interval = 100,  -- 100ms
        fall = 1,
        rise = 2,
        good_statuses = {200, 503},
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"
            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"
            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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
        http_req = [[GET /status HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n]],
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
            local upstream = require "ngx.upstream"
            local ljson = require "ljson"
            local u = "foo.com"
            local peers, err = upstream.get_primary_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))

            peers, err = upstream.get_backup_peers(u)
            if not peers then
                ngx.say("failed to get peers: ", err)
                return
            end
            ngx.say(ljson.encode(peers))
        ';
    }
--- request
GET /t

--- response_body
[{"current_weight":0,"down":true,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12354","weight":1},{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":1,"max_fails":1,"name":"127.0.0.1:12355","weight":1}]
[{"current_weight":0,"effective_weight":1,"fail_timeout":10,"fails":0,"id":0,"max_fails":1,"name":"127.0.0.1:12356","weight":1}]
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

