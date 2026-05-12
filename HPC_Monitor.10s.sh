#!/bin/zsh
#
# Copyright (C) 2026 Matteo Sipione
# Licensed under GPLv3 — see LICENSE in the project root or
# https://www.gnu.org/licenses/gpl-3.0.html
# Distributed WITHOUT ANY WARRANTY.
#
# <xbar.title>HPC Legion Monitor</xbar.title>
# <xbar.version>v1.0</xbar.version>
# <xbar.author>Matteo Sipione</xbar.author>
# <xbar.author.github>sipioteo</xbar.author.github>
# <xbar.desc>Dashboard SwiftBar per il cluster Slurm "Legion" del Politecnico di Torino. Mostra nodi liberi per tier hardware (GPU H200/A100/A40/V100, CPU Skylake/Sapphire), job in esecuzione/coda dell'utente, stato per risorsa con sotto-code per partizione, fair-share, manutenzione, log dei job, e azione "Disconnetti VPN". Si autoesclude quando la VPN PoliTO non è attiva (vedi plugin compagno PoliTO_VPN.5s.sh).</xbar.desc>
# <xbar.dependencies>zsh,ssh,openfortivpn,tmux</xbar.dependencies>
# <xbar.abouturl>https://github.com/Sipioteo/polito-hpc-swiftbar</xbar.abouturl>
# <xbar.image>https://raw.githubusercontent.com/Sipioteo/polito-hpc-swiftbar/main/docs/icon-1024.png</xbar.image>
#
# <xbar.var>string(VAR_HOST="hpc-polito"): SSH host/alias del cluster (definito in ~/.ssh/config)</xbar.var>
# <xbar.var>number(VAR_SSH_TIMEOUT=3): Timeout SSH in secondi</xbar.var>
# <xbar.var>string(VAR_VPN_PROCESS="openfortivpn"): Nome processo VPN da verificare (pgrep)</xbar.var>
# <xbar.var>number(VAR_HOME_QUOTA_GB=1536): Limite quota home in GB. Su Legion è 1.5 TB (1536 GB), gli admin non lo espongono via quota -s. BeeGFS scratch/legacy non hanno quota per-utente. Metti 0 per nascondere la riga.</xbar.var>
#
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>false</swiftbar.refreshOnOpen>

HOST="${VAR_HOST:-hpc-polito}"
SSH_TIMEOUT="${VAR_SSH_TIMEOUT:-3}"
VPN_PROCESS="${VAR_VPN_PROCESS:-openfortivpn}"
HOME_QUOTA_GB="${VAR_HOME_QUOTA_GB:-1536}"

# Palette colori SwiftBar — Apple systemColors light/dark per contrasto su Liquid Glass
# Usare come: color=$COL_LBL  (il prefisso color= appare in sorgente, il valore hex si espande)
COL_LBL="#1D1D1F,#F5F5F7"      # labelColor: testo primario (near-black/near-white)
COL_MUTED="#3C3C43,#EBEBF5"    # secondaryLabel: testo secondario
COL_FAINT="#8E8E93,#8E8E93"    # tertiaryLabel: gray neutrale
COL_OK="#34C759,#30D158"       # systemGreen
COL_WARN="#FF9500,#FF9F0A"     # systemOrange
COL_YEL="#FFCC00,#FFD60A"      # systemYellow
COL_BAD="#FF3B30,#FF453A"      # systemRed
COL_INFO="#007AFF,#0A84FF"     # systemBlue
COL_CYAN="#32ADE6,#64D2FF"     # systemCyan
COL_PURPLE="#AF52DE,#BF5AF2"   # systemPurple
COL_STAR="#FFCC00,#FFD60A"     # alias per ★ (= COL_YEL)

# Esci subito (silenzioso) se la VPN PoliTO non è attiva: niente openfortivpn ⇒
# il cluster è irraggiungibile e il plugin VPN deve prendere il posto in barra.
# Questo evita la finestra in cui SSH risponde ancora dopo un disconnect (la
# rotta ppp rimane su un attimo dopo il kill).
if ! /usr/bin/pgrep -x "$VPN_PROCESS" >/dev/null 2>&1; then
  exit 0
fi

# SSH ControlMaster: la prima connessione apre un socket, le successive lo
# riusano per ~5 minuti. Su un tick da 10s questo abbatte la latenza da ~10s
# (handshake completo ogni volta) a ~200ms (riuso TCP+SSH session). Riduce
# drasticamente il carico di nuove connessioni sul login node del cluster.
# Path corto obbligatorio: macOS limita socket UNIX a 104 byte di path totale
# (TMPDIR su mac è già ~49 caratteri, oltre il budget).
SSH_CM_DIR="/tmp/polito-hpc-cm-$UID"
/bin/mkdir -p "$SSH_CM_DIR" 2>/dev/null
chmod 700 "$SSH_CM_DIR" 2>/dev/null
SSH_OPTS=(
  -q
  -o BatchMode=yes
  -o ConnectTimeout=$SSH_TIMEOUT
  -o ControlMaster=auto
  -o "ControlPath=$SSH_CM_DIR/%r@%h:%p"
  -o ControlPersist=300
)

RAW=$(ssh "${SSH_OPTS[@]}" "$HOST" bash -s 2>/dev/null <<'REMOTE'
U=$(whoami)
echo "===RUNNING==="
squeue -u "$U" -t RUNNING -h -o "%i|%j|%P|%D|%M|%l|%R|%b" 2>/dev/null
echo "===PENDING==="
squeue -u "$U" -t PENDING -h -o "%i|%j|%P|%D|%r|%S|%b" 2>/dev/null
echo "===SINFO==="
sinfo -h -o "%P|%F" 2>/dev/null
echo "===SHARE==="
# sshare per partizione: ogni riga = partition|rawusage|effusage|fairshare
sshare -n -P -o "User,Account,Partition,RawUsage,EffectvUsage,FairShare" 2>/dev/null | awk -F'|' -v u="$U" '$1==u && $3!="" {gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3"|"$4"|"$5"|"$6}'
echo "===SACCT==="
# sacct dipende da slurmdbd: se il database è giù emette stderr e rc!=0.
# Catturiamo il rc per distinguere "0 job oggi" da "db non risponde".
sacct -u "$U" -X -S today -n -P -o "JobID,JobName,State,Elapsed,ExitCode" 2>/dev/null || echo "__SACCT_ERR__"
echo "===QUOTA==="
quota -s 2>/dev/null
echo "===DF==="
# Filesystem rilevanti per l'utente: home + tutte le mount BeeGFS/lustre/scratch.
# Escludiamo root, boot, tmpfs, overlayfs (rumore).
df -hP -t nfs4 -t nfs -t beegfs -t beegfs-7 -t lustre -t glusterfs -t cifs 2>/dev/null \
  | tail -n +2 \
  | awk '{print $1"|"$2"|"$3"|"$4"|"$5"|"$6}'
echo "===USERPATHS==="
# Per ogni mount conosciuta, candidati path personali. Tutto via [ -d ] + stat,
# istantaneo (no scandir ricorsivi). Output: mountpoint|path|mtime
for mp in /home /mnt/beegfs /mnt/beegfs-compat /scratch /work /global /lustre /data; do
  [ -d "$mp" ] || continue
  for sub in "" /users /scratch /work /home /projects; do
    p="$mp$sub/$U"
    if [ -d "$p" ]; then
      mt=$(stat -c '%y' "$p" 2>/dev/null | cut -d. -f1)
      echo "$mp|$p|$mt"
    fi
  done
done
echo "===RESV==="
scontrol show reservation -o 2>/dev/null | awk '
NF>0 {
  name=""; st=""; et=""; nodes=""; flags=""; users=""; state=""; feat=""
  for (i=1;i<=NF;i++) {
    p=index($i,"="); if (!p) continue
    k=substr($i,1,p-1); v=substr($i,p+1)
    if (k=="ReservationName") name=v
    else if (k=="StartTime") st=v
    else if (k=="EndTime") et=v
    else if (k=="Nodes") nodes=v
    else if (k=="Flags") flags=v
    else if (k=="Users") users=v
    else if (k=="State") state=v
    else if (k=="Features") feat=v
  }
  if (name != "") print name "|" state "|" st "|" et "|" nodes "|" flags "|" users
}'
echo "===NODES==="
scontrol -a show node -o 2>/dev/null | awk '
{
  name=""; state=""; gres=""; ctres=""; atres=""; cput=0; cpua=0; memt=0; mema=0; part=""
  for (i=1;i<=NF;i++) {
    p=index($i,"="); if (!p) continue
    k=substr($i,1,p-1); v=substr($i,p+1)
    if (k=="NodeName") name=v
    else if (k=="State") state=v
    else if (k=="Gres") gres=v
    else if (k=="CfgTRES") ctres=v
    else if (k=="AllocTRES") atres=v
    else if (k=="Partitions") part=v
  }
  # CPU totals from CfgTRES (cpu=N) and AllocTRES (cpu=N)
  if (match(ctres,/cpu=[0-9]+/)) cput=substr(ctres,RSTART+4,RLENGTH-4)+0
  if (match(atres,/cpu=[0-9]+/)) cpua=substr(atres,RSTART+4,RLENGTH-4)+0
  # Memory totals (in M) from CfgTRES (mem=NNNNM/G) and AllocTRES
  if (match(ctres,/mem=[0-9]+[MGT]?/)) {
    s=substr(ctres,RSTART+4,RLENGTH-4); u=substr(s,length(s),1)
    n=s+0
    if (u=="G") n*=1024; else if (u=="T") n*=1048576
    memt=n
  }
  if (match(atres,/mem=[0-9]+[MGT]?/)) {
    s=substr(atres,RSTART+4,RLENGTH-4); u=substr(s,length(s),1)
    n=s+0
    if (u=="G") n*=1024; else if (u=="T") n*=1048576
    mema=n
  }
  # GPU totals
  gtot=0
  if (gres != "" && gres != "(null)") {
    ng=split(gres,gg,",")
    for (j=1;j<=ng;j++) {
      if (gg[j] ~ /^gpu/) {
        sub(/\(.*\)/,"",gg[j])
        m=split(gg[j],pp,":")
        gtot += pp[m]+0
      }
    }
  }
  gused=0
  if (match(atres,/gres\/gpu=[0-9]+/)) gused=substr(atres,RSTART+9,RLENGTH-9)+0
  print name "|" state "|" part "|" cpua "|" cput "|" mema "|" memt "|" gused "|" gtot "|" gres
}'
echo "===SINFO_GPU==="
# Mappa nodo→tipo GPU da partizioni (nome partizione come proxy del tipo)
sinfo -h -o "%N|%G|%P" 2>/dev/null | grep -v "(null)"
echo "===JOBSALL==="
squeue -t R -h -a -o "%i|%u|%P|%N|%b|%M|%C|%m" 2>/dev/null | while IFS='|' read -r JID JU JP JN JG JT JC JM; do
  for n in $(scontrol show hostnames "$JN" 2>/dev/null); do
    echo "$JID|$JU|$JP|$n|$JG|$JT|$JC|$JM"
  done
done
echo "===PENDALL==="
# Tutti i pending del cluster, ordinati per priorità (decrescente)
squeue -t PD -h -a -S -p,i -o "%i|%u|%P|%D|%C|%b|%l|%r|%S|%Q|%V" 2>/dev/null
echo "===ME==="
echo "$U"
echo "===SPRIO==="
sprio -h -n -o "%i|%Y|%A|%F|%J|%P|%Q|%T|%U" 2>/dev/null
echo "===PRIOCFG==="
scontrol show config 2>/dev/null | awk '
/^PriorityType/ || /^PriorityWeight/ || /^PriorityDecayHalfLife/ || /^PriorityFavorSmall/ || /^FairShareDampeningFactor/ {
  gsub(/[ \t]+/," "); print
}'
echo "===STDLOGS==="
for j in $(squeue -u "$U" -t RUNNING -h -o "%i" 2>/dev/null); do
  scontrol show job "$j" 2>/dev/null | awk -v j="$j" '
    /StdOut=/ { match($0,/StdOut=[^ ]+/); o=substr($0,RSTART+7,RLENGTH-7) }
    /StdErr=/ { match($0,/StdErr=[^ ]+/); e=substr($0,RSTART+7,RLENGTH-7) }
    END { if (o!="") print j"|"o"|"e }'
done
echo "===END==="
REMOTE
)
SSH_RC=$?

