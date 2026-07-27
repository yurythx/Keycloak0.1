#!/usr/bin/env bash
# =============================================================================
# setup.sh - Provisionamento inicial da stack Keycloak (SSO da Prefeitura)
#
# Idempotente: pode ser executado mais de uma vez sem sobrescrever segredos
# ou certificados ja existentes. Ver docs/00-pre-requisitos.md e docs/01-provisionamento.md.
#
# Uso:
#   ./setup.sh                 modo interativo (recomendado)
#   ./setup.sh --yes           aceita os padroes sem perguntar (CI/automacao)
#   ./setup.sh --self-signed   forca modo homologacao (Traefik com certificado
#                               autoassinado interno) - pula a pergunta de
#                               Let's Encrypt mesmo combinado com --yes
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
mkdir -p secrets certs traefik/certs
log_ok "secrets/  certs/  traefik/certs/"

# -----------------------------------------------------------------------------
step "Configurando .env"
# -----------------------------------------------------------------------------
if [ -f .env ]; then
    log_info ".env ja existe - mantendo valores atuais (apague o arquivo para reconfigurar do zero)"
    # Auto-migracao: .env de uma versao anterior a troca Nginx->Traefik nao
    # tem KC_HOSTNAME_FQDN (usado pela regra Host() do Traefik) - derive do
    # KC_HOSTNAME existente em vez de deixar o Traefik subir sem rota.
    if ! grep -qE '^KC_HOSTNAME_FQDN=' .env 2>/dev/null; then
        FQDN_MIGRATE="$(grep -E '^KC_HOSTNAME=' .env 2>/dev/null | sed -E 's#^KC_HOSTNAME=https?://##' | tr -d '\r')"
        if [ -n "$FQDN_MIGRATE" ]; then
            printf '\nKC_HOSTNAME_FQDN=%s\n' "$FQDN_MIGRATE" >> .env
            log_warn ".env de uma versao anterior (Nginx) - adicionado KC_HOSTNAME_FQDN=${FQDN_MIGRATE} automaticamente (necessario para o Traefik)"
        fi
    fi
else
    [ -f .env.example ] || die ".env.example nao encontrado no repositorio"
    cp .env.example .env
    log_ok ".env criado a partir de .env.example"

    POSTGRES_DB_V=$(ask "Nome do banco Postgres" "keycloak")
    POSTGRES_USER_V=$(ask "Usuario do Postgres" "keycloak_user")
    KC_ADMIN_USER_V=$(ask "Usuario admin inicial do Keycloak" "kc_admin")
    KC_HOSTNAME_V=$(ask "Hostname publico (https://...)" "https://sso.rondonopolis.mt.gov.br")
    KC_HOSTNAME_FQDN_V="$(printf '%s' "$KC_HOSTNAME_V" | sed -E 's#^https?://##')"
    PROXY_TRUSTED_V=$(ask "CIDR de rede confiavel para o proxy" "172.16.0.0/12")
    AD_DOMAIN_V=$(ask "Dominio do Active Directory" "prefeitura.local")
    AD_DC_HOST_V=$(ask "Hostname do Domain Controller" "dc01.prefeitura.local")
    AD_DC_IP_V=$(ask "IP do Domain Controller" "192.168.1.10")
    KC_LOG_LEVEL_V=$(ask "Nivel de log do Keycloak" "INFO")

    ENABLE_PORTAINER_V="false"
    if confirm "Subir o Portainer junto (gerenciador visual do Docker, so' acessivel via 127.0.0.1:9443/SSH tunnel por padrao)?" "N"; then
        ENABLE_PORTAINER_V="true"
    fi

    # --self-signed forca homologacao (Traefik autoassinado) sem perguntar -
    # importante porque --yes faz TODO confirm() responder "sim"
    # automaticamente (ver confirm() em scripts/lib/theme.sh), o que sem
    # essa guarda ligaria Let's Encrypt sem querer numa automacao/CI.
    ACME_LINES=""
    if [ "$SELF_SIGNED" != "1" ] && confirm "Habilitar Let's Encrypt real (producao - requer DNS publico resolvendo '${KC_HOSTNAME_FQDN_V}' para este host)? Responda NAO se for usar certificado proprio da CA da prefeitura" "N"; then
        ACME_EMAIL_V=$(ask "E-mail para o Let's Encrypt (avisos de expiracao/problemas)" "admin@${KC_HOSTNAME_FQDN_V#*.}")
        ACME_LINES=$(printf 'ACME_EMAIL=%s\nCOMPOSE_FILE=docker-compose.yml:docker-compose.prod.yml\n' "$ACME_EMAIL_V")
        log_warn "Let's Encrypt ativado - confirme que '${KC_HOSTNAME_FQDN_V}' resolve por DNS publico para este host ANTES de rodar ./deploy.sh (senao o desafio ACME falha)"
    else
        log_info "Modo homologacao/rede interna - Traefik vai servir certificado autoassinado, a menos que voce copie um certificado proprio depois (ver etapa 'Modo TLS' abaixo)"
    fi

    cat > .env <<EOF
