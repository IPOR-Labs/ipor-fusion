// Keccak-256 and the 4-byte function selector, in plain JavaScript.
//
// The catalog tools hash hundreds of signatures per run; spawning `cast sig`
// for each of them dominated their runtime. This is the standard Keccak-f[1600]
// permutation with the 0x01 domain padding (Ethereum's keccak256, not SHA3-256).
// It is checked against `cast sig` in tools/test-keccak.mjs.

const ROUND_CONSTANTS = [
    0x0000000000000001n,
    0x0000000000008082n,
    0x800000000000808an,
    0x8000000080008000n,
    0x000000000000808bn,
    0x0000000080000001n,
    0x8000000080008081n,
    0x8000000000008009n,
    0x000000000000008an,
    0x0000000000000088n,
    0x0000000080008009n,
    0x000000008000000an,
    0x000000008000808bn,
    0x800000000000008bn,
    0x8000000000008089n,
    0x8000000000008003n,
    0x8000000000008002n,
    0x8000000000000080n,
    0x000000000000800an,
    0x800000008000000an,
    0x8000000080008081n,
    0x8000000000008080n,
    0x0000000080000001n,
    0x8000000080008008n,
];
const ROTATIONS = [
    [0, 36, 3, 41, 18],
    [1, 44, 10, 45, 2],
    [62, 6, 43, 15, 61],
    [28, 55, 25, 21, 56],
    [27, 20, 39, 8, 14],
];
const MASK = (1n << 64n) - 1n;
const rotl = (value, bits) => (bits === 0 ? value : ((value << BigInt(bits)) | (value >> BigInt(64 - bits))) & MASK);

function keccakF(state) {
    for (let round = 0; round < 24; round += 1) {
        // theta
        const c = [0n, 0n, 0n, 0n, 0n];
        for (let x = 0; x < 5; x += 1) c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
        for (let x = 0; x < 5; x += 1) {
            const d = c[(x + 4) % 5] ^ rotl(c[(x + 1) % 5], 1);
            for (let y = 0; y < 25; y += 5) state[x + y] ^= d;
        }
        // rho and pi
        const b = new Array(25).fill(0n);
        for (let x = 0; x < 5; x += 1) {
            for (let y = 0; y < 5; y += 1) {
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rotl(state[x + 5 * y], ROTATIONS[x][y]);
            }
        }
        // chi
        for (let x = 0; x < 5; x += 1) {
            for (let y = 0; y < 25; y += 5) {
                state[x + y] = b[x + y] ^ (~b[((x + 1) % 5) + y] & b[((x + 2) % 5) + y]);
            }
        }
        // iota
        state[0] ^= ROUND_CONSTANTS[round];
    }
}

/// keccak256 of a UTF-8 string or a byte array, as a 0x-prefixed hex string.
export function keccak256(input) {
    const bytes = typeof input === "string" ? new TextEncoder().encode(input) : Uint8Array.from(input);
    const rate = 136; // bytes, for a 256-bit output
    const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate);
    padded.set(bytes);
    padded[bytes.length] ^= 0x01;
    padded[padded.length - 1] ^= 0x80;

    const state = new Array(25).fill(0n);
    for (let offset = 0; offset < padded.length; offset += rate) {
        for (let lane = 0; lane < rate / 8; lane += 1) {
            let word = 0n;
            for (let byte = 7; byte >= 0; byte -= 1) word = (word << 8n) | BigInt(padded[offset + lane * 8 + byte]);
            state[lane] ^= word;
        }
        keccakF(state);
    }
    let hex = "";
    for (let lane = 0; lane < 4; lane += 1) {
        let word = state[lane];
        for (let byte = 0; byte < 8; byte += 1) {
            hex += Number(word & 0xffn)
                .toString(16)
                .padStart(2, "0");
            word >>= 8n;
        }
    }
    return `0x${hex}`;
}

/// The 4-byte selector of a canonical function signature, like `cast sig`.
export function selector(signature) {
    return keccak256(signature).slice(0, 10);
}