if [ $SSH_RC -ne 0 ] || [ -z "$RAW" ]; then
  # openfortivpn gira ma SSH non risponde ancora → tunnel ppp in salita.
  # Mostriamo uno stato "in connessione" così la barra non resta vuota nei
  # secondi tra l'avvio della VPN e quando il cluster diventa raggiungibile.
  echo " | sfimage=hourglass color=#FFCC00,#FFD60A"
  echo "---"
  echo "Connessione al cluster in corso… | sfimage=network color=#8E8E93,#8E8E93"
  echo "Aggiorna ora | refresh=true sfimage=arrow.clockwise"
  exit 0
fi

# --- Parser: split per marker ---
RUN_LINES=()
PEND_LINES=()
SINFO_LINES=()
SHARE_LINES=()
SACCT_LINES=()
QUOTA_LINES=()
DF_LINES=()
USERPATHS_LINES=()
RESV_LINES=()
NODE_LINES=()
SINFOGPU_LINES=()
JOBALL_LINES=()
PENDALL_LINES=()
ME_LINES=()
SPRIO_LINES=()
PRIOCFG_LINES=()
STDLOGS_LINES=()
SECTION=""

while IFS= read -r line; do
  case "$line" in
    "===RUNNING===") SECTION="RUN"; continue ;;
    "===PENDING===") SECTION="PEND"; continue ;;
    "===SINFO===")   SECTION="SINFO"; continue ;;
    "===SHARE===")   SECTION="SHARE"; continue ;;
    "===SACCT===")   SECTION="SACCT"; continue ;;
    "===QUOTA===")   SECTION="QUOTA"; continue ;;
    "===DF===")      SECTION="DF"; continue ;;
    "===USERPATHS===") SECTION="USERPATHS"; continue ;;
    "===RESV===")    SECTION="RESV"; continue ;;
    "===NODES===")    SECTION="NODES"; continue ;;
    "===SINFO_GPU===") SECTION="SINFOGPU"; continue ;;
    "===JOBSALL===") SECTION="JOBSALL"; continue ;;
    "===PENDALL===") SECTION="PENDALL"; continue ;;
    "===ME===")      SECTION="ME"; continue ;;
    "===SPRIO===")   SECTION="SPRIO"; continue ;;
    "===PRIOCFG===") SECTION="PRIOCFG"; continue ;;
    "===STDLOGS===") SECTION="STDLOGS"; continue ;;
    "===END===")     SECTION=""; continue ;;
  esac
  [ -z "$line" ] && continue
  case "$SECTION" in
    RUN)   RUN_LINES+=("$line") ;;
    PEND)  PEND_LINES+=("$line") ;;
    SINFO) SINFO_LINES+=("$line") ;;
    SHARE) SHARE_LINES+=("$line") ;;
    SACCT) SACCT_LINES+=("$line") ;;
    QUOTA) QUOTA_LINES+=("$line") ;;
    DF)    DF_LINES+=("$line") ;;
    USERPATHS) USERPATHS_LINES+=("$line") ;;
    RESV)  RESV_LINES+=("$line") ;;
    NODES)    NODE_LINES+=("$line") ;;
    SINFOGPU) SINFOGPU_LINES+=("$line") ;;
    JOBSALL)  JOBALL_LINES+=("$line") ;;
    PENDALL) PENDALL_LINES+=("$line") ;;
    ME)      ME_LINES+=("$line") ;;
    SPRIO)   SPRIO_LINES+=("$line") ;;
    PRIOCFG) PRIOCFG_LINES+=("$line") ;;
    STDLOGS) STDLOGS_LINES+=("$line") ;;
  esac
done <<< "$RAW"

R=${#RUN_LINES[@]}
P=${#PEND_LINES[@]}

# --- Helper ---
trunc() {
  local s="$1" n="${2:-30}"
  if [ ${#s} -gt $n ]; then
    echo "${s:0:$((n-1))}…"
  else
    echo "$s"
  fi
}
esc() {
  # Escape pipes che SwiftBar interpreta come separatore parametri
  echo "${1//|/\\|}"
}
# Slurm sul server emette timestamp in UTC (es. "2026-05-11T12:00:00").
# utc_to_epoch: converte stringa UTC → unix epoch (per math)
utc_to_epoch() {
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "${1%%.*}" +%s 2>/dev/null
}
# utc_to_local: converte stringa UTC → "YYYY-MM-DD HH:MM ZZZ" in TZ locale
utc_to_local() {
  local ts
  ts=$(utc_to_epoch "$1") || return 1
  [ -z "$ts" ] && return 1
  date -r "$ts" "+%Y-%m-%d %H:%M %Z" 2>/dev/null
}

# --- Helpers di rendering carico (spostati in alto perché usati anche dalla
#     sezione "Nodi liberi" stampata in cima) ---
make_bar() {
  local used=$1 tot=$2 width=${3:-10}
  local b="" filled=0 i=0
  if [ "$tot" -gt 0 ]; then
    filled=$(( used * width / tot ))
    [ $filled -gt $width ] && filled=$width
  fi
  while [ $i -lt $filled ]; do b="${b}█"; i=$((i+1)); done
  while [ $i -lt $width ]; do b="${b}░"; i=$((i+1)); done
  echo "$b"
}
load_color() {
  local pct=$1
  if [ $pct -ge 90 ]; then echo "#FF3B30,#FF453A"
  elif [ $pct -ge 60 ]; then echo "#FF9500,#FF9F0A"
  elif [ $pct -le 5 ]; then echo "#34C759,#30D158"
  else echo "#1D1D1F,#F5F5F7"; fi
}
fmt_mem() {
  local m=$1
  if [ $m -ge 1048576 ]; then echo "$((m/1048576))T"
  elif [ $m -ge 1024 ]; then echo "$((m/1024))G"
  else echo "${m}M"; fi
}
node_is_up() {
  local st="$1"
  case "$st" in
    *DOWN*|*FAIL*|*NOT_RESPONDING*|*DRAIN*|*MAINT*) return 1 ;;
    *) return 0 ;;
  esac
}
node_color() {
  local st="$1" pct="$2"
  case "$st" in
    *DOWN*|*FAIL*|*NOT_RESPONDING*) echo "#FF3B30,#FF453A"; return ;;
    *DRAIN*|*MAINT*)                echo "#FF9500,#FF9F0A"; return ;;
  esac
  load_color "$pct"
}


