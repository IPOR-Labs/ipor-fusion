// Verification of a created vault's state.
//
// Reading and checking are separate on purpose: `readVaultState` talks to a
// node, `checkVaultState` is a pure function over what was read. The checks can
// therefore be tested without a network, and the same rules apply to a
// simulated creation and to one resolved from a real receipt.
//
// Fee percentages are two-decimal percent (100 = 1%), which is numerically the
// same as basis points, the unit the factory's fee packages use.

import { ChainError, cast } from "./chain.mjs";

const same = (left, right) => String(left).toLowerCase() === String(right).toLowerCase();

/// One `cast call` against a node, returning the raw decoded lines.
function call(rpcUrl, address, signature, args = []) {
    const output = cast(["call", "--rpc-url", rpcUrl, address, signature, ...args.map(String)]);
    return output.split("\n").map((line) => line.trim());
}

/// Components whose readings are optional: a receipt may not let every address
/// be resolved, and a missing reading is reported as unresolved, never as a pass.
export async function readVaultState(rpcUrl, instance, factoryAddress) {
    const codeSize = (address) => cast(["code", "--rpc-url", rpcUrl, address]).length;
    const one = (address, signature, args) => call(rpcUrl, address, signature, args)[0];

    const [hasOwnerRole, ownerDelay] = call(rpcUrl, instance.accessManager, "hasRole(uint64,address)(bool,uint32)", [
        1,
        instance.initialOwner,
    ]);
    const managementFeeData = call(rpcUrl, instance.plasmaVault, "getManagementFeeData()((address,uint16,uint32))");
    const performanceFeeData = call(rpcUrl, instance.plasmaVault, "getPerformanceFeeData()((address,uint16))");
    const tuple = (lines) =>
        lines
            .join("")
            .replace(/[()\s]/g, "")
            .split(",");
    const management = tuple(managementFeeData);
    const performance = tuple(performanceFeeData);

    return {
        components: Object.fromEntries(
            [
                "plasmaVault",
                "accessManager",
                "feeManager",
                "rewardsManager",
                "withdrawManager",
                "contextManager",
                "priceManager",
            ]
                .filter((key) => instance[key])
                .map((key) => [key, { address: instance[key], codeChars: codeSize(instance[key]) }]),
        ),
        vault: {
            asset: one(instance.plasmaVault, "asset()(address)"),
            decimals: one(instance.plasmaVault, "decimals()(uint8)"),
            name: one(instance.plasmaVault, "name()(string)").replace(/^"|"$/g, ""),
            symbol: one(instance.plasmaVault, "symbol()(string)").replace(/^"|"$/g, ""),
            accessManager: one(instance.plasmaVault, "getAccessManagerAddress()(address)"),
            priceOracleMiddleware: one(instance.plasmaVault, "getPriceOracleMiddleware()(address)"),
            rewardsClaimManager: one(instance.plasmaVault, "getRewardsClaimManagerAddress()(address)"),
            managementFeeAccount: management[0],
            managementFeeInPercentage: management[1],
            performanceFeeAccount: performance[0],
            performanceFeeInPercentage: performance[1],
        },
        underlying: {
            decimals: one(instance.underlyingToken, "decimals()(uint8)"),
            symbol: one(instance.underlyingToken, "symbol()(string)").replace(/^"|"$/g, ""),
        },
        access: {
            ownerHasRole: hasOwnerRole === "true",
            ownerExecutionDelay: ownerDelay,
            redemptionDelaySeconds: one(instance.accessManager, "REDEMPTION_DELAY_IN_SECONDS()(uint256)"),
        },
        withdraw: instance.withdrawManager
            ? {
                  plasmaVault: one(instance.withdrawManager, "getPlasmaVaultAddress()(address)"),
                  windowSeconds: one(instance.withdrawManager, "getWithdrawWindow()(uint256)"),
              }
            : null,
        fees: {
            plasmaVault: one(instance.feeManager, "PLASMA_VAULT()(address)"),
            daoManagementFee: one(instance.feeManager, "IPOR_DAO_MANAGEMENT_FEE()(uint256)"),
            daoPerformanceFee: one(instance.feeManager, "IPOR_DAO_PERFORMANCE_FEE()(uint256)"),
            daoFeeRecipient: one(instance.feeManager, "getIporDaoFeeRecipientAddress()(address)"),
            totalManagementFee: one(instance.feeManager, "getTotalManagementFee()(uint256)"),
            totalPerformanceFee: one(instance.feeManager, "getTotalPerformanceFee()(uint256)"),
            managementFeeAccount: one(instance.feeManager, "MANAGEMENT_FEE_ACCOUNT()(address)"),
            performanceFeeAccount: one(instance.feeManager, "PERFORMANCE_FEE_ACCOUNT()(address)"),
        },
        factory: {
            address: factoryAddress,
            withdrawWindowSeconds: one(factoryAddress, "getWithdrawWindowInSeconds()(uint256)"),
            plasmaVaultBase: one(factoryAddress, "getPlasmaVaultBaseAddress()(address)"),
        },
    };
}

