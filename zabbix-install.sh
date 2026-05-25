#!/usr/bin/env bash
# =============================================================================
# Zabbix 7.0 LTS — Instalador para Debian 13 (Trixie)
# Stack: PostgreSQL 17 + TimescaleDB + Apache + PHP + Zabbix server/frontend/agent2
# Dimensionado para 100–150 hosts monitorados.
# Uso: sudo bash zabbix-install.sh
# Variáveis de ambiente respeitadas:
#   ZBX_DB_PASS, ZBX_DB_NAME, ZBX_DB_USER, ZBX_TIMEZONE
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- CONFIGURAÇÃO ------------------------------------------------------------
ZBX_MAJOR="7.0"                          # LTS
ZBX_DB_NAME="${ZBX_DB_NAME:-zabbix}"
ZBX_DB_USER="${ZBX_DB_USER:-zabbix}"
ZBX_DB_PASS="${ZBX_DB_PASS:-$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c20)}"
ZBX_ADMIN_PASS="${ZBX_ADMIN_PASS:-}"     # Vazio = mantém default 'zabbix'
ZBX_TIMEZONE="${ZBX_TIMEZONE:-Africa/Luanda}"

PG_VERSION="17"                          # Padrão do Debian 13
PG_CONF_DIR="/etc/postgresql/${PG_VERSION}/main"
PG_HBA="${PG_CONF_DIR}/pg_hba.conf"
PG_MAIN="${PG_CONF_DIR}/postgresql.conf"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/.zabbix-install.conf"
LOG_FILE="/var/log/zabbix-install.log"

# Cores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# --- UTILS -------------------------------------------------------------------
log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
info()    { log "${BLUE}[INFO]${NC}  $*"; }
success() { log "${GREEN}[OK]${NC}    $*"; }
warn()    { log "${YELLOW}[WARN]${NC}  $*"; }
error()   { log "${RED}[ERRO]${NC}  $*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $*${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════════${NC}"; \
            log "STEP: $*"; }

check_root() { [[ $EUID -eq 0 ]] || error "Execute como root: sudo bash $0"; }

detect_os() {
  [[ -f /etc/os-release ]] || error "Sistema operativo não identificado"
  # shellcheck disable=SC1091
  source /etc/os-release
  info "Sistema: $PRETTY_NAME"
  [[ "$ID" == "debian" ]]      || error "Apenas Debian é suportado. Detectado: $ID"
  [[ "$VERSION_ID" == "13" ]]  || warn "Versão esperada: Debian 13 (Trixie). Detectada: $VERSION_ID"
  OS_CODENAME="${VERSION_CODENAME:-trixie}"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# Gerado em $(date)
ZBX_DB_NAME="${ZBX_DB_NAME}"
ZBX_DB_USER="${ZBX_DB_USER}"
ZBX_DB_PASS="${ZBX_DB_PASS}"
ZBX_ADMIN_PASS="${ZBX_ADMIN_PASS}"
ZBX_TIMEZONE="${ZBX_TIMEZONE}"
EOF
  chmod 600 "$CONFIG_FILE"
}

wait_for_apt() {
  # cloud-init e unattended-upgrades podem segurar o lock no boot
  local i=0
  while fuser /var/lib/dpkg/lock-frontend &>/dev/null \
     || fuser /var/lib/apt/lists/lock &>/dev/null \
     || fuser /var/lib/dpkg/lock &>/dev/null; do
    ((i++))
    [[ $i -gt 60 ]] && error "Lock do APT preso há mais de 5 min — verifique 'ps aux | grep apt'"
    info "Aguardando lock do APT liberar... ($i)"
    sleep 5
  done
}

