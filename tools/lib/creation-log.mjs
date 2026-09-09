// Selection of the creation event out of a receipt.
//
// A receipt from a real creation carries hundreds of logs from many contracts,
// and the same event signature can be emitted by anything. Only a log emitted by
// the factory the manifest names counts; a matching log from any other address
// is reported as foreign, never used.

export function selectCreationLog(logs, factoryAddress, topic) {
    const matchingTopic = (logs ?? []).filter((log) => log.topics?.[0] === topic);
    const mine = matchingTopic.filter((log) => log.address?.toLowerCase() === factoryAddress.toLowerCase());
    const foreign = matchingTopic.filter((log) => log.address?.toLowerCase() !== factoryAddress.toLowerCase());

    if (mine.length > 1) return { status: "ambiguous", foreign, count: mine.length };
    if (mine.length === 1) return { status: "found", log: mine[0], foreign };
    if (foreign.length > 0) return { status: "foreign-only", foreign };
    return { status: "absent", foreign: [] };
}
