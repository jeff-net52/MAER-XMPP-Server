# Paquet Synology — MAER XMPP Server

Cette arborescence constitue la première tranche revue et testable du paquet
DSM 7. Elle ne contient aucun binaire précompilé et n'effectue aucune action
sur un NAS.

## Contrat du paquet

| Propriété | Valeur |
|---|---|
| Identifiant | `maerxmppserver` |
| Nom affiché | `MAER XMPP Server` |
| Version SPK | `26.07.0-9` |
| Architecture | `armada38x` uniquement |
| DSM minimal | `7.2-72806` |
| Compte de service | `sc-maerxmppserver`, jamais `root` |
| Domaine XMPP | `xmpp.maer.fr` uniquement |

`spksrc` génère `conf/privilege` à partir de `SERVICE_USER = auto`. Pour DSM 7,
le contrat résultant est `run-as: package`, utilisateur
`sc-maerxmppserver`, groupe isolé `sc-maerxmppserver`. Aucun fichier `privilege` manuel
n'est copié afin d'éviter deux producteurs concurrents du même artefact.
Les champs `distributor` et `distributor_url` de `INFO` sont imposés par la
recette du paquet afin qu'un `local.mk` global de l'environnement `spksrc` ne
puisse pas effacer l'identité MAER lors d'un build reproductible.

Le paquet ne remplace pas le paquet SynoCommunity `ejabberd`, ne crée aucun
lien global `ejabberdctl` et ne déclare aucun remplacement de paquet. Les deux
paquets peuvent donc être installés côte à côte tant que leurs ports ne se
chevauchent pas. MAER XMPP Server refuse de démarrer si l'un de ses ports est
déjà occupé et ne tente pas d'arrêter le processus qui l'utilise.

## Données persistantes

Le code en lecture seule est installé sous
`/var/packages/maerxmppserver/target`. Toutes les données mutables restent sous
`/var/packages/maerxmppserver/var` :

| Chemin | Usage | Mode créé |
|---|---|---|
| `config` | `ejabberd.yml`, `ejabberdctl.cfg`, `inetrc`, secret SMTP | `0700`; fichiers `0600` |
| `data` | SQLite et données Mnesia techniques | `0700` |
| `log` | journaux et crash dumps Erlang | `0700` |
| `run` | PID ejabberd | `0700` |
| `upload` | pièces jointes HTTP Upload | `0700`; fichiers `0600` |

La révision 9 accepte une seule migration en place : depuis `26.07.0-8`.
Elle conserve les comptes, les données XMPP et les uploads, sauvegarde
`ejabberd.yml` sous `ejabberd.yml.pre-26.07.0-9`, puis installe atomiquement le
profil canonique rev9. Toute autre version source est refusée. Une installation
neuve continue d'exiger un répertoire de données vide afin de ne jamais adopter
silencieusement un état étranger au paquet.

Le mot de passe de `no-reply@maer.fr` est demandé par l'assistant DSM à
l'installation ou pendant la migration rev8 → rev9. Il est écrit uniquement
dans `var/config/smtp-password` en mode `0600`; il n'apparaît ni dans
`ejabberd.yml`, ni dans les journaux, ni dans le dépôt.

Le service fixe `HOME` au répertoire d'état privé du paquet. Certaines voies de
lancement DSM omettent cette variable ; Erlang ne peut alors ni localiser ni
créer son cookie et interrompt son noyau avant le démarrage d'ejabberd. Aucun
mot de passe, cookie, jeton, secret TURN ou clé privée n'est présent dans le
dépôt.

