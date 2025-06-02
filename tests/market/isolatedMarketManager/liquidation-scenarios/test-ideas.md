
# Liquidation Test Scenarios for MarketManagerIsolated (pBALRETH and USDC)

## Scenario 1: Multiple Users Liquidated
- Setup: 5 users with varying health factors
- User 1: 1.0 pBALRETH ($1,600), 800 USDC debt (healthy)
- User 2: 1.0 pBALRETH ($1,600), 1,000 USDC debt (borderline)
- User 3: 1.0 pBALRETH ($1,600), 1,100 USDC debt (soft liquidation)
- User 4: 1.0 pBALRETH ($1,600), 1,200 USDC debt (hard liquidation)
- User 5: 1.0 pBALRETH ($1,600), 1,300 USDC debt (severe liquidation)
- Action: Price drop of pBALRETH by 15% (to $1,360)
- Expected: Users 3, 4, and 5 should be liquidated in single transaction

## Scenario 2: Mixed Liquidation Results
- Setup: 4 users with different positions
- User 1: 2.5 pBALRETH ($4,000), 2,500 USDC debt (very healthy)
- User 2: 2.0 pBALRETH ($3,200), 2,500 USDC debt (healthy)
- User 3: 1.8 pBALRETH ($2,880), 2,500 USDC debt (borderline)
- User 4: 1.7 pBALRETH ($2,720), 2,500 USDC debt (risky)
- Action: Price drop of pBALRETH by 10% (to $1,440)
- Expected: Users 3 and 4 liquidated, Users 1 and 2 remain healthy

## Scenario 3: No Users Liquidated
- Setup: 3 users with healthy positions
- User 1: 1.5 pBALRETH ($2,400), 1,000 USDC debt
- User 2: 1.4 pBALRETH ($2,240), 1,000 USDC debt
- User 3: 1.3 pBALRETH ($2,080), 1,000 USDC debt
- Action: Price drop of pBALRETH by 5% (to $1,520)
- Expected: No liquidations occur

## Scenario 4: Mixed Atlas and Regular Liquidations
- Setup: 4 users with varying positions
- User 1: 1.0 pBALRETH ($1,600), 1,200 USDC debt (for Atlas)
- User 2: 0.95 pBALRETH ($1,520), 1,200 USDC debt (for Atlas)
- User 3: 0.9 pBALRETH ($1,440), 1,200 USDC debt (for regular)
- User 4: 0.85 pBALRETH ($1,360), 1,200 USDC debt (for regular)
- Action 1: Price drop by 12% (to $1,408), Atlas transaction with custom parameters for User 1
- Action 2: Price drop by another 3% (to $1,366), Atlas transaction for User 2
- Action 3: Regular liquidation attempt for all users
- Expected: Users 1 and 2 liquidated via Atlas with custom parameters, Users 3 and 4 via regular liquidation

## Scenario 5: Liquidations with Some Bad Debt
- Setup: 5 users with varying risk levels
- User 1: 0.75 pBALRETH ($1,200), 1,000 USDC debt
- User 2: 0.7 pBALRETH ($1,120), 1,000 USDC debt
- User 3: 0.67 pBALRETH ($1,072), 1,000 USDC debt
- User 4: 0.65 pBALRETH ($1,040), 1,000 USDC debt
- User 5: 0.625 pBALRETH ($1,000), 1,000 USDC debt
- Action: Severe price drop of pBALRETH by 25% (to $1,200)
- Expected: All users liquidated, Users 3, 4, and 5 generate bad debt

## Scenario 6: No Normal Liquidation But One Bad Debt
- Setup: 3 users with borderline positions
- User 1: 0.8 pBALRETH ($1,280), 1,000 USDC debt
- User 2: 0.75 pBALRETH ($1,200), 1,000 USDC debt
- User 3: 0.65 pBALRETH ($1,040), 1,000 USDC debt
- Action: Specific price manipulation that doesn't trigger liquidation thresholds but creates underwater position for User 3
- Expected: Regular liquidation attempt fails for all, but bad debt resolution works for User 3

## Scenario 7: No Normal Liquidation But Multiple Bad Debts
- Setup: 4 users with risky positions
- User 1: 0.75 pBALRETH ($1,200), 1,000 USDC debt
- User 2: 0.7 pBALRETH ($1,120), 1,000 USDC debt
- User 3: 0.65 pBALRETH ($1,040), 1,000 USDC debt
- User 4: 0.63 pBALRETH ($1,008), 1,000 USDC debt
- Action: Complex price scenario that doesn't trigger standard liquidation but renders multiple positions underwater
- Expected: Bad debt resolution for Users 3 and 4, no liquidation for Users 1 and 2

## Scenario 8: Sequential Atlas Liquidations
- Setup: 3 users with nearly identical positions
- User 1: 0.7 pBALRETH ($1,120), 1,000 USDC debt
- User 2: 0.68 pBALRETH ($1,088), 1,000 USDC debt
- User 3: 0.66 pBALRETH ($1,056), 1,000 USDC debt
- Action 1: Small price drop to $1,050, Atlas transaction with 15% penalty for User 1
- Action 2: Further price drop to $1,020, Atlas transaction with 20% penalty for User 2
- Action 3: Final price drop to $1,000, Atlas transaction with 25% penalty for User 3
- Expected: Sequential liquidations with increasing penalties

## Scenario 9: Exact vs. Maximum Liquidation
- Setup: 3 users with identical positions
- Each user: 0.75 pBALRETH ($1,200), 1,000 USDC debt
- Action 1: Price drop to $1,100 to trigger liquidation eligibility
- Action 2: Exact liquidation of 300 USDC debt for User 1
- Action 3: Maximum liquidation for User 2
- Action 4: Partial liquidation (500 USDC) for User 3
- Expected: Different liquidation amounts based on specified approach

