# Association sécurisée MAER Chat

`mod_maer_pairing` implémente le contrat d'association v1 entre MAER Chat
Windows, MAER Chat Android et MAER XMPP Server. Il est volontairement limité
au virtual host canonique `xmpp.maer.fr`.

Le poste Windows crée une session HTTPS éphémère et affiche un QR contenant
uniquement l'hôte, l'identifiant de session et un code à six chiffres.
L'application Android inspecte puis approuve cette session au moyen de sa
connexion XMPP déjà authentifiée. Le jeton OAuth `sasl_auth` est livré
uniquement au poste capable de signer la consultation avec la clé Ed25519
éphémère enregistrée à la création.

## Activation

Le fragment [`../config/ejabberd.pairing.yml.example`](../config/ejabberd.pairing.yml.example)
montre les deux éléments requis :

```yaml
listen:
  -
    port: 5443
    module: ejabberd_http
    tls: true
    request_handlers:
      /maer-pairing: mod_maer_pairing

modules:
  mod_maer_pairing: {}
```

Le chemin externe est `https://xmpp.maer.fr/maer-pairing/v1`. Le listener
5443 doit présenter un certificat valide, ou être joint par un reverse proxy
TLS qui vérifie également le certificat du listener. Le handler ne doit jamais
être ajouté au listener administratif 5280. Un accès HTTP en clair reçoit une
réponse 426 et n'est pas redirigé.

Le reverse proxy doit remplacer, et non concaténer, tout en-tête d'adresse
client transmis à ejabberd. Sinon un client pourrait contourner la limite par
IP en fournissant lui-même un en-tête falsifié. Il faut conserver une seconde
limite au niveau du reverse proxy, fixer le corps maximal à 16 Kio et
synchroniser l'horloge du NAS par NTP.

## Propriétés de sécurité

- seules les IQ provenant d'un JID complet, local, actif et authentifié sur
  `xmpp.maer.fr` peuvent inspecter, approuver, lister ou révoquer ;
- les IQ acceptent une forme XML exacte et refusent attributs ou enfants
  supplémentaires ; une session inconnue et un mauvais code produisent la
  même erreur générique ;
- les consultations et annulations HTTPS vérifient le nonce, une date UTC à
  ±30 secondes et une signature Ed25519 canonique ;
- les corps JSON, clés SPKI, encodages base64, identifiants et libellés sont
  strictement bornés ; codes et nonces sont comparés en temps constant ;
- les sessions en attente vivent uniquement en mémoire pendant cinq minutes ;
  les appareils liés sont conservés dans une table Mnesia `disc_copies` ;
- le jeton émis ne porte que la portée OAuth `sasl_auth`. Le hook
  d'authentification ne transmet au module qu'une empreinte SHA-256, jamais le
  bearer token ; une panne du module optionnel ne bloque pas une
  authentification OAuth par ailleurs valide ;
- une révocation cible toutes les connexions XMPP suivies pour cet appareil,
  sans fermer celles des autres appareils ; suppression du compte et changement
  de mot de passe révoquent tous ses appareils liés. Si le backend OAuth est
  momentanément indisponible, une marque de révocation persistante ferme les
  connexions, bloque les reconnexions utilisables et déclenche des tentatives
  périodiques jusqu’à la suppression effective du jeton ;
- les réponses interdisent la mise en cache et aucune erreur ne contient de
  jeton.

Les jetons OAuth doivent rester disponibles en clair dans le stockage privé du
serveur afin que l'API ejabberd puisse les révoquer. Les permissions du paquet,
les sauvegardes Mnesia et leurs exports doivent donc être traités comme des
secrets. Les logs ne doivent jamais inclure le contenu des requêtes de
consultation ni les enregistrements Mnesia.

## Exploitation et limites connues

Les sessions d'association et la carte des connexions actives sont locales au
nœud Erlang. Le paquet Synology cible un seul nœud ; un déploiement ejabberd en
cluster demanderait un routage persistant des requêtes d'une session vers son
nœud créateur et une diffusion de la révocation des connexions. Les appareils
et jetons restent, eux, persistants après redémarrage. Un redémarrage complet
d'ejabberd ferme naturellement toutes les connexions ; une simple recharge du
module ne doit pas être utilisée comme mécanisme de révocation.

Une association approuvée reste consultable plusieurs fois avec la preuve
signée correcte jusqu'à l'expiration de sa session courte. Cette idempotence est
nécessaire lorsque la réponse réseau initiale est perdue. À l'expiration, la
session et le jeton qu'elle contenait en mémoire sont effacés ; le registre
d'appareils conserve seulement le jeton persistant jusqu'à sa révocation ou son
expiration OAuth.

## Validation

Dans un environnement de construction OTP 27 :

```sh
./rebar3 compile
./rebar3 eunit -m mod_maer_pairing,maer_pairing_oauth_hook_tests --cover=false -v
```

Les tests ciblent notamment les signatures réelles, nonce et date invalides,
polling rejoué, annulation, formes JSON/XML strictes, plafonds par IP et global,
plusieurs PID par appareil, disparition d'un PID, révocation ciblée, expiration
avec fermeture de connexion, persistance Mnesia après redémarrage et isolement
du hook OAuth.

Avant publication, exécuter également un scénario de bout en bout avec deux
comptes de test et deux postes liés : approbation Android, authentification
Windows `X-OAUTH2`, révocation d'un seul poste, rejet de sa reconnexion et
maintien de la connexion de l'autre. Vérifier ensuite les journaux et rapports
de panne pour confirmer l'absence de QR, nonce, signature et jeton OAuth.
