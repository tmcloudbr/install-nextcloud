#!/usr/bin/env bash
#
# install.sh — Instalador automatizado do Nextcloud
#
# Detecta a distribuição/versão do Linux e instala o Nextcloud com
# Apache + PHP-FPM + MariaDB + Redis, usando o gerenciador de pacotes
# e os repositórios corretos para cada sistema.
#
# Sistemas suportados:
#   - Debian 12 (bookworm), 13 (trixie)
#   - Ubuntu 22.04, 24.04, 26.04
#   - RHEL / Rocky Linux / AlmaLinux / CentOS Stream / Oracle Linux 8, 9, 10
#   - Fedora 41+
#
# Uso (como root):
#   curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh | sudo bash
#   curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh | sudo bash -s -- --domain cloud.exemplo.com.br
#
# Execute com --help para ver todas as opções.
#
# Todo o código fica dentro de funções e só é executado na última linha:
# se o download via curl for interrompido no meio, nada é executado.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Este script requer bash. Use: curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh | sudo bash" >&2
    exit 1
fi

set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Configuração padrão (pode ser sobrescrita por variáveis de ambiente ou flags)
# ---------------------------------------------------------------------------
NC_VERSION="${NC_VERSION:-latest}"
NC_DOMAIN="${NC_DOMAIN:-}"
NC_ADMIN_USER="${NC_ADMIN_USER:-admin}"
NC_ADMIN_PASS="${NC_ADMIN_PASS:-}"
NC_INSTALL_DIR="${NC_INSTALL_DIR:-/var/www/nextcloud}"
NC_DATA_DIR="${NC_DATA_DIR:-/var/www/nextcloud-data}"
NC_DB_NAME="${NC_DB_NAME:-nextcloud}"
NC_DB_USER="${NC_DB_USER:-nextcloud}"
NC_DB_PASS="${NC_DB_PASS:-}"
NC_TIMEZONE="${NC_TIMEZONE:-America/Sao_Paulo}"
NC_PHONE_REGION="${NC_PHONE_REGION:-BR}"
NC_LETSENCRYPT="${NC_LETSENCRYPT:-no}"
NC_EMAIL="${NC_EMAIL:-}"
NC_PHP_VERSION="${NC_PHP_VERSION:-}"     # vazio = automático
NC_FORCE="${NC_FORCE:-no}"
NC_CHECK_ONLY="${NC_CHECK_ONLY:-no}"

# Faixa de versões do PHP aceitas pelo Nextcloud. Por padrão é lida do
# lib/versioncheck.php da versão escolhida; estes valores são o fallback.
PHP_MIN="${PHP_MIN:-}"
PHP_MAX="${PHP_MAX:-}"
PHP_MIN_DEFAULT="8.3"
PHP_MAX_DEFAULT="8.4"
# Versão instalada quando a do sistema não está na faixa (vazio = automático)
PHP_TARGET="${PHP_TARGET:-}"
PHP_PREFERRED="8.4"

PHP_MEMORY_LIMIT="512M"
UPLOAD_MAX="16G"

LOG_FILE="/var/log/nextcloud-install.log"
CREDENTIALS_FILE="/root/nextcloud-credentials.txt"
NC_DOWNLOAD_BASE="https://download.nextcloud.com/server/releases"

# Preenchidas durante a execução
OS_ID="" OS_VERSION="" OS_MAJOR="" OS_NAME="" OS_CODENAME="" FAMILY=""
PHP_V="" PHP_BIN="" WEB_USER="" APACHE_SVC="" FPM_SVC="" FPM_POOL=""
REDIS_SVC="" DB_CLI="" SERVER_IP="" WORK_DIR=""
PHP_INI_FILES=()
MARIADB_CNF=""

# ---------------------------------------------------------------------------
# Utilitários
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
    C_BLUE=$'\033[1;34m' C_GREEN=$'\033[1;32m' C_YELLOW=$'\033[1;33m' C_RED=$'\033[1;31m' C_RESET=$'\033[0m'
else
    C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_RESET=""
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s  ✔%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  ⚠ %s%s\n' "$C_YELLOW" "$*" "$C_RESET" >&2; }
die()  { printf '%s  ✖ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

on_error() {
    local code=$? line=$1 cmd=$2
    printf '%s  ✖ Falha (código %s) na linha %s: %s%s\n' "$C_RED" "$code" "$line" "$cmd" "$C_RESET" >&2
    printf '    Veja o log completo em %s\n' "$LOG_FILE" >&2
    exit "$code"
}

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

# $1 >= $2 (comparação de versões)
ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]; }

php_in_range() { [ -n "$1" ] && ver_ge "$1" "$PHP_MIN" && ver_ge "$PHP_MAX" "$1"; }

random_pass() {
    local len="${1:-24}" p=""
    p="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 2048 /dev/urandom) | head -c "$len")" || true
    printf '%s' "$p"
}

is_ip() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ || "$1" == *:* ]]; }

selinux_enabled() { command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; }

