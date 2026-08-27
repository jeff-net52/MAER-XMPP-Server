%%%----------------------------------------------------------------------
%%% Canonical HTTP to HTTPS redirect endpoint for the DSM reverse proxy.
%%%
%%% Copyright (C) 2026 MAER contributors
%%% SPDX-License-Identifier: GPL-2.0-only WITH OpenSSL-exception
%%%----------------------------------------------------------------------

-module(mod_maer_redirect).

-export([process/2]).

-define(CANONICAL_ORIGIN, <<"https://xmpp.maer.fr/">>).

process(_Path, _Request) ->
    {308,
     [{<<"Location">>, ?CANONICAL_ORIGIN},
      {<<"Cache-Control">>, <<"no-store">>},
      {<<"Content-Security-Policy">>,
       <<"default-src 'none'; frame-ancestors 'none'">>},
      {<<"Referrer-Policy">>, <<"no-referrer">>},
      {<<"X-Content-Type-Options">>, <<"nosniff">>},
      {<<"X-Frame-Options">>, <<"DENY">>}],
     <<>>}.
