# Audit externe du serveur XMPP actuellement en production

Date de l'audit : **2026-08-27**
Fenêtre d'observation : **05:02–05:12 CEST** (`03:02–03:12 UTC`)
Horodatage de contrôle capturé : `2026-08-27T05:11:34.823+02:00` / `2026-08-27T03:11:34.823Z`
Contre-audit de reproductibilité EOL : `2026-08-27T05:42:39.947+02:00` / `2026-08-27T03:42:39.947Z`
Cible : `xmpp.maer.fr` (`82.67.146.209`)
Mode : sondes externes sûres et non authentifiées depuis Windows ; aucune installation, aucun arrêt de service et aucune modification du NAS.

## Résumé exécutif

Le transport XMPP principal est exploitable : le port 5222 répond, STARTTLS est obligatoire, TLS 1.2 et 1.3 fonctionnent, le certificat est valide pour `xmpp.maer.fr`, BOSH fonctionne réellement sur `https://xmpp.maer.fr/http-bind` et WebSocket effectue une vraie montée de protocole XMPP sur `wss://xmpp.maer.fr/xmpp-websocket`.

Le serveur **actuellement exposé n'est pas le candidat MAER XMPP Server**. Il s'agit de l'ancien service ejabberd (le précédent contrôle DSM indiquait le paquet SynoCommunity `ejabberd 23.10-3`; les sondes réseau identifient ejabberd sans exposer sa version exacte). L'association MAER et `host-meta` sont absents de la production actuelle. Le chemin HTTP Upload répond 404, mais un test de slot authentifié n'a pas été possible sans compte autorisé ; son absence ne peut donc pas être affirmée sur ce seul résultat.

Aucun compte de test n'a été créé. Le serveur annonce XEP-0077, mais deux demandes d'inscription avec des identifiants aléatoires ont été refusées par la politique du service. Les mots de passe ont été générés en mémoire, n'ont jamais été affichés et ont été abandonnés immédiatement.

Verdict avant bascule : **NO-GO fonctionnel pour la suite complète**, mais **socle XMPP actuel opérationnel**. L'installation et la publication du SPK candidat doivent désormais être suspendues jusqu'à correction du défaut de reproductibilité P1-07, reconstruction et nouvel audit. Son exposition HTTPS devra ensuite être corrigée ou confirmée : il annonce le port 5443, qui est actuellement inaccessible depuis Internet.

## Échelle de sévérité

| Niveau | Sens |
|---|---|
| P0 | compromission active, perte de données ou indisponibilité générale immédiate |
| P1 | blocage d'une fonction essentielle ou surface de sécurité importante à corriger avant livraison |
| P2 | défaut de sécurité, de compatibilité ou d'exploitation significatif |
| P3 | durcissement, cohérence ou comportement d'erreur à améliorer |

## Écarts relevés

### P0 — aucun

Aucun contournement d'authentification, certificat invalide, exposition d'API sans contrôle ou arrêt du service n'a été observé.

### P1

#### P1-01 — Association QR MAER absente du serveur actuel

- `OPTIONS https://xmpp.maer.fr/maer-pairing/v1/sessions` → `404 Not Found`, sans les en-têtes que produirait le module candidat.
- `POST {}` avec `Content-Type: application/json` sur ce chemin exact → `404 Not Found` HTML.
- Le chemin racine `/maer-pairing` répond lui aussi 404 en GET et POST.
- La réponse est la page 404 générique ejabberd : le gestionnaire MAER n'est pas chargé.
- Impact : l'association d'un nouvel appareil Windows/Android ne peut pas fonctionner contre la production actuelle.
- Candidat : `mod_maer_pairing` est configuré sur `/maer-pairing` dans le SPK, mais il n'a pas encore été testé sur le NAS.

#### P1-02 — HTTP Upload non validé faute de compte de test autorisé

- `GET https://xmpp.maer.fr/upload` → `404 Not Found`, corps `Not found.`.
- `OPTIONS https://xmpp.maer.fr/upload` → `404 Not Found`.
- `HEAD https://xmpp.maer.fr/upload/audit-never-created` → `404 Not Found` ; aucun fichier n'a été envoyé ou créé.
- Une requête `disco#items` avant authentification reçoit correctement `<not-authorized/>`. L'inscription publique étant refusée, aucun slot authentifié n'a pu être demandé.
- Un 404 à la racine d'un handler de fichiers peut être normal et ne prouve pas à lui seul que `mod_http_upload` est absent.
- Impact : le fonctionnement des pièces jointes du serveur actuel reste non démontré ; il faut un compte jetable provisionné par l'administration pour conclure.
- Candidat : `/upload` est configuré avec une limite de 50 MiB et une origine CORS MAER, à valider après installation.