usage() {
    cat <<EOF
Instalador do Nextcloud (Apache + PHP-FPM + MariaDB + Redis)

Uso:
  curl -fsSL https://raw.githubusercontent.com/tmcloudbr/install-nextcloud/main/install.sh | sudo bash -s -- [opções]
  sudo bash install.sh [opções]

Opções:
  --domain DOMINIO        Domínio/hostname de acesso (padrão: IP do servidor)
  --admin-user USUARIO    Usuário administrador (padrão: admin)
  --admin-pass SENHA      Senha do administrador (padrão: gerada aleatoriamente)
  --db-name NOME          Nome do banco de dados (padrão: nextcloud)
  --db-user USUARIO       Usuário do banco de dados (padrão: nextcloud)
  --db-pass SENHA         Senha do banco de dados (padrão: gerada aleatoriamente)
  --install-dir DIR       Diretório da aplicação (padrão: /var/www/nextcloud)
  --data-dir DIR          Diretório de dados (padrão: /var/www/nextcloud-data)
  --version VERSAO        Versão do Nextcloud, ex.: 35.0.2 (padrão: latest)
  --php-version X.Y       Força uma versão do PHP (padrão: automático)
  --timezone TZ           Fuso horário (padrão: America/Sao_Paulo)
  --phone-region XX       Região telefônica padrão ISO 3166-1 (padrão: BR)
  --letsencrypt           Emite certificado HTTPS com Let's Encrypt (requer --domain e --email)
  --email EMAIL           E-mail para o Let's Encrypt
  --check                 Apenas detecta o sistema e mostra o plano, sem instalar nada
  --force                 Continua mesmo em distribuição/versão não suportada
  -h, --help              Mostra esta ajuda

Todas as opções também podem ser passadas por variável de ambiente
(NC_DOMAIN, NC_ADMIN_PASS, NC_VERSION, NC_LETSENCRYPT=yes, ...).
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --domain)       NC_DOMAIN="${2:?--domain requer um valor}"; shift 2 ;;
            --admin-user)   NC_ADMIN_USER="${2:?--admin-user requer um valor}"; shift 2 ;;
            --admin-pass)   NC_ADMIN_PASS="${2:?--admin-pass requer um valor}"; shift 2 ;;
            --db-name)      NC_DB_NAME="${2:?--db-name requer um valor}"; shift 2 ;;
            --db-user)      NC_DB_USER="${2:?--db-user requer um valor}"; shift 2 ;;
            --db-pass)      NC_DB_PASS="${2:?--db-pass requer um valor}"; shift 2 ;;
            --install-dir)  NC_INSTALL_DIR="${2:?--install-dir requer um valor}"; shift 2 ;;
            --data-dir)     NC_DATA_DIR="${2:?--data-dir requer um valor}"; shift 2 ;;
            --version)      NC_VERSION="${2:?--version requer um valor}"; shift 2 ;;
            --php-version)  NC_PHP_VERSION="${2:?--php-version requer um valor}"; shift 2 ;;
            --timezone)     NC_TIMEZONE="${2:?--timezone requer um valor}"; shift 2 ;;
            --phone-region) NC_PHONE_REGION="${2:?--phone-region requer um valor}"; shift 2 ;;
            --email)        NC_EMAIL="${2:?--email requer um valor}"; shift 2 ;;
            --letsencrypt)  NC_LETSENCRYPT="yes"; shift ;;
            --check)        NC_CHECK_ONLY="yes"; shift ;;
            --force)        NC_FORCE="yes"; shift ;;
            -h|--help)      usage; exit 0 ;;
            *) die "Opção desconhecida: $1 (use --help)" ;;
        esac
    done

    NC_INSTALL_DIR="${NC_INSTALL_DIR%/}"
    NC_DATA_DIR="${NC_DATA_DIR%/}"

    [[ "$NC_DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "--db-name aceita apenas letras, números e _"
    [[ "$NC_DB_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "--db-user aceita apenas letras, números e _"
    if [ -n "$NC_DB_PASS" ] && [[ ! "$NC_DB_PASS" =~ ^[A-Za-z0-9._@%+=-]+$ ]]; then
        die "--db-pass contém caracteres não permitidos (use letras, números e . _ @ % + = -)"
    fi
    if [ "$NC_VERSION" != "latest" ] && [[ ! "$NC_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "--version deve estar no formato X.Y.Z (ex.: 35.0.2) ou ser 'latest'"
    fi
    if [ -n "$NC_PHP_VERSION" ] && [[ ! "$NC_PHP_VERSION" =~ ^[0-9]+\.[0-9]+$ ]]; then
        die "--php-version deve estar no formato X.Y (ex.: 8.3)"
    fi
    if [ "$NC_LETSENCRYPT" = "yes" ]; then
        [ -n "$NC_DOMAIN" ] || die "--letsencrypt requer --domain"
        is_ip "$NC_DOMAIN" && die "--letsencrypt requer um domínio (não um IP)"
        [ -n "$NC_EMAIL" ] || die "--letsencrypt requer --email"
    fi
}

# ---------------------------------------------------------------------------
# Detecção do sistema operacional
# ---------------------------------------------------------------------------
unsupported() {
    if [ "$NC_FORCE" = "yes" ]; then
        warn "$1 — continuando por causa de --force."
    else
        die "$1. Use --force para tentar mesmo assim."
    fi
}

detect_os() {
    [ -r /etc/os-release ] || die "Não foi possível identificar o sistema (/etc/os-release ausente)."
    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID,,}"
    OS_VERSION="${VERSION_ID:-}"
    OS_MAJOR="${OS_VERSION%%.*}"
    OS_NAME="${PRETTY_NAME:-$OS_ID $OS_VERSION}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    local like=" ${ID_LIKE:-} "

    case "$OS_ID" in
        debian)
            FAMILY="debian"
            case "$OS_MAJOR" in
                12|13) ;;
                *) unsupported "Debian ${OS_VERSION:-desconhecido} não é suportado (suportados: 12, 13)" ;;
            esac
            ;;
        ubuntu)
            FAMILY="debian"
            case "$OS_VERSION" in
                22.04|24.04|26.04) ;;
                *) unsupported "Ubuntu ${OS_VERSION:-desconhecido} não é suportado (suportados: 22.04, 24.04, 26.04)" ;;
            esac
            ;;
        rhel|rocky|almalinux|centos|ol)
            FAMILY="rhel"
            case "$OS_MAJOR" in
                8|9|10) ;;
                *) unsupported "$OS_NAME não é suportado (suportadas as versões 8, 9 e 10)" ;;
            esac
            ;;
        fedora)
            FAMILY="fedora"
            if [[ ! "$OS_MAJOR" =~ ^[0-9]+$ ]] || [ "$OS_MAJOR" -lt 41 ]; then
                unsupported "Fedora ${OS_VERSION:-desconhecido} não é suportado (suportado: 41 ou superior)"
            fi
            ;;
        *)
            case "$like" in
                *" ubuntu "*|*" debian "*)            FAMILY="debian" ;;
                *" rhel "*|*" centos "*)              FAMILY="rhel" ;;
                *" fedora "*)                         FAMILY="fedora" ;;
                *) die "Distribuição não suportada: $OS_NAME" ;;
            esac
            unsupported "$OS_NAME é um derivado de ${ID_LIKE} e não foi testado"
            # Derivados do Ubuntu (ex.: Mint) usam o codinome do Ubuntu base
            if [ "$FAMILY" = "debian" ] && [ -n "${UBUNTU_CODENAME:-}" ]; then
                OS_ID="ubuntu"
                OS_CODENAME="$UBUNTU_CODENAME"
            fi
            ;;
    esac

    if [ "$FAMILY" = "rhel" ] && [[ ! "$OS_MAJOR" =~ ^[0-9]+$ ]]; then
        die "Não foi possível determinar a versão principal de $OS_NAME"
    fi

    ok "Sistema detectado: $OS_NAME (família: $FAMILY)"
}