# --- render_resource_status: nuova sezione "Stato per risorsa" ---
# Sostituisce: "CPU load", "GPU load", "Coda completa cluster"
render_resource_status() {
  [ ${#NODE_LINES[@]} -eq 0 ] && return

  # ── Tier classifier ──────────────────────────────────────────────────────────
  # Restituisce tier name per un job (via partizione) o per un nodo (via GT/CT)
  classify_job_tier() {
    local JP="$1"
    case ",$JP," in
      *,gpu_h200,*|*_h200,*)  echo "h200"; return ;;
      *,gpu_a100,*|*_a100,*)  echo "a100"; return ;;
      *,gpu_a40,*|*_a40,*)    echo "a40";  return ;;
      *,gpu_v100,*|*_v100,*)  echo "v100"; return ;;
    esac
    # Multi-tier GPU partitions (cross-tier or private)
    case ",$JP," in
      *,serics_gpu,*|*,fair_gpu,*|*,smartdata_gpu,*|*,cgvg_gpu,*|*,restart_gpu,*|*,musychen_gpu,*)
        echo "multi_gpu"; return ;;
    esac
    # Any other gpu-ish partition name
    case "$JP" in *gpu*) echo "multi_gpu"; return ;; esac
    # CPU tiers
    case ",$JP," in
      *,cpu_sapphire,*|*,edu_sapphire,*) echo "sapphire_96"; return ;;
      *,cpu_skylake,*|*,edu_skylake,*|*_skylake,*) echo "skylake_32"; return ;;
    esac
    # Private CPU or other
    echo "multi_cpu"
  }

  classify_node_tier() {
    local GT="$1" CT="$2" PT="$3"
    if [ "${GT:-0}" -gt 0 ]; then
      case ",$PT," in
        *gpu_h200*|*_h200,*) echo "h200"; return ;;
        *gpu_a100*|*_a100,*) echo "a100"; return ;;
        *gpu_a40*|*_a40,*)   echo "a40";  return ;;
        *gpu_v100*|*_v100,*) echo "v100"; return ;;
        *serics_gpu*|*fair_gpu*|*smartdata_gpu*|*cgvg_gpu*|*restart_gpu*|*musychen_gpu*)
          echo "multi_gpu"; return ;;
        *gpu*) echo "multi_gpu"; return ;;
        *) echo "multi_gpu"; return ;;
      esac
    else
      case "${CT:-0}" in
        32)  echo "skylake_32"; return ;;
        96)  echo "sapphire_96"; return ;;
        128) echo "sapphire_128"; return ;;
        192) echo "sapphire_192"; return ;;
        *)   echo "cpu_other_${CT}"; return ;;
      esac
    fi
  }

  # ── Tier metadata ─────────────────────────────────────────────────────────────
  typeset -A TIER_LABEL TIER_ORDER TIER_KIND
  # GPU tiers
  TIER_LABEL[h200]="GPU H200";       TIER_ORDER[h200]=10;        TIER_KIND[h200]="gpu"
  TIER_LABEL[a100]="GPU A100";       TIER_ORDER[a100]=20;        TIER_KIND[a100]="gpu"
  TIER_LABEL[a40]="GPU A40";         TIER_ORDER[a40]=30;         TIER_KIND[a40]="gpu"
  TIER_LABEL[v100]="GPU V100";       TIER_ORDER[v100]=40;        TIER_KIND[v100]="gpu"
  TIER_LABEL[multi_gpu]="Multi-tier GPU (restricted/fair)"; TIER_ORDER[multi_gpu]=200; TIER_KIND[multi_gpu]="gpu"
  # CPU tiers
  TIER_LABEL[skylake_32]="Skylake 32c";    TIER_ORDER[skylake_32]=60;   TIER_KIND[skylake_32]="cpu"
  TIER_LABEL[sapphire_96]="Sapphire 96c";  TIER_ORDER[sapphire_96]=70;  TIER_KIND[sapphire_96]="cpu"
  TIER_LABEL[sapphire_128]="Sapphire 128c";TIER_ORDER[sapphire_128]=80; TIER_KIND[sapphire_128]="cpu"
  TIER_LABEL[sapphire_192]="Sapphire 192c";TIER_ORDER[sapphire_192]=90; TIER_KIND[sapphire_192]="cpu"
  TIER_LABEL[multi_cpu]="Multi-tier CPU (private/other)"; TIER_ORDER[multi_cpu]=210; TIER_KIND[multi_cpu]="cpu"

  # ── Aggregate node data per tier ─────────────────────────────────────────────
  typeset -A TIER_NODES_FREE TIER_NODES_TOT
  typeset -A TIER_GPU_FREE TIER_GPU_TOT TIER_CPU_FREE TIER_CPU_TOT
  typeset -A TIER_HAS_PENDING TIER_HAS_RUNNING

  local ln NN ST PT CA CT MA MT GU GT GR tier
  for ln in "${NODE_LINES[@]}"; do
    IFS='|' read -r NN ST PT CA CT MA MT GU GT GR <<< "$ln"
    tier=$(classify_node_tier "${GT:-0}" "${CT:-0}" "$PT")
    # Register order for any new cpu_other tier
    if [[ "$tier" == cpu_other_* ]]; then
      TIER_LABEL[$tier]="CPU ${CT}c"
      TIER_ORDER[$tier]=100
      TIER_KIND[$tier]="cpu"
    fi
    case "$ST" in
      *DOWN*|*FAIL*|*NOT_RESPONDING*|*DRAIN*|*MAINT*|*RESERVED*) ;;
      *)
        TIER_NODES_TOT[$tier]=$(( ${TIER_NODES_TOT[$tier]:-0} + 1 ))
        TIER_GPU_TOT[$tier]=$(( ${TIER_GPU_TOT[$tier]:-0} + GT ))
        TIER_CPU_TOT[$tier]=$(( ${TIER_CPU_TOT[$tier]:-0} + CT ))
        TIER_GPU_FREE[$tier]=$(( ${TIER_GPU_FREE[$tier]:-0} + GT - GU ))
        TIER_CPU_FREE[$tier]=$(( ${TIER_CPU_FREE[$tier]:-0} + CT - CA ))
        ;;
    esac
    [ "$ST" = "IDLE" ] && TIER_NODES_FREE[$tier]=$(( ${TIER_NODES_FREE[$tier]:-0} + 1 ))
  done

  # ── Aggregate job data per tier ───────────────────────────────────────────────
  # TIER_RUN_JOBS[tier] → list of "JID|JU|JP|JN|JG|JT|JC|JM" lines
  # TIER_PEND_JOBS[tier] → list of "JID|JU|JP|JN|JC|JG|JL|JR|JS|JQ|JV" lines
  typeset -A TIER_RUN_JOBS TIER_PEND_JOBS

  local jl
  for jl in "${JOBALL_LINES[@]}"; do
    IFS='|' read -r JID JU JP JN JG JT JC JM <<< "$jl"
    tier=$(classify_job_tier "$JP")
    TIER_RUN_JOBS[$tier]+="${jl}
"
    TIER_HAS_RUNNING[$tier]=1
  done

  for jl in "${PENDALL_LINES[@]}"; do
    IFS='|' read -r JID JU JP JN JC JG JL JR JS JQ JV <<< "$jl"
    tier=$(classify_job_tier "$JP")
    TIER_PEND_JOBS[$tier]+="${jl}
