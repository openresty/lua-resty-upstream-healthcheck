OPENRESTY_PREFIX=/usr/local/openresty

PREFIX ?=          /usr/local
LUA_INCLUDE_DIR ?= $(PREFIX)/include
LUA_LIB_DIR ?=     $(PREFIX)/lib/lua/$(LUA_VERSION)
INSTALL ?= install

.PHONY: all test install

all: ;

install: all
	$(INSTALL) -d $(DESTDIR)/$(LUA_LIB_DIR)/resty/upstream/
	$(INSTALL) lib/resty/upstream/*.lua $(DESTDIR)/$(LUA_LIB_DIR)/resty/upstream/

test: all
	PATH=$(OPENRESTY_PREFIX)/nginx/sbin:$$PATH prove -I../test-nginx/lib -r t

lint:
	@find lib -name "*.lua" -type f | sort | xargs -I{} sh -c 'lua-format -i {}'