#### P1-03 — Découverte automatique incomplète

- Aucun SRV `_xmpp-client._tcp.xmpp.maer.fr`.
- Aucun SRV `_xmpps-client._tcp.xmpp.maer.fr`.
- Aucun SRV `_xmpp-server._tcp.xmpp.maer.fr`.
- `GET /.well-known/host-meta` et `GET /.well-known/host-meta.json` → `404`.
- Les résultats NXDOMAIN ont été reproduits auprès de `1.1.1.1` et `8.8.8.8`.
- Impact : un client générique recevant seulement `utilisateur@xmpp.maer.fr` ne peut pas découvrir BOSH/WebSocket par les mécanismes standards. Les clients MAER codés pour 5222 peuvent toutefois se connecter.
- Candidat : `mod_host_meta` est prévu, mais ses URL annoncent actuellement `:5443`.

#### P1-04 — Administration ejabberd exposée publiquement

- `GET https://xmpp.maer.fr/admin/` → `401 Unauthorized` avec `WWW-Authenticate: basic realm="ejabberd"`.
- Le contrôle d'accès fonctionne, mais la surface d'administration et son mécanisme d'authentification sont accessibles depuis Internet.
- Impact : surface de brute force et d'exploitation inutile sur le frontal public.
- Candidat : l'administration est configurée uniquement sur `127.0.0.1:5280`, ce qui corrige le défaut si la configuration installée reste identique.

#### P1-05 — L'ancien domaine est toujours actif publiquement

- `[DOMAINE_RETIRE]` résout encore vers `82.67.146.209` auprès du résolveur local, de `1.1.1.1` et de `8.8.8.8`.
- `https://[DOMAINE_RETIRE]/` → `200 OK` et affiche la page d'accueil Synology Web Station.
- Un certificat Let's Encrypt valide couvre encore `[DOMAINE_RETIRE]` jusqu'au `2026-11-04T09:13:15Z`.
- Son SAN contient aussi `calendar.chaumont.me`, `chaumont.me`, `cloud.chaumont.me`, `file.chaumont.me`, `maison.chaumont.me` et `photos.chaumont.me`.
- Impact : violation de l'exigence de retrait total de ce domaine et maintien d'une surface Web Station inattendue.
- Remédiation : supprimer l'enregistrement DNS public, la règle de reverse proxy/vhost et le domaine du prochain renouvellement de certificat, après vérification de l'usage des autres SAN. Cette action n'a pas été effectuée pendant l'audit.

#### P1-06 — Incohérence d'exposition HTTPS du candidat SPK

- État public actuel : TCP 443 ouvert, TCP 5443 fermé/refusé.
- Le candidat configure et publie BOSH, WebSocket, `host-meta`, upload et pairing sur `https://xmpp.maer.fr:5443`.
- Son fichier de pare-feu DSM déclare 5443, mais cela ne garantit pas la redirection NAT du routeur.
- Impact : après installation, les fonctions HTTP du nouveau serveur pourraient rester injoignables depuis Internet même si le service démarre correctement.
- Décision requise avant bascule : soit ouvrir/rediriger 5443 vers le NAS, soit conserver 443 comme URL publique et router tous les chemins vers le listener interne 5443 ; les URL `host-meta` et `put_url` doivent correspondre au choix retenu.

#### P1-07 — Validation source du SPK non reproductible selon les fins de ligne

Le signalement Hermes a été reproduit exactement dans des checkouts temporaires du commit `8218fed1` :

- clone Windows propre avec `core.autocrlf=true` : **30 échecs** de `validate-source.ps1` ;
- checkout LF intégral avec `core.autocrlf=false` : **2 échecs**, les deux empreintes `COPYING` ;
- état hybride du répertoire de travail historique : **validation réussie**.

La majorité des 30 messages ne signifie pas que les fonctions sont réellement absentes : les expressions régulières du validateur terminées par `$` rencontrent un octet CR avant LF dans les Makefiles, recettes et YAML. Elles produisent donc des faux négatifs sur du contenu pourtant présent. En revanche, les deux erreurs d'empreinte sont un véritable défaut de contrat reproductible : `LOCKS.json` verrouille les octets CRLF de `COPYING`, tandis que le blob Git canonique contient des LF.