# --- REPOS -------------------------------------------------------------------
add_zabbix_repo() {
  step "Adicionando repositório oficial Zabbix ${ZBX_MAJOR} para Debian ${VERSION_ID}"
  # Padrão atual do Zabbix 7.0 para Debian 13 (verificado em zabbix.com/download
  # e listagem em repo.zabbix.com em 2025-08, ficheiro existe desde então):
  #   zabbix-release_latest_<MAJOR>+debian<VERSION>_all.deb
  # URL correcta: repo.zabbix.com/zabbix/<MAJOR>/debian/pool/main/z/zabbix-release/
  # (NÃO inclui /release/ no path — esse era o erro anterior que dava 404)
  local DEB="zabbix-release_latest_${ZBX_MAJOR}+debian${VERSION_ID}_all.deb"
  local URL="${ZBX_REPO_URL:-https://repo.zabbix.com/zabbix/${ZBX_MAJOR}/debian/pool/main/z/zabbix-release/${DEB}}"

  local TMP
  TMP=$(mktemp -d)
  info "Baixando $URL"
  if ! wget -q -O "${TMP}/${DEB}" "$URL"; then
    rm -rf "$TMP"
    error "Falha ao baixar o pacote zabbix-release. Verifique a URL em https://www.zabbix.com/download — ou sobrescreva com a env var ZBX_REPO_URL=<url-completa-do-.deb>"
  fi
  dpkg -i "${TMP}/${DEB}"
  rm -rf "$TMP"
  success "Repositório Zabbix ${ZBX_MAJOR} adicionado"
}

TIMESCALE_PIN_VERSION="${TIMESCALE_PIN_VERSION:-2.19.*}"   # Zabbix 7.0 suporta 2.13–2.26

