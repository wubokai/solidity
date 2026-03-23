# MiniLendingMC_BadDebt_TWAP

A minimal but interview-ready overcollateralized multi-collateral lending protocol with explicit bad debt handling, TWAP-based oracle routing, protocol risk controls, and strong invariant-driven testing.

---

## Overview

This project is a simplified DeFi lending protocol designed to demonstrate the core mechanics and risk model behind overcollateralized lending systems.

It supports:

- single borrow asset pool
- multi-collateral deposits
- debt share + borrow index based interest accrual
- liquidation with close factor
- collateral-insufficient backsolve behavior
- explicit bad debt accounting
- oracle routing through a unified interface
- AMM TWAP based valuation integration
- governance risk controls such as pause, caps, and config sanity checks
- strong testing including unit tests, fuzz tests, invariants, and system-level risk propagation tests

The goal of this project is not only to implement the protocol mechanics, but also to clearly separate **accounting**, **risk valuation**, and **oracle/market data flow**, which is one of the most important design ideas in real DeFi systems.

---

## Core Features

### 1. Lending Core
- users can deposit the borrow asset into the pool
- users can withdraw their deposits if pool liquidity allows
- users can deposit supported collateral assets
- users can borrow the stable asset against collateral
- users can repay partially or fully

### 2. Multi-Collateral Support
- the protocol supports multiple collateral assets
- each collateral asset has its own collateral factor
- collateral valuation is performed through the oracle router

### 3. Interest Accrual with Debt Shares
- debt is represented by `debtShares`
- global debt growth is tracked by `borrowIndex`
- user debt is derived from shares × index
- this avoids updating every borrower’s debt on each accrual

### 4. Liquidation and Bad Debt
- unhealthy positions can be liquidated
- liquidation is restricted by `closeFactor`
- if collateral is insufficient, liquidation uses a backsolve path
- leftover unrecoverable debt can be realized as `badDebt`

### 5. Oracle Routing and TWAP
- the lending protocol does not directly depend on one specific oracle implementation
- prices are consumed through `OracleRouter`
- AMM TWAP adapter can be plugged into the router
- this reduces direct dependency on manipulable spot price

### 6. Governance and Risk Controls
- `pause / unpause`
- `supplyCap / borrowCap`
- config sanity checks
- owner-only admin controls
- risk parameters affect valuation and risk status, not nominal accounting balances

---

## Contracts

### Main Protocol
- `MiniLendingMC_BadDebt_TWAP.sol`  
  Main lending protocol contract. Handles deposits, collateral, borrowing, repay, liquidation, interest accrual, and bad debt realization.

### Oracle / Pricing
- `OracleRouter.sol`  
  Unified interface for reading asset prices used by the lending protocol.

- `AmmTwapAdapter.sol`  
  Adapter that converts AMM TWAP observations into a price source consumable by the router.

- `SimpleTWAPOracle.sol`  
  Stores cumulative observations and computes time-weighted average price.

- `FixedPriceOracle.sol`  
  Simple mock or fixed oracle used for controlled testing.

### AMM
- `MiniAMM.sol`  
  Minimal constant-product AMM used as the market data source for TWAP.

### Tokens / Mocks
- `MockERC20.sol`  
  Mock token used in tests and local integration flows.

---

## System Design

This protocol can be understood as three logical layers:

### 1. Accounting Layer
This layer records nominal user and protocol balances:

- `depositOf`
- `collateralOf`
- `debtSharesOf`
- `totalDeposits`
- `totalDebtShares`
- pool cash
- reserves
- badDebt

This layer should remain internally consistent regardless of how prices move.

### 2. Risk / Valuation Layer
This layer determines whether a position is safe:

- collateral valuation
- borrow power
- health factor
- liquidation eligibility
- bad debt realization conditions
- collateral factor effects

This layer may change when oracle prices or governance parameters change.

### 3. Market / Oracle Layer
This layer provides external pricing input:

- AMM reserves / spot market state
- cumulative price observations
- TWAP oracle
- TWAP adapter
- oracle router

This layer feeds the valuation layer, but should not directly mutate nominal accounting balances.

---

## Key Flows

