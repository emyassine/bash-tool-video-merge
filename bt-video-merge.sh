#!/usr/bin/env bash
set -uo pipefail
IFS=$'\n\t'

# bt-video-merge v0.4.1 — images + audio -> vertical video
#
# Duration logic:
# body_dur  = total_dur - intro_dur - outro_dur
# per_image = body_dur / n_images
#
# Features:
# - Natural sort for images (0, 1, 2... 10, 11)
# - Constant frame rate (30fps) to prevent missing frames
# - Proportional duration calculation
# - Background music (BGM) mixing with optional mute per segment

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'
readonly VERSION="1.4.1"
readonly -a SUPPORTED_IMAGE_EXTS=(jpg jpeg png webp bmp tiff tif gif avif)
readonly -a SUPPORTED_AUDIO_EXTS=(mp3 m4a aac wav ogg flac opus)
readonly -a SUPPORTED_VIDEO_EXTS=(mp4 mov avi mkv webm m4v)
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)
readonly TMP_DIR=".bt-tmp-${TIMESTAMP}"

AUDIO=""
OUTPUT="bt-video-merge-${TIMESTAMP}.mp4"
WIDTH=1080
HEIGHT=1920
BGMODE="black"
SORT_BY="alpha"
KEEP_TMP=false
INTRO=""
OUTRO=""
DURATION=""
VERBOSE=false
DRY_RUN=false
NON_INTERACTIVE=false

INTRO_DUR="2"
OUTRO_DUR="2"
FADE_DUR="0.5"
FADE_INTRO=true
FADE_OUTRO=true
MUTE_INTRO=false
MUTE_OUTRO=false
FPS=30

# =============================================================================
# UI & HELPERS
# =============================================================================
log()  { echo -e "${CYAN}  >>  ${RESET}$*"; }
ok()   { echo -e "${GREEN}  OK  ${RESET}$*"; }
warn() { echo -e "${YELLOW}  !!  ${RESET}$*"; }
err()  { echo -e "${RED}  XX  ${RESET}$*" >&2; }
info() { echo    "        $*"; }
blank(){ echo    ""; }

header() {
    local title="$1"
    local line="----------------------------------------------------"
    blank
    echo -e "${BOLD}  ${line}${RESET}"
    echo -e "${BOLD}    ${title}${RESET}"
    echo -e "${BOLD}  ${line}${RESET}"
    blank
}

summary_row() {
    local label="$1" value="$2"
    printf "    %-26s %s\n" "${label}" "${value}"
}

is_integer()  { [[ "$1" =~ ^[0-9]+$ ]]; }
is_positive() { is_integer "$1" && [[ "$1" -gt 0 ]]; }
is_float()    { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
file_ext()    { local f="${1##*.}"; echo "${f,,}"; }
ext_in_list() {
    local ext="$1"; shift
    local e; for e in "$@"; do [[ "$ext" == "$e" ]] && return 0; done
    return 1
}
is_image_file() {
    local ext; ext=$(file_ext "$1")
    ext_in_list "$ext" "${SUPPORTED_IMAGE_EXTS[@]}"
}
get_media_duration() {
    ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | awk '{printf "%.3f", $1}'
}
awk_gt() { awk "BEGIN { exit !($1 > $2) }"; }

# =============================================================================
# AUTO-DETECT & SORT
# =============================================================================
find_input_audio() {
    local ext
    for ext in "${SUPPORTED_AUDIO_EXTS[@]}" "${SUPPORTED_VIDEO_EXTS[@]}"; do
        [[ -f "input-audio.${ext}" ]] && { echo "input-audio.${ext}"; return 0; }
    done
    return 1
}
find_intro() {
    local ext
    for ext in "${SUPPORTED_VIDEO_EXTS[@]}" "${SUPPORTED_IMAGE_EXTS[@]}"; do
        [[ -f "intro.${ext}" ]] && { echo "intro.${ext}"; return 0; }
    done
    return 1
}
find_outro() {
    local ext
    for ext in "${SUPPORTED_VIDEO_EXTS[@]}" "${SUPPORTED_IMAGE_EXTS[@]}"; do
        [[ -f "outro.${ext}" ]] && { echo "outro.${ext}"; return 0; }
    done
    return 1
}
collect_images() {
    local ext f base
    local -a imgs=() filtered=()
    for ext in "${SUPPORTED_IMAGE_EXTS[@]}"; do
        while IFS= read -r -d '' f; do
            imgs+=("$f")
        done < <(find . -maxdepth 1 -iname "*.${ext}" -print0 2>/dev/null)
    done
    for f in "${imgs[@]+"${imgs[@]}"}"; do
        base=$(basename "$f")
        [[ "$base" == intro.* || "$base" == outro.* ]] && continue
        filtered+=("$f")
    done
    printf '%s\n' "${filtered[@]+"${filtered[@]}"}"
}
sort_images() {
    local sort_mode="$1"; shift
    local -a imgs=("$@")
    case "$sort_mode" in
        alpha)    printf '%s\n' "${imgs[@]}" | sort -V ;;
        datetime) printf '%s\n' "${imgs[@]}" | xargs -I{} stat -c '%Y {}' {} 2>/dev/null | sort -n | awk '{print $2}' || printf '%s\n' "${imgs[@]}" | sort -V ;;
        order)    printf '%s\n' "${imgs[@]}" ;;
    esac
}

