#!/usr/bin/env bash
set -euo pipefail

# bootstrap-linux.sh
#
# -e
# 含义：遇到任何非零退出状态的命令时立即退出脚本。
# 作用：防止错误被忽略，避免脚本继续执行导致更严重的问题。
#
# -u
# 含义：使用未定义的变量时会报错并退出。
# 作用：避免拼写错误或未初始化变量导致不可预期的行为。
#
# -o pipefail
# 含义：在管道命令中，如果任意一个子命令失败，整个管道返回非零状态。
# 默认情况下，管道的返回值是最后一个命令的退出状态，这可能掩盖前面命令的错误。
# 作用：确保管道中任何错误都能被检测到。
#
#
# 用途：
#   初始化一台 Linux 机器，安装基础工具、同步个人 dotfiles，并按配置文件选择
#   是否安装高级组件。脚本设计为幂等执行：重复运行时会尽量复用已有安装，
#   已存在的仓库会执行更新，已存在的插件目录会跳过。
#
# 安装层级：
#   minimal  - 基础安装。包含包管理器检测、基础工具、oh-my-zsh、远程 myconfig
#              仓库同步、.zshrc/.vimrc/.tmux.conf 复制、Vundle/tpm 安装。
#   advanced - 先执行 minimal，再按配置开关安装 Miniconda、Docker、kubectl、
#              kind、Open vSwitch。
#
# 配置文件：
#   默认读取脚本同目录的 bootstrap.conf，也可以通过 --config PATH 指定。
#   配置文件不存在时不会报错，会按 PROFILE=minimal 的安全默认值运行。
#   配置格式是普通 shell 变量赋值，见 bootstrap.conf 示例。
#
# 常用方式：
#   ./bootstrap-linux.sh
#   ./bootstrap-linux.sh --dry-run
#   ./bootstrap-linux.sh --config ./bootstrap.conf -v
#
# 注意：
#   不要使用 sudo 直接调用本脚本。普通用户运行时，脚本只会对系统级命令
#   自动使用 sudo；root 登录 shell 可以直接运行，配置会安装到 /root。

REPO_URL_DEFAULT="https://github.com/Liameternal/myconfig.git"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG_FILE="$SCRIPT_DIR/bootstrap.conf"
LOGFILE_DEFAULT="$SCRIPT_DIR/bootstrap-linux.log"

CONFIG_FILE="$DEFAULT_CONFIG_FILE"
DRY_RUN=false
VERBOSE=false
LOGFILE="$LOGFILE_DEFAULT"