# ---------------------------------------------------------------------------
# Verificações iniciais
# ---------------------------------------------------------------------------
preflight() {
    log "Verificando pré-requisitos"

    case "$(uname -m)" in
        x86_64|aarch64) ;;
        *) unsupported "Arquitetura $(uname -m) não suportada (suportadas: x86_64, aarch64)" ;;
    esac

    local mem_mb
    mem_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [ "$mem_mb" -lt 1024 ]; then
        warn "Apenas ${mem_mb} MB de RAM. O recomendado é pelo menos 2 GB."
    fi

    local parent free_mb
    parent="$(dirname "$NC_INSTALL_DIR")"
    while [ ! -d "$parent" ]; do parent="$(dirname "$parent")"; done
    free_mb=$(df -Pm "$parent" | awk 'NR==2 {print $4}')
    if [ "$free_mb" -lt 2048 ]; then
        warn "Apenas ${free_mb} MB livres em $parent. Recomendado: pelo menos 2 GB + espaço para os dados."
    fi

    if [ -f "$NC_INSTALL_DIR/config/config.php" ]; then
        die "Já existe uma instalação do Nextcloud em $NC_INSTALL_DIR. Abortando para não sobrescrever."
    fi
    if [ -d "$NC_INSTALL_DIR" ] && [ -n "$(ls -A "$NC_INSTALL_DIR" 2>/dev/null)" ]; then
        die "O diretório $NC_INSTALL_DIR já existe e não está vazio."
    fi
    if [ -d "$NC_DATA_DIR" ] && [ -n "$(ls -A "$NC_DATA_DIR" 2>/dev/null)" ]; then
        die "O diretório de dados $NC_DATA_DIR já existe e não está vazio."
    fi

    if ! curl -fsSI --max-time 15 "$NC_DOWNLOAD_BASE/" >/dev/null 2>&1; then
        die "Sem acesso a $NC_DOWNLOAD_BASE. Verifique a conexão com a internet/DNS/proxy."
    fi

    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')" || true
    [ -n "$SERVER_IP" ] || SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || true
    [ -n "$SERVER_IP" ] || SERVER_IP="127.0.0.1"
    [ -n "$NC_DOMAIN" ] || NC_DOMAIN="$SERVER_IP"

    [ -n "$NC_ADMIN_PASS" ] || NC_ADMIN_PASS="$(random_pass 20)"
    [ -n "$NC_DB_PASS" ]    || NC_DB_PASS="$(random_pass 32)"

    ok "Pré-requisitos verificados"
}

# ---------------------------------------------------------------------------
# Versão do Nextcloud e faixa de PHP exigida
# ---------------------------------------------------------------------------
resolve_nc_version() {
    if [ "$NC_VERSION" = "latest" ]; then
        local listing v
        listing="$(curl -fsSL --retry 3 "$NC_DOWNLOAD_BASE/")" || die "Não foi possível listar $NC_DOWNLOAD_BASE"
        v="$(grep -oE 'nextcloud-[0-9]+\.[0-9]+\.[0-9]+\.tar\.bz2"' <<< "$listing" \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -uV | tail -n1 || true)"
        [ -n "$v" ] || die "Não foi possível determinar a versão mais recente do Nextcloud"
        NC_VERSION="$v"
    elif ! curl -fsSI --max-time 15 "$NC_DOWNLOAD_BASE/nextcloud-${NC_VERSION}.tar.bz2" >/dev/null 2>&1; then
        die "Nextcloud $NC_VERSION não encontrado em $NC_DOWNLOAD_BASE"
    fi
    ok "Nextcloud $NC_VERSION"
}

# Lê a faixa de PHP de um lib/versioncheck.php (stdin): define _MIN e _MAX
#   if (PHP_VERSION_ID < 80300)  -> mínimo 8.3
#   if (PHP_VERSION_ID >= 80600) -> máximo 8.5
parse_versioncheck() {
    local src lo hi
    src="$(cat)"
    lo="$(grep -oE 'PHP_VERSION_ID < [0-9]{5}' <<< "$src" | grep -oE '[0-9]{5}' | head -n1 || true)"
    hi="$(grep -oE 'PHP_VERSION_ID >= [0-9]{5}' <<< "$src" | grep -oE '[0-9]{5}' | head -n1 || true)"
    [ -n "$lo" ] && [ -n "$hi" ] || return 1
    _MIN="$((lo / 10000)).$(((lo / 100) % 100))"
    # máximo exclusivo -> maior versão menor aceita
    if [ $(((hi / 100) % 100)) -gt 0 ]; then
        _MAX="$((hi / 10000)).$((((hi / 100) % 100) - 1))"
    else
        return 1
    fi
}

detect_php_range() {
    local _MIN="" _MAX="" src
    if [ -n "$PHP_MIN" ] && [ -n "$PHP_MAX" ]; then
        ok "Faixa de PHP definida manualmente: $PHP_MIN–$PHP_MAX"
    elif src="$(curl -fsSL --max-time 20 --retry 2 \
                "https://raw.githubusercontent.com/nextcloud/server/v${NC_VERSION}/lib/versioncheck.php")" \
            && parse_versioncheck <<< "$src"; then
        PHP_MIN="${PHP_MIN:-$_MIN}"
        PHP_MAX="${PHP_MAX:-$_MAX}"
        ok "Nextcloud $NC_VERSION aceita PHP $PHP_MIN–$PHP_MAX"
    else
        PHP_MIN="${PHP_MIN:-$PHP_MIN_DEFAULT}"
        PHP_MAX="${PHP_MAX:-$PHP_MAX_DEFAULT}"
        warn "Não foi possível consultar os requisitos do Nextcloud $NC_VERSION; usando PHP $PHP_MIN–$PHP_MAX (será validado após o download)"
    fi
    if [ -z "$PHP_TARGET" ]; then
        if php_in_range "$PHP_PREFERRED"; then PHP_TARGET="$PHP_PREFERRED"; else PHP_TARGET="$PHP_MAX"; fi
    fi
}

