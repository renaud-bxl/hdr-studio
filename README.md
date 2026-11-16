# HDR Studio

Une app native pour macOS qui exporte tes photos en **HEIC HDR 10 bits** et tes vidéos en **Rec. 2100 HLG, PQ ou Dolby Vision 8.4**. Les fichiers sont traités sur le Mac.

[Voir la page de présentation et d’installation](https://hdr-studio-mac.rblbxl.chatgpt.site).

1. Choisis l’onglet **Photo** ou **Vidéo**.
2. Glisse tes fichiers dans la zone de dépôt ou clique sur **Choisir des fichiers…**.
3. Dans **Photo**, sélectionne un fichier dans la liste, règle **Intensité HDR** et clique sur **Sans effet** pour comparer. Dans **Vidéo**, choisis **Rec. 2100 HLG**, **Rec. 2100 PQ** ou **Dolby Vision 8.4**.
4. Clique sur **Traiter** et choisis le dossier dans lequel exporter les résultats.

L’app traite les lots fichier par fichier. Clique sur **Exporté** pour retrouver le fichier dans le Finder. Les originaux sont conservés. Si un fichier du même nom existe, le nouvel export reçoit un numéro.

## Installation

Sur un Mac Apple Silicon (M1 ou plus récent) avec macOS 14 ou supérieur, connecte [GitHub CLI](https://cli.github.com/) au compte autorisé à accéder à ce dépôt avec `gh auth login`. Si nécessaire, installe GitHub CLI avec `brew install gh`.

Colle ensuite cette commande dans Terminal :

```sh
( script="$(mktemp)" && trap 'rm -f "$script"' EXIT && gh api --hostname github.com -H 'Accept: application/vnd.github.raw+json' repos/renaud-bxl/hdr-studio/contents/Scripts/install-macos >"$script" && /bin/bash "$script" )
```

La commande télécharge la dernière version publiée, vérifie l’archive et installe ou met à jour l’app dans `~/Applications`, sans `sudo`. Si nécessaire, elle utilise Homebrew pour installer FFmpeg et libheif.

Tu peux aussi [télécharger l’archive sur GitHub](https://github.com/renaud-bxl/hdr-studio/releases/latest), l’ouvrir et lancer **HDR Studio.app**. La conversion vidéo utilise FFmpeg. L’encodeur photo est natif ; libheif sert de solution de repli si l’encodeur macOS est indisponible.

Avec Homebrew :

```sh
brew install ffmpeg libheif
```

Pour compiler depuis les sources (sur Apple Silicon ou Intel), installe les outils de ligne de commande Xcode si nécessaire (`xcode-select --install`), puis :

```sh
./Scripts/build-app
open "dist/HDR Studio.app"
```

Le script crée aussi une archive dans `dist/`. L’app est signée pour un usage local, sans notarisation Apple. FFmpeg et libheif restent des dépendances externes.

Après compilation, `./Scripts/check-exports` génère des fichiers de test et vérifie l’aperçu photo, les exports HEIC, HLG et PQ, ainsi que l’export Dolby Vision. Le test Dolby Vision doit s’exécuter sur un Mac disposant de l’encodeur matériel compatible.

## Formats et rendu

- **Photo** : HEIC 10 bits, BT.2020 / PQ. Le curseur renforce les hautes lumières du lot en laissant les ombres en place. Sur une source déjà HDR, la plage d’origine est conservée jusqu’à 65 % et le rehaussement des zones les plus lumineuses commence au-delà. L’aperçu utilise le réglage d’export ; **Sans effet** permet de le comparer à l’image sans rehaussement. La luminosité visible dépend de l’écran.
- **Vidéo** : MOV, HEVC Main 10 et BT.2020, avec transfert HLG (`arib-std-b67`) ou PQ (`smpte2084`). L’app transforme les valeurs des pixels pour le transfert choisi et conserve l’audio pris en charge. Elle applique le rehaussement aux sources SDR ; un export HDR existant est converti à partir de sa base HDR compatible.
- **Dolby Vision 8.4** : MOV HEVC Main 10, base HLG, avec métadonnées dynamiques par image générées par l’encodeur natif de macOS. Le résultat peut être lu en HLG par un lecteur compatible HLG, et en Dolby Vision par un lecteur compatible avec le profil 8.4. Si l’encodeur ne produit pas la signalisation attendue, l’app indique l’échec au lieu d’exporter un simple HLG sous ce nom. Les modes standard HLG et PQ restent disponibles. Une source Dolby Vision sans base compatible (par exemple le profil 5) ne peut pas être convertie directement par cette app.
- À partir d’un JPEG ou d’une vidéo SDR, passer à 10 bits donne plus de précision au résultat du traitement ; le procédé ne récupère pas les détails déjà écrêtés à la prise de vue.

Références : [Rec. 2100 (UIT)](https://www.itu.int/rec/R-REC-BT.2100-3-202502-I/en), [HEIC HDR 10 bits (Apple)](https://developer.apple.com/videos/play/wwdc2023/10181/), [export Dolby Vision avec AVFoundation (Apple)](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf), [mode HDR dans Lightroom Classic (Adobe)](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/hdr-output.html).
