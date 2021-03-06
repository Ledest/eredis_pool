%%%-------------------------------------------------------------------
%%% @author Hiroe Shin <shin@mac-hiroe-orz-17.local>
%%% @copyright (C) 2011, Hiroe Shin
%%% @doc
%%%
%%% @end
%%% Created :  9 Oct 2011 by Hiroe Shin <shin@mac-hiroe-orz-17.local>
%%%-------------------------------------------------------------------
-module(eredis_pool).

%% Include
-include_lib("eunit/include/eunit.hrl").

%% Default timeout for calls to the client gen_server
%% Specified in http://www.erlang.org/doc/man/gen_server.html#call-3
-define(TIMEOUT, 5000).

%% API
-export([start/0, stop/0]).
-export([q/2, q/3, qp/2, qp/3, transaction/2, watch_transaction/3,
         create_pool/2, create_pool/3, create_pool/4, create_pool/5,
         create_pool/6, create_pool/7, 
         delete_pool/1]).

%%%===================================================================
%%% API functions
%%%===================================================================

start() ->
    application:start(?MODULE).

stop() ->
    application:stop(?MODULE).

%% ===================================================================
%% @doc create new pool.
%% @end
%% ===================================================================
-spec(create_pool(PoolName::atom(), Size::integer()) -> 
             {ok, pid()} | {error,{already_started, pid()}}).

create_pool(PoolName, Size) ->
    eredis_pool_sup:create_pool(PoolName, Size, []).

-spec(create_pool(PoolName::atom(), Size::integer(), Host::string()|[{OptionName::atom(), OptionValue::term()}]) ->
             {ok, pid()} | {error,{already_started, pid()}}).

create_pool(PoolName, Size, [{_, _}|_] = Options) ->
    eredis_pool_sup:create_pool(PoolName, Size, Options);

create_pool(PoolName, Size, Host) ->
    eredis_pool_sup:create_pool(PoolName, Size, [{host, Host}]).

-spec(create_pool(PoolName::atom(), Size::integer(), 
                  Host::string(), Port::integer()) -> 
             {ok, pid()} | {error,{already_started, pid()}}).

create_pool(PoolName, Size, Host, Port) ->
    eredis_pool_sup:create_pool(PoolName, Size, [{host, Host}, {port, Port}]).

-spec(create_pool(PoolName::atom(), Size::integer(), 
                  Host::string(), Port::integer(), Database::string()) -> 
             {ok, pid()} | {error,{already_started, pid()}}).

create_pool(PoolName, Size, Host, Port, Database) ->
    eredis_pool_sup:create_pool(PoolName, Size, [{host, Host}, {port, Port},
                                                 {database, Database}]).

-spec(create_pool(PoolName::atom(), Size::integer(), 
                  Host::string(), Port::integer(), 
                  Database::string(), Password::string()) -> 
             {ok, pid()} | {error,{already_started, pid()}}).

create_pool(PoolName, Size, Host, Port, Database, Password) ->
    eredis_pool_sup:create_pool(PoolName, Size, [{host, Host}, {port, Port},
                                                 {database, Database},
                                                 {password, Password}]).

-spec(create_pool(PoolName::atom(), Size::integer(), 
                  Host::string(), Port::integer(), 
                  Database::string(), Password::string(),
                  ReconnectSleep::integer()) -> 
             {ok, pid()} | {error,{already_started, pid()}}).

create_pool(PoolName, Size, Host, Port, Database, Password, ReconnectSleep) ->
    eredis_pool_sup:create_pool(PoolName, Size, [{host, Host}, {port, Port},
                                                 {database, Database},
                                                 {password, Password},
                                                 {reconnect_sleep, ReconnectSleep}]).


%% ===================================================================
%% @doc delet pool and disconnected to Redis.
%% @end
%% ===================================================================
-spec(delete_pool(PoolName::atom()) -> ok | {error,not_found}).

delete_pool(PoolName) ->
    eredis_pool_sup:delete_pool(PoolName).

%%--------------------------------------------------------------------
%% @doc
%% Executes the given command in the specified connection. The
%% command must be a valid Redis command and may contain arbitrary
%% data which will be converted to binaries. The returned values will
%% always be binaries.
%% @end
%%--------------------------------------------------------------------
-spec q(PoolName::atom(), Command::iolist()) ->
               {ok, binary() | [binary()]} | {error, Reason::binary()}.

q(PoolName, Command) ->
    q(PoolName, Command, ?TIMEOUT).

-spec q(PoolName::atom(), Command::iolist(), Timeout::integer()) ->
               {ok, binary() | [binary()]} | {error, Reason::binary()}.

q(PoolName, Command, Timeout) ->
    poolboy:transaction(PoolName, fun(Worker) ->
                                          eredis:q(Worker, Command, Timeout)
                                  end).

-spec qp(PoolName::atom(), Command::iolist(), Timeout::integer()) ->
               {ok, binary() | [binary()]} | {error, Reason::binary()}.

qp(PoolName, Pipeline) ->
    qp(PoolName, Pipeline, ?TIMEOUT).

qp(PoolName, Pipeline, Timeout) ->
    poolboy:transaction(PoolName, fun(Worker) ->
   		eredis:qp(Worker, Pipeline, Timeout)
    end).


transaction(PoolName, Fun) when is_function(Fun) ->
    F = fun(C) ->
                try
                    {ok, <<"OK">>} = eredis:q(C, ["MULTI"]),
                    Fun(C),
                    eredis:q(C, ["EXEC"])
                catch Klass:Reason ->
                        {ok, <<"OK">>} = eredis:q(C, ["DISCARD"]),
                        io:fwrite(standard_error, ?MODULE_STRING ": Error in redis transaction ~p:~p", [Klass, Reason]),
                        {Klass, Reason}
                end
        end,

    poolboy:transaction(PoolName, F).    

-spec watch_transaction(PoolName::atom(), Keys::[string()|binary()|atom()], Fun::fun((pid()) -> list())) -> {ok, undefined|binary()|[binary()]} | {error, Reason::binary()|term()}.
watch_transaction(PoolName, [_|_] = Keys, Fun) when is_function(Fun, 1) ->
    poolboy:transaction(PoolName,
                        fun(C) ->
                            case eredis:q(C, ["WATCH"|Keys]) of
                                {ok, <<"OK">>} ->
                                    try Fun(C) of
                                        [_|_] = R1 ->
                                            {ok, <<"OK">>} = eredis:q(C, ["MULTI"]),
                                            R2 = eredis:qp(C, R1),
                                            case lists:all(fun({ok, <<"QUEUED">>}) -> true;
                                                              (_) -> false
                                                           end, R2) of
                                                true -> eredis:q(C, ["EXEC"]);
                                                _ ->
                                                    {ok, <<"OK">>} = eredis:q(C, ["DISCARD"]),
                                                    io:fwrite(standard_error,
                                                              ?MODULE_STRING ": Error in redis watch transaction: ~p~n",
                                                              [R2]),
                                                    {error, R2}
                                            end;
                                        [] ->
                                            {ok, <<"OK">>} = eredis:q(C, ["UNWATCH"]),
                                            {ok, []};
                                        E ->
                                            io:fwrite(standard_error,
                                                      ?MODULE_STRING ": Error in redis watch: ~p~n",
                                                      [E]),
                                            {error, E}
                                    catch Class:Reason ->
                                        {ok, <<"OK">>} = eredis:q(C, ["UNWATCH"]),
                                        {Class, Reason}
                                    end;
                                E -> E
                            end
                        end).
