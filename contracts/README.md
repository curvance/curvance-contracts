<h1> <img style="text-align: center; height: 18px" src="https://user-images.githubusercontent.com/77558763/148961492-99d86d51-41a3-45a8-9af6-bdc1a85c722b.png"/> curvance contracts</h1>

## Overview

This directory contains the core contracts for the Curvance protocol. All contracts are written using Solidity 0.8.29.

Curvance is a cross-chain, thesis-driven DeFi lending protocol designed to support diverse asset types while minimizing systemic risk. Key features include:

- **Dynamic Liquidation Engine (DLE)**: A multi-tiered liquidation system that efficiently balances risk management with capital efficiency.
- **Cross-Chain Architecture**: Native multi-chain support through a hub-and-spoke model powered by secure messaging protocols.
- **Thesis-Driven Markets**: Specialized markets with tailored risk parameters for different asset classes and investment theses.
- **Governance-Optimized Tokenomics**: A sophisticated CVE/veCVE system enabling protocol governance across multiple chains.
- **Security-First Design**: Comprehensive validation systems for external interactions, including dedicated calldata checkers for oracle updates and DEX operations.

The protocol implements isolated risk environments for exotic assets while providing deep liquidity for blue-chip collateral, all governed by a decentralized voting mechanism that directs token emissions based on community decisions.
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
**Purpose**: Foundational contracts that establish the core governance and operational infrastructure for the Curvance protocol. These contracts manage protocol-wide permissions, cross-chain communication, reward distribution, and token emissions governance, forming the secure backbone that enables all other protocol components to function cohesively across multiple chains.

**Contents**:
- 📄 `CentralRegistry.sol`: Manages permissions and protocol contract registration within the Curvance Protocol.
- 📄 `DAOTimelock.sol`: A timelock controller for the Curvance DAO that enforces a delay period before administrative operations can be executed.
- 📄 `FeeManager.sol`: A system for managing fee collected through Curvance DAO operations within Curvance Protocol.
- 📄 `GaugeManager.sol`: A market specific system for distributing rewards to Curvance market users inside the Curvance Protocol.
- 📄 `MessagingHub.sol`: A comprehensive system for cross-chain communication within the Curvance Protocol ecosystem
- 📄 `RewardManager.sol`: A system for managing rewards within the Curvance Protocol.
- 📄 `UniversalBalance.sol`: A user-facing system for flexible token management within the Curvance Protocol.
- 📄 `NativeUniversalBalance.sol`: A specialized system for managing native gas tokens within the Curvance Protocol.
- 📄 `VotingHub.sol`: Coordinates protocol-wide token emission allocation based on governance decisions

<br/>

---

### 📁 calldata-checker
**Purpose**: Security infrastructure that validates external transaction calldata for critical protocol operations, protecting against malicious inputs and ensuring transaction integrity. These contracts enable secure oracle updates and DEX interactions by validating calldata structures, parameters, and execution paths before allowing external data or swap operations to affect the protocol.

**Contents**:
- 📁 `multicall-checker/`: Contracts for validating multicall operations related to oracle price updates
- 📁 `swap-checker/`: Contracts for validating external swap operations and DEX interactions.
- 📄 `BaseCalldataChecker.sol`: A base contract that provides utility functions for parsing and examining calldata.

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
Core lending infrastructure that implements Curvance's unique Dynamic Liquidation Engine (DLE) and thesis-driven market approach. This directory contains the MarketManager contract which manages risk between collateral (pTokens) and debt (eTokens), with specialized components for liquidity management, position leveraging, and isolated markets - all designed to support diverse asset types while minimizing systemic risk.

**Contents**
- 📁 `isolated/`: Contracts for isolated markets.
- 📁 `position-management/`: Contracts that contain the logic for managing leveraged positions.
- 📁 `token/`: Contracts for several different token types, including simple ERC20's and exotic assets. Also includes logic for eTokens (Debt Tokens) and pTokens. (Position/Collateral Tokens).
- 📄 `DynamicIRM.sol`: Manages borrow and supply interest rates for Curvance debt tokens.
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
- 📄 `BaseZapper.sol`: An abstract contract that provides the foundational infrastructure for various zapper implementations in the Curvance protocol, handling common functionality such as token routing, protocol interactions, and slippage controls.
---
### 📁 testnet

---
### 📁 token

**Purpose**: Implements Curvance's sophisticated tokenomics framework through a system of cross-chain compatible governance tokens (CVE) and vote-escrowed mechanics (veCVE). These contracts power the protocol's economic incentives, governance mechanisms, and multichain operations while managing token allocations, vesting schedules, and reward distribution - establishing both the protocol's ownership structure and its value accrual mechanisms.

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





