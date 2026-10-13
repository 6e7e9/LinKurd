#!/data/data/com.termux/files/usr/bin/bash
# ==============================================================================
#  LinKurd — Native Debian + KDE Plasma on Android (no root)
#
#  proot-distro · Termux:X11 · PulseAudio · GPU acceleration
#  (Adreno / Mali / Xclipse / PowerVR) · Firefox · VS Code · Google Antigravity
#
#  Usage:
#     bash linkurd.sh install   full guided installation
#     linkurd-start             start KDE Plasma (opens Termux:X11)
#     linkurd-stop              stop everything
#     linkurd bench             quick GPU benchmark inside Debian
#     linkurd help              all commands
#
#  v2.0.0 highlights
#     · Antigravity install fixed: no more apt "Conflicting values set for option
#       Signed-By" after re-runs, per-repo apt refresh, direct .deb fallback,
#       Electron runtime deps pre-installed, proper --no-sandbox launchers.
#     · Adreno fast path: Turnip self-test with automatic fallback, ZINK
#       descriptor auto (descriptor-buffer), glthread, immediate present,
#       vblank off, 2 GB shader cache, KWin/Plasma animation + splash off.
#     · New turnip-safe mode (software WSI) for black-screen devices.
#     · Faster installs: dpkg unsafe-io, docs/man excluded, batched pkg installs.
#
#  Built by studying and combining techniques from:
#     sabamdarif/termux-desktop      GPU driver matrix, Turnip/Zink, VirGL, X11 launcher
#     orailnoor/DroidDesk            proot app/menu integration ideas
#     StevenMXZ/Adreno-Tools-Drivers Android-native Turnip builds (host Vulkan ICD)
#     EXALAB/AnLinux-App             proot rootfs bootstrap patterns
#     AndronixApp/AndronixOrigin     DE launch scripts, PulseAudio over TCP
#     ahmed-alnassif/AndroSH         isolated proot environment management
#     zenithblue-oss/fluxlinux       host PulseAudio + Turnip/VirGL architecture
#     ExTV/Podroid                   device capability checks
#
#  License: GPL-3.0 (derivative ideas from GPL-3.0 projects above)
# ==============================================================================

set -o pipefail

# ------------------------------------------------------------------------------
#  Constants
# ------------------------------------------------------------------------------
readonly LK_VERSION="2.0.0"
readonly LK_NAME="LinKurd"
readonly PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
readonly TMPDIR="${TMPDIR:-$PREFIX/tmp}"
readonly LK_HOME="$HOME/.linkurd"
readonly LK_CACHE="$LK_HOME/cache"
readonly LK_LOG="$LK_HOME/install.log"
readonly LK_SESSION_LOG="$LK_HOME/session.log"
readonly LK_SESSION_PID="$LK_HOME/session.pid"
readonly LK_ETC="$PREFIX/etc/linkurd"
readonly LK_CONF="$LK_ETC/linkurd.conf"
readonly LK_BIN="$PREFIX/bin"
readonly LK_DISTRO="debian"
readonly LK_DISPLAY=":0"
readonly LK_X11_PKG="com.termux.x11"
readonly LK_API_PKG="com.termux.api"

# Debian-side Mesa with Turnip (KGSL) + Zink — prebuilt by sabamdarif/termux-desktop
readonly MESA_FREEDRENO_VERSION="26.3.0-devel-20260824"
readonly MESA_FREEDRENO_URL="https://github.com/sabamdarif/termux-desktop/releases/download/mesa-freedreno-${MESA_FREEDRENO_VERSION}/mesa-freedreno-${MESA_FREEDRENO_VERSION}-aarch64.zip"
readonly MESA_FREEDRENO_PREFIX="/opt/mesa-freedreno"

# Termux-side Android Vulkan wrapper (xMeM) — for Mali / Xclipse / PowerVR Zink
readonly VK_WRAPPER_VERSION="25.0.0-3"
readonly VK_WRAPPER_URL="https://github.com/sabamdarif/termux-desktop/releases/download/vulkan-wrapper-android_${VK_WRAPPER_VERSION}/vulkan-wrapper-android_${VK_WRAPPER_VERSION}_aarch64.deb"

# Android-native Turnip builds (AdrenoTools format) — StevenMXZ
readonly TURNIP_RELEASES_API="https://api.github.com/repos/StevenMXZ/Adreno-Tools-Drivers/releases?per_page=25"
readonly HOST_TURNIP_DIR="$PREFIX/opt/linkurd/turnip"

readonly LK_APT_OPTS=(-y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive

LK_TOTAL_STEPS=13
LK_STEP=0
LK_YES="${LINKURD_YES:-0}"
LK_API_OK=0
LK_SKIPPED=()
LK_WARNINGS=()

# ------------------------------------------------------------------------------
#  Colours — Kurdistan flag palette (red · white · green · sun yellow)
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
	C_R=$'\e[38;5;196m'
	C_W=$'\e[38;5;255m'
	C_G=$'\e[38;5;35m'
	C_Y=$'\e[38;5;220m'
	C_D=$'\e[38;5;245m'
	C_B=$'\e[1m'
	C_0=$'\e[0m'
else
	C_R="" C_W="" C_G="" C_Y="" C_D="" C_B="" C_0=""
fi

# ------------------------------------------------------------------------------
#  UI primitives
# ------------------------------------------------------------------------------
lk_cols() {
	local c
	c=$(tput cols 2>/dev/null || echo 48)
	((c > 74)) && c=74
	((c < 30)) && c=30
	echo "$c"
}

lk_repeat() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf '%s' "$s"; }

lk_rule() { printf '%s%s%s\n' "${1:-$C_D}" "$(lk_repeat '─' "$(lk_cols)")" "$C_0"; }

lk_log() { printf '[%(%F %T)T] %s\n' -1 "$*" >>"$LK_LOG" 2>/dev/null; }

lk_info() { printf '  %s●%s %s\n' "$C_Y" "$C_0" "$*"; lk_log "INFO  $*"; }
lk_ok() { printf '  %s✔%s %s\n' "$C_G" "$C_0" "$*"; lk_log "OK    $*"; }
lk_warn() { printf '  %s▲%s %s%s%s\n' "$C_Y" "$C_0" "$C_Y" "$*" "$C_0"; lk_log "WARN  $*"; LK_WARNINGS+=("$*"); }
lk_err() { printf '  %s✖%s %s%s%s\n' "$C_R" "$C_0" "$C_R" "$*" "$C_0" >&2; lk_log "ERROR $*"; }
lk_dim() { printf '    %s%s%s\n' "$C_D" "$*" "$C_0"; }

lk_die() {
	lk_err "$*"
	printf '\n  %sFull log:%s %s\n\n' "$C_D" "$C_0" "$LK_LOG" >&2
	tput cnorm 2>/dev/null
	exit 1
}

lk_banner() {
	clear 2>/dev/null
	local cols
	cols=$(lk_cols)
	echo
	if ((cols >= 58)); then
		printf '  %s%s\n' "$C_R" "██╗     ██╗███╗   ██╗██╗  ██╗██╗   ██╗██████╗ ██████╗ "
		printf '  %s%s\n' "$C_R" "██║     ██║████╗  ██║██║ ██╔╝██║   ██║██╔══██╗██╔══██╗"
		printf '  %s%s\n' "$C_W" "██║     ██║██╔██╗ ██║█████╔╝ ██║   ██║██████╔╝██║  ██║"
		printf '  %s%s\n' "$C_W" "██║     ██║██║╚██╗██║██╔═██╗ ██║   ██║██╔══██╗██║  ██║"
		printf '  %s%s\n' "$C_G" "███████╗██║██║ ╚████║██║  ██╗╚██████╔╝██║  ██║██████╔╝"
		printf '  %s%s%s\n' "$C_G" "╚══════╝╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═════╝ " "$C_0"
	else
		printf '  %s%s\n' "$C_R" "█   █ █▄ █ █▄▀ █ █ █▀█ █▀▄"
		printf '  %s%s\n' "$C_W" "█▄▄ █ █ ▀█ █ █ █▄█ █▀▄ █▄▀"
		printf '  %s%s%s\n' "$C_G" "$(lk_repeat '▀' 26)" "$C_0"
	fi
	printf '  %s☀%s  %sDebian · KDE Plasma · Android%s %s— no root · v%s%s\n' \
		"$C_Y" "$C_0" "$C_B" "$C_0" "$C_D" "$LK_VERSION" "$C_0"
	lk_rule
}

lk_step() {
	LK_STEP=$((LK_STEP + 1))
	local title="$1" cols width pct filled
	cols=$(lk_cols)
	width=$((cols - 14))
	pct=$((LK_STEP * 100 / LK_TOTAL_STEPS))
	filled=$((pct * width / 100))
	echo
	printf '%s╭─%s %sSTEP %d/%d%s %s%s%s\n' "$C_D" "$C_0" "$C_B$C_Y" "$LK_STEP" "$LK_TOTAL_STEPS" "$C_0" "$C_B" "$title" "$C_0"
	printf '%s│%s %s%s%s%s%s %3d%%\n' "$C_D" "$C_0" \
		"$C_G" "$(lk_repeat '█' "$filled")" "$C_D" "$(lk_repeat '░' $((width - filled)))" "$C_0" "$pct"
	printf '%s╰%s%s\n' "$C_D" "$(lk_repeat '─' $((cols - 1)))" "$C_0"
	lk_log "===== STEP $LK_STEP/$LK_TOTAL_STEPS: $title ====="
}

# Runs a command in the background with a spinner; output goes to the log.
lk_spin() {
	local label="$1"
	shift
	local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 start=$SECONDS el rc
	{
		printf '\n### %s\n$ %s\n' "$label" "$*"
	} >>"$LK_LOG"
	("$@") >>"$LK_LOG" 2>&1 </dev/null &
	local pid=$!
	tput civis 2>/dev/null
	while kill -0 "$pid" 2>/dev/null; do
		el=$((SECONDS - start))
		printf '\r  %s%s%s %s %s%02d:%02d%s\e[K' "$C_Y" "${frames[i++ % 10]}" "$C_0" "$label" "$C_D" $((el / 60)) $((el % 60)) "$C_0"
		sleep 0.12
	done
	wait "$pid"
	rc=$?
	tput cnorm 2>/dev/null
	el=$((SECONDS - start))
	if ((rc == 0)); then
		printf '\r  %s✔%s %s %s%ds%s\e[K\n' "$C_G" "$C_0" "$label" "$C_D" "$el" "$C_0"
	else
		printf '\r  %s✖%s %s %s(exit %d)%s\e[K\n' "$C_R" "$C_0" "$label" "$C_R" "$rc" "$C_0"
	fi
	return "$rc"
}

# lk_spin + interactive Retry / Skip / Abort on failure.
lk_task() {
	local label="$1" answer
	shift
	while true; do
		lk_spin "$label" "$@" && return 0
		printf '    %s┌ last log lines%s\n' "$C_D" "$C_0"
		tail -n 12 "$LK_LOG" | sed "s/^/    ${C_D}│${C_0} /"
		printf '    %s└%s\n' "$C_D" "$C_0"
		if [[ "$LK_YES" == "1" ]]; then
			return 1
		fi
		read -r -p "    ${C_B}[R]${C_0}etry  ${C_B}[S]${C_0}kip  ${C_B}[A]${C_0}bort ? " answer </dev/tty
		case "${answer,,}" in
		s*)
			lk_warn "Skipped: $label"
			LK_SKIPPED+=("$label")
			return 0
			;;
		a*) lk_die "Aborted by user at: $label" ;;
		*) lk_info "Retrying…" ;;
		esac
	done
}

lk_ask_yn() {
	local prompt="$1" default="${2:-y}" answer hint="[Y/n]"
	[[ "$default" == "n" ]] && hint="[y/N]"
	if [[ "$LK_YES" == "1" ]]; then
		[[ "$default" == "y" ]]
		return
	fi
	read -r -p "  ${C_Y}?${C_0} ${prompt} ${C_D}${hint}${C_0} " answer </dev/tty
	answer="${answer:-$default}"
	[[ "${answer,,}" == y* ]]
}

