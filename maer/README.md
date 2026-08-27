# MAER XMPP Server

`MAER XMPP Server` est le nom de distribution du service XMPP exploité par
MAER Engineering. La base technique reste **ejabberd** et ses identifiants
internes (`ejabberd`, `ejabberdctl`, modules Erlang) ne sont pas renommés afin
de rester compatibles avec l’amont.

Ce répertoire contient uniquement la couche d’intégration MAER : catalogue
public des organisations, modèles de configuration et documentation
d’exploitation. Il ne contient aucun secret.

Client Android associé :
[Maer Chat](https://github.com/jeff-net52/MaerChat). Le client et ce serveur
emploient le même schéma public d’organisation ; le serveur reste l’autorité
pour l’authentification, l’abonnement et l’isolation des données.

## Licence et provenance

- ejabberd est distribué sous GNU GPL v2 ; l’exception de liaison OpenSSL
  placée en tête de `COPYING` reste applicable ;
- `COPYING`, les avis de copyright ProcessOne/auteurs et l’historique Git
  doivent rester intacts ;
- les modifications MAER distribuées avec le serveur restent sous GNU GPL v2 ;
- « MAER XMPP Server » désigne la distribution et le service. Ce nom ne doit
  pas masquer que le logiciel serveur sous-jacent est ejabberd ;
- faire payer l’hébergement, l’administration, le support ou l’accès au
  service est distinct de la licence du code source.

Amont conservé : <https://github.com/processone/ejabberd>.

## Organisation des fichiers

- `catalog/organizations.example.json` : métadonnées publiques consommables
  par Maer Chat ;
- `catalog/organizations.schema.json` : contrat strict du catalogue ;
- `config/ejabberd.multi-organization.yml.example` : base fonctionnelle pour
  plusieurs virtual hosts, à fusionner avec les certificats et listeners du
  modèle amont ;
- `config/ejabberd.pairing.yml.example` : activation minimale du handler HTTPS
  et de `mod_maer_pairing` sur le listener TLS 5443 ;
- `docs/MULTI_ORGANIZATION.md` : modèle de cloisonnement et procédure
  d’ajout/retrait d’un client ;
- `docs/PAIRING_SERVER.md` : architecture, garanties de sécurité, limites et
  validation de l’association QR Windows/Android.

Avant toute mise en production, partir d’un tag stable ejabberd, conserver le
remote `upstream`, valider la configuration avec la version réellement
déployée, sauvegarder la configuration et la base, puis tester avec des comptes
dédiés. Le HEAD de développement n’est pas une version de production.

Le modèle rend les salons privés et réservés aux comptes locaux par défaut. Le
listener HTTPS ejabberd, ou le proxy placé devant celui-ci, doit relier
`/http-bind`, `/xmpp-websocket`, les documents `/.well-known/host-meta` et
`/upload` aux handlers indiqués dans le modèle, sans remplacer les listeners
client XMPP existants. L’API `/maer-pairing/v1` doit rester sur le listener TLS
5443 et ne doit jamais être montée sur l’interface administrative 5280.