## Scenario 10: Edge Cases
- Test with minimum collateral (0.01 pBALRETH)
- Test with maximum allowable position sizes (100+ pBALRETH)
- Test with very small price movements at liquidation boundaries
- Test with extreme liquidation incentives at min/max config values


# Additional Liquidation Test Scenarios for MarketManagerIsolated

## Scenario 11: Cascading Liquidations
- Setup: 5 users with interconnected risk profiles
- Each user: 1.0 pBALRETH ($1,600), 1,100 USDC debt
- Action: Gradual price decline in 5% increments
- Expected: Each price drop triggers a new set of liquidations, affecting market dynamics for remaining users

## Scenario 12: Partial Liquidations with Recovery
- Setup: 3 users with identical positions
- Each user: 1.25 pBALRETH ($2,000), 1,500 USDC debt
- Action 1: Price drop to $1,450, triggering partial liquidations
- Action 2: Price recovery to $1,550
- Action 3: Additional borrowing after recovery
- Action 4: Second price drop to $1,400
- Expected: Test how previous partial liquidations affect subsequent liquidation eligibility

## Scenario 13: Threshold Boundary Testing
- Setup: 10 users with positions at precise health factor intervals
- User 1-10: 1.0 pBALRETH with debt ranging from 1,000-1,300 USDC in 30 USDC increments
- Action: Price adjustments in very small increments (0.25%)
- Expected: Identify exact threshold where each position becomes liquidatable

## Scenario 14: Liquidation with Accrued Interest
- Setup: 4 users with identical initial positions
- Each user: 1.0 pBALRETH ($1,600), 1,000 USDC initial debt
- Action 1: Time passage simulation causing interest accrual
- Action 2: Price drop of pBALRETH by 10%
- Expected: Different liquidation outcomes based on varying total debt due to interest

## Scenario 15: Maximum Gas Efficiency Test
- Setup: 20+ users with similar underwater positions
- Each user: Slight variations of ~0.8 pBALRETH, ~1,200 USDC debt
- Action: Bulk liquidation attempt in single transaction
- Expected: Test gas limits and optimization of multiple liquidations

## Scenario 16: Liquidation Under Extreme Volatility
- Setup: 5 users with varied positions
- Action 1: Rapid price oscillations (±20% repeatedly)
- Action 2: Liquidation attempts during price swings
- Expected: Test system resilience during extreme market conditions

## Scenario 17: Minimum Liquidation Size Testing
- Setup: Users with very small positions
- User 1: 0.01 pBALRETH ($16), 10 USDC debt
- User 2: 0.005 pBALRETH ($8), 5 USDC debt
- Action: Price drop triggering liquidation eligibility
- Expected: Test system behavior with dust positions

## Scenario 18: Recovery Position Testing
- Setup: 3 users with liquidated positions
- Action 1: Initial liquidation event
- Action 2: Users attempt to add new collateral post-liquidation
- Action 3: Users attempt to repay remaining debt
- Expected: Test behavior of accounts attempting recovery after liquidation

## Scenario 19: Collateral Exhaustion Test
- Setup: 3 users with positions near total liquidation
- User 1: 1.0 pBALRETH, 1,550 USDC debt
- User 2: 1.0 pBALRETH, 1,570 USDC debt
- User 3: 1.0 pBALRETH, 1,590 USDC debt
- Action: Price drop causing near-complete liquidation
- Expected: Test behavior when almost all collateral must be seized

## Scenario 20: Price Recovery During Liquidation
- Setup: 5 users eligible for liquidation
- Action 1: Price drop triggering liquidation eligibility
- Action 2: Partial liquidation of first 2 users
- Action 3: Price recovery before remaining users are liquidated
- Expected: Test if remaining users escape liquidation after price recovery

## Scenario 21: Different LTV Ratio Testing
- Setup: Multiple users with same dollar value but different collateral-to-debt ratios
- User 1: 0.5 pBALRETH ($800), 400 USDC (50% LTV)
- User 2: 1.0 pBALRETH ($1,600), 1,000 USDC (62.5% LTV)
- User 3: 2.0 pBALRETH ($3,200), 2,400 USDC (75% LTV)
- Action: Uniform price drop of 20%
- Expected: Different liquidation outcomes based on initial LTV

## Scenario 22: Multiple Oracle Price Updates During Liquidation
- Setup: 10 users eligible for liquidation
- Action 1: Initial price drop triggering eligibility
- Action 2: Begin liquidation process
- Action 3: Price updates during ongoing liquidations
- Expected: Test system response to changing prices mid-liquidation

## Scenario 23: Stress Test with Maximum Protocol Capacity
- Setup: Hundreds of positions near liquidation threshold
- Action: Price drop triggering mass liquidation event
- Expected: Test protocol performance under maximum stress

## Scenario 24: Liquidation When Collateral Cap Reached
- Setup: Market with collateral cap nearly reached
- Action 1: New users try to add collateral at cap
- Action 2: Price drop triggering liquidations
- Expected: Test interaction between collateral caps and liquidation process

## Scenario 25: Atlas Parameter Edge Cases
- Setup: Users near liquidation threshold
- Action 1: Atlas transaction with minimum allowed penalty
- Action 2: Atlas transaction with maximum allowed penalty
- Action 3: Atlas transaction with boundary close factors
- Expected: Test full range of Atlas parameter adjustments