Impact : aucun clone propre standard ne reproduit actuellement le succès local, ni sous Windows CRLF ni sous Linux/LF. La revendication de build reproductible et la publication du candidat doivent être considérées **NO-GO** jusqu'à correction, nouvelle construction et nouvel audit. Cela ne démontre pas une compromission du binaire SPK déjà produit, mais invalide son chemin de validation reproductible ; gravité P1 de chaîne de livraison, pas P0 runtime.

### P2

#### P2-01 — Port serveur-à-serveur 5269 inutilement exposé

- TCP 5269 est ouvert publiquement.
- La négociation S2S annonce STARTTLS, mais sans élément `<required/>` avant TLS ; après TLS, SASL EXTERNAL et dialback sont annoncés.
- Impact : surface de fédération et de traitement de stanzas non nécessaire à l'objectif privé MAER.
- Candidat : `s2s_access` refuse tout et aucun listener 5269 n'est déclaré dans son profil ; il faudra confirmer que 5269 est réellement fermé après bascule.

#### P2-02 — HTTP clair et empreinte Synology exposés

- `http://xmpp.maer.fr/` sur le port 80 → `200 OK`, page `Hello! Welcome to Synology Web Station!`.
- Aucune redirection HTTPS n'est effectuée.
- Impact : exposition de la plateforme et risque de confusion pour un utilisateur qui saisit l'URL sans HTTPS.
- Remédiation : redirection 301/308 vers HTTPS ou fermeture du vhost public, sans casser les challenges ACME.

#### P2-03 — En-têtes de durcissement HTTPS absents

Les réponses testées sur `https://xmpp.maer.fr` ne contiennent pas `Strict-Transport-Security`, `Content-Security-Policy`, `X-Content-Type-Options` ni `X-Frame-Options`. Les endpoints protocolaires n'ont pas tous besoin d'une CSP, mais HSTS et le cloisonnement de la page d'administration sont recommandés au niveau du reverse proxy.

#### P2-04 — Mécanismes SASL hérités annoncés

Après STARTTLS sur 5222 et au démarrage WebSocket, le serveur annonce :

- `DIGEST-MD5` ;
- `PLAIN` ;
- `SCRAM-SHA-512` ;
- `SCRAM-SHA-256` ;
- `SCRAM-SHA-1` ;
- `X-OAUTH2`.

`PLAIN` reste protégé ici par TLS obligatoire, mais `DIGEST-MD5` et SCRAM-SHA-1 sont des choix hérités à retirer si aucun client ne les exige. Le candidat impose le stockage SCRAM-SHA-256 ; l'offre SASL effective devra néanmoins être vérifiée en exécution.

#### P2-05 — CORS BOSH/WebSocket très large

- BOSH répond `Access-Control-Allow-Origin: *` et autorise `GET, POST, OPTIONS`.
- WebSocket répond également avec une origine CORS générique sur sa page informative.
- Impact : toute application Web peut initier une connexion XMPP vers le service ; cela n'accorde pas de compte, mais augmente la surface d'abus.
- Remédiation : confirmer le besoin multi-origine ; sinon limiter aux origines MAER utilisées par les clients Web.

### P3

#### P3-01 — Inscription XEP-0077 annoncée mais systématiquement refusée

- Le flux pré-authentification contient `<register xmlns='http://jabber.org/features/iq-register'/>`.
- Le formulaire public contient `username` et `password`.
- Deux créations jetables ont toutes deux reçu `forbidden` et `Access denied by service policy`.
- Aucun compte n'a été créé et aucun nettoyage n'était nécessaire.
- Impact : des clients peuvent afficher une fonction d'inscription qui échoue ensuite.
- Candidat : `mod_register` n'est pas activé, comportement cohérent avec un provisioning administré.

#### P3-02 — Réponses d'erreur protocolaires perfectibles

- BOSH avec XML invalide → HTTP `400 Unexpected payload`, comportement correct.
- BOSH avec domaine cible invalide → HTTP `200` avec un corps XMPP `terminate condition='internal-server-error'` ; fonctionnel, mais peu précis pour le diagnostic.
- Une montée WebSocket volontairement invalide reçoit la page informative HTTP 200 au lieu d'une erreur 4xx.
- `TRACE` est correctement bloqué par nginx avec `405 Not Allowed`.

