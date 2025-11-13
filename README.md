# 🪙 TXTON Token

**TXTON** is a fixed-supply ERC20 token with advanced administrative controls, secure minting, deposit-based burning, and batch airdrop capabilities.  
It is built using **OpenZeppelin** contracts and implements robust safety features including **AccessControl**, **ReentrancyGuard**, and configurable burn logic.

---

## 📜 Overview

TXTON is designed to provide a controlled and transparent token economy.  
It supports:
- Role-based access management for minting, burning, and airdrops.  
- Configurable **burn intervals** and **burn divisors**.  
- **Deposit-based burning** (users deposit tokens that can later be burned).  
- **Batch airdrops** (up to 50 recipients per transaction).  
- **Safe token recovery** and **ETH forwarding** to the admin.

---

## ⚙️ Key Features

| Feature | Description |
|----------|--------------|
| **Fixed Max Supply** | 200,000,000 TXTON (6 decimals) |
| **Initial Mint** | 20% (40,000,000 TXTON) minted to admin on deployment |
| **Roles** | `ADMIN_ROLE`, `MINT_ROLE`, `BURN_ROLE`, `AIRDROP_ROLE` |
| **Deposit-based Burn** | Tokens can be deposited for future scheduled burns |
| **Configurable Burn Divisor** | Controls periodic burn size (`burnAmount = totalSupply / burnDivisor`) |
| **Configurable Burn Interval** | Default: once per year (`365 days`) |
| **Batch Airdrops** | Distribute tokens to up to 50 addresses in one call |
| **Secure Recovery** | Recover accidentally sent ERC20 tokens or excess TXTON safely |
| **ETH Handling** | Automatically forwards received ETH to admin |

---

## 🔐 Roles and Permissions

| Role | Description |
|------|--------------|
| `DEFAULT_ADMIN_ROLE` | Full administrative rights (granted to the deployer) |
| `ADMIN_ROLE` | Configure burn settings, transfer admin rights, withdraw ETH, recover tokens |
| `MINT_ROLE` | Mint new tokens (up to max supply) |
| `BURN_ROLE` | Trigger scheduled or full burns |
| `AIRDROP_ROLE` | Execute batch airdrops |

---

## 🧮 Tokenomics

| Parameter | Value |
|------------|--------|
| **Max Supply** | `200,000,000 TXTON` |
| **Decimals** | `6` |
| **Initial Mint to Admin** | `20% of total supply` |
| **Burn Mechanism** | Deposit-based & scheduled burns |
| **Default Burn Divisor** | `100,000,000` (~0.001% per burn) |
| **Default Burn Interval** | `365 days` |

---

## 🔥 Burn Mechanism

1. **Users deposit tokens** using `depositForBurn(amount)`.
2. The contract records the amount in `BurnBalance`.
3. When the burn interval passes, an authorized account (`BURN_ROLE`) can call:
   - `triggerBurnFromDeposits()` — burns only deposited tokens, respecting the divisor.
   - `burnAllDeposited()` — burns all deposited tokens immediately.

**Safety checks** ensure:
- Burns cannot exceed deposits.
- Burns occur only after the configured interval.
- Divisor is bounded to prevent misconfiguration.

---

## 🎁 Airdrop System

Admins (with `AIRDROP_ROLE`) can distribute tokens efficiently via:
```solidity
airdrop(address[] calldata recipients, uint256[] calldata amounts)
