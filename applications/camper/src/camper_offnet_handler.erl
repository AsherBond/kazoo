%%%-------------------------------------------------------------------
%%% @copyright (C) 2010-2013, 2600Hz
%%% @doc
%%%
%%%  Read `tries`, 'try_interval' and 'stop_after' from app's config
%%%  document.
%%%
%%%  Ring to offnet number, parks it and bridge with reqester.
%%%
%%% @end
%%% @contributors
%%%   SIPLABS LLC (Maksim Krzhemenevskiy)
%%%-------------------------------------------------------------------
-module(camper_offnet_handler).

-behaviour(gen_listener).

-export([start_link/1]).
-export([init/1
    ,handle_call/3
    ,handle_cast/2
    ,handle_info/2
    ,terminate/2
    ,code_change/3
    ,handle_resource_response/2
]).

-export([add_request/2]).

-include("camper.hrl").

-record(state, {exten :: ne_binary()
                ,stored_call :: whapps_call:call()
                ,queue :: queue()
                ,n_try :: non_neg_integer()
                ,max_tries :: non_neg_integer()
                ,try_after :: non_neg_integer()
                ,stop_timer :: non_neg_integer()
                ,parked_call :: ne_binary()
                ,offnet_ctl_q :: ne_binary()
               }).

-define(MK_CALL_BINDING(CALLID), [{'callid', CALLID}, {'restrict_to', [<<"CHANNEL_DESTROY">>
                                                                       ,<<"CHANNEL_ANSWER">>]}]).

-define(BINDINGS, [{'self', []}]).
-define(RESPONDERS, [{{?MODULE, 'handle_resource_response'}
                      ,[{<<"*">>, <<"*">>}]
                     }
                    ]).
-define(QUEUE_NAME, <<>>).
-define(QUEUE_OPTIONS, []).
-define(CONSUME_OPTIONS, []).

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
-spec start_link([term()]) -> startlink_ret().
start_link(Args) ->
    gen_listener:start_link(?MODULE, [{'responders', ?RESPONDERS}
                                      ,{'bindings', ?BINDINGS}
                                      ,{'queue_name', ?QUEUE_NAME}
                                      ,{'queue_options', ?QUEUE_OPTIONS}
                                      ,{'consume_options', ?CONSUME_OPTIONS}
                                     ], Args).