#### P3-03 — Pas d'IPv6 public ni de DNS pour les sous-domaines de service

- Aucun AAAA pour `xmpp.maer.fr`.
- `conference.xmpp.maer.fr` et `upload.xmpp.maer.fr` ne résolvent pas.
- Ce n'est pas bloquant pour un déploiement privé sans fédération, mais doit être documenté pour éviter de promettre une disponibilité IPv6 ou S2S/MUC publique.

## Matrice des ports

Observations externes vers `82.67.146.209` :

| Port | État | Observation |
|---:|---|---|
| 80/tcp | ouvert | Synology Web Station, sans redirection HTTPS |
| 443/tcp | ouvert | reverse proxy HTTPS ; ancien ejabberd sur les chemins XMPP |
| 5222/tcp | ouvert | XMPP client, STARTTLS obligatoire |
| 5269/tcp | ouvert | XMPP S2S, STARTTLS offert mais non déclaré obligatoire |
| 5280/tcp | fermé/refusé | bon résultat pour l'administration interne prévue |
| 5443/tcp | fermé/refusé | bloquant si les URL publiques du candidat conservent `:5443` |

Aucun balayage large de ports n'a été effectué ; seuls les ports XMPP/HTTP connus du projet ont été interrogés.

## Matrice des endpoints HTTPS actuels

| Test | Résultat | Verdict |
|---|---|---|
| `GET /` | 404 ejabberd | service atteint via le reverse proxy |
| `OPTIONS /http-bind` | 200, CORS `*` | BOSH exposé |
| `POST /http-bind` avec ouverture BOSH valide | 200, session temporaire créée | BOSH fonctionnel ; SID masqué, aucune authentification |
| `GET /http-bind` | 200, page informative `ejabberd mod_bosh` | handler présent |
| WebSocket RFC 6455 `/xmpp-websocket` | 101, `Sec-WebSocket-Accept` valide, sous-protocole `xmpp` | fonctionnel |
| Ouverture XMPP sur WebSocket | `<open/>` puis fonctionnalités SASL | fonctionnel sans authentification |
| `GET /.well-known/host-meta` | 404 | absent |
| `GET /.well-known/host-meta.json` | 404 | absent |
| `GET/OPTIONS /upload` | 404 | slot authentifié non testable ; résultat non conclusif sur le module |
| `OPTIONS/POST /maer-pairing/v1/sessions` | 404 HTML | handler MAER absent |
| `GET /admin/` | 401 Basic ejabberd | protégé mais publiquement exposé |
| `GET /api` | 404 | API HTTP non exposée |
| `TRACE /` | 405 nginx | correctement bloqué |

La session BOSH de test était non authentifiée, annonçait `inactivity='30'` et a expiré automatiquement. Son SID a été supprimé des preuves.

## TLS et certificats

### HTTPS 443

- Validation de chaîne et du nom : réussie.
- TLS 1.0 : refusé.
- TLS 1.1 : refusé.
- TLS 1.2 : accepté, `ECDHE-ECDSA-AES128-GCM-SHA256`.
- TLS 1.3 : accepté, `TLS_AES_256_GCM_SHA384`.
- Sujet : `CN=manager.maer.fr`.
- SAN : `manager.maer.fr`, `rtm.maer.fr`, `xmpp.maer.fr`.
- Émetteur : Let's Encrypt `YE1`.
- Validité : `2026-08-24T16:46:43Z` à `2026-11-22T16:46:42Z`.
- Empreinte SHA-256 : `304E71B5E54210858CB2CF7572EE524D324B2834CF3B7B5F4025E1178D49AE05`.

### XMPP STARTTLS 5222 et S2S 5269

- Validation de chaîne et du nom 5222 : réussie.
- STARTTLS 5222 : offert et obligatoire.
- TLS 1.0/1.1 : refusés.
- TLS 1.2 : accepté, `ECDHE-RSA-AES256-GCM-SHA384`.
- TLS 1.3 : accepté, `TLS_AES_256_GCM_SHA384`.
- Sujet : `CN=manager.maer.fr`.
- SAN : `manager.maer.fr`, `rtm.maer.fr`, `xmpp.maer.fr`.
- Émetteur : Let's Encrypt `YR2`.
- Validité : `2026-08-24T16:46:33Z` à `2026-11-22T16:46:32Z`.
- Empreinte SHA-256 : `F575122D9F6D99204477505961BDDEA763525A2095398A8B1582E6DA605D0D32`.
- 5269 présente le même profil de certificat et négocie TLS 1.3, mais STARTTLS n'est pas marqué obligatoire avant la négociation.

