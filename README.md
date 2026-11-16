# HDR Studio

Une app native pour macOS qui exporte tes photos en **HEIC HDR 10 bits** et tes vidéos en **HEVC Main 10, Rec. 2100 HLG ou PQ**. Les fichiers sont traités sur le Mac.

[Voir la page de présentation et d’installation](https://hdr-studio-mac.rblbxl.chatgpt.site).

1. Choisis l’onglet **Photo** ou **Vidéo**.
2. Glisse tes fichiers dans la zone de dépôt ou clique sur **Choisir des fichiers…**.
3. Pour une vidéo, choisis **Rec. 2100 HLG** ou **Rec. 2100 PQ**.
4. Clique sur **Traiter** et choisis le dossier dans lequel exporter les résultats.

L’app traite les lots fichier par fichier. Clique sur **Exporté** pour retrouver le fichier dans le Finder. Les originaux sont conservés. Si un fichier du même nom existe, le nouvel export reçoit un numéro.

## Installation

Sur un Mac Apple Silicon (M1 ou plus récent) avec macOS 14 ou supérieur, connecte [GitHub CLI](https://cli.github.com/) au compte autorisé à accéder à ce dépôt avec `gh auth login`. Si nécessaire, installe GitHub CLI avec `brew install gh`.

Colle ensuite cette commande dans Terminal :

```sh
( script="$(mktemp)" && trap 'rm -f "$script"' EXIT && gh api --hostname github.com -H 'Accept: application/vnd.github.raw+json' repos/renaud-bxl/hdr-studio/contents/Scripts/install-macos >"$script" && /bin/bash "$script" )
```

La commande vérifie l’archive et installe l’app dans `~/Applications`, sans `sudo`. Si nécessaire, elle utilise Homebrew pour installer FFmpeg et libheif.

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

Après compilation, `./Scripts/check-exports` génère une photo et une vidéo de test, puis vérifie les trois formats exportés.

## Formats et rendu

- **Photo** : HEIC 10 bits, BT.2020 / PQ. Les hautes lumières d’une source SDR sont rehaussées progressivement ; les sources HDR reconnues conservent leur plage dynamique. La lecture des fichiers dépend des formats reconnus par macOS. Comme dans le mode HDR de Lightroom, l’éclat se voit sur un écran HDR dans une application qui prend en charge le format.
- **Vidéo** : MOV, HEVC Main 10 et BT.2020, avec transfert HLG (`arib-std-b67`) ou PQ (`smpte2084`). L’app transforme les valeurs des pixels pour le transfert choisi et conserve l’audio pris en charge. Elle applique le rehaussement aux sources SDR ; un export HDR existant est converti à partir de sa base HDR compatible.
- **Dolby Vision** : le rendu vise des hautes lumières plus lumineuses. Les fichiers exportés sont en Rec. 2100 ou en HEIC HDR, sans métadonnées dynamiques Dolby Vision. Un fichier Dolby Vision sans base HLG/PQ compatible ne peut pas être converti tel quel.
- À partir d’un JPEG ou d’une vidéo SDR, passer à 10 bits donne plus de précision au résultat du traitement ; le procédé ne récupère pas les détails déjà écrêtés à la prise de vue.

Références : [Rec. 2100 (UIT)](https://www.itu.int/rec/R-REC-BT.2100-3-202502-I/en), [HEIC HDR 10 bits (Apple)](https://developer.apple.com/videos/play/wwdc2023/10181/), [Dolby Vision pour la création (Dolby)](https://professional.dolby.com/content-creation/dolby-vision-for-content-creators/), [mode HDR dans Lightroom Classic (Adobe)](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/hdr-output.html).
