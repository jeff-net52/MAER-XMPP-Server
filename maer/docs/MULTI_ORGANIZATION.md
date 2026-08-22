# Architecture multi-organisation

## Contrat client–serveur

Une organisation possède quatre métadonnées publiques :

| Champ | Rôle |
|---|---|
| `id` | identifiant stable enregistré par Maer Chat |
| `display_name` | libellé lisible affiché à l’utilisateur |
| `xmpp_domain` | virtual host ejabberd et domaine du JID |
| `default` | choix initial d’une installation neuve |

Exemple : le choix « MAER Engineering » produit
`utilisateur@contacts.chaumont.me`. Le mot de passe n’est jamais placé dans le
catalogue et n’est envoyé qu’au virtual host sélectionné, après validation TLS
du domaine.

Le catalogue est de la découverte, pas une autorisation. Un client modifié
peut saisir n’importe quel JID ; ejabberd ou le fournisseur d’identité doit donc
refuser tout compte absent, suspendu ou sans abonnement actif.

La version 1 du client embarque le catalogue dans l’APK. Cela évite qu’une
altération du réseau redirige les identifiants vers un domaine hostile. Si un
catalogue distant devient nécessaire, le publier en HTTPS et signer le contenu
ou sa version avec une clé de publication épinglée dans l’application. Une
simple réponse JSON distante non authentifiée ne suffit pas.

## Deux niveaux de cloisonnement

### Offre mutualisée

Plusieurs domaines figurent dans `hosts`. ejabberd sépare les identités et, avec
le nouveau schéma SQL, les données fonctionnelles par la colonne
`server_host`. Les services MUC, PubSub/PEP, vCard, archives MAM et upload sont
instanciés pour chaque virtual host via `@HOST@`.

Ce niveau est une séparation logique, pas une isolation d’infrastructure : le
processus, le compte SQL, les sauvegardes, les journaux et l’administration
restent partagés. De plus, deux domaines locaux peuvent communiquer si aucune
politique supplémentaire ne l’interdit. Ne pas vendre cette variante comme une
instance physiquement dédiée.

Le modèle limite l’accès, la création, la persistance et les archives MUC aux
comptes locaux provisionnés. Les nouveaux salons sont non publics, non listés
et réservés à leurs membres. Autoriser la fédération ou les invitations par les
utilisateurs doit être une décision explicite liée au contrat, suivie de tests
d’isolation entre organisations.

### Offre dédiée — recommandée pour une messagerie privée clé en main

Déployer une instance (ou un conteneur) MAER XMPP Server par organisation, avec
son domaine, sa base, son stockage d’upload, ses certificats, ses clés TURN, ses
sauvegardes et ses droits d’administration. Ce modèle rend aussi la suppression
contractuelle et la restauration d’un tenant indépendantes.

Le catalogue côté client reste identique : seul le domaine change. Cette
séparation est celle à utiliser lorsqu’un contrat promet un cloisonnement fort,
une localisation spécifique des données ou une rétention propre au client.

## Provisionnement d’une organisation

1. Attribuer un `id` immuable et un domaine XMPP contrôlé par le client ou MAER.
2. Choisir explicitement le niveau mutualisé ou dédié dans le contrat.
3. Créer le DNS du domaine, les enregistrements SRV client et, selon la
   politique, serveur-à-serveur ; obtenir les certificats correspondants.
4. Ajouter le domaine à `hosts` ou créer le déploiement dédié.
5. Appliquer les migrations du nouveau schéma SQL et créer les comptes par le
   canal d’administration ; l’inscription publique reste désactivée.
6. Ajouter uniquement les quatre métadonnées publiques au catalogue, valider le
   schéma et vérifier qu’un seul tenant est marqué par défaut.
7. Valider la configuration avec l’exécutable de la version déployée, puis
   tester avec deux comptes sans réutiliser d’identifiants de production.
8. Tester TLS/SRV, authentification, avatars PEP/vCard, MAM, Carbons, Stream
   Management, OMEMO multi-appareil, upload, salons MUC, blocage et sauvegarde.
9. Publier la nouvelle application ou le catalogue signé, puis surveiller le
   service avant l’ouverture commerciale.

## Retrait ou suspension

La suspension commerciale doit être imposée côté authentification. Masquer une
organisation dans l’application n’invalide pas les sessions ni les clients
XMPP tiers. Pour un retrait définitif : suspendre les comptes, révoquer les
jetons et sessions, appliquer la durée de conservation contractuelle, exporter
si prévu, supprimer les données du tenant, retirer DNS/certificats et seulement
ensuite retirer le catalogue.

## Vérifications de licence

Les fichiers MAER distribués avec ce fork restent sous GNU GPL v2. Conserver
`COPYING`, l’exception OpenSSL, les en-têtes, la provenance et le lien vers
l’amont. Toute distribution binaire doit être accompagnée de l’accès au code
source correspondant selon la GPL. La facturation porte sur le service,
l’hébergement et le support ; elle ne doit pas être présentée comme une
restriction de la licence libre du serveur.