"
    TIER_HAS_PENDING[$tier]=1
  done

  # ── ETA helper ────────────────────────────────────────────────────────────────
  fmt_eta() {
    local START="$1"
    [ -z "$START" ] || [ "$START" = "N/A" ] || [ "$START" = "Unknown" ] && return
    local STS
    STS=$(utc_to_epoch "$START") || return
    [ -z "$STS" ] && return
    [ "$STS" -le "$NOW" ] && return
    local DLT=$(( (STS - NOW) / 60 ))
    if [ $DLT -ge 1440 ]; then echo "→ tra $((DLT/1440))g$((DLT%1440/60))h"
    elif [ $DLT -ge 60 ]; then echo "→ tra $((DLT/60))h$((DLT%60))m"
    else echo "→ tra ${DLT}m"; fi
  }

  # ── Tier header color ─────────────────────────────────────────────────────────
  tier_color() {
    local kind="$1" gfree="${2:-0}" gtot="${3:-0}" cfree="${4:-0}" ctot="${5:-0}" \
          nfree="${6:-0}" ntot="${7:-0}" has_pending="${8:-0}"
    if [ "$kind" = "gpu" ]; then
      local free=$gfree tot=$gtot
      if [ $tot -gt 0 ] && [ $free -eq 0 ] && [ $has_pending -eq 1 ]; then
        echo "#FF3B30,#FF453A"; return   # red: saturato + coda
      elif [ $free -eq 0 ]; then
        echo "#8E8E93,#8E8E93"; return   # gray: nessuna GPU libera
      elif [ $free -le 2 ]; then
        echo "#FF9500,#FF9F0A"; return   # orange: 1-2 libere
      else
        echo "#34C759,#30D158"; return   # green: libere
      fi
    else
      if [ $ntot -gt 0 ] && [ $nfree -eq 0 ] && [ $has_pending -eq 1 ]; then
        echo "#FF3B30,#FF453A"; return
      elif [ $cfree -eq 0 ]; then
        echo "#8E8E93,#8E8E93"; return
      elif [ $nfree -eq 0 ]; then
        echo "#FF9500,#FF9F0A"; return   # yellow-ish: sub-avail only
      else
        echo "#34C759,#30D158"; return
      fi
    fi
  }

  # ── Section header ────────────────────────────────────────────────────────────
  echo "Stato per risorsa | sfimage=cpu.fill"

  # Pre-declare loop variables to avoid zsh local-inside-loop printing
  local TIERS_SORTED t kind label ntot nfree gfree gtot cfree ctot has_pend
  local bar sfcol sfim extra _partitions
  local tier_node_lines
  local node_pct nclr nbar nstats nsfim state_badge
  local pend_lines_tier pend_count _pord _PKEY _CNT rest _rem
  local shown_pend total_pend_groups MAX_PEND_SHOWN
  local my_pos tier_q_total
  local jsfim jsfcol pjsfim pjsfcol ETA_STR eta_part GINFO nt

  # ── Iterate tiers in order ────────────────────────────────────────────────────
  TIERS_SORTED=$(for t in "${(k)TIER_ORDER[@]}"; do
    # Only emit tier if has nodes OR has jobs
    if [ -n "${TIER_NODES_TOT[$t]:-}" ] || [ -n "${TIER_HAS_RUNNING[$t]:-}" ] || [ -n "${TIER_HAS_PENDING[$t]:-}" ]; then
      printf "%d|%s\n" "${TIER_ORDER[$t]}" "$t"
    fi
  done | sort -t'|' -k1,1n)

  while IFS='|' read -r _ t; do
    [ -z "$t" ] && continue
    kind="${TIER_KIND[$t]:-cpu}"
    label="${TIER_LABEL[$t]:-$t}"
    ntot=${TIER_NODES_TOT[$t]:-0}
    nfree=${TIER_NODES_FREE[$t]:-0}
    gfree=${TIER_GPU_FREE[$t]:-0}
    gtot=${TIER_GPU_TOT[$t]:-0}
    cfree=${TIER_CPU_FREE[$t]:-0}
    ctot=${TIER_CPU_TOT[$t]:-0}
    has_pend=0
    [ -n "${TIER_HAS_PENDING[$t]:-}" ] && has_pend=1

    # Special header for multi-tier buckets
    if [ "$t" = "multi_gpu" ] || [ "$t" = "multi_cpu" ]; then
      sfcol="#AF52DE,#BF5AF2"
      sfim="memorychip"
      [ "$kind" = "cpu" ] && sfim="cpu"
      printf -- "%-14s | font=Menlo sfimage=%s sfcolor=%s color=%s\n" "$label" "$sfim" "$sfcol" "$sfcol"

      # List partitions involved
      _partitions=""
      for jl in ${(f)"${TIER_RUN_JOBS[$t]:-}"}; do
        [ -z "$jl" ] && continue
        IFS='|' read -r _ _ JP _ <<< "$jl"
        case ",$_partitions," in *,$JP,*) ;; *) _partitions="${_partitions:+$_partitions,}$JP" ;; esac
      done
      for jl in ${(f)"${TIER_PEND_JOBS[$t]:-}"}; do
        [ -z "$jl" ] && continue
        IFS='|' read -r _ _ JP _ <<< "$jl"
        case ",$_partitions," in *,$JP,*) ;; *) _partitions="${_partitions:+$_partitions,}$JP" ;; esac
      done
      [ -n "$_partitions" ] && echo "-- Partizioni: $(esc "$_partitions") | font=Menlo color=#8E8E93,#8E8E93"
    else
      # Normal tier header con utilization bar.
      # Allineamento: label %-14s · bar 10c · used/tot %5d/%-5d · unit · free %5d
      # font=Menlo obbligatorio per allineare colonne con caratteri monospace.
      # NB: niente `local` perché siamo a top-level non dentro una function.
      if [ "$kind" = "gpu" ]; then
        _used=$((gtot - gfree)); _tot=$gtot; _free=$gfree; _unit="GPU"
        bar=$(make_bar $_used $_tot 10)
        sfim="memorychip"
      else
        _used=$((ctot - cfree)); _tot=$ctot; _free=$cfree; _unit="core"
        bar=$(make_bar $_used $_tot 10)
        sfim="cpu"
      fi
      sfcol=$(tier_color "$kind" $gfree $gtot $cfree $ctot $nfree $ntot $has_pend)
      printf -- "%-14s %s  %5d/%-5d %-4s in uso · %5d free | font=Menlo sfimage=%s sfcolor=%s color=%s\n" \
        "$label" "$bar" "$_used" "$_tot" "$_unit" "$_free" "$sfim" "$sfcol" "$sfcol"
    fi

    # ── Running nodes sub-section ─────────────────────────────────────────────
    # Collect nodes that have this tier AND have jobs or are schedulable
    tier_node_lines=()
    for ln in "${NODE_LINES[@]}"; do
      IFS='|' read -r NN ST PT CA CT MA MT GU GT GR <<< "$ln"
      nt=$(classify_node_tier "${GT:-0}" "${CT:-0}" "$PT")
      [ "$nt" = "$t" ] || continue
      case "$ST" in *DOWN*|*FAIL*|*NOT_RESPONDING*|*DRAIN*|*MAINT*|*RESERVED*) continue ;; esac
      tier_node_lines+=("$ln")
    done

    if [ ${#tier_node_lines[@]} -gt 0 ]; then
      echo "-- Nodi (${#tier_node_lines[@]}) | sfimage=server.rack"
      for ln in "${tier_node_lines[@]}"; do
        IFS='|' read -r NN ST PT CA CT MA MT GU GT GR <<< "$ln"
        # Build per-node stats
        node_pct=0
        if [ "$kind" = "gpu" ]; then
          [ $GT -gt 0 ] && node_pct=$(( GU * 100 / GT ))
        else
          [ $CT -gt 0 ] && node_pct=$(( CA * 100 / CT ))
        fi
        nclr=$(node_color "$ST" $node_pct)
        # State badge
        state_badge="[$ST]"
        case "$ST" in
          IDLE)        state_badge="[IDLE]" ;;
          MIXED)       state_badge="[MIXED]" ;;
          ALLOCATED)   state_badge="[ALLOCATED]" ;;
        esac
        # Allineamento colonne (font=Menlo monospace):
        #   nodename %-12s · cpu %3d/%-3d · mem %4s/%-4s · [gpu %d/%d ·] state
        if [ "$kind" = "gpu" ]; then
          nsfim="memorychip"
          printf -- "---- %-12s cpu=%3d/%-3d  mem=%4s/%-4s  gpu=%d/%-2d %-12s | font=Menlo color=%s sfimage=%s\n" \
            "$NN" "$CA" "$CT" "$(fmt_mem $MA)" "$(fmt_mem $MT)" "$GU" "$GT" "$state_badge" "$nclr" "$nsfim"
        else
          nsfim="cpu"
          printf -- "---- %-12s cpu=%3d/%-3d  mem=%4s/%-4s              %-12s | font=Menlo color=%s sfimage=%s\n" \
            "$NN" "$CA" "$CT" "$(fmt_mem $MA)" "$(fmt_mem $MT)" "$state_badge" "$nclr" "$nsfim"
        fi

        # Jobs on this node
        if node_is_up "$ST"; then
          for jl in "${JOBALL_LINES[@]}"; do
            IFS='|' read -r JID JU JP JN JG JT JC JM <<< "$jl"
            [ "$JN" != "$NN" ] && continue
            jsfim="person.fill"; jsfcol=""; jcolor="color=#1D1D1F,#F5F5F7"
            if [ "$JU" = "$ME_USR" ]; then
              jsfim="star.fill"; jsfcol=" sfcolor=#FFCC00,#FFD60A"
              jcolor="color=#FFCC00,#FFD60A"
            fi
            GINFO=""
            [ -n "$JG" ] && [ "$JG" != "N/A" ] && [ "$JG" != "(null)" ] && GINFO="  $(esc "$JG")"
            echo "------ $JU  job=$JID$GINFO  t=$JT  [$(esc "$JP")] | font=Menlo $jcolor sfimage=$jsfim$jsfcol"
          done
        fi
      done
    fi

    # ── Pending queue sub-section ─────────────────────────────────────────────
    pend_lines_tier=$(printf '%s' "${TIER_PEND_JOBS[$t]:-}")
    if [ -n "$pend_lines_tier" ]; then
      pend_count=$(printf '%s\n' "$pend_lines_tier" | grep -c '^.' 2>/dev/null || echo 0)
      echo "-- In coda ($pend_count) | sfimage=hourglass"

      # Collapse by "JP|JC|JG|JL|JR|JQ" key, maintain priority order
      typeset -A _PGRP_CNT _PGRP_FIRST _PGRP_ORD
      _PGRP_CNT=(); _PGRP_FIRST=(); _PGRP_ORD=()
      _pord=0
      while IFS= read -r jl; do
        [ -z "$jl" ] && continue
        IFS='|' read -r JID JU JP JN JC JG JL JR JS JQ JV <<< "$jl"
        _PKEY="${JP}|${JC}|${JG}|${JL}|${JR}|${JQ}"
        if [ -z "${_PGRP_FIRST[$_PKEY]:-}" ]; then
          _PGRP_FIRST[$_PKEY]="$jl"
          _PGRP_ORD[$_PKEY]=$_pord
          _pord=$((_pord+1))
        fi
        _PGRP_CNT[$_PKEY]=$(( ${_PGRP_CNT[$_PKEY]:-0} + 1 ))
      done <<< "$pend_lines_tier"

      # Emit collapsed rows ordered by original priority order (already sorted desc)
      shown_pend=0; total_pend_groups=${#_PGRP_ORD[@]}; MAX_PEND_SHOWN=8
      for _PKEY in ${(k)_PGRP_ORD}; do
        echo "${_PGRP_ORD[$_PKEY]}|${_PGRP_CNT[$_PKEY]:-1}|${_PGRP_FIRST[$_PKEY]}"
      done | sort -t'|' -k1,1n | while IFS='|' read -r _ORD _CNT rest; do
        [ -z "$rest" ] && continue
        if [ $shown_pend -ge $MAX_PEND_SHOWN ]; then
          _rem=$(( total_pend_groups - shown_pend ))
          echo "---- … altri $_rem | font=Menlo color=#8E8E93,#8E8E93"
          break
        fi
        IFS='|' read -r JID JU JP JN JC JG JL JR JS JQ JV <<< "$rest"
        pjsfim="person.fill"; pjsfcol=""; pjcolor="color=#1D1D1F,#F5F5F7"
        if [ "$JU" = "$ME_USR" ]; then
          pjsfim="star.fill"; pjsfcol=" sfcolor=#FFCC00,#FFD60A"
          pjcolor="color=#FFCC00,#FFD60A"
        fi
        GINFO=""
        [ -n "$JG" ] && [ "$JG" != "N/A" ] && [ "$JG" != "(null)" ] && GINFO="  $(esc "$JG")"
        ETA_STR=$(fmt_eta "$JS")
        eta_part=""
        [ -n "$ETA_STR" ] && eta_part="  $ETA_STR"
        if [ "${_CNT:-1}" -gt 1 ]; then
          echo "---- × $_CNT  $JU  prio=$JQ  N=$JN cpu=$JC$GINFO  $(esc "$JL")  $(esc "$JP")  [$(esc "$JR")]$eta_part | font=Menlo $pjcolor sfimage=$pjsfim$pjsfcol"
        else
          echo "---- $JID  $JU  prio=$JQ  N=$JN cpu=$JC$GINFO  $(esc "$JL")  $(esc "$JP")  [$(esc "$JR")]$eta_part | font=Menlo $pjcolor sfimage=$pjsfim$pjsfcol"
        fi
        shown_pend=$((shown_pend+1))
      done

      # My position in this tier's queue
      if [ -n "$ME_USR" ]; then
        my_pos=0; tier_q_total=0
        while IFS= read -r jl; do
          [ -z "$jl" ] && continue
          tier_q_total=$((tier_q_total+1))
          IFS='|' read -r _ JU _ <<< "$jl"
          [ "$JU" = "$ME_USR" ] && [ $my_pos -eq 0 ] && my_pos=$tier_q_total
        done <<< "$pend_lines_tier"
        if [ $my_pos -gt 0 ]; then
          echo "---- Tu sei in posizione $my_pos/$tier_q_total in questo tier | sfimage=star.fill sfcolor=#FFCC00,#FFD60A font=Menlo"
        fi
      fi

      unset _PGRP_CNT _PGRP_FIRST _PGRP_ORD
    fi

  done <<< "$TIERS_SORTED"
}

