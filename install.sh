#!/bin/zsh
# Installer per polito-hpc-swiftbar. Idempotente, lancialo quante volte vuoi.
# Fa: brew + deps, sudoers ristretto, symlink dei plugin nella cartella SwiftBar.
set -e

REPO_DIR="${0:A:h}"   # cartella dove sta install.sh
VPN_HOST_DEFAULT="vpn.polito.it:443"
SUDOERS_FILE="/etc/sudoers.d/polito-hpc-swiftbar"

# Colori solo se siamo in un TTY
if [[ -t 1 ]]; then
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BOLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_OFF=""
fi
ok()   { echo "${C_GREEN}ok${C_OFF}   $*"; }
warn() { echo "${C_YELLOW}warn${C_OFF} $*"; }
err()  { echo "${C_RED}err${C_OFF}  $*" >&2; }
info() { echo "${C_BOLD}>${C_OFF}    $*"; }
ask()  { local p="$1" d="$2" r=""; read -r "r?$p [$d]: "; echo "${r:-$d}"; }

[[ "$(uname)" == "Darwin" ]] || { err "macOS only."; exit 1; }
echo "${C_BOLD}polito-hpc-swiftbar installer${C_OFF}"
echo "Repo: $REPO_DIR"
echo

# Homebrew
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew presente: $(brew --version | head -1)"
else
  warn "Homebrew non installato."
  reply=$(ask "Lo installo ora? (richiede password sudo)" "y")
  if [[ "$reply" =~ ^[Yy] ]]; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Aggiungi brew al PATH (Apple Silicon)
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  else
    err "Homebrew necessario. Abort."; exit 1
  fi
fi

# Pacchetti
for pkg in openfortivpn tmux; do
  if brew list "$pkg" >/dev/null 2>&1; then
    ok "$pkg già installato"
  else
    info "brew install $pkg"
    brew install "$pkg"
  fi
done

if [[ ! -d "/Applications/SwiftBar.app" ]]; then
  reply=$(ask "SwiftBar.app non trovato. Lo installo?" "y")
  if [[ "$reply" =~ ^[Yy] ]]; then
    brew install --cask swiftbar
  else
    warn "Senza SwiftBar i plugin non girano."
  fi
else
  ok "SwiftBar.app già presente"
fi

# Sudoers ristretto — niente NOPASSWD: ALL.
OFV_PATH="$(command -v openfortivpn || echo /opt/homebrew/bin/openfortivpn)"
PKILL_PATH="/usr/bin/pkill"
USER_NAME="$(whoami)"

vpn_host=$(ask "Hostname VPN (host:port)" "$VPN_HOST_DEFAULT")

SUDOERS_CONTENT="# /etc/sudoers.d/polito-hpc-swiftbar
# Generato da install.sh il $(date '+%Y-%m-%d %H:%M:%S')
# Permessi NOPASSWD ristretti per PoliTO_VPN.5s.sh.

$USER_NAME ALL=(root) NOPASSWD: $OFV_PATH $vpn_host --saml-login
$USER_NAME ALL=(root) NOPASSWD: $PKILL_PATH -x openfortivpn
$USER_NAME ALL=(root) NOPASSWD: $PKILL_PATH -x pppd
$USER_NAME ALL=(root) NOPASSWD: $PKILL_PATH -9 -x openfortivpn
$USER_NAME ALL=(root) NOPASSWD: $PKILL_PATH -9 -x pppd
"

TMP_SUDO=$(mktemp)
echo "$SUDOERS_CONTENT" > "$TMP_SUDO"

if ! /usr/sbin/visudo -cf "$TMP_SUDO" >/dev/null 2>&1; then
  err "Sudoers ha errori di sintassi:"
  /usr/sbin/visudo -cf "$TMP_SUDO"
  /bin/rm -f "$TMP_SUDO"
  exit 1
fi
ok "Sudoers validato"

info "Installo $SUDOERS_FILE (chiede la password sudo)"
sudo -v
sudo /bin/cp "$TMP_SUDO" "$SUDOERS_FILE"
sudo /bin/chmod 0440 "$SUDOERS_FILE"
sudo /usr/sbin/chown root:wheel "$SUDOERS_FILE"
/bin/rm -f "$TMP_SUDO"
ok "Sudoers installato"

if sudo -n "$OFV_PATH" --version >/dev/null 2>&1; then
  ok "sudo openfortivpn passa senza password"
else
  warn "Sudo test fallito. Controlla con: sudo -n openfortivpn --version"
fi

# Plugin folder
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
[[ -z "$PLUGIN_DIR" ]] && PLUGIN_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
PLUGIN_DIR="${PLUGIN_DIR/#\~/$HOME}"

reply=$(ask "Plugin folder SwiftBar" "$PLUGIN_DIR")
PLUGIN_DIR="${reply/#\~/$HOME}"

if [[ ! -d "$PLUGIN_DIR" ]]; then
  reply=$(ask "Non esiste. La creo?" "y")
  if [[ "$reply" =~ ^[Yy] ]]; then
    /bin/mkdir -p "$PLUGIN_DIR"
  else
    err "Serve la plugin folder. Abort."; exit 1
  fi
fi

for plugin in HPC_Monitor.10s.sh PoliTO_VPN.5s.sh; do
  src="$REPO_DIR/$plugin"
  dst="$PLUGIN_DIR/$plugin"
  if [[ ! -f "$src" ]]; then
    err "$src non esiste"; continue
  fi
  if [[ -L "$dst" || -f "$dst" ]]; then
    if [[ -L "$dst" && "$(readlink "$dst")" == "$src" ]]; then
      ok "$plugin già linkato"
    else
      warn "$dst esiste — sovrascrivo"
      /bin/rm -f "$dst"
      /bin/ln -s "$src" "$dst"
      ok "$plugin → linkato"
    fi
  else
    /bin/ln -s "$src" "$dst"
    ok "$plugin → linkato"
  fi
  /bin/chmod +x "$src"
done

current_pdir=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [[ "$current_pdir" != "$PLUGIN_DIR" ]]; then
  reply=$(ask "Setto SwiftBar PluginDirectory a $PLUGIN_DIR?" "y")
  if [[ "$reply" =~ ^[Yy] ]]; then
    defaults write com.ameba.SwiftBar PluginDirectory "$PLUGIN_DIR"
    ok "SwiftBar PluginDirectory aggiornato"
  fi
fi

echo
ok "${C_BOLD}Fatto.${C_OFF}"
echo
echo "Cose da controllare prima di usare:"
echo "  - ssh hpc-polito whoami     (se non risponde, fixa ~/.ssh/config)"
echo "  - open -a SwiftBar          (poi menu > Refresh All)"
echo
echo "Per disinstallare il sudoers: sudo rm $SUDOERS_FILE"
