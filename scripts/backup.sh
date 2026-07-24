#!/bin/bash
# Backup logico diario do banco do Keycloak.
# Uso (cron, 02:00 todo dia):
#   0 2 * * * /opt/keycloak-stack/scripts/backup.sh >> /var/log/keycloak-backup.log 2>&1
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/mnt/backup_nfs}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DATE="$(date +%Y%m%d_%H%M%S)"

cd "$STACK_DIR"
# shellcheck disable=SC1091
[ -f .env ] && source .env

POSTGRES_DB="${POSTGRES_DB:-keycloak}"
POSTGRES_USER="${POSTGRES_USER:-keycloak_user}"

mkdir -p "$BACKUP_DIR"
OUT_FILE="${BACKUP_DIR}/keycloak_${DATE}.sql.gz"
TMP_FILE="${OUT_FILE}.part"

echo "[$(date '+%F %T')] Iniciando backup de '${POSTGRES_DB}' -> ${OUT_FILE}"

if docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$TMP_FILE"; then
    mv "$TMP_FILE" "$OUT_FILE"
    echo "[$(date '+%F %T')] Backup concluido: ${OUT_FILE} ($(du -h "$OUT_FILE" | cut -f1))"
else
    rm -f "$TMP_FILE"
    echo "[$(date '+%F %T')] ERRO: falha ao gerar o backup" >&2
    exit 1
fi

echo "[$(date '+%F %T')] Removendo backups com mais de ${RETENTION_DAYS} dias"
find "$BACKUP_DIR" -name 'keycloak_*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete

echo "[$(date '+%F %T')] Backup finalizado com sucesso"