show_help() {
  cat <<EOF
bootstrap-linux.sh - Linux bootstrap with minimal/advanced profiles

Usage:
  ./bootstrap-linux.sh [OPTIONS]

Options:
  --config PATH       Read config from PATH (default: $DEFAULT_CONFIG_FILE)
  --dry-run           Print actions without making changes
  --log-file PATH     Write verbose log to PATH (default: $LOGFILE_DEFAULT)
  -v, --verbose       Enable verbose logging to logfile
  -h, --help          Show this help

Config:
  PROFILE=minimal     Run basic setup only
  PROFILE=advanced    Run basic setup plus enabled advanced components

Notes:
  Do not run this script with sudo directly.
  Normal users should run it directly; system commands will use sudo as needed.
  Root may run it from a root login shell, for example after sudo -i or su -,
  to install configuration under /root.

EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config)
      if [ $# -lt 2 ]; then
        echo "Missing value for --config" >&2
        exit 1
      fi
      CONFIG_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --log-file)
      if [ $# -lt 2 ]; then
        echo "Missing value for --log-file" >&2
        exit 1
      fi
      LOGFILE="$2"
      shift 2
      ;;
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

resolve_home_for_user() {
  local user="$1"
  local home=""

  if command -v getent >/dev/null 2>&1; then
    home="$(getent passwd "$user" | cut -d: -f6 || true)"
  fi

  if [ -z "$home" ] && [ -n "${HOME:-}" ]; then
    home="$HOME"
  fi

  if [ -z "$home" ]; then
    echo "[bootstrap-linux] Could not determine home directory for user: $user" >&2
    return 1
  fi

  printf '%s' "$home"
}

# 支持普通用户直接运行，或 root 登录 shell 直接运行。
# 禁止 sudo 直接调用脚本，避免 TARGET_HOME/HOME 和配置文件属主混乱。
# 允许 sudo -i / su - 后在 root shell 中运行，用于初始化 /root。
# 这里不写日志，因为 log() 还未定义，避免脚本启动阶段出现函数顺序问题。
if [ "$(id -u)" -eq 0 ]; then
  script_name="$(basename "${BASH_SOURCE[0]}")"
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && [[ "${SUDO_COMMAND:-}" == *"$script_name"* ]]; then
    echo "[bootstrap-linux] Do not run this script with sudo directly. Use ./bootstrap-linux.sh as your normal user, or enter a root shell with sudo -i / su - and run it there." >&2
    exit 1
  fi
  TARGET_USER="root"
  TARGET_HOME="/root"
else
  TARGET_USER="$(id -un)"
  TARGET_HOME="$(resolve_home_for_user "$TARGET_USER")"
fi
DEST_DIR_DEFAULT="$TARGET_HOME/myconfig"

if [ "$DRY_RUN" = false ] && [ ! -w "$(dirname "$LOGFILE")" ] 2>/dev/null; then
  LOGFILE="$TARGET_HOME/bootstrap-linux.log"
fi

log() {
  echo "[bootstrap-linux] $*"
  if [ "$VERBOSE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
      printf "[DRY-RUN][%s] %s\n" "$(date -Iseconds)" "$*" >>"$LOGFILE" 2>/dev/null || true
    else
      printf "[%s] %s\n" "$(date -Iseconds)" "$*" >>"$LOGFILE" 2>/dev/null || true
    fi
  fi
}

if [ -t 1 ]; then
  GREEN="$(printf '\033[0;32m')"
  BLUE="$(printf '\033[0;34m')"
  RESET="$(printf '\033[0m')"
else
  GREEN=""
  BLUE=""
  RESET=""
fi

stage_start() {
  STAGE_NAME="$1"
  STAGE_START_TIME="$(date +%s)"
  printf "%s==> START: %s%s\n" "$BLUE" "$STAGE_NAME" "$RESET"
}

stage_end() {
  local now dur
  now="$(date +%s)"
  dur=$((now - STAGE_START_TIME))
  printf "%s<== DONE: %s (%ss)%s\n" "$GREEN" "$STAGE_NAME" "$dur" "$RESET"
  unset STAGE_NAME
  unset STAGE_START_TIME
}

run_stage() {
  local name="$1"
  local rc
  shift
  stage_start "$name"
  set +e
  "$@"
  rc=$?
  set -e
  stage_end
  return "$rc"
}

# 读取配置文件。
# 何时执行：参数解析和日志初始化后、任何安装动作前。
# 幂等性：只读取变量，不修改文件。
# 失败策略：默认配置文件不存在时继续运行；显式指定的配置文件不存在或不可读则退出。
load_config() {
  CONFIG_WAS_LOADED=false

  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
    CONFIG_WAS_LOADED=true
    log "Loaded config: $CONFIG_FILE"
    return 0
  fi

  if [ "$CONFIG_FILE" != "$DEFAULT_CONFIG_FILE" ]; then
    log "Config file not found: $CONFIG_FILE"
    return 1
  fi

  log "Default config not found; using built-in minimal defaults"
}

normalize_bool() {
  local name="$1"
  local value="$2"

  case "$value" in
    true|false)
      printf '%s' "$value"
      ;;
    *)
      echo "[bootstrap-linux] Invalid boolean for $name: $value (expected true or false)" >&2
      return 1
      ;;
  esac
}

# 校验并补齐配置默认值。
# 何时执行：load_config 之后。
# 幂等性：只整理内存中的变量。
# 失败策略：PROFILE 或布尔开关非法时直接退出，避免执行错误范围的安装。
validate_config() {
  PROFILE="${PROFILE:-minimal}"
  REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
  DEST_DIR="${DEST_DIR:-$DEST_DIR_DEFAULT}"

  case "$PROFILE" in
    minimal|advanced) ;;
    *)
      log "Invalid PROFILE: $PROFILE (expected minimal or advanced)"
      return 1
      ;;
  esac

  if [ "$PROFILE" = "advanced" ]; then
    INSTALL_CONDA="$(normalize_bool INSTALL_CONDA "${INSTALL_CONDA:-true}")"
    INSTALL_DOCKER="$(normalize_bool INSTALL_DOCKER "${INSTALL_DOCKER:-true}")"
    INSTALL_KUBECTL="$(normalize_bool INSTALL_KUBECTL "${INSTALL_KUBECTL:-true}")"
    INSTALL_KIND="$(normalize_bool INSTALL_KIND "${INSTALL_KIND:-true}")"
    INSTALL_OVS="$(normalize_bool INSTALL_OVS "${INSTALL_OVS:-true}")"
  else
    INSTALL_CONDA=false
    INSTALL_DOCKER=false
    INSTALL_KUBECTL=false
    INSTALL_KIND=false
    INSTALL_OVS=false
  fi

  log "Profile: $PROFILE"
  log "Advanced components: conda=$INSTALL_CONDA docker=$INSTALL_DOCKER kubectl=$INSTALL_KUBECTL kind=$INSTALL_KIND ovs=$INSTALL_OVS"
}