Deux certificats distincts mais valides sont donc utilisés sur 443 et 5222/5269. Le PEM copié au candidat devra être contrôlé sur **les deux surfaces** après bascule.

### Ancien domaine

- Validation HTTPS de `[DOMAINE_RETIRE]` : réussie.
- TLS : 1.3, AES-256.
- Sujet : `CN=chaumont.me`.
- Émetteur : Let's Encrypt `YE1`.
- Validité : `2026-08-06T09:13:16Z` à `2026-11-04T09:13:15Z`.
- Empreinte SHA-256 : `7C6C24E115DE9D9D887CBE3C0592852C43D4B3699A5E48C767A2077F48F359F0`.
- Empreinte SHA-1 observée par Windows : `FF165A5134C3A72C22F5174B00F013B5AB51015D`.

## Test des comptes temporaires

Le mécanisme XEP-0077 étant annoncé, deux identifiants uniques ont été proposés :

- `maeraudit08270310255ca` ;
- `maeraudit08270310255cb`.

Pour chacun :

1. connexion 5222 ;
2. vérification de STARTTLS obligatoire ;
3. validation TLS de `xmpp.maer.fr` ;
4. récupération du formulaire `jabber:iq:register` ;
5. tentative d'inscription avec un mot de passe aléatoire uniquement présent en mémoire.

Résultat identique :

```xml
<error type='auth'>
  <forbidden xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'/>
  <text xmlns='urn:ietf:params:xml:ns:xmpp-stanzas'>Access denied by service policy</text>
</error>
```

Conclusion : **aucun compte créé**, aucune authentification réelle tentée, aucun mot de passe conservé, aucun compte à supprimer. Il est impossible de tester l'échange de messages authentifié avec des comptes jetables par le mécanisme public actuel. Aucun contournement de la politique n'a été tenté.

## Serveur actuel et candidat SPK : ne pas confondre

| Fonction | Serveur actuel observé | Candidat `maerxmppserver` inspecté statiquement |
|---|---|---|
| Paquet | ancien ejabberd SynoCommunity | paquet distinct `maerxmppserver` 26.07.0-2 |
| Domaine | sert `xmpp.maer.fr`, tandis que l'ancien domaine reste actif ailleurs | `hosts: [xmpp.maer.fr]` uniquement |
| XMPP 5222 | opérationnel, STARTTLS obligatoire | configuré avec STARTTLS obligatoire |
| BOSH | opérationnel sur 443 via reverse proxy | configuré sur 5443 `/http-bind` |
| WebSocket | opérationnel sur 443 via reverse proxy | configuré sur 5443 `/xmpp-websocket` |
| `host-meta` | 404 | configuré, annonce `:5443` |
| HTTP Upload | racine 404 ; slot non testable sans compte | configuré sur 5443, maximum 50 MiB |
| Association MAER | 404 | `mod_maer_pairing` configuré sur 5443 |
| Administration | publiquement joignable sur 443, Basic auth | loopback uniquement sur 5280 |
| Inscription publique | annoncée mais refusée par politique | module non activé |
| Fédération 5269 | port ouvert, STARTTLS optionnel | accès S2S refusé, aucun listener 5269 déclaré |
| Stockage des nouveaux mots de passe | non vérifié sans compte | SCRAM-SHA-256 prévu en SQLite |

L'inspection statique du candidat repose sur le commit local `8218fed1` (`feat(synology): package hardened ARMv7 XMPP server`) et son profil `packaging/synology/spksrc-overlay/spk/maerxmppserver/src/defaults/ejabberd.yml`. Elle ne constitue pas une preuve de fonctionnement sur le RS816.

## Contre-audit des fins de ligne et de la reproductibilité du SPK

### Pourquoi la validation locale réussissait

La configuration Git système de la machine est `core.autocrlf=true`, mais les fichiers de packaging ont été créés puis commités sans être rematérialisés par un nouveau checkout. Le répertoire historique est ainsi hybride :

- 29 fichiers suivis sous `packaging/synology` ont des LF dans le répertoire de travail ;
- le `COPYING` packagé est en CRLF ;
- le `COPYING` canonique à la racine est lui aussi en CRLF ;
- `validate-source.ps1` et `defaults/ejabberd.yml` restent en LF.

