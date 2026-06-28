# home-backup

リモートサーバーの `/home` と `/etc` を別ディスクへバックアップする仕組み。
cron 設定込みで Git 管理しており、サーバーリプレース時も clone + install で導入できる。

## 構成

| ファイル | 役割 |
| --- | --- |
| `config.env` | 全スクリプト共通の設定（パス・世代数など） |
| `bin/daily-rsync.sh` | 日次: `/home` `/etc` を `--delete` 付きで rsync 同期 |
| `bin/weekly-archive.sh` | 週次: 同期先を tar.gz 化し、4世代(約1ヶ月)でローテーション |
| `cron/home-backup` | cron 定義（`/etc/cron.d/` に配置される雛形） |
| `install.sh` | 配置先へコピーし cron を登録 |

## バックアップ動作

```
/home  ─┐  rsync(--delete) 日次 03:00
/etc   ─┴─▶ /mnt/disk/backup/pidev/{home,etc}
                      │  tar.gz 週次 日曜 04:00
                      └─▶ /mnt/disk/backup/archives/backup-YYYYmmdd-HHMMSS.tar.gz
                          （4世代を保持、超過分は自動削除）
```

- **日次 rsync**: ミラー同期（元で消したファイルは同期先からも削除）。
- **週次 tar**: その時点のミラーをまるごと圧縮保存。誤削除からの復旧用に世代を残す。
- アーカイブ出力先 `archives/` は tar 対象から除外しているため再帰しない。

## 導入

```bash
git clone <このリポジトリ> home-backup
cd home-backup

# 必要に応じてパスや世代数を編集
vi config.env

# 配置先(/opt/home-backup)へインストールし cron を登録
sudo ./install.sh
```

配置先を変えたい場合:

```bash
sudo INSTALL_DIR=/srv/home-backup ./install.sh
```

## 設定変更

`config.env` を編集して再度 `sudo ./install.sh` を実行すれば反映される。

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `SOURCE_DIRS` | `/home /etc` | 同期元（スペース区切りで複数可） |
| `BACKUP_ROOT` | `/mnt/disk/backup` | バックアップ先ルート |
| `SYNC_DEST` | `${BACKUP_ROOT}/pidev` | rsync 同期先 |
| `ARCHIVE_DIR` | `${BACKUP_ROOT}/archives` | tar 出力先 |
| `ARCHIVE_KEEP` | `4` | 保持世代数（週次なので約1ヶ月） |
| `LOG_DIR` | `/var/log/home-backup` | ログ出力先 |

## 動作確認・運用

```bash
# 手動実行
sudo /opt/home-backup/bin/daily-rsync.sh
sudo /opt/home-backup/bin/weekly-archive.sh

# ログ確認
tail -f /var/log/home-backup/daily-rsync.log
tail -f /var/log/home-backup/weekly-archive.log

# cron 確認
cat /etc/cron.d/home-backup
```

## 復元

```bash
# rsync ミラーから直接コピー
rsync -aAXH /mnt/disk/backup/pidev/home/ /home/

# tar アーカイブから復元
tar -xzf /mnt/disk/backup/archives/backup-YYYYmmdd-HHMMSS.tar.gz -C /restore/target
```