# 统一执行命令。
# 何时执行：所有需要修改系统、写入用户配置或调用外部安装命令的步骤。
# 幂等性：由调用方保证；此函数只负责 dry-run、日志和重试。
# 失败策略：默认重试 3 次，全部失败后返回原始错误码。
run_with_retries() {
  local scope="$1"
  local cmd="$2"
  : "${RETRIES:=3}"
  : "${RETRY_DELAY:=5}"

  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN [$scope]: $cmd"
    return 0
  fi

  local attempt=1
  local rc=0
  local sleep_seconds

  while [ "$attempt" -le "$RETRIES" ]; do
    log "RUN [$scope] (attempt $attempt/$RETRIES): $cmd"
    if [ "$scope" = "root" ]; then
      if [ "$(id -u)" -eq 0 ]; then
        if eval "$cmd"; then
          rc=0
        else
          rc=$?
        fi
      else
        if ! command -v sudo >/dev/null 2>&1; then
          log "sudo is required for system command but was not found"
          return 1
        fi
        if sudo bash -lc "$cmd"; then
          rc=0
        else
          rc=$?
        fi
      fi
    else
      if (
        export HOME="$TARGET_HOME"
        eval "$cmd"
      ); then
        rc=0
      else
        rc=$?
      fi
    fi

    if [ "$rc" -eq 0 ]; then
      return 0
    fi

    log "Command failed with exit code $rc: $cmd"
    if [ "$attempt" -lt "$RETRIES" ]; then
      sleep_seconds=$((RETRY_DELAY * (2 ** (attempt - 1))))
      log "Retrying in ${sleep_seconds}s..."
      sleep "$sleep_seconds"
    fi
    attempt=$((attempt + 1))
  done

  log "All $RETRIES attempts failed for: $cmd"
  return "$rc"
}

run_root() {
  run_with_retries root "$*"
}

run_user() {
  run_with_retries user "$*"
}

# 检测发行版和包管理器。
# 何时执行：安装前第一步。
# 幂等性：只读取 /etc/os-release 和 PATH。
# 失败策略：无法识别时设置为 unknown，后续安装函数会跳过不支持的操作。
detect_distro_and_pkgmgr() {
  DISTRO="unknown"
  VERSION_ID="unknown"
  PRETTY_NAME="unknown"

  if [ -r /etc/os-release ]; then
    # shellcheck source=/dev/null
    . /etc/os-release || true
    DISTRO="${ID:-unknown}"
    VERSION_ID="${VERSION_ID:-unknown}"
    PRETTY_NAME="${PRETTY_NAME:-unknown}"
  fi

  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER=apt
  elif command -v dnf >/dev/null 2>&1; then
    PKG_MANAGER=dnf
  elif command -v yum >/dev/null 2>&1; then
    PKG_MANAGER=yum
  elif command -v zypper >/dev/null 2>&1; then
    PKG_MANAGER=zypper
  elif command -v pacman >/dev/null 2>&1; then
    PKG_MANAGER=pacman
  else
    PKG_MANAGER=unknown
  fi

  log "Detected distro: $DISTRO ($PRETTY_NAME), version: $VERSION_ID, package manager: $PKG_MANAGER"
}

# 安装包列表。
# 何时执行：minimal 基础工具、高级组件依赖。
# 幂等性：直接在函数内按包管理器查询包数据库；已安装或同名命令已存在则跳过。
# 失败策略：只保留 run_root 作为系统命令执行边界，包管理器选择和安装命令都在这里完成。
ensure_packages() {
  local to_install=()
  local pkg
  local pkgstr

  for pkg in "$@"; do
    case "$PKG_MANAGER" in
      apt)
        if dpkg -s "$pkg" >/dev/null 2>&1; then
          log "Package already installed: $pkg"
          continue
        fi
        ;;
      dnf|yum|zypper)
        if rpm -q "$pkg" >/dev/null 2>&1; then
          log "Package already installed: $pkg"
          continue
        fi
        ;;
      pacman)
        if pacman -Qi "$pkg" >/dev/null 2>&1; then
          log "Package already installed: $pkg"
          continue
        fi
        ;;
    esac

    if command -v "$pkg" >/dev/null 2>&1; then
      log "Command already available; skip package: $pkg"
    else
      to_install+=("$pkg")
    fi
  done

  if [ "${#to_install[@]}" -eq 0 ]; then
    log "No packages to install"
    return 0
  fi

  pkgstr="$(printf '%s ' "${to_install[@]}")"
  log "Installing packages: $pkgstr"
  case "$PKG_MANAGER" in
    apt)
      run_root "apt-get update -y" || return 1
      run_root "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $pkgstr"
      ;;
    dnf)
      run_root "dnf install -y $pkgstr"
      ;;
    yum)
      run_root "yum install -y $pkgstr"
      ;;
    zypper)
      run_root "zypper install -y $pkgstr"
      ;;
    pacman)
      run_root "pacman -Sy --noconfirm $pkgstr"
      ;;
    *)
      log "No supported package manager found; skipping package install: $pkgstr"
      return 1
      ;;
  esac
}

