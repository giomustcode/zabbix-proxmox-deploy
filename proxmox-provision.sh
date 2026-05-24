#!/usr/bin/env bash
# =============================================================================
# Zabbix 7.0 LTS — Provisionamento de VM no Proxmox VE (Debian 13 Trixie)
# Cria a VM com cloud-init e dispara zabbix-install.sh dentro do convidado.
# Executar no HOST Proxmox como root.
#
# IMPORTANTE: este script é seguro em relação ao host:
#   - nunca altera storage, bridges, firewall ou outras VMs do host
#   - recusa-se a continuar se o VMID já estiver em uso
#   - todos os snippets de cloud-init são exclusivos por VMID
#   - tudo o que é pesado (PostgreSQL, Zabbix) é instalado dentro da VM
# =============================================================================

set -euo pipefail

# --- CONFIGURAÇÃO DA VM ------------------------------------------------------
# VMID vazio = auto-detectar via /cluster/nextid (próximo livre no cluster)
VMID="${VMID:-}"
VM_NAME="${VM_NAME:-zabbix-monitoring}"
VM_MEMORY="${VM_MEMORY:-8192}"          # MB — folga para PG + cache do Zabbix
VM_CORES="${VM_CORES:-4}"
VM_DISK_SIZE="${VM_DISK_SIZE:-100}"     # GB — TimescaleDB cresce com history/trends
VM_STORAGE="${VM_STORAGE:-local-lvm}"
VM_BRIDGE="${VM_BRIDGE:-vmbr0}"
VM_VLAN="${VM_VLAN:-}"                  # Deixar vazio para sem VLAN tag
VM_IP="${VM_IP:-dhcp}"                  # Ex: 192.0.2.10/24 ou 'dhcp'
VM_GW="${VM_GW:-}"                      # Gateway (se IP estático)
VM_DNS="${VM_DNS:-8.8.8.8}"
VM_SSHKEY="${VM_SSHKEY:-}"              # Path para chave SSH pública

# Cloud-init / OS — Debian 13 (Trixie)
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2}"
CLOUD_IMAGE_FILE="/var/lib/vz/template/qemu/debian-13-genericcloud-amd64.qcow2"
CLOUD_USER="${CLOUD_USER:-zabbixadm}"
CLOUD_PASS="${CLOUD_PASS:-$(openssl rand -base64 12)}"

# Verificação de integridade da imagem cloud
# Override com env var DEBIAN_CLOUD_KEYS="fpr1 fpr2" se a Debian rotacionar
DEBIAN_CLOUD_KEYS="${DEBIAN_CLOUD_KEYS:-DF9B9C49EAA9298432589D76DA87E80D6294BE9B}"
# SKIP_IMAGE_VERIFY=1 → ignora verificação (apenas para debug/emergência)
SKIP_IMAGE_VERIFY="${SKIP_IMAGE_VERIFY:-0}"

# Passwords da aplicação (geradas se não vierem do ambiente)
ZBX_DB_PASS="${ZBX_DB_PASS:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c20)}"
ZBX_ADMIN_PASS="${ZBX_ADMIN_PASS:-}"     # Vazio = mantém default 'zabbix' do Zabbix

# Script remoto
ZBX_SCRIPT_DIR="/opt/zabbix-deploy"
ZBX_INSTALL_REMOTE_PATH="${ZBX_SCRIPT_DIR}/zabbix-install.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "$(date '+%H:%M:%S') $*"; }
info()    { log "${BLUE}[INFO]${NC}  $*"; }
success() { log "${GREEN}[OK]${NC}    $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
error()   { log "${RED}[ERRO]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══  $*  ══${NC}"; }

# --- PARSE ARGS --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid)     VMID="$2"; shift ;;
    --name)     VM_NAME="$2"; shift ;;
    --memory)   VM_MEMORY="$2"; shift ;;
    --cores)    VM_CORES="$2"; shift ;;
    --disk)     VM_DISK_SIZE="$2"; shift ;;
    --storage)  VM_STORAGE="$2"; shift ;;
    --bridge)   VM_BRIDGE="$2"; shift ;;
    --vlan)     VM_VLAN="$2"; shift ;;
    --ip)       VM_IP="$2"; shift ;;
    --gw)       VM_GW="$2"; shift ;;
    --dns)      VM_DNS="$2"; shift ;;
    --sshkey)   VM_SSHKEY="$2"; shift ;;
    --db-pass)     ZBX_DB_PASS="$2"; shift ;;
    --admin-pass)  ZBX_ADMIN_PASS="$2"; shift ;;
    --help|-h)
      cat <<USAGE