# --- render_sprio_submenu: composizione priorità sprio ---
render_sprio_submenu() {
  [ ${#PENDALL_LINES[@]} -eq 0 ] && return
  # Only show if user has pending jobs
  local has_my_pend=0
  for ln in "${PENDALL_LINES[@]}"; do
    IFS='|' read -r _ JU _ <<< "$ln"
    [ "$JU" = "$ME_USR" ] && has_my_pend=1 && break
  done
  [ $has_my_pend -eq 0 ] && return

  echo "▾ Dettaglio composizione priorità (sprio) | sfimage=slider.horizontal.3 sfcolor=#AF52DE,#BF5AF2"

  # Cluster weights header
  if [ ${#PRIOCFG_LINES[@]} -gt 0 ]; then
    local PT
    PT=$(printf '%s\n' "${PRIOCFG_LINES[@]}" | awk -F'= *' '/^PriorityType/{print $2}')
    [ -n "$PT" ] && echo "-- Politica: $(esc "$PT") | font=Menlo color=$COL_FAINT"
    local WCFG
    WCFG=$(printf '%s\n' "${PRIOCFG_LINES[@]}" | awk -F'= *' '
      /PriorityWeightAge/       {age=$2}
      /PriorityWeightFairshare/ {fs=$2}
      /PriorityWeightJobSize/   {js=$2}
      /PriorityWeightPartition/ {pt=$2}
      /PriorityWeightQOS/       {qos=$2}
      /PriorityWeightTRES/      {tres=$2}
      /PriorityDecayHalfLife/   {hl=$2}
      END {printf "Age=%s FS=%s JS=%s Part=%s QOS=%s TRES=%s HL=%s", age, fs, js, pt, qos, tres, hl}
    ')
    echo "-- Pesi: $WCFG | font=Menlo color=$COL_FAINT"
  fi

  if [ ${#SPRIO_LINES[@]} -gt 0 ]; then
    echo "-- JOBID  AGE  ASSOC  FAIRSHARE  JOBSIZE  PART  QOS  TRES  USER  (contributi pesati) | font=Menlo color=$COL_FAINT"
    local j=0
    for sl in "${SPRIO_LINES[@]}"; do
      [ $j -ge 40 ] && break
      IFS='|' read -r SJID SAGE SASSOC SFS SJS SPRT SQOS STRES SUSR <<< "$sl"
      local SCLR="$COL_LBL"
      [ "$SUSR" = "$ME_USR" ] && SCLR="$COL_CYAN"
      echo "-- $SJID  $SAGE  $SASSOC  $SFS  $SJS  $SPRT  $SQOS  $STRES  $SUSR | font=Menlo color=$SCLR"
      j=$((j+1))
    done
  fi
}

# --- Stato manutenzione: scansione preliminare ---
NOW=$(date +%s)
MAINT_ACTIVE=0
MAINT_UPCOMING=0
DRAIN_NODES=0; MAINT_NODES=0; DOWN_NODES=0; RESV_NODES=0
UP_CPU_TOT=0; UP_GPU_TOT=0
for ln in "${NODE_LINES[@]}"; do
  IFS='|' read -r _ ST _ _ CT _ _ _ GT _ <<< "$ln"
  case "$ST" in
    *DRAIN*)    DRAIN_NODES=$((DRAIN_NODES+1)) ;;
  esac
  case "$ST" in
    *MAINT*)    MAINT_NODES=$((MAINT_NODES+1)) ;;
  esac
  case "$ST" in
    *DOWN*)     DOWN_NODES=$((DOWN_NODES+1)) ;;
  esac
  case "$ST" in
    *RESERVED*) RESV_NODES=$((RESV_NODES+1)) ;;
  esac
  case "$ST" in
    *DOWN*|*FAIL*|*NOT_RESPONDING*|*DRAIN*|*MAINT*) ;;
    *) UP_CPU_TOT=$((UP_CPU_TOT + CT)); UP_GPU_TOT=$((UP_GPU_TOT + GT)) ;;
  esac
done
for ln in "${RESV_LINES[@]}"; do
  IFS='|' read -r RN RST RS RE RNODES RFL _ <<< "$ln"
  case "$RFL$RN" in *MAINT*) ;; *) continue ;; esac
  RS_TS=$(utc_to_epoch "$RS"); RS_TS=${RS_TS:-0}
  RE_TS=$(utc_to_epoch "$RE"); RE_TS=${RE_TS:-0}
  if [ "$RS_TS" -le "$NOW" ] && [ "$RE_TS" -gt "$NOW" ]; then
    MAINT_ACTIVE=$((MAINT_ACTIVE+1))
  elif [ "$RS_TS" -gt "$NOW" ]; then
    MAINT_UPCOMING=$((MAINT_UPCOMING+1))
  fi