# lk_menu VAR default "key|label|description" ...
lk_menu() {
	local __var="$1" default="$2" i=1 choice entry key label desc keys=()
	shift 2
	for entry in "$@"; do
		IFS='|' read -r key label desc <<<"$entry"
		keys+=("$key")
		local mark="  "
		[[ "$key" == "$default" ]] && mark="${C_G}★${C_0} "
		printf '   %s%s%d)%s %s%s%s\n' "$mark" "$C_B" "$i" "$C_0" "$C_B" "$label" "$C_0"
		[[ -n "$desc" ]] && printf '        %s%s%s\n' "$C_D" "$desc" "$C_0"
		i=$((i + 1))
	done
	if [[ "$LK_YES" == "1" ]]; then
		printf -v "$__var" '%s' "$default"
		return
	fi
	while true; do
		read -r -p "  ${C_Y}?${C_0} Choose ${C_D}[★ = recommended, Enter]${C_0} " choice </dev/tty
		if [[ -z "$choice" ]]; then
			printf -v "$__var" '%s' "$default"
			return
		fi
		if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#keys[@]})); then
			printf -v "$__var" '%s' "${keys[choice - 1]}"
			return
		fi
		lk_warn "Invalid choice, try again."
	done
}

lk_kv() { printf '   %s%-18s%s %s\n' "$C_D" "$1" "$C_0" "$2"; }

trap 'tput cnorm 2>/dev/null; printf "\n\n  %s✖ Interrupted.%s Log: %s\n\n" "$C_R" "$C_0" "$LK_LOG"; exit 130' INT TERM

# ------------------------------------------------------------------------------
#  Environment helpers
# ------------------------------------------------------------------------------
lk_in_termux() { [[ "$PREFIX" == *"/com.termux/"* && -d "$PREFIX/bin" ]]; }

lk_in_proot() {
	local tracer
	tracer=$(awk '/^TracerPid/{print $2}' /proc/$$/status 2>/dev/null)
	[[ -n "$tracer" && "$tracer" != "0" ]] &&
		grep -q '^Name:[[:space:]]*proot' "/proc/$tracer/status" 2>/dev/null
}

lk_rootfs() {
	# Newer proot-distro releases store containers here; older releases used
	# installed-rootfs/<name>. Check the current layout first so an existing
	# Debian container is not mistaken for a missing rootfs.
	local runtime="$PREFIX/var/lib/proot-distro"
	local modern="$runtime/containers/$LK_DISTRO/rootfs"
	local legacy="$runtime/installed-rootfs/$LK_DISTRO"
	if [[ -d "$modern" ]]; then
		printf '%s\n' "$modern"
		return 0
	fi
	if [[ -d "$legacy" ]]; then
		printf '%s\n' "$legacy"
		return 0
	fi
	# Keep a fallback for custom/older proot-distro layouts.
	find "$runtime" -maxdepth 5 -type d -name "$LK_DISTRO" 2>/dev/null | head -n 1
}

lk_rootfs_ready() { local r; r=$(lk_rootfs); [[ -n "$r" && -x "$r/bin/bash" ]]; }

lk_guest_has() { local r; r=$(lk_rootfs); [[ -e "$r$1" || -L "$r$1" ]]; }

# dpkg -s also succeeds for removed packages that left config files behind.
lk_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

lk_app_installed() { pm list packages 2>/dev/null | grep -qx "package:$1" || cmd package list packages 2>/dev/null | grep -qx "package:$1"; }

lk_have() { command -v "$1" >/dev/null 2>&1; }

lk_api() {
	((LK_API_OK)) || return 1
	timeout 8 "$@" >/dev/null 2>&1
}

lk_api_probe() {
	LK_API_OK=0
	lk_have termux-battery-status || return 1
	if timeout 10 termux-battery-status 2>/dev/null | grep -q '"percentage"'; then
		LK_API_OK=1
	fi
	((LK_API_OK))
}

lk_load_conf() {
	# shellcheck disable=SC1090
	[[ -f "$LK_CONF" ]] && source "$LK_CONF"
}

lk_save_conf() {
	mkdir -p "$LK_ETC"
	{
		echo "# LinKurd configuration — generated $(date '+%F %T')"
		local k
		for k in LK_USER LK_PROFILE LK_GPU_VENDOR LK_GPU_MODEL LK_GPU_GEN LK_GPU_MODE LK_HOST_ICD LK_MIC LK_INSTALLED_VERSION; do
			printf '%s=%q\n' "$k" "${!k}"
		done
	} >"$LK_CONF"
}

# Guest runner: executes a provisioning phase inside Debian as root.
lk_guest() {
	proot-distro login "$LK_DISTRO" --shared-tmp -- /usr/bin/env -i \
		HOME=/root USER=root LOGNAME=root TERM="${TERM:-xterm-256color}" LANG=C.UTF-8 \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
		DEBIAN_FRONTEND=noninteractive \
		LK_USER="$LK_USER" LK_TZ="$LK_TZ" LK_PROFILE="$LK_PROFILE" LK_GPU_MODE="$LK_GPU_MODE" \
		/bin/bash /usr/local/lib/linkurd/guest.sh "$@"
}

lk_download() {
	local url="$1" dest="$2" attempt
	mkdir -p "$(dirname "$dest")"
	for attempt in 1 2 3 4; do
		if curl -fL --retry 2 --connect-timeout 20 -o "$dest.part" "$url"; then
			if [[ -s "$dest.part" ]] && ! head -c 512 "$dest.part" | grep -qi '<html'; then
				mv -f "$dest.part" "$dest"
				return 0
			fi
		fi
		echo "download attempt $attempt failed: $url"
		sleep $((attempt * 2))
	done
	rm -f "$dest.part"
	return 1
}

# ------------------------------------------------------------------------------
#  GPU detection
# ------------------------------------------------------------------------------
lk_detect_gpu() {
	local egl vk platform soc chip board hw kgsl_model brand blob
	egl=$(getprop ro.hardware.egl 2>/dev/null)
	vk=$(getprop ro.hardware.vulkan 2>/dev/null)
	platform=$(getprop ro.board.platform 2>/dev/null)
	soc=$(getprop ro.soc.model 2>/dev/null)
	chip=$(getprop ro.hardware.chipname 2>/dev/null)
	board=$(getprop ro.product.board 2>/dev/null)
	hw=$(getprop ro.hardware 2>/dev/null)
	brand=$(getprop ro.product.brand 2>/dev/null)
	kgsl_model=$(cat /sys/class/kgsl/kgsl-3d0/gpu_model 2>/dev/null)
	blob="${egl,,} ${vk,,} ${platform,,} ${soc,,} ${chip,,} ${board,,} ${hw,,}"

	LK_GPU_VENDOR="unknown"
	LK_GPU_MODEL=""
	LK_GPU_GEN=""
	LK_DEVICE_BRAND="${brand,,}"
	LK_SOC="${soc:-$platform}"

	# Word-bounded matching: values in $blob are space separated, and short
	# codenames like "sun" must not match inside e.g. "samsung".
	local b='(^|[[:space:]])' e='([[:space:]]|$)'
	local re_xclipse="xclipse|${b}(s5e99[2-5]5|s5e88[4-5]5|exynos2[2-5]00|exynos1[45]80)${e}"
	local re_adreno="adreno|qcom|${b}(msm[0-9]*|sdm[0-9]+|sm[0-9]{4}|lahaina|taro|kalama|pineapple|sun|kona|lito|holi|parrot|crow|cliffs|volcano|canoe|bengal|khaje|trinket)${e}"
	local re_mali="mali|${b}(mt[68][0-9]{3}[a-z]*|exynos[0-9]*|s5e[0-9]+|gs[0-9]{3}|zuma|zumapro|kirin[0-9]*|ums[0-9]+|tensor)${e}"

	if [[ "$blob" =~ $re_xclipse ]]; then
		LK_GPU_VENDOR="xclipse"
		LK_GPU_MODEL="Samsung Xclipse (${soc:-${chip:-$hw}})"
	elif [[ -n "$kgsl_model" || -e /dev/kgsl-3d0 || "$blob" =~ $re_adreno ]]; then
		LK_GPU_VENDOR="adreno"
		LK_GPU_MODEL="${kgsl_model:-Adreno (${soc:-${platform:-$hw}})}"
		if [[ "$kgsl_model" =~ ([0-9])[0-9]{2} ]]; then
			LK_GPU_GEN="${BASH_REMATCH[1]}"
		fi
	elif [[ "${egl,,}" == *powervr* || "${vk,,}" == *powervr* ]]; then
		LK_GPU_VENDOR="powervr"
		LK_GPU_MODEL="Imagination PowerVR (${soc:-${platform:-$hw}})"
	elif [[ -e /dev/mali0 || "$blob" =~ $re_mali ]]; then
		LK_GPU_VENDOR="mali"
		LK_GPU_MODEL="ARM Mali (${soc:-${platform:-$hw}})"
	fi

	if [[ -n "${LINKURD_GPU:-}" ]]; then
		LK_GPU_VENDOR="${LINKURD_GPU,,}"
		LK_GPU_MODEL="${LK_GPU_MODEL:-manual override}"
	fi
	lk_log "GPU detect: vendor=$LK_GPU_VENDOR model=$LK_GPU_MODEL gen=$LK_GPU_GEN blob=[$blob] kgsl=[$kgsl_model]"
}

lk_recommended_gpu_mode() {
	case "$LK_GPU_VENDOR" in
	adreno)
		if [[ -n "$LK_GPU_GEN" ]] && ((LK_GPU_GEN < 6)); then
			echo "virgl"
		else
			echo "turnip"
		fi
		;;
	mali | xclipse | powervr) echo "virgl" ;;
	*) echo "virgl" ;;
	esac
}

lk_gpu_mode_label() {
	case "$1" in
	turnip) echo "Turnip + Zink (native Adreno Vulkan inside Debian)" ;;
	turnip-safe) echo "Turnip + Zink, software WSI (black-screen fix)" ;;
	zink) echo "VirGL server · Zink over host Vulkan" ;;
	virgl) echo "VirGL server · Android GLES (universal)" ;;
	angle) echo "VirGL server · ANGLE over Android Vulkan" ;;
	software) echo "LLVMpipe software rendering" ;;
	*) echo "$1" ;;
	esac
}

lk_choose_gpu_mode() {
	local rec
	rec=$(lk_recommended_gpu_mode)
	echo
	printf '  %sDetected GPU:%s %s%s%s  %s[%s]%s\n' "$C_B" "$C_0" "$C_Y" "$LK_GPU_MODEL" "$C_0" "$C_D" "$LK_GPU_VENDOR" "$C_0"
	echo
	local opts=()
	if [[ "$LK_GPU_VENDOR" == "adreno" ]]; then
		opts+=("turnip|Turnip + Zink|Fastest on Adreno 6xx/7xx/8xx. Native Vulkan 1.4 + OpenGL 4.6, self-tested at every start.")
		opts+=("zink|VirGL + Zink (host Turnip)|Uses StevenMXZ Turnip on the Termux side. Try on Adreno 8xx if Turnip fails.")
	fi
	opts+=("virgl|VirGL (Android GLES)|Works on every GPU: Mali, Xclipse, Adreno, PowerVR. Most stable.")
	if [[ "$LK_GPU_VENDOR" != "adreno" ]]; then
		opts+=("zink|VirGL + Zink (Vulkan wrapper)|Android Vulkan driver via xMeM wrapper. Faster on modern Mali/Xclipse.")
		opts+=("angle|VirGL + ANGLE Vulkan|ANGLE translates GL to Android Vulkan. Often fastest on Mali-G7xx/Immortalis.")
	fi
	opts+=("software|Software (LLVMpipe)|No GPU. Use only if everything else fails.")
	lk_menu LK_GPU_MODE "$rec" "${opts[@]}"
	lk_ok "GPU mode: $(lk_gpu_mode_label "$LK_GPU_MODE")"
}

