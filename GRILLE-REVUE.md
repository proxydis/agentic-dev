# Grille de revue d'un lot

Grille commune : le relecteur s'en sert pour la revue (étapes `revue` et `revue-livraison` de `cycle-lot`), l'agent
développeur pour sa relecture de fin de lot (cadre de la passe FIN de `run-lot.sh`). Les mêmes critères des deux
côtés : moins de surprises en revue, donc moins d'aller-retours. Le cycle s'arrête au 5e verdict À REPRENDRE, et à partir
de la 3e revue les points non bloquants partent en cartes du lot suivant (valeurs par défaut, réglables dans
`cycle-lot.json` : `max_aller_retours`, `revue_report_non_bloquants`).

## Les règles du projet

Les règles d'arbitrage du projet (`regles-arbitrage.md`) tranchent les décisions de l'agent développeur et servent de
référence à chaque point de revue.

## Pour chaque carte

- **Conforme à la carte et aux arbitrages** (`arbitrages.md` du dossier du lot) : tout ce que la carte demande, rien de
  plus.
- **Tests** : un test qui échoue sans la correction et passe avec, plus le test du cas voisin, dont le comportement ne
  change pas. Couverture suffisante du code ajouté.
- **Appelants vérifiés** : chaque fonction modifiée est relue avec ceux qui l'appellent, côté back et côté front.
- **Rien hors du périmètre** : pas de changement sans carte ni arbitrage.
- **Même donnée, même rendu** partout où elle apparaît (écran, export, document) : même texte, même valeur, même unité.
- **Textes pour l'utilisateur** : dans sa langue, sans jargon technique ni nom de champ.
- **Lisibilité** : noms explicites, pas de commentaire inutile, pas de code mort.
- **Sécurité basique** : pas de secret dans le code, pas d'injection, entrées validées, dépendances sans avis critique.
- **Parcours Playwright** sur la version déployée du lot pour chaque carte visible de l'utilisateur : le parcours de la
  carte, puis un parcours voisin non touché (non-régression). Captures jointes au rapport.
- **Preuve en réel** pour chaque critère qui dépend d'un service externe (modèle d'IA, base de données hébergée, e-mail,
  captcha, source de données, stockage) : la commande ou le parcours joué sur la préproduction et son résultat, dans le
  fichier que l'agent développeur donne à `cycle-lot passe --reel`. Un test sur des données fabriquées ne prouve pas que
  le service répond : un traitement qui n'a jamais tourné sur le vrai service avant la revue coûte des aller-retours, et
  peut encore échouer en production.
- **Réglages de déploiement** : chaque variable d'environnement, workflow à lancer, donnée à republier ou migration que la
  carte suppose est déclaré (`cycle-lot reglage <v> --ajouter`). Écrit seulement dans la PR, il est oublié à la
  livraison.

## Classement des points

- **BLOQUANT** : enfreint une règle du projet, régression, carte non faite, critère d'acceptation non tenu ou sans
  preuve en réel quand il dépend d'un service externe, test absent sur une correction.
- **NON BLOQUANT** : défaut réel, sans risque pour l'utilisateur ni perte d'information (libellé, cohérence, test du
  cas voisin manquant, lisibilité).
- **HORS PÉRIMÈTRE** : idée ou défaut ancien que le lot n'a pas touché. Il devient une carte de la version suivante et
  n'entraîne pas À REPRENDRE.

Verdict, selon le numéro de la revue (valeurs par défaut) :

- **Revues 1 et 2 : tout se corrige.** **À REPRENDRE** dès qu'il reste un point BLOQUANT **ou** NON BLOQUANT.
- **À partir de la 3e revue : seul un point BLOQUANT renvoie le lot.** Chaque point NON BLOQUANT devient une carte du lot
  suivant, créée pendant la revue par `cycle-lot carte-report` ; l'agent développeur ne le corrige pas dans ce lot. Sans
  bloquant, le verdict est **À MERGER**.
- **5 aller-retours au plus** : le 5e À REPRENDRE arrête le cycle, l'humain décide.
- **Un point découvert après la 1re revue dans du code inchangé depuis** est NON BLOQUANT, sauf s'il touche la sécurité :
  la 1re revue était le moment de le voir. Les points « vus tardivement » rallongent la boucle sans rien apprendre de la
  correction.
- **Voie courte** : après le merge du lot, un correctif qui ne touche que la CI, les tests ou la documentation se relit
  sur son diff, sans preview ni parcours Playwright, hors compteur d'aller-retours.

## Rapporter tout, dès la première revue

- La première revue est exhaustive : tous les points, avec `fichier:ligne`, le constat, la correction attendue et la
  carte concernée. Pour chaque carte, un tableau « critère d'acceptation | vérifié comment | résultat » : un critère
  sans ligne n'a pas été regardé. « Non vérifiable » se justifie, et devient un point bloquant si le critère dépend
  d'un service externe que l'agent développeur devait jouer en réel.
- Pour chaque point, nomme la **famille** du défaut et ses variantes voisines connues (autres tournures, autres
  écrans, autres chemins du même code) : l'agent développeur corrige la famille, pas le cas rapporté.
- Une revue de correction vérifie chaque point du rapport précédent, puis ce que les corrections touchent (diff de la
  reprise depuis la tête revue, plage donnée par le relais ; appelants, tests). Pas de nouvelle revue complète. Un défaut non bloquant découvert tard dans du code que le lot n'a pas modifié devient une
  carte de la version suivante. Un défaut bloquant reste toujours un point bloquant.

## Corriger la famille, pas le cas (agent développeur)

Une correction au cas par cas laisse passer la variante suivante du même défaut, et chaque variante coûte un
aller-retour de plus sur le même point. Pour chaque point du rapport :

1. Énumère les variantes voisines du défaut (table de cas dans la PR), au-delà de l'exemple du relecteur.
2. Écris un test paramétré qui les couvre et qui rougit, plus le test du cas voisin qui ne doit pas changer.
3. Corrige à la racine, puis vérifie les appelants.
4. Avant `cycle-lot passe`, une passe distincte relit le diff de la reprise avec cette grille, avec pour seule consigne
   de chercher ce que la correction casse, oublie ou laisse passer (contre-relecture). Son rapport est exigé par
   `cycle-lot passe --contre-relecture`.

## Format du rapport

1. Tableau carte -> verdict (validée / à reprendre) et justification.
2. Points BLOQUANTS, puis NON BLOQUANTS, numérotés (N1, N2…) : `fichier:ligne`, constat, famille du défaut,
   correction attendue, carte. À partir de la 3e revue, chaque point non bloquant porte le lien de sa carte reportée.
3. Points HORS PÉRIMÈTRE proposés pour la version suivante.
4. Tests joués (ciblés, Playwright) et leurs résultats.
5. Dernière ligne : `VERDICT: À MERGER` ou `VERDICT: À REPRENDRE`.
