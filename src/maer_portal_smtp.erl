%%%----------------------------------------------------------------------
%%% Minimal TLS-only SMTP transport for the MAER Chat account portal.
%%%
%%% The transport deliberately supports implicit TLS only.  Keeping STARTTLS
%%% and plaintext modes out of this module makes a configuration mistake fail
%%% closed instead of exposing SMTP credentials on the network.
%%%----------------------------------------------------------------------

-module(maer_portal_smtp).

-export([configured/1, send/5]).

-include_lib("kernel/include/file.hrl").

-define(MAX_REPLY_LINES, 100).

-spec configured(map()) -> boolean().
configured(Opts) when is_map(Opts) ->
    Host = maps:get(smtp_host, Opts, <<>>),
    Port = maps:get(smtp_port, Opts, 465),
    User = maps:get(smtp_username, Opts, <<>>),
    PasswordFile = maps:get(smtp_password_file, Opts, <<>>),
    From = maps:get(smtp_from, Opts, <<>>),
    Timeout = maps:get(smtp_timeout, Opts, 10000),
    valid_host(Host) andalso valid_port(Port) andalso valid_address(From) andalso
    valid_timeout(Timeout) andalso
    case auth_shape(User, PasswordFile) of
        no_auth -> true;
        password_file -> password_file_available(PasswordFile);
        invalid -> false
    end;
configured(_) -> false.

-spec send(map(), binary(), binary(), binary(), binary()) ->
          ok | {error, not_configured | invalid_configuration |
                       credentials_unavailable | tls_failed | smtp_rejected}.
send(Opts, Recipient, Subject, Body, MessageID)
  when is_map(Opts), is_binary(Recipient), is_binary(Subject),
       is_binary(Body), is_binary(MessageID) ->
    process_flag(sensitive, true),
    case smtp_config(Opts) of
        {ok, Config} ->
            deliver(Config, Recipient, Subject, Body, MessageID);
        Error ->
            Error
    end.

smtp_config(Opts) ->
    Host = maps:get(smtp_host, Opts, <<>>),
    Port = maps:get(smtp_port, Opts, 465),
    User = maps:get(smtp_username, Opts, <<>>),
    PasswordFile = maps:get(smtp_password_file, Opts, <<>>),
    From = maps:get(smtp_from, Opts, <<>>),
    Timeout = maps:get(smtp_timeout, Opts, 10000),
    case {valid_host(Host), valid_port(Port), valid_address(From),
          valid_timeout(Timeout), auth_shape(User, PasswordFile)} of
        {false, _, _, _, _} when Host =:= <<>> ->
            {error, not_configured};
        {true, true, true, true, no_auth} ->
            {ok, #{host => Host, port => Port, username => <<>>,
                   password => <<>>, from => From, timeout => Timeout}};
        {true, true, true, true, password_file} ->
            case read_password(PasswordFile) of
                {ok, Password} ->
                    {ok, #{host => Host, port => Port, username => User,
                           password => Password, from => From,
                           timeout => Timeout}};
                error ->
                    {error, credentials_unavailable}
            end;
        _ ->
            {error, invalid_configuration}
    end.

auth_shape(<<>>, <<>>) -> no_auth;
auth_shape(User, File) when User =/= <<>>, File =/= <<>> -> password_file;
auth_shape(_, _) -> invalid.

valid_host(Host) when is_binary(Host), byte_size(Host) =< 253 ->
    no_control_chars(Host) andalso
    re:run(Host, <<"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$">>,
           [{capture, none}]) =:= match;
valid_host(_) -> false.

valid_port(Port) -> is_integer(Port) andalso Port > 0 andalso Port < 65536.
valid_timeout(Timeout) ->
    is_integer(Timeout) andalso Timeout >= 1000 andalso Timeout =< 60000.

valid_address(Address) when is_binary(Address), byte_size(Address) =< 254 ->
    no_control_chars(Address) andalso
    re:run(Address,
           <<"^[A-Za-z0-9.!#$%&'*+/=?^_{}|~-]+@[A-Za-z0-9.-]+$">>,
           [{capture, none}]) =:= match;