# Gerado por setup.sh em $(date '+%F %T')
POSTGRES_DB=${POSTGRES_DB_V}
POSTGRES_USER=${POSTGRES_USER_V}

KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER_V}

KC_HOSTNAME=${KC_HOSTNAME_V}
KC_HOSTNAME_FQDN=${KC_HOSTNAME_FQDN_V}
PROXY_TRUSTED_ADDRESSES=${PROXY_TRUSTED_V}
${ACME_LINES}
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
# SSH tunnel/VPN - mude com cuidado (ver docs/scripts-referencia.md).
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
# Ver docs/02-configuracao-keycloak.md.
gen_secret() {
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
}

# O Keycloak (e o Postgres) rodam como usuario nao-root dentro do
# container, mas com GID 0 (grupo "root") - convencao tipo OpenShift
# (confirmado: uid=1000(keycloak) gid=0(root)). O "secrets:" do Docker
# Compose fora do modo Swarm e' um bind mount simples - ele NAO remapeia
# dono/grupo, preserva exatamente a permissao que o arquivo tem no HOST.
# Por isso o arquivo precisa ser legivel pelo grupo 0, senao o container
# recebe "Permission denied" ao ler /run/secrets/* (achado real: stack
# quebrou em producao com os arquivos em 600/root:root, ilegiveis pelo
# processo do Keycloak). 640 + grupo 0 resolve sem tornar o arquivo
# legivel por qualquer usuario do host (evita ir ate 644/world-readable).
fix_secret_perms() {
    local file="$1"
    if chgrp 0 "$file" 2>/dev/null; then
        chmod 640 "$file"
    else
        chmod 644 "$file"
        log_warn "$(basename "$file"): nao foi possivel ajustar o grupo para 0 (root) - usando 644"
    fi
}

make_secret_file() {
    local file="$1" label="$2"
    if [ -s "$file" ]; then
        log_info "${label} ja existe em ${file} - mantendo valor atual (so ajustando permissao)"
    else
        gen_secret > "$file"
        log_ok "${label} gerado -> ${file} (32 chars)"
    fi
    fix_secret_perms "$file"
}

make_secret_file "secrets/postgres_password.txt" "Senha do Postgres"
make_secret_file "secrets/kc_admin_password.txt" "Senha do admin do Keycloak"

# -----------------------------------------------------------------------------
step "Modo TLS (Traefik)"
# -----------------------------------------------------------------------------
# Tres modos, checados nesta ordem de prioridade:
#   1. Certificado proprio em traefik/certs/ (CA interna/corporativa da
#      prefeitura) - se presente, gera o dynamic config do Traefik
#      (provider "file", na mesma pasta) apontando pra ele. Detectado por
#      SNI automaticamente, sem precisar de label extra no keycloak.
#      (Nao confundir com certs/ad-ca.pem - CA do Active Directory, pro
#      Keycloak confiar no LDAPS, assunto totalmente diferente.)
#   2. Let's Encrypt real (docker-compose.prod.yml, COMPOSE_FILE no .env).
#   3. Homologacao - autoassinado automatico do proprio Traefik.
CUSTOM_CERT_DIR="traefik/certs"
CUSTOM_CERT_FILE="${CUSTOM_CERT_DIR}/fullchain.pem"
CUSTOM_KEY_FILE="${CUSTOM_CERT_DIR}/privkey.pem"
DYNAMIC_TLS_FILE="${CUSTOM_CERT_DIR}/tls.yml"