Uso: bash proxmox-provision.sh [opções]
  --vmid <id>       ID da VM (omisso = auto via /cluster/nextid)
  --name <nome>     Nome da VM (padrão: zabbix-monitoring)
  --memory <MB>     RAM em MB (padrão: 8192)
  --cores <n>       Número de cores (padrão: 4)
  --disk <GB>       Tamanho do disco (padrão: 100)
  --storage <s>     Storage Proxmox (padrão: local-lvm)
  --bridge <b>      Bridge de rede (padrão: vmbr0)
  --vlan <id>       VLAN tag (opcional)
  --ip <cidr>       IP estático (ex: 192.0.2.10/24) ou 'dhcp'
  --gw <ip>         Gateway (obrigatório se IP estático)
  --dns <ip>        DNS (padrão: 8.8.8.8)
  --sshkey <path>   Chave SSH pública para acesso
  --db-pass <pwd>   Senha da BD Zabbix (gerada se omitida)
  --admin-pass <p>  Senha do Admin do Zabbix UI (default: 'zabbix')
USAGE
      exit 0
      ;;
    *) warn "Argumento desconhecido: $1" ;;
  esac
  shift
done

# --- VERIFICAÇÕES DE SEGURANÇA ----------------------------------------------
check_proxmox_host() {
  command -v pvesh &>/dev/null || error "Este script deve ser executado no host Proxmox VE"
  command -v qm &>/dev/null    || error "Comando 'qm' não encontrado — host não é Proxmox?"
  [[ $EUID -eq 0 ]] || error "Execute como root no host Proxmox"
}

# Em ambiente cluster, recusa-se a continuar se não houver quorum — qm create
# pode corromper a vista do cluster se rodar sem maioria.
check_cluster_health() {
  if [[ -f /etc/corosync/corosync.conf ]] && command -v pvecm &>/dev/null; then
    info "Cluster Proxmox detectado"
    if ! pvecm status 2>/dev/null | grep -qE "^Quorate:[[:space:]]+Yes"; then
      error "Cluster SEM QUORUM. Abortando para não criar VM em estado inconsistente. Veja: pvecm status"
    fi
    local NODES
    NODES=$(pvecm nodes 2>/dev/null | awk 'NR>4 {print $3}' | grep -v '^$' | wc -l)
    success "Cluster com quorum (${NODES} nós membros)"
  else
    info "Nó standalone (sem cluster)"
  fi
}

# Se o utilizador não passou --vmid, pede ao PVE o próximo VMID livre.
# Funciona em cluster e standalone.
auto_pick_vmid() {
  if [[ -n "$VMID" ]]; then
    return  # utilizador definiu explicitamente
  fi
  local PICKED
  PICKED=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]"' )
  [[ "$PICKED" =~ ^[0-9]+$ ]] || error "Falha a obter VMID livre via 'pvesh get /cluster/nextid'"
  VMID="$PICKED"
  info "VMID auto-atribuído pelo cluster: $VMID"
}

