# Icône de Keo

Un K dont le fût est une cage de NAS : quatre baies dans un boîtier, et un bras qui en sort.

## La règle de construction

Le bras n'est pas posé à côté de la cage, il en **dérive**. Deux rapports à ne pas casser :

- son épaisseur vaut une hauteur de baie (26 contre 24) ;
- ses deux extrémités tombent sur l'axe de la première et de la dernière baie (y = 78 et 174).

Changer la cage sans recalculer le bras défait la marque : elle redevient deux objets côte à côte.

## Palette

| | Fond | Cage | Baies + bras |
|---|---|---|---|
| Any | `#e9a178` | `#cf8154` | `#ffffff` |
| Dark | *(transparent)* | `#7a4a30` | `#e9a178` |
| Tinted | *(transparent)* | `#6e6e6e` | `#ffffff` |

La cage est **toujours plus sombre que son environnement**, dans les trois variantes. C'est ce
rapport de luminance qui la fait exister ; en teinté iOS ne garde que la luminance, et une cage
trop proche du fond disparaît purement et simplement.

## Les trois variantes

Ce que demande iOS 18, vérifié sur la documentation Apple, pas supposé :

- **Any** : carré **plein et opaque**, sans coins arrondis. C'est le système qui masque.
  Arrondir soi-même produit un liseré sur le masque système.
- **Dark** : la marque sur **fond transparent**. Le système pose son propre fond sombre.
- **Tinted** : la marque en **niveaux de gris**, sur fond transparent. Le système applique la
  teinte de l'utilisateur d'après la luminance.

Sans ces deux dernières, iOS les fabrique tout seul — et il le fait mal sur une marque à deux tons.

## Reconstruire

```sh
python3 Design/icon/build.py
```

Écrit les trois SVG maîtres ici et les trois PNG 1024² dans
`Keo/Assets.xcassets/AppIcon.appiconset/`, avec le `Contents.json` qui déclare les apparences.
La géométrie ne vit qu'à un endroit, dans ce script : ne pas retoucher les SVG à la main, ils
sont regénérés.

Les maîtres ne contiennent **aucun trait** : le bras est un contour plein (deux demi-cercles de
rayon 13, une jonction ronde, une pointe intérieure en onglet). Un trait se déforme à la mise à
l'échelle non uniforme et ne se découpe pas proprement.

## Vérifier que les variantes sont bien passées

Une apparence absente du catalogue compilé ne produit aucune erreur de build :

```sh
xcrun assetutil --info ~/Library/Developer/Xcode/DerivedData/Keo-*/Build/Products/Debug-iphoneos/Keo.app/Assets.car \
  | grep -A1 AppIcon
```

Doit montrer `(any)`, `UIAppearanceDark` et `ISAppearanceTintable`.

## Ce qui a été essayé et écarté

- **Le chevron doublé** (profondeur du stockage) : se lit « retour rapide », le K disparaît.
- **Une baie assombrie** (le disque en cours de lecture) : se lit « disque manquant ».
- **La couture des baies prolongée à travers le bras** : même réduite à 5 unités, elle sectionne
  la pointe du K, qui en est la charnière.
- **Loquets, LED, grille de ventilation** : moins de 2 px à 60 px. Se bouchent et salissent.

## Aller plus loin côté matière

Pour une icône Liquid Glass (Xcode 26), importer les calques des SVG dans **Icon Composer** et
le laisser poser profondeur, matière et reflets. Ne pas tenter de les simuler dans le SVG.
