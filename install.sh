#!/usr/bin/env bash
# =============================================================================
# home-backup インストーラ
#   このリポジトリを INSTALL_DIR に配置し、cron を登録する。
#   サーバーリプレース時はリポジトリを clone して sudo ./install.sh するだけ。
# =============================================================================
set -euo pipefail

# 配置先（必要なら環境変数で上書き可: INSTALL_DIR=/opt/home-backup ./install.sh）
INSTALL_DIR="${INSTALL_DIR:-/opt/home-backup}"
CRON_DEST="/etc/cron.d/home-backup"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "root 権限で実行してください: sudo ./install.sh" >&2
    exit 1
fi

echo "==> 配置先: ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"

# リポジトリ内容をコピー（.git は除く）
rsync -a --delete --exclude='.git' "${REPO_DIR}/" "${INSTALL_DIR}/"

chmod +x "${INSTALL_DIR}/bin/"*.sh "${INSTALL_DIR}/install.sh"

# cron を配置（プレースホルダを実パスに置換）
echo "==> cron 登録: ${CRON_DEST}"
sed "s#__INSTALL_DIR__#${INSTALL_DIR}#g" "${INSTALL_DIR}/cron/home-backup" > "${CRON_DEST}"
chmod 644 "${CRON_DEST}"
chown root:root "${CRON_DEST}"

# cron.d はファイル変更で自動反映されるが、念のため cron を再読込
if command -v systemctl >/dev/null 2>&1; then
    systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
fi

echo "==> 完了"
echo "    設定確認 : ${INSTALL_DIR}/config.env"
echo "    手動実行 : ${INSTALL_DIR}/bin/daily-rsync.sh"
echo "    cron確認 : cat ${CRON_DEST}"
