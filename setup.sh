#!/usr/bin/env bash
# =============================================================================
# setup.sh - Provisionamento inicial da stack Keycloak (SSO da Prefeitura)
#
# Idempotente: pode ser executado mais de uma vez sem sobrescrever segredos
# ou certificados ja existentes. Ver docs/RUNBOOK.md (Etapa 0 e Etapa 1).
#
# Uso:
#   ./setup.sh                 modo interativo (recomendado)
#   ./setup.sh --yes           aceita os padroes sem perguntar (CI/automacao)
#   ./setup.sh --self-signed   gera certificado autoassinado (SOMENTE homologacao)
#   ./setup.sh --no-anim       desativa a animacao de abertura
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

ASSUME_YES=0
SELF_SIGNED=0
NO_ANIM=0

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --self-signed) SELF_SIGNED=1 ;;
        --no-anim) NO_ANIM=1 ;;
        -h|--help)
            echo "Uso: ./setup.sh [--yes] [--self-signed] [--no-anim]"
            exit 0
            ;;
        *) die "Argumento desconhecido: $arg (use --help)" ;;
    esac
done
export ASSUME_YES NO_ANIM

trap 'log_err "Setup interrompido na linha $LINENO. Nenhuma alteracao destrutiva foi feita."' ERR

print_header "SETUP - Provisionamento Inicial"

# -----------------------------------------------------------------------------
step "Verificando pre-requisitos"
# -----------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Docker nao encontrado. Instale o Docker Engine antes de continuar."
log_ok "Docker encontrado: $(docker --version)"

docker compose version >/dev/null 2>&1 || die "Docker Compose v2 (plugin) nao encontrado."
log_ok "Docker Compose: $(docker compose version --short 2>/dev/null || echo v2)"

docker info >/dev/null 2>&1 || die "O daemon do Docker nao esta respondendo. Ele esta rodando?"
log_ok "Daemon do Docker respondendo"

command -v openssl >/dev/null 2>&1 || die "openssl nao encontrado (necessario para gerar segredos/certificados)."
log_ok "openssl encontrado: $(openssl version)"

# -----------------------------------------------------------------------------
step "Preparando estrutura de diretorios"
# -----------------------------------------------------------------------------
mkdir -p secrets certs nginx/certs
log_ok "secrets/  certs/  nginx/certs/"

# -----------------------------------------------------------------------------
step "Configurando .env"
# -----------------------------------------------------------------------------
if [ -f .env ]; then
    log_info ".env ja existe - mantendo valores atuais (apague o arquivo para reconfigurar do zero)"
else
    [ -f .env.example ] || die ".env.example nao encontrado no repositorio"
    cp .env.example .env
    log_ok ".env criado a partir de .env.example"

    POSTGRES_DB_V=$(ask "Nome do banco Postgres" "keycloak")
    POSTGRES_USER_V=$(ask "Usuario do Postgres" "keycloak_user")
    KC_ADMIN_USER_V=$(ask "Usuario admin inicial do Keycloak" "kc_admin")
    KC_HOSTNAME_V=$(ask "Hostname publico (https://...)" "https://auth.prefeitura.gov.br")
    PROXY_TRUSTED_V=$(ask "CIDR de rede confiavel para o proxy" "172.16.0.0/12")
    AD_DOMAIN_V=$(ask "Dominio do Active Directory" "prefeitura.local")
    AD_DC_HOST_V=$(ask "Hostname do Domain Controller" "dc01.prefeitura.local")
    AD_DC_IP_V=$(ask "IP do Domain Controller" "192.168.1.10")
    KC_LOG_LEVEL_V=$(ask "Nivel de log do Keycloak" "INFO")

    ENABLE_PORTAINER_V="false"
    if confirm "Subir o Portainer junto (gerenciador visual do Docker, so' acessivel via 127.0.0.1:9443/SSH tunnel por padrao)?" "N"; then
        ENABLE_PORTAINER_V="true"
    fi

    cat > .env <<EOF
# Gerado por setup.sh em $(date '+%F %T')
POSTGRES_DB=${POSTGRES_DB_V}
POSTGRES_USER=${POSTGRES_USER_V}

KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER_V}

KC_HOSTNAME=${KC_HOSTNAME_V}
PROXY_TRUSTED_ADDRESSES=${PROXY_TRUSTED_V}

AD_DOMAIN=${AD_DOMAIN_V}
AD_DC_HOSTNAME=${AD_DC_HOST_V}
AD_DC_IP=${AD_DC_IP_V}

KC_LOG_LEVEL=${KC_LOG_LEVEL_V}