/// Pure rules. `expected` carries what the user asked for; every other value is
/// checked against another value read from the same chain, never against a
/// constant written down here.
export function checkVaultState(readings, expected, instance) {
    const checks = [];
    const unresolved = [];
    const record = (id, description, ok, observed, wanted) =>
        checks.push({ id, description, ok, observed: String(observed), expected: String(wanted) });

    for (const [key, component] of Object.entries(readings.components)) {
        record(
            `component.${key}.code`,
            `${key} exists and has runtime code`,
            component.codeChars > 2 && !/^0x0{40}$/i.test(component.address),
            `${component.address} (${component.codeChars} hex chars)`,
            "non-zero address with code",
        );
    }

    record(
        "vault.asset",
        "the vault's asset is the requested underlying token",
        same(readings.vault.asset, expected.underlying),
        readings.vault.asset,
        expected.underlying,
    );
    record(
        "vault.name",
        "the vault carries the requested name",
        readings.vault.name === expected.name,
        readings.vault.name,
        expected.name,
    );
    record(
        "vault.symbol",
        "the vault carries the requested symbol",
        readings.vault.symbol === expected.symbol,
        readings.vault.symbol,
        expected.symbol,
    );
    record(
        "underlying.decimals",
        "the underlying token's decimals are the ones the input declared",
        String(readings.underlying.decimals) === String(expected.underlyingDecimals),
        readings.underlying.decimals,
        expected.underlyingDecimals,
    );
    record(
        "vault.decimals",
        "the vault's decimals match the instance the factory reported",
        String(readings.vault.decimals) === String(instance.assetDecimals),
        readings.vault.decimals,
        instance.assetDecimals,
    );
    record(
        "vault.accessManager",
        "the vault points at its own access manager",
        same(readings.vault.accessManager, instance.accessManager),
        readings.vault.accessManager,
        instance.accessManager,
    );
    record(
        "vault.priceOracleMiddleware",
        "the vault points at its own price manager",
        same(readings.vault.priceOracleMiddleware, instance.priceManager),
        readings.vault.priceOracleMiddleware,
        instance.priceManager,
    );
    record(
        "vault.rewardsClaimManager",
        "the vault points at its own rewards manager",
        same(readings.vault.rewardsClaimManager, instance.rewardsManager),
        readings.vault.rewardsClaimManager,
        instance.rewardsManager,
    );
    record(
        "vault.plasmaVaultBase",
        "the instance's vault base is the one the factory reports",
        same(instance.plasmaVaultBase, readings.factory.plasmaVaultBase),
        instance.plasmaVaultBase,
        readings.factory.plasmaVaultBase,
    );

    record(
        "access.owner",
        "the requested owner holds OWNER_ROLE",
        readings.access.ownerHasRole === true,
        readings.access.ownerHasRole,
        true,
    );
    record(
        "access.ownerDelay",
        "the owner's role has no execution delay",
        String(readings.access.ownerExecutionDelay) === "0",
        readings.access.ownerExecutionDelay,
        0,
    );
    record(
        "access.redemptionDelay",
        "the redemption delay is the requested number of seconds",
        String(readings.access.redemptionDelaySeconds) === String(expected.redemptionDelaySeconds),
        readings.access.redemptionDelaySeconds,
        expected.redemptionDelaySeconds,
    );

    if (readings.withdraw === null) unresolved.push("withdrawManager");
    if (readings.withdraw !== null)
        record(
            "withdraw.plasmaVault",
            "the withdraw manager belongs to this vault",
            same(readings.withdraw.plasmaVault, instance.plasmaVault),
            readings.withdraw.plasmaVault,
            instance.plasmaVault,
        );
    if (readings.withdraw !== null)
        record(
            "withdraw.window",
            "the withdraw window equals the factory's configured window",
            String(readings.withdraw.windowSeconds) === String(readings.factory.withdrawWindowSeconds),
            readings.withdraw.windowSeconds,
            readings.factory.withdrawWindowSeconds,
        );

    record(
        "fees.feeManagerVault",
        "the fee manager belongs to this vault",
        same(readings.fees.plasmaVault, instance.plasmaVault),
        readings.fees.plasmaVault,
        instance.plasmaVault,
    );
    record(
        "fees.daoManagement",
        "the DAO management fee is the expected package's fee",
        String(readings.fees.daoManagementFee) === String(expected.managementFeeBps),
        readings.fees.daoManagementFee,
        expected.managementFeeBps,
    );
    record(
        "fees.daoPerformance",
        "the DAO performance fee is the expected package's fee",
        String(readings.fees.daoPerformanceFee) === String(expected.performanceFeeBps),
        readings.fees.daoPerformanceFee,
        expected.performanceFeeBps,
    );
    record(
        "fees.daoRecipient",
        "the DAO fee recipient is the expected one",
        same(readings.fees.daoFeeRecipient, expected.feeRecipient),
        readings.fees.daoFeeRecipient,
        expected.feeRecipient,
    );
    // The vault pays into the fee manager's own fee accounts, not into the fee
    // manager itself, so the link is checked against what the manager reports.
    record(
        "fees.vaultManagementAccount",
        "the vault pays management fees into the fee manager's management account",
        same(readings.vault.managementFeeAccount, readings.fees.managementFeeAccount),
        readings.vault.managementFeeAccount,
        readings.fees.managementFeeAccount,
    );
    record(
        "fees.vaultPerformanceAccount",
        "the vault pays performance fees into the fee manager's performance account",
        same(readings.vault.performanceFeeAccount, readings.fees.performanceFeeAccount),
        readings.vault.performanceFeeAccount,
        readings.fees.performanceFeeAccount,
    );
    record(
        "fees.vaultManagementRate",
        "the vault's management fee equals the fee manager's total",
        String(readings.vault.managementFeeInPercentage) === String(readings.fees.totalManagementFee),
        readings.vault.managementFeeInPercentage,
        readings.fees.totalManagementFee,
    );
    record(
        "fees.vaultPerformanceRate",
        "the vault's performance fee equals the fee manager's total",
        String(readings.vault.performanceFeeInPercentage) === String(readings.fees.totalPerformanceFee),
        readings.vault.performanceFeeInPercentage,
        readings.fees.totalPerformanceFee,
    );

    for (const key of ["plasmaVault", "accessManager", "feeManager", "rewardsManager", "priceManager"]) {
        if (!readings.components[key]) unresolved.push(key);
    }
    if (!readings.components.contextManager) unresolved.push("contextManager");

    return { ok: checks.every((check) => check.ok), checks, unresolved };
}

export async function verifyVaultState(rpcUrl, instance, expected, factoryAddress) {
    let readings;
    try {
        readings = await readVaultState(rpcUrl, instance, factoryAddress);
    } catch (error) {
        throw new ChainError(
            "VAULT_STATE_UNREADABLE",
            `a created component did not answer a state read: ${error.message}`,
        );
    }
    return { ...checkVaultState(readings, expected, instance), readings };
}
