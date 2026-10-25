#!/usr/bin/env bash
# =============================================================================
# 週次 tar アーカイブ（月次フル + 週次差分）+ 月単位ローテーション
#   SYNC_DEST の内容を無圧縮 tar で ARCHIVE_DIR に保存する。
#     - その月の level0 snar が無ければフル (backup-YYYYMM-full-<TS>.tar)
#     - 有れば snar を作業コピーして差分   (backup-YYYYMM-diff-<TS>.tar)
#       差分は常にその月のフルが基準。level0 snar 自体は書き換えない。
#   JPEG/MP4 など既圧縮データが大半なので gzip は使わない。
#   I/O 負荷を抑えるため tar / rm は nice + ionice idle で実行する。
#   ※ ARCHIVE_DIR が SYNC_DEST 配下にある場合はパス指定で除外して再帰を防ぐ。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# テスト時は CONFIG_FILE で別設定を読み込める。
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.env}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# 保持する月数（今月を含む）。config.env に無い場合の既定値。
ARCHIVE_KEEP_MONTHS="${ARCHIVE_KEEP_MONTHS:-2}"

mkdir -p "${ARCHIVE_DIR}" "${LOG_DIR}"

LOG_FILE="${LOG_DIR}/weekly-archive.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"; }

# I/O 負荷を最小化するための前置コマンド。
LOWPRIO=(nice -n 19 ionice -c 3)

TS="$(date '+%Y%m%d-%H%M%S')"
YM="$(date '+%Y%m')"
SNAR_LEVEL0="${ARCHIVE_DIR}/level0-${YM}.snar"

# --- tar の起点とメンバー -----------------------------------------------------
# BACKUP_ROOT を起点に ./<SYNC_BASENAME> をアーカイブする。
SYNC_BASENAME="$(basename "${SYNC_DEST}")"
TAR_MEMBER="./${SYNC_BASENAME}"

# ARCHIVE_DIR が SYNC_DEST 配下にある場合のみ、アーカイブ内パスで除外する。
# （BACKUP_ROOT/archives のように外にある場合は除外指定そのものが不要）
TAR_EXCLUDES=()
sync_abs="$(realpath -m "${SYNC_DEST}")"
archive_abs="$(realpath -m "${ARCHIVE_DIR}")"
if [[ "${archive_abs}" == "${sync_abs}/"* ]]; then
    TAR_EXCLUDES+=("--exclude=${TAR_MEMBER}/${archive_abs#"${sync_abs}/"}")
fi

# --- 後始末 -------------------------------------------------------------------
PART_FILE=""
WORK_SNAR=""
cleanup() {
    [[ -n "${WORK_SNAR}" ]] && rm -f "${WORK_SNAR}"
    [[ -n "${PART_FILE}" ]] && rm -f "${PART_FILE}"
    return 0
}
trap cleanup EXIT

# --- モード決定 ---------------------------------------------------------------
if [[ -f "${SNAR_LEVEL0}" ]]; then
    MODE="diff"
else
    MODE="full"
fi

ARCHIVE_PATH="${ARCHIVE_DIR}/backup-${YM}-${MODE}-${TS}.tar"
PART_FILE="${ARCHIVE_PATH}.part"

log "===== アーカイブ開始 (${MODE}): ${ARCHIVE_PATH} ====="

# --- 空き容量チェック（フル時のみ） -------------------------------------------
# du で 600GB を走査すると遅いので、直近のフルのサイズを見積もりに使う。
avail_bytes="$(df -B1 --output=avail "${ARCHIVE_DIR}" | tail -n1 | tr -d ' ')"

newest_size() {
    find "${ARCHIVE_DIR}" -maxdepth 1 -type f -name "$1" -printf '%T@ %s\n' 2>/dev/null \
        | sort -rn | awk 'NR==1 { print $2 }'
}

if [[ "${MODE}" == "full" ]]; then
    estimate="$(newest_size 'backup-*-full-*.tar' || true)"
    if [[ -z "${estimate}" ]]; then
        # 旧形式(.tar.gz)しか無い場合はそのサイズを下限の目安にする。
        estimate="$(newest_size 'backup-*.tar.gz' || true)"
    fi
    if [[ -z "${estimate}" ]]; then
        log "WARN: 見積もり用の既存アーカイブが無いため空き容量チェックをスキップ（空き ${avail_bytes} bytes）"
    elif (( avail_bytes < estimate )); then
        log "ERROR: 空き容量不足 - 必要見積もり ${estimate} bytes / 空き ${avail_bytes} bytes"
        exit 1
    else
        log "空き容量チェック OK: 見積もり ${estimate} bytes / 空き ${avail_bytes} bytes"
    fi
else
    log "空き容量: ${avail_bytes} bytes（差分なのでチェックは省略）"
