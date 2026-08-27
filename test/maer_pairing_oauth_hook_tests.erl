%%%----------------------------------------------------------------------
%%% Tests for the small ejabberd_c2s OAuth hook used by MAER pairing.
%%%----------------------------------------------------------------------

-module(maer_pairing_oauth_hook_tests).

-include_lib("eunit/include/eunit.hrl").

oauth_pairing_hook_test_() ->
    {foreach,
     fun setup/0,
     fun cleanup/1,
     [fun valid_token_emits_only_fingerprint/0,
      fun invalid_token_never_emits_hook/0,
      fun faulty_optional_hook_cannot_break_valid_login/0]}.

setup() ->
    meck:new(ejabberd_oauth, [unstick]),
    meck:new(ejabberd_hooks, [unstick]),
    ok.

cleanup(_) ->
    meck:unload(ejabberd_hooks),
    meck:unload(ejabberd_oauth).

valid_token_emits_only_fingerprint() ->
    Parent = self(),
    User = <<"alice">>,
    Server = <<"xmpp.maer.fr">>,
    Token = <<"opaque-bearer-must-not-reach-the-hook">>,
    ExpectedHash = crypto:hash(sha256, Token),
    meck:expect(
      ejabberd_oauth, check_token,
      fun(User0, Server0, [<<"sasl_auth">>], Token0) ->
              ?assertEqual({User, Server, Token}, {User0, Server0, Token0}),
              true
      end),
    meck:expect(
      ejabberd_hooks, run,
      fun(c2s_oauth_authenticated, Server0,
          [Pid, User0, Server1, Fingerprint]) ->
              Parent ! {hook, Pid, User0, Server0, Server1, Fingerprint},
              ok
      end),
    Check = ejabberd_c2s:check_password_fun(
              <<"X-OAUTH2">>, #{lserver => Server}),
    ?assertEqual({true, ejabberd_oauth}, Check(User, <<>>, Token)),
    receive
        {hook, Pid, User, Server, Server, Fingerprint} ->
            ?assertEqual(self(), Pid),
            ?assertEqual(ExpectedHash, Fingerprint),
            ?assertNotEqual(Token, Fingerprint),
            ?assertEqual(32, byte_size(Fingerprint))
    after 1000 ->
        error(pairing_hook_not_called)
    end.

invalid_token_never_emits_hook() ->
    Parent = self(),
    Server = <<"xmpp.maer.fr">>,
    meck:expect(ejabberd_oauth, check_token, fun(_, _, _, _) -> false end),
    meck:expect(
      ejabberd_hooks, run,
      fun(_, _, _) -> Parent ! unexpected_pairing_hook, ok end),
    Check = ejabberd_c2s:check_password_fun(
              <<"X-OAUTH2">>, #{lserver => Server}),
    ?assertEqual(
       {false, ejabberd_oauth},
       Check(<<"alice">>, <<>>, <<"invalid-token">>)),
    receive
        unexpected_pairing_hook -> error(hook_called_for_invalid_token)
    after 25 ->
        ok
    end.

faulty_optional_hook_cannot_break_valid_login() ->
    Server = <<"xmpp.maer.fr">>,
    meck:expect(ejabberd_oauth, check_token, fun(_, _, _, _) -> true end),
    meck:expect(
      ejabberd_hooks, run,
      fun(_, _, _) -> error(simulated_pairing_module_failure) end),
    Check = ejabberd_c2s:check_password_fun(
              <<"X-OAUTH2">>, #{lserver => Server}),
    ?assertEqual(
       {true, ejabberd_oauth},
       Check(<<"alice">>, <<>>, <<"still-valid-token">>)).