# ------------------------------------------------------------------------------
#  Host (Termux) GPU stack
# ------------------------------------------------------------------------------
lk_host_turnip_install() {
	local re zip="$LK_CACHE/host-turnip.zip" url
	if [[ "$LK_GPU_GEN" == "8" ]]; then
		re='^Turnip_Gen8_V[0-9]+\.zip$'
	elif [[ "$LK_DEVICE_BRAND" == samsung* ]]; then
		re='^Turnip_v[0-9.]+-R[0-9]+-Oneui\.zip$'
	else
		re='^Turnip_v[0-9.]+-R[0-9]+\.zip$'
	fi
	url=$(curl -fsSL "$TURNIP_RELEASES_API" | jq -r --arg re "$re" \
		'[.[] | select(.prerelease|not) | .assets[] | select(.name|test($re))][0].browser_download_url // empty')
	[[ -n "$url" ]] || { echo "no matching Turnip asset ($re)"; return 1; }
	echo "Turnip asset: $url"
	lk_download "$url" "$zip" || return 1
	rm -rf "$HOST_TURNIP_DIR"
	mkdir -p "$HOST_TURNIP_DIR"
	unzip -o -q "$zip" -d "$HOST_TURNIP_DIR" || return 1
	local so
	so=$(jq -r '.libraryName // "libvulkan_freedreno.so"' "$HOST_TURNIP_DIR/meta.json" 2>/dev/null)
	[[ -f "$HOST_TURNIP_DIR/$so" ]] || { echo "driver library $so missing in zip"; return 1; }
	cat >"$HOST_TURNIP_DIR/turnip_icd.json" <<-EOF
		{
		  "file_format_version": "1.0.0",
		  "ICD": { "library_path": "$HOST_TURNIP_DIR/$so", "api_version": "1.3.0" }
		}
	EOF
	if [[ -d "$HOME/storage/shared" ]]; then
		mkdir -p "$HOME/storage/shared/LinKurd/drivers"
		cp -f "$zip" "$HOME/storage/shared/LinKurd/drivers/$(basename "$url")" 2>/dev/null || true
	fi
	echo "installed host turnip: $HOST_TURNIP_DIR/$so"
}

lk_host_vk_wrapper_install() {
	local deb="$LK_CACHE/vulkan-wrapper-android.deb"
	lk_download "$VK_WRAPPER_URL" "$deb" || return 1
	apt-get "${LK_APT_OPTS[@]}" install "$deb"
}

lk_host_gpu_install() {
	LK_HOST_ICD=""
	# virglrenderer-android depends on angle-android and is the fallback
	# server for every mode, including Turnip.
	lk_pkg_install_list virglrenderer-android
	case "$LK_GPU_MODE" in
	zink)
		lk_pkg_install_list mesa virglrenderer vulkan-loader-generic
		if [[ "$LK_GPU_VENDOR" == "adreno" ]]; then
			if lk_ask_yn "Use latest Turnip from StevenMXZ/Adreno-Tools-Drivers for the host?" "$([[ "$LK_GPU_GEN" == "8" ]] && echo y || echo n)"; then
				if lk_task "Fetching Android Turnip (StevenMXZ)" lk_host_turnip_install; then
					[[ -f "$HOST_TURNIP_DIR/turnip_icd.json" ]] && LK_HOST_ICD="$HOST_TURNIP_DIR/turnip_icd.json"
				fi
			fi
			[[ -z "$LK_HOST_ICD" ]] && lk_pkg_install_list mesa-vulkan-icd-freedreno
		else
			lk_task "Installing Android Vulkan wrapper (xMeM)" lk_host_vk_wrapper_install
			[[ -f "$PREFIX/share/vulkan/icd.d/wrapper_icd.aarch64.json" ]] &&
				LK_HOST_ICD="$PREFIX/share/vulkan/icd.d/wrapper_icd.aarch64.json"
		fi
		;;
	esac
	lk_ok "Host GPU stack ready for: $(lk_gpu_mode_label "$LK_GPU_MODE")"
}

# Starts the host-side GPU server; prints the effective mode on stdout.
lk_gpu_server_start() {
	local mode="$1" sock="$TMPDIR/.virgl_test" i
	pkill -f virgl_test_server >/dev/null 2>&1
	rm -f "$sock"
	case "$mode" in
	software)
		echo "$mode"
		return 0
		;;
	turnip | turnip-safe)
		# Turnip renders natively inside Debian. A VirGL server is still started
		# so linkurd-session can fall back to it if the Turnip self-test fails.
		if lk_have virgl_test_server_android; then
			nohup virgl_test_server_android >>"$LK_SESSION_LOG" 2>&1 </dev/null &
		fi
		echo "$mode"
		return 0
		;;
	virgl)
		nohup virgl_test_server_android >>"$LK_SESSION_LOG" 2>&1 &
		;;
	zink)
		nohup env MESA_NO_ERROR=1 GALLIUM_DRIVER=zink ZINK_DESCRIPTORS=lazy \
			MESA_GL_VERSION_OVERRIDE=4.3COMPAT MESA_GLES_VERSION_OVERRIDE=3.2 \
			${LK_HOST_ICD:+VK_ICD_FILENAMES="$LK_HOST_ICD"} \
			virgl_test_server --use-egl-surfaceless --use-gles >>"$LK_SESSION_LOG" 2>&1 &
		;;
	angle)
		# Termux's virglrenderer-android ships ANGLE and selects it natively.
		nohup virgl_test_server_android --angle-vulkan >>"$LK_SESSION_LOG" 2>&1 &
		;;
	*)
		echo "software"
		return 1
		;;
	esac
	for i in $(seq 1 30); do
		[[ -S "$sock" ]] && { echo "$mode"; return 0; }
		sleep 0.2
	done
	echo "software"
	return 1
}

# ------------------------------------------------------------------------------
#  Package helpers
# ------------------------------------------------------------------------------
lk_pkg_install_one() {
	pkg install "${LK_APT_OPTS[@]}" "$1"
}

