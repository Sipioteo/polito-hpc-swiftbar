#!/bin/zsh
#
# Copyright (C) 2026 Matteo Sipione
# Licensed under GPLv3 — see LICENSE in the project root or
# https://www.gnu.org/licenses/gpl-3.0.html
# Distributed WITHOUT ANY WARRANTY.
#
# <xbar.title>PoliTO VPN</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Matteo Sipione</xbar.author>
# <xbar.author.github>sipioteo</xbar.author.github>
# <xbar.desc>Controllo VPN PoliTO via openfortivpn + SAML login. Gestisce connect/disconnect, mostra stato e uptime. Si autoesclude quando connesso (lascia spazio al plugin HPC_Monitor). Refresha SwiftBar automaticamente ai cambi di stato. Richiede openfortivpn installato (brew install openfortivpn) e una entry NOPASSWD in sudoers (vedi README).</xbar.desc>
# <xbar.dependencies>zsh,openfortivpn,tmux</xbar.dependencies>
# <xbar.abouturl>https://github.com/Sipioteo/polito-hpc-swiftbar</xbar.abouturl>
#
# <xbar.var>string(VAR_VPN_HOST="vpn.polito.it:443">Hostname/porta gateway VPN</xbar.var>
# <xbar.var>string(VAR_TMUX_SESSION="polito-vpn"): Nome sessione tmux dove gira openfortivpn</xbar.var>
# <xbar.var>string(VAR_OFV_PATH="/opt/homebrew/bin/openfortivpn"): Path eseguibile openfortivpn</xbar.var>
# <xbar.var>string(VAR_TMUX_PATH="/opt/homebrew/bin/tmux"): Path eseguibile tmux</xbar.var>
# <xbar.var>string(VAR_LOG_FILE="/tmp/openfortivpn.log"): File di log openfortivpn</xbar.var>
#
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

PLUGIN_PATH="${0:A}"
OFV="${VAR_OFV_PATH:-/opt/homebrew/bin/openfortivpn}"
TMUX="${VAR_TMUX_PATH:-/opt/homebrew/bin/tmux}"
TMUX_SESSION="${VAR_TMUX_SESSION:-polito-vpn}"
VPN_HOST="${VAR_VPN_HOST:-vpn.polito.it:443}"
LOG_FILE="${VAR_LOG_FILE:-/tmp/openfortivpn.log}"

# ── Action handlers ───────────────────────────────────────────────────────────
if [[ "$1" == "connect" ]]; then
    : > "$LOG_FILE"
    # openfortivpn --saml-login richiede un tty controllante per fare il
    # flusso SAML correttamente con vpn.polito.it. SwiftBar non lo fornisce,
    # quindi lo lanciamo dentro una sessione tmux detached (headless ma con pty).
    "$TMUX" kill-session -t "$TMUX_SESSION" 2>/dev/null
    "$TMUX" new-session -d -s "$TMUX_SESSION" \
        "sudo -n $OFV $VPN_HOST --saml-login 2>&1 | tee $LOG_FILE"
    # Attende che openfortivpn stampi la URL di autenticazione e la apre nel browser.
    # openfortivpn stampa: INFO: Authenticate at 'https://...?redirect=1'
    # NB: niente apici singoli nella classe URL, sono i delimitatori del log.
    URL=""
    for i in {1..50}; do
        URL=$(grep -aoE "https?://[A-Za-z0-9._~:/?#@!\$&()*+,;=%-]+" "$LOG_FILE" 2>/dev/null | head -1)
        [[ -n "$URL" ]] && break
        sleep 0.2
    done
    # Aspetta che (a) il listener su 127.0.0.1:8020 accetti TCP e (b) openfortivpn
    # abbia completato la registrazione col gateway polito. Senza (b) il browser
    # arriva prima e polito redirige al portale invece che al callback.
    if [[ -n "$URL" ]]; then
        # (a) listener TCP up
        for i in {1..50}; do
            /usr/bin/nc -z 127.0.0.1 8020 2>/dev/null && break
            sleep 0.1
        done
        # (b) openfortivpn risponde HTTP (handler pronto, non solo bind)
        for i in {1..50}; do
            if /usr/bin/curl -s -o /dev/null -m 1 http://127.0.0.1:8020/; then
                break
            fi
            sleep 0.1
        done
        # (c) grace period per la registrazione lato gateway polito
        sleep 1.5
        /usr/bin/open "$URL"
    fi
    # Watcher in background: forza il refresh di SwiftBar in due momenti utili:
    #  1) quando appare l'interfaccia ppp → VPN sparisce, HPC mostra "in connessione"
    #  2) quando il cluster risponde via SSH → HPC mostra la dashboard piena
    # Senza questo doppio refresh la barra resta in hourglass per 10s (tick HPC).
    (
        PPP_SEEN=0
        for i in {1..180}; do
            /usr/bin/pgrep -x openfortivpn >/dev/null 2>&1 || exit 0
            if [[ $PPP_SEEN -eq 0 ]]; then
                if /sbin/ifconfig 2>/dev/null | /usr/bin/awk '/^ppp[0-9]/{f=1} END{exit !f}'; then
                    PPP_SEEN=1
                    /usr/bin/open -g "swiftbar://refreshallplugins"
                fi
            else
                if /usr/bin/ssh -q -o ConnectTimeout=2 -o BatchMode=yes hpc-polito true 2>/dev/null; then
                    /usr/bin/open -g "swiftbar://refreshallplugins"
                    exit 0
                fi
            fi
            sleep 1
        done
    ) >/dev/null 2>&1 &
    disown
    exit 0