Cet état hybride satisfait simultanément les regex qui supposent LF et l'empreinte `COPYING` calculée sur CRLF. La validation locale donne donc un résultat vert qui n'est pas reproductible après clone.

`.gitattributes` ne définit actuellement aucun attribut `text` ou `eol` pour :

- `COPYING` et sa copie packagée ;
- `*.ps1` ;
- `*.yml` ;
- les Makefiles et plusieurs fichiers de recette Synology.

Il impose seulement LF à quelques familles comme `*.sh`, `*.erl`, `*.hrl`, `*.in` et les fichiers Autotools.

### Preuve 1 — clone Windows propre

Commandes équivalentes exécutées dans un répertoire temporaire :

```powershell
git -c core.autocrlf=true clone --shared --no-checkout --branch maer/server-v1 --single-branch <depot-source> <clone-temporaire>
git -C <clone-temporaire> config core.autocrlf true
git -C <clone-temporaire> checkout -f maer/server-v1
git -C <clone-temporaire> ls-files --eol -- COPYING packaging/synology/spksrc-overlay/spk/maerxmppserver/src/COPYING packaging/synology/tests/validate-source.ps1 packaging/synology/spksrc-overlay/spk/maerxmppserver/src/defaults/ejabberd.yml
pwsh -NoProfile -File <clone-temporaire>/packaging/synology/tests/validate-source.ps1
```

État observé :

```text
i/lf  w/crlf  COPYING
i/lf  w/crlf  packaging/synology/spksrc-overlay/spk/maerxmppserver/src/COPYING
i/lf  w/crlf  packaging/synology/tests/validate-source.ps1
i/lf  w/crlf  packaging/synology/spksrc-overlay/spk/maerxmppserver/src/defaults/ejabberd.yml
Synology packaging validation failed (30 issue(s))
VALIDATOR_EXIT=1
```

Les 30 échecs reproduits couvrent notamment les distributeurs SPK, modes exécutables, options OTP/OpenSSL/SQLite, hôte canonique, STARTTLS, SCRAM-SHA-256, MAM, MUC, pairing, PubSub, push et ports Erlang. Le test shell du contrat de service passe avant ces échecs.

### Preuve 2 — checkout LF intégral

Un checkout du même commit avec `core.autocrlf=false` produit :

| Fichier | CRLF | SHA-256 |
|---|---:|---|
| `COPYING` canonique | 0 | `469bb8cfa3ef22c102875ff31932450c075e6908ff3f7d36893485c0c30898eb` |
| `COPYING` packagé | 0 | `469bb8cfa3ef22c102875ff31932450c075e6908ff3f7d36893485c0c30898eb` |
| `validate-source.ps1` | 0 | `2be6b3eaae7ce487373426e6ff4398fb8abc0edef880fdd85228771f338dd526` |
| `defaults/ejabberd.yml` | 0 | `cf862320d04954250ad413b6ff73e9f6c81de39682c71819d8185335962733e1` |

Résultat :

```text
Synology packaging validation failed (2 issue(s)):
 - Canonical COPYING hash mismatch. (actual='469bb8...', expected='8f0fc6...')
 - Packaged COPYING hash mismatch. (actual='469bb8...', expected='8f0fc6...')
VALIDATOR_EXIT=1
```

L'empreinte verrouillée `8f0fc61b2b9ff3f4d7887a525100e786bedf1b39dde68f3831d363fda61818a1` est celle des deux fichiers `COPYING` en CRLF, pas celle de leur contenu Git LF.

### Preuve 3 — mode hybride historique

En partant du checkout LF puis en laissant uniquement les deux `COPYING` en CRLF :

```text
COPYING canonique                           CRLF=343  SHA256=8f0fc61b...
COPYING packagé                             CRLF=343  SHA256=8f0fc61b...
validate-source.ps1                         CRLF=0    SHA256=2be6b3ea...
defaults/ejabberd.yml                       CRLF=0    SHA256=cf862320...
service contract tests passed
Synology packaging source validation passed.
VALIDATOR_EXIT=0
```

C'est le même profil de fins de ligne que le répertoire depuis lequel le GO précédent avait été obtenu.

### Correction nécessaire avant nouvelle livraison