# One batched transaction first (much faster), per-package retry only on failure.
lk_pkg_install_list() {
	local p missing=()
	for p in "$@"; do
		if lk_pkg_installed "$p"; then
			printf '  %s✔%s %s %s(already installed)%s\n' "$C_G" "$C_0" "$p" "$C_D" "$C_0"
		else
			missing+=("$p")
		fi
	done
	((${#missing[@]})) || return 0
	if ((${#missing[@]} > 1)); then
		lk_spin "pkg install ${#missing[@]} packages: ${missing[*]:0:4}$( ((${#missing[@]} > 4)) && echo ' …')" \
			pkg install "${LK_APT_OPTS[@]}" "${missing[@]}" && return 0
		lk_warn "Batched install failed — retrying packages one by one"
	fi
	for p in "${missing[@]}"; do
		lk_pkg_installed "$p" && continue
		lk_task "pkg install $p" lk_pkg_install_one "$p"
	done
}

# ------------------------------------------------------------------------------
#  Guest (Debian) provisioning script — written into the rootfs
# ------------------------------------------------------------------------------
lk_write_guest_files() {
	local r
	r=$(lk_rootfs)
	mkdir -p "$r/usr/local/lib/linkurd" "$r/usr/local/bin" "$r/etc/linkurd/gpu"

	cat >"$r/usr/local/lib/linkurd/guest.sh" <<'GUEST_EOF'
#!/bin/bash
# LinKurd guest provisioning — runs inside Debian (proot-distro) as root.
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
U="${LK_USER:-kurd}"
UH="/home/$U"
ARCH="$(dpkg --print-architecture 2>/dev/null)"
SRC_D=/etc/apt/sources.list.d
KEY_D=/etc/apt/keyrings

AG_REPO="https://us-central1-apt.pkg.dev/projects/antigravity-auto-updater-dev"
AG_KEY_URL="https://us-central1-apt.pkg.dev/doc/repo-signing-key.gpg"

# Shared Electron/Chromium runtime libraries. Both the Debian 12 names and the
# Debian 13 "t64" names are listed; install_avail keeps whichever exists.
ELECTRON_DEPS=(
	libgtk-3-0t64 libgtk-3-0 libnss3 libnspr4 libasound2t64 libasound2
	libatk-bridge2.0-0t64 libatk-bridge2.0-0 libatk1.0-0t64 libatk1.0-0 libatspi2.0-0t64 libatspi2.0-0
	libcups2t64 libcups2 libgbm1 libdrm2 libxkbfile1 libxkbcommon0 libsecret-1-0 libxss1 libxtst6
	libxcomposite1 libxdamage1 libxrandr2 libxfixes3 libcurl4t64 libcurl4 libudev1 xdg-utils
)

log() { echo "[linkurd-guest] $*"; }
have_pkg() { apt-cache show "$1" >/dev/null 2>&1; }
pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

install_avail() {
	local want=() p
	for p in "$@"; do
		if have_pkg "$p"; then want+=("$p"); else log "not available, skipping: $p"; fi
	done
	((${#want[@]})) || return 0
	"${APT[@]}" install --no-install-recommends "${want[@]}"
}

retry() {
	local n=0
	until "$@"; do
		n=$((n + 1))
		((n >= 3)) && return 1
		log "retry $n: $*"
		sleep 3
		dpkg --configure -a || true
		"${APT[@]}" -f install || true
	done
}

# Refresh one source file only: faster, and a broken third-party repo can no
# longer make the whole apt update (and every later phase) fail.
apt_update_src() {
	apt-get update -o Dir::Etc::sourcelist="$1" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
}

# Two source files for the same repo with different Signed-By values make apt
# refuse to run at all ("Conflicting values set for option Signed-By"). This is
# what broke Antigravity after VS Code's postinst rewrote its own source file.
drop_repo_dupes() {
	local pattern="$1" keep="$2" f
	for f in "$SRC_D"/*.list "$SRC_D"/*.sources; do
		[[ -f "$f" && "$f" != "$keep" ]] || continue
		if grep -q -- "$pattern" "$f"; then
			log "removing conflicting apt source: $f"
			rm -f "$f"
		fi
	done
}

# Accepts armored or binary keys and always writes a binary keyring.
fetch_key() {
	local url="$1" dest="$2" tmp
	tmp=$(mktemp)
	if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp" "$url" || [[ ! -s "$tmp" ]]; then
		rm -f "$tmp"
		log "could not download signing key: $url"
		return 1
	fi
	install -d -m 0755 "$(dirname "$dest")"
	if grep -q 'BEGIN PGP' "$tmp"; then
		gpg --dearmor --yes -o "$dest" "$tmp" || { rm -f "$tmp"; return 1; }
	else
		install -m 0644 "$tmp" "$dest"
	fi
	chmod 0644 "$dest"
	rm -f "$tmp"
}

as_user() { su - "$U" -c "$*"; }

write_electron_fix() {
	cat >/usr/local/bin/linkurd-electron-fix <<-'EOF'
		#!/bin/sh
		# Electron apps under proot: no setuid sandbox, unreliable /dev/shm and no
		# KWallet. Re-applied after every dpkg run by an apt hook.
		for app in code antigravity; do
		  [ -e "/usr/bin/$app" ] || continue
		  cat >"/usr/local/bin/$app" <<WRAP
		#!/bin/sh
		flags="--no-sandbox --disable-gpu-sandbox --disable-dev-shm-usage --password-store=basic"
		case "\${LINKURD_GPU:-}" in
		  turnip|turnip-safe) flags="\$flags --ignore-gpu-blocklist --enable-gpu-rasterization --enable-zero-copy" ;;
		  software) flags="\$flags --disable-gpu" ;;
		esac
		exec /usr/bin/$app \$flags "\$@"
		WRAP
		  chmod 755 "/usr/local/bin/$app"
		  for f in "/usr/share/applications/$app.desktop" "/usr/share/applications/$app-url-handler.desktop"; do
		    [ -f "$f" ] && sed -i -E "s#^Exec=[^ ]+#Exec=/usr/local/bin/$app#" "$f"
		  done
		done
		exit 0
	EOF
	chmod 755 /usr/local/bin/linkurd-electron-fix
	echo 'DPkg::Post-Invoke { "/usr/local/bin/linkurd-electron-fix || true"; };' >/etc/apt/apt.conf.d/99linkurd-electron
}

phase_base() {
	printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
	chmod +x /usr/sbin/policy-rc.d

	cat >/etc/apt/apt.conf.d/99linkurd <<-'EOF'
		Acquire::Retries "5";
		Acquire::http::Timeout "30";
		Acquire::https::Timeout "30";
		Acquire::Queue-Mode "host";
		Acquire::Languages "none";
		APT::Periodic::Enable "0";
		Dpkg::Use-Pty "0";
	EOF
	# fsync is expensive under proot, and docs/man pages are ~400 MB nobody reads on a phone.
	mkdir -p /etc/dpkg/dpkg.cfg.d
	cat >/etc/dpkg/dpkg.cfg.d/99linkurd <<-'EOF'
		force-unsafe-io
		path-exclude=/usr/share/doc/*
		path-include=/usr/share/doc/*/copyright
		path-exclude=/usr/share/man/*
		path-exclude=/usr/share/info/*
		path-exclude=/usr/share/lintian/*
	EOF
	echo "man-db man-db/auto-update boolean false" | debconf-set-selections 2>/dev/null || true
	rm -f /var/lib/man-db/auto-update

	retry apt-get update || return 1
	retry "${APT[@]}" full-upgrade || return 1
	retry install_avail sudo locales tzdata ca-certificates curl wget gnupg apt-transport-https \
		dbus dbus-x11 xdg-utils xdg-user-dirs nano less procps psmisc unzip xz-utils file \
		bash-completion debconf-utils || return 1
	sed -i 's/^# *\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen
	locale-gen || true
	update-locale LANG=en_US.UTF-8 || true
	if [[ -n "$LK_TZ" && -e "/usr/share/zoneinfo/$LK_TZ" ]]; then
		ln -sf "/usr/share/zoneinfo/$LK_TZ" /etc/localtime
		echo "$LK_TZ" >/etc/timezone
	fi
	dbus-uuidgen --ensure || true
	write_electron_fix
}

phase_user() {
	local passfile=/root/.linkurd-pass g
	id "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U" || return 1
	for g in sudo audio video render input plugdev netdev; do
		getent group "$g" >/dev/null && usermod -aG "$g" "$U"
	done
	if [[ -s "$passfile" ]]; then
		printf '%s:%s\n' "$U" "$(cat "$passfile")" | chpasswd || return 1
	fi
	shred -u "$passfile" 2>/dev/null || rm -f "$passfile"
	echo "$U ALL=(ALL:ALL) ALL" >/etc/sudoers.d/linkurd
	chmod 440 /etc/sudoers.d/linkurd
	ln -sfn /sdcard "$UH/Android" 2>/dev/null || true
	chown -h "$U:$U" "$UH/Android" 2>/dev/null || true
}

phase_kde() {
	local pkgs=(
		kde-plasma-desktop plasma-workspace kwin-x11 plasma-pa kscreen powerdevil
		konsole dolphin kate ark gwenview okular spectacle kcalc
		systemsettings kinfocenter plasma-systemmonitor
		breeze breeze-gtk-theme breeze-icon-theme breeze-cursor-theme kde-config-gtk-style
		xdg-desktop-portal-kde
		fonts-noto-core fonts-noto-color-emoji fonts-dejavu-core
		x11-xserver-utils x11-utils xauth
	)
	[[ "$LK_PROFILE" == "full" ]] && pkgs+=(kde-standard elisa haruna kdeconnect filelight partitionmanager)
	retry install_avail "${pkgs[@]}" || return 1
	# PackageKit polls constantly and cannot work under proot; the welcome wizard is noise.
	"${APT[@]}" purge plasma-welcome packagekit plasma-discover-backend-packagekit >/dev/null 2>&1 || true
	command -v startplasma-x11 >/dev/null || { log "startplasma-x11 missing"; return 1; }

	mkdir -p "$UH/.config"
	cat >"$UH/.config/kscreenlockerrc" <<-'EOF'
		[Daemon]
		Autolock=false
		LockOnResume=false
		Timeout=0
	EOF
	cat >"$UH/.config/baloofilerc" <<-'EOF'
		[Basic Settings]
		Indexing-Enabled=false
	EOF
	cat >"$UH/.config/ksmserverrc" <<-'EOF'
		[General]
		loginMode=emptySession
		confirmLogout=false
	EOF
	cat >"$UH/.config/kwinrc" <<-'EOF'
		[Compositing]
		Enabled=false
		LatencyPolicy=Low
		[Plugins]
		blurEnabled=false
		contrastEnabled=false
		slidingpopupsEnabled=false
		fadingpopupsEnabled=false
	EOF
	cat >"$UH/.config/powerdevilrc" <<-'EOF'
		[AC][Display]
		TurnOffDisplayWhenIdle=false
		DimDisplayWhenIdle=false
	EOF
	cat >"$UH/.config/ksplashrc" <<-'EOF'
		[KSplash]
		Engine=none
		Theme=None
	EOF
	cat >"$UH/.config/kwalletrc" <<-'EOF'
		[Wallet]
		Enabled=false
		First Use=false
	EOF
	chown -R "$U:$U" "$UH/.config"
}

phase_gpu() {
	# Runtime libraries the prebuilt Turnip/Zink Mesa links against, plus the
	# Vulkan loader Zink dlopens (libvulkan.so.1).
	retry install_avail mesa-utils mesa-utils-bin mesa-vulkan-drivers libgl1-mesa-dri libglx-mesa0 \
		libegl-mesa0 libgles2 libgbm1 libvulkan1 vulkan-tools libgl1 xdg-desktop-portal \
		libdrm2 libexpat1 zlib1g libzstd1 libxcb1 libxcb-randr0 libxcb-dri3-0 libxcb-present0 \
		libxcb-xfixes0 libxcb-sync1 libxcb-shm0 libxcb-glx0 libxshmfence1 libwayland-client0 \
		libx11-xcb1 libxext6 libxxf86vm1 glmark2-x11 || return 1
	mkdir -p /etc/linkurd/gpu
	local mf="/opt/mesa-freedreno"
	cat >/etc/linkurd/gpu/turnip.env <<-EOF
		VK_ICD_FILENAMES=$mf/share/vulkan/icd.d/freedreno_icd.aarch64.json
		LD_LIBRARY_PATH=$mf/lib/aarch64-linux-gnu
		LIBGL_DRIVERS_PATH=$mf/lib/aarch64-linux-gnu/dri
		MESA_LOADER_DRIVER_OVERRIDE=zink
		GALLIUM_DRIVER=zink
		TU_DEBUG=noconform
		ZINK_DESCRIPTORS=auto
		MESA_VK_WSI_PRESENT_MODE=immediate
		MESA_NO_ERROR=1
		mesa_glthread=true
		vblank_mode=0
		MESA_SHADER_CACHE_MAX_SIZE=2G
	EOF
	# Same stack with Mesa's software presentation path for devices where the
	# Termux:X11 DRI3 path shows a black screen.
	sed -e 's/^ZINK_DESCRIPTORS=.*/ZINK_DESCRIPTORS=lazy/' -e '/^mesa_glthread=/d' \
		/etc/linkurd/gpu/turnip.env >/etc/linkurd/gpu/turnip-safe.env
	echo "MESA_VK_WSI_DEBUG=sw" >>/etc/linkurd/gpu/turnip-safe.env
	local m
	for m in virgl zink angle; do
		cat >"/etc/linkurd/gpu/$m.env" <<-'EOF'
			GALLIUM_DRIVER=virpipe
			MESA_GL_VERSION_OVERRIDE=4.0
			MESA_GLES_VERSION_OVERRIDE=3.2
			MESA_NO_ERROR=1
			mesa_glthread=true
			vblank_mode=0
			MESA_SHADER_CACHE_MAX_SIZE=1G
		EOF
	done
	cat >/etc/linkurd/gpu/software.env <<-'EOF'
		LIBGL_ALWAYS_SOFTWARE=1
		GALLIUM_DRIVER=llvmpipe
		MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
		QT_QUICK_BACKEND=software
		vblank_mode=0
	EOF
	if [[ -d "$mf" ]]; then
		ldconfig || true
		[[ -f "$mf/share/vulkan/icd.d/freedreno_icd.aarch64.json" ]] || { log "turnip ICD missing"; return 1; }
	fi
}

phase_firefox() {
	local src="$SRC_D/mozilla.list" key="$KEY_D/packages.mozilla.org.gpg"
	drop_repo_dupes 'packages.mozilla.org' "$src"
	rm -f "$KEY_D/packages.mozilla.org.asc"
	if fetch_key https://packages.mozilla.org/apt/repo-signing-key.gpg "$key"; then
		echo "deb [signed-by=$key] https://packages.mozilla.org/apt mozilla main" >"$src"
		printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' >/etc/apt/preferences.d/mozilla
		retry apt_update_src "$src" || true
	fi
	if ! retry "${APT[@]}" install firefox; then
		log "Mozilla build failed, falling back to firefox-esr"
		rm -f "$src" /etc/apt/preferences.d/mozilla
		retry "${APT[@]}" install firefox-esr || return 1
	fi
	local d
	for d in /usr/lib/firefox /usr/lib/firefox-esr; do
		[[ -d "$d" ]] || continue
		mkdir -p "$d/defaults/pref"
		cat >"$d/defaults/pref/linkurd.js" <<-'EOF'
			pref("gfx.x11-egl.force-enabled", true);
			pref("layers.acceleration.force-enabled", true);
			pref("media.hardware-video-decoding.enabled", false);
			pref("browser.cache.memory.capacity", 262144);
			pref("toolkit.cosmeticAnimations.enabled", false);
		EOF
	done
}

phase_vscode() {
	local src="$SRC_D/vscode.list" key=/usr/share/keyrings/microsoft.gpg
	retry install_avail "${ELECTRON_DEPS[@]}" || true
	# Use the exact key path VS Code's own postinst uses, so whatever it writes
	# later can never conflict with this file.
	echo "code code/add-microsoft-repo boolean false" | debconf-set-selections
	drop_repo_dupes 'packages.microsoft.com/repos/code' "$src"
	fetch_key https://packages.microsoft.com/keys/microsoft.asc "$key" || return 1
	echo "deb [arch=$ARCH signed-by=$key] https://packages.microsoft.com/repos/code stable main" >"$src"
	retry apt_update_src "$src" || return 1
	retry "${APT[@]}" install code || return 1
	write_electron_fix
	/usr/local/bin/linkurd-electron-fix
	[[ -e /usr/bin/code ]]
}

# Pick the newest .deb for this architecture straight from the repo index.
antigravity_direct_deb() {
	local idx file rc deb=/var/cache/apt/archives/antigravity-linkurd.deb
	idx=$(curl -fsSL --retry 3 --connect-timeout 20 "$AG_REPO/dists/antigravity-debian/main/binary-$ARCH/Packages") || return 1
	file=$(awk '/^Version:/{v=$2} /^Filename:/{print v" "$2}' <<<"$idx" | sort -V | tail -n1 | cut -d' ' -f2)
	[[ -n "$file" ]] || { log "no antigravity build for $ARCH in the index"; return 1; }
	log "downloading $AG_REPO/$file"
	curl -fL --retry 3 --connect-timeout 20 -o "$deb" "$AG_REPO/$file" || return 1
	[[ $(stat -c %s "$deb" 2>/dev/null || echo 0) -gt 1000000 ]] || { log "downloaded .deb is too small"; return 1; }
	retry "${APT[@]}" install "$deb"
	rc=$?
	rm -f "$deb"
	return "$rc"
}

phase_antigravity() {
	local src="$SRC_D/antigravity.list" key="$KEY_D/antigravity-repo-key.gpg"
	case "$ARCH" in
	arm64 | amd64) ;;
	*) log "Antigravity has no build for $ARCH — skipping"; return 0 ;;
	esac
	retry install_avail "${ELECTRON_DEPS[@]}" || true
	drop_repo_dupes 'antigravity-auto-updater-dev' "$src"
	if fetch_key "$AG_KEY_URL" "$key"; then
		echo "deb [arch=$ARCH signed-by=$key] $AG_REPO/ antigravity-debian main" >"$src"
		if retry apt_update_src "$src"; then
			retry "${APT[@]}" install antigravity || log "apt install antigravity failed"
		else
			log "Antigravity repo refresh failed"
		fi
	fi
	if ! pkg_ok antigravity; then
		log "falling back to direct .deb download"
		antigravity_direct_deb || return 1
	fi
	write_electron_fix
	/usr/local/bin/linkurd-electron-fix
	mkdir -p "$UH/.antigravity"
	[[ -f "$UH/.antigravity/argv.json" ]] ||
		printf '{\n  "password-store": "basic",\n  "enable-crash-reporter": false\n}\n' >"$UH/.antigravity/argv.json"
	chown -R "$U:$U" "$UH/.antigravity" 2>/dev/null || true
	[[ -e /usr/share/antigravity/bin/antigravity || -e /usr/bin/antigravity ]]
}

phase_audio() {
	retry install_avail pulseaudio-utils libpulse0 alsa-utils libasound2-plugins pavucontrol-qt || return 1
	cat >/etc/asound.conf <<-'EOF'
		pcm.!default { type pulse }
		ctl.!default { type pulse }
	EOF
	mkdir -p /etc/pulse
	sed -i -e '/^default-server/d' -e '/^autospawn/d' /etc/pulse/client.conf 2>/dev/null || true
	echo "default-server = tcp:127.0.0.1:4713" >>/etc/pulse/client.conf
	echo "autospawn = no" >>/etc/pulse/client.conf
	cat >/etc/profile.d/linkurd.sh <<-'EOF'
		export PULSE_SERVER=tcp:127.0.0.1:4713
		export DISPLAY="${DISPLAY:-:0}"
		export MOZ_ENABLE_WAYLAND=0
		export MOZ_FAKE_NO_SANDBOX=1
	EOF
}

phase_polish() {
	write_electron_fix

	cat >/usr/local/bin/linkurd-session <<-'EOF'
		#!/bin/bash
		# Starts KDE Plasma (X11) for LinKurd. Called by linkurd-start from Termux.
		export DISPLAY="${DISPLAY:-:0}"
		export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
		mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
		export PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4713}"
		export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=KDE XDG_SESSION_DESKTOP=KDE
		export DESKTOP_SESSION=plasma KDE_FULL_SESSION=true QT_QPA_PLATFORM=xcb
		export LANG="${LANG:-en_US.UTF-8}" MOZ_ENABLE_WAYLAND=0 MOZ_FAKE_NO_SANDBOX=1
		# SysV shared memory inside proot is not visible to the Termux:X11 server.
		export QT_X11_NO_MITSHM=1 _X11_NO_MITSHM=1 _MITSHM=0
		export ELECTRON_OZONE_PLATFORM_HINT=x11
		if command -v kwriteconfig6 >/dev/null; then KW=kwriteconfig6; export KDE_SESSION_VERSION=6
		else KW=kwriteconfig5; export KDE_SESSION_VERSION=5; fi

		load_env() { [ -f "/etc/linkurd/gpu/$1.env" ] && { set -a; . "/etc/linkurd/gpu/$1.env"; set +a; }; }

		mode="${LINKURD_GPU:-software}"
		case "$mode" in
		turnip | turnip-safe)
		  # A broken Turnip would leave Plasma without any OpenGL at all, so
		  # prove the driver works before committing the whole session to it.
		  ok=1
		  [ -e /dev/kgsl-3d0 ] || ok=0
		  if [ "$ok" = 1 ] && command -v vulkaninfo >/dev/null; then
		    ( load_env "$mode"; timeout 20 vulkaninfo --summary 2>/dev/null ) | grep -qiE 'turnip|adreno' || ok=0
		  fi
		  if [ "$ok" = 0 ]; then
		    echo "[linkurd-session] Turnip self-test failed"
		    if [ -S /tmp/.virgl_test ]; then mode=virgl; else mode=software; fi
		  fi
		  ;;
		esac
		load_env "$mode"
		export LINKURD_GPU="$mode"
		echo "[linkurd-session] GPU mode: $mode"

		if [ "${LINKURD_COMPOSITOR:-false}" = true ]; then
		  export KWIN_COMPOSE=O2
		else
		  export KWIN_COMPOSE=N
		fi
		$KW --file kwinrc --group Compositing --key Enabled "${LINKURD_COMPOSITOR:-false}" 2>/dev/null
		$KW --file kwinrc --group Compositing --key LatencyPolicy Low 2>/dev/null
		$KW --file kdeglobals --group KDE --key AnimationDurationFactor "${LINKURD_ANIMATIONS:-0}" 2>/dev/null
		$KW --file ksplashrc --group KSplash --key Engine none 2>/dev/null
		$KW --file ksplashrc --group KSplash --key Theme None 2>/dev/null
		$KW --file kwalletrc --group Wallet --key Enabled false 2>/dev/null
		$KW --file kscreenlockerrc --group Daemon --key Autolock false 2>/dev/null
		$KW --file kscreenlockerrc --group Daemon --key LockOnResume false 2>/dev/null
		$KW --file baloofilerc --group "Basic Settings" --key Indexing-Enabled false 2>/dev/null
		if [ -n "$LINKURD_DPI" ]; then
		  $KW --file kcmfonts --group General --key forceFontDPI "$LINKURD_DPI" 2>/dev/null
		  echo "Xft.dpi: $LINKURD_DPI" | xrdb -merge 2>/dev/null
		fi
		if [ ! -f "$HOME/.config/linkurd-firstrun" ]; then
		  touch "$HOME/.config/linkurd-firstrun"
		  ( sleep 15; lookandfeeltool -a org.kde.breezedark.desktop >/dev/null 2>&1 ) &
		fi
		exec dbus-launch --exit-with-session startplasma-x11
	EOF
	chmod 755 /usr/local/bin/linkurd-session

	cat >/usr/local/bin/linkurd-bench <<-'EOF'
		#!/bin/bash
		# Quick GPU benchmark for the active LinKurd GPU mode.
		mode="${LINKURD_GPU:-software}"
		[ -f "/etc/linkurd/gpu/$mode.env" ] && { set -a; . "/etc/linkurd/gpu/$mode.env"; set +a; }
		export DISPLAY="${DISPLAY:-:0}"
		echo "== GPU mode: $mode"
		glxinfo -B 2>/dev/null | grep -E 'renderer string|core profile version|^OpenGL version' | sed 's/^/   /'
		if command -v vulkaninfo >/dev/null; then
		  vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName|apiVersion' | head -n 3 | sed 's/^ */   /'
		fi
		if command -v glmark2 >/dev/null; then
		  echo "== glmark2 (short run, 800x480)"
		  timeout 180 glmark2 --size 800x480 -b build:use-vbo=true -b texture -b shading:shading=phong \
		    -b bump:bump-render=normals -b effect2d -b refract 2>&1 | grep -E '\]|Score' | sed 's/^/   /'
		else
		  echo "== glxgears (10 s)"
		  timeout 11 glxgears 2>&1 | grep -E 'FPS' | sed 's/^/   /'
		fi
	EOF
	chmod 755 /usr/local/bin/linkurd-bench

	mkdir -p "$UH/Desktop"
	local d
	for d in firefox firefox-esr code antigravity org.kde.konsole org.kde.dolphin; do
		[[ -f "/usr/share/applications/$d.desktop" ]] || continue
		install -m 755 "/usr/share/applications/$d.desktop" "$UH/Desktop/$d.desktop"
	done
	chown -R "$U:$U" "$UH/Desktop"
	as_user "xdg-user-dirs-update" || true
	/usr/local/bin/linkurd-electron-fix
	"${APT[@]}" autoremove >/dev/null 2>&1 || true
	apt-get clean
}

# Heal installs made by LinKurd 1.x, where duplicate sources broke apt.
phase_sources() {
	local p
	for p in 'packages.microsoft.com/repos/code:vscode.list' 'antigravity-auto-updater-dev:antigravity.list' 'packages.mozilla.org:mozilla.list'; do
		[[ -f "$SRC_D/${p#*:}" ]] && drop_repo_dupes "${p%%:*}" "$SRC_D/${p#*:}"
	done
	return 0
}

phase_update() {
	write_electron_fix
	phase_sources
	retry apt-get update || return 1
	retry "${APT[@]}" full-upgrade || return 1
	/usr/local/bin/linkurd-electron-fix 2>/dev/null || true
	apt-get clean
}

phase="$1"
shift
case "$phase" in
base | user | kde | gpu | firefox | vscode | antigravity | audio | polish | sources | update) "phase_$phase" "$@" ;;
*) echo "unknown phase: $phase"; exit 2 ;;
esac
GUEST_EOF
	chmod 755 "$r/usr/local/lib/linkurd/guest.sh"
}

lk_guest_turnip_install() {
	local zip="$LK_CACHE/mesa-freedreno-${MESA_FREEDRENO_VERSION}.zip" r
	r=$(lk_rootfs)
	if [[ -s "$zip" ]] && ! unzip -tq "$zip" >/dev/null 2>&1; then
		echo "cached zip is corrupt, downloading again"
		rm -f "$zip"
	fi
	[[ -s "$zip" ]] || lk_download "$MESA_FREEDRENO_URL" "$zip" || return 1
	unzip -tq "$zip" >/dev/null || return 1
	# Stale libraries from an older build would mix with the new libgallium.
	rm -rf "${r:?}$MESA_FREEDRENO_PREFIX"
	unzip -o -q "$zip" -d "$r/" || return 1
	find "$LK_CACHE" -maxdepth 1 -name 'mesa-freedreno-*.zip' ! -name "$(basename "$zip")" -delete 2>/dev/null
	[[ -f "$r$MESA_FREEDRENO_PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json" &&
		-f "$r$MESA_FREEDRENO_PREFIX/lib/aarch64-linux-gnu/libvulkan_freedreno.so" ]]
}

# ------------------------------------------------------------------------------
#  Installer steps
# ------------------------------------------------------------------------------
step_preflight() {
	lk_step "Pre-flight system checks"
	local fails=0 arch sdk free_kb mem_kb release

	if lk_in_termux; then lk_ok "Running inside Termux"; else lk_die "This script must run inside Termux (F-Droid / GitHub build)."; fi
	if lk_in_proot; then lk_die "Do not run LinKurd inside proot. Exit the container first."; fi
	lk_ok "Not inside proot"

	arch=$(uname -m)
	case "$arch" in
	aarch64) lk_ok "CPU architecture: $arch" ;;
	armv7l | armv8l) lk_warn "32-bit ARM ($arch): Turnip & Antigravity unavailable, performance will be limited" ;;
	x86_64) lk_warn "x86_64 (emulator/Chromebook): GPU acceleration falls back to VirGL/software" ;;
	*) lk_err "Unsupported architecture: $arch"; fails=$((fails + 1)) ;;
	esac
	LK_ARCH="$arch"

	sdk=$(getprop ro.build.version.sdk 2>/dev/null)
	if [[ -n "$sdk" ]] && ((sdk >= 26)); then
		lk_ok "Android $(getprop ro.build.version.release) (API $sdk)"
	else
		lk_err "Android 8.0 (API 26) or newer is required (found API ${sdk:-?})"
		fails=$((fails + 1))
	fi

	release="${TERMUX_APK_RELEASE:-${TERMUX_APP__APK_RELEASE:-unknown}}"
	if [[ "$release" == *PLAY* ]]; then
		lk_warn "Termux from Google Play detected — install the F-Droid/GitHub build for Termux:API & X11 compatibility"
	else
		lk_ok "Termux build: ${release} ${TERMUX_VERSION:+(v$TERMUX_VERSION)}"
	fi

	free_kb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
	if [[ -n "$free_kb" ]]; then
		local free_gb=$((free_kb / 1024 / 1024))
		if ((free_gb >= 8)); then
			lk_ok "Free storage: ${free_gb} GB"
		elif ((free_gb >= 5)); then
			lk_warn "Free storage: ${free_gb} GB (8 GB+ recommended for KDE + apps)"
		else
			lk_err "Free storage: ${free_gb} GB — at least 5 GB is required"
			fails=$((fails + 1))
		fi
	fi

	mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
	if [[ -n "$mem_kb" ]]; then
		local mem_gb=$(((mem_kb + 524288) / 1024 / 1024))
		if ((mem_gb >= 6)); then lk_ok "RAM: ~${mem_gb} GB"; elif ((mem_gb >= 4)); then lk_warn "RAM: ~${mem_gb} GB (KDE works, 6 GB+ is smoother)"; else lk_warn "RAM: ~${mem_gb} GB — KDE Plasma may be very slow"; fi
	fi

	if curl -fsS -m 10 -o /dev/null https://deb.debian.org 2>/dev/null || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
		lk_ok "Internet connection"
	else
		lk_err "No internet connection"
		fails=$((fails + 1))
	fi

	if [[ -e /dev/kgsl-3d0 ]]; then
		if [[ -r /dev/kgsl-3d0 && -w /dev/kgsl-3d0 ]]; then
			lk_ok "Adreno KGSL device accessible (/dev/kgsl-3d0) — Turnip fast path available"
		else
			lk_warn "/dev/kgsl-3d0 exists but is not accessible — Turnip will fall back to VirGL"
		fi
	fi

	if [[ -n "$sdk" ]] && ((sdk >= 31)); then
		lk_warn "Android 12+: the Phantom Process Killer can kill the desktop (signal 9)."
		lk_dim "Android 14+: Developer options → enable 'Disable child process restrictions'"
		lk_dim "Android 12/13 (via adb from a PC):"
		lk_dim "adb shell \"/system/bin/device_config set_sync_disabled_for_tests persistent\""
		lk_dim "adb shell \"/system/bin/device_config put activity_manager max_phantom_processes 2147483647\""
		lk_dim "adb shell settings put global settings_enable_monitor_phantom_procs false"
	fi

	((fails == 0)) || lk_die "$fails pre-flight check(s) failed. Fix them and run ./linkurd.sh install again."
}

