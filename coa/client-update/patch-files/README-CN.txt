CoA 客户端补充包（2026-10-18）
适用：现役 rev8 客户端（CoA-Client-Patch-CN-20260924 / clientRevision 8，Extensions.dll 端点已指向 soulcore.asia）

本包补的是上游仓库里“客户端侧”的文件，共三项：

1) Interface\Icons\INV_GrootCoin.blp            必需
   服务端物品 910001「Groot Coin」使用自定义显示 ID 990001（InventoryIcon_1 = INV_GrootCoin）。
   服务端只会把显示行的“元数据”下发给客户端，不会传贴图；客户端缺少这个贴图时，物品图标显示成红色问号。
2) Interface\AddOns\AncientEnchantingAltars     可选（地图标记）
   上游 2026-10-15 新增：外域祭坛地图标记（依赖 CoA 客户端内建的 DB_MapPOI）。
3) Interface\AddOns\CoACrowsCache               可选（当前无效）
   Crow's Cache 高风险 PvP 事件的地图标记；服务端 CrowsCache.Enable 目前为 0，启用后才会显示。

安装（每台客户端各做一次）
1. 完全退出游戏进程（不是回角色界面）。
2. 把本包内容解压覆盖到客户端根目录（与 Ascension.exe / Data\ / Interface\ 同级）。
   只需要修图标的话，只放第 1 项那一个文件即可。
3. 删除客户端目录下的 Cache\WDB —— 关键一步，不删的话图标会继续用旧缓存，仍然显示问号。
4. 重新启动游戏。插件没生效就 /reload 或再重启一次，并在角色选择界面的“插件”里确认已勾选。

说明
- 本包不含 patch-B.MPQ / patch-T.MPQ / patch-Z.MPQ，不改客户端二进制，也不动 realmlist。
- 以后若要做成单文件 MPQ（patch-ZG.MPQ），需要 mpqcli + 客户端原始 patch-M.MPQ，可用上游脚本
  modules/mod-ethereal-bazaar/client-art/build_client_patch.sh 生成（其 README 有完整步骤与回滚 SQL）。
- 服务端侧以后按需开 CrowsCache（modules/coa.conf 的 CrowsCache.Enable = 1）与 Manastorm 模式。
来源：github.com/jealous-sound/azerothcore-wotlk-coa（client/、client-addons/、modules/mod-ethereal-bazaar/client-art/）
INV_GrootCoin.blp sha256 = 3ca16759835b0974b8ec799a50f4024c6c9fcde636221f19e056b348e6b435ca
