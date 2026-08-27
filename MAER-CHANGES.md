# Changements MAER

## Non publié

- ajout de `mod_maer_pairing`, pièce serveur du protocole d’association QR v1
  entre MAER Chat Windows et Android : session HTTPS signée Ed25519,
  approbation XMPP authentifiée et jeton OAuth limité à `sasl_auth` ;
- ajout d’un registre Mnesia persistant des appareils liés, de leur liste et
  révocation ciblée, avec fermeture immédiate des connexions suivies ;
- ajout d’un hook OAuth best-effort dans `ejabberd_c2s` qui transmet uniquement
  l’empreinte SHA-256 du jeton au registre d’appareils ;
- ajout de limites de débit par IP, par compte et globales, nettoyage des
  sessions/appareils expirés, validation stricte JSON/XML et tests de sécurité
  ciblés OTP 27 ;
- ajout du fragment de configuration TLS 5443 et du guide d’exploitation de
  l’association ;
- remplacement du domaine historique par le domaine canonique
  `xmpp.maer.fr` dans le catalogue et le modèle multi-organisation ;
- ajout au modèle des modules BOSH et XEP-0156, avec les chemins publics
  `/http-bind`, `/xmpp-websocket` et `/.well-known/host-meta` attendus par le
  client Windows.

## 0.1.0 — 22 août 2026 — base ejabberd 26.07

- ajout de l’identité de distribution « MAER XMPP Server — basé sur ejabberd
  Community Server » ;
- ajout d’un catalogue public strict d’organisations, sans secret ;
- ajout d’un modèle ejabberd multi-organisation par virtual hosts ;
- configuration cible documentée pour PEP/avatars, MAM, Carbons, Stream
  Management, upload HTTP, vCard et salons MUC ;
- inscription XMPP publique et push volontairement absents du modèle ;
- distinction documentée entre séparation mutualisée logique et déploiement
  dédié par client ;
- ajout des procédures de provenance, synchronisation amont, sécurité et
  marque.

Cette première couche n’altère pas le cœur Erlang d’ejabberd. La configuration
de production doit être adaptée uniquement après identification et sauvegarde
de la version et du stockage réellement exploités.
