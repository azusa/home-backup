#!/usr/bin/env bash
# =============================================================================
# 日次 rsync 同期
#   SOURCE_DIRS を SYNC_DEST 配下へ --delete 付きで同期する。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.env"

mkdir -p "${SYNC_DEST}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/daily-rsync.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

log "===== rsync 開始 ====="

for src in ${SOURCE_DIRS}; do
    if [[ ! -d "${src}" ]]; then
        log "WARN: 同期元が存在しないためスキップ: ${src}"
        continue
    fi
    # 末尾スラッシュ無しで渡し、ベース名のディレクトリごと同期する。
    #   例: /home -> ${SYNC_DEST}/home/
    log "rsync: ${src} -> ${SYNC_DEST}/"
    rsync -aAXH --delete \
        --numeric-ids \
        --exclude='lost+found' \
        "${src}" "${SYNC_DEST}/" 2>&1 | tee -a "${LOG_FILE}"
done

log "===== rsync 完了 ====="
