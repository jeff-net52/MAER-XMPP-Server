# MAER XMPP Server — deployment report 26.07.0-8

Deployment date: 2026-08-27 (Europe/Paris)

## Result

`maerxmppserver` version `26.07.0-8` is installed on Synology DSM, volume 2,
and DSM reports the package as running.

The public canonical service is `xmpp.maer.fr`. No compatibility alias for
`contacts.chaumont.me` is configured or required.

## Incident fixed

Revision 7 started its loopback HTTP listener on `127.0.0.1:5080`, but every
request crashed in `ejabberd_http:code_to_phrase(308)`. Ejabberd 26.07 does not
provide a phrase for status 308, so DSM returned 502 through its reverse proxy.

`mod_maer_redirect` now returns the ejabberd-compatible permanent status 301.
The source validation gate requires `{301,` and rejects any reintroduction of
`{308,`.

## Package evidence

- SPK: `maerxmppserver_armada38x-7.1_26.07.0-8.spk`
- Size: `16240640` bytes
- SHA-256: `2DCCDA1ED06230906FA09AEC2D978DF1800A83221DF9D824E4F9E2E0ABA8AD3C`
- Two consecutive builds produced the same byte-for-byte SHA-256.
- `validate-source.ps1`: passed.
- `release-gate.ps1`: passed.
- DSM `preinst`: exit 0.
- DSM `postinst`: exit 0.
- DSM installation result: `success: true`.

The DSM installation transcript is archived on the publication share as
`server/DSM-XMPP-INSTALL-REV8.txt`.

## Live checks after installation

| Check | Result |
| --- | --- |
| DSM package version | `26.07.0-8` |
| DSM package state | Running |
| `GET http://xmpp.maer.fr/` | `301` |
| `GET https://xmpp.maer.fr/.well-known/host-meta` | `200` |
| `GET https://xmpp.maer.fr/.well-known/host-meta.json` | `200` |
| `OPTIONS https://xmpp.maer.fr/maer-pairing/v1/sessions` | `204` |
| Public TCP `xmpp.maer.fr:5222` | Reachable |
| `dsm-publication-preflight.ps1` | Passed |

## Operational cleanup

Revision 7 and all of its package data were removed before installing revision
8. The one-shot root installation task was deleted after a successful run so it
cannot execute again on its former schedule.