pkg_name() {
  local key="$1"

  case "$key" in
    openvswitch)
      case "$PKG_MANAGER" in
        apt) printf '%s' "openvswitch-switch" ;;
        dnf|yum)
          if [ "$DISTRO" = "fedora" ]; then
            printf '%s' "openvswitch"
          else
            printf '%s' "openvswitch3.5"
          fi
          ;;
        zypper|pacman) printf '%s' "openvswitch" ;;
        *) printf '%s' "$key" ;;
      esac
      ;;
    shellcheck)
      case "$PKG_MANAGER" in
        dnf|yum) printf '%s' "ShellCheck" ;;
        *) printf '%s' "shellcheck" ;;
      esac
      ;;
    *)
      printf '%s' "$key"
      ;;
  esac
}

# 在 RHEL 系发行版上补充 EPEL 仓库。
# 何时执行：minimal 阶段，安装基础工具之前。
# 幂等性：已安装的 repo 包会跳过。
# 失败策略：仓库包安装失败不强行退出，后续包安装仍按 best-effort 继续。
ensure_rhel_repos() {
  if [ "$DISTRO" = "fedora" ]; then
    log "Fedora detected; skipping EPEL setup"
    return 0
  fi

  case "$PKG_MANAGER" in
    dnf|yum)
      if echo "$DISTRO" | grep -Eiq 'amzn|amazon'; then
        if command -v amazon-linux-extras >/dev/null 2>&1; then
          run_root "amazon-linux-extras install -y epel || true"
        fi
      fi

      ensure_packages epel-release || true
      run_root "$PKG_MANAGER makecache || true"
      ;;
    *)
      log "RHEL repo setup not applicable for package manager: $PKG_MANAGER"
      ;;
  esac
}

# 在 RHEL/CentOS/Rocky 等系统上为 Open vSwitch 准备 NFV 仓库。
# 何时执行：advanced 且 INSTALL_OVS=true 时，在安装 OVS 包之前。
# 幂等性：repo 包已安装则跳过。
# 失败策略：仓库包可能因发行版差异不可用，失败只记录并继续尝试安装 OVS。
ensure_openvswitch_repos() {
  if [ "$DISTRO" = "fedora" ]; then
    log "Fedora provides openvswitch directly; skipping NFV repo setup"
    return 0
  fi

  case "$PKG_MANAGER" in
    dnf|yum)
      ensure_packages centos-release-nfv-common centos-release-nfv-openvswitch || true
      run_root "$PKG_MANAGER makecache || true"
      ;;
    *)
      log "Open vSwitch repo setup not applicable for package manager: $PKG_MANAGER"
      ;;
  esac
}

# 禁用 SELinux。
# 何时执行：minimal 阶段早期。
# 幂等性：已禁用时跳过；首次修改会备份 /etc/selinux/config。
# 失败策略：setenforce/sed 失败会被降级为日志，避免非 SELinux 环境中断。
# 副作用：会把运行时 SELinux 从 Enforcing 调成 Permissive，并把配置持久化为 disabled。
ensure_selinux_disabled() {
  local cur_state="unknown"

  if [ ! -f /etc/selinux/config ] && ! command -v getenforce >/dev/null 2>&1; then
    log "SELinux not detected; skipping"
    return 0
  fi

  if command -v getenforce >/dev/null 2>&1; then
    cur_state="$(getenforce 2>/dev/null || echo Disabled)"
    if [ "$cur_state" = "Disabled" ]; then
      log "SELinux already disabled"
      return 0
    fi
  fi

  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: would set SELinux permissive and write SELINUX=disabled"
    return 0
  fi

  if [ "$cur_state" = "Enforcing" ]; then
    run_root "setenforce 0 || true"
  fi

  if [ -f /etc/selinux/config ]; then
    if [ ! -f /etc/selinux/config.bak-bootstrap ]; then
      run_root "cp -a /etc/selinux/config /etc/selinux/config.bak-bootstrap || true"
    fi
    run_root "sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true"
  fi
}

# 安装 minimal 所需基础工具。
# 何时执行：minimal 阶段。
# 幂等性：ensure_packages 会跳过已安装包。
# 失败策略：个别发行版缺包时记录日志并继续，避免一个可选工具阻塞整机初始化。
install_basic_tools() {
  local tools=(git curl wget zsh tmux vim python3-pip fzf ripgrep)
  local tool mapped

  for tool in "${tools[@]}"; do
    mapped="$(pkg_name "$tool")"
    ensure_packages "$mapped" || log "Package may be unavailable on this distro: $mapped"
  done
}