# =============================================================================
# FFMPEG TOOLS
# =============================================================================
ffmpeg_run() {
    if [[ "$VERBOSE" == true ]]; then ffmpeg "$@"
    else ffmpeg "$@" -loglevel error; fi
}

build_scale_vf() {
    local mode="$1" w="$2" h="$3"
    case "$mode" in
        black) echo "scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:color=black" ;;
        crop)  echo "scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}" ;;
    esac
}
build_scale_fc() {
    local w="$1" h="$2"
    echo "[0:v]scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h},boxblur=20[bg];[0:v]scale=${w}:${h}:force_original_aspect_ratio=decrease[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2[out]"
}

apply_scale() {
    local input="$1" output="$2" dur="${3:-}"
    local extra_in=()
    [[ -n "$dur" ]] && extra_in=(-loop 1 -t "$dur")
    if [[ "$BGMODE" == "blur" ]]; then
        local fc; fc=$(build_scale_fc "$WIDTH" "$HEIGHT")
        ffmpeg_run "${extra_in[@]+"${extra_in[@]}"}" -i "$input" -filter_complex "$fc" -map "[out]" -r "$FPS" -pix_fmt yuv420p -c:v libx264 -an "$output" -y
    else
        local vf; vf=$(build_scale_vf "$BGMODE" "$WIDTH" "$HEIGHT")
        ffmpeg_run "${extra_in[@]+"${extra_in[@]}"}" -i "$input" -vf "$vf" -r "$FPS" -pix_fmt yuv420p -c:v libx264 -an "$output" -y
    fi
}