done

# --- Barra menu ---
# Triangolino giallo SOLO se cluster completamente offline (manutenzione pesante):
# nessun nodo schedulabile né per CPU né per GPU.
# Costruisce label minimale: niente "R: 0" o "P: 0", e solo icona se entrambi zero
LABEL=""
[ $R -gt 0 ] && LABEL="R: $R"
[ $P -gt 0 ] && LABEL="${LABEL:+$LABEL }P: $P"
if [ $UP_CPU_TOT -eq 0 ] && [ $UP_GPU_TOT -eq 0 ]; then
  echo "$LABEL | sfimage=exclamationmark.triangle.fill color=#FFCC00,#FFD60A"
else
  echo "$LABEL | sfimage=cpu.fill color=#1D1D1F,#F5F5F7"
fi
echo "---"
echo "Stato Cluster Legion ($HOST) | sfimage=network"
echo "Aggiorna ora | refresh=true sfimage=arrow.clockwise"
echo "---"

# Manutenzione/nodi degradati spostati in fondo (cluster sempre con qualche
# nodo down/drain, non vale come info "in cima").

# --- Job in esecuzione ---
# Costruisci mappa JID→stdout|stderr dai log Slurm
typeset -A LOG_OUT LOG_ERR
for _ln in "${STDLOGS_LINES[@]}"; do
  IFS='|' read -r _J _O _E <<< "$_ln"
  [ -n "$_J" ] && LOG_OUT[$_J]="$_O"
  [ -n "$_J" ] && LOG_ERR[$_J]="$_E"
done

echo "Job in esecuzione: $R | sfimage=play.circle.fill"
if [ $R -eq 0 ]; then
  echo "-- — nessuno — | color=$COL_FAINT"
else
  for ln in "${RUN_LINES[@]}"; do
    IFS='|' read -r JID NAME PART NODES TIME LIMIT NODELIST GRES <<< "$ln"
    NAME_T=$(trunc "$NAME" 30)
    echo "-- $JID  $(esc "$NAME_T") | sfimage=hammer.fill"
    echo "---- Partition: $(esc "$PART")"
    echo "---- Time: $(esc "$TIME") / $(esc "$LIMIT")"
    echo "---- Nodes: $NODES  ($(esc "$NODELIST"))"
    [ -n "$GRES" ] && [ "$GRES" != "N/A" ] && [ "$GRES" != "(null)" ] && echo "---- GRES: $(esc "$GRES")"
    echo "---- ──────────"
    echo "---- scontrol show job $JID | terminal=true shell=ssh param1=-t param2=$HOST param3=scontrol param4=show param5=job param6=$JID sfimage=info.circle"
    echo "---- scancel $JID | terminal=true shell=ssh param1=-t param2=$HOST param3=scancel param4=$JID sfimage=xmark.circle color=#FF3B30,#FF453A"
    # --- Voci log ---
    O="${LOG_OUT[$JID]:-}"
    E="${LOG_ERR[$JID]:-}"
    if [ -n "$O" ]; then
      echo "---- ──────────"
      OBASE=$(basename "$O")
      EBASE=$(basename "$E")
      echo "---- log: $OBASE | font=Menlo color=$COL_FAINT"
      if [ "$O" = "$E" ] || [ -z "$E" ]; then
        # stdout e stderr stesso file (o stderr non definito)
        echo "---- tail -f log | terminal=true shell=ssh param1=-t param2=$HOST param3=tail param4=-n param5=100 param6=-f param7=$(esc "$O") sfimage=doc.text sfcolor=#34C759,#30D158"
        echo "---- less log | terminal=true shell=ssh param1=-t param2=$HOST param3=less param4=+G param5=$(esc "$O") sfimage=doc.plaintext"
        echo "---- scarica log in /tmp | shell=scp param1=$HOST:$(esc "$O") param2=/tmp/ sfimage=arrow.down.doc.fill sfcolor=#007AFF,#0A84FF"
      else
        # stdout e stderr separati
        echo "---- tail -f stdout | terminal=true shell=ssh param1=-t param2=$HOST param3=tail param4=-n param5=100 param6=-f param7=$(esc "$O") sfimage=doc.text sfcolor=#34C759,#30D158"
        echo "---- tail -f stderr | terminal=true shell=ssh param1=-t param2=$HOST param3=tail param4=-n param5=100 param6=-f param7=$(esc "$E") sfimage=exclamationmark.octagon.fill sfcolor=#FF3B30,#FF453A"
        echo "---- less stdout | terminal=true shell=ssh param1=-t param2=$HOST param3=less param4=+G param5=$(esc "$O") sfimage=doc.plaintext"
        echo "---- scarica stdout in /tmp | shell=scp param1=$HOST:$(esc "$O") param2=/tmp/ sfimage=arrow.down.doc.fill sfcolor=#007AFF,#0A84FF"
        echo "---- scarica stderr in /tmp | shell=scp param1=$HOST:$(esc "$E") param2=/tmp/ sfimage=arrow.down.doc.fill sfcolor=#007AFF,#0A84FF"
      fi
      echo "---- apri /tmp in Finder | shell=open param1=/tmp/ sfimage=folder.fill sfcolor=#007AFF,#0A84FF"
    fi
  done
fi
echo "---"

# --- Job in coda ---
echo "Job in coda: $P | sfimage=pause.circle.fill"
if [ $P -eq 0 ]; then
  echo "-- — nessuno — | color=$COL_FAINT"
else
  for ln in "${PEND_LINES[@]}"; do
    IFS='|' read -r JID NAME PART NODES REASON START GRES <<< "$ln"
    NAME_T=$(trunc "$NAME" 30)
    echo "-- $JID  $(esc "$NAME_T") | sfimage=hourglass"
    echo "---- Partition: $(esc "$PART")"
    echo "---- Nodes richiesti: $NODES"
    echo "---- Reason: $(esc "$REASON")"
    if [ -n "$START" ] && [ "$START" != "N/A" ]; then
      START_LOC=$(utc_to_local "$START")
      echo "---- Est. start: $(esc "${START_LOC:-$START}") | font=Menlo"
    fi
    [ -n "$GRES" ] && [ "$GRES" != "N/A" ] && [ "$GRES" != "(null)" ] && echo "---- GRES: $(esc "$GRES")"
    echo "---- ──────────"
    echo "---- scancel $JID | terminal=true shell=ssh param1=-t param2=$HOST param3=scancel param4=$JID sfimage=xmark.circle color=#FF3B30,#FF453A"
  done
fi
echo "---"

ME_USR="${ME_LINES[1]:-${ME_LINES[0]:-}}"

# --- Stato per risorsa (sostituisce CPU load + GPU load + Coda cluster) ---
render_resource_status
echo "---"

# --- Composizione priorità sprio (solo se l'utente ha pending) ---
render_sprio_submenu
echo "---"