Le service refuse volontairement de démarrer tant qu'un PEM combiné lisible
par le compte de paquet n'est pas installé à
`/usr/local/etc/certificate/maerxmppserver/maerxmppserver_client/xmpp.pem`.
Le profil ne crée pas automatiquement le compte `admin@xmpp.maer.fr`.
L'opérateur installe, avec `install-bootstrap-admin-root`, la copie vérifiée de
`maer-bootstrap-admin` sous `/usr/local/libexec/maerxmppserver/`, puis l'exécute
interactivement après le premier démarrage. Le mot de passe et sa confirmation
ne sont placés ni dans argv, ni dans l'environnement, ni dans les journaux. Le
helper crée exclusivement l'identité autorisée par l'ACL et la transaction
distante unique vérifie son stockage SCRAM-SHA-256, avec rollback interne si
la validation échoue. Aucun compte jetable n'est créé en production. Il ne
faut jamais exécuter comme root la copie située dans un arbre package-owned.

DSM 7 interdit l'intégration `SERVICE_CERT` aux paquets communautaires. Le
helper audité est donc livré séparément dans `packaging/synology/operator/` et
ne doit jamais être exécuté comme root depuis le `target` du paquet, lequel est
modifiable par le compte de service. Avant le premier démarrage, l'opérateur
vérifie l'asset publié, exécute `install-certificate-sync-root` pour installer
une copie root-owned `0700` sous `/usr/local/libexec/maerxmppserver/`, puis lance
`certificate-sync` avec `MAER_CERT_ARCHIVE_ID` fixé à l'identifiant DSM choisi.
Une tâche DSM root quotidienne exécute uniquement cette copie root-owned. Elle
sélectionne/refuse expiration, SAN, symlinks et clé discordante, écrit le PEM
atomiquement en `0640` (`root:sc-maerxmppserver`), et ne redémarre qu'un service déjà actif. Le premier
sync doit précéder le premier start. À la désinstallation, l'opérateur supprime
explicitement le libexec et l'arbre certificat root-owned.

## Profil fonctionnel initial

Le profil active les transports clients STARTTLS, BOSH et WebSocket, les
archives MAM, les salons MUC privés, HTTP Upload, les fonctions PubSub/PEP
nécessaires à OMEMO, les abonnements push et l'authentification rapide. Les
mots de passe nouvellement enregistrés sont stockés uniquement en
SCRAM-SHA-256 dans SQLite.

HTTP Upload limite chaque fichier à 50 Mio. `mod_http_upload_quota` applique à
chaque compte un seuil souple de 500 Mio, un seuil dur de 600 Mio et supprime
quotidiennement les fichiers âgés de plus de 30 jours. Au franchissement du
seuil dur, les plus anciens fichiers du compte sont retirés jusqu'au seuil
souple. Ces quotas par compte ne remplacent pas une surveillance globale du
volume.

Le paquet livre donc la commande read-only
`/var/packages/maerxmppserver/target/bin/maer-upload-usage-check`. Elle publie
la taille globale du répertoire Upload et l'occupation du volume, retourne 1 à
80 % et 2 à 90 %. Il faut l'exécuter périodiquement depuis le Planificateur de
tâches DSM et relier tout code non nul aux notifications de stockage. Les seuils
peuvent être ajustés avec `MAER_UPLOAD_FS_WARN_PERCENT` et
`MAER_UPLOAD_FS_CRITICAL_PERCENT` sans modifier les quotas par compte.

Cette tranche active l'association sécurisée MAER sur la route HTTPS
`/maer-pairing` du listener TLS local `127.0.0.1:5443`. Le reverse proxy DSM
publie uniquement les routes protocolaires autorisées sur le port public 443.
Le module limite les sessions
par IP et globalement, exige l'approbation d'un compte authentifié du domaine
canonique, crée sa table Mnesia persistante au démarrage et refuse explicitement
un schéma incompatible. Elle désactive implicitement ou explicitement les autres
surfaces qui ne sont pas encore prêtes : inscription publique, API HTTP
d'administration, fédération serveur-à-serveur et découverte STUN/TURN.
Le signalement Jingle audio/vidéo transite déjà par XMPP, mais les appels hors
LAN nécessiteront un service TURN séparé avec secrets éphémères avant d'être
annoncés aux clients.

## Portail utilisateur et SMTP

