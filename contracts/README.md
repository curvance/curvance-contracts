# Curvance Contracts

## Overview

This directory contains the core contracts for the Curvance protocol. All contracts are written using Solidity 0.8.29. 

## Directory Structure

```
contracts/
├── 📁 architecture/
├── 📁 calldata-checker/
├── 📁 interfaces/
├── 📁 libraries/
├── 📁 market/
├── 📁 misc/
├── 📁 mocks/
├── 📁 oracles/
├── 📁 plugins/
├── 📁 testnet/
├── 📁 token/
```

## Subdirectories

### 📁 architecture
**Purpose**: Core architecture contracts for the protocol, including a registry for the protocol's contracts, delegation, cross-chain communication, rewards, gauges, and more.

**Contents**:
- 📄 `CentralRegistry.sol`: Manages permissions and protocol contract registration within the Curvance Protocol.
- 📄 `CurvanceDAOTimelock.sol`: A timelock controller for the Curvance DAO that enforces a delay period before administrative operations can be executed.
- 📄 `FeeManager.sol`: A system for managing fee collected through Curvance DAO operations within Curvance Protocol.
- 📄 `GaugeManager.sol`: A market specific system for distributing rewards to Curvance market users inside the Curvance Protocol.
- 📄 `MessagingHub.sol`: A comprehensive system for cross-chain communication within the Curvance Protocol ecosystem
- 📄 `RewardManager.sol`: A system for managing rewards within the Curvance Protocol.
- 📄 `UniversalBalance.sol`: A user-facing system for flexible token management within the Curvance Protocol.
- 📄 `UniversalBalanceNative.sol`: A specialized system for managing native gas tokens within the Curvance Protocol.
- 📄 `VotingHub.sol`: Coordinates protocol-wide token emission allocation based on governance decisions

<br/>

---

### 📁 calldata-checker
**Purpose**: Tools for checking arbitrary calldata of transactions to ensure they are valid.

**Contents**:
- 📁 `multicall-checker/`: Contracts for validating multicall operations related to oracle price updates
- 📁 `swap-checker/`: Contracts for validating external swap operations and DEX interactions.
- 📄 `BaseCallDataChecker.sol`: A base contract that provides utility functions for parsing and examining calldata.

<br/>

---

### 📁 interfaces
**Purpose**: Interface contracts needed for Curvance to interact with its contracts internally and externally.

**Contents**:
- 📁 `external/`: Interface contracts needed for Curvance to interact with external contracts like DEXs, Oracles, etc.
- 📄 Interface contracts needed for Curvance to interact with its contracts internally.


<br/>

---

### 📁 Libraries
**Purpose**: Libraries for logic, types, type conversions, constants, smooth math operations, external contract interactions, primordial contracts, etc.

**Contents**:
- 📁 `external/`: Libraries for interacting with external contracts, like Wormhole, 

# !!!Come back to this section, file structure will probably change.!!!

<br/>

---

### 📁 market
**Purpose**: Contracts that contain logic for the Curvance market.

**Contents**
- 📁 `isolated/`: Contracts for isolated markets.
- 📁 `position-management/`: Contracts that contain the logic for managing leveraged positions.
- 📁 `token/`: Contracts for several different token types, including simple ERC20's and exotic assets. Also includes logic for eTokens (Debt Tokens) and pTokens. (Position/Collateral Tokens).
- 📄 `DynamicInterestRateModel.sol`: Manages borrow and supply interest rates for Curvance debt tokens.
- 📄 `LiquidationManager.sol`: Manages Curvance's liquidation queue system, enabling efficient capture of Optimal Extractable Value (OEV) while ensuring liquidations always proceed in a timely manner.
- 📄 `MarketManager.sol`: The MarketManager is the central risk management component in Curvance that governs interactions between collateral (pTokens) and debt (eTokens), implementing the dynamic liquidation engine with tiered thresholds to maintain system stability while supporting diverse asset types with isolated risk profiles.

<br/>

---

### 📁 misc

---
### 📁 mocks
---
### 📁 oracles
**Purpose**: Contracts that contain the logic for fetching data from external sources for Curvance's unique pricefeed system. Each pricefeed adaptor is responsible for fetching data from a specific source, and returning it in a standardized format. Adaptors are managed by the CentralRegistry.

**Contents**:
- 📁 `adaptors/`: A contract that contains the logic for fetching data from external sources for Curvance's unique pricefeed system.    
- 📄 `OracleManager.sol`: Provides a universal interface allowing contracts to retrieve secure pricing data based on various price feeds.
---
### 📁 plugins
**Purpose**: Contains independent helper contracts that are used to 'zap' into complex positions. They allow users to enter/exit positions across different protocols, swap, deposit, redeem, claim rewards, etc.

**Contents**:
- 📁 `market/`: Contains specialized zapper contracts that facilitate seamless interactions between users and various DeFi protocols (like Pendle and Velodrome), enabling complex multi-step operations to be executed in single transactions within the Curvance ecosystem.
- 📁 `rewards/`: Contracts that streamline the process of claiming rewards and reinvesting them into the protocol in a single transactions.
- 📄 `ZapperBase.sol`: An abstract contract that provides the foundational infrastructure for various zapper implementations in the Curvance protocol, handling common functionality such as token routing, protocol interactions, and slippage controls.
---
### 📁 testnet

---
### 📁 token

**Purpose**: Contains the core token contracts that power the Curvance protocol's economic system. 

**Contents**:
- 📄 `CVE.sol`: The main Curvance governance token contract that manages token allocations, implements vesting schedules, and handles controlled token minting for different stakeholders including treasury, community, and contributors.
- 📄 `CVEBase.sol`: An abstract base contract that provides fundamental CVE token functionality including cross-chain bridging capabilities, messaging, emissions minting, and permission controls shared across all CVE token implementations.
- 📄 `RemoteCVE.sol`: A simplified implementation of the CVE token designed for deployment on secondary chains that inherits core functionality from CVEBase but excludes token vesting functions present in the main CVE contract.
- 📄 `VeCVE.sol`: Vote-escrowed token implementation that enables CVE holders to lock their tokens for governance rights, featuring innovations like continuous lock mode, multichain voting capabilities, early expiry optionality, and a points-based reward system.

## Additional Information

### Usage Guidelines
- When adding new files, place them in the appropriate subdirectory based on their purpose.
- Maintain the directory structure to ensure project organization remains consistent.
- Reference this document when onboarding new team members.

*Last updated: 3/14/2025*

*Maintained by: Curvance Core Team*