# ---------------------------------------------------------------------------
# Família Debian / Ubuntu (apt)
# ---------------------------------------------------------------------------
apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# Obs.: evitar "cmd | grep -q" — com pipefail, o SIGPIPE do cmd faz o teste falhar.
apt_has() {
    local out
    out="$(apt-cache policy "$1" 2>/dev/null)" || return 1
    [[ "$out" =~ Candidate:\ [0-9] ]]
}

# Instala o primeiro pacote disponível da lista. Retorna 1 se nenhum existir.
apt_install_one_of() {
    local p
    for p in "$@"; do
        if apt_has "$p"; then apt_install "$p" && return 0; fi
    done
    return 1
}

apt_native_php() {
    apt-cache policy php-fpm 2>/dev/null \
        | awk '/Candidate:/ {print $2}' | sed -E 's/^[0-9]+://' | grep -oE '^[0-9]+\.[0-9]+' || true
}

add_php_repo_debian() {
    if [ "$OS_ID" = "ubuntu" ]; then
        log "Adicionando o PPA ondrej/php"
        apt_install software-properties-common
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    else
        log "Adicionando o repositório packages.sury.org/php"
        [ -n "$OS_CODENAME" ] || die "Codinome da versão do Debian não encontrado em /etc/os-release"
        curl -fsSL -o "$WORK_DIR/debsuryorg-archive-keyring.deb" \
            https://packages.sury.org/debsuryorg-archive-keyring.deb
        dpkg -i "$WORK_DIR/debsuryorg-archive-keyring.deb"
        echo "deb [signed-by=/usr/share/keyrings/debsuryorg-archive-keyring.gpg] https://packages.sury.org/php/ $OS_CODENAME main" \
            > /etc/apt/sources.list.d/php-sury.list
    fi
    apt-get update -qq
}

plan_debian() {
    apt-get update -qq
    local native
    native="$(apt_native_php)"
    if [ -n "$NC_PHP_VERSION" ]; then
        PHP_V="$NC_PHP_VERSION"
    elif php_in_range "$native"; then
        PHP_V="$native"
    else
        PHP_V="$PHP_TARGET"
    fi
    if [ "$PHP_V" = "$native" ]; then
        ok "PHP $PHP_V dos repositórios oficiais de $OS_NAME"
    else
        ok "PHP $PHP_V via repositório externo (o sistema oferece PHP ${native:-nenhum}; aceito: $PHP_MIN–$PHP_MAX)"
    fi
}

install_debian() {
    log "Instalando pacotes com apt"
    apt_install ca-certificates curl bzip2 tar gnupg tzdata

    if ! apt_has "php${PHP_V}-fpm"; then
        add_php_repo_debian
        apt_has "php${PHP_V}-fpm" || die "PHP $PHP_V não está disponível para $OS_NAME"
    fi

    local v="php${PHP_V}"
    apt_install apache2 mariadb-server \
        "$v-fpm" "$v-cli" "$v-common" "$v-mysql" "$v-gd" "$v-curl" "$v-mbstring" \
        "$v-intl" "$v-xml" "$v-zip" "$v-bcmath" "$v-gmp" "$v-bz2"

    apt_install_one_of redis-server valkey-server || die "Nenhum pacote Redis/Valkey disponível"

    # Extensões recomendadas (não impedem a instalação)
    apt_install_one_of "$v-opcache"            || warn "OPcache não encontrado como pacote separado (pode já estar embutido)"
    apt_install_one_of "$v-apcu" php-apcu      || warn "APCu indisponível — cache local desativado"
    apt_install_one_of "$v-redis" php-redis    || warn "php-redis indisponível — cache/locking via Redis desativado"
    apt_install_one_of "$v-imagick" php-imagick || warn "Imagick indisponível — miniaturas limitadas"

    WEB_USER="www-data"
    APACHE_SVC="apache2"
    FPM_SVC="php${PHP_V}-fpm"
    FPM_POOL="/etc/php/${PHP_V}/fpm/pool.d/www.conf"
    PHP_BIN="/usr/bin/php${PHP_V}"
    PHP_INI_FILES=("/etc/php/${PHP_V}/fpm/conf.d/90-nextcloud.ini" "/etc/php/${PHP_V}/cli/conf.d/90-nextcloud.ini")
    MARIADB_CNF="/etc/mysql/mariadb.conf.d/90-nextcloud.cnf"
    ok "Pacotes instalados"
}

configure_apache_debian() {
    log "Configurando Apache"
    local f
    for f in /etc/apache2/mods-enabled/php*.load; do
        if [ -e "$f" ]; then a2dismod -q "$(basename "$f" .load)"; fi
    done
    a2dismod -q mpm_prefork >/dev/null 2>&1 || true
    a2enmod -q mpm_event proxy_fcgi setenvif rewrite headers env dir mime ssl
    a2enconf -q "php${PHP_V}-fpm"
    write_vhost "/etc/apache2/sites-available/nextcloud.conf"
    a2ensite -q nextcloud
    a2dissite -q 000-default >/dev/null 2>&1 || true
    apache2ctl configtest
    ok "Apache configurado"
}

# ---------------------------------------------------------------------------
# Família RHEL (Rocky, Alma, CentOS Stream, Oracle) e Fedora (dnf)
# ---------------------------------------------------------------------------
# Repete uma vez limpando os metadados (espelhos do EPEL/Remi às vezes falham)
dnf_install() {
    dnf install -y -q "$@" && return 0
    warn "dnf falhou; limpando metadados e tentando novamente"
    dnf clean metadata -q >/dev/null 2>&1 || true
    sleep 5
    dnf install -y -q "$@"
}

dnf_install_one_of() {
    local p
    for p in "$@"; do
        dnf_install "$p" >/dev/null 2>&1 && { ok "Instalado: $p"; return 0; }
    done
    return 1
}

