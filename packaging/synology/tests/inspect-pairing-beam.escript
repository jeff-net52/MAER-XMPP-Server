#!/usr/bin/env escript
%% Verify the stripped BEAM actually imports the two distinct XMPP conditions.
main([Beam]) ->
    {ok, {mod_maer_pairing, Chunks}} = beam_lib:chunks(Beam, [imports, atoms]),
    Imports = proplists:get_value(imports, Chunks),
    Atoms = [Atom || {_Index, Atom} <- proplists:get_value(atoms, Chunks)],
    true = lists:member({xmpp, err_policy_violation, 0}, Imports),
    true = lists:member({xmpp, err_resource_constraint, 0}, Imports),
    true = lists:member(iq_rate_limit_error, Atoms),
    true = lists:member(iq_device_limit_error, Atoms),
    io:format("EMBEDDED_BEAM_CONDITIONS=PASS~n");
main(_) ->
    io:format(standard_error, "usage: inspect-pairing-beam.escript PATH_TO_BEAM~n", []),
    halt(64).