# --- Fair-share (priorità relativa) ---
# sshare emette una riga per PARTIZIONE: partition|rawusage|effusage|fairshare.
# Il valore FS assoluto di Slurm su cluster grandi varia di pochissimo (l'uso
# individuale è una goccia nel mare totale del cluster), quindi NON è informativo
# da solo. Mostriamo invece un PUNTEGGIO RELATIVO 0-100 normalizzato min-max sul
# profilo dell'utente: 100 = la partizione dove sei più favorito; 0 = la peggio.
# Auto-adattivo: se la varianza è trascurabile (range < 0.001) o c'è una sola
# partizione, fallback a "tutte simili".
if [ ${#SHARE_LINES[@]} -gt 0 ]; then
  echo "Fair-share priorità relativa | sfimage=scale.3d color=$COL_LBL"

  # Calcola min e max FS sul profilo utente (single awk pass)
  FS_STATS=$(printf '%s\n' "${SHARE_LINES[@]}" | awk -F'|' '
    NR==1 { min=$4; max=$4; sum=$4; n=1; next }
          { if ($4<min) min=$4; if ($4>max) max=$4; sum+=$4; n++ }
    END   { printf "%.6f|%.6f|%.6f|%d", min, max, sum/n, n }')
  IFS='|' read -r FS_MIN FS_MAX FS_AVG FS_N <<< "$FS_STATS"

  # Range "informativo" se max-min > 0.001 (oltre il "rumore" tipico) E ci sono ≥2 partizioni
  FS_RANGE_INT=$(awk -v a="$FS_MIN" -v b="$FS_MAX" 'BEGIN{printf "%d", (b-a)*1000+0.5}')
  if [ "$FS_N" -ge 2 ] && [ "$FS_RANGE_INT" -gt 0 ]; then
    NORM_OK=1
  else
    NORM_OK=0
  fi

  echo "-- Quanto sei privilegiato su ciascuna partizione, RELATIVO al tuo profilo. | font=Menlo color=$COL_MUTED"
  if [ "$NORM_OK" = "1" ]; then
    echo "-- 100 = dove conviene sottomettere ora · 0 = dove sei più penalizzato. | font=Menlo color=$COL_MUTED"
  else
    echo "-- Tutte le partizioni hanno priorità simile per te in questo momento. | font=Menlo color=$COL_FAINT"
  fi
  echo "-- ──────────"

  # Ordina per fairshare desc (la migliore in cima)
  SHARE_SORTED=$(printf '%s\n' "${SHARE_LINES[@]}" | sort -t'|' -k4,4rn)

  while IFS='|' read -r PART RAWU EFFU FS; do
    [ -z "$PART" ] && continue

    # Punteggio normalizzato 0-100 (min-max sul profilo utente)
    if [ "$NORM_OK" = "1" ]; then
      SCORE=$(awk -v v="$FS" -v lo="$FS_MIN" -v hi="$FS_MAX" \
        'BEGIN{printf "%d", (v-lo)/(hi-lo)*100+0.5}')
    else
      SCORE=50  # neutro
    fi

    pct_int=$(awk -v v="$EFFU" 'BEGIN{printf "%d", v*100+0.5}')
    BAR=$(make_bar "$SCORE" 100 12)

    # Etichetta interpretativa + colore
    if   [ "$SCORE" -ge 75 ]; then  LBL="favorito";    SCOL="$COL_OK"
    elif [ "$SCORE" -ge 50 ]; then  LBL="sopra media"; SCOL="$COL_YEL"
    elif [ "$SCORE" -ge 25 ]; then  LBL="sotto media"; SCOL="$COL_WARN"
    else                            LBL="penalizzato"; SCOL="$COL_BAD"
    fi
    [ "$NORM_OK" = "0" ] && { LBL="—"; SCOL="$COL_FAINT"; }

    printf -- "-- %-18s  %s  %3d  %-12s  usato %2d%% | font=Menlo color=%s\n" \
      "$PART" "$BAR" "$SCORE" "$LBL" "$pct_int" "$SCOL"
  done <<< "$SHARE_SORTED"

  echo "-- ──────────"
  if [ "$NORM_OK" = "1" ]; then
    # Mostra range FS assoluto per trasparenza (in formato "min..max"). Tipicamente
    # su Legion il range è ~0.001 — è normale, lo Slurm fa così sui cluster condivisi.
    FS_RANGE_FMT=$(awk -v a="$FS_MIN" -v b="$FS_MAX" 'BEGIN{printf "%.4f..%.4f", a, b}')
    echo "-- Range fs Slurm sul tuo profilo: $FS_RANGE_FMT (variazione di ${FS_RANGE_INT}‰). | font=Menlo color=$COL_FAINT sfimage=info.circle"
  fi
  echo "---"
fi

# --- Storico oggi ---
# Distinguo 3 casi: (a) sacct ha risposto con N job, (b) sacct ha risposto vuoto,
# (c) slurmdbd è giù (marker __SACCT_ERR__).
SACCT_ERR=0
SACCT_REAL=()
for ln in "${SACCT_LINES[@]}"; do
  if [ "$ln" = "__SACCT_ERR__" ]; then
    SACCT_ERR=1
  else
    SACCT_REAL+=("$ln")
  fi
done

COMP=0; FAIL=0; TIMO=0; CANC=0; OTHR=0
for ln in "${SACCT_REAL[@]}"; do
  IFS='|' read -r _ _ ST _ _ <<< "$ln"
  case "$ST" in
    COMPLETED)  COMP=$((COMP+1)) ;;
    FAILED)     FAIL=$((FAIL+1)) ;;
    TIMEOUT)    TIMO=$((TIMO+1)) ;;
    CANCELLED*) CANC=$((CANC+1)) ;;
    *)          OTHR=$((OTHR+1)) ;;
  esac
done

if [ $SACCT_ERR -eq 1 ]; then
  echo "Oggi: storico non disponibile | sfimage=calendar.badge.exclamationmark color=$COL_WARN"
  echo "-- slurmdbd giù (sacct: Connection refused) — solo i job correnti via squeue qui sopra | font=Menlo color=$COL_FAINT"
elif [ ${#SACCT_REAL[@]} -eq 0 ]; then
  if [ $R -gt 0 ] || [ $P -gt 0 ]; then
    echo "Oggi: $R running, $P pending (nessun job concluso oggi) | sfimage=calendar color=$COL_LBL"
  else
    echo "Oggi: nessun job ancora oggi | sfimage=calendar color=$COL_FAINT"
  fi
else
  echo "Oggi: ok=$COMP  err=$FAIL  timeout=$TIMO  canc=$CANC  altri=$OTHR | sfimage=calendar"
  for ln in "${SACCT_REAL[@]}"; do
    IFS='|' read -r JID JNAME ST EL EC <<< "$ln"
    JNAME_T=$(trunc "$JNAME" 25)
    case "$ST" in
      COMPLETED)  ICON="checkmark.circle"; CLR="#34C759,#30D158" ;;
      FAILED)     ICON="xmark.octagon"; CLR="#FF3B30,#FF453A" ;;
      TIMEOUT)    ICON="clock.badge.exclamationmark"; CLR="#FF9500,#FF9F0A" ;;
      CANCELLED*) ICON="minus.circle"; CLR="#8E8E93,#8E8E93" ;;
      RUNNING)    ICON="play.circle"; CLR="#007AFF,#0A84FF" ;;
      *)          ICON="circle"; CLR="#8E8E93,#8E8E93" ;;
    esac
    echo "-- $JID  $(esc "$JNAME_T")  $(esc "$ST")  $(esc "$EL")  rc=$(esc "$EC") | sfimage=$ICON color=$CLR font=Menlo"
  done
fi
echo "---"

# --- Spazio disco ---
# Realtà PoliTO Legion: NÉ `quota -s` NÉ `beegfs-ctl --getquota` espongono
# la quota personale dell'utente. L'unico modo per saperla è `du -sh ~`,
# che richiede minuti su decine/centinaia di GB. Mostriamo quindi:
#   - Capacità del FS (globale, non per-utente)
#   - Path personali esistenti su ciascun FS (con last-modified)
#   - Pulsante per lanciare `du -sh` in terminale separato (a discrezione utente)
if [ ${#DF_LINES[@]} -gt 0 ]; then
  echo "Spazio disco | sfimage=externaldrive.connected.to.line.below color=$COL_LBL"
  echo "-- Capacità FS (globale del cluster). Quota personale non esposta da Legion. | font=Menlo color=$COL_MUTED"
  echo "-- ──────────"

  # Etichette friendly per i mountpoint noti
  fs_label() {
    case "$1" in
      /home)               echo "Home (NFS)" ;;
      /mnt/beegfs)         echo "BeeGFS scratch" ;;
      /mnt/beegfs-compat)  echo "BeeGFS legacy (compat)" ;;
      /scratch)            echo "Scratch" ;;
      /work)               echo "Work" ;;
      /share/apps)         echo "Apps (read-only)" ;;
      *)                   echo "$1" ;;
    esac
  }

  # Costruisci mappa mountpoint → user paths (può averne 0..N).
  # Separatore record interno: § (carattere raro, non presente nei path).
  typeset -A MP_PATHS
  for ul in "${USERPATHS_LINES[@]}"; do
    IFS='|' read -r mp p mt <<< "$ul"
    MP_PATHS[$mp]="${MP_PATHS[$mp]:+${MP_PATHS[$mp]}§}$p|$mt"
  done

  # Ordina FS in ordine: home → beegfs → beegfs-compat → resto
  ORD_FS=$(for ln in "${DF_LINES[@]}"; do
    IFS='|' read -r _ _ _ _ _ MNT <<< "$ln"
    case "$MNT" in
      /home)              ord=10 ;;
      /mnt/beegfs)        ord=20 ;;
      /mnt/beegfs-compat) ord=30 ;;
      /share/apps)        ord=99 ;;
      *)                  ord=50 ;;
    esac
    printf "%d|%s\n" "$ord" "$ln"
  done | sort -t'|' -k1,1n)

  while IFS='|' read -r _ FS SZ USED AVAIL PCT MNT; do
    [ -z "$FS" ] && continue
    PN=${PCT%\%}
    [ -z "$PN" ] && PN=0
    # Color: green <50%, yellow 50-70, orange 70-85, red >85
    if   [ $PN -ge 85 ]; then DCLR="$COL_BAD"
    elif [ $PN -ge 70 ]; then DCLR="$COL_WARN"
    elif [ $PN -ge 50 ]; then DCLR="$COL_YEL"
    else                       DCLR="$COL_OK"
    fi
    BAR=$(make_bar $PN 100 12)
    LBL=$(fs_label "$MNT")

    printf -- "%-22s %s  %3d%%  %5s/%-5s  free %5s | font=Menlo color=%s sfimage=externaldrive.fill\n" \
      "$LBL" "$BAR" "$PN" "$USED" "$SZ" "$AVAIL" "$DCLR"

    # Nota quota legata al filesystem (inline così non si confonde con altri FS)
    case "$MNT" in
      /home)
        if [ "$HOME_QUOTA_GB" -gt 0 ] 2>/dev/null; then
          if [ "$HOME_QUOTA_GB" -ge 1024 ] 2>/dev/null; then
            _HQ_LBL="$((HOME_QUOTA_GB / 1024)).$(( (HOME_QUOTA_GB % 1024) * 10 / 1024 )) TB"
          else
            _HQ_LBL="${HOME_QUOTA_GB} GB"
          fi
          echo "-- Quota utente: $_HQ_LBL (limite noto, il cluster non lo espone) | font=Menlo color=$COL_FAINT sfimage=person.crop.circle"
        fi
        ;;
      /mnt/beegfs|/mnt/beegfs-compat)
        echo "-- Nessuna quota per-utente · usabile fino al limite FS | font=Menlo color=$COL_FAINT sfimage=infinity"
        ;;
    esac

    # Path personali su questo FS (split per '§' separator)
    if [ -n "${MP_PATHS[$MNT]:-}" ]; then
      for entry in ${(s:§:)MP_PATHS[$MNT]}; do
        [ -z "$entry" ] && continue
        IFS='|' read -r upath umtime <<< "$entry"
        echo "-- $(esc "$upath")  ·  modificato $(esc "$umtime") | font=Menlo color=$COL_LBL sfimage=folder.fill"
        echo "---- misura con du -sh (apre terminale) | terminal=true shell=ssh param1=-t param2=$HOST param3=du param4=-sh param5=$(esc "$upath") sfimage=ruler"
      done
    elif [ "$MNT" = "/share/apps" ] || [ "$MNT" = "/" ] || [ "$MNT" = "/boot" ]; then
      :  # niente path personale atteso
    else
      echo "-- (nessuna dir personale rilevata su questo FS) | font=Menlo color=$COL_FAINT"
    fi
  done <<< "$ORD_FS"

  echo "---"