# 安装 advanced 所需基础工具。
# 何时执行：advanced 阶段。
# 幂等性：ensure_packages 会跳过已安装包。
# 失败策略：个别发行版缺包时记录日志并继续，避免一个可选工具阻塞整机初始化。
install_dev_tools() {
  local tools=(p7zip procps-ng sysstat iproute perf tcpdump strace bpftrace gdb shellcheck iscsi-initiator-utils unrar net-snmp-utils helm sshpass golang)
  local tool mapped

  for tool in "${tools[@]}"; do
    mapped="$(pkg_name "$tool")"
    ensure_packages "$mapped" || log "Package may be unavailable on this distro: $mapped"
  done
}

# 安装 oh-my-zsh。
# 何时执行：minimal 阶段，复制 .zshrc 前。
# 幂等性：目标目录存在则跳过。
# 失败策略：优先 git clone；git 不可用时才下载官方安装脚本。
# 权限策略：始终以目标用户身份写入 TARGET_HOME，不做后置家目录 chown。
install_oh_my_zsh() {
  local oh_dir="$TARGET_HOME/.oh-my-zsh"

  if [ -d "$oh_dir" ]; then
    log "oh-my-zsh already installed: $oh_dir"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: would install oh-my-zsh into $oh_dir"
    return 0
  fi

  if command -v git >/dev/null 2>&1; then
    run_user "git clone https://github.com/ohmyzsh/ohmyzsh.git '$oh_dir'"
  elif command -v curl >/dev/null 2>&1; then
    run_user "curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/ohmyzsh_install.sh"
    run_user "env KEEP_ZSHRC=yes CHSH=no RUNZSH=no sh /tmp/ohmyzsh_install.sh || true"
    run_user "rm -f /tmp/ohmyzsh_install.sh || true"
  elif command -v wget >/dev/null 2>&1; then
    run_user "wget -qO /tmp/ohmyzsh_install.sh https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
    run_user "env KEEP_ZSHRC=yes CHSH=no RUNZSH=no sh /tmp/ohmyzsh_install.sh || true"
    run_user "rm -f /tmp/ohmyzsh_install.sh || true"
  else
    log "Cannot install oh-my-zsh: git/curl/wget unavailable"
    return 1
  fi
}

# 安装 oh-my-zsh 插件依赖。
# 何时执行：minimal 阶段，插件 clone 前。
# 幂等性：包管理器或 pip 会自行处理已安装情况。
# 失败策略：pygments 只是部分插件增强依赖，失败不阻断主流程。
install_oh_my_zsh_plugin_deps() {
  if [ "$PKG_MANAGER" = "apt" ] && [ "$DISTRO" = "ubuntu" ]; then
    ensure_packages python3-pygments || log "python3-pygments install failed; continuing"
    return 0
  fi

  if command -v pip3 >/dev/null 2>&1; then
    run_user "pip3 install --user pygments || true"
  else
    log "pip3 unavailable; skipping pygments"
  fi
}

# 安装常用 oh-my-zsh 插件。
# 何时执行：minimal 阶段。
# 幂等性：插件目录存在则跳过。
# 失败策略：单个插件 clone 失败会记录日志并继续。
install_oh_my_zsh_plugins() {
  local custom_dir="$TARGET_HOME/.oh-my-zsh/custom/plugins"
  local spec name url
  local plugins=(
    "zsh-autosuggestions|https://github.com/zsh-users/zsh-autosuggestions"
    "zsh-syntax-highlighting|https://github.com/zsh-users/zsh-syntax-highlighting"
    "zsh-history-substring-search|https://github.com/zsh-users/zsh-history-substring-search"
    "conda-zsh-completion|https://github.com/conda-incubator/conda-zsh-completion"
  )

  if [ "$DRY_RUN" = false ]; then
    run_user "mkdir -p '$custom_dir'"
  fi

  for spec in "${plugins[@]}"; do
    name="${spec%%|*}"
    url="${spec#*|}"
    if [ -d "$custom_dir/$name" ]; then
      log "oh-my-zsh plugin already installed: $name"
    else
      run_user "git clone '$url' '$custom_dir/$name'" || log "Plugin install failed: $name"
    fi
  done
}

# 同步远程 myconfig 仓库。
# 何时执行：minimal 阶段，复制 dotfiles 前。
# 幂等性：已有 git 仓库时执行 pull --rebase；不存在时 clone。
# 失败策略：clone 失败会中断 dotfiles 阶段，因为后续源文件依赖该仓库。
clone_or_update_myconfig_repo() {
  if [ -d "$DEST_DIR/.git" ]; then
    run_user "git -C '$DEST_DIR' pull --rebase || true"
  else
    run_user "git clone '$REPO_URL' '$DEST_DIR'"
  fi
}

install_dotfile() {
  local src="$1"
  local dst="$2"

  if [ -f "$src" ]; then
    run_user "cp -f '$src' '$dst'"
  else
    log "Dotfile source not found; skipping: $src"
  fi
}