Le même listener TLS local sert le portail autonome sur `/account`. Le module
ne réutilise pas le WebAdmin et n'expose aucune commande d'administration. Une
connexion saisie sous forme d'identifiant court est toujours résolue sur
`@xmpp.maer.fr`. Le portail permet d'associer puis de vérifier une adresse
email, de demander un changement de mot de passe confirmé par email et de
conserver les préférences appels audio, appels vidéo, partage d'écran, MAER
Assistance et gestionnaire de mots de passe. Ces préférences ne déclenchent
aucune facturation et ne promettent pas à elles seules la disponibilité d'un
service côté client.

Les profils et les empreintes SHA-256 des jetons sont conservés dans la base
séparée `/var/packages/maerxmppserver/var/data/maer-portal.sqlite`. Les sessions
restent en mémoire, expirent et sont révoquées après un changement de mot de
passe. Les liens reçus par email placent leur jeton après `#` : les requêtes et
les journaux du reverse proxy ne contiennent donc pas le secret. Tous les POST
exigent l'origine canonique, un cookie SameSite/HttpOnly/Secure et un jeton
CSRF à usage borné. Les tentatives de connexion et les envois email sont
limités par IP et par compte.

L'assistant DSM demande le mot de passe SMTP pendant une installation neuve ou
la migration rev8 → rev9. Le paquet le valide puis le provisionne atomiquement
dans `/var/packages/maerxmppserver/var/config/smtp-password`, sous le compte de
service et en mode exact `0600`. Le profil canonique contient déjà :

```yaml
smtp_host: smtp-zose.yulpa.io
smtp_port: 465
smtp_username: no-reply@maer.fr
smtp_password_file: /var/packages/maerxmppserver/var/config/smtp-password
smtp_from: no-reply@maer.fr
```

Une création manuelle ne sert qu'au dépannage si le secret provisionné par DSM
a été perdu ou supprimé. Dans ce cas, arrêter le paquet, recréer ce fichier avec
une saisie interactive qui n'apparaît ni dans l'historique ni dans la ligne de
commande, refuser tout lien symbolique, lui appliquer le propriétaire
`sc-maerxmppserver:sc-maerxmppserver` et le mode exact `0600`, puis redémarrer.
Il ne faut ni placer le secret dans `ejabberd.yml`, ni modifier les cinq valeurs
canoniques ci-dessus. Tester ensuite séparément l'association d'adresse email et
le changement de mot de passe. Sans secret lisible et strictement protégé, la
connexion et les préférences restent disponibles mais les actions email sont
désactivées.

Le transport SMTP accepte uniquement TLS implicite, vérifie la chaîne publique
et le nom du serveur, et ne journalise ni identifiants, ni mots de passe, ni
jetons. Un relais STARTTLS sur 587 doit être placé derrière un relais TLS
implicite local ou remplacé par un service offrant le port 465 ; il ne faut pas
affaiblir cette vérification dans la configuration du paquet.

## Provenance reproductible

[`LOCKS.json`](LOCKS.json) verrouille :

- `spksrc` au commit `954871e356f7f990c179eb58af11c20d82872d8f` ;
- le toolchain `armada38x-7.1` (GCC 8.5.0, glibc 2.26) ;
- Erlang/OTP `27.3.4.16` et ses empreintes ;
- OpenSSL `3.5.7` et ses empreintes, construit par une recette MAER dédiée qui
  neutralise les chemins et options de compilation incorporés et fixe
  `SOURCE_DATE_EPOCH` à la date publique de cette version ;
- la source publique MAER au commit immuable
  `fea59faa0224c7a8f52751eed0bd4d21f55c8d93`, et les empreintes exactes de
  son archive GitHub ;
- les deux couches tar du SPK à la date UTC publique du paquet, avec un ordre
  lexical stable et un en-tête gzip sans horodatage. Deux réassemblages
  successifs d'un staging inchangé doivent ainsi produire le même SHA-256.

Une nouvelle publication source devra mettre à jour le commit, l'URL d'archive,
la taille et les trois empreintes ensemble. Une branche ou un tag mobile ne doit
jamais être utilisé comme entrée de build.

