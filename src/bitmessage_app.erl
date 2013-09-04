-module(bitmessage_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    application:start(crypto),
    application:start(ranch),
    bitmessage_sup:start_link().

stop(_State) ->
    ok.