dnf_native_php() {
    dnf -q repoquery --qf '%{version}\n' php-cli 2>/dev/null \
        | grep -oE '^[0-9]+\.[0-9]+' | sort -V | tail -n1 || true
}

enable_epel_crb() {
    local m="$OS_MAJOR" arch
    arch="$(uname -m)"
    log "Habilitando EPEL e CodeReady Builder/CRB"
    dnf_install dnf-plugins-core || true

    if ! rpm -q epel-release >/dev/null 2>&1 && ! rpm -q oracle-epel-release-el"$m" >/dev/null 2>&1; then
        case "$OS_ID" in
            ol) dnf_install "oracle-epel-release-el$m" ;;
            rhel) dnf_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$m.noarch.rpm" ;;
            *) dnf_install epel-release || dnf_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$m.noarch.rpm" ;;
        esac
    fi

    case "$OS_ID" in
        rhel) subscription-manager repos --enable "codeready-builder-for-rhel-$m-$arch-rpms" \
                  || warn "Não foi possível habilitar o CodeReady Builder (assinatura ativa?)" ;;
        ol)   dnf config-manager --set-enabled "ol${m}_codeready_builder" || warn "Não foi possível habilitar o CodeReady Builder" ;;
        *)
            if command -v crb >/dev/null 2>&1; then
                crb enable || warn "Não foi possível habilitar o CRB"
            elif [ "$m" = "8" ]; then
                dnf config-manager --set-enabled powertools || warn "Não foi possível habilitar o PowerTools"
            else
                dnf config-manager --set-enabled crb || warn "Não foi possível habilitar o CRB"
            fi
            ;;
    esac
}

plan_rhel() {
    if [ "$FAMILY" = "rhel" ] && [ "$OS_MAJOR" -lt 10 ]; then
        # EL 8/9: PHP do sistema é antigo/sem extensões PECL -> Remi (módulo)
        PHP_V="${NC_PHP_VERSION:-$PHP_TARGET}"
        ok "PHP $PHP_V via repositório Remi (módulo php:remi-$PHP_V)"
        return
    fi
    # EL 10 e Fedora: PHP do sistema (sem módulos); Remi/Fedora fornecem PECL
    local native
    native="$(dnf_native_php)"
    if [ -n "$NC_PHP_VERSION" ] && [ "$NC_PHP_VERSION" != "$native" ]; then
        die "Em $OS_NAME só é suportado o PHP do sistema (${native:-desconhecido}); --php-version $NC_PHP_VERSION não é possível"
    fi
    if ! php_in_range "$native"; then
        unsupported "PHP ${native:-desconhecido} de $OS_NAME fora da faixa suportada ($PHP_MIN–$PHP_MAX)"
    fi
    PHP_V="${native:-$PHP_TARGET}"
    ok "PHP $PHP_V dos repositórios oficiais de $OS_NAME"
}

install_rhel() {
    log "Instalando pacotes com dnf"

    if [ "$FAMILY" = "rhel" ]; then
        enable_epel_crb
        log "Adicionando o repositório Remi"
        rpm -q remi-release >/dev/null 2>&1 \
            || dnf_install "https://rpms.remirepo.net/enterprise/remi-release-$OS_MAJOR.rpm"

        if [ "$OS_MAJOR" -lt 10 ]; then
            dnf module reset -y -q php
            dnf module enable -y -q "php:remi-$PHP_V" || die "Módulo php:remi-$PHP_V indisponível"
            # MariaDB 10.11 (o padrão do EL 8/9 é antigo demais)
            dnf module reset -y -q mariadb >/dev/null 2>&1 || true
            if dnf module enable -y -q mariadb:10.11 >/dev/null 2>&1; then
                ok "MariaDB 10.11 (módulo)"
            else
                warn "Módulo mariadb:10.11 indisponível — usando a versão padrão do sistema"
            fi
        fi
    fi

    # curl não entra: já existe (o script roda via curl) e no EL 9 conflita com curl-minimal
    dnf_install bzip2 tar tzdata openssl util-linux httpd mod_ssl mariadb-server \
        php php-fpm php-cli php-common php-mysqlnd php-gd php-mbstring php-intl \
        php-xml php-process php-bcmath php-gmp php-opcache php-pdo

    dnf_install_one_of php-pecl-zip php-zip || die "Extensão PHP zip indisponível"
    dnf_install_one_of redis valkey         || die "Nenhum pacote Redis/Valkey disponível"

    dnf_install_one_of php-sodium                                  || warn "php-sodium indisponível"
    dnf_install_one_of php-pecl-apcu                               || warn "APCu indisponível — cache local desativado"
    dnf_install_one_of php-pecl-redis6 php-pecl-redis5 php-redis   || warn "php-redis indisponível — cache/locking via Redis desativado"
    dnf_install_one_of php-pecl-imagick-im7 php-pecl-imagick       || warn "Imagick indisponível — miniaturas limitadas"

    if selinux_enabled; then
        dnf_install policycoreutils-python-utils
    fi

    WEB_USER="apache"
    APACHE_SVC="httpd"
    FPM_SVC="php-fpm"
    FPM_POOL="/etc/php-fpm.d/www.conf"
    PHP_BIN="/usr/bin/php"
    PHP_INI_FILES=("/etc/php.d/90-nextcloud.ini")
    MARIADB_CNF="/etc/my.cnf.d/90-nextcloud.cnf"
    ok "Pacotes instalados"
}

configure_apache_rhel() {
    log "Configurando Apache"
    # Esvazia a página de boas-vindas (manter o arquivo evita que volte em atualizações)
    if [ -f /etc/httpd/conf.d/welcome.conf ]; then : > /etc/httpd/conf.d/welcome.conf; fi
    write_vhost "/etc/httpd/conf.d/nextcloud.conf"
    # O mod_ssl só gera o certificado padrão no primeiro start do httpd;
    # sem ele o configtest falha.
    local crt=/etc/pki/tls/certs/localhost.crt key=/etc/pki/tls/private/localhost.key
    if [ -f /etc/httpd/conf.d/ssl.conf ] && [ ! -s "$crt" ]; then
        if [ -x /usr/libexec/httpd-ssl-gencerts ]; then
            /usr/libexec/httpd-ssl-gencerts
        fi
        if [ ! -s "$crt" ]; then
            openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
                -subj "/CN=${NC_DOMAIN}" -keyout "$key" -out "$crt" >/dev/null 2>&1
            chmod 600 "$key"
        fi
    fi
    apachectl configtest
    ok "Apache configurado"
}