### Deposit / Withdraw
1. A supplier deposits the borrow asset into the pool.
2. The protocol increases `depositOf(user)` and `totalDeposits`.
3. A supplier can later withdraw if the pool has enough cash and protocol constraints are satisfied.

### Deposit Collateral / Borrow
1. A user deposits supported collateral.
2. The protocol reads collateral price through `OracleRouter`.
3. Borrow power is calculated using collateral value × collateral factor.
4. Borrow is allowed only if the resulting health factor is safe and borrow caps are respected.
5. Debt is recorded as debt shares, not as a directly updated fixed balance.

### Repay / Withdraw Collateral
1. A borrower repays debt partially or fully.
2. Debt shares are burned according to current borrow index.
3. Collateral can only be withdrawn if the remaining position is still healthy.

### Liquidation / Bad Debt
1. If health factor falls below threshold, the position becomes liquidatable.
2. Liquidation repays part of the debt and seizes collateral with liquidation bonus.
3. Close factor limits how much debt can be repaid in a single liquidation.
4. If collateral is insufficient, the system uses a backsolve path and may leave residual unrecoverable debt.
5. That unrecoverable debt can later be realized as `badDebt`.

---

## Why Debt Shares + Borrow Index?

Instead of storing and updating each borrower’s debt amount every time interest accrues, this project uses:

- `debtSharesOf(user)`
- `totalDebtShares`
- `borrowIndex`

When interest accrues, only the global index changes.  
User debt is derived from:

debt = debtShares × borrowIndex

This design is much more scalable and closely follows the idea used in real lending systems.

---

## Why Use TWAP Instead of Spot?

AMM spot price is easy to manipulate in a single trade or via flash liquidity.

TWAP helps reduce this risk by averaging price over time.  
This increases the cost of manipulation, because an attacker must sustain distorted pricing for longer.

However, TWAP is not perfect:
- it still has lag risk
- it can still be influenced if the manipulation persists long enough
- shallow liquidity can still make it fragile

So TWAP is a mitigation, not a magical solution.

---

## Risk Controls

This protocol includes several important safety and risk-control ideas:

- overcollateralized borrowing
- collateral factor based borrow limits
- close factor limited liquidation
- pause system that blocks new risk but still allows `repay` and `liquidate`
- supply caps and borrow caps
- explicit bad debt accounting
- configuration sanity checks
- unified oracle routing
- separation between accounting state and valuation state

One important design principle in this project is:

> Oracle price changes, collateral factor changes, and governance config changes should affect risk interpretation, but should not directly mutate nominal accounting balances such as deposits, debt shares, or recorded collateral amounts.

---

## Testing Strategy

This project emphasizes protocol correctness through multiple layers of testing.

### Unit Tests
Used to verify:
- deposit / withdraw paths
- collateral flows
- borrow / repay behavior
- liquidation edge cases
- bad debt realization
- access control
- pause behavior
- cap behavior
- config sanity checks
- event emission

### Fuzz Tests
Used to verify behavior under random input combinations:
- rounding edge cases
- partial repay / partial liquidation
- boundary values
- unexpected action ordering
- dust handling

### Invariant Tests
Used to verify that core system relationships hold under long random sequences of actions.

Examples:
- `totalDeposits == sum(depositOf users)`
- `totalDebtShares == sum(debtSharesOf users)`
- `borrowIndex` is non-decreasing
- protocol collateral accounting does not exceed actual on-chain holdings
- `totalDebt ≈ totalDebtShares * borrowIndex / WAD`

### System / Scenario Tests
Used to verify protocol-level design properties:
- spot manipulation does not instantly propagate one-to-one into lending valuation when TWAP is used
- TWAP lag risk exists and is observable
- governance parameter changes affect risk status but not nominal accounting
- oracle price changes affect health factor and liquidation eligibility, not stored balances directly

---

## Repository Structure

```text
src/
  MiniLendingMC_BadDebt_TWAP.sol
  OracleRouter.sol
  AmmTwapAdapter.sol
  SimpleTWAPOracle.sol
  MiniAMM.sol
  FixedPriceOracle.sol
  MockERC20.sol

test/
  ...unit tests
  ...fuzz / invariant tests
  ...system scenario tests

docs/
  architecture.md
  security.md
  demo.md
  interview-notes.md    