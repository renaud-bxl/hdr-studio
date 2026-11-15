#!/bin/bash
# hdrvideo - convertit une video en Dolby Vision 10 bits Profil 8.1 (base HDR10)
# via x265 + dovi_tool + MP4Box. Usage: hdrvideo.sh <source> <dossier_destination>
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

src="$1"; dest="$2"
[ -f "$src" ] || { echo "Introuvable: $src"; exit 1; }
base=$(basename "$src"); name="${base%.*}"
out="$dest/${name}_DV.mp4"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Images et cadence
frames=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of default=nw=1:nk=1 "$src" 2>/dev/null)
case "$frames" in ''|*[!0-9]*) frames=0;; esac
if [ "$frames" -lt 1 ]; then
  frames=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$src" 2>/dev/null)
  case "$frames" in ''|*[!0-9]*) frames=0;; esac
fi
[ "$frames" -lt 1 ] && { echo "Nombre d'images indetermine"; exit 1; }
rfr=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=nw=1:nk=1 "$src" 2>/dev/null)
fps=$(awk -v r="$rfr" 'BEGIN{n=split(r,a,"/"); if(n==2 && a[2]+0>0) printf "%.4f", a[1]/a[2]; else printf "%s", r}')
[ -z "$fps" ] && fps=25

# Audio present ?
has_audio=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$src" 2>/dev/null)

# 1. Base HDR10 10 bits PQ
ffmpeg -y -i "$src" -an -pix_fmt yuv420p10le -c:v libx265 \
  -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400:hdr10=1:repeat-headers=1" \
  -f hevc "$work/base.hevc" 2>"$work/enc.log" || { echo "Echec encodage"; tail -2 "$work/enc.log"; exit 1; }

# 2. RPU Dolby Vision 8.1
printf '{"cm_version":"V40","length":%s,"level6":{"max_display_mastering_luminance":10000,"min_display_mastering_luminance":1,"max_content_light_level":1000,"max_frame_average_light_level":400}}' "$frames" > "$work/dv.json"
dovi_tool generate -j "$work/dv.json" -o "$work/rpu.bin" >/dev/null 2>&1 || { echo "Echec generation RPU"; exit 1; }

# 3. Injection
dovi_tool inject-rpu -i "$work/base.hevc" --rpu-in "$work/rpu.bin" -o "$work/dv.hevc" >/dev/null 2>&1 || { echo "Echec injection RPU"; exit 1; }

# 4. Mux avec signalisation Dolby Vision (boite dvcC) + audio
MP4Box -add "$work/dv.hevc:dv-profile=8.1:fps=$fps" -new "$out" >/dev/null 2>&1 || { echo "Echec mux video"; exit 1; }
if [ -n "$has_audio" ]; then
  MP4Box -add "${src}#audio" "$out" >/dev/null 2>&1 || true
fi

echo "$out"
