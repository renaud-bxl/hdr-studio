# HDR Studio

Application macOS pour transformer des photos SDR en photos HDR (gain map Apple)
et des vidéos en Dolby Vision 10 bits (profil 8.1). Fenetre a deux onglets,
glisser-deposer, traitement en lot.

## Installation (terminal)

```bash
git clone https://github.com/renaud-bxl/hdr-studio.git
cd hdr-studio
./install.sh
```

Le script installe au besoin ffmpeg, dovi_tool et gpac (via Homebrew), compile
l'application et la depose sur le Bureau.

Prerequis : Mac Apple Silicon, macOS 14+, Homebrew, outils Xcode
(`xcode-select --install`).

## Utilisation

- Onglet **Photo** : glisse tes photos, choisis le dossier d'export, clique
  « Exporter en HDR ». Les fichiers `_HDR.heic` sont crees dans le dossier choisi.
- Onglet **Video** : glisse tes videos, choisis le dossier d'export, clique
  « Exporter en Dolby Vision ». Les fichiers `_DV.mp4` sont crees dans le dossier.

En ligne de commande :

```bash
~/.local/bin/hdrphoto photo1.jpg photo2.jpg
~/.local/bin/hdrvideo.sh video.mp4 /dossier/sortie
```

## A savoir (honnete)

- Partir d'une source SDR donne une **mise en valeur** HDR, pas une recuperation
  de details perdus dans les hautes lumieres.
- Pour une **distribution publique** de l'app :
  - il faut un compte **Apple Developer** (99 $/an) pour signer et notariser,
    sinon macOS bloque l'ouverture ;
  - « Dolby Vision » est une marque et un format proprietaires ; diffuser un
    produit public qui en porte le nom releve en principe d'une licence Dolby.
    Sans licence, privilegier l'angle « HDR / HLG 10 bits ».

## Technique

- Photo : Core Image, gain map ISO 21496-1, sortie HEIC Display P3.
- Video : x265 (base HDR10 PQ 10 bits) + dovi_tool (RPU 8.1) + MP4Box
  (signalisation dvcC).