add_timescaledb_repo() {
  step "Adicionando repositório oficial TimescaleDB (Community Edition, pinned)"
  # Porquê packagecloud e não o pacote nativo do Debian?
  #   - O `postgresql-17-timescaledb` do Debian é a build "Apache-only":
  #     SEM compression, SEM continuous aggregates, SEM policies. O Zabbix
  #     mostra "Detected license does not support compression" e perde-se
  #     o ganho de disco de ~5–10× em history/trends.
  #   - O repo packagecloud entrega a Community Edition (TSL) que tem tudo
  #     o que o Zabbix usa.
  #
  # Porquê PIN de versão?
  #   - O Zabbix 7.0 LTS só suporta TimescaleDB 2.13.x–2.26.x. Sem pin, o
  #     packagecloud entrega a latest (>=2.27 em 2026) e o Zabbix rejeita.
  #   - Fixamos em ${TIMESCALE_PIN_VERSION} (default 2.19.*) — bem dentro do
  #     intervalo suportado e sem drift em `apt upgrade`.
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
    | gpg --dearmor -o /etc/apt/keyrings/timescaledb.gpg
  chmod 0644 /etc/apt/keyrings/timescaledb.gpg

  cat > /etc/apt/sources.list.d/timescaledb.list <<REPO
deb [signed-by=/etc/apt/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ ${OS_CODENAME} main
REPO

  # Pin de versão via apt preferences (Pin-Priority 1001 > 1000 = força
  # downgrade se necessário, sobrevive a apt upgrade).
  #
  # NOTA: NÃO incluir `timescaledb-tools` no Package: — esse pacote tem
  # numeração própria (0.x.x) e nunca casa com `2.19.*`. Quando o havia,
  # o apt parecia ignorar a stanza toda e instalava a latest do .so.
  cat > /etc/apt/preferences.d/timescaledb.pref <<PREF
Package: timescaledb-2-postgresql-${PG_VERSION} timescaledb-2-loader-postgresql-${PG_VERSION}
Pin: version ${TIMESCALE_PIN_VERSION}
Pin-Priority: 1001
PREF
  success "Repo TimescaleDB adicionado; pin em ${TIMESCALE_PIN_VERSION}"
}

apt_update() {
  wait_for_apt
  info "apt-get update"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
}

# --- DEPENDÊNCIAS ------------------------------------------------------------
install_base_packages() {
  step "Instalando pacotes base"
  wait_for_apt
  # psmisc fornece `fuser` — usado por wait_for_apt(). Sem ele, wait_for_apt
  # vira silenciosamente um no-op (fuser ausente faz o `&>/dev/null` engolir
  # o erro), e poderíamos correr durante locks do cloud-init.
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg apt-transport-https \
    sudo lsb-release net-tools cron unzip rsync psmisc
  success "Pacotes base instalados"
}

install_postgres_and_timescale() {
  step "Instalando PostgreSQL ${PG_VERSION} + TimescaleDB Community"
  wait_for_apt
  # Pacote `timescaledb-2-postgresql-<v>` vem do packagecloud (Community
  # Edition, com compression). O pin em /etc/apt/preferences.d garante
  # que a versão fica em ${TIMESCALE_PIN_VERSION}.
  # Fixamos versão do .so e do loader explicitamente (=${TIMESCALE_PIN_VERSION})
  # — defesa-em-profundidade ao pin em /etc/apt/preferences.d. timescaledb-tools
  # entra sem versão (numeração própria, 0.x.x).
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" \
    "postgresql-contrib-${PG_VERSION}" \
    "timescaledb-2-postgresql-${PG_VERSION}=${TIMESCALE_PIN_VERSION}" \
    "timescaledb-2-loader-postgresql-${PG_VERSION}=${TIMESCALE_PIN_VERSION}" \
    timescaledb-tools

  systemctl enable postgresql
  systemctl start postgresql

  # Log da versão de TimescaleDB instalada (útil em troubleshooting)
  local TS_VER
  TS_VER=$(dpkg-query -W -f='${Version}' "timescaledb-2-postgresql-${PG_VERSION}" 2>/dev/null || echo "?")
  info "TimescaleDB instalado: ${TS_VER} (Zabbix 7.0 suporta 2.13.x–2.26.x)"
  success "PostgreSQL e TimescaleDB instalados"
}

install_zabbix_packages() {
  step "Instalando pacotes Zabbix ${ZBX_MAJOR}"
  wait_for_apt
  # NOTA importante: `zabbix-frontend-php` declara extensões PHP como
  # Recommends em algumas versões — combinado com --no-install-recommends
  # isto dá-nos erros confusos no frontend (ex: "DB type POSTGRESQL is not
  # supported", gráficos sem renderizar, etc.). Instalamos TODAS as
  # extensões PHP que o Zabbix usa, explicitamente:
  #   php-pgsql    → driver PostgreSQL (obrigatório com $DB['TYPE']='POSTGRESQL')
  #   php-gd       → renderização de gráficos
  #   php-bcmath   → cálculos de big numbers
  #   php-mbstring → strings multi-byte
  #   php-xml      → parsing XML (templates, imports)
  #   php-ldap     → autenticação LDAP (opcional mas barato)
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    zabbix-server-pgsql zabbix-frontend-php zabbix-apache-conf \
    zabbix-sql-scripts zabbix-agent2 zabbix-agent2-plugin-postgresql \
    php-pgsql php-gd php-bcmath php-mbstring php-xml php-ldap
  success "Zabbix server/frontend/agent2 instalados"
}

# --- POSTGRESQL --------------------------------------------------------------
tune_postgres() {
  step "Tuning do PostgreSQL para 8 GB de RAM / 100–150 hosts"

  # Não sobrescrevemos postgresql.conf — colocamos um drop-in em conf.d
  local DROPIN="${PG_CONF_DIR}/conf.d/99-zabbix.conf"
  mkdir -p "$(dirname "$DROPIN")"
  cat > "$DROPIN" <<PGCONF
# Tuning Zabbix 7.0 LTS — 100–150 hosts em VM 8 GB RAM
# Gerado por zabbix-install.sh

shared_preload_libraries = 'timescaledb'

# Memória
shared_buffers = 2GB
effective_cache_size = 6GB
work_mem = 16MB
maintenance_work_mem = 512MB

# Conexões
max_connections = 200

# WAL / checkpoints
wal_buffers = 16MB
checkpoint_completion_target = 0.9
min_wal_size = 1GB
max_wal_size = 4GB

# Disco (assume SSD)
random_page_cost = 1.1
effective_io_concurrency = 200

# Paralelismo (ajustado aos 4 vCPU)
max_worker_processes = 8
max_parallel_workers = 4
max_parallel_workers_per_gather = 2
max_parallel_maintenance_workers = 2

# Logging básico — útil para troubleshooting do Zabbix
log_min_duration_statement = 1000
log_checkpoints = on
log_connections = off
log_disconnections = off
log_lock_waits = on
log_temp_files = 0
log_line_prefix = '%m [%p] %q%u@%d '

# Standard conforming strings (recomendação Zabbix)
standard_conforming_strings = on

# Timescale
timescaledb.telemetry_level = off
PGCONF

  systemctl restart postgresql
  success "PostgreSQL tuned (drop-in em $DROPIN)"
}

create_zabbix_db() {
  step "Criando BD e utilizador Zabbix"
  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${ZBX_DB_USER}') THEN
    CREATE ROLE ${ZBX_DB_USER} LOGIN PASSWORD '${ZBX_DB_PASS}';
  ELSE
    ALTER ROLE ${ZBX_DB_USER} WITH PASSWORD '${ZBX_DB_PASS}';
  END IF;
END
\$\$;
SQL

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${ZBX_DB_NAME}'" | grep -q 1; then
    sudo -u postgres createdb -O "${ZBX_DB_USER}" -E UTF8 -T template0 "${ZBX_DB_NAME}"
    info "BD ${ZBX_DB_NAME} criada"
  else
    warn "BD ${ZBX_DB_NAME} já existia — mantendo"
  fi

  # Extensão Timescale criada como superuser; o schema do Zabbix entra depois
  sudo -u postgres psql -d "${ZBX_DB_NAME}" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
  success "BD Zabbix pronta com TimescaleDB"
}

import_zabbix_schema() {
  step "Importando schema do Zabbix"
  local SCHEMA="/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz"
  [[ -f "$SCHEMA" ]] || error "Schema não encontrado: $SCHEMA"

  # Só importa se o schema ainda não estiver carregado
  if sudo -u postgres psql -d "${ZBX_DB_NAME}" -tAc \
       "SELECT 1 FROM information_schema.tables WHERE table_name='users' AND table_schema='public'" \
       | grep -q 1; then
    warn "Schema do Zabbix já parece carregado — pulando import"
    return
  fi

  info "Carregando server.sql.gz (pode demorar 1–2 min)..."
  zcat "$SCHEMA" | sudo -u "${ZBX_DB_USER}" PGPASSWORD="${ZBX_DB_PASS}" \
    psql -h 127.0.0.1 -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" -q
  success "Schema importado"
}

set_admin_password() {
  if [[ -z "$ZBX_ADMIN_PASS" ]]; then
    info "ZBX_ADMIN_PASS não fornecida — Admin fica com 'zabbix' (mudar no UI)"
    return
  fi
  step "Definindo senha do utilizador Admin no Zabbix UI"

  # htpasswd vem do apache2-utils — instalar se faltar
  if ! command -v htpasswd &>/dev/null; then
    info "Instalando apache2-utils (htpasswd) para gerar hash bcrypt"
    wait_for_apt
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends apache2-utils
  fi

  # Gera hash bcrypt no formato $2y$ — aceite pelo password_verify() do PHP
  local HASH
  HASH=$(htpasswd -nbB Admin "${ZBX_ADMIN_PASS}" 2>/dev/null | cut -d: -f2 | tr -d '\r\n')
  if [[ ! "$HASH" =~ ^\$2[aby]\$ ]]; then
    warn "Falha a gerar hash bcrypt — Admin fica com a senha default"
    return
  fi

  # Dollar-quote com tag única ($zbxpw$) — robusto contra os '$' do hash bcrypt
  sudo -u "${ZBX_DB_USER}" PGPASSWORD="${ZBX_DB_PASS}" \
    psql -h 127.0.0.1 -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" -q -v ON_ERROR_STOP=1 \
    -c "UPDATE users SET passwd = \$zbxpw\$${HASH}\$zbxpw\$, attempt_failed = 0 WHERE username = 'Admin';" \
    || { warn "Falha a aplicar password do Admin via SQL — fica o default"; return; }

  success "Password do Admin definida"
}

apply_timescale_hypertables() {
  step "Configurando hypertables do TimescaleDB para o Zabbix"
  # O Zabbix 7.0 fornece o script de inicialização Timescale dentro do pacote.
  # Caminhos possíveis nas distribuições oficiais:
  local CANDIDATES=(
    "/usr/share/zabbix-sql-scripts/postgresql/timescaledb/schema.sql"
    "/usr/share/zabbix-sql-scripts/postgresql/timescaledb.sql"
  )
  local TS_SQL=""
  for c in "${CANDIDATES[@]}"; do
    [[ -f "$c" ]] && { TS_SQL="$c"; break; }
  done
  [[ -n "$TS_SQL" ]] || { warn "Script TimescaleDB do Zabbix não encontrado — hypertables não criadas"; return; }

  info "Aplicando ${TS_SQL}"
  # ON_ERROR_STOP=1 é crítico aqui: o script Timescale do Zabbix começa por
  # `RAISE EXCEPTION` se a versão do TimescaleDB estiver fora do suportado
  # (2.13–2.26). Sem isto, o psql continua, dá falsos hypertables e o erro
  # só aparece muito mais tarde no UI ("Unsupported TimescaleDB...").
  sudo -u "${ZBX_DB_USER}" PGPASSWORD="${ZBX_DB_PASS}" \
    psql -h 127.0.0.1 -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" -q \
         -v ON_ERROR_STOP=1 -f "$TS_SQL"
  success "Hypertables TimescaleDB configuradas"
}

# --- ZABBIX SERVER -----------------------------------------------------------
configure_zabbix_server() {
  step "Configurando zabbix_server.conf"
  local CONF="/etc/zabbix/zabbix_server.conf"
  [[ -f "$CONF" ]] || error "zabbix_server.conf não encontrado — pacote não instalado?"

  # Pequena helper para set/replace de chaves no formato KEY=VALUE
  set_kv() {
    local key="$1" val="$2" file="$3"
    if grep -qE "^[#[:space:]]*${key}=" "$file"; then
      sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${val}|" "$file"
    else
      echo "${key}=${val}" >> "$file"
    fi
  }

  # BD
  set_kv DBHost     "127.0.0.1"        "$CONF"
  set_kv DBName     "${ZBX_DB_NAME}"   "$CONF"
  set_kv DBUser     "${ZBX_DB_USER}"   "$CONF"
  set_kv DBPassword "${ZBX_DB_PASS}"   "$CONF"
  set_kv DBPort     "5432"             "$CONF"

  # Tuning para 100–150 hosts
  set_kv StartPollers              "20"  "$CONF"
  set_kv StartPollersUnreachable   "5"   "$CONF"
  set_kv StartTrappers             "5"   "$CONF"
  set_kv StartPingers              "4"   "$CONF"
  set_kv StartDiscoverers          "3"   "$CONF"
  set_kv StartHTTPPollers          "4"   "$CONF"
  set_kv StartPreprocessors        "8"   "$CONF"
  set_kv StartHistoryPollers       "2"   "$CONF"
  # StartReportWriters=0: os relatórios agendados precisam de `zabbix-web-service`
  # (que arrasta Chromium). Não o instalamos, então 0 evita warnings constantes
  # no log do zabbix-server. Para activar relatórios, instale zabbix-web-service
  # e suba este valor para 1+.
  set_kv StartReportWriters        "0"   "$CONF"

  set_kv CacheSize                 "128M" "$CONF"
  set_kv HistoryCacheSize          "64M"  "$CONF"
  set_kv HistoryIndexCacheSize     "32M"  "$CONF"
  set_kv TrendCacheSize            "32M"  "$CONF"
  set_kv ValueCacheSize            "128M" "$CONF"

  set_kv Timeout                   "15"   "$CONF"
  set_kv LogSlowQueries            "3000" "$CONF"

  chown root:zabbix "$CONF"
  chmod 640 "$CONF"
  success "zabbix_server.conf configurado"
}

configure_zabbix_agent2() {
  step "Configurando Zabbix agent2 (auto-monitorização)"
  local CONF="/etc/zabbix/zabbix_agent2.conf"
  [[ -f "$CONF" ]] || { warn "agent2 não instalado"; return; }

  sed -i -E 's|^[#[:space:]]*Server=.*|Server=127.0.0.1|'           "$CONF"
  sed -i -E 's|^[#[:space:]]*ServerActive=.*|ServerActive=127.0.0.1|' "$CONF"
  sed -i -E "s|^[#[:space:]]*Hostname=.*|Hostname=$(hostname)|"     "$CONF"

  success "agent2 configurado"
}

# --- APACHE / PHP ------------------------------------------------------------
configure_zabbix_frontend() {
  step "Pré-configurando o frontend (pula o setup wizard)"
  # Quando /etc/zabbix/web/zabbix.conf.php existe e é válido, o Zabbix não
  # mostra o setup wizard — vai directo para o ecrã de login. Como já temos
  # toda a info (BD, user, password, timezone), gravamos o ficheiro nós.
  #
  # IDEMPOTÊNCIA: se o ficheiro já existe (re-run, edição manual ou wizard
  # corrido antes), respeitamos e não tocamos nele.
  local CONF_DIR="/etc/zabbix/web"
  local CONF_FILE="${CONF_DIR}/zabbix.conf.php"

  if [[ -f "$CONF_FILE" ]]; then
    warn "${CONF_FILE} já existe — não vou sobrescrever. Apague o ficheiro se quiser regenerar."
    return
  fi

  mkdir -p "$CONF_DIR"

  cat > "$CONF_FILE" <<EOPHP
<?php
// Ficheiro gerado por zabbix-install.sh em $(date '+%Y-%m-%d %H:%M:%S')
// Para regenerar: apague este ficheiro e re-execute zabbix-install.sh,
// ou abra o setup wizard em /zabbix/setup.php

\$DB['TYPE']     = 'POSTGRESQL';
\$DB['SERVER']   = '127.0.0.1';
\$DB['PORT']     = '5432';
\$DB['DATABASE'] = '${ZBX_DB_NAME}';
\$DB['USER']     = '${ZBX_DB_USER}';
\$DB['PASSWORD'] = '${ZBX_DB_PASS}';

// Schema (vazio para PostgreSQL)
\$DB['SCHEMA']        = '';

// Encriptação BD — desligada (BD local em 127.0.0.1)
\$DB['ENCRYPTION']    = false;
\$DB['KEY_FILE']      = '';
\$DB['CERT_FILE']     = '';
\$DB['CA_FILE']       = '';
\$DB['VERIFY_HOST']   = false;
\$DB['CIPHER_LIST']   = '';

// Vault — não usado
\$DB['VAULT']           = '';
\$DB['VAULT_URL']       = '';
\$DB['VAULT_DB_PATH']   = '';
\$DB['VAULT_TOKEN']     = '';
\$DB['VAULT_CERT_FILE'] = '';
\$DB['VAULT_KEY_FILE']  = '';
\$DB['VAULT_PREFIX']    = '';

// IEEE-754 para float de 64 bits (default em instalações novas do Zabbix 7.0)
\$DB['DOUBLE_IEEE754']  = true;

// Endereço do server e nome mostrado no UI
\$ZBX_SERVER      = '127.0.0.1';
\$ZBX_SERVER_PORT = '10051';
\$ZBX_SERVER_NAME = '$(hostname)';

\$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;

// Elasticsearch — não usado
\$HISTORY['url']   = '';
\$HISTORY['types'] = [];

// SAML — não usado
\$SSO['SP_KEY']   = '';
\$SSO['SP_CERT']  = '';
\$SSO['IDP_CERT'] = '';
\$SSO['SETTINGS'] = [];
EOPHP

  chown root:www-data "$CONF_FILE"
  chmod 0640 "$CONF_FILE"

  # Validar sintaxe PHP — se falhar, apaga e cai de volta no wizard
  if ! php -l "$CONF_FILE" &>/dev/null; then
    warn "Sintaxe PHP inválida em ${CONF_FILE} — removendo, vai cair no setup wizard"
    rm -f "$CONF_FILE"
    return
  fi

  success "Frontend pré-configurado — wizard será saltado"
}

generate_locales() {
  step "Gerando locales (en_US, pt_PT, pt_BR)"
  # Cloud-images Debian vêm só com C/POSIX. O frontend do Zabbix chama
  # setlocale() e falha com "Locale for language 'en_US' is not found on
  # the web server" se en_US.UTF-8 não estiver gerada pelo locale-gen.
  # Geramos en_US (obrigatório p/ o default do Zabbix) + pt_PT + pt_BR
  # (timezone default Africa/Luanda → utilizadores PT-falantes).
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends locales

  # Passar nomes directamente ao locale-gen — não depende de sed em
  # /etc/locale.gen (formato muda entre versões). Idempotente: se já existe,
  # `locale-gen <name>` apenas regenera o ficheiro do locale.
  locale-gen en_US.UTF-8 pt_PT.UTF-8 pt_BR.UTF-8

  # Verificação dura — se algo correr mal, o instalador pára aqui em vez
  # de o utilizador descobrir o erro só no browser depois.
  if ! locale -a | grep -qi '^en_us\.utf8$'; then
    error "locale-gen falhou: en_US.UTF-8 não aparece em 'locale -a'"
  fi
  success "Locales prontos (en_US.UTF-8, pt_PT.UTF-8, pt_BR.UTF-8)"
}

configure_apache_php() {
  step "Configurando Apache + PHP (timezone: ${ZBX_TIMEZONE})"
  # O pacote zabbix-apache-conf já entrega /etc/zabbix/apache.conf e
  # /etc/apache2/conf-enabled/zabbix.conf — só precisamos do timezone.
  local APACHE_CONF="/etc/zabbix/apache.conf"
  if [[ -f "$APACHE_CONF" ]]; then
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*php_value date.timezone .*|        php_value date.timezone ${ZBX_TIMEZONE}|" "$APACHE_CONF"
    # Caso a linha não exista, anexa em ambos os blocos PHP (mod_php e fpm)
    grep -q "date.timezone ${ZBX_TIMEZONE}" "$APACHE_CONF" || \
      sed -i "/<IfModule mod_php/,/<\\/IfModule>/{/<\\/IfModule>/i\\        php_value date.timezone ${ZBX_TIMEZONE}
}" "$APACHE_CONF"
  fi

  # Também no php.ini de CLI (útil para troubleshooting)
  for ini in /etc/php/*/cli/php.ini /etc/php/*/apache2/php.ini; do
    [[ -f "$ini" ]] || continue
    sed -i -E "s|^;?date.timezone =.*|date.timezone = ${ZBX_TIMEZONE}|" "$ini"
  done

  systemctl enable apache2
  systemctl restart apache2
  success "Apache + PHP configurados"
}