Les recettes adaptées de `spksrc` restent sous BSD-3-Clause ; le texte est
conservé dans [`LICENSES/BSD-3-Clause.txt`](LICENSES/BSD-3-Clause.txt). Le
serveur, le profil et les scripts runtime restent sous GPLv2 avec l'exception
OpenSSL définie dans le `COPYING` du dépôt.

Le runtime redistribue aussi `libatomic.so.1.2.0` issu du toolchain GCC 8.5.0.
Le paquet conserve ensemble la GPLv3, l'exception GCC Runtime Library 3.1 et
une notice de provenance qui désigne l'archive binaire Synology exacte ainsi
que la source GCC 8.5.0 et son empreinte SHA-256 vérifiée. Toute publication du
SPK doit préserver ces notices et garantir un accès réseau gratuit équivalent
à cette source pendant la durée de distribution du binaire.

## Validation sans build

Depuis la racine du dépôt :

```powershell
pwsh -NoProfile -File packaging/synology/tests/validate-source.ps1
```

Le validateur contrôle les identités, les verrous, les empreintes déclarées,
le contrat de privilèges généré, les chemins persistants, les ports, l'absence
de secrets ou de marqueurs de substitution et la syntaxe des scripts shell. Il
exécute aussi le test de comportement du service si `sh` est disponible. Avec
`-SpkPath`, il ouvre les deux couches d'archive, vérifie les modes DSM, les
composants et licences attendus, et refuse les sources, répertoires d'exemples, documentation,
archives statiques, applications OTP de développement, outils, clés privées,
chemins de build et dépendances runtime non résolues qui n'ont rien à faire dans
le runtime livré.

### Barrière obligatoire pour chaque nouveau SPK

Toute création de SPK destinée à être installée ou publiée doit terminer par :

```powershell
pwsh -NoProfile -File packaging/synology/tests/release-gate.ps1 -SpkPath /chemin/vers/maerxmppserver_armada38x-7.1_VERSION.spk
```

Cette barrière enregistre et bloque explicitement les régressions déjà rencontrées :

- décalage entre la version du nom de fichier, `INFO`, `LOCKS.json` et le contrat attendu ;
- rejet de la racine DSM 7 canonique
  `/var/packages/maerxmppserver/var -> ${SYNOPKG_PKGVAR}` : ce lien symbolique
  géré par DSM est accepté uniquement s'il résout exactement vers
  `SYNOPKG_PKGVAR`, tandis que chaque sous-chemin mutable reste soumis au refus
  strict des liens symboliques ;
- test de comportement qui ne reproduit pas cette topologie DSM 7 avec une
  racine `var` symbolique, sa cible `SYNOPKG_PKGVAR`, puis des sous-chemins
  strictement contrôlés ;
- absence du NIF JID ou démarrage de la validation avant `application:ensure_all_started(xmpp)` ;
- absence de `crypto_callback.so`, chargeur OpenSSL dynamique indispensable à OTP 27 ;
- suppression abusive de `httpd_example.beam`, module runtime `inets` requis par ejabberd ;
- `HOME` Erlang absent ou situé hors du répertoire privé du compte DSM ;
- mode non exécutable des scripts DSM, dépendance ELF manquante, RPATH non canonique ou lien symbolique pendant ;
- page WebAdmin des utilisateurs cassée lorsqu'un compte n'a aucune donnée `mod_last` ;
- création de compte testée sans cookie ou jeton CSRF réellement fourni par WebAdmin ;
- bannissement de tous les clients locaux partageant l'adresse de sortie du réseau ;
- origine Electron `file://` ou absence de l'origine privilégiée exacte `maer-chat://app` ;
- absence des modules, feuilles de style, scripts ou logo du portail/WebAdmin MAER ;
- chemin UNC/WSL transmis à `tar.exe` avec le préfixe interne PowerShell
  `Microsoft.PowerShell.Core\FileSystem::` au lieu du chemin fournisseur natif ;
