# CoA 注册站（容器化）

原服务：旧服 `192.168.1.89` 的 `C:\COA\CoA-Repack\WebRegister\register_server.py`
（纯标准库 `http.server` + `pymysql` + `Pillow`，无第三方 Web 框架）。现在改由
fn176 的容器 `coa-register` 承载，直接写**新服**的 `acore_auth.account`
（SRP6：`SHA1(salt || SHA1(USER^:PASS^))`，明文不落库），因此注册出来的账号
在本 realm 直接可用。

## 组成

```
webregister/
├── Dockerfile                    # python:3.12-slim + pymysql + pillow（pypi 走阿里云镜像）
└── context/
    ├── WebRegister/
    │   ├── register_server.py    # 上游源码，仅 2 处改动，见下
    │   └── index.html            # 余烬熔岩风格页面，{{REALM}} 由服务端替换
    └── Settings/
        ├── database.json         # {"appUser":"acore","appPassword":"…"}  ← 不提交
        └── repack.json           # mysqlHost/mysqlPort/realmAddress         ← 不提交
```

`register_server.py` 相对上游的改动（其余原样保留，便于日后与旧服对比）：

1. `load_config()` 支持可选的 `repack.json → mysqlHost` 与 `database.json → appUser`
   （默认仍是 `127.0.0.1` / `acore`）——容器里数据库主机名是 `coa-database`。
2. `realm_has_character()` 的 `characters` 表补上库名前缀 `acore_characters.characters`
   （原来是裸表名，连到 `acore_auth` 时必然查不到表、被 `except` 吞掉恒返回 0）。

## 端口与路由

| 路由 | 说明 |
| --- | --- |
| `GET /` `/index.html` | 注册页（`{{REALM}}` 替换为 `repack.json.realmAddress`） |
| `GET /captcha?sid=` | Pillow 位图验证码，`X-Captcha-Sid` 回传，300 s 单次有效 |
| `GET /health` | 连一次数据库，`{"status":"ok"}` / 503 `db-error` |
| `POST /api/qq/sendcode` | 经 NapCat OneBot（`http://192.168.1.176:3001`）发 6 位验证码 |
| `POST /api/register` | 校验验证码 + QQ 绑定 + 限额后建号 |

限额（源码常量）：同 IP 60 s 内 12 次失败、每 IP 每小时 5 个建号、同 QQ 24 h 3 次发码、
同 IP 每小时 10 次发码；客户端 IP 只信 `X-Real-IP`（nginx 强制覆盖），**禁止**改用
`X-Forwarded-For`（可伪造绕过限流）。

## 运行

```bash
# 1) 数据库账号（一次性，deploy.sh 里已自动化）
docker exec -i coa-database mysql -uroot -p"$COA_DB_ROOT_PASSWORD" <<'SQL'
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED BY '<appPassword>';
GRANT SELECT, INSERT, UPDATE, DELETE ON acore_auth.* TO 'acore'@'%';
GRANT SELECT ON acore_characters.* TO 'acore'@'%';
SQL

# 2) 建镜像 + 起服务
cd /vol1/1000/docker/coa-fn176
docker build -t coa-register:local webregister
docker compose up -d coa-register
curl -s http://127.0.0.1:8090/health
```

## 公网入口（隧道）

对外仍是 `https://register.soulcore.asia`：
`玩家 → VPS nginx(47.238.240.32:443) → 127.0.0.1:<remotePort> → frps → frpc(fn176) → coa-register:8090`。

容器 `coa-frpc`（compose profile `tunnel`，配置 `fn176/frpc.toml`）用与旧服相同的
`serverAddr = soulcore.asia:7000` 和 token，只注册一个代理
`coa-register-<remotePort>`。切换步骤见 `../README.md` 与部署记录：

1. VPS `/etc/frp/frps.toml` 的 `allowPorts` 加入新的 remotePort（如 8091），重启 `frps`；
2. VPS nginx vhost `coa-register` 的 `proxy_pass` 改指新端口，`nginx -t && systemctl reload nginx`；
3. 旧服 `.89` 上的 `CoA-Register` 计划任务与它的 8090 代理保留不动（成为历史路径，不再被外网使用）。