fi

# --- Azioni ---
echo "Azioni rapide | sfimage=bolt.fill"
echo "-- nvtop (GPU) | terminal=true shell=ssh param1=-t param2=$HOST param3=nvtop sfimage=memorychip"
echo "-- squeue (tutti i job) | terminal=true shell=ssh param1=-t param2=$HOST param3=squeue sfimage=list.bullet.rectangle"
echo "-- sinfo | terminal=true shell=ssh param1=-t param2=$HOST param3=sinfo sfimage=server.rack"
echo "-- shell su $HOST | terminal=true shell=ssh param1=$HOST sfimage=terminal"
echo "---"

# --- Manutenzione (in fondo: cluster ha sempre qualche nodo down/drain,
# non vale come allarme prioritario) ---
if [ $MAINT_ACTIVE -gt 0 ] || [ $MAINT_UPCOMING -gt 0 ] || [ ${#RESV_LINES[@]} -gt 0 ] \
   || [ $DRAIN_NODES -gt 0 ] || [ $MAINT_NODES -gt 0 ] || [ $DOWN_NODES -gt 0 ] || [ $RESV_NODES -gt 0 ]; then
  if [ $MAINT_ACTIVE -gt 0 ]; then
    HCLR="$COL_WARN"; HICON="wrench.and.screwdriver.fill"
    HTXT="Manutenzione IN CORSO ($MAINT_ACTIVE)"
  elif [ $MAINT_UPCOMING -gt 0 ]; then
    HCLR="$COL_YEL"; HICON="wrench.and.screwdriver"
    HTXT="Manutenzione programmata ($MAINT_UPCOMING)"
  elif [ $DOWN_NODES -gt 0 ] || [ $DRAIN_NODES -gt 0 ]; then
    HCLR="$COL_FAINT"; HICON="exclamationmark.triangle"
    HTXT="Stato nodi"
  else
    HCLR="$COL_LBL"; HICON="checkmark.shield"
    HTXT="Stato nodi"
  fi
  echo "$HTXT | sfimage=$HICON color=$HCLR"
  if [ $DRAIN_NODES -gt 0 ] || [ $MAINT_NODES -gt 0 ] || [ $DOWN_NODES -gt 0 ] || [ $RESV_NODES -gt 0 ]; then
    echo "-- Nodi: drain=$DRAIN_NODES  maint=$MAINT_NODES  down=$DOWN_NODES  reserved=$RESV_NODES | font=Menlo color=$COL_MUTED"
    for ln in "${NODE_LINES[@]}"; do
      IFS='|' read -r NN ST _ _ _ _ _ _ _ _ <<< "$ln"
      case "$ST" in
        *DRAIN*|*MAINT*|*DOWN*|*RESERVED*|*FAIL*|*NOT_RESPONDING*)
          NCLR="$COL_WARN"
          case "$ST" in *DOWN*|*FAIL*|*NOT_RESPONDING*) NCLR="$COL_BAD" ;; esac
          echo "---- $NN  [$ST] | font=Menlo color=$NCLR"
          ;;
      esac
    done
  fi
  if [ ${#RESV_LINES[@]} -gt 0 ]; then
    for ln in "${RESV_LINES[@]}"; do
      IFS='|' read -r RN RST RS RE RNODES RFL RUSERS <<< "$ln"
      case "$RFL$RN" in *MAINT*) RICON="wrench.and.screwdriver.fill"; RLBL="MAINT" ;;
                       *)        RICON="calendar.badge.clock";        RLBL="RESV"  ;;
      esac
      RS_TS=$(utc_to_epoch "$RS"); RS_TS=${RS_TS:-0}
      RE_TS=$(utc_to_epoch "$RE"); RE_TS=${RE_TS:-0}
      RCLR="$COL_LBL"
      WHEN=""
      if [ "$RS_TS" -le "$NOW" ] && [ "$RE_TS" -gt "$NOW" ]; then
        RCLR="$COL_WARN"
        REM=$(( (RE_TS - NOW) / 60 ))
        if [ $REM -ge 60 ]; then WHEN="ATTIVA, finisce tra $((REM/60))h$((REM%60))m"
        else WHEN="ATTIVA, finisce tra ${REM}m"; fi
      elif [ "$RS_TS" -gt "$NOW" ]; then
        RCLR="$COL_YEL"
        DLT=$(( (RS_TS - NOW) / 60 ))
        if [ $DLT -ge 1440 ]; then WHEN="inizia tra $((DLT/1440))g $((DLT%1440/60))h"
        elif [ $DLT -ge 60 ]; then WHEN="inizia tra $((DLT/60))h $((DLT%60))m"
        else WHEN="inizia tra ${DLT}m"; fi
      else
        RCLR="$COL_FAINT"; WHEN="conclusa"
      fi
      echo "-- [$RLBL] $(esc "$RN")  $WHEN | sfimage=$RICON color=$RCLR"
      RS_LOC=$(utc_to_local "$RS"); RE_LOC=$(utc_to_local "$RE")
      echo "---- Inizio: $(esc "${RS_LOC:-$RS}") | font=Menlo color=$COL_FAINT"
      echo "---- Fine:   $(esc "${RE_LOC:-$RE}") | font=Menlo color=$COL_FAINT"
      echo "---- Nodi:   $(esc "$RNODES") | font=Menlo color=$COL_MUTED"
      [ -n "$RFL" ] && echo "---- Flags:  $(esc "$RFL") | font=Menlo color=$COL_FAINT"
      [ -n "$RUSERS" ] && echo "---- Users:  $(esc "$RUSERS") | font=Menlo color=$COL_FAINT"
    done
  fi
  echo "---"
fi

# Trova PoliTO_VPN.5s.sh: prima nella stessa dir di questo script (caso install
# standard via symlink in ~/Library/.../SwiftBar/Plugins), poi via PluginDirectory,
# poi fallback al path classico ~/Developer.
_HERE="${0:A:h}"
VPN_PLUGIN="$_HERE/PoliTO_VPN.5s.sh"
if [ ! -e "$VPN_PLUGIN" ]; then
  _PDIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
  [ -n "$_PDIR" ] && [ -e "$_PDIR/PoliTO_VPN.5s.sh" ] && VPN_PLUGIN="$_PDIR/PoliTO_VPN.5s.sh"
fi
[ ! -e "$VPN_PLUGIN" ] && VPN_PLUGIN="$HOME/Developer/polito-hpc-swiftbar/PoliTO_VPN.5s.sh"

echo "Disconnetti VPN PoliTO | shell=$VPN_PLUGIN param1=disconnect terminal=false refresh=true sfimage=lock.open.fill color=$COL_WARN"
