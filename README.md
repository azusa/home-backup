# home-backup

リモートサーバーの `/home` と `/etc` を別ディスクへバックアップする仕組み。
cron 設定込みで Git 管理しており、サーバーリプレース時も clone + install で導入できる。

## 構成

| ファイル | 役割 |
| --- | --- |
| `config.env` | 全スクリプト共通の設定（パス・世代数など） |
| `bin/daily-rsync.sh` | 日次: `/home` `/etc` を `--delete` 付きで rsync 同期 |
| `bin/weekly-archive.sh` | 週次: 同期先を無圧縮 tar 化（月次フル + 週次差分）し、月単位でローテーション |
| `cron/home-backup` | cron 定義（`/etc/cron.d/` に配置される雛形） |
| `install.sh` | 配置先へコピーし cron を登録 |

## バックアップ動作

```
/home  ─┐  rsync(--delete) 日次 03:00
/etc   ─┴─▶ /mnt/disk/backup/pidev/{home,etc}
                      │  tar 週次 日曜 04:00 (無圧縮 / --listed-incremental)
                      ├─▶ archives/backup-YYYYMM-full-<TS>.tar  月の最初の1回（フル）
                      ├─▶ archives/backup-YYYYMM-diff-<TS>.tar  以降の週（その月のフルとの差分）
                      └─▶ archives/level0-YYYYMM.snar           その月のフル時点のスナップショット状態
                          （ARCHIVE_KEEP_MONTHS ヶ月より古い月を丸ごと削除）
```

- **日次 rsync**: ミラー同期（元で消したファイルは同期先からも削除）。
- **週次 tar**: 月の最初の実行でフルを取り、`level0-YYYYMM.snar` を作る。
  同じ月の2回目以降は、その snar を**作業コピーしてから**差分を取るため、
  差分は常に「その月のフルとの差分」になる（週ごとの増分チェーンにはならない）。
  復元に必要なのは **フル 1 本 + 任意の差分 1 本** だけ。
- **圧縮しない**: 中身がほぼ JPEG / MP4 で圧縮が効かず、gzip は CPU と時間だけ食うため `.tar` で出力する。
- **負荷対策**: tar と削除は `nice -n 19 ionice -c 3`（idle）で実行し、I/O 待ちで機器が固まるのを抑える。
- **不完全な世代を残さない**: 一度 `<名前>.part` に書き出し、成功時のみ正式名に `mv` する。
  tar の終了コードは 0 と 1（読み込み中にファイルが変化）を成功、2 以上を失敗として扱う。
  失敗時は `.part` と、フル実行中なら作りかけの `level0` snar も削除する。
- **空き容量チェック**: フル実行前に、直近のフル（無ければ旧 `.tar.gz`）のサイズを見積もりとして
  `ARCHIVE_DIR` の空きと比較し、足りなければログを残して異常終了する（`du` による走査はしない）。
- アーカイブ出力先 `archives/` が `pidev/` 配下にある場合はアーカイブ内パスで除外するため再帰しない。

## 導入

```bash
git clone <このリポジトリ> home-backup
cd home-backup

# 必要に応じてパスや保持月数を編集
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
| `ARCHIVE_KEEP_MONTHS` | `2` | アーカイブを保持する月数（今月を含む。2 なら今月＋先月） |
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

### 1. 最新の状態に戻したいだけなら rsync ミラーから

```bash
rsync -aAXH /mnt/disk/backup/pidev/home/ /home/
```

### 2. アーカイブ（フル + 差分）から戻す

**フルを展開してから、重ねたい差分を上に展開する**。順番が重要で、
差分側には `--listed-incremental=/dev/null` を付ける（これでアーカイブ内の
ディレクトリ情報が解釈され、フル以降に削除されたファイルも復元先から消える）。

```bash
cd /mnt/disk/backup/archives
ls -1 backup-*.tar            # 使える世代を確認

RESTORE=/restore/target
mkdir -p "${RESTORE}"

# (1) 戻したい月のフルを展開
tar -xf backup-202610-full-20251005-040000.tar \
    -C "${RESTORE}" --listed-incremental=/dev/null

# (2) その月の差分のうち、戻したい時点のものを1本だけ重ねる
#     （差分はどれもフル基準なので、差分を何本も順に重ねる必要はない）
tar -xf backup-202610-diff-20251026-040000.tar \
    -C "${RESTORE}" --listed-incremental=/dev/null
```

展開後は `${RESTORE}/pidev/home/...` `${RESTORE}/pidev/etc/...` という構成になる。
そこから必要な範囲だけ元の場所へコピーする。

```bash
rsync -aAXH "${RESTORE}/pidev/home/" /home/
```

中身の確認だけなら展開せずに一覧できる。

```bash
tar -tvf backup-202610-full-20251005-040000.tar | less
```

> **注意**
> - フルだけを展開した場合は「月初のフル時点」の状態になる。
> - 差分を重ねる場合、同じ月のフルと組み合わせること（`YYYYMM` を揃える）。
> - 旧形式の `backup-YYYYmmdd-HHMMSS.tar.gz` は
>   `tar -xzf backup-YYYYmmdd-HHMMSS.tar.gz -C /restore/target` で展開する。
>   これらは月単位ローテーションの対象外なので、不要になったら手動で削除する。