# 配置 zsh/vim/tmux。
# 何时执行：minimal 阶段，myconfig 同步后。
# 幂等性：dotfiles 覆盖复制；Vundle/tpm 目录存在则跳过。
# 失败策略：vim 插件安装可能在无交互环境失败，失败时提示手动执行。
configure_shell_editor_tmux() {
  local vundle_dir="$TARGET_HOME/.vim/bundle/Vundle.vim"
  local tpm_dir="$TARGET_HOME/.tmux/plugins/tpm"
  local zsh_path

  if [ -f "$DEST_DIR/zshrc" ]; then
    install_dotfile "$DEST_DIR/zshrc" "$TARGET_HOME/.zshrc"
  elif [ -f "$DEST_DIR/.zshrc" ]; then
    install_dotfile "$DEST_DIR/.zshrc" "$TARGET_HOME/.zshrc"
  else
    log "No zshrc found in $DEST_DIR"
  fi

  if command -v zsh >/dev/null 2>&1; then
    zsh_path="$(command -v zsh)"
    if [ "$DRY_RUN" = true ]; then
      log "DRY-RUN: would set shell $zsh_path for user $TARGET_USER"
    elif run_root "chsh -s '$zsh_path' '$TARGET_USER' >/dev/null 2>&1"; then
      log "Default shell changed for $TARGET_USER to $zsh_path"
    else
      log "chsh failed; run manually if needed: chsh -s $zsh_path $TARGET_USER"
    fi
  fi

  if [ -f "$DEST_DIR/.vimrc" ]; then
    install_dotfile "$DEST_DIR/.vimrc" "$TARGET_HOME/.vimrc"
  elif [ -f "$DEST_DIR/vimrc" ]; then
    install_dotfile "$DEST_DIR/vimrc" "$TARGET_HOME/.vimrc"
  else
    log "No vimrc found in $DEST_DIR"
  fi

  if [ ! -d "$vundle_dir" ]; then
    run_user "git clone https://github.com/VundleVim/Vundle.vim.git '$vundle_dir'"
  else
    log "Vundle already installed"
  fi

  if [ -d "$DEST_DIR/ftdetect" ]; then
    run_user "cp -Rf '$DEST_DIR/ftdetect' '$TARGET_HOME/.vim/'"
  else
    log "No vim ftdetect directory found in $DEST_DIR"
  fi

  if command -v vim >/dev/null 2>&1; then
    if [ "$DRY_RUN" = true ]; then
      log "DRY-RUN: would run vim +PluginInstall +qall as $TARGET_USER"
    else
      run_user "vim +PluginInstall +qall" || log "vim PluginInstall failed; run manually as $TARGET_USER"
    fi
  fi

  if [ -f "$DEST_DIR/.tmux.conf" ]; then
    install_dotfile "$DEST_DIR/.tmux.conf" "$TARGET_HOME/.tmux.conf"
  elif [ -f "$DEST_DIR/tmux.conf" ]; then
    install_dotfile "$DEST_DIR/tmux.conf" "$TARGET_HOME/.tmux.conf"
  else
    log "No tmux.conf found in $DEST_DIR"
  fi

  if [ ! -d "$tpm_dir" ]; then
    run_user "git clone https://github.com/tmux-plugins/tpm '$tpm_dir'"
  else
    log "tpm already installed"
  fi
}

# 启用并启动 systemd 服务。
# 何时执行：Docker/Open vSwitch 安装后。
# 幂等性：已 enabled/active 时跳过。
# 失败策略：systemd 在容器内常不可用，因此失败会降级为日志。
ensure_service_enabled() {
  local svc="${1%.service}"

  if [ -z "$svc" ]; then
    return 1
  fi

  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: would enable and start ${svc}.service"
    return 0
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl unavailable; skipping service enable: $svc"
    return 0
  fi

  if ! systemctl is-enabled "${svc}.service" >/dev/null 2>&1; then
    run_root "systemctl enable --now ${svc}.service || true"
    return 0
  fi

  if systemctl is-active "${svc}.service" >/dev/null 2>&1; then
    log "Service already enabled and running: $svc"
    return 0
  fi

  run_root "systemctl start ${svc}.service || true"
}

configure_docker_group() {
  if [ "$TARGET_USER" = "root" ]; then
    log "Root user does not need docker group membership; skipping"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    run_root "getent group docker >/dev/null 2>&1 || groupadd docker" || return 1
    run_root "id -nG '$TARGET_USER' 2>/dev/null | tr ' ' '\n' | grep -qx docker || usermod -aG docker '$TARGET_USER'"
    return 0
  fi

  if ! getent group docker >/dev/null 2>&1; then
    run_root "groupadd docker" || return 1
  else
    log "Docker group already exists"
  fi

  if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log "User $TARGET_USER is already in docker group"
    return 0
  fi

  run_root "usermod -aG docker '$TARGET_USER'"
}