# VMID tem de ser único em TODO o cluster, não só no nó local.
check_vmid() {
  [[ "$VMID" =~ ^[0-9]+$ ]] || error "VMID inválido: $VMID"
  [[ "$VMID" -ge 100 && "$VMID" -le 999999999 ]] || error "VMID fora do intervalo permitido (100-999999999)"

  # 1) check cluster-wide via /cluster/resources — funciona em standalone também
  local CLUSTER_VMS
  if CLUSTER_VMS=$(pvesh get /cluster/resources --type vm --output-format json 2>/dev/null); then
    if echo "$CLUSTER_VMS" | grep -Eq "\"vmid\"[[:space:]]*:[[:space:]]*${VMID}([^0-9]|$)"; then
      local OTHER_NODE
      OTHER_NODE=$(echo "$CLUSTER_VMS" \
        | grep -oE "\"node\"[[:space:]]*:[[:space:]]*\"[^\"]+\"[^}]*\"vmid\"[[:space:]]*:[[:space:]]*${VMID}([^0-9]|$)" \
        | head -1 | grep -oE "\"node\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" | cut -d'"' -f4)
      error "VMID ${VMID} já em uso${OTHER_NODE:+ no nó '${OTHER_NODE}'}. Veja IDs livres com: pvesh get /cluster/nextid"
    fi
  fi

  # 2) fallback local — caso /cluster/resources falhe por algum motivo
  if pvesh get "/nodes/$(hostname)/qemu/${VMID}/status/current" &>/dev/null 2>&1; then
    error "VMID ${VMID} já existe no nó local"
  fi
  success "VMID ${VMID} disponível em todo o cluster"
}

# Aviso (não fatal) se a memória pedida exceder a folga do nó atual.
check_node_resources() {
  local FREE_MEM_MB
  FREE_MEM_MB=$(free -m 2>/dev/null | awk '/^Mem:/ {print $7}')
  if [[ -n "$FREE_MEM_MB" && "$FREE_MEM_MB" -lt "$VM_MEMORY" ]]; then
    warn "Memória disponível no nó ($(hostname)): ${FREE_MEM_MB} MB"
    warn "VM pede ${VM_MEMORY} MB — overcommit pode pressionar outras VMs em execução"
    warn "Considere mover para outro nó ou reduzir --memory"
  fi
}

check_storage() {
  if ! pvesm status -storage "$VM_STORAGE" &>/dev/null; then
    error "Storage '${VM_STORAGE}' não existe neste host. Veja com: pvesm status"
  fi
  success "Storage ${VM_STORAGE} disponível"
}

check_bridge() {
  if [[ ! -d "/sys/class/net/${VM_BRIDGE}" ]]; then
    warn "Bridge ${VM_BRIDGE} não encontrada em /sys/class/net — verifique a rede do host"
  else
    success "Bridge ${VM_BRIDGE} disponível"
  fi
}

# --- CLOUD IMAGE -------------------------------------------------------------
download_cloud_image() {
  step "Imagem Cloud Debian 13 (Trixie)"
  if [[ -f "$CLOUD_IMAGE_FILE" ]]; then
    info "Imagem já existe: $CLOUD_IMAGE_FILE"
    return
  fi
  mkdir -p "$(dirname "$CLOUD_IMAGE_FILE")"
  info "Download: $CLOUD_IMAGE_URL"
  wget -q --show-progress -O "${CLOUD_IMAGE_FILE}.part" "$CLOUD_IMAGE_URL" || {
    rm -f "${CLOUD_IMAGE_FILE}.part"
    error "Falha ao baixar a imagem cloud"
  }
  mv "${CLOUD_IMAGE_FILE}.part" "$CLOUD_IMAGE_FILE"
  success "Imagem baixada"
}