if [ -s "$CUSTOM_CERT_FILE" ] && [ -s "$CUSTOM_KEY_FILE" ]; then
    HOST_FOR_CERT="$(grep -E '^KC_HOSTNAME_FQDN=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    # Extrai so' o valor do CN, parando no proximo campo do subject (ex.:
    # "CN=x, O=y" -> "x") - certificados reais de CA quase sempre tem O=/OU=/C=
    # depois do CN; sem parar no ",", o valor extraido incluia esses campos
    # tambem e a comparacao com KC_HOSTNAME_FQDN dava falso-positivo de
    # mismatch mesmo com o dominio certo (achado real, testado com um
    # certificado de teste com subject "CN=x, O=y").
    CERT_CN="$(openssl x509 -noout -subject -in "$CUSTOM_CERT_FILE" 2>/dev/null | sed -E 's#.*CN\s*=\s*##; s#,.*##')"
    cat > "$DYNAMIC_TLS_FILE" <<EOF
tls:
  certificates:
    - certFile: /etc/traefik/certs/fullchain.pem
      keyFile: /etc/traefik/certs/privkey.pem
EOF
    if [ -n "$HOST_FOR_CERT" ] && [ -n "$CERT_CN" ] && [ "$HOST_FOR_CERT" != "$CERT_CN" ]; then
        log_warn "Certificado proprio ativo em ${CUSTOM_CERT_DIR}/, mas foi emitido para '${CERT_CN}' e KC_HOSTNAME_FQDN e' '${HOST_FOR_CERT}' - navegadores vao rejeitar (dominio nao bate). Confira se e' o arquivo certo"
    else
        log_ok "Certificado proprio (CA da prefeitura) ativo em ${CUSTOM_CERT_DIR}/ (CN='${CERT_CN}', bate com KC_HOSTNAME_FQDN)"
    fi
elif grep -qE '^COMPOSE_FILE=.*docker-compose\.prod\.yml' .env 2>/dev/null; then
    rm -f "$DYNAMIC_TLS_FILE"
    ACME_EMAIL_SHOW="$(grep -E '^ACME_EMAIL=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
    log_ok "Producao - Let's Encrypt ativado (e-mail: ${ACME_EMAIL_SHOW:-?}). Confirme o DNS publico antes do deploy"
else
    rm -f "$DYNAMIC_TLS_FILE"
    log_ok "Homologacao/rede interna - certificado autoassinado automatico do Traefik (aviso de seguranca esperado no navegador)"
    log_info "Tem certificado proprio da CA da prefeitura (nao Let's Encrypt)? Copie fullchain.pem e privkey.pem para ${CUSTOM_CERT_DIR}/ e rode ./setup.sh de novo"
    log_warn "Se o navegador ja tiver visitado este dominio via HTTPS antes com HSTS ativo, ele pode BLOQUEAR o botao 'Avancado -> Continuar' - limpe em chrome://net-internals/#hsts (Delete domain security policies) antes de testar"
fi

# -----------------------------------------------------------------------------
step "CA do Active Directory (necessaria na Etapa 3, docs/03-federacao-ad.md)"
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
STATUS_TLS="homologacao (Traefik autoassinado)"
if [ -s traefik/certs/fullchain.pem ] && [ -s traefik/certs/privkey.pem ]; then
    STATUS_TLS="certificado proprio (CA da prefeitura)"
elif grep -qE '^COMPOSE_FILE=.*docker-compose\.prod\.yml' .env 2>/dev/null; then
    STATUS_TLS="producao (Let's Encrypt)"
fi
STATUS_PORTAINER="desativado"
grep -qE '^ENABLE_PORTAINER=true' .env 2>/dev/null && STATUS_PORTAINER="ativado (127.0.0.1:9443)"

print_panel "RESUMO DO SETUP" \
    ".env ................... ${STATUS_ENV}" \
    "secrets/*.txt ........... ${STATUS_SECRETS}" \
    "TLS (Traefik) ........... ${STATUS_TLS}" \
    "Portainer ............... ${STATUS_PORTAINER}" \
    "" \
    "Proximo passo: ./deploy.sh" \
    "Referencia completa: docs/README.md"

printf "\n%sSetup concluido.%s\n\n" "${C_BGREEN}" "${C_RESET}"
