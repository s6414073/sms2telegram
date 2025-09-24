# SMS → Telegram 轉發器（ModemManager）

將插在 Linux 機器上的 4G/5G/LTE 數據機（由 **ModemManager** 管理）收到的 SMS，轉發到你的 Telegram 群組／頻道。腳本會長期監看新簡訊，支援 UCS-2（常見於中文簡訊）解碼、OTP（一次性驗證碼）白名單模式、空白或未解碼訊息的摘要轉發，並在成功送出後清理簡訊避免重複。

---

## 功能特色

- **即時監看 + 自動回退**：優先用 `mmcli -m any --monitor-sms --timeout=0` 監看；若監看異常中斷，會自動切換為輪詢模式再嘗試回復監看。  
- **UCS-2/HEX 解碼**：`content.text` 為空但 `content.data` 有 HEX 時，自動嘗試以 **UCS-2BE → UTF-8** 解碼，失敗時回退為二進位直譯。  
- **空白／未解碼訊息摘要**：可輸出 HEX 前幾百 bytes 或 RAW 前數行做除錯，行為由環境變數控制。  
- **OTP-only 模式**：只轉發內含 **4–8 位數字**的簡訊（常見 OTP）。  
- **避免重送**：使用「已處理清單」記錄已轉發的 SMS，防止重複推送。  
- **相容多版本 `mmcli` 刪除語法**：成功轉發後嘗試多種刪除語法，最大化相容性。  

---

## 系統需求

- Linux（以 **systemd** 啟動為例）
- 套件：`modemmanager`（含 `mmcli`）、`curl`、`awk`、`sed`、`xxd`、`iconv`、`bash`
- 已可正常工作的 4G/5G 行動數據機（建議以 **ModemManager** 管理）

---

## 安裝

1. **安裝相依套件**
   ```bash
   # Debian/Ubuntu
   sudo apt-get update
   sudo apt-get install -y modemmanager curl gawk sed xxd libc-bin
   ```

2. **放置腳本與設定**
   ```bash
   # 將腳本放到 /usr/local/bin
   sudo install -m 0755 sms-to-telegram.sh /usr/local/bin/sms-to-telegram.sh

   # 建立設定檔（至少填入 BOT_TOKEN 與 CHAT_ID）
   sudo install -m 0600 sms2tg.env /etc/sms2tg.env
   ```

3. **（可選）安裝 systemd 服務**
   ```bash
   sudo cp sms-to-telegram.service /etc/systemd/system/sms-to-telegram.service
   sudo systemctl daemon-reload
   sudo systemctl enable --now sms-to-telegram.service
   ```
   > 若服務檔內 `ExecStart=` 路徑不同，請改成 `/usr/local/bin/sms-to-telegram.sh`；並確保能讀到 `/etc/sms2tg.env`（常見作法是 `EnvironmentFile=/etc/sms2tg.env`）。

---

## 設定說明（`/etc/sms2tg.env`）

| 變數 | 必填 | 預設 | 說明 |
|---|---|---|---|
| `BOT_TOKEN` | ✅ | — | BotFather 取得的 Token。請妥善保密。 |
| `CHAT_ID` | ✅ | — | 目標聊天室 ID。群組多為負號開頭（如 `-100...`）。 |
| `OTP_ONLY` | ❶ | `no` | `yes` 時只轉發含 4–8 位數字的簡訊。 |
| `FORWARD_RAW_ON_EMPTY` | ❶ | `yes` | 無文字內容時是否轉發 RAW/HEX 預覽。 |
| `RAW_PREVIEW_BYTES` | ❶ | `220` | 未解碼 HEX 的摘要長度（bytes）。 |
| `DEBUG_DUMP_FILE` | ❶ | `/var/log/sms2tg.last` | 每則處理時輸出 KV/RAW 診斷。 |

> ❶：可省略，腳本有內建預設值。缺少必要值會在日誌中示警。

---

## 啟動與驗證（必要步驟）

### 1) 確認 **ModemManager** 正常
在啟動服務前，先確認系統已由 ModemManager 管理到數據機並啟用簡訊功能：
```bash
sudo systemctl status ModemManager --no-pager -l
mmcli -L
mmcli -m any --messaging-status
```

### 2) 設定檔與腳本權限
```bash
chmod 600 /etc/sms2tg.env
chmod 700 /usr/local/bin/sms-to-telegram.sh
```

### 3) 啟用 / 重啟 systemd 服務
```bash
systemctl daemon-reload
systemctl enable --now sms-to-telegram.service
systemctl restart sms-to-telegram.service
```

---

## 執行方式

- **前景測試**
  ```bash
  sudo /usr/local/bin/sms-to-telegram.sh
  ```
  首次啟動會等待 ModemManager 與 messaging 子系統就緒，再開始監看新簡訊。

- **背景執行（systemd）**  
  依上節啟用服務後即可自動啟動與開機自動執行。

---

## 運作流程（重點）

1. 設定 `mmcli` 預設逾時（例如 8 秒），避免個別讀寫卡住。
2. 收到 SMS 事件或掃描到新 SMS 後，先用 `--output-keyvalue` 取得欄位，再輔以 RAW 解析（必要時由 RAW 回填缺漏欄位）。
3. 文字空白但有 `content.data` 時嘗試 **UCS-2BE** 解碼；仍無法取得內容時，依設定轉發 HEX/RAW 摘要。
4. `OTP_ONLY=yes` 時，非 OTP 訊息會略過並刪除。
5. 成功送出即嘗試刪除簡訊（多種刪除語法以相容不同版本 `mmcli`）。
6. 以「已處理清單」去重，避免重複轉發。

---

## 取得 Telegram `CHAT_ID` 小撇步

1. 先把 Bot 加入你的群組／頻道並賦予發言權。  
2. 在群組任意發一則訊息，使用第三方工具或 Telegram Bot API 取得 `update`，即可看到群組的 `chat.id`（常見為負數）。

> 切勿把 `BOT_TOKEN` 上傳到公開倉庫或發在 issue／聊天群組。

---

## 疑難排解

- **收不到訊息**：確認 `ModemManager` 有管理到你的模組，且 `mmcli -m any --messaging-status` 正常回應；服務日誌中如顯示「waiting for modem…」代表尚未 ready。  
- **訊息是亂碼或空白**：檢查 `DEBUG_DUMP_FILE`（預設 `/var/log/sms2tg.last`）內的 KV 與 RAW；如出現 `content.data` HEX，腳本會嘗試 UCS-2 解碼。  
- **重複轉發**：清除「已處理清單」可能導致歷史訊息再被處理，請留意。  
- **權限錯誤**：請依上節指令設定 `/etc/sms2tg.env` 為 `600`、腳本為 `700`。  

---

## 安全性建議

- `/etc/sms2tg.env` 建議 **0600** 權限；腳本啟動時亦可使用 `umask 077`，避免產生過寬權限的檔案。  
- Bot 僅應加入你信任的群組或頻道，避免被濫用。

---

### 附錄：Telegram 訊息格式

成功轉發的 SMS 範例（Telegram 端為 **HTML** 格式，關閉連結預覽）：
```
📩 SMS
From: <來電號碼>
Time: <時間戳>
State: <狀態>

<訊息本文>
```