step_storage_update() {
	lk_step "Storage access & Termux update"
	if [[ -d "$HOME/storage/shared" ]]; then
		lk_ok "Storage permission already granted"
	else
		lk_info "Requesting storage permission — tap ${C_B}Allow${C_0} on the Android dialog"
		termux-setup-storage
		local i
		for i in $(seq 1 40); do
			[[ -d "$HOME/storage/shared" ]] && break
			sleep 1
		done
		if [[ -d "$HOME/storage/shared" ]]; then lk_ok "Storage linked at ~/storage"; else lk_warn "Storage permission not granted (shared folders will be unavailable)"; fi
	fi
	lk_task "pkg update" pkg update "${LK_APT_OPTS[@]}" || lk_die "pkg update failed — try: termux-change-repo"
	lk_task "pkg upgrade" pkg upgrade "${LK_APT_OPTS[@]}" || lk_die "pkg upgrade failed"
}

step_repos() {
	lk_step "Repositories: mandoc · tur-repo · root-repo · x11-repo"
	lk_task "pkg install mandoc tur-repo root-repo x11-repo" \
		pkg install "${LK_APT_OPTS[@]}" mandoc tur-repo root-repo x11-repo || lk_die "Could not enable repositories"
	lk_task "pkg update" pkg update "${LK_APT_OPTS[@]}" || lk_die "pkg update failed"
	lk_task "pkg upgrade" pkg upgrade "${LK_APT_OPTS[@]}" || lk_die "pkg upgrade failed"
	local repo
	for repo in tur x11 root; do
		if lk_pkg_installed "${repo}-repo"; then lk_ok "${repo}-repo enabled"; else lk_warn "${repo}-repo is not installed"; fi
	done
}

