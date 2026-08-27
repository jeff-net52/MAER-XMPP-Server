# Paquet Synology — MAER XMPP Server

Cette arborescence constitue la première tranche revue et testable du paquet
DSM 7. Elle ne contient aucun binaire précompilé et n'effectue aucune action
sur un NAS.

## Contrat du paquet

| Propriété | Valeur |
|---|---|
| Identifiant | `maerxmppserver` |
| Nom affiché | `MAER XMPP Server` |
| Version SPK | `26.07.0-2` |
| Architecture | `armada38x` uniquement |
| DSM minimal | `7.2-72806` |
| Compte de service | `sc-maerxmppserver`, jamais `root` |
| Domaine XMPP | `xmpp.maer.fr` uniquement |

`spksrc` génère `conf/privilege` à partir de `SERVICE_USER = auto`. Pour DSM 7,
le contrat résultant est `run-as: package`, utilisateur
`sc-maerxmppserver`, groupe `synocommunity`. Aucun fichier `privilege` manuel
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
| `config` | `ejabberd.yml`, `ejabberdctl.cfg`, `inetrc` | `0700`; fichiers `0600` |
| `certs` | certificat et clé combinés `xmpp.pem` | `0700`; fichier exigé `0400` ou `0600` |
| `data` | SQLite et données Mnesia techniques | `0700` |
| `log` | journaux et crash dumps Erlang | `0700` |
| `run` | PID ejabberd | `0700` |
| `upload` | pièces jointes HTTP Upload | `0700`; fichiers `0600` |

Les configurations existantes ne sont jamais écrasées pendant une mise à
niveau. Le script ne réaffecte pas `HOME` : DSM fournit l'environnement du
compte de paquet et Erlang y gère son cookie. Aucun mot de passe, cookie,
jeton, secret TURN ou clé privée n'est présent dans le dépôt.

Le service refuse volontairement de démarrer tant qu'un PEM combiné lisible
par le compte de paquet n'est pas installé à
`/var/packages/maerxmppserver/var/certs/xmpp.pem`. Le profil ne crée pas non
plus le compte `admin@xmpp.maer.fr`; le bootstrap sécurisé de ce compte fera
l'objet d'une tranche distincte.

## Profil fonctionnel initial

Le profil active les transports clients STARTTLS, BOSH et WebSocket, les
archives MAM, les salons MUC privés, HTTP Upload, les fonctions PubSub/PEP
nécessaires à OMEMO, les abonnements push et l'authentification rapide. Les
mots de passe nouvellement enregistrés sont stockés uniquement en
SCRAM-SHA-256 dans SQLite.

Cette tranche active l'association sécurisée MAER sur la route HTTPS
`/maer-pairing` du seul listener TLS public 5443. Le module limite les sessions
par IP et globalement, exige l'approbation d'un compte authentifié du domaine
canonique, crée sa table Mnesia persistante au démarrage et refuse explicitement
un schéma incompatible. Elle désactive implicitement ou explicitement les autres
surfaces qui ne sont pas encore prêtes : inscription publique, API HTTP
d'administration, fédération serveur-à-serveur et découverte STUN/TURN.
Le signalement Jingle audio/vidéo transite déjà par XMPP, mais les appels hors
LAN nécessiteront un service TURN séparé avec secrets éphémères avant d'être
annoncés aux clients.

## Provenance reproductible

[`LOCKS.json`](LOCKS.json) verrouille :

- `spksrc` au commit `954871e356f7f990c179eb58af11c20d82872d8f` ;
- le toolchain `armada38x-7.1` (GCC 8.5.0, glibc 2.26) ;
- Erlang/OTP `27.3.4.16` et ses empreintes ;
- OpenSSL `3.5.7` et ses empreintes, construit par une recette MAER dédiée qui
  neutralise les chemins et options de compilation incorporés et fixe
  `SOURCE_DATE_EPOCH` à la date publique de cette version ;
- la source publique MAER au commit immuable
  `444c56576df676b37437c3de490cd904d7bca840`, et les empreintes exactes de
  son archive GitHub.

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
composants et licences attendus, et refuse les sources, exemples, documentation,
archives statiques, applications OTP de développement, outils, clés privées,
chemins de build et dépendances runtime non résolues qui n'ont rien à faire dans
le runtime livré.

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
`packages/maerxmppserver_armada38x-7.1_26.07.0-2.spk`, à la racine du checkout
`spksrc`.

Après le build, valider le SPK réel, y compris `INFO`, `conf/privilege` et les
modes des scripts :

```powershell
pwsh -NoProfile -File packaging/synology/tests/validate-source.ps1 -SpkPath /chemin/vers/maerxmppserver_armada38x-7.1_26.07.0-2.spk
```

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