configure_selinux() {
    selinux_enabled || return 0
    log "Configurando contextos do SELinux"
    local ctx
    semanage fcontext -a -t httpd_sys_content_t "$NC_INSTALL_DIR(/.*)?" 2>/dev/null \
        || semanage fcontext -m -t httpd_sys_content_t "$NC_INSTALL_DIR(/.*)?"
    for ctx in "$NC_DATA_DIR(/.*)?" \
               "$NC_INSTALL_DIR/config(/.*)?" \
               "$NC_INSTALL_DIR/apps(/.*)?" \
               "$NC_INSTALL_DIR/.htaccess" \
               "$NC_INSTALL_DIR/.user.ini" \
               "$NC_INSTALL_DIR/3rdparty/aws/aws-sdk-php/src/data/logs(/.*)?"; do
        semanage fcontext -a -t httpd_sys_rw_content_t "$ctx" 2>/dev/null \
            || semanage fcontext -m -t httpd_sys_rw_content_t "$ctx"
    done
    restorecon -R "$NC_INSTALL_DIR" "$NC_DATA_DIR"
    setsebool -P httpd_can_network_connect=1 httpd_can_network_connect_db=1 httpd_can_sendmail=1
    ok "SELinux configurado"
}

# ---------------------------------------------------------------------------
# Configuração comum
# ---------------------------------------------------------------------------
write_vhost() {
    cat > "$1" <<EOF
# Gerado pelo instalador do Nextcloud
<VirtualHost *:80>
    ServerName ${NC_DOMAIN}
    DocumentRoot ${NC_INSTALL_DIR}

    <Directory ${NC_INSTALL_DIR}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF
    # APACHE_LOG_DIR só existe no Debian/Ubuntu
    if [ "$FAMILY" != "debian" ]; then
        # shellcheck disable=SC2016  # o literal ${APACHE_LOG_DIR} é intencional
        sed -i 's|\${APACHE_LOG_DIR}|logs|g' "$1"
    fi
}

configure_php() {
    log "Configurando PHP $PHP_V"
    # Validado só aqui: o tzdata é instalado junto com os pacotes
    if [ ! -e "/usr/share/zoneinfo/$NC_TIMEZONE" ]; then
        warn "Fuso horário '$NC_TIMEZONE' inválido, usando UTC."
        NC_TIMEZONE="UTC"
    fi
    local f
    for f in "${PHP_INI_FILES[@]}"; do
        mkdir -p "$(dirname "$f")"
        cat > "$f" <<EOF
; Gerado pelo instalador do Nextcloud
memory_limit = ${PHP_MEMORY_LIMIT}
upload_max_filesize = ${UPLOAD_MAX}
post_max_size = ${UPLOAD_MAX}
max_execution_time = 3600
max_input_time = 3600
output_buffering = 0
date.timezone = ${NC_TIMEZONE}

opcache.enable = 1
opcache.interned_strings_buffer = 32
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 256
opcache.save_comments = 1
opcache.revalidate_freq = 60

apc.enable_cli = 1
EOF
    done

    [ -f "$FPM_POOL" ] || die "Pool do PHP-FPM não encontrado: $FPM_POOL"
    sed -i -E \
        -e 's|^;?env\[PATH\].*|env[PATH] = /usr/local/bin:/usr/bin:/bin|' \
        -e 's|^;?pm\.max_children\s*=.*|pm.max_children = 32|' \
        -e 's|^;?pm\.start_servers\s*=.*|pm.start_servers = 8|' \
        -e 's|^;?pm\.min_spare_servers\s*=.*|pm.min_spare_servers = 4|' \
        -e 's|^;?pm\.max_spare_servers\s*=.*|pm.max_spare_servers = 16|' \
        "$FPM_POOL"
    grep -q '^env\[PATH\]' "$FPM_POOL" || echo 'env[PATH] = /usr/local/bin:/usr/bin:/bin' >> "$FPM_POOL"

    local real_v
    real_v="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
    php_in_range "$real_v" || unsupported "PHP instalado ($real_v) fora da faixa suportada ($PHP_MIN–$PHP_MAX)"
    PHP_V="$real_v"

    systemctl enable --now "$FPM_SVC"
    systemctl restart "$FPM_SVC"
    ok "PHP $PHP_V configurado ($FPM_SVC)"
}

