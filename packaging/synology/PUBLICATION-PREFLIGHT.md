# Préflight de publication DSM

Ce profil publie un seul domaine, `xmpp.maer.fr`. Le paquet écoute XMPP sur
`0.0.0.0:5222`, la redirection HTTP sur `127.0.0.1:5080`, l'administration sur
`127.0.0.1:5280` et les transports HTTPS sur `127.0.0.1:5443`. Les ports 5080
et 5443 sont des backends locaux : ils ne doivent être ni ouverts dans le
pare-feu DSM, ni redirigés directement par le routeur.

## DNS public

Avant la bascule :

- `A xmpp.maer.fr` pointe vers l'adresse publique du site ;
- `_xmpp-client._tcp.xmpp.maer.fr SRV 0 5 5222 xmpp.maer.fr.` est publié ;
- aucun SRV S2S n'est publié pour ce profil privé ;
- l'ancien domaine retiré ne possède plus d'enregistrement DNS, de vhost, de
  règle de proxy ni de certificat.

## Reverse proxy DSM

Créer une règle HTTPS publique sur `xmpp.maer.fr:443` vers
`https://127.0.0.1:5443`. Elle doit conserver l'en-tête `Host:
xmpp.maer.fr`, accepter WebSocket et ne publier que ces préfixes :

- `/.well-known/host-meta` et `/.well-known/host-meta.json` ;
- `/http-bind` ;
- `/xmpp-websocket` ;
- `/upload` ;
- `/maer-pairing`.

Créer également une règle HTTP publique sur `xmpp.maer.fr:80` vers
`http://127.0.0.1:5080`. Ce backend dédié ne sert aucun contenu : il répond
uniquement `301 Location: https://xmpp.maer.fr/`.

Ne jamais publier `/admin`, `/api` ou le port 5280. Remplacer les en-têtes
d'adresse client à l'entrée du proxy au lieu de concaténer une valeur fournie
par le client. Limiter les corps de `/maer-pairing` à 16 Kio et appliquer une
seconde limitation de débit. Le certificat public et le PEM du backend doivent
couvrir `xmpp.maer.fr`; le proxy doit vérifier le certificat du backend.

Le serveur ne fait confiance pour `X-Forwarded-For` qu'aux réseaux loopback
`127.0.0.0/8` et `::1/128`. La source du reverse proxy DSM doit donc rester
loopback et sa règle doit écraser toute valeur `X-Forwarded-For` fournie par le
client. La confiance globale `all` est interdite.

Le proxy doit remplacer les éventuels en-têtes amont avec les valeurs suivantes :

```text
Access-Control-Allow-Origin: https://xmpp.maer.fr
Content-Security-Policy: default-src 'none'; frame-ancestors 'none'
Referrer-Policy: no-referrer
Strict-Transport-Security: max-age=31536000
Vary: Origin
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
```

Le serveur vérifie en plus l'en-tête de poignée de main WebSocket avec
`websocket_origin: https://xmpp.maer.fr`. Une origine de navigateur différente
doit recevoir un refus 403 ; les clients natifs sans en-tête `Origin` restent
acceptés par ejabberd.

Le port 80 doit rediriger en 301/308 vers HTTPS, à l'exception éventuelle d'un
chemin ACME strictement borné. Le pare-feu et la redirection NAT doivent exposer
uniquement 80, 443 et 5222 pour ce service. Les ports 5080, 5269, 5280 et 5443
restent inaccessibles depuis Internet. EPMD 4369 et le port fixe de
distribution Erlang 5211 sont également privés. TLS 1.0 et TLS 1.1 doivent être
refusés sur HTTPS 443 comme après STARTTLS sur XMPP 5222.

Le quota Upload est de 500 Mio souple et 600 Mio dur par compte, avec une
rétention maximale de 30 jours. Programmer aussi
`/var/packages/maerxmppserver/target/bin/maer-upload-usage-check` dans le
Planificateur DSM : son code 1 signale 80 % d'occupation du volume, son code 2
signale 90 %, et sa sortie contient la consommation Upload globale en Mio.

## Contrôle automatisé après installation

Depuis une machine extérieure au LAN :

```powershell
pwsh -NoProfile -File packaging/synology/dsm-publication-preflight.ps1 -RetiredDomain 'retired-domain.example'
```

Remplacer impérativement `retired-domain.example` par le FQDN réellement retiré.
Le préflight exige son absence DNS/SRV et la fermeture de ses anciens ports
publics ; le nom historique n'est volontairement pas conservé dans le dépôt.

Le préflight vérifie DNS/SRV, ports, certificat HTTPS, host-meta, BOSH,
WebSocket, refus d'une origine WebSocket hostile, upload, pairing, CORS,
en-têtes, redirection HTTP, absence des surfaces d'administration/API, puis
STARTTLS 5222, refus explicite de TLS 1.0/1.1, certificat XMPP, mécanismes SASL,
valeurs exactes des en-têtes et refus propre de l'inscription publique. Il est
volontairement en échec tant que l'ancien serveur ou une règle DSM incomplète
répond encore.

Après un résultat vert, effectuer deux tests authentifiés : un échange XMPP
entre comptes jetables puis le parcours complet QR Android → approbation →
authentification OAuth Windows → révocation → refus de reconnexion.
