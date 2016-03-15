package = "lua-resty-upstream-healthcheck"
version = "0.1.0-1"
source = {
   url = "https://github.com/...todo.../v2_0_0.tar.gz",
   dir = "lua-resty-upstream-healthcheck-0_1_0",
}
description = {
   summary = "Upstream healthcheck module for OpenResty",
   detailed = [[
      lua-resty-upstream-healthcheck is a module that periodically
      tests upstream peers and flags unavailability.
   ]],
   license = "Apache 2.0",
   homepage = "https://github.com/Mashape/...todo.../"
}
dependencies = {
}
build = {
   type = "builtin",
   modules = { 
     ["resty.upstream.healthcheck"] = "lib/resty/upstream/healthcheck.lua",
     ["resty.upstream.healthcheck.hcu_wrapper"] = "lib/resty/upstream/healthcheck/hcu_wrapper.lua",
   }
}