- patch serveur au format Git `a/`/`b/` alors que spksrc l'applique avec `patch -p0`, ce qui créerait un faux répertoire `b/` ou attendrait une saisie interactive ;
- secret SMTP placé dans le YAML, imprimé par l'installeur ou créé avec un mode autre que `0600` ;
- assistant DSM d'installation/migration absent du SPK final, notamment si
  `src/wizard` existe mais n'est pas déclaré par `WIZARDS_DIR` dans la recette spksrc ;
- migration rev8 → rev9 qui remplace ou supprime la base de comptes au lieu de ne rafraîchir que le profil runtime.

Le paquet ne doit être copié sur le NAS qu'après le message
`MAER XMPP Server release gate passed` et l'émission de son SHA-256.

La reproductibilité des fins de ligne se vérifie séparément dans deux clones
propres synthétiques, l'un avec le profil Git Windows et l'autre avec le profil
Linux/LF :

```powershell
pwsh -NoProfile -File packaging/synology/tests/test-clean-checkouts.ps1
```

Les deux profils exigent des octets LF pour les sources, recettes, licences et
verrous. Le validateur normalise aussi défensivement les textes avant les
expressions régulières, sans normaliser les fichiers dont l'empreinte est
verrouillée.

## Build isolé et validation de l'artefact

Le build doit être effectué sur un hôte Linux ou dans l'environnement de build
officiel de `spksrc`, jamais directement sur le NAS de production :

```bash
git clone https://github.com/SynoCommunity/spksrc.git
git -C spksrc checkout --detach 954871e356f7f990c179eb58af11c20d82872d8f
```

Depuis le dépôt MAER, préparer ensuite le checkout externe. Le script refuse un
commit différent, un checkout sale ou une recette cible préexistante.

Pour un checkout stocké dans le système de fichiers Linux de WSL, utiliser le
compagnon Bash afin que la validation Git et les copies soient toutes exécutées
par WSL. Le mode `--check` réalise le préflight complet sans créer ni modifier
aucun fichier :

```powershell
wsl.exe -d Ubuntu-26.04 -- bash "/mnt/c/Users/Emili/Documents/ChatGPT/MAER Chat/MAER-XMPP-Server-clean/packaging/synology/prepare-overlay.sh" --spksrc /home/emilien/src/maer-spksrc --check
```

Après un préflight réussi, retirer seulement `--check` :

```powershell
wsl.exe -d Ubuntu-26.04 -- bash "/mnt/c/Users/Emili/Documents/ChatGPT/MAER Chat/MAER-XMPP-Server-clean/packaging/synology/prepare-overlay.sh" --spksrc /home/emilien/src/maer-spksrc
```

Le script crée son staging dans le checkout Linux, vérifie que les trois parents
de recettes sont sur le même système de fichiers, puis utilise
`renameat2(RENAME_NOREPLACE)` pour chaque installation. Il normalise les
répertoires à `0755` et les fichiers à `0644`, puis rétablit explicitement
`service-setup.sh` et `service-start-stop.sh` à `0755`. En cas d'erreur interceptée, il
tente un rollback uniquement pour les chemins dont le device et l'inode sont
ceux enregistrés par l'exécution courante. Les cinq renommages ne constituent
cependant pas une transaction unique : après un `SIGKILL`, un arrêt de WSL ou
une coupure machine, il faut inspecter `git status --short` et supprimer
manuellement uniquement les recettes non suivies avant de relancer le script.

`prepare-overlay.ps1` reste disponible pour un checkout Windows natif. Il ne
doit pas être utilisé sur un chemin UNC `\\wsl.localhost`: Git for Windows peut
y voir de faux changements de modes ou de fins de ligne.

```powershell
pwsh -NoProfile -File packaging/synology/prepare-overlay.ps1 -SpksrcPath /chemin/vers/spksrc
```

Puis, dans le checkout `spksrc` :

```bash
make setup
make -C spk/maerxmppserver arch-armada38x-7.1
```

Le SPK attendu est alors
`packages/maerxmppserver_armada38x-7.1_26.07.0-9.spk`, à la racine du checkout
`spksrc`.

