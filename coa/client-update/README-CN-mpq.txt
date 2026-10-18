CoA 客户端补充包（MPQ 版，2026-10-18）
适用：rev8 客户端（CoA-Client-Patch-CN-20260924 / clientRevision 8）

包内容
  Data\patch-ZG.MPQ   __MPQ_SIZE__ 字节   sha256 __MPQ_SHA256__
    Interface\Icons\INV_GrootCoin.blp           物品 910001「Groot Coin」图标（必需）
    Interface\AddOns\AncientEnchantingAltars    外域祭坛地图标记（可选，上游 2026-10-15 新增）
    Interface\AddOns\CoACrowsCache              Crow's Cache 地图标记（可选，服务端当前未启用）

安装（每台客户端做一次）
  1. 完全退出游戏进程（不是退回角色界面）。
  2. 把 Data\patch-ZG.MPQ 放进客户端 Data\ 目录（不要解压）。
  3. 删除客户端 Cache\WDB 目录 —— 关键一步，不删图标仍会显示红色问号。
  4. 重新启动游戏；插件没生效就 /reload，或在角色选择界面的「插件」里确认已勾选。

为什么用 patch-ZG
  patch-ZG.MPQ 的加载顺序排在 patch-Z / patch-ZH 之后，用于覆盖或新增界面资源；
  这是上游仓库 modules/mod-ethereal-bazaar 对同一枚图标（displayid 990001）采用的官方做法。
  它不修改任何 CoA 官方文件（patch-B.MPQ / patch-T.MPQ / patch-Z.MPQ 均不动），
  因此上游每次客户端发版都不会与它冲突。

回滚
  删除 Data\patch-ZG.MPQ 与 Cache\WDB 即可，客户端回到原状。

与散装版的关系
  散装版（把 Interface\Icons\INV_GrootCoin.blp 等直接放进客户端目录）与本包内容完全等价，
  两者任选其一；WoW 中散装文件优先级高于 MPQ，同时装也不会冲突。

来源：github.com/jealous-sound/azerothcore-wotlk-coa
      （client/AncientEnchantingAltars、client-addons/CoACrowsCache、modules/mod-ethereal-bazaar/client-art）
INV_GrootCoin.blp sha256 = 3ca16759835b0974b8ec799a50f4024c6c9fcde636221f19e056b348e6b435ca