configure_mariadb() {
    log "Configurando MariaDB"
    mkdir -p "$(dirname "$MARIADB_CNF")"
    cat > "$MARIADB_CNF" <<'EOF'
# Gerado pelo instalador do Nextcloud
[mysqld]
transaction_isolation = READ-COMMITTED
binlog_format = ROW
innodb_file_per_table = 1
character_set_server = utf8mb4
collation_server = utf8mb4_general_ci
EOF
    systemctl enable --now mariadb
    systemctl restart mariadb

    DB_CLI="$(command -v mariadb || command -v mysql || true)"
    [ -n "$DB_CLI" ] || die "Cliente do MariaDB não encontrado"

    "$DB_CLI" <<SQL
DROP USER IF EXISTS ''@'localhost';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${NC_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';
ALTER USER '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';
GRANT ALL PRIVILEGES ON \`${NC_DB_NAME}\`.* TO '${NC_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
    ok "Banco '${NC_DB_NAME}' e usuário '${NC_DB_USER}' criados"
}

configure_redis() {
    log "Iniciando Redis/Valkey"
    local s
    for s in redis-server redis valkey-server valkey; do
        if [[ "$(systemctl list-unit-files --no-legend "$s.service" 2>/dev/null || true)" == "$s.service"* ]]; then
            REDIS_SVC="$s"
            break
        fi
    done
    [ -n "$REDIS_SVC" ] || die "Serviço do Redis/Valkey não encontrado"
    systemctl enable --now "$REDIS_SVC"
    ok "Serviço $REDIS_SVC ativo"
}

download_nextcloud() {
    local file="nextcloud-${NC_VERSION}.tar.bz2"

    log "Baixando Nextcloud ($NC_VERSION)"
    curl -fSL --retry 3 --progress-bar -o "$WORK_DIR/$file" "$NC_DOWNLOAD_BASE/$file" \
        || die "Falha ao baixar $NC_DOWNLOAD_BASE/$file (a versão existe?)"
    curl -fsSL --retry 3 -o "$WORK_DIR/$file.sha256" "$NC_DOWNLOAD_BASE/$file.sha256"
    # O .sha256 pode listar outros arquivos (ex.: latest.metadata): usa só a linha do tarball
    local expected actual
    expected="$(awk -v f="$file" '$2 == f || $2 == "*"f {print $1; exit}' "$WORK_DIR/$file.sha256")"
    [ -n "$expected" ] || die "Checksum de $file não encontrado em $file.sha256"
    actual="$(sha256sum "$WORK_DIR/$file" | awk '{print $1}')"
    [ "$expected" = "$actual" ] || die "Checksum SHA-256 inválido para $file"
    ok "Download verificado (SHA-256)"

    log "Extraindo para $NC_INSTALL_DIR"
    tar -xjf "$WORK_DIR/$file" -C "$WORK_DIR"

    # Confirma a faixa de PHP com o próprio código baixado
    local _MIN="" _MAX=""
    if parse_versioncheck < "$WORK_DIR/nextcloud/lib/versioncheck.php"; then
        if ! ver_ge "$PHP_V" "$_MIN" || ! ver_ge "$_MAX" "$PHP_V"; then
            die "Nextcloud $NC_VERSION exige PHP $_MIN–$_MAX, mas foi instalado o PHP $PHP_V. Use --php-version X.Y."
        fi
    fi
    mkdir -p "$(dirname "$NC_INSTALL_DIR")"
    if [ -d "$NC_INSTALL_DIR" ]; then rmdir "$NC_INSTALL_DIR"; fi
    mv "$WORK_DIR/nextcloud" "$NC_INSTALL_DIR"
    mkdir -p "$NC_DATA_DIR"
    chown -R "$WEB_USER:$WEB_USER" "$NC_INSTALL_DIR" "$NC_DATA_DIR"
    chmod 750 "$NC_DATA_DIR"
    ok "Arquivos instalados"
}

occ() {
    (cd "$NC_INSTALL_DIR" && runuser -u "$WEB_USER" -- "$PHP_BIN" occ "$@")
}

php_has_ext() { grep -qix "$1" <<< "$("$PHP_BIN" -m 2>/dev/null || true)"; }

install_nextcloud() {
    log "Executando a instalação do Nextcloud"
    occ maintenance:install \
        --database mysql \
        --database-host localhost \
        --database-name "$NC_DB_NAME" \
        --database-user "$NC_DB_USER" \
        --database-pass "$NC_DB_PASS" \
        --admin-user "$NC_ADMIN_USER" \
        --admin-pass "$NC_ADMIN_PASS" \
        --data-dir "$NC_DATA_DIR"

    log "Aplicando configurações recomendadas"
    occ config:system:set trusted_domains 0 --value=localhost
    occ config:system:set trusted_domains 1 --value="$NC_DOMAIN"
    if [ "$SERVER_IP" != "$NC_DOMAIN" ]; then
        occ config:system:set trusted_domains 2 --value="$SERVER_IP"
    fi
    occ config:system:set overwrite.cli.url --value="http://$NC_DOMAIN"
    occ config:system:set htaccess.RewriteBase --value=/
    occ maintenance:update:htaccess
    occ config:system:set default_phone_region --value="$NC_PHONE_REGION"
    occ config:system:set default_timezone --value="$NC_TIMEZONE"
    occ config:system:set maintenance_window_start --type=integer --value=1

    if php_has_ext apcu; then
        occ config:system:set memcache.local --value='\OC\Memcache\APCu'
    fi
    if php_has_ext redis; then
        occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
        occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
        occ config:system:set redis host --value=localhost
        occ config:system:set redis port --type=integer --value=6379
    fi

    occ background:cron
    occ db:add-missing-indices || warn "db:add-missing-indices falhou"
    occ maintenance:repair --include-expensive || warn "maintenance:repair falhou"
    ok "Nextcloud instalado e configurado"
}

# Adiciona ao config.php blocos comentados de trusted_domains e
# trusted_proxies, para o administrador ativar depois.
# Roda por último: qualquer "occ config:system:set" (ou alteração pelo
# painel) reescreve o config.php e remove os comentários.
add_config_comments() {
    local f="$NC_INSTALL_DIR/config/config.php" tmp
    log "Adicionando configurações comentadas em $f"
    [ "$(tail -n1 "$f")" = ");" ] || { warn "Formato inesperado de $f; configurações comentadas não adicionadas"; return 0; }
    tmp="$(mktemp "$f.XXXXXX")"
    {
        head -n -1 "$f"
        cat <<'EOF'
  # --- Configurações opcionais (adicionadas pelo instalador) ---
  # Para ativar, remova o "//" do início das linhas do bloco e ajuste os
  # valores. Ao ativar, apague o 'trusted_domains' definido acima, pois o
  # PHP usa a última definição da chave.
  # Atenção: alterações via occ ou pelo painel reescrevem este arquivo e
  # removem estes comentários.
  #
  # Domínios e IPs pelos quais o Nextcloud pode ser acessado
  // 'trusted_domains' =>
  // array (
  //   0 => 'ip-domain',
  //   1 => 'nextcloud.dominio',
  // ),
  #
  # IPs dos proxies reversos à frente do Nextcloud
  // 'trusted_proxies' =>
  // array (
  //   0 => 'ip-proxie',
  // ),
);
EOF
    } > "$tmp"
    if "$PHP_BIN" -l "$tmp" >/dev/null 2>&1; then
        chown --reference="$f" "$tmp"
        chmod --reference="$f" "$tmp"
        mv -f "$tmp" "$f"
        if selinux_enabled; then restorecon "$f"; fi
        ok "Configurações comentadas adicionadas ao config.php"
    else
        rm -f "$tmp"
        warn "Erro de sintaxe ao adicionar as configurações comentadas; config.php mantido sem alterações"
    fi
}

configure_cron() {
    log "Configurando tarefas em segundo plano (systemd timer)"
    cat > /etc/systemd/system/nextcloud-cron.service <<EOF
[Unit]
Description=Nextcloud cron.php
After=network.target ${REDIS_SVC}.service mariadb.service

[Service]
Type=oneshot
User=${WEB_USER}
ExecStart=${PHP_BIN} -f ${NC_INSTALL_DIR}/cron.php
KillMode=process
EOF
    cat > /etc/systemd/system/nextcloud-cron.timer <<'EOF'
[Unit]
Description=Executa o cron.php do Nextcloud a cada 5 minutos

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
Unit=nextcloud-cron.service

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now nextcloud-cron.timer
    ok "Timer nextcloud-cron.timer ativo"
}

start_apache() {
    systemctl enable --now "$APACHE_SVC"
    systemctl restart "$APACHE_SVC"
    ok "Serviço $APACHE_SVC ativo"
}

configure_firewall() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log "Liberando HTTP/HTTPS no firewalld"
        firewall-cmd -q --permanent --add-service=http --add-service=https
        firewall-cmd -q --reload
        ok "firewalld atualizado"
    elif command -v ufw >/dev/null 2>&1 && [[ "$(ufw status 2>/dev/null || true)" == *"Status: active"* ]]; then
        log "Liberando HTTP/HTTPS no ufw"
        ufw allow 80/tcp >/dev/null
        ufw allow 443/tcp >/dev/null
        ok "ufw atualizado"
    fi
}

configure_letsencrypt() {
    [ "$NC_LETSENCRYPT" = "yes" ] || return 0
    log "Emitindo certificado Let's Encrypt para $NC_DOMAIN"
    if [ "$FAMILY" = "debian" ]; then
        apt_install certbot python3-certbot-apache
    else
        dnf_install certbot python3-certbot-apache
    fi
    if certbot --apache --non-interactive --agree-tos --redirect \
            -m "$NC_EMAIL" -d "$NC_DOMAIN"; then
        occ config:system:set overwrite.cli.url --value="https://$NC_DOMAIN"
        occ config:system:set overwriteprotocol --value=https
        ok "HTTPS ativo (renovação automática configurada pelo certbot)"
        return 0
    fi
    warn "Falha ao emitir o certificado. Verifique se o DNS de $NC_DOMAIN aponta para este servidor e rode:"
    warn "  certbot --apache -d $NC_DOMAIN -m $NC_EMAIL --agree-tos --redirect"
    NC_LETSENCRYPT="failed"
}

save_credentials() {
    local proto="http"
    if [ "$NC_LETSENCRYPT" = "yes" ]; then proto="https"; fi
    umask 077
    cat > "$CREDENTIALS_FILE" <<EOF
# Nextcloud — credenciais geradas em $(date '+%Y-%m-%d %H:%M:%S')
URL:            ${proto}://${NC_DOMAIN}
Administrador:  ${NC_ADMIN_USER}
Senha admin:    ${NC_ADMIN_PASS}

Banco:          ${NC_DB_NAME}
Usuário banco:  ${NC_DB_USER}
Senha banco:    ${NC_DB_PASS}

Aplicação:      ${NC_INSTALL_DIR}
Dados:          ${NC_DATA_DIR}
PHP:            ${PHP_V} (${FPM_SVC})
EOF
    chmod 600 "$CREDENTIALS_FILE"

    cat <<EOF

${C_GREEN}════════════════════════════════════════════════════════════${C_RESET}
${C_GREEN} Nextcloud instalado com sucesso!${C_RESET}
${C_GREEN}════════════════════════════════════════════════════════════${C_RESET}
  URL:            ${proto}://${NC_DOMAIN}
  Administrador:  ${NC_ADMIN_USER}
  Senha:          (salva em ${CREDENTIALS_FILE})

  Credenciais:    ${CREDENTIALS_FILE} (somente root)
  Log:            ${LOG_FILE}
EOF
    if [ "$NC_LETSENCRYPT" != "yes" ]; then
        cat <<EOF

  ${C_YELLOW}O acesso está em HTTP. Para produção, configure HTTPS:${C_RESET}
    curl ... | sudo bash -s -- --domain seu.dominio --letsencrypt --email voce@dominio
    (ou rode o certbot manualmente)
EOF
    fi
    echo
}

print_plan() {
    cat <<EOF

Plano de instalação:
  Sistema:        $OS_NAME (família $FAMILY)
  PHP:            $PHP_V (aceito: $PHP_MIN–$PHP_MAX)
  Nextcloud:      $NC_VERSION
  Domínio:        $NC_DOMAIN
  Aplicação:      $NC_INSTALL_DIR
  Dados:          $NC_DATA_DIR
  Banco:          $NC_DB_NAME (usuário $NC_DB_USER)
  Let's Encrypt:  $NC_LETSENCRYPT

EOF
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"
    [ "$(id -u)" -eq 0 ] || die "Execute como root (ex.: curl ... | sudo bash)"
    command -v systemctl >/dev/null 2>&1 || die "systemd é necessário"

    # O script pode estar sendo lido do stdin (curl | bash): nenhum comando
    # filho deve consumir o stdin.
    exec </dev/null

    touch "$LOG_FILE" && chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR
    trap cleanup EXIT
    WORK_DIR="$(mktemp -d)"

    log "Instalador do Nextcloud — $(date '+%Y-%m-%d %H:%M:%S')"
    detect_os
    preflight
    resolve_nc_version
    detect_php_range

    case "$FAMILY" in
        debian)      plan_debian ;;
        rhel|fedora) plan_rhel ;;
    esac
    print_plan

    if [ "$NC_CHECK_ONLY" = "yes" ]; then
        ok "Modo --check: nenhuma alteração foi feita."
        exit 0
    fi

    case "$FAMILY" in
        debian)      install_debian ;;
        rhel|fedora) install_rhel ;;
    esac

    configure_php
    configure_mariadb
    configure_redis
    download_nextcloud

    case "$FAMILY" in
        debian)      configure_apache_debian ;;
        rhel|fedora) configure_apache_rhel ;;
    esac

    install_nextcloud
    configure_selinux
    start_apache
    configure_firewall
    configure_cron
    configure_letsencrypt
    add_config_comments
    save_credentials
}

main "$@"