# 安装 Miniconda。
# 何时执行：advanced 且 INSTALL_CONDA=true。
# 幂等性：检测 conda 命令或目标目录下 conda。
# 失败策略：下载或安装失败会返回错误，advanced 调用处会记录并继续其他组件。
install_miniconda() {
  local miniconda_dir="$TARGET_HOME/miniconda3"
  local miniconda_url="${MINICONDA_URL:-https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh}"
  local installer

  if command -v conda >/dev/null 2>&1 || [ -x "$miniconda_dir/bin/conda" ]; then
    log "Miniconda already installed"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: would install Miniconda to $miniconda_dir from $miniconda_url"
    return 0
  fi

  installer="$(mktemp /tmp/miniconda-installer.XXXXXX.sh)"
  if command -v curl >/dev/null 2>&1; then
    run_user "curl -fL -o '$installer' '$miniconda_url'" || return 1
  elif command -v wget >/dev/null 2>&1; then
    run_user "wget --show-progress -O '$installer' '$miniconda_url'" || return 1
  else
    log "Cannot download Miniconda: curl/wget unavailable"
    return 1
  fi

  run_user "chmod +x '$installer'" || return 1
  run_user "bash '$installer' -b -p '$miniconda_dir'" || return 1
  run_user "rm -f '$installer' || true"

  if [ -x "$miniconda_dir/bin/conda" ]; then
    run_user "'$miniconda_dir/bin/conda' config --set auto_activate false" || return 1
    run_user "'$miniconda_dir/bin/conda' init zsh || true"
  else
    log "Miniconda install completed but conda binary was not found"
    return 1
  fi
}

# 安装 Docker。
# 何时执行：advanced 且 INSTALL_DOCKER=true。
# 幂等性：docker 命令存在则跳过安装，只尝试启用服务。
# 失败策略：不同发行版仓库差异较大，安装失败会记录日志并继续。
# 副作用：RHEL/Fedora 会添加 Docker 官方仓库。
install_docker() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
    ensure_service_enabled docker
    configure_docker_group || log "Docker group configuration failed"
    return 0
  fi

  case "$PKG_MANAGER" in
    apt)
      ensure_packages ca-certificates curl gnupg || true
      run_root "install -m 0755 -d /etc/apt/keyrings"
      run_root "curl -fsSL https://download.docker.com/linux/$DISTRO/gpg -o /etc/apt/keyrings/docker.asc || true"
      run_root "chmod a+r /etc/apt/keyrings/docker.asc || true"
      run_root "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$DISTRO \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list || true"
      ensure_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || log "Docker package install failed"
      ;;
    dnf|yum)
      ensure_packages dnf-plugins-core yum-utils || true
      if [ "$DISTRO" = "fedora" ]; then
        run_root "dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo || true"
      else
        run_root "$PKG_MANAGER config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true"
      fi
      ensure_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || log "Docker package install failed"
      ;;
    zypper)
      ensure_packages docker || log "Docker package install failed"
      ;;
    pacman)
      ensure_packages docker docker-compose || log "Docker package install failed"
      ;;
    *)
      log "Docker install unsupported for package manager: $PKG_MANAGER"
      return 1
      ;;
  esac

  ensure_service_enabled docker
  configure_docker_group || log "Docker group configuration failed"
}

# 安装 kubectl。
# 何时执行：advanced 且 INSTALL_KUBECTL=true。
# 幂等性：kubectl 命令存在则跳过。
# 失败策略：官方二进制下载失败时记录并继续。
install_kubectl() {
  local kubectl_ver

  if command -v kubectl >/dev/null 2>&1; then
    log "kubectl already installed"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: would download kubectl to /usr/local/bin/kubectl"
    return 0
  fi

  kubectl_ver="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  if [ -z "$kubectl_ver" ]; then
    log "Failed to resolve latest kubectl version"
    return 1
  fi

  if [ ! -d /usr/local/bin ]; then
    log "/usr/local/bin does not exist; skipping kubectl direct binary install"
    return 1
  fi
  run_root "curl -fL -o /usr/local/bin/kubectl https://dl.k8s.io/release/${kubectl_ver}/bin/linux/amd64/kubectl" || return 1
  run_root "chmod 0755 /usr/local/bin/kubectl" || return 1
}

