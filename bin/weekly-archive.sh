#!/usr/bin/env bash
# =============================================================================
# 週次 tar アーカイブ + 世代ローテーション
#   SYNC_DEST の内容を tar.gz 化して ARCHIVE_DIR に保存し、
#   ARCHIVE_KEEP 世代を超えた古いアーカイブを削除する。
#   ※ アーカイブ出力先 (ARCHIVE_DIR) は tar 対象から除外して再帰を防ぐ。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.env"

mkdir -p "${ARCHIVE_DIR}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/weekly-archive.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

TS="$(date '+%Y%m%d-%H%M%S')"
ARCHIVE_PATH="${ARCHIVE_DIR}/backup-${TS}.tar.gz"

log "===== アーカイブ開始: ${ARCHIVE_PATH} ====="

# BACKUP_ROOT を起点に pidev/ をアーカイブ（ARCHIVE_DIR は除外）。
ARCHIVE_BASENAME="$(basename "${ARCHIVE_DIR}")"
SYNC_BASENAME="$(basename "${SYNC_DEST}")"

tar -czf "${ARCHIVE_PATH}" \
    -C "${BACKUP_ROOT}" \
    --exclude="${ARCHIVE_BASENAME}" \
    "${SYNC_BASENAME}" 2>&1 | tee -a "${LOG_FILE}"

log "アーカイブ完了: $(du -h "${ARCHIVE_PATH}" | cut -f1)"

# --- 世代ローテーション -------------------------------------------------------
log "ローテーション: ${ARCHIVE_KEEP} 世代を保持"
mapfile -t archives < <(ls -1t "${ARCHIVE_DIR}"/backup-*.tar.gz 2>/dev/null || true)

if (( ${#archives[@]} > ARCHIVE_KEEP )); then
    for old in "${archives[@]:ARCHIVE_KEEP}"; do
        log "削除: ${old}"
        rm -f "${old}"
    done
else
    log "削除対象なし（現在 ${#archives[@]} 世代）"
fi

log "===== アーカイブ完了 ====="
