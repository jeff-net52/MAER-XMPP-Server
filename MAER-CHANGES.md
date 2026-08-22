# Changements MAER

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
