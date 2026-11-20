"""Vérifie, sur un log de chaîne de run-lot.sh, que deux parties mécaniques ne se chevauchent jamais (piste B).

    python3 -I meca-sequentielles.py <log de chaîne>      sortie 0 : jamais deux à la fois
"""
import re
import sys

debut = re.compile(r"=== étape \S+ : partie mécanique sans Claude")
fin = re.compile(r"(OK étape \S+ : partie mécanique verte|étape \S+ : partie mécanique ROUGE"
                 r"|ÉCHEC étape \S+ : la partie mécanique|ÉCHEC préparation \S+ \(partie mécanique\))")
en_cours = 0
for ligne in open(sys.argv[1], encoding="utf-8"):
    if debut.search(ligne):
        en_cours += 1
        if en_cours > 1:
            print(f"chevauchement : {ligne.strip()}")
            sys.exit(1)
    elif fin.search(ligne):
        en_cours -= 1
sys.exit(0)
