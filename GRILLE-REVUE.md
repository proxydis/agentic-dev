# Grille de revue d'un lot

Grille commune : le relecteur s'en sert pour la revue (étapes `revue` et `revue-livraison` de `cycle-lot`), l'agent
développeur pour sa relecture de fin de lot (cadre de la passe FIN de `run-lot.sh`). Les mêmes critères des deux
côtés : moins de surprises en revue, donc moins d'aller-retours. Le cycle s'arrête au 3e verdict À REPRENDRE.

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

## Classement des points

- **BLOQUANT** : enfreint une règle du projet, régression, carte non faite, test absent sur une correction.
- **NON BLOQUANT** : défaut réel, sans risque pour l'utilisateur ni perte d'information (libellé, cohérence, test du
  cas voisin manquant, lisibilité).
- **HORS PÉRIMÈTRE** : idée ou défaut ancien que le lot n'a pas touché. Il devient une carte de la version suivante et
  n'entraîne pas À REPRENDRE.

Verdict : **À REPRENDRE** dès qu'il reste un point BLOQUANT **ou** NON BLOQUANT. **À MERGER** sinon.

## Rapporter tout, dès la première revue

- La première revue est exhaustive : tous les points, avec `fichier:ligne`, le constat, la correction attendue et la
  carte concernée.
- Une revue de correction vérifie chaque point du rapport précédent, puis ce que les corrections touchent (diff de la
  reprise, appelants, tests). Un défaut non bloquant découvert tard dans du code que le lot n'a pas modifié devient une
  carte de la version suivante. Un défaut bloquant reste toujours un point bloquant.

## Format du rapport

1. Tableau carte -> verdict (validée / à reprendre) et justification.
2. Points BLOQUANTS, puis NON BLOQUANTS, numérotés (N1, N2…) : `fichier:ligne`, constat, correction attendue, carte.
3. Points HORS PÉRIMÈTRE proposés pour la version suivante.
4. Tests joués (ciblés, Playwright) et leurs résultats.
5. Dernière ligne : `VERDICT: À MERGER` ou `VERDICT: À REPRENDRE`.
