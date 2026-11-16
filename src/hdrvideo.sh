#!/bin/bash
# Convertit une vidéo en HEVC 10 bits HDR (PQ, BT.2020), avec ou sans métadonnées Dolby Vision 8.1.
# Usage : hdrvideo.sh <source> <sortie.mp4> [dv|hdr10] [stops]
#   stops : réserve de hautes lumières ajoutée aux sources SDR (défaut 2.0, soit un pic vers 800 nits)
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

src="${1:-}"; out="${2:-}"; mode="${3:-dv}"; stops="${4:-2.0}"
[ -f "$src" ] || { echo "Fichier introuvable"; exit 1; }
[ -n "$out" ] || { echo "Sortie non précisée"; exit 1; }

need="ffmpeg ffprobe MP4Box"
[ "$mode" = "dv" ] && need="$need dovi_tool"
for t in $need; do
  command -v "$t" >/dev/null 2>&1 || { echo "Outil manquant : $t (brew install ffmpeg gpac dovi_tool)"; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

probe() { ffprobe -v error -select_streams v:0 -show_entries "stream=$1" -of default=nw=1:nk=1 "$src" 2>/dev/null | head -1; }
trc=$(probe color_transfer)
mtx=$(probe color_space)
afr=$(probe avg_frame_rate)
case "$afr" in ""|"0/0"|"N/A") afr=$(probe r_frame_rate) ;; esac
case "$afr" in ""|"0/0"|"N/A") afr="25/1" ;; esac
fps=$(awk -v r="$afr" 'BEGIN{n=split(r,a,"/"); if(n==2 && a[2]+0>0) printf "%.5f", a[1]/a[2]; else printf "%s", r}')

# Courbes (expressions ffmpeg). L = signal normalisé, Y = luminance en fraction de 10 000 nits.
K=$(awk -v s="$stops" 'BEGIN{printf "%.4f", 2^s-1}')
peak=$(awk -v s="$stops" 'BEGIN{p=203*2^s; if(p>4000)p=4000; printf "%d", p}')
L="(val/maxval)"
pq() { echo "maxval*pow((0.8359375+18.8515625*pow($1,0.1593017578125))/(1+18.6875*pow($1,0.1593017578125)),78.84375)"; }

case "$trc" in
  smpte2084)
    # Déjà en PQ : on conserve le signal tel quel.
    vf="format=yuv420p10le"
    peak=1000
    ;;
  arib-std-b67)
    # HLG (iPhone) vers PQ : OETF inverse puis gamma système 1,2 pour un écran de 1000 nits.
    E="if(lte($L,0.5),$L*$L/3,(exp(($L-0.55991073)/0.17883277)+0.28466892)/12)"
    C=$(pq "min(1,0.1*pow($E,1.2))")
    vf="scale=in_color_matrix=bt2020,format=gbrp16le,lutrgb=r='$C':g='$C':b='$C',scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le"
    peak=1000
    ;;
  *)
    # SDR : linéarisation, passage BT.709 vers BT.2020, blanc de référence à 203 nits,
    # puis rehaussement progressif des hautes lumières jusqu'au pic choisi.
    case "$mtx" in bt470bg|smpte170m) inm="bt601" ;; *) inm="bt709" ;; esac
    LIN="maxval*pow($L,2.4)"
    C=$(pq "min(1,0.0203*$L*(1+$K*pow($L,3)))")
    vf="scale=in_color_matrix=$inm,format=gbrp16le,lutrgb=r='$LIN':g='$LIN':b='$LIN',colorchannelmixer=rr=0.6274:rg=0.3293:rb=0.0433:gr=0.0691:gg=0.9195:gb=0.0114:br=0.0164:bg=0.0880:bb=0.8956,lutrgb=r='$C':g='$C':b='$C',scale=out_color_matrix=bt2020:out_range=tv,format=yuv420p10le"
    ;;
esac
fall=$((peak / 4))

# Les lignes « P <pourcentage> » et « S <étape> » servent au suivi dans l'application.
dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$src" 2>/dev/null | head -1)
case "$dur" in ''|*[!0-9.]*) dur=0 ;; esac

# 1. Encodage de la base HDR10
echo "S Encodage"
ffmpeg -nostdin -y -progress pipe:1 -nostats -i "$src" -an -sn -vf "$vf" -r "$afr" -fps_mode cfr \
  -c:v libx265 -preset fast -crf 19 -pix_fmt yuv420p10le \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv \
  -x265-params "log-level=error:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=limited:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=$peak,$fall:hdr10=1:repeat-headers=1" \
  -f hevc "$work/base.hevc" 2>"$work/enc.log" \
  | awk -F= -v d="$dur" '$1=="out_time_us" && d>0 { p=int($2/10000/d); if(p>99)p=99; if(p!=last){ print "P " p; fflush(); last=p } }'
[ "${PIPESTATUS[0]}" -eq 0 ] || { echo "Échec de l'encodage : $(tail -1 "$work/enc.log")"; exit 1; }

video="$work/base.hevc"
addopt="fps=$fps"

# 2. Métadonnées Dolby Vision 8.1
if [ "$mode" = "dv" ]; then
  echo "S Métadonnées Dolby Vision"
  frames=$(ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of default=nw=1:nk=1 "$work/base.hevc" 2>/dev/null | head -1)
  case "$frames" in ''|*[!0-9]*) echo "Nombre d'images indéterminé"; exit 1 ;; esac
  printf '{"cm_version":"V40","length":%s,"level6":{"max_display_mastering_luminance":1000,"min_display_mastering_luminance":1,"max_content_light_level":%s,"max_frame_average_light_level":%s}}' \
    "$frames" "$peak" "$fall" > "$work/dv.json"
  dovi_tool generate -j "$work/dv.json" -o "$work/rpu.bin" >"$work/dv.log" 2>&1 || { echo "Échec des métadonnées Dolby Vision"; exit 1; }
  dovi_tool inject-rpu -i "$work/base.hevc" --rpu-in "$work/rpu.bin" -o "$work/dv.hevc" >>"$work/dv.log" 2>&1 || { echo "Échec de l'injection Dolby Vision"; exit 1; }
  video="$work/dv.hevc"
  addopt="dv-profile=8.1:fps=$fps"
fi

# 3. Audio : copie si possible, sinon AAC
echo "S Assemblage du fichier"
audio=""
if [ -n "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$src" 2>/dev/null | head -1)" ]; then
  if ffmpeg -nostdin -y -i "$src" -vn -sn -map 0:a:0 -c:a copy "$work/audio.m4a" >/dev/null 2>&1; then
    audio="$work/audio.m4a"
  elif ffmpeg -nostdin -y -i "$src" -vn -sn -map 0:a:0 -c:a aac -b:a 256k "$work/audio.m4a" >/dev/null 2>&1; then
    audio="$work/audio.m4a"
  fi
fi

# 4. Conteneur MP4 avec signalisation HDR / Dolby Vision
rm -f "$out"
if [ -n "$audio" ]; then
  MP4Box -quiet -add "$video:$addopt" -add "$audio" -new "$out" >"$work/mux.log" 2>&1 || { echo "Échec de l'assemblage MP4"; exit 1; }
else
  MP4Box -quiet -add "$video:$addopt" -new "$out" >"$work/mux.log" 2>&1 || { echo "Échec de l'assemblage MP4"; exit 1; }
fi
[ -s "$out" ] || { echo "Fichier de sortie vide"; exit 1; }
echo "OK"