1. Déclarer explicitement les fins de ligne dans `.gitattributes`, au minimum pour `COPYING`, sa copie packagée, `*.ps1`, `*.yml`, Makefiles, recettes et fichiers texte consommés par les validateurs.
2. Choisir LF comme représentation canonique multi-plateforme pour les sources et licences, puis renormaliser l'index Git.
3. Mettre `LOCKS.json` à jour avec l'empreinte LF de `COPYING` : `469bb8cfa3ef22c102875ff31932450c075e6908ff3f7d36893485c0c30898eb`.
4. Normaliser les textes lus par les regex dans le validateur, ou accepter explicitement `\r?` avant chaque fin de ligne, comme défense supplémentaire.
5. Ajouter une matrice de test de clone propre : Windows avec `core.autocrlf=true` et environnement LF avec `core.autocrlf=false`.
6. Refaire la préparation overlay, le build ARMv7, les validations source/SPK, les SBOM/empreintes et l'audit indépendant. L'empreinte du SPK changera probablement et devra être republiée.

## Contrôles à exécuter immédiatement après la future bascule

1. Vérifier le démarrage sous `sc-maerxmppserver`, sans privilèges root persistants.
2. Contrôler 5222 STARTTLS, le nom SAN, la chaîne, TLS 1.2/1.3 et l'expiration.
3. Choisir et tester l'URL publique HTTPS : 443 reverse proxy ou 5443 direct.
4. Tester BOSH par une vraie ouverture de session, pas seulement un `GET`.
5. Tester une vraie montée WebSocket et l'ouverture XMPP.
6. Vérifier les deux variantes `host-meta` et leurs URL publiées.
7. Tester pairing : création, approbation authentifiée, polling signé, consommation unique, révocation et expiration.
8. Créer deux comptes administratifs jetables, tester authentification SCRAM-SHA-256, roster, présence et message `no-store`, puis les supprimer et vérifier le refus de reconnexion.
9. Tester HTTP Upload : demande de slot authentifiée, PUT, GET, limite 50 MiB, MIME, CORS, traversal et suppression/rétention.
10. Vérifier OMEMO/PEP, MAM, MUC privé, blocage et push avec deux clients.
11. Confirmer que `/admin` et `/api` ne sont pas publics et que 5280 reste inaccessible extérieurement.
12. Confirmer que 5269 est fermé et que la fédération est refusée.
13. Retester le retrait DNS/HTTPS de `[DOMAINE_RETIRE]` depuis au moins deux résolveurs publics.
14. Redémarrer le paquet puis répéter connexion, pairing et persistance ; effectuer ensuite un test de rollback documenté.

## Méthode et garde-fous

- Résolution DNS Windows et vérification croisée via Cloudflare `1.1.1.1` et Google `8.8.8.8`.
- Connexions TCP ciblées uniquement sur 80, 443, 5222, 5269, 5280 et 5443.
- TLS avec validation du nom et de la chaîne système ; essais forcés TLS 1.0 à 1.3.
- Flux XMPP brut pré-authentification pour STARTTLS et fonctionnalités SASL.
- Handshake WebSocket RFC 6455 avec clé aléatoire et contrôle de `Sec-WebSocket-Accept`.
- BOSH avec une seule session non authentifiée à expiration courte ; SID masqué.
- Requêtes HTTP sans secret, sans cookie DSM et sans en-tête d'autorisation.
- Aucun mot de passe réel, aucun essai d'identifiant existant, aucun brute force.
- Aucun fichier envoyé, aucune clé privée lue, aucune modification du NAS, aucun arrêt ni redémarrage.

## Tentative `26.07.0-3` invalidée par la QA finale — NO-GO

Cette section conserve la trace de la première remédiation, mais son artefact
est retiré et ne doit être ni publié ni installé. La QA finale a identifié des
écarts supplémentaires sur la confiance proxy, les quotas Upload, la politique
d'upgrade, le préflight et les métadonnées d'archive. La seule révision encore
candidate est `26.07.0-4`, décrite dans la section finale de ce rapport.

Les corrections ci-dessous portent uniquement sur le dépôt et sur un build
isolé. Le NAS et le serveur actuellement publié n'ont pas été modifiés, arrêtés
ou redémarrés.

### Écarts corrigés dans le candidat

- P1-01/P1-03 : le module de pairing est présent dans le runtime ARMv7 ; son
  contrat, le QR canonique, `host-meta`, BOSH, WebSocket et Upload utilisent
  tous `xmpp.maer.fr` et les URL publiques HTTPS sur le port 443.
