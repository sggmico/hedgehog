# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在本项目中工作时提供指导。

## 开发规范

### 工作流程规范
1. **功能完整性原则**：以完整的功能模块为单位进行开发，每完成一个功能模块后必须询问用户是否继续，或者进行阶段性总结输出
2. **代码推送权限**：在用户明确同意之前，不得推送代码到远程仓库
3. **简洁设计原则**：避免过度设计，保持代码简洁和易读，优先实现核心功能
4. **注释规范**：
   - 使用中文注释，注释必须简洁明了
   - 专业术语和技术名词可以使用英文
   - 避免冗长的解释，突出关键信息

### 代码质量要求
- 遵循 Solidity 最佳实践
- 所有外部调用使用 Checks-Effects-Interactions 模式
- 使用 ReentrancyGuard 防止重入攻击
- 使用 Solidity 0.8.x 内置溢出检查
- 使用 OpenZeppelin AccessControl 进行权限控制
- 关键参数修改需要 48 小时时间锁

## 项目概述

Hedgehog (刺猬协议) 是一个去中心化衍生品交易平台，主要特性：
- 永续合约和去中心化期权交易
- 混合 AMM 机制（vAMM + 订单簿）
- AI 驱动的风险管理
- zkSNARK 隐私层
- 跨链资产支持

**当前状态**：Phase 1 开发阶段 - 核心合约实现中

## 开发命令

```bash
# 安装依赖
npm install

# 编译智能合约
npx hardhat compile

# 运行测试
npx hardhat test

# 部署到测试网
npx hardhat run scripts/deploy.js --network arbitrum-goerli

# 前端开发（创建后）
cd frontend && npm run dev
```

## 智能合约架构

### 合约目录结构

```
contracts/
├── core/              # 核心交易合约
│   ├── PerpetualMarket.sol    # 永续合约市场
│   ├── OptionsMarket.sol      # 期权市场
│   ├── Vault.sol              # 资金库（已完成）
│   └── ClearingHouse.sol      # 清算所
├── amm/               # AMM 机制
│   ├── VirtualAMM.sol         # 虚拟 AMM（已完成）
│   ├── LiquidityPool.sol      # 流动性池
│   └── FundingRate.sol        # 资金费率（已完成）
├── oracle/            # 价格预言机
│   ├── PriceOracle.sol        # 价格聚合器（已完成）
│   ├── ChainlinkAdapter.sol   # Chainlink 适配器（已完成）
│   └── PythAdapter.sol        # Pyth 适配器
├── risk/              # 风险管理
│   ├── RiskEngine.sol         # 风险引擎
│   ├── InsuranceFund.sol      # 保险基金
│   └── Liquidator.sol         # 清算器
├── governance/        # 治理与代币
│   ├── HedgehogToken.sol      # HEDGE 代币（已完成）
│   ├── TokenVesting.sol       # 代币锁仓（已完成）
│   ├── StakingRewards.sol     # 质押奖励
│   └── DAO.sol                # DAO 治理
└── utils/             # 工具合约
    └── MockERC20.sol          # 测试代币
```

### 技术栈

**区块链层**: Arbitrum One (主网), Solidity 0.8.20
**后端**: Rust (订单撮合引擎), Node.js + Express, Redis, Kafka
**前端**: React 18 + TypeScript, ethers.js v6, TradingView 图表, Zustand
**数据层**: InfluxDB (时序数据), PostgreSQL, The Graph
**运维**: Docker + Kubernetes, GitHub Actions

### 系统分层

1. **用户界面层**: Web/移动端应用, TradingView 插件, API SDK
2. **应用服务层**: API 网关, WebSocket, 认证服务
3. **业务逻辑层**: 订单引擎, 风险管理, 价格推送, 清算, 分析
4. **区块链交互层**: 智能合约, 事件监听, 交易管理
5. **区块链网络层**: Arbitrum, Optimism, Ethereum, Polygon, BSC

## 开发路线图

### Phase 1 (6个月) - 基础设施 ⏳ 进行中

**已完成**:
- ✅ Vault 资金库
- ✅ HEDGE 治理代币
- ✅ TokenVesting 代币锁仓
- ✅ PriceOracle 价格聚合器
- ✅ ChainlinkAdapter 适配器
- ✅ VirtualAMM 虚拟做市商
- ✅ FundingRate 资金费率

**待开发**:
- ⏳ InsuranceFund 保险基金
- ⏳ RiskEngine 风险引擎
- ⏳ Liquidator 清算器
- ⏳ PerpetualMarket 永续合约市场
- ⏳ ClearingHouse 清算所
- ⏳ 交易 UI（钱包集成：MetaMask, WalletConnect）
- ⏳ REST API 和 WebSocket 服务

### Phase 2 (6个月) - 高级功能

- 期权协议（Black-Scholes 定价）
- 跨链集成（LayerZero）
- zkSNARK 隐私电路
- 跟单交易系统
- DAO 治理
- 质押奖励

### Phase 3 (12个月) - 生态建设

- 机器学习风险引擎
- 结构化产品
- 机构 API 交易
- 移动端应用（iOS/Android）

## 风险管理参数

### 仓位管理
- 初始保证金：1%-20%（基于资产波动率）
- 维持保证金：0.5%-10%
- 清算阈值：维持保证金的 80%

### 预言机安全
- 多源价格聚合（Chainlink 主要，Pyth Network，Uniswap TWAP）
- 中位数算法防止操纵
- ±3σ 偏差监控
- MEV 攻击保护

### 熔断机制
- 价格偏离现货 ±10% 时暂停新开仓
- 小时波动率 >20% 时强制减仓
- 紧急暂停功能

## 代币经济模型

### HEDGE 代币（总量 10亿）
- 40% 社区激励（流动性挖矿、交易奖励）
- 20% 团队/顾问（4年锁仓）
- 15% 早期投资者（2年锁仓）
- 15% DAO 金库
- 10% 公开销售

### 收入模式
- 交易手续费：0.05%-0.1%
- 持仓资金费率
- 清算罚金：5%
- 期权交易费：0.3%

## 文档结构

遵循以下文档组织结构：
- `docs/whitepaper/` - 技术和经济白皮书（中英文）
- `docs/developer/` - 智能合约、SDK、集成指南
- `docs/user/` - 入门指南、交易教程、常见问题
- `docs/research/` - AMM 设计、风险引擎、ZK 隐私

## 重要信息

- README.md 为中文，包含完整的规划文档
- 目标部署：Arbitrum One（低 Gas、高 TPS）
- 最大杠杆：100x（对比：dYdX 20x，GMX 50x）
- 计划审计：OpenZeppelin, Trail of Bits, Consensys Diligence
- 开源协议：合约/前端 MIT，后端 AGPL-3.0

## 开发状态追踪

### 当前 Sprint
- 核心合约开发
- 单元测试编写
- 集成测试准备

### 下一步计划
根据用户确认后继续推进 Phase 1 剩余功能模块