step_core_packages() {
	lk_step "Installing necessary Termux packages"
	lk_pkg_install_list proot-distro proot termux-x11-nightly pulseaudio termux-api termux-tools \
		wget curl unzip jq git which ncurses-utils procps psmisc coreutils tar xz-utils \
		file openssl-tool
	local b nmissing=0
	for b in proot-distro termux-x11 pulseaudio pactl jq unzip curl; do
		lk_have "$b" || { lk_err "missing binary: $b"; nmissing=$((nmissing + 1)); }
	done
	((nmissing == 0)) || lk_die "$nmissing core binaries missing"
	lk_ok "All core binaries present"
}

step_companion_apps() {
	lk_step "Companion apps: Termux:X11 & Termux:API"
	if lk_app_installed "$LK_X11_PKG"; then
		lk_ok "Termux:X11 app installed"
	else
		lk_warn "Termux:X11 app not detected"
		lk_dim "Download: https://github.com/termux/termux-x11/releases/tag/nightly"
		if [[ "${TERMUX_APK_RELEASE:-${TERMUX_APP__APK_RELEASE:-}}" == GITHUB* ]]; then
			lk_dim "Pick termux-x11-universal-sharedUid-debug.apk — Android then keeps full CPU"
			lk_dim "speed for Debian while the desktop is on screen (big performance win)."
		else
			lk_dim "Pick termux-x11-universal-debug.apk (sharedUid build needs Termux from GitHub)"
		fi
		if lk_ask_yn "Open the download page now?" y; then
			termux-open-url "https://github.com/termux/termux-x11/releases/tag/nightly" >/dev/null 2>&1
			[[ "$LK_YES" == "1" ]] || read -r -p "  Press Enter after installing Termux:X11… " _ </dev/tty
		fi
	fi
	if lk_app_installed "$LK_API_PKG"; then lk_ok "Termux:API app installed"; else lk_warn "Termux:API app not detected (install from F-Droid, same source as Termux)"; fi

	lk_info "Testing Termux:API bridge (up to 10 s)…"
	if lk_api_probe; then
		local batt
		batt=$(timeout 8 termux-battery-status 2>/dev/null | jq -r '"\(.percentage)% · \(.status)"' 2>/dev/null)
		lk_ok "Termux:API responding — battery ${batt:-?}"
		lk_api termux-toast -s "LinKurd: installing Debian KDE Plasma…"
		lk_api termux-vibrate -d 60
	else
		lk_warn "Termux:API not responding — notifications/toasts disabled (everything else still works)"
	fi
}