add_fade() {
    local input="$1" output="$2" dur="$3" fade="$4" do_in="$5" do_out="$6"
    local filters=()
    [[ "$do_in"  == true ]] && awk_gt "$fade" "0" && filters+=("fade=t=in:st=0:d=${fade}")
    if [[ "$do_out" == true ]] && awk_gt "$fade" "0"; then
        local st; st=$(awk "BEGIN { printf \"%.6f\", $dur - $fade }")
        filters+=("fade=t=out:st=${st}:d=${fade}")
    fi
    if [[ ${#filters[@]} -eq 0 ]]; then cp "$input" "$output"; return; fi
    local vf; vf=$(IFS=','; echo "${filters[*]}")
    ffmpeg_run -i "$input" -vf "$vf" -c:v libx264 -pix_fmt yuv420p -an "$output" -y
}

# =============================================================================
# BUILD
# =============================================================================
build_video() {
    header "Rendering"

    local -a raw_imgs
    mapfile -t raw_imgs < <(collect_images)
    local n=${#raw_imgs[@]}
    [[ $n -eq 0 ]] && { err "No images found."; exit 1; }
    local -a imgs
    mapfile -t imgs < <(sort_images "$SORT_BY" "${raw_imgs[@]}")

    if [[ -z "$AUDIO" ]]; then
        AUDIO=$(find_input_audio 2>/dev/null) || { err "No audio found."; exit 1; }
        log "Auto-detected audio: ${AUDIO}"
    fi
    local audio_dur; audio_dur=$(get_media_duration "$AUDIO")
    local total_dur="${DURATION:-$audio_dur}"

    [[ -z "$INTRO" ]] && INTRO=$(find_intro 2>/dev/null || true)
    [[ -z "$OUTRO" ]] && OUTRO=$(find_outro 2>/dev/null || true)

    local intro_actual="0"
    if [[ -n "$INTRO" ]]; then
        if is_image_file "$INTRO"; then intro_actual="$INTRO_DUR"
        else intro_actual=$(get_media_duration "$INTRO"); fi
    fi
    local outro_actual="0"
    if [[ -n "$OUTRO" ]]; then
        if is_image_file "$OUTRO"; then outro_actual="$OUTRO_DUR"
        else outro_actual=$(get_media_duration "$OUTRO"); fi
    fi

    local body_dur
    body_dur=$(awk "BEGIN { printf \"%.6f\", ${total_dur} - ${intro_actual} - ${outro_actual} }")
    if ! awk_gt "$body_dur" "0"; then err "Intro+Outro too long for total duration."; exit 1; fi
    local per_img; per_img=$(awk "BEGIN { printf \"%.6f\", $body_dur / $n }")

    ok "Body: ${body_dur}s | Images: ${n} | Per image: ${per_img}s"

    mkdir -p "$TMP_DIR"
    if [[ "$DRY_RUN" == true ]]; then ok "Dry run complete."; return; fi

    # --- body slideshow ---
    local concat_list="${TMP_DIR}/concat.txt"
    : > "$concat_list"
    for img in "${imgs[@]}"; do
        printf "file '%s'\nduration %s\n" "$(realpath "$img")" "$per_img" >> "$concat_list"
    done
    printf "file '%s'\n" "$(realpath "${imgs[-1]}")" >> "$concat_list"

    log "Rendering body slideshow..."
    local body_raw="${TMP_DIR}/body.mp4"
    if [[ "$BGMODE" == "blur" ]]; then
        local fc; fc=$(build_scale_fc "$WIDTH" "$HEIGHT")
        ffmpeg_run -f concat -safe 0 -i "$concat_list" -filter_complex "$fc" -map "[out]" -r "$FPS" -pix_fmt yuv420p -c:v libx264 -an "$body_raw" -y
    else
        local vf; vf=$(build_scale_vf "$BGMODE" "$WIDTH" "$HEIGHT")
        ffmpeg_run -f concat -safe 0 -i "$concat_list" -vf "$vf" -r "$FPS" -pix_fmt yuv420p -c:v libx264 -an "$body_raw" -y
    fi

    # --- intro ---
    local intro_clip=""
    if [[ -n "$INTRO" ]]; then
        local intro_scaled="${TMP_DIR}/intro-scaled.mp4"
        local intro_faded="${TMP_DIR}/intro-faded.mp4"
        if is_image_file "$INTRO"; then apply_scale "$INTRO" "$intro_scaled" "$intro_actual"
        else apply_scale "$INTRO" "$intro_scaled"; fi
        add_fade "$intro_scaled" "$intro_faded" "$intro_actual" "$FADE_DUR" "$FADE_INTRO" false
        intro_clip="$intro_faded"
    fi

    # --- outro ---
    local outro_clip=""
    if [[ -n "$OUTRO" ]]; then
        local outro_scaled="${TMP_DIR}/outro-scaled.mp4"
        local outro_faded="${TMP_DIR}/outro-faded.mp4"
        if is_image_file "$OUTRO"; then apply_scale "$OUTRO" "$outro_scaled" "$outro_actual"
        else apply_scale "$OUTRO" "$outro_scaled"; fi
        add_fade "$outro_scaled" "$outro_faded" "$outro_actual" "$FADE_DUR" false "$FADE_OUTRO"
        outro_clip="$outro_faded"
    fi

    # --- assemble silent ---
    local final_silent="${TMP_DIR}/final-silent.mp4"
    local parts_list="${TMP_DIR}/parts.txt"
    : > "$parts_list"
    [[ -n "$intro_clip" ]] && echo "file '$(realpath "$intro_clip")'" >> "$parts_list"
    echo "file '$(realpath "$body_raw")'" >> "$parts_list"
    [[ -n "$outro_clip" ]] && echo "file '$(realpath "$outro_clip")'" >> "$parts_list"
    ffmpeg_run -f concat -safe 0 -i "$parts_list" -c copy "$final_silent" -y

    # --- mix audio ---
    log "Mixing audio..."
    local mute_expr="1"
    if [[ "$MUTE_INTRO" == true && -n "$INTRO" ]]; then mute_expr="if(between(t,0,${intro_actual}),0,1)"; fi
    if [[ "$MUTE_OUTRO" == true && -n "$OUTRO" ]]; then
        local body_end; body_end=$(awk "BEGIN { printf \"%.3f\", $intro_actual + $body_dur }")
        mute_expr="${mute_expr}*if(between(t,${body_end},${total_dur}),0,1)"
    fi

    ffmpeg_run -i "$final_silent" -i "$AUDIO" \
        -filter_complex "[1:a]volume=enable='between(t,0,${total_dur})':volume='${mute_expr}':eval=frame[music]" \
        -map 0:v -map "[music]" -t "$total_dur" -c:v copy -c:a aac -b:a 192k -y "$OUTPUT"

    ok "DONE: ${BOLD}${OUTPUT}${RESET}"
    [[ "$KEEP_TMP" == false ]] && rm -rf "$TMP_DIR"
}

# =============================================================================
# CLI PARSING & ENTRY
# =============================================================================
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --audio=*)    AUDIO="${arg#*=}" ;;
            --output=*)   OUTPUT="${arg#*=}" ;;
            --intro=*)    INTRO="${arg#*=}" ;;
            --outro=*)    OUTRO="${arg#*=}" ;;
            --duration=*) DURATION="${arg#*=}" ;;
            --by=*)       SORT_BY="${arg#*=}" ;;
            --bgmode=*)   BGMODE="${arg#*=}" ;;
            --mute-intro) MUTE_INTRO=true ;;
            --mute-outro) MUTE_OUTRO=true ;;
            --verbose)    VERBOSE=true ;;
            *) err "Unknown option: ${arg}"; exit 1 ;;
        esac
    done
}

main() {
    if [[ $# -eq 0 ]]; then check_deps; header "bt-video-merge"; err "Use CLI arguments or run help."; exit 1; fi
    parse_args "$@"; check_deps
    build_video
}
main "$@"