# Verifica SHA512SUMS + assinatura GPG da Debian Cloud Team antes do import.
# Falha fechada por defeito; bypass apenas com SKIP_IMAGE_VERIFY=1.
verify_cloud_image() {
  step "Verificando integridade da imagem cloud"

  if [[ "$SKIP_IMAGE_VERIFY" == "1" ]]; then
    warn "SKIP_IMAGE_VERIFY=1 — verificação SALTADA (não recomendado em produção)"
    return
  fi

  local IMG_DIR IMG_NAME BASE_URL SUMS_FILE SIGN_FILE
  IMG_DIR="$(dirname "$CLOUD_IMAGE_FILE")"
  IMG_NAME="$(basename "$CLOUD_IMAGE_FILE")"
  BASE_URL="${CLOUD_IMAGE_URL%/*}"
  SUMS_FILE="${IMG_DIR}/SHA512SUMS"
  SIGN_FILE="${IMG_DIR}/SHA512SUMS.sign"

  # Re-baixa sempre (são leves, ~few KB; reflectem o último build)
  info "Baixando SHA512SUMS + .sign"
  wget -q -O "$SUMS_FILE" "${BASE_URL}/SHA512SUMS"      || error "Falha a baixar SHA512SUMS"
  wget -q -O "$SIGN_FILE" "${BASE_URL}/SHA512SUMS.sign" || error "Falha a baixar SHA512SUMS.sign"

  # --- 1) Verificação GPG da SHA512SUMS ---
  if ! command -v gpg &>/dev/null; then
    error "gpg não instalado. Instale com 'apt install gnupg' ou use SKIP_IMAGE_VERIFY=1 (não recomendado)"
  fi

  local GNUPGHOME_TMP
  GNUPGHOME_TMP=$(mktemp -d)
  # Cleanup garantido mesmo em erro
  trap 'rm -rf "$GNUPGHOME_TMP"' EXIT

  info "Importando chave(s) Debian Cloud Team: ${DEBIAN_CLOUD_KEYS}"
  local KEY_OK=0
  for KS in "hkps://keyring.debian.org" "hkps://keys.openpgp.org"; do
    if GNUPGHOME="$GNUPGHOME_TMP" gpg --batch --quiet --keyserver "$KS" \
         --recv-keys $DEBIAN_CLOUD_KEYS 2>/dev/null; then
      KEY_OK=1
      info "Chave obtida via $KS"
      break
    fi
  done
  [[ "$KEY_OK" == "1" ]] || error "Não consegui obter a chave GPG de nenhum keyserver — verifique rede ou defina DEBIAN_CLOUD_KEYS"

  info "Verificando assinatura GPG de SHA512SUMS..."
  if ! GNUPGHOME="$GNUPGHOME_TMP" gpg --batch --quiet \
         --verify "$SIGN_FILE" "$SUMS_FILE" 2>/dev/null; then
    error "ASSINATURA GPG INVÁLIDA — SHA512SUMS pode ter sido adulterado. Abortando."
  fi
  success "Assinatura GPG válida (Debian Cloud Team)"

  # --- 2) Verificação SHA512 da imagem ---
  info "Verificando SHA512 de ${IMG_NAME}..."
  local EXPECTED ACTUAL
  EXPECTED=$(grep -E "[[:space:]]${IMG_NAME}$" "$SUMS_FILE" | awk '{print $1}' | head -1)
  [[ -n "$EXPECTED" ]] || error "Imagem ${IMG_NAME} não está em SHA512SUMS — URL desactualizada?"

  ACTUAL=$(sha512sum "$CLOUD_IMAGE_FILE" | awk '{print $1}')
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    error "SHA512 NÃO BATE para ${IMG_NAME}. Apague ${CLOUD_IMAGE_FILE} e re-execute. Esperado: ${EXPECTED:0:32}... Obtido: ${ACTUAL:0:32}..."
  fi
  success "SHA512 confirmado — imagem íntegra"

  trap - EXIT
  rm -rf "$GNUPGHOME_TMP"
}