step_config_wizard() {
	lk_step "Configuration"
	lk_detect_gpu
	LK_TZ=$(getprop persist.sys.timezone 2>/dev/null)

	local def_user="${LINKURD_USER:-kurd}" u p1 p2
	if [[ "$LK_YES" == "1" ]]; then
		LK_USER="$def_user"
		LK_PASS="${LINKURD_PASS:-linkurd}"
	else
		while true; do
			read -r -p "  ${C_Y}?${C_0} Debian username ${C_D}[$def_user]${C_0} " u </dev/tty
			u="${u:-$def_user}"
			[[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$u" != "root" ]] && break
			lk_warn "Use lowercase letters, digits, - or _ (not 'root')."
		done
		LK_USER="$u"
		while true; do
			read -r -s -p "  ${C_Y}?${C_0} Password for $LK_USER ${C_D}(min 4 chars)${C_0} " p1 </dev/tty
			echo
			read -r -s -p "  ${C_Y}?${C_0} Repeat password " p2 </dev/tty
			echo
			[[ ${#p1} -ge 4 && "$p1" == "$p2" ]] && break
			lk_warn "Passwords do not match or are too short."
		done
		LK_PASS="$p1"
	fi

	echo
	printf '  %sKDE Plasma profile%s\n' "$C_B" "$C_0"
	lk_menu LK_PROFILE "standard" \
		"standard|Standard|Plasma + Dolphin, Konsole, Kate, Okular, Gwenview, Spectacle, Ark." \
		"full|Full|Standard + kde-standard, Elisa, Haruna, KDE Connect, Filelight (+1.5 GB)."

	lk_choose_gpu_mode

	LK_MIC="n"
	lk_ask_yn "Enable microphone input for Debian apps?" n && LK_MIC="y"

	echo
	lk_rule
	printf '  %sInstallation summary%s\n' "$C_B" "$C_0"
	lk_kv "Distro" "Debian (proot-distro, stable)"
	lk_kv "Desktop" "KDE Plasma ($LK_PROFILE) on Termux:X11"
	lk_kv "User" "$LK_USER (sudo)"
	lk_kv "GPU" "$LK_GPU_MODEL"
	lk_kv "Acceleration" "$(lk_gpu_mode_label "$LK_GPU_MODE")"
	lk_kv "Audio" "PulseAudio TCP 127.0.0.1:4713$([[ $LK_MIC == y ]] && echo ' + mic')"
	lk_kv "Apps" "Firefox · VS Code · Google Antigravity"
	lk_kv "Timezone" "${LK_TZ:-UTC}"
	lk_rule
	lk_ask_yn "Start installation?" y || lk_die "Cancelled."
	mkdir -p "$LK_ETC"
	LK_INSTALLED_VERSION="$LK_VERSION"
	lk_save_conf
}

step_host_gpu() {
	lk_step "GPU drivers (Termux side)"
	lk_host_gpu_install
	lk_save_conf
}

# Install Debian, but gracefully reuse a container if proot-distro reports
# that its name already exists. The login probe also triggers proot-distro's
# automatic migration from its legacy rootfs layout when needed.
lk_install_debian_or_reuse() {
	local output rc
	output=$(proot-distro install "$LK_DISTRO" 2>&1)
	rc=$?
	[[ -n "$output" ]] && printf '%s\n' "$output"
	((rc == 0)) && return 0

	if grep -Eqi "container.*already exists|already installed" <<<"$output"; then
		lk_info "Debian container already exists; checking it with proot-distro login $LK_DISTRO"
		proot-distro login "$LK_DISTRO" -- /bin/sh -c 'exit 0'
		return $?
	fi
	return "$rc"
}

step_debian() {
	lk_step "Debian root filesystem"
	if lk_rootfs_ready; then
		lk_ok "Debian already installed at $(lk_rootfs)"
		if lk_ask_yn "Keep the existing Debian installation? (No = wipe & reinstall)" y; then
			# Log in once to validate the container and let proot-distro migrate
			# any legacy installed-rootfs layout to containers/<name>/rootfs.
			lk_task "Checking existing Debian via proot-distro login $LK_DISTRO" \
				proot-distro login "$LK_DISTRO" -- /bin/sh -c 'exit 0' ||
				lk_die "Existing Debian was found but proot-distro login $LK_DISTRO failed"
		else
			lk_task "Resetting Debian" proot-distro reset "$LK_DISTRO" || lk_die "Debian reset failed"
		fi
	else
		lk_task "proot-distro install debian (downloading rootfs)" lk_install_debian_or_reuse ||
			lk_die "Debian installation failed (and an existing container could not be opened)"
	fi
	lk_rootfs_ready || lk_die "Debian rootfs not found. Checked both the current containers/debian/rootfs path and the legacy installed-rootfs/debian path."
	lk_ok "Rootfs: $(lk_rootfs)"
	lk_write_guest_files
	lk_ok "Provisioning scripts deployed"
}

step_debian_base() {
	lk_step "Debian base system & user"
	lk_task "apt update · full-upgrade · locales · tools" lk_guest base || lk_die "Debian base setup failed"
	local r
	r=$(lk_rootfs)
	umask 077
	printf '%s' "$LK_PASS" >"$r/root/.linkurd-pass"
	umask 022
	unset LK_PASS
	lk_task "Creating user '$LK_USER' with sudo" lk_guest user || lk_die "User creation failed"
}

step_kde() {
	lk_step "KDE Plasma desktop ($LK_PROFILE)"
	lk_info "This is the largest download — usually 5–20 minutes"
	lk_task "Installing KDE Plasma + Breeze + core apps" lk_guest kde || lk_die "KDE Plasma installation failed"
}

step_guest_gpu() {
	lk_step "GPU drivers (Debian side)"
	LK_ARCH="${LK_ARCH:-$(uname -m)}"
	if [[ "$LK_GPU_MODE" == turnip* && "$LK_ARCH" != "aarch64" ]]; then
		LK_GPU_MODE="virgl"
		lk_warn "Turnip build is aarch64-only — switched to VirGL"
	fi
	if [[ "$LK_GPU_VENDOR" == "adreno" && "$LK_ARCH" == "aarch64" ]]; then
		lk_task "Turnip + Zink Mesa ${MESA_FREEDRENO_VERSION}" lk_guest_turnip_install ||
			{ [[ "$LK_GPU_MODE" == turnip* ]] && LK_GPU_MODE="virgl" && lk_warn "Turnip unavailable — switched to VirGL"; }
	fi
	lk_task "Mesa · Vulkan loader · GL/EGL/GLES · env profiles" lk_guest gpu || lk_warn "Some GPU packages failed"
	lk_save_conf
}

step_apps() {
	lk_step "Applications: Firefox · VS Code · Antigravity"
	lk_task "Firefox (Mozilla APT, fallback ESR)" lk_guest firefox
	lk_task "Visual Studio Code (Microsoft APT)" lk_guest vscode
	case "${LK_ARCH:-$(uname -m)}" in
	aarch64 | x86_64)
		lk_task "Google Antigravity (Google APT, fallback direct .deb)" lk_guest antigravity
		;;
	*) lk_warn "Google Antigravity has no build for $(uname -m) — skipped" ;;
	esac
}

step_finalize() {
	lk_step "Audio, launchers & verification"
	lk_task "PulseAudio client · ALSA→Pulse bridge" lk_guest audio
	lk_task "Session launcher · Electron fixes · desktop icons" lk_guest polish || lk_die "Session setup failed"
	lk_install_commands
	lk_ok "Commands installed: linkurd · linkurd-start · linkurd-stop · linkurd-shell · linkurd-doctor · linkurd-bench"
	echo
	cmd_doctor --embedded
}

lk_install_commands() {
	local self
	self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
	if [[ ! -f "$self" ]]; then
		lk_warn "Script was piped into bash — save it as a file so the linkurd command can be installed"
		return 1
	fi
	if [[ "$self" != "$LK_BIN/linkurd" ]]; then
		install -m 755 "$self" "$LK_BIN/linkurd"
	fi
	local c
	for c in start stop shell doctor bench; do
		printf '#!%s/bin/bash\nexec "%s/linkurd" %s "$@"\n' "$PREFIX" "$LK_BIN" "$c" >"$LK_BIN/linkurd-$c"
		chmod 755 "$LK_BIN/linkurd-$c"
	done
}

# ------------------------------------------------------------------------------
#  Commands
# ------------------------------------------------------------------------------
cmd_install() {
	mkdir -p "$LK_HOME" "$LK_CACHE"
	: >"$LK_LOG"
	lk_log "LinKurd $LK_VERSION install started on $(getprop ro.product.model) ($(getprop ro.product.brand))"
	lk_banner
	printf '  %sInstalls native Debian with KDE Plasma, GPU acceleration, audio,%s\n' "$C_D" "$C_0"
	printf '  %sFirefox, VS Code and Google Antigravity. Log: %s%s\n' "$C_D" "$LK_LOG" "$C_0"
	local start=$SECONDS

	step_preflight
	step_storage_update
	step_repos
	step_core_packages
	step_companion_apps
	step_config_wizard
	step_host_gpu
	step_debian
	step_debian_base
	step_kde
	step_guest_gpu
	step_apps
	step_finalize

	local el=$((SECONDS - start))
	echo
	lk_rule "$C_G"
	printf '  %s☀  LinKurd is installed%s %s(%dm %ds)%s\n' "$C_B$C_G" "$C_0" "$C_D" $((el / 60)) $((el % 60)) "$C_0"
	lk_rule "$C_G"
	lk_kv "Start desktop" "${C_B}linkurd-start${C_0}"
	lk_kv "Stop desktop" "${C_B}linkurd-stop${C_0}"
	lk_kv "Debian shell" "linkurd-shell"
	lk_kv "Health check" "linkurd-doctor"
	lk_kv "Switch GPU mode" "linkurd gpu"
	lk_kv "Update all" "linkurd update"
	if ((${#LK_SKIPPED[@]})); then
		echo
		lk_warn "Skipped steps: ${LK_SKIPPED[*]}"
	fi
	echo
	lk_api termux-notification --id linkurd-install --title "LinKurd installed" \
		--content "Run linkurd-start to launch KDE Plasma" --priority high
	lk_api termux-vibrate -d 200
}

cmd_start() {
	local gpu_override="" compositor="false" legacy=0 open_app=1 debug=0 dpi="" scale="" animations=0 fullscreen=""
	while (($#)); do
		case "$1" in
		--gpu) gpu_override="$2"; shift ;;
		--compositor) compositor="true" ;;
		--legacy) legacy=1 ;;
		--no-open) open_app=0 ;;
		--dpi) dpi="$2"; shift ;;
		--scale) scale="$2"; shift ;;
		--fullscreen) fullscreen="true" ;;
		--animations) animations=1 ;;
		--debug) debug=1 ;;
		-h | --help)
			cat <<-EOF
				linkurd-start [options]
				  --gpu MODE      turnip | turnip-safe | zink | virgl | angle | software (one-off)
				  --compositor    enable KWin compositing (effects; best with turnip)
				  --legacy        Termux:X11 legacy drawing (fixes black screen on some devices)
				  --dpi N         force DPI (e.g. 120 for phones, 96 for monitors)
				  --scale PCT     render at PCT% of native resolution (e.g. 50 = ~4x fewer pixels, much faster)
				  --fullscreen    hide Android status/navigation bars
				  --animations    keep Plasma animations (off by default for speed)
				  --no-open       do not auto-open the Termux:X11 app
				  --debug         follow the session log in this terminal
			EOF
			return 0
			;;
		*) lk_warn "Unknown option: $1" ;;
		esac
		shift
	done
	case "${gpu_override:-}" in
	"" | turnip | turnip-safe | zink | virgl | angle | software) ;;
	*) lk_die "Unknown GPU mode '$gpu_override' (use turnip, turnip-safe, zink, virgl, angle or software)" ;;
	esac
	[[ -z "$dpi" || "$dpi" =~ ^[0-9]{2,3}$ ]] || lk_die "--dpi expects a number like 120"
	[[ -z "$scale" || "$scale" =~ ^[0-9]{2,3}$ ]] || lk_die "--scale expects a percentage like 50"

	lk_in_proot && lk_die "Run linkurd-start from Termux, not inside Debian."
	[[ -f "$LK_CONF" ]] || lk_die "LinKurd is not installed. Run: ./linkurd.sh install"
	lk_load_conf
	lk_rootfs_ready || lk_die "Debian rootfs missing. Reinstall with: linkurd install"
	lk_guest_has /usr/local/bin/linkurd-session || lk_die "Session launcher missing. Run: linkurd repair"
	mkdir -p "$LK_HOME"

	printf '\n  %s☀ LinKurd%s %sstarting KDE Plasma…%s\n' "$C_B$C_Y" "$C_0" "$C_D" "$C_0"
	lk_rule

	cmd_stop --quiet

	lk_api_probe >/dev/null 2>&1
	if ((LK_API_OK)); then
		local batt pct status
		batt=$(timeout 8 termux-battery-status 2>/dev/null)
		pct=$(jq -r '.percentage // empty' <<<"$batt" 2>/dev/null)
		status=$(jq -r '.status // empty' <<<"$batt" 2>/dev/null)
		if [[ -n "$pct" ]] && ((pct < 20)) && [[ "$status" != "CHARGING" ]]; then
			lk_warn "Battery at ${pct}% — plug in the charger for a smoother session"
		fi
	fi
	lk_app_installed "$LK_X11_PKG" || lk_warn "Termux:X11 app not detected — install it or the display will not show"

	: >"$LK_SESSION_LOG"
	termux-wake-lock 2>/dev/null && lk_ok "Wake lock acquired"

	pulseaudio --kill >/dev/null 2>&1
	rm -rf "$HOME/.config/pulse/"*-runtime "$TMPDIR"/pulse-* 2>/dev/null
	if pulseaudio --start --exit-idle-time=-1 \
		--load="module-native-protocol-tcp auth-ip-acl=127.0.0.1 auth-anonymous=1 port=4713" >>"$LK_SESSION_LOG" 2>&1; then
		[[ "$LK_MIC" == "y" ]] && pactl load-module module-sles-source >/dev/null 2>&1
		lk_ok "PulseAudio on tcp:127.0.0.1:4713$([[ $LK_MIC == y ]] && echo ' (+mic)')"
	else
		lk_warn "PulseAudio failed to start — no sound this session"
	fi

	local mode="${gpu_override:-$LK_GPU_MODE}" effective
	effective=$(lk_gpu_server_start "$mode")
	if [[ "$effective" != "$mode" ]]; then
		lk_warn "GPU server for '$mode' failed — falling back to software rendering"
	else
		lk_ok "GPU: $(lk_gpu_mode_label "$effective")"
	fi

	rm -f "$TMPDIR/.X11-unix/X0" "$TMPDIR/.X0-lock"
	local x11_args=("$LK_DISPLAY" -ac)
	((legacy)) && x11_args+=(-legacy-drawing)
	[[ -n "$dpi" ]] && x11_args+=(-dpi "$dpi")
	nohup termux-x11 "${x11_args[@]}" >>"$LK_SESSION_LOG" 2>&1 </dev/null &
	local i
	for i in $(seq 1 50); do
		[[ -S "$TMPDIR/.X11-unix/X0" ]] && break
		sleep 0.2
	done
	[[ -S "$TMPDIR/.X11-unix/X0" ]] || lk_die "Termux:X11 server did not start. See $LK_SESSION_LOG"
	lk_ok "X11 server on display $LK_DISPLAY"

	if ((open_app)); then
		am start --user 0 -n "$LK_X11_PKG/$LK_X11_PKG.MainActivity" >/dev/null 2>&1 &&
			lk_ok "Termux:X11 opened"
	fi

	# termux-x11-preference blocks forever when the activity is not up, hence the timeout.
	local prefs=()
	[[ -n "$scale" ]] && prefs+=("displayResolutionMode=scaled" "displayScale=$scale")
	[[ -n "$fullscreen" ]] && prefs+=("fullscreen=true")
	if ((${#prefs[@]})) && lk_have termux-x11-preference; then
		local kv args=()
		for kv in "${prefs[@]}"; do args+=("\"${kv%%=*}\"=\"${kv#*=}\""); done
		if timeout 6 termux-x11-preference "${args[@]}" >>"$LK_SESSION_LOG" 2>&1; then
			lk_ok "Termux:X11 preferences: ${prefs[*]}"
		else
			lk_warn "Could not apply Termux:X11 preferences (open the app once and retry)"
		fi
	fi

	nohup proot-distro login "$LK_DISTRO" --user "$LK_USER" --shared-tmp -- \
		/usr/bin/env DISPLAY="$LK_DISPLAY" PULSE_SERVER=tcp:127.0.0.1:4713 \
		LINKURD_GPU="$effective" LINKURD_COMPOSITOR="$compositor" LINKURD_DPI="$dpi" \
		LINKURD_ANIMATIONS="$animations" \
		/usr/local/bin/linkurd-session >>"$LK_SESSION_LOG" 2>&1 </dev/null &
	echo $! >"$LK_SESSION_PID"
	lk_ok "KDE Plasma launching as '$LK_USER' (first boot takes ~30 s)"

	lk_api termux-notification --id linkurd --ongoing --priority low \
		--title "LinKurd · KDE Plasma running" \
		--content "GPU: $effective · user: $LK_USER" \
		--button1 "Open desktop" --button1-action "am start --user 0 -n $LK_X11_PKG/$LK_X11_PKG.MainActivity" \
		--button2 "Stop" --button2-action "$LK_BIN/linkurd-stop"
	lk_rule
	lk_dim "Stop: linkurd-stop   ·   Log: $LK_SESSION_LOG"
	echo
	if ((debug)); then
		tail -f "$LK_SESSION_LOG"
	fi
}

lk_kill_tree() {
	local pid="$1" child
	for child in $(pgrep -P "$pid" 2>/dev/null); do lk_kill_tree "$child"; done
	kill -TERM "$pid" 2>/dev/null
}

cmd_stop() {
	local quiet=0
	[[ "$1" == "--quiet" ]] && quiet=1
	lk_in_proot && lk_die "Run linkurd-stop from Termux, not inside Debian."

	if [[ -f "$LK_SESSION_PID" ]]; then
		lk_kill_tree "$(cat "$LK_SESSION_PID")"
		rm -f "$LK_SESSION_PID"
	fi
	pkill -TERM -f 'startplasma-x11|plasmashell|kwin_x11|ksmserver|kded[56]|kglobalaccel|krunner|kactivitymanagerd|org_kde_powerdevil|xembedsniproxy|gmenudbusmenuproxy|linkurd-session' >/dev/null 2>&1
	sleep 1
	pkill -KILL -f 'startplasma-x11|plasmashell|kwin_x11|ksmserver|kded[56]' >/dev/null 2>&1
	pkill -f 'dbus-daemon --syslog --fork --print-pid' >/dev/null 2>&1
	am broadcast -a com.termux.x11.ACTION_STOP -p "$LK_X11_PKG" >/dev/null 2>&1
	pkill -f 'com.termux.x11' >/dev/null 2>&1
	pkill -f 'termux-x11 :' >/dev/null 2>&1
	pkill -f virgl_test_server >/dev/null 2>&1
	pulseaudio --kill >/dev/null 2>&1
	rm -f "$TMPDIR/.X11-unix/X0" "$TMPDIR/.X0-lock" "$TMPDIR/.virgl_test" 2>/dev/null
	termux-wake-unlock >/dev/null 2>&1

	lk_api_probe >/dev/null 2>&1
	lk_api termux-notification-remove linkurd
	if ((!quiet)); then
		lk_ok "LinKurd stopped (X11, Plasma, GPU server, PulseAudio, wake lock)"
		lk_api termux-toast -s "LinKurd stopped"
	fi
	return 0
}

cmd_shell() {
	lk_load_conf
	lk_rootfs_ready || lk_die "Debian is not installed."
	exec proot-distro login "$LK_DISTRO" --user "${LK_USER:-root}" --shared-tmp -- \
		/usr/bin/env DISPLAY="$LK_DISPLAY" PULSE_SERVER=tcp:127.0.0.1:4713 /bin/bash -l "$@"
}

cmd_doctor() {
	local embedded=0 gpu_test=0 pass=0 warn=0 fail=0
	for a in "$@"; do
		[[ "$a" == "--embedded" ]] && embedded=1
		[[ "$a" == "--gpu-test" ]] && gpu_test=1
	done
	((embedded)) || lk_banner
	lk_load_conf
	printf '  %sLinKurd health check%s\n\n' "$C_B" "$C_0"

	chk() {
		local level="$1" label="$2"
		shift 2
		if "$@" >/dev/null 2>&1; then
			printf '  %s✔%s %s\n' "$C_G" "$C_0" "$label"
			pass=$((pass + 1))
		elif [[ "$level" == "warn" ]]; then
			printf '  %s▲%s %s\n' "$C_Y" "$C_0" "$label"
			warn=$((warn + 1))
		else
			printf '  %s✖%s %s\n' "$C_R" "$C_0" "$label"
			fail=$((fail + 1))
		fi
	}

	printf '  %sTermux host%s\n' "$C_D" "$C_0"
	chk fail "Running in Termux" lk_in_termux
	chk fail "Storage linked (~/storage)" test -d "$HOME/storage/shared"
	local p
	for p in proot-distro termux-x11-nightly pulseaudio termux-api virglrenderer-android; do
		chk fail "package: $p" lk_pkg_installed "$p"
	done
	chk warn "repo: tur-repo" lk_pkg_installed tur-repo
	chk warn "repo: x11-repo" lk_pkg_installed x11-repo
	chk warn "repo: root-repo" lk_pkg_installed root-repo
	chk fail "Termux:X11 app" lk_app_installed "$LK_X11_PKG"
	chk warn "Termux:API app responding" lk_api_probe
	chk fail "linkurd-start command" test -x "$LK_BIN/linkurd-start"
	chk fail "linkurd-stop command" test -x "$LK_BIN/linkurd-stop"

	echo
	printf '  %sGPU · %s · mode %s%s\n' "$C_D" "${LK_GPU_MODEL:-?}" "${LK_GPU_MODE:-?}" "$C_0"
	case "$LK_GPU_MODE" in
	turnip | turnip-safe)
		chk fail "Turnip ICD in Debian" lk_guest_has "$MESA_FREEDRENO_PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json"
		chk fail "Turnip driver library" lk_guest_has "$MESA_FREEDRENO_PREFIX/lib/aarch64-linux-gnu/libvulkan_freedreno.so"
		chk fail "Adreno KGSL device (/dev/kgsl-3d0)" test -w /dev/kgsl-3d0
		chk warn "vulkaninfo (Turnip self-test)" lk_guest_has /usr/bin/vulkaninfo
		chk warn "VirGL fallback server" lk_have virgl_test_server_android
		;;
	virgl | angle) chk fail "virgl_test_server_android" lk_have virgl_test_server_android ;;
	zink)
		chk fail "virgl_test_server" lk_have virgl_test_server
		[[ -n "$LK_HOST_ICD" ]] && chk fail "host Vulkan ICD ($LK_HOST_ICD)" test -f "$LK_HOST_ICD"
		;;
	esac
	chk fail "GPU env profile" lk_guest_has "/etc/linkurd/gpu/${LK_GPU_MODE:-software}.env"

	echo
	printf '  %sDebian guest%s\n' "$C_D" "$C_0"
	chk fail "Debian rootfs" lk_rootfs_ready
	chk fail "User '$LK_USER'" grep -q "^${LK_USER}:" "$(lk_rootfs)/etc/passwd"
	chk fail "KDE Plasma (startplasma-x11)" lk_guest_has /usr/bin/startplasma-x11
	chk fail "Session launcher" lk_guest_has /usr/local/bin/linkurd-session
	chk fail "dbus-launch" lk_guest_has /usr/bin/dbus-launch
	chk fail "PulseAudio client (pactl)" lk_guest_has /usr/bin/pactl
	chk warn "Mesa utils (glxinfo)" lk_guest_has /usr/bin/glxinfo
	chk fail "Firefox" bash -c "[[ -e '$(lk_rootfs)/usr/bin/firefox' || -L '$(lk_rootfs)/usr/bin/firefox' || -e '$(lk_rootfs)/usr/bin/firefox-esr' ]]"
	chk fail "Visual Studio Code" lk_guest_has /usr/share/code/bin/code
	chk warn "VS Code proot launcher (--no-sandbox)" lk_guest_has /usr/local/bin/code
	case "$(uname -m)" in
	aarch64 | x86_64)
		chk fail "Google Antigravity" lk_guest_has /usr/share/antigravity/bin/antigravity
		chk warn "Antigravity proot launcher (--no-sandbox)" lk_guest_has /usr/local/bin/antigravity
		chk warn "apt sources free of Signed-By conflicts" lk_sources_clean
		;;
	esac

	if ((gpu_test)); then
		echo
		if [[ -S "$TMPDIR/.X11-unix/X0" ]]; then
			printf '  %sLive GPU test%s\n' "$C_D" "$C_0"
			lk_guest_bench_quick
		else
			lk_warn "Start the desktop first (linkurd-start) to run the live GPU test"
		fi
	fi

	echo
	lk_rule
	printf '  %s✔ %d passed%s   %s▲ %d warnings%s   %s✖ %d failed%s\n' "$C_G" "$pass" "$C_0" "$C_Y" "$warn" "$C_0" "$C_R" "$fail" "$C_0"
	lk_rule
	((fail == 0))
}