fi

if [[ "$1" == "disconnect" ]]; then
    sudo /usr/bin/pkill -x openfortivpn 2>/dev/null
    sudo /usr/bin/pkill -x pppd 2>/dev/null
    "$TMUX" kill-session -t "$TMUX_SESSION" 2>/dev/null
    # Aspetta che openfortivpn muoia davvero prima di rinfrescare: altrimenti
    # HPC fa pgrep, lo trova ancora vivo e resta in barra fino al tick successivo.
    for i in {1..20}; do
        /usr/bin/pgrep -x openfortivpn >/dev/null 2>&1 || break
        sleep 0.1
    done
    # Forza l'uccisione se TERM non è bastato
    sudo /usr/bin/pkill -9 -x openfortivpn 2>/dev/null
    sudo /usr/bin/pkill -9 -x pppd 2>/dev/null
    /usr/bin/open -g "swiftbar://refreshallplugins"
    exit 0
fi

# ── Detect state ──────────────────────────────────────────────────────────────
VPN_PID=$(pgrep -x openfortivpn 2>/dev/null | head -1)
PPP_IF=$(ifconfig 2>/dev/null | awk '/^ppp[0-9]/{sub(/:$/,"",$1); print $1; exit}')

if [[ -z "$VPN_PID" ]]; then
    STATE="disconnected"
elif [[ -n "$PPP_IF" ]]; then
    STATE="connected"
else
    STATE="connecting"
fi

# ── First-run / dependency check ──────────────────────────────────────────────
# Verifica tutto ciò che serve per funzionare. In caso di problemi mostra menu
# guidato con link a install.sh.
DEPS_OK=1
MISSING_DEPS=()
[[ ! -x "$OFV" ]]   && { DEPS_OK=0; MISSING_DEPS+=("openfortivpn"); }
[[ ! -x "$TMUX" ]]  && { DEPS_OK=0; MISSING_DEPS+=("tmux"); }

SUDO_OK=0
[[ $DEPS_OK -eq 1 ]] && sudo -n "$OFV" --version > /dev/null 2>&1 && SUDO_OK=1

# Path dello script di install (cartella sopra al symlink, se la struttura standard)
INSTALL_SH="${PLUGIN_PATH:h}/install.sh"
[[ ! -f "$INSTALL_SH" ]] && INSTALL_SH="$HOME/Developer/polito-hpc-swiftbar/install.sh"

# ── Uptime ────────────────────────────────────────────────────────────────────
UPTIME_STR=""
if [[ "$STATE" == "connected" && -n "$VPN_PID" ]]; then
    ETIME=$(ps -p "$VPN_PID" -o etime= 2>/dev/null | tr -d ' ')
    if [[ -n "$ETIME" ]]; then
        days=0; hrs=0; mins=0
        if [[ "$ETIME" == *-* ]]; then
            days="${ETIME%%-*}"; rest="${ETIME#*-}"
        else
            rest="$ETIME"
        fi
        IFS=":" read -r p1 p2 p3 <<< "$rest"
        if [[ -n "$p3" ]]; then hrs="$p1"; mins="$p2"
        else mins="$p1"; fi
        [[ $days -gt 0 ]] && UPTIME_STR="${days}g "
        [[ $hrs -gt 0 ]]  && UPTIME_STR+="${hrs}h "
        UPTIME_STR+="${mins}m"
    fi
