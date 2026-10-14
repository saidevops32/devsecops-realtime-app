-module(worker).
-behaviour(gen_server).
-include_lib("amqp_client/include/amqp_client.hrl").
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).
-record(state, {conn, chan}).

start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    case connect(20) of
        {ok, Conn} ->
            erlang:monitor(process, Conn),
            {ok, Chan} = amqp_connection:open_channel(Conn),
            amqp_channel:call(Chan, #'queue.declare'{queue = <<"tasks">>, durable = true}),
            amqp_channel:call(Chan, #'queue.declare'{queue = <<"results">>, durable = true}),
            amqp_channel:call(Chan, #'basic.qos'{prefetch_count = 10}),
            amqp_channel:subscribe(Chan, #'basic.consume'{queue = <<"tasks">>}, self()),
            logger:notice("Worker connected to RabbitMQ"),
            {ok, #state{conn = Conn, chan = Chan}};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(_Req, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.

handle_info(#'basic.consume_ok'{}, State) -> {noreply, State};

handle_info({#'basic.deliver'{delivery_tag = Tag}, #amqp_msg{payload = Payload}},
            #state{chan = Chan} = State) ->
    try
        Task = jsx:decode(Payload, [return_maps]),
        Id = maps:get(<<"id">>, Task),
        Title = maps:get(<<"title">>, Task),
        logger:notice("Processing task ~p", [Id]),
        timer:sleep(2000),
        Upper = unicode:characters_to_binary(string:uppercase(Title)),
        Result = jsx:encode(#{<<"id">> => Id, <<"result">> => <<"Processed: ", Upper/binary>>}),
        amqp_channel:cast(Chan,
            #'basic.publish'{exchange = <<>>, routing_key = <<"results">>},
            #amqp_msg{props = #'P_basic'{delivery_mode = 2, content_type = <<"application/json">>},
                      payload = Result})
    catch
        Class:Err -> logger:error("Bad task message: ~p:~p", [Class, Err])
    end,
    amqp_channel:cast(Chan, #'basic.ack'{delivery_tag = Tag}),
    {noreply, State};

handle_info({'DOWN', _Ref, process, _Pid, Reason}, State) ->
    {stop, {rabbitmq_down, Reason}, State};   %% crash on purpose, supervisor restarts us
handle_info(#'basic.cancel'{}, State) -> {stop, normal, State};
handle_info(_Other, State) -> {noreply, State}.

terminate(_Reason, #state{conn = Conn}) -> catch amqp_connection:close(Conn), ok.

connect(0) -> {error, rabbitmq_unreachable};
connect(Retries) ->
    Params = #amqp_params_network{
        host = env("RABBITMQ_HOST", "localhost"),
        port = list_to_integer(env("RABBITMQ_PORT", "5672")),
        username = list_to_binary(env("RABBITMQ_USER", "guest")),
        password = list_to_binary(env("RABBITMQ_PASS", "guest"))},
    case amqp_connection:start(Params) of
        {ok, Conn} -> {ok, Conn};
        {error, _} -> logger:notice("RabbitMQ not ready, retrying"), timer:sleep(3000), connect(Retries - 1)
    end.

env(Name, Default) -> case os:getenv(Name) of false -> Default; V -> V end.