# True when no repo is defined twice across sources.list.d (the v1 Antigravity bug).
lk_sources_clean() {
	local d pattern n
	d="$(lk_rootfs)/etc/apt/sources.list.d"
	for pattern in 'packages.microsoft.com/repos/code' 'antigravity-auto-updater-dev' 'packages.mozilla.org'; do
		n=$(grep -l -- "$pattern" "$d"/*.list "$d"/*.sources 2>/dev/null | wc -l)
		((n <= 1)) || return 1
	done
}

lk_guest_bench_quick() {
	proot-distro login "$LK_DISTRO" --user "$LK_USER" --shared-tmp -- /usr/bin/env \
		DISPLAY="$LK_DISPLAY" LINKURD_GPU="$LK_GPU_MODE" /bin/bash -c \
		'mode=$LINKURD_GPU; [ -f /etc/linkurd/gpu/$mode.env ] && { set -a; . /etc/linkurd/gpu/$mode.env; set +a; }
		glxinfo -B 2>&1 | grep -E "renderer string|version string" | sed "s/^/    /"'
}

cmd_bench() {
	lk_load_conf
	[[ -f "$LK_CONF" ]] || lk_die "Install LinKurd first."
	lk_in_proot && lk_die "Run linkurd bench from Termux, not inside Debian."
	[[ -S "$TMPDIR/.X11-unix/X0" ]] || lk_die "Start the desktop first: linkurd-start"
	lk_guest_has /usr/local/bin/linkurd-bench || lk_die "Benchmark helper missing. Run: linkurd repair"
	local mode="${1:-$LK_GPU_MODE}"
	printf '\n  %s☀ LinKurd GPU benchmark%s %s(%s)%s\n' "$C_B$C_Y" "$C_0" "$C_D" "$(lk_gpu_mode_label "$mode")" "$C_0"
	lk_rule
	proot-distro login "$LK_DISTRO" --user "$LK_USER" --shared-tmp -- /usr/bin/env \
		DISPLAY="$LK_DISPLAY" LINKURD_GPU="$mode" /usr/local/bin/linkurd-bench
	lk_rule
	lk_dim "Compare modes: linkurd bench turnip · linkurd bench turnip-safe · linkurd bench virgl"
}

cmd_gpu() {
	lk_load_conf
	[[ -f "$LK_CONF" ]] || lk_die "Install LinKurd first."
	lk_banner
	mkdir -p "$LK_HOME" "$LK_CACHE"
	lk_detect_gpu
	LK_ARCH=$(uname -m)
	lk_choose_gpu_mode
	LK_TOTAL_STEPS=2
	LK_STEP=0
	lk_rootfs_ready && lk_write_guest_files
	step_host_gpu
	step_guest_gpu
	lk_ok "GPU mode saved. Restart with: linkurd-stop && linkurd-start"
}

cmd_update() {
	lk_load_conf
	lk_banner
	mkdir -p "$LK_HOME"
	LK_TOTAL_STEPS=3
	LK_STEP=0
	lk_step "Termux packages"
	lk_task "pkg update" pkg update "${LK_APT_OPTS[@]}"
	lk_task "pkg upgrade" pkg upgrade "${LK_APT_OPTS[@]}"
	lk_step "Debian packages (KDE, Firefox, VS Code, Antigravity)"
	lk_write_guest_files
	lk_task "apt full-upgrade in Debian (heals duplicate apt sources)" lk_guest update
	if [[ "$LK_GPU_VENDOR" == "adreno" && "$(uname -m)" == "aarch64" ]]; then
		lk_task "Turnip + Zink Mesa ${MESA_FREEDRENO_VERSION}" lk_guest_turnip_install
		lk_task "GPU env profiles" lk_guest gpu
	fi
	lk_task "Session launcher · Electron fixes" lk_guest polish
	lk_step "LinKurd commands"
	lk_install_commands
	lk_ok "Everything is up to date"
}

cmd_repair() {
	lk_load_conf
	[[ -n "$LK_USER" ]] || lk_die "No configuration found — run install."
	lk_banner
	mkdir -p "$LK_HOME"
	LK_TOTAL_STEPS=2
	LK_STEP=0
	lk_step "Re-deploying guest scripts"
	lk_write_guest_files
	lk_task "Removing duplicate apt sources (Signed-By conflicts)" lk_guest sources
	if [[ "$(uname -m)" =~ ^(aarch64|x86_64)$ ]] && ! lk_guest_has /usr/share/antigravity/bin/antigravity; then
		lk_task "Google Antigravity (reinstall)" lk_guest antigravity
	fi
	lk_task "Session launcher · Electron fixes" lk_guest polish
	lk_task "Audio bridge" lk_guest audio
	lk_task "GPU env profiles" lk_guest gpu
	lk_step "Commands"
	lk_install_commands
	cmd_doctor --embedded
}

cmd_uninstall() {
	lk_banner
	lk_warn "This removes the Debian container, ALL its files, and LinKurd commands."
	local answer
	read -r -p "  Type ${C_B}yes${C_0} to confirm: " answer </dev/tty
	[[ "$answer" == "yes" ]] || lk_die "Cancelled."
	cmd_stop --quiet
	lk_spin "Removing Debian container" proot-distro remove "$LK_DISTRO"
	rm -f "$LK_BIN"/linkurd-{start,stop,shell,doctor,bench}
	rm -rf "$LK_ETC" "$HOST_TURNIP_DIR" "$LK_CACHE"
	lk_ok "LinKurd removed. Termux packages were left installed."
	rm -f "$LK_BIN/linkurd"
}

cmd_help() {
	lk_banner
	cat <<-EOF
		  ${C_B}Install${C_0}
		    bash linkurd.sh install     guided full installation
		  ${C_B}Daily use${C_0}
		    linkurd-start [--help]      start KDE Plasma and open Termux:X11
		    linkurd-start --scale 50    render at half resolution (fastest)
		    linkurd-start --gpu turnip-safe   Adreno black-screen fix
		    linkurd-stop                stop the desktop and free resources
		    linkurd-shell               Debian terminal as your user
		  ${C_B}Performance${C_0}
		    linkurd bench [MODE]        glxinfo + vulkaninfo + glmark2 (desktop running)
		  ${C_B}Maintenance${C_0}
		    linkurd doctor [--gpu-test] health check (live GL test while running)
		    linkurd gpu                 re-detect GPU and switch acceleration mode
		    linkurd update              upgrade Termux + Debian + apps + Turnip
		    linkurd repair              redeploy launchers/configs (fixes Antigravity apt)
		    linkurd uninstall           remove everything
		  ${C_B}Unattended install${C_0}
		    LINKURD_YES=1 LINKURD_USER=me LINKURD_PASS=secret ./linkurd.sh install
		    LINKURD_GPU=adreno|mali|xclipse|powervr   force GPU vendor detection

	EOF
}

main() {
	local cmd="${1:-help}"
	shift 2>/dev/null
	case "$cmd" in
	install) cmd_install "$@" ;;
	start) cmd_start "$@" ;;
	stop) cmd_stop "$@" ;;
	shell) cmd_shell "$@" ;;
	doctor | check) cmd_doctor "$@" ;;
	gpu) cmd_gpu "$@" ;;
	bench | benchmark) cmd_bench "$@" ;;
	update) cmd_update "$@" ;;
	repair) cmd_repair "$@" ;;
	uninstall | remove) cmd_uninstall "$@" ;;
	version | -v | --version) echo "$LK_NAME $LK_VERSION" ;;
	help | -h | --help) cmd_help ;;
	*) lk_err "Unknown command: $cmd"; cmd_help; exit 1 ;;
	esac
}

main "$@"
