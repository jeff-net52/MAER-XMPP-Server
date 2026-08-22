# Synchronisation avec ejabberd amont

Le remote `upstream` doit toujours pointer vers
<https://github.com/processone/ejabberd>. Le remote `origin` pointe vers le fork
public MAER.

La branche `master` du fork suit l’amont sans modification MAER. Les versions
MAER sont préparées depuis un tag stable exact sur une branche
`maer/<version-ejabberd>`, par exemple `maer/26.07`.

Avant une mise à niveau :

1. lire les notes de version, migrations SQL et avis de sécurité amont ;
2. créer une branche depuis le nouveau tag signé ou annoté ;
3. réappliquer la couche `maer/` et les avis datés ;
4. construire et tester sur une instance de préproduction avec une copie
   anonymisée ou dédiée des données ;
5. valider configuration, sauvegarde, restauration et retour arrière ;
6. publier le commit source exact correspondant au binaire déployé.

Ne jamais déployer directement `upstream/master` en production.