fi

# --- snar の準備 --------------------------------------------------------------
if [[ "${MODE}" == "full" ]]; then
    # level0 snar も .part に書き、成功時だけ確定させる。
    WORK_SNAR="${SNAR_LEVEL0}.part"
    rm -f "${WORK_SNAR}"
else
    # level0 を作業コピーして差分を取る（level0 本体は書き換えない）。
    #   → 毎週その月のフルを基準にした差分になる。
    WORK_SNAR="${ARCHIVE_DIR}/diff-${TS}.snar.work"
    cp -f "${SNAR_LEVEL0}" "${WORK_SNAR}"
fi

# --- tar 実行 -----------------------------------------------------------------
start_epoch="$(date '+%s')"
rc=0
"${LOWPRIO[@]}" tar \
    --create \
    --file="${PART_FILE}" \
    --listed-incremental="${WORK_SNAR}" \
    --warning=no-file-changed \
    -C "${BACKUP_ROOT}" \
    ${TAR_EXCLUDES[@]+"${TAR_EXCLUDES[@]}"} \
    "${TAR_MEMBER}" 2>>"${LOG_FILE}" || rc=$?
elapsed=$(( $(date '+%s') - start_epoch ))

# rc=1 は「読み込み中にファイルが変化した」= 稼働中のバックアップでは正常扱い。
if (( rc > 1 )); then
    log "ERROR: tar が失敗しました (rc=${rc}, ${elapsed}秒) - 不完全な世代は破棄します"
    rm -f "${PART_FILE}"
    if [[ "${MODE}" == "full" ]]; then
        log "作りかけの level0 snar を削除: ${WORK_SNAR}"
    fi
    # フルなら作りかけの level0 snar、差分なら作業コピー。どちらも残さない。
    rm -f "${WORK_SNAR}"
    PART_FILE=""
    WORK_SNAR=""
    exit 1
fi

if (( rc == 1 )); then
    log "NOTE: tar rc=1（読み込み中にファイルが変化）- 成功として扱います"
fi

# 成功: .part を本来の名前にして世代として確定させる。
mv -f "${PART_FILE}" "${ARCHIVE_PATH}"
PART_FILE=""

if [[ "${MODE}" == "full" ]]; then
    mv -f "${WORK_SNAR}" "${SNAR_LEVEL0}"
    log "level0 snar を作成: ${SNAR_LEVEL0}"
else
    rm -f "${WORK_SNAR}"
fi
WORK_SNAR=""

log "アーカイブ完了 (${MODE}): ${ARCHIVE_PATH} / サイズ $(du -h "${ARCHIVE_PATH}" | cut -f1) / 所要 ${elapsed}秒"

# --- 月単位ローテーション -----------------------------------------------------
# ARCHIVE_KEEP_MONTHS=2 なら「今月 + 先月」を残し、それより古い月を丸ごと削除する。
# 旧形式の backup-*.tar.gz は対象外（手動で削除する）。
if (( ARCHIVE_KEEP_MONTHS < 1 )); then
    log "WARN: ARCHIVE_KEEP_MONTHS=${ARCHIVE_KEEP_MONTHS} は不正なため 1 として扱います"
    ARCHIVE_KEEP_MONTHS=1
fi

cutoff_ym="$(date -d "${YM}01 -$((ARCHIVE_KEEP_MONTHS - 1)) months" '+%Y%m' 2>/dev/null || true)"
if [[ ! "${cutoff_ym}" =~ ^[0-9]{6}$ ]]; then
    log "WARN: 保持境界の月を計算できませんでした - ローテーションをスキップします"
else
    log "ローテーション: ${cutoff_ym} 以降の月を保持 (ARCHIVE_KEEP_MONTHS=${ARCHIVE_KEEP_MONTHS}, 今月=${YM})"
    deleted=0
    while IFS= read -r name; do
        if [[ "${name}" =~ ^backup-([0-9]{6})-(full|diff)-.+\.tar$ ]] \
            || [[ "${name}" =~ ^level0-([0-9]{6})\.snar$ ]]; then
            file_ym="${BASH_REMATCH[1]}"
        else
            continue
        fi
        # 今月は絶対に消さない。
        [[ "${file_ym}" == "${YM}" ]] && continue
        if (( 10#${file_ym} < 10#${cutoff_ym} )); then
            log "削除: ${name}"
            "${LOWPRIO[@]}" rm -f "${ARCHIVE_DIR}/${name}"
            deleted=$(( deleted + 1 ))
        fi
    done < <(find "${ARCHIVE_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort)
    if (( deleted == 0 )); then
        log "削除対象なし"
    else
        log "${deleted} 件を削除しました"
    fi
fi

log "===== 週次アーカイブ終了 (${MODE}) ====="
