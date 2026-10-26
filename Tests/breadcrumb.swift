import Foundation

// L'arithmétique pop/push du fil d'Ariane — l'endroit exact d'où venait le bug « le fil
// d'Ariane bouclait ». `Breadcrumb.trail` est vérifié dans links.swift ; ici, ce qu'un appui
// sur une miette fait à la pile.
func checkClimb() {
    // Descente depuis la racine : piste Freebox/NAS/Photos/Été (profondeur 4), pile à 3.
    // Chaque miette remonte d'exactement les niveaux qui la séparent du dossier courant.
    assert(Breadcrumb.move(toStep: 2, of: 4, stacked: 3) == .pop(levels: 1),
           "la miette juste au-dessus dépile un niveau")
    assert(Breadcrumb.move(toStep: 1, of: 4, stacked: 3) == .pop(levels: 2),
           "deux crans plus haut, deux niveaux")
    assert(Breadcrumb.move(toStep: 0, of: 4, stacked: 3) == .pop(levels: 3),
           "la racine vide toute la pile")

    // Arrivée de côté — « Aller dans » depuis une recherche : la pile ne contient pas les
    // ancêtres, il n'y a rien à dépiler, la miette se pousse.
    assert(Breadcrumb.move(toStep: 1, of: 4, stacked: 1) == .push,
           "un ancêtre jamais visité se pousse au lieu de dépiler")
    assert(Breadcrumb.move(toStep: 0, of: 4, stacked: 2) == .push,
           "même la racine, quand la pile est plus courte que la remontée")

    // La frontière : autant d'entrées que de niveaux à remonter, on dépile tout juste.
    assert(Breadcrumb.move(toStep: 0, of: 3, stacked: 2) == .pop(levels: 2),
           "pile exactement assez profonde : on dépile, on ne pousse pas")

    print("ok — l'arithmétique du fil d'Ariane (dépiler ou pousser)")
}
