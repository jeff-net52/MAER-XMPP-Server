%%%----------------------------------------------------------------------
%%% MAER Chat pairing service for ejabberd.
%%%
%%% Copyright (C) 2026 MAER Engineering
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%----------------------------------------------------------------------

-module(mod_maer_pairing).

-behaviour(gen_mod).
-behaviour(gen_server).

-export([start/2, stop/1, reload/3, depends/2,
	 mod_opt_type/1, mod_options/1, mod_doc/0]).
-export([process/2, process_iq/1, decode_iq_subel/1]).
-export([oauth_authenticated/4, revoke_user_devices/2]).
-export([operator_bootstrap_admin/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include_lib("xmpp/include/xmpp.hrl").

-define(NS, <<"urn:maer:pairing:1">>).
-define(CANONICAL_HOST, <<"xmpp.maer.fr">>).
-define(DEVICE_TABLE, maer_pairing_device).
-define(CLEANUP_INTERVAL, 30000).
-define(MAX_BODY_SIZE, 16384).
-define(RATE_WINDOW_SECONDS, 60).
-define(RATE_ENTRY_TTL_SECONDS, 120).
-define(MAX_DEVICE_NAME_CHARS, 80).
-define(MAX_DEVICE_NAME_BYTES, 320).
-define(MAX_APP_VERSION_BYTES, 40).
-define(SPKI_PREFIX, <<16#30, 16#2A, 16#30, 16#05, 16#06, 16#03,
		       16#2B, 16#65, 16#70, 16#03, 16#21, 16#00>>).

operator_bootstrap_admin(Password)
  when is_binary(Password), byte_size(Password) >= 12,
       byte_size(Password) =< 1024 ->
    User = <<"admin">>,
    Host = ?CANONICAL_HOST,
    case ejabberd_auth:user_exists(User, Host) of
        true -> verify_existing_admin(User, Host, Password);
        false ->
            case ejabberd_auth:try_register(User, Host, Password) of
                ok -> verify_created_admin(User, Host, Password);
                {error, exists} -> verify_existing_admin(User, Host, Password);
                Error -> Error
            end
    end;
operator_bootstrap_admin(_) ->
    {error, invalid_password}.

verify_created_admin(User, Host, Password) ->
    case verify_admin_credentials(User, Host, Password) of
        ok -> {ok, created};
        {error, Reason} ->
            ejabberd_auth:remove_user(User, Host),
            case ejabberd_auth:user_exists(User, Host) of
                false -> {error, {validation_failed, Reason}};
                true -> {error, rollback_failed}
            end
    end.

verify_existing_admin(User, Host, Password) ->
    case verify_admin_credentials(User, Host, Password) of
        ok -> {ok, existing};
        {error, _} -> {error, exists}
    end.

verify_admin_credentials(User, Host, Password) ->
    try
        Stored = ejabberd_auth:get_password(User, Host),
        case is_list(Stored) andalso Stored =/= [] andalso
             lists:all(fun is_strict_scram_sha256/1, Stored) andalso
             ejabberd_auth:check_password(User, <<>>, Host, Password) of
            true -> ok;
            false -> {error, credential_mismatch}
        end
    catch _:_ ->
        {error, credential_validation_failed}
    end.

is_strict_scram_sha256(T) ->
    is_tuple(T) andalso tuple_size(T) =:= 6 andalso
    element(1, T) =:= scram andalso
    is_binary(element(2, T)) andalso byte_size(element(2, T)) > 0 andalso
    is_binary(element(3, T)) andalso byte_size(element(3, T)) > 0 andalso
    is_binary(element(4, T)) andalso byte_size(element(4, T)) > 0 andalso
    element(5, T) =:= sha256 andalso
    is_integer(element(6, T)) andalso element(6, T) >= 4096.

-record(pair_session,
	{id                    :: binary(),
	 verification_code     :: binary(),
	 poll_nonce             :: binary(),
	 public_key             :: binary(),
	 device_name            :: binary(),
	 platform               :: binary(),
	 app_version            :: binary(),
	 client_ip              :: inet:ip_address(),
	 expires_at             :: integer(),
	 status = pending       :: pending | approved,
	 jid = undefined        :: binary() | undefined,
	 token = undefined      :: binary() | undefined,
	 token_expires_at = undefined :: integer() | undefined,
	 device_id = undefined  :: binary() | undefined}).

-record(maer_pairing_device,
	{key                   :: {binary(), binary()},
	 jid                   :: binary(),
	 device_id             :: binary(),
	 label                 :: binary(),
	 platform              :: binary(),
	 token                 :: binary(),
	 token_hash            :: binary(),
	 created_at            :: integer(),
	 last_seen_at = undefined :: integer() | undefined,
	 revocation_pending = false :: boolean(),
	 expires_at            :: integer()}).

-record(state,
	{host                  :: binary(),
	 sessions              :: ets:tid() | undefined,
	 rate_limits           :: ets:tid(),
	 session_ttl           :: pos_integer(),
	 token_ttl             :: pos_integer(),
	 timestamp_skew        :: pos_integer(),
	 max_active_per_ip     :: pos_integer(),
	 max_active_global     :: pos_integer(),
	 max_devices_per_account :: pos_integer(),
	 http_requests_per_minute :: pos_integer(),
	 http_requests_global_per_minute :: pos_integer(),
	 iq_requests_per_minute :: pos_integer(),
	 connections = #{}     :: map(),
	 monitors = #{}        :: map(),
	 cleanup_ref           :: reference()}).

%%%----------------------------------------------------------------------
%%% gen_mod callbacks
%%%----------------------------------------------------------------------

start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    gen_mod:stop_child(?MODULE, Host).

reload(Host, NewOpts, _OldOpts) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    gen_server:cast(Proc, {reload, NewOpts}).

depends(_Host, _Opts) ->
    [].

mod_opt_type(session_ttl) ->
    econf:pos_int();
mod_opt_type(token_ttl) ->
    econf:pos_int();
mod_opt_type(timestamp_skew) ->
    econf:pos_int();
mod_opt_type(max_active_per_ip) ->
    econf:pos_int();
mod_opt_type(max_active_global) ->
    econf:pos_int();
mod_opt_type(max_devices_per_account) ->
    econf:pos_int();
mod_opt_type(http_requests_per_minute) ->
    econf:pos_int();
mod_opt_type(http_requests_global_per_minute) ->
    econf:pos_int();
mod_opt_type(iq_requests_per_minute) ->
    econf:pos_int().

mod_options(_Host) ->
    [{session_ttl, 300},
     {token_ttl, 2592000},
     {timestamp_skew, 30},
     {max_active_per_ip, 10},
     {max_active_global, 10000},
     {max_devices_per_account, 100},
     {http_requests_per_minute, 120},
     {http_requests_global_per_minute, 6000},
     {iq_requests_per_minute, 120}].

mod_doc() ->
    #{desc =>
	  <<"MAER Chat device pairing over HTTPS and authenticated XMPP IQ. "
	    "Pairing sessions are ephemeral and OAuth tokens are limited to "
	    "the sasl_auth scope.">>,
      note => "added by MAER in 2026",
      opts =>
	  [{session_ttl,
	    #{value => <<"seconds">>, desc => <<"Lifetime of an uncompleted pairing.">>}},
	   {token_ttl,
	    #{value => <<"seconds">>, desc => <<"Lifetime of the issued OAuth token.">>}},
	   {timestamp_skew,
	    #{value => <<"seconds">>, desc => <<"Maximum signed-request clock skew.">>}},
	   {max_active_per_ip,
	    #{value => <<"integer">>, desc => <<"Maximum active sessions per source IP.">>}},
	   {max_active_global,
	    #{value => <<"integer">>, desc => <<"Maximum active sessions for this host.">>}},
	   {max_devices_per_account,
	    #{value => <<"integer">>, desc => <<"Maximum linked devices per account.">>}},
	   {http_requests_per_minute,
	    #{value => <<"integer">>, desc => <<"Per-IP HTTP request limit per minute.">>}},
	   {http_requests_global_per_minute,
	    #{value => <<"integer">>, desc => <<"Global HTTP request limit per minute.">>}},
	   {iq_requests_per_minute,
	    #{value => <<"integer">>, desc => <<"Per-account pairing IQ limit per minute.">>}}]}.

%%%----------------------------------------------------------------------
%%% gen_server callbacks
%%%----------------------------------------------------------------------

init([?CANONICAL_HOST = Host, Opts]) ->
    process_flag(trap_exit, true),
    process_flag(sensitive, true),
    case ensure_device_table() of
	ok ->
	    Sessions = ets:new(?MODULE, [set, private,
					{keypos, #pair_session.id}]),
	    RateLimits = ets:new(maer_pairing_rate_limits, [set, private]),
	    register_handlers(Host),
	    Ref = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
	    {ok, state_from_opts(Host, Sessions, RateLimits, Ref, Opts)};
	{error, Reason} ->
	    {stop, {cannot_initialize_pairing_devices, Reason}}
    end;
init([Host, _Opts]) ->
    {stop, {unsupported_maer_pairing_host, Host}}.

handle_call({create, IP, Data}, _From, State) ->
    case allow_http_request(IP, State) of
	true ->
	    {Reply, NewState} = create_session(IP, Data, State),
	    {reply, Reply, NewState};
	false ->
	    {reply, rate_limited_response(), State}
    end;
handle_call({poll, IP, ID, Data}, _From, State) ->
    case allow_http_request(IP, State) of
	true -> {reply, poll_session(ID, Data, State), State};
	false -> {reply, rate_limited_response(), State}
    end;
handle_call({cancel, IP, ID, Data}, _From, State) ->
    case allow_http_request(IP, State) of
	true -> {reply, cancel_session(ID, Data, State), State};
	false -> {reply, rate_limited_response(), State}
    end;
handle_call({iq, IQ}, _From, State) ->
    {Reply, NewState} = handle_pairing_iq(IQ, State),
    {reply, Reply, NewState};
handle_call({oauth_authenticated, Pid, User, Server, TokenHash}, _From, State) ->
    {reply, ok, track_oauth_connection(Pid, User, Server, TokenHash, State)};
handle_call({revoke_user_devices, User, Server}, _From, State) ->
    {reply, ok, revoke_all_user_devices(User, Server, State)};
handle_call(_Request, From, State) ->
    ?WARNING_MSG("Unexpected MAER pairing call from ~p", [From]),
    {reply, {error, unexpected_request}, State}.

handle_cast({reload, Opts}, State) ->
    {noreply, update_state_opts(State, Opts)};
handle_cast(_Message, State) ->
    ?WARNING_MSG("Unexpected MAER pairing cast", []),
    {noreply, State}.

handle_info(cleanup, State) ->
    CleanState = cleanup(State),
    Ref = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {noreply, CleanState#state{cleanup_ref = Ref}};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, State) ->
    {noreply, remove_connection_monitor(Ref, State)};
handle_info(_Info, State) ->
    ?WARNING_MSG("Unexpected MAER pairing message", []),
    {noreply, State}.

terminate(_Reason, #state{host = Host, cleanup_ref = Ref, monitors = Monitors}) ->
    erlang:cancel_timer(Ref),
    maps:foreach(fun(Monitor, _) -> erlang:demonitor(Monitor, [flush]) end,
		 Monitors),
    unregister_handlers(Host),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

state_from_opts(Host, Sessions, RateLimits, Ref, Opts) ->
    #state{host = Host,
	   sessions = Sessions,
	   rate_limits = RateLimits,
	   session_ttl = maps:get(session_ttl, Opts, 300),
	   token_ttl = maps:get(token_ttl, Opts, 2592000),
	   timestamp_skew = maps:get(timestamp_skew, Opts, 30),
	   max_active_per_ip = maps:get(max_active_per_ip, Opts, 10),
	   max_active_global = maps:get(max_active_global, Opts, 10000),
	   max_devices_per_account = maps:get(max_devices_per_account, Opts, 100),
	   http_requests_per_minute = maps:get(http_requests_per_minute, Opts, 120),
	   http_requests_global_per_minute =
	       maps:get(http_requests_global_per_minute, Opts, 6000),
	   iq_requests_per_minute = maps:get(iq_requests_per_minute, Opts, 120),
	   cleanup_ref = Ref}.

update_state_opts(State, Opts) ->
    State#state{
      session_ttl = maps:get(session_ttl, Opts, State#state.session_ttl),
      token_ttl = maps:get(token_ttl, Opts, State#state.token_ttl),
      timestamp_skew = maps:get(timestamp_skew, Opts,
				State#state.timestamp_skew),
      max_active_per_ip = maps:get(max_active_per_ip, Opts,
				   State#state.max_active_per_ip),
      max_active_global = maps:get(max_active_global, Opts,
				   State#state.max_active_global),
      max_devices_per_account = maps:get(max_devices_per_account, Opts,
					 State#state.max_devices_per_account),
      http_requests_per_minute = maps:get(http_requests_per_minute, Opts,
					 State#state.http_requests_per_minute),
      http_requests_global_per_minute =
	  maps:get(http_requests_global_per_minute, Opts,
		   State#state.http_requests_global_per_minute),
      iq_requests_per_minute = maps:get(iq_requests_per_minute, Opts,
				       State#state.iq_requests_per_minute)}.

%%%----------------------------------------------------------------------
%%% HTTP handler
%%%----------------------------------------------------------------------

process(Path, #request{tp = https} = Request) ->
    process_https(Path, Request);
process(_Path, #request{}) ->
    json_response(426, #{<<"error">> => <<"tls_required">>}).

process_https(_Path, #request{method = 'OPTIONS'}) ->
    {204, common_headers() ++
	 [{<<"Access-Control-Allow-Methods">>, <<"POST, OPTIONS">>},
	  {<<"Access-Control-Allow-Headers">>, <<"Content-Type">>},
	  {<<"Access-Control-Max-Age">>, <<"600">>}], <<>>};
process_https([<<"v1">>, <<"sessions">>],
	#request{method = 'POST', host = Host, ip = {IP, _},
		 data = Data, length = Length, headers = Headers}) ->
	with_json_body(Length, Data, Headers,
		    fun() -> call_host(Host, {create, IP, Data}) end);
process_https([<<"v1">>, <<"sessions">>, ID, <<"poll">>],
	#request{method = 'POST', host = Host, ip = {IP, _}, data = Data,
		 length = Length, headers = Headers}) ->
	with_json_body(Length, Data, Headers,
		    fun() -> call_host(Host, {poll, IP, ID, Data}) end);
process_https([<<"v1">>, <<"sessions">>, ID, <<"cancel">>],
	#request{method = 'POST', host = Host, ip = {IP, _}, data = Data,
		 length = Length, headers = Headers}) ->
	with_json_body(Length, Data, Headers,
		    fun() -> call_host(Host, {cancel, IP, ID, Data}) end);
process_https(_Path, _Request) ->
    json_response(404, #{<<"error">> => <<"not_found">>}).

with_json_body(Length, Data, Headers, Fun) ->
    case {Length =< ?MAX_BODY_SIZE andalso
	  byte_size(Data) =< ?MAX_BODY_SIZE,
	  has_json_content_type(Headers)} of
	{false, _} ->
	    json_response(413, #{<<"error">> => <<"request_too_large">>});
	{true, false} ->
	    json_response(415, #{<<"error">> => <<"unsupported_media_type">>});
	{true, true} ->
	    Fun()
    end.

has_json_content_type(Headers) ->
    Value = case proplists:get_value('Content-Type', Headers) of
	undefined -> proplists:get_value(<<"Content-Type">>, Headers, <<>>);
	Header -> Header
    end,
    case binary:split(misc:tolower(Value), <<";">>, [trim_all]) of
	[<<"application/json">> | _] -> true;
	_ -> false
    end.

call_host(Host0, Message) ->
    case normalize_host(Host0) of
	{ok, Host} ->
	    Proc = gen_mod:get_module_proc(Host, ?MODULE),
	    try gen_server:call(Proc, Message, 5000) of
		Response -> Response
	    catch
		exit:_ ->
		    json_response(503, #{<<"error">> =>
					     <<"service_unavailable">>})
	    end;
	error ->
	    json_response(400, #{<<"error">> => <<"invalid_host">>})
    end.

normalize_host(Host) ->
    case jid:nameprep(Host) of
	error -> error;
	LHost -> {ok, LHost}
    end.

common_headers() ->
    [{<<"Content-Type">>, <<"application/json; charset=utf-8">>},
     {<<"Cache-Control">>, <<"no-store">>},
     {<<"Pragma">>, <<"no-cache">>},
     {<<"X-Content-Type-Options">>, <<"nosniff">>},
	 {<<"Referrer-Policy">>, <<"no-referrer">>},
	 {<<"Strict-Transport-Security">>, <<"max-age=31536000">>}].

json_response(Status, Body) ->
    {Status, common_headers(), encode_json(Body)}.

rate_limited_response() ->
    {429, [{<<"Retry-After">>, integer_to_binary(?RATE_WINDOW_SECONDS)} |
	   common_headers()],
	 encode_json(#{<<"error">> => <<"rate_limited">>})}.

encode_json(Body) ->
    misc:json_encode(Body).

decode_json(Data) ->
    misc:json_decode(Data).

allow_http_request(IP,
		   #state{rate_limits = RateLimits,
			  http_requests_per_minute = PerIPLimit,
			  http_requests_global_per_minute = GlobalLimit}) ->
    %% This process serializes all requests, so charging the global and
    %% per-source buckets here is deterministic without external locking.
    allow_rate({http, IP}, PerIPLimit, RateLimits)
	andalso allow_rate({http_global}, GlobalLimit, RateLimits).

allow_iq_request(JID,
		 #state{rate_limits = RateLimits,
			iq_requests_per_minute = Limit}) ->
    allow_rate({iq, JID}, Limit, RateLimits).

allow_rate(Key, Limit, RateLimits) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(RateLimits, Key) of
	[] ->
	    true = ets:insert(RateLimits, {Key, Now, 1}),
	    true;
	[{Key, Started, _Count}] when Now - Started >= ?RATE_WINDOW_SECONDS ->
	    true = ets:insert(RateLimits, {Key, Now, 1}),
	    true;
	[{Key, Started, Count}] when Count < Limit ->
	    true = ets:insert(RateLimits, {Key, Started, Count + 1}),
	    true;
	[_] ->
	    false
    end.

%%%----------------------------------------------------------------------
%%% HTTP session operations
%%%----------------------------------------------------------------------

create_session(IP, Data, #state{sessions = Sessions} = State) ->
    Now = erlang:system_time(second),
    cleanup_sessions(Sessions, Now),
    case decode_create_payload(Data) of
	{ok, Payload} ->
	    case below_limits(IP, Now, State) of
	true ->
		    Session = insert_new_session(IP, Payload, Now, State, 3),
		    Reply = json_response(
			      201,
			      #{<<"version">> => 1,
				<<"session_id">> => Session#pair_session.id,
				<<"verification_code">> =>
				    Session#pair_session.verification_code,
				<<"expires_at">> =>
				    format_timestamp(Session#pair_session.expires_at),
				<<"poll_nonce">> =>
				    Session#pair_session.poll_nonce}),
		    {Reply, State};
		false ->
		    {json_response(429, #{<<"error">> => <<"rate_limited">>}),
		     State}
	    end;
	{error, _} ->
	    {json_response(400, #{<<"error">> => <<"invalid_request">>}),
	     State}
    end.

insert_new_session(IP, Payload, Now, State, Attempts) when Attempts > 0 ->
    Session = new_session(IP, Payload, Now, State),
    case ets:insert_new(State#state.sessions, Session) of
	true -> Session;
	false -> insert_new_session(IP, Payload, Now, State, Attempts - 1)
    end;
insert_new_session(_IP, _Payload, _Now, _State, 0) ->
    error(cannot_allocate_pairing_session).

poll_session(ID, Data, #state{sessions = Sessions} = State) ->
    case find_verified_session(<<"POLL">>, ID, Data, State) of
	{ok, #pair_session{status = pending, expires_at = Expires}} ->
	    json_response(200, #{<<"status">> => <<"pending">>,
				 <<"expires_at">> => format_timestamp(Expires)});
	{ok, #pair_session{status = approved} = Session} ->
	    json_response(
	      200,
	      #{<<"status">> => <<"approved">>,
		<<"jid">> => Session#pair_session.jid,
		<<"access_token">> => Session#pair_session.token,
		<<"token_expires_at">> =>
		    format_timestamp(Session#pair_session.token_expires_at),
		<<"device_id">> => Session#pair_session.device_id});
	{error, not_found} ->
	    ets:delete(Sessions, ID),
	    json_response(404, #{<<"error">> => <<"not_found">>});
	{error, invalid_request} ->
	    json_response(400, #{<<"error">> => <<"invalid_request">>})
    end.

cancel_session(ID, Data, #state{sessions = Sessions} = State) ->
    case find_verified_session(<<"CANCEL">>, ID, Data, State) of
	{ok, #pair_session{status = pending}} ->
	    ets:delete(Sessions, ID),
	    json_response(200, #{<<"status">> => <<"cancelled">>});
	{ok, #pair_session{status = approved}} ->
	    json_response(409, #{<<"error">> => <<"already_approved">>});
	{error, not_found} ->
	    ets:delete(Sessions, ID),
	    json_response(404, #{<<"error">> => <<"not_found">>});
	{error, invalid_request} ->
	    json_response(400, #{<<"error">> => <<"invalid_request">>})
    end.

find_verified_session(Operation, ID, Data,
		      #state{sessions = Sessions, timestamp_skew = Skew}) ->
    Now = erlang:system_time(second),
    case valid_session_id(ID) andalso ets:lookup(Sessions, ID) of
	[#pair_session{expires_at = Expires} = Session] when Expires > Now ->
	    case decode_signed_payload(Data) of
		{ok, Nonce, Timestamp, Signature} ->
		    Signed = canonical_payload(Operation, ID, Nonce, Timestamp),
		    case secure_equal(Nonce, Session#pair_session.poll_nonce)
			 andalso timestamp_is_fresh(Timestamp, Now, Skew)
			 andalso verify_signature(Session#pair_session.public_key,
					      Signed, Signature) of
			true -> {ok, Session};
			false -> {error, invalid_request}
		    end;
		{error, _} ->
		    {error, invalid_request}
	    end;
	_ ->
	    {error, not_found}
    end.

new_session(IP, Payload, Now, #state{session_ttl = TTL}) ->
    #pair_session{id = url_token(24),
		  verification_code = verification_code(),
		  poll_nonce = url_token(24),
		  public_key = maps:get(public_key, Payload),
		  device_name = maps:get(device_name, Payload),
		  platform = maps:get(platform, Payload),
		  app_version = maps:get(app_version, Payload),
		  client_ip = IP,
		  expires_at = Now + TTL}.

below_limits(IP, Now,
	     #state{sessions = Sessions,
		    max_active_per_ip = PerIPLimit,
		    max_active_global = GlobalLimit}) ->
    {Global, PerIP} = ets:foldl(
	fun(#pair_session{expires_at = Expires, client_ip = SessionIP},
	    {Global0, PerIP0}) when Expires > Now ->
		{Global0 + 1,
		 case SessionIP == IP of true -> PerIP0 + 1; false -> PerIP0 end};
	   (_, Acc) -> Acc
	end, {0, 0}, Sessions),
    Global < GlobalLimit andalso PerIP < PerIPLimit.

decode_create_payload(Data) ->
    case decode_json_map(Data) of
	{ok, #{<<"protocol_version">> := 1,
	       <<"client_public_key">> := EncodedKey,
	       <<"device_name">> := DeviceName0,
	       <<"platform">> := <<"windows">>,
	       <<"app_version">> := AppVersion} = Map}
	  when map_size(Map) == 5,
	       is_binary(EncodedKey), is_binary(DeviceName0),
	       is_binary(AppVersion) ->
	    case {strict_public_key(EncodedKey),
		  normalize_device_name(DeviceName0),
		  valid_app_version(AppVersion)} of
		{{ok, PublicKey}, {ok, DeviceName}, true} ->
		    {ok, #{public_key => PublicKey,
			   device_name => DeviceName,
			   platform => <<"windows">>,
			   app_version => AppVersion}};
		_ ->
		    {error, invalid_fields}
	    end;
	_ ->
	    {error, invalid_payload}
    end.

decode_signed_payload(Data) ->
    case decode_json_map(Data) of
	{ok, #{<<"nonce">> := Nonce,
	       <<"timestamp">> := Timestamp,
	       <<"signature">> := EncodedSignature} = Map}
	  when map_size(Map) == 3, is_binary(Nonce), is_binary(Timestamp),
	       is_binary(EncodedSignature), byte_size(Timestamp) =< 40 ->
	    case {valid_opaque_id(Nonce, 32),
		  strict_base64(EncodedSignature, 64)} of
		{true, {ok, Signature}} ->
		    {ok, Nonce, Timestamp, Signature};
		_ ->
		    {error, invalid_signature}
	    end;
	_ ->
	    {error, invalid_payload}
    end.

decode_json_map(Data) when is_binary(Data), byte_size(Data) > 0 ->
    try decode_json(Data) of
	Map when is_map(Map) -> {ok, Map};
	_ -> {error, invalid_json_type}
    catch _:_ ->
	{error, invalid_json}
    end;
decode_json_map(_) ->
    {error, invalid_json}.

strict_public_key(Encoded) when byte_size(Encoded) =< 128 ->
    Prefix = ?SPKI_PREFIX,
	case strict_base64(Encoded, 44) of
	{ok, <<Prefix:12/binary, PublicKey:32/binary>>} -> {ok, PublicKey};
	_ -> {error, invalid_spki}
    end;
strict_public_key(_) ->
    {error, invalid_spki}.

strict_base64(Encoded, ExpectedBytes) when is_binary(Encoded) ->
    try base64:decode(Encoded) of
	Decoded when byte_size(Decoded) == ExpectedBytes ->
	    case secure_equal(Encoded, base64:encode(Decoded)) of
		true -> {ok, Decoded};
		false -> {error, non_canonical_base64}
	    end;
	_ ->
	    {error, invalid_base64_size}
    catch _:_ ->
	{error, invalid_base64}
    end.

normalize_device_name(Name) when byte_size(Name) =< ?MAX_DEVICE_NAME_BYTES ->
    try string:trim(Name) of
	Trimmed when is_binary(Trimmed), byte_size(Trimmed) > 0 ->
	    case unicode:characters_to_list(Trimmed, utf8) of
		Chars when is_list(Chars), length(Chars) =< ?MAX_DEVICE_NAME_CHARS ->
		    case lists:all(fun safe_display_char/1, Chars) of
			true -> {ok, Trimmed};
			false -> {error, control_character}
		    end;
		_ -> {error, invalid_utf8}
	    end;
	_ -> {error, empty_name}
    catch _:_ ->
	{error, invalid_name}
    end;
normalize_device_name(_) ->
    {error, invalid_name}.

safe_display_char(C) when C < 32; C >= 127, C =< 159 -> false;
safe_display_char(16#200E) -> false;
safe_display_char(16#200F) -> false;
safe_display_char(C) when C >= 16#202A, C =< 16#202E -> false;
safe_display_char(C) when C >= 16#2066, C =< 16#2069 -> false;
safe_display_char(_) -> true.

valid_app_version(Version) when byte_size(Version) >= 1,
				byte_size(Version) =< ?MAX_APP_VERSION_BYTES ->
    re:run(Version, <<"^[A-Za-z0-9._+-]+$">>, [{capture, none}]) == match;
valid_app_version(_) ->
    false.

valid_session_id(ID) ->
    valid_opaque_id(ID, 32).

valid_opaque_id(ID, Minimum) when is_binary(ID), byte_size(ID) >= Minimum,
				       byte_size(ID) =< 128 ->
    re:run(ID, <<"^[A-Za-z0-9_-]+$">>, [{capture, none}]) == match;
valid_opaque_id(_, _) ->
    false.

canonical_payload(Operation, ID, Nonce, Timestamp) ->
    <<"MAER-PAIR-", Operation/binary, "\n1\n", ID/binary, "\n",
	Nonce/binary, "\n", Timestamp/binary>>.

verify_signature(PublicKey, Payload, Signature) ->
    try crypto:verify(eddsa, none, Payload, Signature,
		      [PublicKey, ed25519])
    catch _:_ ->
	false
    end.

timestamp_is_fresh(Timestamp, Now, Skew) ->
    case parse_timestamp(Timestamp) of
	{ok, Value} -> abs(Now - Value) =< Skew;
	error -> false
    end.

parse_timestamp(Timestamp) ->
    Pattern = <<"^([0-9]{4})-([0-9]{2})-([0-9]{2})T",
		"([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\\.[0-9]{1,9})?Z$">>,
    case re:run(Timestamp, Pattern, [{capture, all_but_first, binary}]) of
	{match, [Y, Mo, D, H, Mi, S]} ->
	    try
		DateTime = {{binary_to_integer(Y), binary_to_integer(Mo),
			     binary_to_integer(D)},
			    {binary_to_integer(H), binary_to_integer(Mi),
			     binary_to_integer(S)}},
		case calendar:valid_date(element(1, DateTime))
		     andalso binary_to_integer(H) =< 23
		     andalso binary_to_integer(Mi) =< 59
		     andalso binary_to_integer(S) =< 59 of
		    true ->
			Epoch = calendar:datetime_to_gregorian_seconds(
				  {{1970, 1, 1}, {0, 0, 0}}),
			Value = calendar:datetime_to_gregorian_seconds(DateTime) - Epoch,
			case Value >= 0 of true -> {ok, Value}; false -> error end;
		    false -> error
		end
	    catch _:_ -> error
	    end;
	_ ->
	    error
    end.

format_timestamp(Seconds) ->
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    {{Y, Mo, D}, {H, Mi, S}} =
	calendar:gregorian_seconds_to_datetime(Epoch + Seconds),
    iolist_to_binary(io_lib:format(
	"~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.000Z",
	[Y, Mo, D, H, Mi, S])).

secure_equal(A, B) when is_binary(A), is_binary(B),
			byte_size(A) == byte_size(B) ->
    secure_equal(A, B, 0) == 0;
secure_equal(_, _) ->
    false.

secure_equal(<<>>, <<>>, Acc) -> Acc;
secure_equal(<<A, ATail/binary>>, <<B, BTail/binary>>, Acc) ->
    secure_equal(ATail, BTail, Acc bor (A bxor B)).

url_token(Bytes) ->
    Encoded = base64:encode(crypto:strong_rand_bytes(Bytes)),
    URL1 = binary:replace(Encoded, <<"+">>, <<"-">>, [global]),
    URL2 = binary:replace(URL1, <<"/">>, <<"_">>, [global]),
    binary:replace(URL2, <<"=">>, <<>>, [global]).

verification_code() ->
    <<Value:32/unsigned-integer>> = crypto:strong_rand_bytes(4),
    %% Reject the incomplete tail instead of introducing modulo bias.  The
    %% chance of retry is below 0.03%, while every six-digit code remains
    %% exactly equiprobable.
    UniformRange = (1 bsl 32) - ((1 bsl 32) rem 1000000),
    case Value < UniformRange of
	true ->
	    Number = Value rem 1000000,
	    Digits = integer_to_binary(Number),
	    Padding = binary:copy(<<"0">>, 6 - byte_size(Digits)),
	    <<Padding/binary, Digits/binary>>;
	false ->
	    verification_code()
    end.

%%%----------------------------------------------------------------------
%%% XMPP IQ operations
%%%----------------------------------------------------------------------

register_handlers(Host) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS,
				  ?MODULE, process_iq),
    ejabberd_hooks:add(c2s_oauth_authenticated, Host, ?MODULE,
		       oauth_authenticated, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE, revoke_user_devices, 40),
    ejabberd_hooks:add(set_password, Host, ?MODULE, revoke_user_devices, 40).

unregister_handlers(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS),
    ejabberd_hooks:delete(c2s_oauth_authenticated, Host, ?MODULE,
			 oauth_authenticated, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE, revoke_user_devices, 40),
    ejabberd_hooks:delete(set_password, Host, ?MODULE, revoke_user_devices, 40).

oauth_authenticated(Pid, User, Server, TokenHash)
  when is_pid(Pid), is_binary(User), is_binary(Server),
       is_binary(TokenHash), byte_size(TokenHash) == 32 ->
    call_module(Server,
		{oauth_authenticated, Pid, User, Server, TokenHash}, 1000),
    ok;
oauth_authenticated(_, _, _, _) ->
    ok.

revoke_user_devices(User, Server) when is_binary(User), is_binary(Server) ->
    call_module(Server, {revoke_user_devices, User, Server}, 10000),
    ok;
revoke_user_devices(_, _) ->
    ok.

call_module(Host, Message, Timeout) ->
    try
	case gen_mod:is_loaded(Host, ?MODULE) of
	    true ->
		Proc = gen_mod:get_module_proc(Host, ?MODULE),
		gen_server:call(Proc, Message, Timeout);
	    false ->
		ok
	end
    catch Class:_Reason ->
	?WARNING_MSG("MAER pairing hook delivery failed on ~ts (~p)",
		     [Host, Class]),
	ok
    end.

decode_iq_subel(#xmlel{} = Element) ->
    Element.

process_iq(#iq{to = #jid{lserver = Host}} = IQ) ->
    Proc = gen_mod:get_module_proc(Host, ?MODULE),
    try gen_server:call(Proc, {iq, IQ}, 10000) of
	Response -> Response
    catch exit:_ ->
	xmpp:make_error(IQ, xmpp:err_internal_server_error())
    end.

handle_pairing_iq(#iq{from = From, to = To} = IQ, State) ->
    case authorized_local_account(From, To, State) of
	true ->
	    BareJID = jid:encode(jid:make(From#jid.luser, From#jid.lserver)),
	    case allow_iq_request(BareJID, State) of
		true -> handle_authorized_iq(IQ, State);
		false ->
		    {iq_rate_limit_error(IQ), State}
	    end;
	false -> {xmpp:make_error(IQ, xmpp:err_forbidden()), State}
    end.

iq_rate_limit_error(IQ) ->
    xmpp:make_error(IQ, xmpp:err_policy_violation()).

authorized_local_account(
  #jid{luser = LUser, lserver = Host, lresource = Resource},
  #jid{luser = <<>>, lserver = ServiceHost, lresource = <<>>},
  #state{host = Host})
  when LUser =/= <<>>, Host =/= <<>>, Host == ServiceHost,
       Resource =/= <<>> ->
    ejabberd_router:is_my_host(Host)
	andalso ejabberd_auth:user_exists(LUser, Host);
authorized_local_account(_, _, _) ->
    false.

handle_authorized_iq(#iq{type = get, sub_els = [#xmlel{name = <<"inspect">>} = El]}
		       = IQ, State) ->
    inspect_iq(IQ, El, State);
handle_authorized_iq(#iq{type = set, sub_els = [#xmlel{name = <<"approve">>} = El]}
		       = IQ, State) ->
    approve_iq(IQ, El, State);
handle_authorized_iq(#iq{type = get,
			 sub_els = [#xmlel{name = <<"devices">>} = El]} = IQ,
		       State) ->
    devices_iq(IQ, El, State);
handle_authorized_iq(#iq{type = set, sub_els = [#xmlel{name = <<"revoke">>} = El]}
		       = IQ, State) ->
    revoke_iq(IQ, El, State);
handle_authorized_iq(IQ, State) ->
    {xmpp:make_error(IQ, xmpp:err_bad_request()), State}.

inspect_iq(IQ, El, #state{sessions = Sessions} = State) ->
    case iq_request_attrs(<<"inspect">>, [<<"session">>, <<"code">>], El) of
	{ok, [ID, Code]} ->
	    Now = erlang:system_time(second),
	    case lookup_session_with_code(Sessions, ID, Code, Now) of
		{ok, Session} ->
		    Result = xml_element(
			       <<"session">>,
			       [{<<"id">>, Session#pair_session.id},
				{<<"label">>, Session#pair_session.device_name},
				{<<"platform">>, Session#pair_session.platform},
				{<<"expires">>,
				 format_timestamp(Session#pair_session.expires_at)}], []),
		    {xmpp:make_iq_result(IQ, Result), State};
		error ->
		    {xmpp:make_error(IQ, xmpp:err_item_not_found()), State}
	    end;
	error ->
	    {xmpp:make_error(IQ, xmpp:err_bad_request()), State}
    end.

approve_iq(#iq{from = From} = IQ, El, State) ->
    case iq_request_attrs(<<"approve">>, [<<"session">>, <<"code">>], El) of
	{ok, [ID, Code]} ->
	    approve_session(IQ, From, ID, Code, State);
	error ->
	    {xmpp:make_error(IQ, xmpp:err_bad_request()), State}
    end.

approve_session(IQ, From, ID, Code,
		#state{sessions = Sessions, token_ttl = TokenTTL,
		       max_devices_per_account = MaxDevices} = State) ->
    Now = erlang:system_time(second),
    case lookup_session_with_code(Sessions, ID, Code, Now) of
	{ok, #pair_session{status = pending} = Session} ->
	    BareJID = jid:make(From#jid.luser, From#jid.lserver),
	    JIDBinary = jid:encode(BareJID),
	    case issue_oauth_token(JIDBinary, TokenTTL) of
		{ok, Token} ->
		    DeviceID = url_token(18),
		    TokenExpires = Now + TokenTTL,
		    Device = #maer_pairing_device{
			key = {JIDBinary, DeviceID}, jid = JIDBinary,
			device_id = DeviceID,
			label = Session#pair_session.device_name,
			platform = Session#pair_session.platform,
			token = Token,
			token_hash = crypto:hash(sha256, Token),
			created_at = Now, expires_at = TokenExpires},
		    case store_device(Device, MaxDevices, Now) of
			ok ->
			    Approved = Session#pair_session{
				status = approved, jid = JIDBinary,
				token = Token, token_expires_at = TokenExpires,
				device_id = DeviceID},
			    true = ets:insert(Sessions, Approved),
			    Result = xml_element(
				       <<"approved">>,
				       [{<<"device-id">>, DeviceID}], []),
			    {xmpp:make_iq_result(IQ, Result), State};
			{error, device_limit} ->
			    revoke_token(Token),
			    {iq_device_limit_error(IQ), State};
			{error, _} ->
			    revoke_token(Token),
			    {xmpp:make_error(
			       IQ, xmpp:err_internal_server_error()), State}
		    end;
		{error, _} ->
		    {xmpp:make_error(IQ, xmpp:err_internal_server_error()), State}
	    end;
	{ok, #pair_session{status = approved}} ->
	    {xmpp:make_error(IQ, xmpp:err_conflict()), State};
	error ->
	    {xmpp:make_error(IQ, xmpp:err_item_not_found()), State}
    end.

iq_device_limit_error(IQ) ->
    xmpp:make_error(IQ, xmpp:err_resource_constraint()).

devices_iq(#iq{from = From} = IQ, El, State) ->
    case iq_request_attrs(<<"devices">>, [], El) of
	{ok, []} ->
	    JIDBinary = jid:encode(jid:make(From#jid.luser, From#jid.lserver)),
	    Now = erlang:system_time(second),
	    case list_devices(JIDBinary, Now) of
		{ok, Devices0} ->
		    Devices = [device_element(Device) || Device <- Devices0],
		    Result = xml_element(<<"devices">>, [], Devices),
		    {xmpp:make_iq_result(IQ, Result), State};
		{error, _} ->
		    {xmpp:make_error(IQ, xmpp:err_internal_server_error()), State}
	    end;
	error ->
	    {xmpp:make_error(IQ, xmpp:err_bad_request()), State}
    end.

revoke_iq(#iq{from = From} = IQ, El, State) ->
    case iq_request_attrs(<<"revoke">>, [<<"device-id">>], El) of
	{ok, [DeviceID]} when byte_size(DeviceID) >= 16,
			      byte_size(DeviceID) =< 128 ->
	    JIDBinary = jid:encode(jid:make(From#jid.luser, From#jid.lserver)),
	    case valid_opaque_id(DeviceID, 16) andalso
		 lookup_device(JIDBinary, DeviceID) of
		{ok, #maer_pairing_device{token = Token} = Device} ->
		    case revoke_token(Token) of
			ok ->
			    delete_device(JIDBinary, DeviceID),
			    NewState = invalidate_device(
					 {JIDBinary, DeviceID}, State),
			    Result = xml_element(
				       <<"revoked">>,
				       [{<<"device-id">>, DeviceID}], []),
			    {xmpp:make_iq_result(IQ, Result), NewState};
			{error, _Reason} ->
			    _ = mark_revocation_pending(Device),
			    NewState = invalidate_device(
					 {JIDBinary, DeviceID}, State),
			    ?WARNING_MSG(
			      "Deferred OAuth revocation for MAER device ~ts",
			      [DeviceID]),
			    {xmpp:make_error(
			       IQ, xmpp:err_internal_server_error()), NewState}
		    end;
		_ ->
		    {xmpp:make_error(IQ, xmpp:err_item_not_found()), State}
	    end;
	error ->
	    {xmpp:make_error(IQ, xmpp:err_bad_request()), State}
    end.

lookup_session_with_code(Sessions, ID, Code, Now)
  when is_binary(ID), is_binary(Code) ->
    case valid_session_id(ID) andalso valid_verification_code(Code)
	 andalso ets:lookup(Sessions, ID) of
	[#pair_session{expires_at = Expires, verification_code = Expected}
	 = Session] when Expires > Now ->
	    case secure_equal(Code, Expected) of
		true -> {ok, Session};
		false -> error
	    end;
	_ -> error
    end;
lookup_session_with_code(_, _, _, _) ->
    error.

valid_verification_code(Code) when is_binary(Code), byte_size(Code) == 6 ->
    re:run(Code, <<"^[0-9]{6}$">>, [{capture, none}]) == match;
valid_verification_code(_) ->
    false.

iq_request_attrs(ExpectedName, Names,
		 #xmlel{name = ExpectedName, attrs = Attrs, children = []} = El) ->
    AttributeNames = [Name || {Name, _} <- Attrs],
    ExpectedNames = [<<"xmlns">> | Names],
    case xmpp:get_ns(El) == ?NS
	 andalso lists:sort(AttributeNames) == lists:sort(ExpectedNames) of
	true ->
	    Values = [proplists:get_value(Name, Attrs) || Name <- Names],
	    case lists:all(fun is_binary/1, Values) of
		true -> {ok, Values};
		false -> error
	    end;
	false ->
	    error
    end;
iq_request_attrs(_, _, _) ->
    error.

xml_element(Name, Attrs, Children) ->
    #xmlel{name = Name,
	    attrs = [{<<"xmlns">>, ?NS} | Attrs],
	    children = Children}.

device_element(#maer_pairing_device{device_id = ID, label = Label,
				    platform = Platform,
				    created_at = Created,
				    last_seen_at = LastSeen,
				    expires_at = Expires}) ->
    LastSeenAttribute = case LastSeen of
	undefined -> [];
	_ -> [{<<"last-seen">>, format_timestamp(LastSeen)}]
    end,
    xml_element(<<"device">>,
		[{<<"id">>, ID}, {<<"label">>, Label},
		 {<<"platform">>, Platform},
		 {<<"created">>, format_timestamp(Created)}] ++ LastSeenAttribute ++
		[
		 {<<"expires">>, format_timestamp(Expires)}], []).

issue_oauth_token(JIDBinary, TTL) ->
    try ejabberd_oauth:oauth_issue_token(binary_to_list(JIDBinary), TTL,
					 [<<"sasl_auth">>]) of
	{Token, Scope, _Expires} when is_binary(Token), is_list(Scope) ->
	    case lists:member(<<"sasl_auth">>, Scope) of
		true -> {ok, Token};
		false -> {error, unexpected_oauth_scope}
	    end;
	{error, Reason} -> {error, Reason};
	Other -> {error, {unexpected_oauth_response, Other}}
    catch Class:Reason ->
	{error, {Class, Reason}}
    end.

revoke_token(Token) ->
    try ejabberd_oauth:oauth_revoke_token(Token) of
	{ok, _} -> ok;
	ok -> ok;
	Other -> {error, Other}
    catch Class:Reason ->
	{error, {Class, Reason}}
    end.

%%%----------------------------------------------------------------------
%%% Persistent device registry
%%%----------------------------------------------------------------------

ensure_device_table() ->
    Options = [{attributes, record_info(fields, maer_pairing_device)},
	       {disc_copies, [node()]}, {type, set},
	       {index, [#maer_pairing_device.jid]}],
    case mnesia:create_table(?DEVICE_TABLE, Options) of
	{atomic, ok} -> wait_for_device_table();
	{aborted, {already_exists, ?DEVICE_TABLE}} -> wait_for_device_table();
	{aborted, Reason} -> {error, Reason}
    end.

wait_for_device_table() ->
    case mnesia:wait_for_tables([?DEVICE_TABLE], 10000) of
	ok -> verify_device_table_schema();
	{timeout, Tables} -> {error, {table_timeout, Tables}};
	{error, Reason} -> {error, Reason}
    end.

verify_device_table_schema() ->
    Expected = record_info(fields, maer_pairing_device),
    try mnesia:table_info(?DEVICE_TABLE, attributes) of
	Expected ->
	    Indexes = mnesia:table_info(?DEVICE_TABLE, index),
	    case lists:member(#maer_pairing_device.jid, Indexes) of
		true -> ok;
		false -> {error, {missing_table_index, jid}}
	    end;
	Actual -> {error, {incompatible_table_schema, Actual}}
    catch Class:Reason ->
	{error, {Class, Reason}}
    end.

store_device(#maer_pairing_device{jid = JIDBinary, key = Key} = Device,
	     Maximum, Now) ->
    Transaction = fun() ->
	mnesia:write_lock_table(?DEVICE_TABLE),
	Devices = mnesia:index_read(
		    ?DEVICE_TABLE, JIDBinary, #maer_pairing_device.jid),
	Active = lists:foldl(
		   fun(#maer_pairing_device{expires_at = Expires}, Count)
			 when Expires =< Now -> Count;
		      (_, Count) -> Count + 1
		   end, 0, Devices),
	case {Active < Maximum, mnesia:read(?DEVICE_TABLE, Key, write)} of
	    {true, []} ->
		mnesia:write(?DEVICE_TABLE, Device, write),
		ok;
	    {false, _} ->
		mnesia:abort(device_limit);
	    {true, _} ->
		mnesia:abort(device_id_collision)
	end
    end,
    case mnesia:transaction(Transaction) of
	{atomic, ok} -> ok;
	{aborted, Reason} -> {error, Reason}
    end.

list_devices(JIDBinary, Now) ->
    try mnesia:dirty_index_read(
	  ?DEVICE_TABLE, JIDBinary, #maer_pairing_device.jid) of
	Devices ->
	    Active = lists:filter(
	      fun(#maer_pairing_device{expires_at = Expires}) -> Expires > Now end,
	      Devices),
	    {ok, lists:sort(
		   fun(#maer_pairing_device{created_at = A},
		       #maer_pairing_device{created_at = B}) -> A >= B end,
		   Active)}
    catch Class:Reason -> {error, {Class, Reason}}
    end.

lookup_device(JIDBinary, DeviceID)
  when is_binary(DeviceID) ->
    try mnesia:dirty_read(?DEVICE_TABLE, {JIDBinary, DeviceID}) of
	[#maer_pairing_device{} = Device] -> {ok, Device};
	_ -> error
    catch _:_ -> error
    end;
lookup_device(_, _) ->
    error.

delete_device(JIDBinary, DeviceID) ->
    mnesia:dirty_delete(?DEVICE_TABLE, {JIDBinary, DeviceID}).

find_device_by_token_hash(JIDBinary, TokenHash, Now) ->
    case list_devices(JIDBinary, Now) of
	{ok, Devices} ->
	    lists:foldl(
	      fun(#maer_pairing_device{token_hash = Expected} = Device, Found) ->
		      case secure_equal(TokenHash, Expected) of
			  true -> {ok, Device};
			  false -> Found
		      end
	      end, error, Devices);
	{error, _} = Error ->
	    Error
    end.

track_oauth_connection(Pid, User, Server, TokenHash,
		       #state{host = Server} = State) ->
    JIDBinary = jid:encode(jid:make(User, Server)),
    Now = erlang:system_time(second),
    case find_device_by_token_hash(JIDBinary, TokenHash, Now) of
	{ok, #maer_pairing_device{revocation_pending = true}} ->
	    %% OAuth storage may be temporarily unavailable during revocation.
	    %% A persisted tombstone still prevents the bearer from establishing a
	    %% usable XMPP session while cleanup retries the backend operation.
	    ejabberd_c2s:route(Pid, kick),
	    State;
	{ok, #maer_pairing_device{} = Device} ->
	    _ = update_last_seen(Device, Now),
	    add_connection(Device#maer_pairing_device.key, Pid, State);
	_ ->
	    State
    end;
track_oauth_connection(_Pid, _User, _Server, _TokenHash, State) ->
    State.

update_last_seen(Device, Now) ->
    try mnesia:dirty_write(?DEVICE_TABLE,
			   Device#maer_pairing_device{last_seen_at = Now}) of
	ok -> ok
    catch Class:Reason ->
	{error, {Class, Reason}}
    end.

mark_revocation_pending(Device) ->
    try mnesia:dirty_write(
	  ?DEVICE_TABLE,
	  Device#maer_pairing_device{revocation_pending = true}) of
	ok -> ok
    catch Class:Reason ->
	?ERROR_MSG("Failed to persist a MAER revocation tombstone: ~p",
		   [{Class, Reason}]),
	{error, {Class, Reason}}
    end.

add_connection(DeviceKey, Pid, #state{connections = Connections} = State) ->
    DeviceConnections = maps:get(DeviceKey, Connections, #{}),
    case maps:is_key(Pid, DeviceConnections) of
	true ->
	    State;
	false ->
	    Ref = erlang:monitor(process, Pid),
	    State#state{
	      connections = maps:put(
		DeviceKey, maps:put(Pid, Ref, DeviceConnections), Connections),
	      monitors = maps:put(Ref, {DeviceKey, Pid}, State#state.monitors)}
    end.

remove_connection_monitor(Ref, #state{monitors = Monitors} = State) ->
    case maps:take(Ref, Monitors) of
	{{DeviceKey, Pid}, NewMonitors} ->
	    DeviceConnections = maps:get(DeviceKey, State#state.connections, #{}),
	    Remaining = maps:remove(Pid, DeviceConnections),
	    NewConnections = case map_size(Remaining) of
		0 -> maps:remove(DeviceKey, State#state.connections);
		_ -> maps:put(DeviceKey, Remaining, State#state.connections)
	    end,
	    State#state{connections = NewConnections, monitors = NewMonitors};
	error ->
	    State
    end.

kick_device_connections(DeviceKey,
			#state{connections = Connections, monitors = Monitors} = State) ->
    case maps:take(DeviceKey, Connections) of
	{DeviceConnections, NewConnections} ->
	    NewMonitors = maps:fold(
	      fun(Pid, Ref, Acc) ->
		      erlang:demonitor(Ref, [flush]),
		      ejabberd_c2s:route(Pid, kick),
		      maps:remove(Ref, Acc)
	      end, Monitors, DeviceConnections),
	    State#state{connections = NewConnections, monitors = NewMonitors};
	error ->
	    State
    end.

invalidate_device({JIDBinary, DeviceID} = DeviceKey,
		  #state{sessions = Sessions} = State) ->
    case Sessions of
	undefined -> ok;
	_ ->
	    ets:select_delete(
	      Sessions,
	      [{{pair_session, '_', '_', '_', '_', '_', '_', '_', '_', '_',
		 approved, JIDBinary, '_', '_', DeviceID}, [], [true]}])
    end,
    kick_device_connections(DeviceKey, State).

revoke_all_user_devices(User, Server,
			#state{host = Server} = State) ->
    JIDBinary = jid:encode(jid:make(User, Server)),
    case list_all_devices(JIDBinary) of
	{ok, Devices} ->
	    lists:foldl(
		      fun(#maer_pairing_device{key = DeviceKey, token = Token,
				       device_id = DeviceID} = Device, Acc) ->
		      case revoke_token(Token) of
			  ok ->
			      delete_device(JIDBinary, DeviceID),
			      invalidate_device(DeviceKey, Acc);
			  {error, _Reason} ->
			      _ = mark_revocation_pending(Device),
			      ?ERROR_MSG(
				"Deferred revocation of a MAER linked device for ~ts",
				[JIDBinary]),
			      invalidate_device(DeviceKey, Acc)
		      end
	      end, State, Devices);
	{error, Reason} ->
	    ?ERROR_MSG("Failed to enumerate MAER linked devices for ~ts: ~p",
		       [JIDBinary, Reason]),
	    State
    end;
revoke_all_user_devices(_User, _Server, State) ->
    State.

list_all_devices(JIDBinary) ->
    try mnesia:dirty_index_read(
	  ?DEVICE_TABLE, JIDBinary, #maer_pairing_device.jid) of
	Devices -> {ok, Devices}
    catch Class:Reason -> {error, {Class, Reason}}
    end.

%%%----------------------------------------------------------------------
%%% Cleanup
%%%----------------------------------------------------------------------

cleanup(#state{sessions = Sessions, rate_limits = RateLimits} = State) ->
    Now = erlang:system_time(second),
    cleanup_sessions(Sessions, Now),
    NewState = cleanup_devices(Now, State),
    cleanup_rate_limits(RateLimits),
    NewState.

cleanup_sessions(Sessions, Now) ->
    ets:select_delete(
      Sessions,
      [{{pair_session, '_', '_', '_', '_', '_', '_', '_', '_', '$1',
	  '_', '_', '_', '_', '_'},
	[{'=<', '$1', Now}], [true]}]),
    ok.

cleanup_devices(Now, State) ->
    %% Use the raw Mnesia tuple as a match pattern.  Record construction is
    %% type-checked as a real value by Dialyzer, whereas '_' is only valid as
    %% the wildcard understood by dirty_match_object/2.
    Pattern = {maer_pairing_device, '_', '_', '_', '_', '_', '_', '_',
	       '_', '_', '_', '_'},
    try mnesia:dirty_match_object(?DEVICE_TABLE, Pattern) of
	Devices ->
	    cleanup_device_records(Devices, Now, State)
    catch Class:Reason ->
	?WARNING_MSG("Failed to clean MAER pairing devices: ~p", [{Class, Reason}]),
	State
    end.

cleanup_device_records(Devices, Now, State) ->
    cleanup_device_records(Devices, Now, State,
			   fun revoke_token/1, fun safe_delete_device/1).

cleanup_device_records(Devices, Now, State, Revoke, Delete) ->
    lists:foldl(
	      fun(#maer_pairing_device{key = Key, token = Token,
					revocation_pending = true}, Acc) ->
		      case Revoke(Token) of
			  ok -> Delete(Key);
			  {error, _Reason} ->
			      ?WARNING_MSG(
				"MAER OAuth revocation retry remains pending", [])
		      end,
		      invalidate_device(Key, Acc);
		 (#maer_pairing_device{key = Key, token = Token,
					expires_at = Expires}, Acc)
		    when Expires =< Now ->
		      Revoke(Token),
		      Delete(Key),
		      invalidate_device(Key, Acc);
		 (_, Acc) -> Acc
	      end, State, Devices).

safe_delete_device(Key) ->
    try mnesia:dirty_delete(?DEVICE_TABLE, Key) of
	ok -> ok
    catch Class:Reason ->
	?WARNING_MSG("Failed to delete an expired MAER pairing device: ~p",
		     [{Class, Reason}]),
	{error, {Class, Reason}}
    end.

cleanup_rate_limits(RateLimits) ->
    Cutoff = erlang:monotonic_time(second) - ?RATE_ENTRY_TTL_SECONDS,
    ets:select_delete(
      RateLimits,
      [{{'_', '$1', '_'}, [{'=<', '$1', Cutoff}], [true]}]),
    ok.

%%%----------------------------------------------------------------------
%%% Unit tests
%%%----------------------------------------------------------------------

-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").

strict_public_key_test() ->
    Key = crypto:strong_rand_bytes(32),
    Prefix = ?SPKI_PREFIX,
    Encoded = base64:encode(<<Prefix/binary, Key/binary>>),
    ?assertEqual({ok, Key}, strict_public_key(Encoded)),
	?assertMatch({error, _}, strict_public_key(base64:encode(Key))),
    ?assertMatch({error, _}, strict_public_key(<<Encoded/binary, "\n">>)).

canonical_host_only_test() ->
    ?assertEqual(
	{stop, {unsupported_maer_pairing_host, <<"other.example">>}},
	init([<<"other.example">>, #{}])).

signed_payload_test() ->
    Expected = <<"MAER-PAIR-POLL\n1\nsession\nnonce\n"
		 "2026-08-26T12:00:00.000Z">>,
    ?assertEqual(Expected,
		 canonical_payload(<<"POLL">>, <<"session">>, <<"nonce">>,
				   <<"2026-08-26T12:00:00.000Z">>)).

ed25519_signature_test() ->
    {PublicKey, PrivateKey} = crypto:generate_key(eddsa, ed25519),
    Payload = <<"pairing payload">>,
    Signature = crypto:sign(eddsa, none, Payload, [PrivateKey, ed25519]),
    ?assert(verify_signature(PublicKey, Payload, Signature)),
    ?assertNot(verify_signature(PublicKey, <<Payload/binary, 0>>, Signature)).

timestamp_test() ->
    ?assertMatch({ok, _}, parse_timestamp(<<"2026-08-26T12:34:56.789Z">>)),
    ?assertEqual(error, parse_timestamp(<<"2026-02-31T12:34:56Z">>)),
	?assertEqual(error, parse_timestamp(<<"2026-08-26 12:34:56Z">>)),
    ?assertEqual(error, parse_timestamp(<<"2026-08-26T24:00:00Z">>)),
    ?assertEqual(error, parse_timestamp(<<"2026-08-26T23:60:00Z">>)),
    ?assertEqual(error, parse_timestamp(<<"2026-08-26T23:59:60Z">>)).

secure_equal_test() ->
    ?assert(secure_equal(<<"123456">>, <<"123456">>)),
    ?assertNot(secure_equal(<<"123456">>, <<"123457">>)),
    ?assertNot(secure_equal(<<"short">>, <<"longer">>)).

decode_create_payload_test() ->
    Key = crypto:strong_rand_bytes(32),
    Prefix = ?SPKI_PREFIX,
    Encoded = base64:encode(<<Prefix/binary, Key/binary>>),
    Data = encode_json(
	     #{<<"protocol_version">> => 1,
	       <<"client_public_key">> => Encoded,
	       <<"device_name">> => <<"  PC Atelier  ">>,
	       <<"platform">> => <<"windows">>,
	       <<"app_version">> => <<"1.0.3">>}),
    ?assertMatch({ok, #{public_key := Key,
			device_name := <<"PC Atelier">>}},
		 decode_create_payload(Data)),
    ?assertMatch(
	{error, _},
	decode_create_payload(
	  encode_json(
	    #{<<"protocol_version">> => 1,
	      <<"client_public_key">> => Encoded,
	      <<"device_name">> => <<"PC", 16#E2, 16#80, 16#AE, "evil">>,
	      <<"platform">> => <<"windows">>,
	      <<"app_version">> => <<"1.0.3">>}))),
    ?assertMatch(
	{error, _},
	decode_create_payload(
	  encode_json(
	    #{<<"protocol_version">> => 1,
	      <<"client_public_key">> => Encoded,
	      <<"device_name">> => <<"PC Atelier">>,
	      <<"platform">> => <<"windows">>,
	      <<"app_version">> => <<"1.0.3">>,
	      <<"unexpected">> => true}))).

signed_payload_validation_test() ->
    Signature = base64:encode(crypto:strong_rand_bytes(64)),
    Good = encode_json(
	     #{<<"nonce">> => url_token(24),
	       <<"timestamp">> => <<"2026-08-26T12:00:00.000Z">>,
	       <<"signature">> => Signature}),
    ?assertMatch({ok, _, _, _}, decode_signed_payload(Good)),
    NonCanonical = binary:replace(Signature, <<"=">>, <<"\n=">>),
    Bad = encode_json(
	    #{<<"nonce">> => url_token(24),
	      <<"timestamp">> => <<"2026-08-26T12:00:00.000Z">>,
	      <<"signature">> => NonCanonical}),
    ?assertMatch({error, _}, decode_signed_payload(Bad)).

https_and_media_type_test() ->
    Base = #request{method = 'POST', host = <<"xmpp.maer.fr">>,
		    ip = {{127, 0, 0, 1}, 12345}, data = <<"{}">>, length = 2},
    ?assertMatch({426, _, _}, process([], Base#request{tp = http})),
    ?assertMatch(
	{415, _, _},
	process([<<"v1">>, <<"sessions">>], Base#request{tp = https})),
    TooLarge = binary:copy(<<"x">>, ?MAX_BODY_SIZE + 1),
    ?assertMatch(
	{413, _, _},
	process(
	  [<<"v1">>, <<"sessions">>],
	  Base#request{tp = https, data = TooLarge,
		       length = byte_size(TooLarge),
		       headers = [{'Content-Type', <<"application/json">>}]})).

iq_payload_is_strict_test() ->
    Inspect = #xmlel{name = <<"inspect">>,
		     attrs = [{<<"xmlns">>, ?NS},
			      {<<"session">>, url_token(24)},
			      {<<"code">>, <<"123456">>}],
		     children = []},
    ?assertMatch({ok, [_, <<"123456">>]},
		 iq_request_attrs(<<"inspect">>,
				  [<<"session">>, <<"code">>], Inspect)),
    ?assertEqual(
	error,
	iq_request_attrs(
	  <<"inspect">>, [<<"session">>, <<"code">>],
	  Inspect#xmlel{attrs = [{<<"extra">>, <<"value">>} |
				 Inspect#xmlel.attrs]})),
    ?assertEqual(
	error,
	iq_request_attrs(
	  <<"inspect">>, [<<"session">>, <<"code">>],
	  Inspect#xmlel{children = [{xmlcdata, <<"unexpected">>}]})).

authorized_local_account_test_() ->
    {setup, fun authorization_fixture/0, fun authorization_cleanup/1,
     fun authorization_assertions/1}.

authorization_fixture() ->
    meck:new(ejabberd_router, [unstick]),
    meck:new(ejabberd_auth, [unstick]),
    meck:expect(
      ejabberd_router, is_my_host,
      fun(?CANONICAL_HOST) -> true end),
    meck:expect(
      ejabberd_auth, user_exists,
      fun(<<"disabled">>, ?CANONICAL_HOST) -> false;
	 (<<"alice">>, ?CANONICAL_HOST) -> true
      end),
    ok.

authorization_cleanup(_) ->
    meck:unload(ejabberd_auth),
    meck:unload(ejabberd_router).

authorization_assertions(_) ->
    fun() ->
       State = #state{host = ?CANONICAL_HOST},
       Service = jid:make(<<>>, ?CANONICAL_HOST, <<>>),
       Alice = jid:make(<<"alice">>, ?CANONICAL_HOST, <<"android">>),
       ?assert(authorized_local_account(Alice, Service, State)),
       ?assertNot(
	 authorized_local_account(
	   jid:make(<<"alice">>, ?CANONICAL_HOST, <<>>), Service, State)),
       ?assertNot(
	 authorized_local_account(
	   jid:make(<<"alice">>, <<"other.example">>, <<"android">>),
	   Service, State)),
       ?assertNot(
	 authorized_local_account(
	   Alice, jid:make(<<"service">>, ?CANONICAL_HOST, <<>>), State)),
       ?assertNot(
	 authorized_local_account(
	   jid:make(<<"disabled">>, ?CANONICAL_HOST, <<"android">>),
	   Service, State))
    end.

oauth_issue_scope_test_() ->
    {setup, fun oauth_fixture/0, fun oauth_cleanup/1,
     fun oauth_scope_assertions/1}.

oauth_fixture() ->
    meck:new(ejabberd_oauth, [unstick]),
    ok.

oauth_cleanup(_) ->
    meck:unload(ejabberd_oauth).

oauth_scope_assertions(_) ->
    fun() ->
       JID = <<"alice@xmpp.maer.fr">>,
       meck:expect(
	 ejabberd_oauth, oauth_issue_token,
	 fun("alice@xmpp.maer.fr", 60, [<<"sasl_auth">>]) ->
		 {<<"scoped-token">>, [<<"sasl_auth">>], "60 seconds"}
	 end),
       ?assertEqual({ok, <<"scoped-token">>}, issue_oauth_token(JID, 60)),
       meck:expect(
	 ejabberd_oauth, oauth_issue_token,
	 fun(_, _, _) -> {<<"unsafe-token">>, [<<"ejabberd:admin">>],
			  "60 seconds"} end),
       ?assertEqual(
	 {error, unexpected_oauth_scope}, issue_oauth_token(JID, 60)),
       meck:expect(
	 ejabberd_oauth, oauth_revoke_token,
	 fun(<<"scoped-token">>) -> {ok, ""} end),
       ?assertEqual(ok, revoke_token(<<"scoped-token">>))
    end.

rate_limit_test() ->
    Table = ets:new(maer_pairing_rate_test, [set, private]),
    Key = {http, {127, 0, 0, 1}},
    ?assert(allow_rate(Key, 2, Table)),
    ?assert(allow_rate(Key, 2, Table)),
    ?assertNot(allow_rate(Key, 2, Table)),
    [{Key, Started, Count}] = ets:lookup(Table, Key),
    true = ets:insert(Table, {Key, Started - ?RATE_WINDOW_SECONDS, Count}),
    ?assert(allow_rate(Key, 2, Table)),
    ets:delete(Table).

http_global_rate_limit_test() ->
    Table = ets:new(maer_pairing_global_rate_test, [set, private]),
    State = #state{rate_limits = Table,
		   http_requests_per_minute = 10,
		   http_requests_global_per_minute = 2},
    ?assert(allow_http_request({127, 0, 0, 1}, State)),
    ?assert(allow_http_request({127, 0, 0, 2}, State)),
    ?assertNot(allow_http_request({127, 0, 0, 3}, State)),
    ets:delete(Table).

iq_rate_limit_condition_test() ->
    IQ = #iq{type = get, id = <<"rate-limit-test">>},
    ErrorIQ = iq_rate_limit_error(IQ),
    #stanza_error{reason = 'policy-violation'} = xmpp:get_error(ErrorIQ),
    ok.

iq_device_limit_condition_test() ->
    IQ = #iq{type = set, id = <<"device-limit-test">>},
    ErrorIQ = iq_device_limit_error(IQ),
    #stanza_error{reason = 'resource-constraint'} = xmpp:get_error(ErrorIQ),
    ok.

signed_poll_and_cancel_flow_test() ->
    Sessions = ets:new(maer_pairing_session_flow_test,
		       [set, private, {keypos, #pair_session.id}]),
    {PublicKey, PrivateKey} = crypto:generate_key(eddsa, ed25519),
    Now = erlang:system_time(second),
    ID = url_token(24),
    Nonce = url_token(24),
    Session = #pair_session{
	id = ID, verification_code = <<"123456">>, poll_nonce = Nonce,
	public_key = PublicKey, device_name = <<"PC Atelier">>,
	platform = <<"windows">>, app_version = <<"1.0.0">>,
	client_ip = {127, 0, 0, 1}, expires_at = Now + 300},
    true = ets:insert(Sessions, Session),
    State = #state{sessions = Sessions, timestamp_skew = 30},
    Timestamp = format_timestamp(Now),
    PollPayload = canonical_payload(<<"POLL">>, ID, Nonce, Timestamp),
    PollSignature = crypto:sign(
		      eddsa, none, PollPayload, [PrivateKey, ed25519]),
    PollBody = signed_json(Nonce, Timestamp, PollSignature),
    {200, _, PendingJSON} = poll_session(ID, PollBody, State),
    ?assertMatch(#{<<"status">> := <<"pending">>}, decode_json(PendingJSON)),

    %% The delivery proof is replay-safe during the short session TTL.
    Approved = Session#pair_session{
	status = approved, jid = <<"alice@xmpp.maer.fr">>,
	token = <<"oauth-secret">>, token_expires_at = Now + 3600,
	device_id = url_token(18)},
    true = ets:insert(Sessions, Approved),
    {200, _, ApprovedJSON1} = poll_session(ID, PollBody, State),
    {200, _, ApprovedJSON2} = poll_session(ID, PollBody, State),
    ?assertEqual(decode_json(ApprovedJSON1), decode_json(ApprovedJSON2)),
    ?assertMatch(#{<<"status">> := <<"approved">>,
		   <<"access_token">> := <<"oauth-secret">>},
		 decode_json(ApprovedJSON1)),

    _ = invalidate_device(
	  {<<"alice@xmpp.maer.fr">>, Approved#pair_session.device_id}, State),
    ?assertEqual([], ets:lookup(Sessions, ID)),
    true = ets:insert(Sessions, Approved),

    BadSignature = crypto:strong_rand_bytes(64),
    ?assertMatch({400, _, _},
		 poll_session(ID,
			      signed_json(Nonce, Timestamp, BadSignature), State)),
    WrongNonce = url_token(24),
    WrongNoncePayload = canonical_payload(
			  <<"POLL">>, ID, WrongNonce, Timestamp),
    WrongNonceSignature = crypto:sign(
			    eddsa, none, WrongNoncePayload,
			    [PrivateKey, ed25519]),
    ?assertMatch({400, _, _},
		 poll_session(ID,
			      signed_json(WrongNonce, Timestamp,
					  WrongNonceSignature), State)),
    StaleTimestamp = format_timestamp(Now - 31),
    StalePayload = canonical_payload(
		     <<"POLL">>, ID, Nonce, StaleTimestamp),
    StaleSignature = crypto:sign(
		       eddsa, none, StalePayload, [PrivateKey, ed25519]),
    ?assertMatch({400, _, _},
		 poll_session(ID,
			      signed_json(Nonce, StaleTimestamp,
					  StaleSignature), State)),

    CancelID = url_token(24),
    CancelSession = Session#pair_session{id = CancelID},
    true = ets:insert(Sessions, CancelSession),
    CancelPayload = canonical_payload(
		      <<"CANCEL">>, CancelID, Nonce, Timestamp),
    CancelSignature = crypto:sign(
		        eddsa, none, CancelPayload, [PrivateKey, ed25519]),
    ?assertMatch({200, _, _},
		 cancel_session(CancelID,
				signed_json(Nonce, Timestamp,
					    CancelSignature), State)),
    ?assertEqual([], ets:lookup(Sessions, CancelID)),
    ets:delete(Sessions).

signed_json(Nonce, Timestamp, Signature) ->
    encode_json(#{<<"nonce">> => Nonce,
		  <<"timestamp">> => Timestamp,
		  <<"signature">> => base64:encode(Signature)}).

persistent_registry_test_() ->
    case mnesia:system_info(is_running) of
	no ->
	    {setup, fun setup_registry_fixture/0, fun cleanup_registry_fixture/1,
	     fun registry_survives_mnesia_restart/1};
	_ ->
	    %% Never alter a Mnesia instance owned by a wider test suite.
	    []
    end.

setup_registry_fixture() ->
    OldDirectory = application:get_env(mnesia, dir),
    Directory = filename:absname(
		  filename:join(
		    ["_build", "maer_pairing_mnesia_" ++
			   integer_to_list(
			     erlang:unique_integer([positive]))])),
    ok = application:set_env(mnesia, dir, Directory),
    ok = mnesia:create_schema([node()]),
    ok = application:start(mnesia),
    ok = ensure_device_table(),
    {Directory, OldDirectory}.

cleanup_registry_fixture({Directory, OldDirectory}) ->
    case mnesia:system_info(is_running) of
	yes ->
	    _ = mnesia:delete_table(?DEVICE_TABLE),
	    ok = application:stop(mnesia);
	_ -> ok
    end,
    _ = mnesia:delete_schema([node()]),
    case OldDirectory of
	{ok, Value} -> ok = application:set_env(mnesia, dir, Value);
	undefined -> ok = application:unset_env(mnesia, dir)
    end,
    _ = file:del_dir_r(Directory),
    ok.

registry_survives_mnesia_restart(Setup) ->
    fun() -> exercise_registry_restart(Setup) end.

exercise_registry_restart(_Setup) ->
    Now = erlang:system_time(second),
    JID = <<"alice@xmpp.maer.fr">>,
    Device = #maer_pairing_device{
	key = {JID, <<"device-00000001">>}, jid = JID,
	device_id = <<"device-00000001">>, label = <<"PC Atelier">>,
	platform = <<"windows">>, token = <<"oauth-secret">>,
	token_hash = crypto:hash(sha256, <<"oauth-secret">>),
	created_at = Now, expires_at = Now + 3600},
    ?assertEqual(ok, store_device(Device, 1, Now)),
    ?assertMatch({ok, #maer_pairing_device{label = <<"PC Atelier">>}},
		 lookup_device(JID, <<"device-00000001">>)),
    Other = Device#maer_pairing_device{
	key = {JID, <<"device-00000002">>},
	device_id = <<"device-00000002">>, token = <<"other-token">>,
	token_hash = crypto:hash(sha256, <<"other-token">>)},
    ?assertEqual({error, device_limit}, store_device(Other, 1, Now)),
    ?assertEqual(ok, mark_revocation_pending(Device)),

    ok = application:stop(mnesia),
    ok = application:start(mnesia),
    ok = wait_for_device_table(),
    ?assertMatch({ok, #maer_pairing_device{
			 token = <<"oauth-secret">>, revocation_pending = true}},
		 lookup_device(JID, <<"device-00000001">>)),
    ?assertMatch({ok, [#maer_pairing_device{}]}, list_devices(JID, Now)),
    exercise_concurrent_approval(Now),
    ok.

exercise_concurrent_approval(Now) ->
    meck:new(ejabberd_oauth, [unstick]),
    try
	meck:expect(
	  ejabberd_oauth, oauth_issue_token,
	  fun("alice@xmpp.maer.fr", 60, [<<"sasl_auth">>]) ->
		  Suffix = integer_to_binary(
			     erlang:unique_integer([positive])),
		  {<<"concurrent-token-", Suffix/binary>>,
		   [<<"sasl_auth">>], "60 seconds"}
	  end),
	Sessions = ets:new(maer_pairing_concurrent_approval,
			   [set, public, {keypos, #pair_session.id}]),
	ID = url_token(24),
	Code = <<"654321">>,
	true = ets:insert(
		 Sessions,
		 #pair_session{id = ID, verification_code = Code,
			       poll_nonce = url_token(24),
			       public_key = crypto:strong_rand_bytes(32),
			       device_name = <<"PC Concurrent">>,
			       platform = <<"windows">>, app_version = <<"1.0.0">>,
			       client_ip = {127, 0, 0, 1}, expires_at = Now + 300}),
	State = #state{sessions = Sessions, token_ttl = 60,
		       max_devices_per_account = 100},
	From = jid:make(<<"alice">>, ?CANONICAL_HOST, <<"android">>),
	IQ = #iq{type = set, from = From,
		 to = jid:make(<<>>, ?CANONICAL_HOST, <<>>), id = <<"pair">>},
	Server = spawn(fun() -> approval_test_loop(State) end),
	Parent = self(),
	Caller = fun() ->
		 Ref = make_ref(),
		 Server ! {approve, self(), Ref, IQ, From, ID, Code},
		 receive {Ref, Reply} -> Parent ! {approval_result, Reply} end
	 end,
	spawn(Caller),
	spawn(Caller),
	Types = lists:sort([receive_approval_type(), receive_approval_type()]),
	?assertEqual([error, result], Types),
	?assertEqual(1, meck:num_calls(ejabberd_oauth, oauth_issue_token, 3)),
	ServerMonitor = erlang:monitor(process, Server),
	Server ! stop,
	receive {'DOWN', ServerMonitor, process, Server, normal} -> ok
	after 1000 -> error(approval_test_server_did_not_stop)
	end,
	ets:delete(Sessions)
    after
	meck:unload(ejabberd_oauth)
    end.

approval_test_loop(State) ->
    receive
	{approve, Caller, Ref, IQ, From, ID, Code} ->
	    {Reply, NewState} = approve_session(IQ, From, ID, Code, State),
	    Caller ! {Ref, Reply},
	    approval_test_loop(NewState);
	stop -> ok
    end.

receive_approval_type() ->
    receive
	{approval_result, #iq{type = Type}} -> Type
    after 2000 ->
	error(concurrent_approval_timeout)
    end.

targeted_connection_lifecycle_test() ->
    Worker = fun Loop() -> receive stop -> ok; _ -> Loop() end end,
    PidA1 = spawn(Worker),
    PidA2 = spawn(Worker),
    PidB = spawn(Worker),
    DeviceA = {<<"alice@xmpp.maer.fr">>, <<"same-device-id">>},
    DeviceB = {<<"bob@xmpp.maer.fr">>, <<"same-device-id">>},
    State0 = #state{},
    State1 = add_connection(DeviceA, PidA1, State0),
    State2 = add_connection(DeviceA, PidA2, State1),
    State3 = add_connection(DeviceB, PidB, State2),
    %% Reusing the same device/PID must not allocate another monitor.
    State3 = add_connection(DeviceA, PidA1, State3),
    ?assertEqual(3, map_size(State3#state.monitors)),
    RefA1 = maps:get(PidA1, maps:get(DeviceA, State3#state.connections)),
    exit(PidA1, kill),
    State4 = receive
	{'DOWN', RefA1, process, PidA1, _} ->
	    remove_connection_monitor(RefA1, State3)
    after 1000 ->
	error(missing_process_monitor)
    end,
    ?assertEqual(1, map_size(maps:get(DeviceA, State4#state.connections))),
    State5 = kick_device_connections(DeviceA, State4),
    ?assertNot(maps:is_key(DeviceA, State5#state.connections)),
    ?assert(maps:is_key(DeviceB, State5#state.connections)),
    PidA2 ! stop,
    PidB ! stop,
    maps:foreach(fun(Ref, _) -> erlang:demonitor(Ref, [flush]) end,
		 State5#state.monitors).

expired_device_closes_only_its_connections_test() ->
    Worker = fun Loop() -> receive stop -> ok; _ -> Loop() end end,
    ExpiredPid = spawn(Worker),
    ActivePid = spawn(Worker),
    ExpiredKey = {<<"alice@xmpp.maer.fr">>, <<"expired-device">>},
    ActiveKey = {<<"alice@xmpp.maer.fr">>, <<"active-device">>},
    State0 = add_connection(
	       ExpiredKey, ExpiredPid,
	       add_connection(ActiveKey, ActivePid, #state{})),
    Expired = #maer_pairing_device{
	key = ExpiredKey,
	jid = <<"alice@xmpp.maer.fr">>, device_id = <<"expired-device">>,
	label = <<"PC">>, platform = <<"windows">>, token = <<"secret">>,
	token_hash = crypto:hash(sha256, <<"secret">>), created_at = 1,
	expires_at = 9},
    Active = Expired#maer_pairing_device{
	key = ActiveKey,
	device_id = <<"active-device">>, expires_at = 11},
    Parent = self(),
    Revoke = fun(Token) -> Parent ! {revoked, Token}, ok end,
    Delete = fun(Key) -> Parent ! {deleted, Key}, ok end,
    State1 = cleanup_device_records([Expired, Active], 10, State0,
				    Revoke, Delete),
    ?assertNot(maps:is_key(ExpiredKey, State1#state.connections)),
    ?assert(maps:is_key(ActiveKey, State1#state.connections)),
	receive {revoked, <<"secret">>} -> ok
	after 1000 -> error(expired_token_not_revoked)
	end,
	receive
	    {deleted, {<<"alice@xmpp.maer.fr">>, <<"expired-device">>}} -> ok
	after 1000 -> error(expired_device_not_deleted)
	end,
    ExpiredPid ! stop,
    ActivePid ! stop,
    maps:foreach(fun(Ref, _) -> erlang:demonitor(Ref, [flush]) end,
		 State1#state.monitors).

pending_revocation_is_retried_and_kept_test() ->
    Worker = fun Loop() -> receive stop -> ok; _ -> Loop() end end,
    Pid = spawn(Worker),
    Key = {<<"alice@xmpp.maer.fr">>, <<"pending-device">>},
    State0 = add_connection(Key, Pid, #state{}),
    Device = #maer_pairing_device{
	key = Key, jid = <<"alice@xmpp.maer.fr">>,
	device_id = <<"pending-device">>, label = <<"PC">>,
	platform = <<"windows">>, token = <<"pending-secret">>,
	token_hash = crypto:hash(sha256, <<"pending-secret">>),
	created_at = 1, revocation_pending = true, expires_at = 100},
    Parent = self(),
    Revoke = fun(Token) -> Parent ! {retry, Token}, {error, unavailable} end,
    Delete = fun(Key0) -> Parent ! {unexpected_delete, Key0}, ok end,
    State1 = cleanup_device_records([Device], 10, State0, Revoke, Delete),
    ?assertNot(maps:is_key(Key, State1#state.connections)),
    receive {retry, <<"pending-secret">>} -> ok
    after 1000 -> error(revocation_was_not_retried)
    end,
    receive {unexpected_delete, _} -> error(pending_tombstone_was_deleted)
    after 25 -> ok
    end,
    Pid ! stop,
    maps:foreach(fun(Ref, _) -> erlang:demonitor(Ref, [flush]) end,
		 State1#state.monitors).

-endif.
