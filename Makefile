REBAR=./rebar

.PHONY: all compile deps clean distclean eunit

all: compile

deps: $(REBAR)
	$(REBAR) get-deps

compile: deps
	$(REBAR) compile
	$(REBAR) escriptize

eunit: compile
	$(REBAR) eunit skip_deps=true

clean: $(REBAR)
	$(REBAR) clean

distclean: clean
	$(REBAR) delete-deps
	rm -rfv plts