fi

# Quando la VPN è connessa, il plugin HPC prende il suo posto: usciamo silenziosi
# così SwiftBar nasconde l'item VPN.
if [[ "$STATE" == "connected" ]]; then
    exit 0
fi

# ── Menu bar title ────────────────────────────────────────────────────────────
case "$STATE" in
    connecting)   echo "VPN | sfimage=lock.rotation" ;;
    disconnected) echo "VPN | sfimage=lock.open.fill" ;;
esac
echo "---"

# ── Header ────────────────────────────────────────────────────────────────────
echo "PoliTO VPN | sfimage=building.columns.fill"
echo "Aggiorna | refresh=true sfimage=arrow.clockwise"
echo "---"

# ── State-specific menu ───────────────────────────────────────────────────────
case "$STATE" in
  connected)
    echo "Connesso a $VPN_HOST | sfimage=checkmark.shield.fill"
    [[ -n "$UPTIME_STR" ]] && echo "Attivo da: $UPTIME_STR | sfimage=clock"
    [[ -n "$PPP_IF" ]]     && echo "Interfaccia: $PPP_IF | sfimage=network font=Menlo"
    echo "---"
    echo "Disconnetti | shell=$PLUGIN_PATH param1=disconnect terminal=false refresh=true sfimage=lock.open.fill"
    echo "-- Mostra log | shell=/usr/bin/open param1=$LOG_FILE terminal=false sfimage=doc.text"
    ;;
  connecting)
    echo "Autenticazione SAML in corso... | sfimage=lock.rotation"
    echo "Il browser si aprirà per il login PoliTO"
    echo "PID: $VPN_PID | font=Menlo"
    echo "---"
    echo "Annulla | shell=$PLUGIN_PATH param1=disconnect terminal=false refresh=true sfimage=xmark.circle"
    echo "-- Mostra log | shell=/usr/bin/open param1=$LOG_FILE terminal=false sfimage=doc.text"
    ;;
  disconnected)
    echo "Disconnesso | sfimage=xmark.shield"
    echo "---"
    if [[ $DEPS_OK -eq 0 ]]; then
      missing_str="${(j:, :)MISSING_DEPS}"
      echo "Dipendenze mancanti: $missing_str | sfimage=exclamationmark.triangle.fill sfcolor=#FF3B30,#FF453A color=#FF3B30,#FF453A"
      if [[ -f "$INSTALL_SH" ]]; then
        echo "Esegui installer (apre terminale) | terminal=true shell=zsh param1=$INSTALL_SH sfimage=wrench.and.screwdriver.fill sfcolor=#007AFF,#0A84FF"
      else
        echo "Apri repo per istruzioni | href=https://github.com/Sipioteo/polito-hpc-swiftbar sfimage=book.fill"
      fi
      echo "---"
    elif [[ $SUDO_OK -eq 0 ]]; then
      echo "sudo NOPASSWD non configurato | sfimage=exclamationmark.triangle.fill sfcolor=#FF9500,#FF9F0A color=#FF9500,#FF9F0A"
      echo "-- Senza, ogni connect chiederebbe la password | font=Menlo color=#3C3C43,#EBEBF5"
      if [[ -f "$INSTALL_SH" ]]; then
        echo "Configura sudoers (esegue install.sh) | terminal=true shell=zsh param1=$INSTALL_SH sfimage=wrench.and.screwdriver.fill sfcolor=#007AFF,#0A84FF"
      fi
      echo "-- O manualmente: vedi README | href=https://github.com/Sipioteo/polito-hpc-swiftbar#sudoers-richiesto-per-la-vpn sfimage=book.fill"
      echo "---"
      echo "Connetti VPN PoliTO (chiederà password) | shell=$PLUGIN_PATH param1=connect terminal=false refresh=true sfimage=lock.fill"
    else
      echo "Connetti VPN PoliTO | shell=$PLUGIN_PATH param1=connect terminal=false refresh=true sfimage=lock.fill"
    fi
    ;;
esac

# ── Log tail ──────────────────────────────────────────────────────────────────
echo "---"
echo "Log VPN | sfimage=doc.plaintext"
if [[ -f "$LOG_FILE" ]]; then
    tail -5 "$LOG_FILE" 2>/dev/null | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "-- $line | font=Menlo size=10"
    done
else
    echo "-- (nessun log)"
fi