- P1-04 : l'administration écoute uniquement sur `127.0.0.1:5280` et les
  chemins `/admin` et `/api` ne font pas partie de la publication DSM.
- P1-06 : le profil est désormais explicite et testable : publication DSM
  `xmpp.maer.fr:443` vers `https://127.0.0.1:5443`, conservation du Host/SNI et
  validation du certificat backend. Le port 5443 n'est plus déclaré au
  pare-feu public du paquet.
- P1-07 : `.gitattributes` impose LF aux sources, recettes, licences et verrous ;
  `COPYING`, sa copie packagée et `LOCKS.json` utilisent tous l'empreinte LF
  `469bb8cfa3ef22c102875ff31932450c075e6908ff3f7d36893485c0c30898eb`.
  Le validateur normalise défensivement les textes mais conserve les octets
  bruts pour les empreintes.
- P2-01 à P2-05 : le candidat n'a pas de listener 5269, refuse tout S2S,
  exige STARTTLS sur 5222, limite SASL à SCRAM-SHA-256 et X-OAUTH2, fixe CORS et
  l'origine WebSocket à l'origine canonique et ajoute HSTS, CSP, Referrer-Policy,
  X-Content-Type-Options, X-Frame-Options et Vary.
- P3-01/P3-02 : l'inscription publique n'est ni annoncée ni routée ; le
  préflight exige également un refus XMPP protocolaire propre d'une requête
  XEP-0077 non authentifiée.
- La chaîne exacte de l'ancien domaine a été supprimée de tous les fichiers,
  y compris de ce rapport historique ; la preuve est conservée sous la forme
  neutre `[DOMAINE_RETIRE]`.

### Build et artefact validés

- Clone `spksrc` propre et détaché au commit
  `954871e356f7f990c179eb58af11c20d82872d8f`.
- Build réel : `armada38x-7.1`, version `26.07.0-3`, terminé avec succès dans
  WSL Ubuntu 26.04 en utilisant exclusivement le PATH Linux natif.
- Artefact prêt pour staging isolé :
  `C:\Users\Emili\Documents\ChatGPT\MAER Chat\.codex-tmp\spk-release\maerxmppserver_armada38x-7.1_26.07.0-3.spk`.
- Taille : `16 363 520` octets.
- SHA-256 :
  `1B318A79A08D6D583430B1C04EBFCD367E0783500D0F82549B6CEB5C2D730C8E`.
- SHA-256 de la configuration embarquée, identique à la source validée :
  `8A02BCE0314DC391F75AC857EFA463F479016F06176E3A427544E275ED8AFFF6`.
- Les deux couches tar ont un ordre et un horodatage fixes, et gzip n'embarque
  aucun horodatage. Deux réassemblages successifs ont produit exactement le
  même SHA-256 ci-dessus.

### Validations réussies

- validation source complète et test shell du contrat de service ;
- inspection réelle des deux couches du SPK, de `INFO`, des privilèges, modes,
  licences, dépendances runtime et de la configuration embarquée ;
- clones propres synthétiques Windows (`core.autocrlf=true`) et Linux/LF
  (`core.autocrlf=false`) ;
- chargement réel de `defaults/ejabberd.yml` par `ejabberd_config:load/0` avec
  Erlang/OTP 27 et les modules/NIF du serveur : succès ;
- parse de tous les scripts PowerShell et `git diff --check` : succès ;
- recherche globale des références actives à l'ancien domaine : zéro résultat.

Le nouveau préflight DSM exécute de vraies ouvertures XMPP STARTTLS, BOSH et
WebSocket, contrôle TLS/SAN/chaîne, SASL, refus XEP-0077, CORS/origines, en-têtes,
DNS A/SRV, ports privés et absence d'administration publique. Exécuté sans
authentification contre le serveur historique inchangé, il a remonté 49 écarts
attendus et a donc confirmé qu'il détecte bien le profil à remplacer.

### Blocages résiduels avant publication de production

Le candidat est prêt pour une installation de staging DSM, mais le GO production
reste conditionné aux essais qui nécessitent un NAS isolé et des comptes
jetables : installation/post-install sous l'utilisateur de paquet, démarrage et
redémarrage, permissions persistantes, pairing complet avec expiration/rejeu et
révocation, Upload authentifié, roster/présence/message, OMEMO/PEP, MAM, MUC,
push, ainsi qu'au préflight public après création des DNS A/SRV et du reverse
proxy DSM. Aucun de ces essais n'a été simulé sur le NAS de production.