# --- SERVIÇOS ----------------------------------------------------------------
enable_services() {
  step "Habilitando e iniciando serviços"
  systemctl enable zabbix-server zabbix-agent2 apache2
  systemctl restart zabbix-server
  systemctl restart zabbix-agent2
  systemctl restart apache2

  sleep 3
  for svc in postgresql zabbix-server zabbix-agent2 apache2; do
    if systemctl is-active --quiet "$svc"; then
      success "${svc}: ativo"
    else
      warn   "${svc}: NÃO está ativo — verifique 'journalctl -u ${svc}'"
    fi
  done
}

# --- SEGURANÇA (LEVE) --------------------------------------------------------
basic_hardening() {
  step "Hardening básico"

  # PG só escuta localhost — Zabbix server fala com PG via 127.0.0.1
  if grep -qE "^[[:space:]]*#?listen_addresses" "$PG_MAIN"; then
    sed -i -E "s|^[[:space:]]*#?listen_addresses.*|listen_addresses = 'localhost'|" "$PG_MAIN"
  else
    echo "listen_addresses = 'localhost'" >> "$PG_MAIN"
  fi

  # Garantir scram-sha-256 para o user zabbix em 127.0.0.1
  if ! grep -qE "^host[[:space:]]+${ZBX_DB_NAME}[[:space:]]+${ZBX_DB_USER}[[:space:]]+127\.0\.0\.1/32" "$PG_HBA"; then
    echo "host ${ZBX_DB_NAME} ${ZBX_DB_USER} 127.0.0.1/32 scram-sha-256" >> "$PG_HBA"
  fi
  systemctl reload postgresql || systemctl restart postgresql

  # UFW se já estiver instalado — não instala por padrão (mexer em firewall no host por sua conta)
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp     comment "Zabbix HTTP"   || true
    ufw allow 10050/tcp  comment "Zabbix agent"  || true
    ufw allow 10051/tcp  comment "Zabbix trapper" || true
  fi
  success "Hardening aplicado"
}

