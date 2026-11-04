## Carte 1 — Date de dernière mise à jour des données

L'API renvoie la date de la dernière mise à jour des données dans chaque réponse, pour que le front puisse l'afficher.
Critères d'acceptation : champ `mis_a_jour_le` (ISO 8601, UTC) dans les réponses de `/donnees` ; absent = erreur.