Une seconde exécution de la même commande réassemble le paquet. Son SHA-256
doit rester strictement identique ; toute différence signale une entrée de
build non déterministe et interdit la publication.

### Checklist de reconstruction avant upload

Avant chaque build destiné au NAS :

- resynchroniser **tout** `packaging/synology/spksrc-overlay` avec
  `prepare-overlay.sh`, puis contrôler dans le checkout `spksrc` la valeur de
  `SPK_REV`, l'ensemble des répertoires `patches/`, `WIZARDS_DIR` et les
  fichiers `src/wizard/` ; la recopie isolée d'un seul fichier est interdite ;
- exécuter le build dans WSL avec un `PATH` Linux explicite et propre, sans
  entrée `/mnt/c`, chemin Windows ni répertoire KeePassXC, puis vérifier que
  `command -v bash make tar patch` résout uniquement dans le système Linux ;
- après le build, lire `INFO` dans le SPK produit et vérifier que sa version et
  sa révision correspondent à `SPK_VERS`/`SPK_REV` et au nom du fichier attendu
  avant tout upload ; lancer ensuite `release-gate.ps1 -SpkPath ...` sur ce
  fichier exact et conserver le SHA-256 annoncé.

Après le build, valider le SPK réel, y compris `INFO`, `conf/privilege` et les
modes des scripts :

```powershell
pwsh -NoProfile -File packaging/synology/tests/validate-source.ps1 -SpkPath /chemin/vers/maerxmppserver_armada38x-7.1_26.07.0-9.spk
```

Les chemins locaux, UNC et `\\wsl.localhost\...` sont normalisés vers leur
`ProviderPath` natif avant l'appel à `tar.exe`. Le test de régression reproduit
la forme qualifiée du fournisseur PowerShell sans exiger qu'une distribution
WSL soit installée sur la machine de validation.

Le choix `--disable-year2038` est intentionnel pour ce premier essai 32 bits
sur glibc 2.26. Le support OTP 27 sur GCC 8.5 et ce compromis de temps 32 bits
restent des risques à valider lors du premier build. Aucun paquet ne doit être
signé, publié ou installé tant que la compilation, l'inspection du SPK et les
tests sur un DSM isolé n'ont pas réussi.

`REQUIRED_MIN_DSM` reste fixé à `7.1` parce qu'il contrôle la version du SDK de
compilation et qu'aucun toolchain DSM 7.2 n'existe pour `armada38x` dans
`spksrc`. La métadonnée de paquet `OS_MIN_VER = 7.2-72806` est distincte et
continue d'interdire l'installation sur une version DSM antérieure à celle
validée pour le RS816.

## Publication réseau

Le paquet ne demande plus l'ouverture DSM de 5443. Sa topologie canonique est
`Internet:443 → reverse proxy DSM → 127.0.0.1:5443`; les URL host-meta, BOSH,
WebSocket, upload et pairing ne publient donc aucun port non standard. Le port
5280 et l'administration restent loopback-only, aucun listener 5269 n'est
déclaré, l'inscription XEP-0077 publique est absente et l'offre SASL exclut
`ANONYMOUS`, `CRAM-MD5`, `DIGEST-MD5`, `LOGIN`, `PLAIN`, SCRAM-SHA-1 et les
variantes non stockées. X-OAUTH2 reste disponible parce qu'il transporte les
jetons d'association MAER.

Seuls les reverse proxies loopback `127.0.0.0/8` et `::1/128` sont déclarés
fiables pour `X-Forwarded-For`; la valeur `all` est interdite. La règle DSM doit
remplacer l'en-tête reçu du client, jamais lui ajouter une valeur. Les ports
EPMD 4369, distribution Erlang 5211, S2S 5269, administration 5280 et backend
HTTP 5080 et HTTPS 5443 doivent tous rester inaccessibles depuis Internet.

Les réglages DNS, SRV, pare-feu et reverse proxy à appliquer sont décrits dans
[`PUBLICATION-PREFLIGHT.md`](PUBLICATION-PREFLIGHT.md). Après installation et
avant d'autoriser les clients :