# --- SUMÁRIO -----------------------------------------------------------------
print_summary() {
  step "Instalação concluída!"
  local IP
  IP=$(hostname -I | awk '{print $1}')
  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║          ZABBIX 7.0 LTS INSTALADO COM             ║${NC}"
  echo -e "${GREEN}${BOLD}║                    SUCESSO!                       ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}URL:${NC}            http://${IP}/zabbix/"
  if [[ -n "$ZBX_ADMIN_PASS" ]]; then
    echo -e "  ${BOLD}Login:${NC}          Admin / ${ZBX_ADMIN_PASS}"
  else
    echo -e "  ${BOLD}Login inicial:${NC}  Admin / zabbix"
    echo -e "  ${RED}TROQUE a senha do Admin no primeiro login.${NC}"
  fi
  echo ""
  echo -e "  ${BOLD}BD:${NC}             ${ZBX_DB_NAME}"
  echo -e "  ${BOLD}User BD:${NC}        ${ZBX_DB_USER}"
  echo -e "  ${BOLD}Pass BD:${NC}        ${ZBX_DB_PASS}"
  echo ""
  echo -e "  ${BOLD}Config salvo:${NC}   ${CONFIG_FILE}"
  echo -e "  ${BOLD}Log:${NC}            ${LOG_FILE}"
  echo ""
  echo -e "${CYAN}Próximos passos:${NC}"
  echo -e "  1. Aceder a http://${IP}/zabbix/ e fazer login"
  echo -e "     (wizard JÁ ESTÁ saltado — frontend pré-configurado)"
  echo -e "  2. Ativar o host 'Zabbix server' (vem desativado): Configuration → Hosts"
  echo -e "  3. Ativar compressão TimescaleDB:"
  echo -e "     Administration → General → Housekeeping → 'Override item history/trend period'"
  echo -e "  4. Para Azure Monitor: Configuration → Hosts → criar host com template"
  echo -e "     'Azure by HTTP' (já vem com o Zabbix 7.0)"
  echo ""
}

# --- MAIN --------------------------------------------------------------------
main() {
  # log de tudo
  exec > >(tee -a "$LOG_FILE") 2>&1
  check_root
  detect_os

  install_base_packages
  add_zabbix_repo
  add_timescaledb_repo
  apt_update

  install_postgres_and_timescale
  install_zabbix_packages

  tune_postgres
  create_zabbix_db
  import_zabbix_schema
  set_admin_password
  apply_timescale_hypertables

  configure_zabbix_server
  configure_zabbix_agent2
  generate_locales
  configure_apache_php
  configure_zabbix_frontend

  basic_hardening
  enable_services

  save_config
  print_summary
}

main "$@"