# --- CRIAR VM ----------------------------------------------------------------
create_vm() {
  step "Criando VM ${VMID}: ${VM_NAME}"

  qm create "${VMID}" \
    --name "${VM_NAME}" \
    --memory "${VM_MEMORY}" \
    --balloon 0 \
    --cores "${VM_CORES}" \
    --cpu host \
    --ostype l26 \
    --machine q35 \
    --bios ovmf \
    --efidisk0 "${VM_STORAGE}:4,efitype=4m,pre-enrolled-keys=0" \
    --scsihw virtio-scsi-single \
    --boot order=scsi0 \
    --agent enabled=1 \
    --serial0 socket \
    --vga serial0 \
    --onboot 1 \
    --tags "zabbix,monitoring"

  info "Importando imagem de disco..."
  qm importdisk "${VMID}" "${CLOUD_IMAGE_FILE}" "${VM_STORAGE}" --format qcow2
  qm set "${VMID}" --scsi0 "${VM_STORAGE}:vm-${VMID}-disk-1,discard=on,ssd=1,iothread=1"
  qm resize "${VMID}" scsi0 "${VM_DISK_SIZE}G"

  qm set "${VMID}" --ide2 "${VM_STORAGE}:cloudinit"

  local NET_OPTS="virtio,bridge=${VM_BRIDGE}"
  [[ -n "${VM_VLAN}" ]] && NET_OPTS="${NET_OPTS},tag=${VM_VLAN}"
  qm set "${VMID}" --net0 "${NET_OPTS}"

  qm set "${VMID}" \
    --ciuser "${CLOUD_USER}" \
    --cipassword "${CLOUD_PASS}" \
    --nameserver "${VM_DNS}" \
    --searchdomain "local"

  if [[ "$VM_IP" == "dhcp" ]]; then
    qm set "${VMID}" --ipconfig0 "ip=dhcp"
  else
    [[ -z "$VM_GW" ]] && error "Gateway (--gw) obrigatório para IP estático"
    qm set "${VMID}" --ipconfig0 "ip=${VM_IP},gw=${VM_GW}"
  fi

  if [[ -n "$VM_SSHKEY" && -f "$VM_SSHKEY" ]]; then
    qm set "${VMID}" --sshkeys "${VM_SSHKEY}"
    success "Chave SSH configurada"
  fi

  success "VM ${VMID} criada"
}

# --- CLOUD-INIT USER-DATA ----------------------------------------------------
write_userdata() {
  step "Preparando user-data do cloud-init"

  local SNIPPETS_DIR="/var/lib/vz/snippets"
  local USERDATA_FILE="${SNIPPETS_DIR}/zabbix-${VMID}-userdata.yaml"
  mkdir -p "$SNIPPETS_DIR"

  # Heredoc com os scripts embutidos — copiados para a VM em /opt/zabbix-deploy
  # via write_files. Mais simples que SCP e não depende de chave SSH.
  local INSTALL_B64
  INSTALL_B64=$(base64 -w0 < "${SCRIPT_DIR}/zabbix-install.sh")

  cat > "${USERDATA_FILE}" <<YAML
#cloud-config
hostname: ${VM_NAME}
manage_etc_hosts: true
package_update: true
package_upgrade: false

packages:
  - qemu-guest-agent
  - curl
  - wget
  - ca-certificates
  - gnupg
  - sudo

write_files:
  - path: ${ZBX_INSTALL_REMOTE_PATH}
    permissions: '0750'
    owner: root:root
    encoding: b64
    content: |
      ${INSTALL_B64}
  - path: /etc/zabbix-deploy.env
    permissions: '0600'
    owner: root:root
    content: |
      ZBX_DB_PASS=${ZBX_DB_PASS}
      ZBX_ADMIN_PASS=${ZBX_ADMIN_PASS}

runcmd:
  - systemctl enable --now qemu-guest-agent
  - mkdir -p ${ZBX_SCRIPT_DIR}
  - set -a && . /etc/zabbix-deploy.env && set +a && bash ${ZBX_INSTALL_REMOTE_PATH} 2>&1 | tee /var/log/zabbix-install.log

final_message: "Zabbix 7.0 LTS instalado. Acesse http://\$_INSTANCE_IP/zabbix/"
YAML

  qm set "${VMID}" --cicustom "user=local:snippets/zabbix-${VMID}-userdata.yaml"
  success "user-data gravado em ${USERDATA_FILE}"
}

# --- INICIAR VM --------------------------------------------------------------
start_vm() {
  step "Iniciando VM"
  qm start "${VMID}"
  success "VM ${VMID} iniciada"

  info "Aguardando boot e qemu-guest-agent (até 120s)..."
  local RETRIES=24
  while ! qm guest exec "${VMID}" -- /bin/true &>/dev/null; do
    [[ $RETRIES -le 0 ]] && { warn "qemu-guest-agent não respondeu — VM pode estar lenta"; return; }
    sleep 5
    ((RETRIES--))
  done
  success "qemu-guest-agent respondendo"

  if [[ "$VM_IP" == "dhcp" ]]; then
    local VM_IP_ACTUAL
    VM_IP_ACTUAL=$(qm guest exec "${VMID}" -- hostname -I 2>/dev/null \
      | grep -oP '\d+\.\d+\.\d+\.\d+' | grep -v '^127\.' | head -1 || echo "?")
    info "IP da VM: ${VM_IP_ACTUAL}"
  fi
}