# 安装 kind。
# 何时执行：advanced 且 INSTALL_KIND=true。
# 幂等性：kind 命令存在则跳过。
# 失败策略：优先 go install；没有 go 时下载最新 release 二进制。
install_kind() {
  local kind_ver

  if command -v kind >/dev/null 2>&1; then
    log "kind already installed"
    return 0
  fi

  if [ "$DRY_RUN" = true ]; then
    log "DRY-RUN: would install kind"
    return 0
  fi

  if command -v go >/dev/null 2>&1; then
    run_user "go install sigs.k8s.io/kind@latest" || return 1
    if id -u "$TARGET_USER" >/dev/null 2>&1; then
      run_user "grep -qxF 'export PATH=\$PATH:\$HOME/go/bin' '$TARGET_HOME/.zshrc' || sed -i -E '/^[[:space:]]*source[[:space:]]+\$ZSH\/oh-my-zsh\.sh[[:space:]]*$/i export PATH=\$PATH:\$HOME/go/bin' '$TARGET_HOME/.zshrc'"
    fi
  else
    kind_ver="$(curl -L -s https://api.github.com/repos/kubernetes-sigs/kind/releases/latest | grep '\"tag_name\":' | sed -E 's/.*\"([^\"]+)\".*/\1/')"
    if [ -z "$kind_ver" ]; then
      log "Failed to resolve latest kind version"
      return 1
    fi
    if [ ! -d /usr/local/bin ]; then
      log "/usr/local/bin does not exist; skipping kind direct binary install"
      return 1
    fi
    run_root "curl -fL -o /usr/local/bin/kind https://kind.sigs.k8s.io/dl/${kind_ver}/kind-linux-amd64" || return 1
    run_root "chmod +x /usr/local/bin/kind" || return 1
  fi
}

# 安装 Open vSwitch。
# 何时执行：advanced 且 INSTALL_OVS=true。
# 幂等性：ovs-vsctl 存在则跳过安装，只尝试启用服务。
# 失败策略：包名依赖发行版仓库，安装失败会记录并继续。
install_openvswitch() {
  local pkgname

  if command -v ovs-vsctl >/dev/null 2>&1; then
    log "Open vSwitch already installed"
    ensure_service_enabled openvswitch
    return 0
  fi

  ensure_openvswitch_repos
  pkgname="$(pkg_name openvswitch)"
  ensure_packages "$pkgname" || log "Open vSwitch package may be unavailable: $pkgname"
  ensure_service_enabled openvswitch
}

run_minimal_profile() {
  run_stage "Detect distro and package manager" detect_distro_and_pkgmgr
  run_stage "Ensure RHEL repositories if needed" ensure_rhel_repos
  run_stage "Disable SELinux if present" ensure_selinux_disabled
  run_stage "Install basic tools" install_basic_tools
  run_stage "Install oh-my-zsh" install_oh_my_zsh
  run_stage "Install oh-my-zsh plugin deps" install_oh_my_zsh_plugin_deps
  run_stage "Install oh-my-zsh plugins" install_oh_my_zsh_plugins
  run_stage "Clone or update myconfig repo" clone_or_update_myconfig_repo
  run_stage "Configure shell editor and tmux" configure_shell_editor_tmux
}

run_advanced_profile() {
  run_stage "Install development tools" install_dev_tools
  if [ "$INSTALL_CONDA" = true ]; then
    run_stage "Install Miniconda" install_miniconda || log "Miniconda stage failed; continuing"
  fi
  if [ "$INSTALL_DOCKER" = true ]; then
    run_stage "Install Docker" install_docker || log "Docker stage failed; continuing"
  fi
  if [ "$INSTALL_KUBECTL" = true ]; then
    run_stage "Install kubectl" install_kubectl || log "kubectl stage failed; continuing"
  fi
  if [ "$INSTALL_KIND" = true ]; then
    run_stage "Install kind" install_kind || log "kind stage failed; continuing"
  fi
  if [ "$INSTALL_OVS" = true ]; then
    run_stage "Install Open vSwitch" install_openvswitch || log "Open vSwitch stage failed; continuing"
  fi
}

print_summary() {
  cat <<EOF
Done. Summary:
- Profile: $PROFILE
- Config file: $CONFIG_FILE
- Config loaded: $CONFIG_WAS_LOADED
- Repo: $DEST_DIR
- Dotfiles copied if present: .zshrc, .vimrc, .vim/ftdetect, .tmux.conf
- Advanced components: conda=$INSTALL_CONDA docker=$INSTALL_DOCKER kubectl=$INSTALL_KUBECTL kind=$INSTALL_KIND ovs=$INSTALL_OVS
- Dry run: $DRY_RUN
- Log file: $LOGFILE

Next manual steps:
- Start tmux and press prefix+I to install tmux plugins, or run:
  $TARGET_HOME/.tmux/plugins/tpm/bin/install_plugins
- If vim plugins were not installed in the headless run, execute:
  vim +PluginInstall +qall
- Reboot once after bootstrap so shell changes and Docker group membership take effect.
EOF
}

main() {
  load_config
  validate_config
  run_minimal_profile

  if [ "$PROFILE" = "advanced" ]; then
    run_advanced_profile
  fi

  log "Bootstrap finished"
  print_summary
}

main "$@"