init([Exten, Call]) ->
    lager:info("Statred offnet handler(~p) for request ~s->~s", [self(), whapps_call:from_user(Call), Exten]),
    MaxTries = whapps_config:get(?CAMPER_CONFIG_CAT, <<"tries">>, 10),
    TryInterval = whapps_config:get(?CAMPER_CONFIG_CAT, <<"try_interval">>, timer:minutes(3)),
    StopAfter = whapps_config:get(?CAMPER_CONFIG_CAT, <<"stop_after">>, timer:minutes(31)),
    StopTimer = timer:apply_after(StopAfter, 'gen_listener', 'cast', [self(), 'stop_campering']),
    {'ok', #state{exten = Exten
                  ,stored_call = Call
                  ,queue = 'undefined'
                  ,n_try = 0
                  ,max_tries = MaxTries
                  ,stop_timer = StopTimer
                  ,try_after = TryInterval
                 }}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    lager:debug("unhandled request from ~p: ~p", [_From, _Request]),
    {'reply', {'error', 'not_implemented'}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast({'gen_listener', {'created_queue', Q}}, #state{queue = 'undefined'} = S) ->
    gen_listener:cast(self(), 'count'),
    {'noreply', S#state{queue = Q}};
handle_cast('count', State) ->
    lager:debug("count"),
    NTry = State#state.n_try,
    MaxTries = State#state.max_tries,
    case NTry < MaxTries of
        'true' ->
            lager:info("making originate request(~p/~p)", [NTry + 1, MaxTries]),
            gen_listener:cast(self(), 'originate_park'),
            {'noreply', State#state{n_try = 1 + State#state.n_try}};
        'false' ->
            {'stop', 'normal', State}
    end;
handle_cast('originate_park', State) ->
    lager:debug("originate park"),
    Exten = State#state.exten,
    Call = State#state.stored_call,
    Q = State#state.queue,
    originate_park(Exten, Call, Q),
    {'noreply', State};
handle_cast({'offnet_ctl_queue', CtrlQ}, State) ->
    {'noreply', State#state{offnet_ctl_q = CtrlQ}};
handle_cast('hangup_parked_call', State) ->
    lager:debug("hangup park"),
    ParkedCall = State#state.parked_call,
    case ParkedCall =:= 'undefined' of
        'false' ->
            Hangup = [{<<"Application-Name">>, <<"hangup">>}
                      ,{<<"Insert-At">>, <<"now">>}
                      ,{<<"Call-ID">>, ParkedCall}
                      | wh_api:default_headers(State#state.queue, <<"call">>, <<"command">>, ?APP_NAME, ?APP_VERSION)],
            wapi_dialplan:publish_command(State#state.offnet_ctl_q, props:filter_undefined(Hangup));
        'true' -> 'ok'
    end,
    {'noreply', State#state{parked_call = 'undefined'}};
handle_cast({'parked', CallId}, State) ->
    Req = build_bridge_request(CallId, State#state.stored_call, State#state.queue),
    lager:debug("Publishing bridge request"),
    wapi_resource:publish_originate_req(Req),
    {'noreply', State#state{parked_call = CallId}};
handle_cast('wait', #state{try_after = Time} = State) ->
    lager:debug("wait before next try"),
    timer:apply_after(Time, 'gen_listener', 'cast', [self(), 'count']),
    {'noreply', State};
handle_cast('stop_campering', #state{stop_timer = 'undefined'} = State) ->
    lager:debug("stopping"),
    {'stop', 'normal', State};
handle_cast('stop_campering', #state{stop_timer = Timer} = State) ->
    lager:debug("stopping"),
    timer:cancel(Timer),
    {'stop', 'normal', State};
handle_cast(_Msg, State) ->
    lager:debug("unhandled cast: ~p", [_Msg]),
    {'noreply', State}.

-spec add_request(ne_binary(), whapps_call:call()) -> 'ok'.
add_request(Exten, Call) ->
    lager:info("adding offnet request to ~s", [Exten]),
    camper_offnet_sup:new(Exten, Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    lager:debug("unhandled msg: ~p", [_Info]),
    {'noreply', State}.

-spec handle_resource_response(wh_json:object(), proplist()) -> 'ok'.
handle_resource_response(JObj, Props) ->
    Srv = props:get_value('server', Props),
    CallId = wh_json:get_value(<<"Call-ID">>, JObj),
    case {wh_json:get_value(<<"Event-Category">>, JObj)
          ,wh_json:get_value(<<"Event-Name">>, JObj)}
    of
        {<<"resource">>, <<"offnet_resp">>} ->
            ResResp = wh_json:get_value(<<"Resource-Response">>, JObj),
            handle_originate_ready(ResResp, Props);
        {<<"call_event">>,<<"CHANNEL_ANSWER">>} ->
            lager:debug("time to bridge"),
            gen_listener:cast(Srv, {'parked', CallId});
        {<<"call_event">>,<<"CHANNEL_DESTROY">>} ->
            lager:debug("Got channel destroy, retrying..."),
            gen_listener:cast(Srv, 'wait');
        {<<"resource">>,<<"originate_resp">>} ->
            case {wh_json:get_value(<<"Application-Name">>, JObj)
                  ,wh_json:get_value(<<"Application-Response">>, JObj)}
            of
                {<<"bridge">>, <<"SUCCESS">>} ->
                    lager:debug("Users bridged"),
                    gen_listener:cast(Srv, 'stop_campering');
                _Ev -> lager:info("Unhandled event: ~p", [_Ev])
            end;
        {<<"error">>,<<"originate_resp">>} ->
            gen_listener:cast(Srv, 'hangup_parked_call'),
            'ok';
        _Ev -> lager:info("Unhandled event ~p", [_Ev])
    end,
    'ok'.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    'ok'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {'ok', State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec build_bridge_request(wh_json:object(), whapps_call:call(), ne_binary()) -> wh_proplist().
build_bridge_request(ParkedCallId, Call, Q) ->
    CIDNumber = whapps_call:kvs_fetch('cf_capture_group', Call),
    MsgId = wh_util:rand_hex_binary(6),
    PresenceId = cf_attributes:presence_id(Call),
    AcctId = whapps_call:account_id(Call),
    {'ok', EP} = cf_endpoint:build(whapps_call:authorizing_id(Call),wh_json:from_list([{<<"can_call_self">>, 'true'}]), Call),
    props:filter_undefined([{<<"Resource-Type">>, <<"audio">>}
        ,{<<"Application-Name">>, <<"bridge">>}
        ,{<<"Existing-Call-ID">>, ParkedCallId}
        ,{<<"Endpoints">>, EP}
        ,{<<"Outbound-Caller-ID-Number">>, CIDNumber}
        ,{<<"Originate-Immediate">>, 'false'}
        ,{<<"Msg-ID">>, MsgId}
        ,{<<"Presence-ID">>, PresenceId}
        ,{<<"Account-ID">>, AcctId}
        ,{<<"Account-Realm">>, whapps_call:from_realm(Call)}
        ,{<<"Timeout">>, 10000}
        ,{<<"From-URI-Realm">>, whapps_call:from_realm(Call)}
        | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
    ]).

originate_park(Exten, Call, Q) ->
    wapi_offnet_resource:publish_req(build_offnet_request(Exten, Call, Q)).

-spec handle_originate_ready(wh_json:object(), proplist()) -> 'ok'.
handle_originate_ready(JObj, Props) ->
    Srv = props:get_value('server', Props),
    case {wh_json:get_value(<<"Event-Category">>, JObj)
          ,wh_json:get_value(<<"Event-Name">>, JObj)}
    of
        {<<"dialplan">>, <<"originate_ready">>} ->
            Q = wh_json:get_value(<<"Server-ID">>, JObj),
            CallId = wh_json:get_value(<<"Call-ID">>, JObj),
            CtrlQ = wh_json:get_value(<<"Control-Queue">>, JObj),
            Prop = [{<<"Call-ID">>, CallId}
                    ,{<<"Msg-ID">>, wh_json:get_value(<<"Msg-ID">>, JObj)}
                    | wh_api:default_headers(gen_listener:queue_name(Srv), ?APP_NAME, ?APP_VERSION)
            ],
            gen_listener:cast(Srv, {'offnet_ctl_queue', CtrlQ}),
            gen_listener:add_binding(Srv, {'call', ?MK_CALL_BINDING(CallId)}),
            wapi_dialplan:publish_originate_execute(Q, Prop);
        _Ev -> lager:info("unkown event: ~p", [_Ev])
    end,
    'ok'.

-spec build_offnet_request(wh_json:object(), whapps_call:call(), ne_binary()) -> wh_proplist().
build_offnet_request(Exten, Call, Q) ->
    {ECIDNum, ECIDName} = cf_attributes:caller_id(<<"emergency">>, Call),
    {CIDNumber, CIDName} = cf_attributes:caller_id(<<"external">>, Call),
    MsgId = wh_util:rand_hex_binary(6),
    PresenceId = cf_attributes:presence_id(Call),
    AcctId = whapps_call:account_id(Call),
    CallId = wh_util:rand_hex_binary(8),
    props:filter_undefined([{<<"Resource-Type">>, <<"originate">>}
        ,{<<"Application-Name">>, <<"park">>}
        ,{<<"Emergency-Caller-ID-Name">>, ECIDName}
        ,{<<"Emergency-Caller-ID-Number">>, ECIDNum}
        ,{<<"Outbound-Caller-ID-Name">>, CIDName}
        ,{<<"Outbound-Caller-ID-Number">>, CIDNumber}
        ,{<<"Msg-ID">>, MsgId}
        ,{<<"Presence-ID">>, PresenceId}
        ,{<<"Account-ID">>, AcctId}
        ,{<<"Call-ID">>, CallId}
        ,{<<"Account-Realm">>, whapps_call:from_realm(Call)}
        ,{<<"Timeout">>, 10000}
        ,{<<"To-DID">>, Exten}
        ,{<<"From-URI-Realm">>, whapps_call:from_realm(Call)}
        | wh_api:default_headers(Q, ?APP_NAME, ?APP_VERSION)
    ]).