```powershell
pwsh -NoProfile -File packaging/synology/dsm-publication-preflight.ps1 -RetiredDomain 'retired-domain.example'
```

La valeur `retired-domain.example` est un exemple réservé : elle doit être
remplacée par le FQDN réellement retiré avant tout verdict de publication.

Les recettes OTP désactivent explicitement `wx`, `debugger`, `observer`, `et` et
`reltool` avec les options `--without-*` de la configuration OTP. OTP 27 ne
résout pas automatiquement les dépendances entre applications : désactiver
seulement `wx` laisserait par exemple `debugger` tenter de compiler ses modules
graphiques sans le comportement `wx_object`. Ces applications ne sont pas
requises par ejabberd et ne sont pas livrées dans le runtime serveur.

Le runtime OTP natif ne sert qu'à produire les artefacts croisés : sa
configuration désactive donc PGO afin d'éviter une seconde compilation guidée
par profil sans bénéfice pour le paquet livré. Durant la compilation ARMv7, le
répertoire `bin` de cet OTP épinglé est placé avant le `PATH` système pour qu'une
version Erlang éventuellement installée dans WSL ne puisse pas être sélectionnée.

## Runtime durci et reproductible

La phase finale du paquet réintègre d'abord explicitement l'ensemble verrouillé
des applications runtime ejabberd, y compris lors d'un build incrémental, puis
ne conserve que ce qui est nécessaire en production. Elle retire les sources,
exemples, documentation, pages de manuel,
en-têtes, bibliothèques statiques, outils ncurses et OTP de développement,
ainsi que les applications OTP `common_test`, `dialyzer`, `edoc`,
`erl_interface` et `eunit`. Les bibliothèques ncurses `form`, `menu` et `panel`
non référencées sont supprimées ; seule `libncursesw` requise par l'émulateur
Erlang reste livrée. Le terminfo complet, les moteurs de test et tous les
fichiers `.orig` ou `.key` sont également retirés. Les
PEM de démonstration contenant une clé privée sont interdits ; l'unique exception
de chemin est `lib/pkix-*/priv/cacert.pem`, certificat CA public requis par la
bibliothèque PKIX.
Les notices des composants redistribués sont copiées sous
`share/maerxmppserver/licenses` avant cet élagage.

L'inventaire `installed_application_versions` est réécrit en même temps pour
ne plus annoncer les cinq applications OTP retirées. L'installateur OTP
post-build et les lanceurs embarqués `start`/`start_erl`, qui dépendaient de
`run_erl` volontairement absent du runtime MAER, sont supprimés ; la recette
échoue si une référence à `run_erl` ou un lien symbolique orphelin subsiste.

Tous les modules BEAM sont réécrits par `beam_lib:strip_files/1` avec l'OTP natif
verrouillé. Le code exécutable est conservé, tandis que les sections de debug et
d'informations de compilation qui révélaient le checkout de build disparaissent.
Les métadonnées compilées dans `beam.smp` et `libcrypto.so.3` sont neutralisées
à la source. `beam.smp` conserve toutefois l'identifiant relatif amont
`arm-unknown-linux-gnueabi/opt/emu/erl_poll.flbk.c` utilisé pour nommer un
fichier source OTP dans un diagnostic interne. Il ne contient ni racine hôte,
ni nom d'utilisateur, ni checkout de build et n'est donc pas réécrit après
l'édition de liens. Les racines absolues et les noms du checkout restent
interdits par le validateur. Enfin, chaque ELF dynamique est normalisé avec un unique RPATH
`/var/packages/maerxmppserver/target/lib`; la recette échoue si un chemin de
build ou un RPATH différent subsiste. La recette refuse aussi tout lien
symbolique orphelin et toute dépendance ELF `NEEDED` qui n'est ni livrée dans le
paquet ni explicitement fournie par le socle DSM 7.

Après génération des scripts DSM, un hook de service impose également le mode
`0755` au `scripts/service-setup` final avant la création de l'archive externe.
