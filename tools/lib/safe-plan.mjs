// Pure parts of the Safe export: the batch document and the fee comparison.
//
// Kept out of the CLI so that the comparison — which is the point of the whole
// export — can be tested without a network.

/// Safe Transaction Builder batch document for one call. It is a file to import
/// into the Safe UI, not a proposal: nothing here talks to a Safe service.
export function safeBatch({ chainId, safe, to, value, data, name, description, createdAt }) {
    return {
        version: "1.0",
        chainId: String(chainId),
        createdAt,
        meta: {
            name,
            description,
            txBuilderVersion: "1.16.5",
            createdFromSafeAddress: safe,
            createdFromOwnerAddress: "",
        },
        transactions: [{ to, value: String(value), data, contractMethod: null, contractInputsValues: null }],
    };
}

const normalize = (address) => String(address).toLowerCase();

/// Compares what the factory resolves for the Safe against what it resolves for
/// another caller (typically the owner EOA). The factory selects by msg.sender,
/// so these can differ for identical arguments.
export function compareFeeResolution(safeResolution, otherResolution) {
    const differences = [];
    if (safeResolution.source !== otherResolution.source) {
        differences.push({
            field: "source",
            safe: safeResolution.source,
            other: otherResolution.source,
        });
    }
    for (const field of ["managementFeeBps", "performanceFeeBps"]) {
        if (Number(safeResolution[field]) !== Number(otherResolution[field])) {
            differences.push({ field, safe: safeResolution[field], other: otherResolution[field] });
        }
    }
    if (normalize(safeResolution.feeRecipient) !== normalize(otherResolution.feeRecipient)) {
        differences.push({ field: "feeRecipient", safe: safeResolution.feeRecipient, other: otherResolution.feeRecipient });
    }
    return { differs: differences.length > 0, differences };
}