valid_address(_) -> false.

no_control_chars(Value) ->
    re:run(Value, <<"[\\x00-\\x1f\\x7f]">>, [{capture, none}]) =:= nomatch.

read_password(Path) when is_binary(Path), byte_size(Path) =< 4096 ->
    File = binary_to_list(Path),
    case file:read_link_info(File) of
        {ok, #file_info{type = regular, mode = Mode, size = Size}}
          when Size > 0, Size =< 4096, (Mode band 8#027) =:= 0 ->
            case file:read_file(File) of
                {ok, Raw} ->
                    Password = strip_one_line_ending(Raw),
                    case Password =/= <<>> andalso no_control_chars(Password) of
                        true -> {ok, Password};
                        false -> error
                    end;
                _ -> error
            end;
        _ -> error
    end;
read_password(_) -> error.

password_file_available(Path) when is_binary(Path), byte_size(Path) =< 4096 ->
    case file:read_link_info(binary_to_list(Path)) of
        {ok, #file_info{type = regular, mode = Mode, size = Size}} ->
            Size > 0 andalso Size =< 4096 andalso (Mode band 8#027) =:= 0;
        _ -> false
    end;
password_file_available(_) -> false.

strip_one_line_ending(Value) ->
    Size = byte_size(Value),
    case Size >= 2 andalso binary:part(Value, Size - 2, 2) =:= <<"\r\n">> of
        true -> binary:part(Value, 0, Size - 2);
        false ->
            case Size >= 1 andalso binary:part(Value, Size - 1, 1) =:= <<"\n">> of
                true -> binary:part(Value, 0, Size - 1);
                false -> Value
            end
    end.

deliver(#{host := Host, port := Port, timeout := Timeout} = Config,
        Recipient, Subject, Body, MessageID) ->
    case valid_address(Recipient) andalso safe_header(Subject) andalso
         safe_header(MessageID) of
        false ->
            {error, invalid_configuration};
        true ->
            TLSOpts = [{active, false},
                       {packet, line},
                       {verify, verify_peer},
                       {cacertfile, path_list(pkix:get_cafile())},
                       {server_name_indication, binary_to_list(Host)},
                       {customize_hostname_check,
                        [{match_fun,
                          public_key:pkix_verify_hostname_match_fun(https)}]},
                       {versions, ['tlsv1.2', 'tlsv1.3']}],
            case ssl:connect(binary_to_list(Host), Port, TLSOpts, Timeout) of
                {ok, Socket} ->
                    Result = smtp_dialog(Socket, Config, Recipient, Subject,
                                         Body, MessageID),
                    _ = ssl:close(Socket),
                    Result;
                _ ->
                    {error, tls_failed}
            end
    end.

path_list(Path) when is_binary(Path) -> binary_to_list(Path);
path_list(Path) -> Path.

safe_header(Value) ->
    is_binary(Value) andalso byte_size(Value) =< 998 andalso
    no_control_chars(Value).

smtp_dialog(Socket, #{host := Host, username := User, password := Password,
                      from := From, timeout := Timeout},
            Recipient, Subject, Body, MessageID) ->
    case expect(Socket, 220, Timeout) of
        ok ->
            with_command(Socket, <<"EHLO ", Host/binary>>, 250, Timeout,
              fun() ->
                  authenticate(Socket, User, Password, Timeout,
                    fun() ->
                        with_command(Socket, <<"MAIL FROM:<", From/binary, ">">>,
                                     250, Timeout,
                          fun() ->
                              with_command(Socket,
                                           <<"RCPT TO:<", Recipient/binary, ">">>,
                                           [250, 251], Timeout,
                                fun() ->
                                    with_command(Socket, <<"DATA">>, 354,
                                                 Timeout,
                                      fun() ->
                                          send_message(Socket, From, Recipient,
                                                       Subject, Body, MessageID,
                                                       Timeout)
                                      end)
                                end)
                          end)
                    end)
              end);
        error -> {error, smtp_rejected}
    end.

authenticate(_Socket, <<>>, <<>>, _Timeout, Next) -> Next();
authenticate(Socket, User, Password, Timeout, Next) ->
    Credentials = base64:encode(<<0, User/binary, 0, Password/binary>>),
    with_command(Socket, <<"AUTH PLAIN ", Credentials/binary>>, 235,
                 Timeout, Next).

with_command(Socket, Command, Codes, Timeout, Next) ->
    case ssl:send(Socket, [Command, "\r\n"]) of
        ok ->
            case expect(Socket, Codes, Timeout) of
                ok -> Next();
                error -> {error, smtp_rejected}
            end;
        _ -> {error, smtp_rejected}
    end.

send_message(Socket, From, Recipient, Subject, Body, MessageID, Timeout) ->
    Message = [<<"From: ">>, From, <<"\r\nTo: ">>, Recipient,
               <<"\r\nSubject: ">>, Subject,
               <<"\r\nMessage-ID: <">>, MessageID, <<"@xmpp.maer.fr>\r\n">>,
               <<"MIME-Version: 1.0\r\n">>,
               <<"Content-Type: text/plain; charset=UTF-8\r\n">>,
               <<"Content-Transfer-Encoding: 8bit\r\n\r\n">>,
               dot_stuff(Body), <<"\r\n.\r\n">>],
    case ssl:send(Socket, Message) of
        ok ->
            case expect(Socket, 250, Timeout) of
                ok ->
                    _ = ssl:send(Socket, <<"QUIT\r\n">>),
                    ok;
                error -> {error, smtp_rejected}
            end;
        _ -> {error, smtp_rejected}
    end.

dot_stuff(Body) ->
    Normalized0 = binary:replace(Body, <<"\r\n">>, <<"\n">>, [global]),
    Normalized = binary:replace(Normalized0, <<"\r">>, <<"\n">>, [global]),
    Lines = binary:split(Normalized, <<"\n">>, [global]),
    iolist_to_binary(lists:join(<<"\r\n">>,
                                [dot_stuff_line(Line) || Line <- Lines])).

dot_stuff_line(<<".", _/binary>> = Line) -> <<".", Line/binary>>;
dot_stuff_line(Line) -> Line.

expect(Socket, Codes, Timeout) when is_integer(Codes) ->
    expect(Socket, [Codes], Timeout);
expect(Socket, Codes, Timeout) ->
    recv_reply(Socket, Codes, Timeout, ?MAX_REPLY_LINES).

recv_reply(_Socket, _Codes, _Timeout, 0) -> error;
recv_reply(Socket, Codes, Timeout, Remaining) ->
    case ssl:recv(Socket, 0, Timeout) of
        {ok, <<A, B, C, Sep, _/binary>>}
          when A >= $0, A =< $9, B >= $0, B =< $9, C >= $0, C =< $9 ->
            Code = (A - $0) * 100 + (B - $0) * 10 + (C - $0),
            case {lists:member(Code, Codes), Sep} of
                {true, $ } -> ok;
                {true, $-} ->
                    recv_reply(Socket, Codes, Timeout, Remaining - 1);
                _ -> error
            end;
        _ -> error
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

dot_stuff_test() ->
    ?assertEqual(<<"one\r\n..two\r\n...three">>,
                 dot_stuff(<<"one\n.two\r\n..three">>)).

address_validation_test() ->
    ?assert(valid_address(<<"person@example.org">>)),
    ?assertNot(valid_address(<<"person@example.org\r\nBcc:x@example.org">>)),
    ?assertNot(valid_address(<<"missing-at.example.org">>)).

host_validation_test() ->
    ?assert(valid_host(<<"smtp.example.org">>)),
    ?assertNot(valid_host(<<"smtp.example.org\r\n">>)).

missing_password_file_is_not_configured_test() ->
    Opts = #{smtp_host => <<"smtp.example.org">>, smtp_port => 465,
             smtp_username => <<"sender@example.org">>,
             smtp_password_file => <<"/definitely/missing/maer-smtp-password">>,
             smtp_from => <<"sender@example.org">>, smtp_timeout => 10000},
    ?assertNot(configured(Opts)).

-endif.