# --- RESUMO ------------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║        VM PROXMOX CRIADA COM SUCESSO!        ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}VMID:${NC}          ${VMID}"
  echo -e "  ${BOLD}Nome:${NC}          ${VM_NAME}"
  echo -e "  ${BOLD}RAM:${NC}           ${VM_MEMORY} MB"
  echo -e "  ${BOLD}CPU:${NC}           ${VM_CORES} cores"
  echo -e "  ${BOLD}Disco:${NC}         ${VM_DISK_SIZE} GB"
  echo -e "  ${BOLD}Storage:${NC}       ${VM_STORAGE}"
  echo -e "  ${BOLD}Rede:${NC}          ${VM_BRIDGE}${VM_VLAN:+ VLAN ${VM_VLAN}}"
  echo -e "  ${BOLD}IP:${NC}            ${VM_IP}"
  echo -e "  ${BOLD}User Cloud:${NC}    ${CLOUD_USER}"
  echo -e "  ${BOLD}Pass Cloud:${NC}    ${CLOUD_PASS}"
  echo -e "  ${BOLD}DB Pass:${NC}       ${ZBX_DB_PASS}"
  if [[ -n "$ZBX_ADMIN_PASS" ]]; then
    echo -e "  ${BOLD}Admin UI Pass:${NC} ${ZBX_ADMIN_PASS}"
  else
    echo -e "  ${BOLD}Admin UI Pass:${NC} ${YELLOW}zabbix (default — trocar no primeiro login)${NC}"
  fi
  echo ""
  echo -e "  ${YELLOW}A instalação roda via cloud-init dentro da VM (~5–10 min).${NC}"
  echo -e "  ${YELLOW}Acompanhe:${NC} qm guest exec ${VMID} -- tail -n50 /var/log/zabbix-install.log"
  echo -e "  ${YELLOW}Ou via SSH:${NC} ssh ${CLOUD_USER}@<IP-VM> 'sudo tail -f /var/log/zabbix-install.log'"
  echo ""
  echo -e "  ${BOLD}Após terminar:${NC} acesse http://<IP-VM>/zabbix/ — login Admin/zabbix"
  echo -e "  ${RED}TROQUE A SENHA do Admin no primeiro login.${NC}"
  echo ""
  echo -e "  ${BOLD}${YELLOW}══ Backup — configurar IMEDIATAMENTE ══${NC}"
  echo -e "  ${YELLOW}Datacenter → Backup → Add${NC} (selecionar VMID ${VMID}), ou via CLI:"
  echo ""
  echo -e "    ${CYAN}pvesh create /cluster/backup \\${NC}"
  echo -e "    ${CYAN}  --vmid ${VMID} --storage <pbs-ou-storage-backup> \\${NC}"
  echo -e "    ${CYAN}  --schedule \"02:30\" --mode snapshot \\${NC}"
  echo -e "    ${CYAN}  --compress zstd --mailnotification failure${NC}"
  echo ""
  echo -e "  ${YELLOW}Para PITR de PostgreSQL, complementar com WAL archiving${NC}"
  echo -e "  ${YELLOW}dentro da VM (pg_basebackup + archive_command).${NC}"
  echo ""
}

# --- MAIN --------------------------------------------------------------------
main() {
  check_proxmox_host
  check_cluster_health
  auto_pick_vmid
  check_vmid
  check_storage
  check_bridge
  check_node_resources

  # zabbix-install.sh tem de existir ao lado deste script para ser embutido
  [[ -f "${SCRIPT_DIR}/zabbix-install.sh" ]] || \
    error "zabbix-install.sh não encontrado em ${SCRIPT_DIR}"

  download_cloud_image
  verify_cloud_image
  create_vm
  write_userdata
  start_vm
  print_summary
}

main "$@"