# Imagem do Keycloak publicada pelo CI (ver .github/workflows/ci.yml).
# Em producao, prefira travar KEYCLOAK_IMAGE_TAG num "sha-xxxxxxx" especifico
# em vez de "latest".
KEYCLOAK_IMAGE=ghcr.io/yurythx/keycloak-sso
KEYCLOAK_IMAGE_TAG=latest

# Portainer (opcional). PORTAINER_BIND=127.0.0.1 so' permite acesso via
# SSH tunnel/VPN - mude com cuidado (ver docs/RUNBOOK.md).
ENABLE_PORTAINER=${ENABLE_PORTAINER_V}
PORTAINER_BIND=127.0.0.1
EOF
    log_ok ".env preenchido"
fi

# -----------------------------------------------------------------------------
step "Gerando segredos (32 caracteres alfanumericos)"
# -----------------------------------------------------------------------------
# Alfanumerico puro (sem +, / ou =) de proposito: segredos base64 "crus"
# quebram testes com 'curl -d' sem --data-urlencode (o '+' vira espaco).
# Ver docs/RUNBOOK.md, nota na Etapa 2.
gen_secret() {
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
}

make_secret_file() {
    local file="$1" label="$2"
    if [ -s "$file" ]; then
        log_info "${label} ja existe em ${file} - mantendo (nao sobrescrito)"
    else
        gen_secret > "$file"
        chmod 600 "$file"
        log_ok "${label} gerado -> ${file} (600, 32 chars)"
    fi
}

make_secret_file "secrets/postgres_password.txt" "Senha do Postgres"
make_secret_file "secrets/kc_admin_password.txt" "Senha do admin do Keycloak"

# -----------------------------------------------------------------------------
step "Certificado TLS do Nginx (nginx/certs/)"
# -----------------------------------------------------------------------------
if [ -s nginx/certs/fullchain.pem ] && [ -s nginx/certs/privkey.pem ]; then
    log_ok "Certificado ja presente em nginx/certs/"
elif [ "$SELF_SIGNED" = "1" ] || confirm "Certificado da CA da prefeitura ainda nao chegou. Gerar um autoassinado (SOMENTE para homologacao/teste)?"; then
    HOST_FOR_CERT="$(grep -E '^KC_HOSTNAME=' .env 2>/dev/null | sed -E 's#^KC_HOSTNAME=https?://##' | tr -d '\r')"
    HOST_FOR_CERT="${HOST_FOR_CERT:-localhost}"
    MSYS_NO_PATHCONV=1 openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
        -keyout nginx/certs/privkey.pem -out nginx/certs/fullchain.pem \
        -subj "/CN=${HOST_FOR_CERT}" -addext "subjectAltName=DNS:${HOST_FOR_CERT}" \
        >/dev/null 2>&1
    log_warn "Certificado AUTOASSINADO gerado para '${HOST_FOR_CERT}' (30 dias) - troque pelo certificado da CA corporativa antes do go-live em producao"
else
    log_warn "Certificado TLS pendente - copie fullchain.pem e privkey.pem para nginx/certs/ antes de rodar ./deploy.sh"
fi

# -----------------------------------------------------------------------------
step "CA do Active Directory (necessaria na Etapa 3 do RUNBOOK)"
# -----------------------------------------------------------------------------
if [ -s certs/ad-ca.pem ]; then
    log_ok "certs/ad-ca.pem presente"
else
    log_info "certs/ad-ca.pem ainda nao foi copiado - so e necessario para a federacao LDAPS (Etapa 3), nao bloqueia o deploy inicial"
fi

# -----------------------------------------------------------------------------
# Resumo
# -----------------------------------------------------------------------------
STATUS_ENV="OK"
STATUS_SECRETS="OK"
STATUS_CERT="OK"
if [ ! -s nginx/certs/fullchain.pem ] || [ ! -s nginx/certs/privkey.pem ]; then
    STATUS_CERT="PENDENTE"
fi
STATUS_PORTAINER="desativado"
grep -qE '^ENABLE_PORTAINER=true' .env 2>/dev/null && STATUS_PORTAINER="ativado (127.0.0.1:9443)"

print_panel "RESUMO DO SETUP" \
    ".env ................... ${STATUS_ENV}" \
    "secrets/*.txt ........... ${STATUS_SECRETS}" \
    "nginx/certs/*.pem ....... ${STATUS_CERT}" \
    "Portainer ............... ${STATUS_PORTAINER}" \
    "" \
    "Proximo passo: ./deploy.sh" \
    "Referencia completa: docs/RUNBOOK.md"

printf "\n%sSetup concluido.%s\n\n" "${C_BGREEN}" "${C_RESET}"
