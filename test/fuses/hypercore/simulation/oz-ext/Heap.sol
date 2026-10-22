// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Heap: minimal local stand-in for OpenZeppelin Contracts v5.1's utils/structs/Heap.sol
// (Uint256Heap, min-heap variant), which does not exist in this repo's pinned OpenZeppelin
// Contracts v5.0.2. Implements only the subset of the API used by the vendored HyperCore
// simulator (insert, pop, peek, length) as a plain array-backed binary min-heap. Not part of
// the upstream hyper-evm-lib vendoring -- added locally because the repo cannot bump its
// OpenZeppelin dependency for this test-only simulator.
// See test/fuses/hypercore/simulation/VENDORED.md for details.
library Heap {
    struct Uint256Heap {
        uint256[] data;
    }

    function insert(Uint256Heap storage self, uint256 value) internal {
        self.data.push(value);
        uint256 i = self.data.length - 1;
        while (i > 0) {
            uint256 parent = (i - 1) / 2;
            if (self.data[parent] <= self.data[i]) break;
            (self.data[parent], self.data[i]) = (self.data[i], self.data[parent]);
            i = parent;
        }
    }

    function peek(Uint256Heap storage self) internal view returns (uint256) {
        return self.data[0];
    }

    function pop(Uint256Heap storage self) internal returns (uint256 top) {
        top = self.data[0];
        uint256 last = self.data.length - 1;
        self.data[0] = self.data[last];
        self.data.pop();

        uint256 i = 0;
        uint256 len = self.data.length;
        while (true) {
            uint256 left = 2 * i + 1;
            uint256 right = 2 * i + 2;
            uint256 smallest = i;
            if (left < len && self.data[left] < self.data[smallest]) smallest = left;
            if (right < len && self.data[right] < self.data[smallest]) smallest = right;
            if (smallest == i) break;
            (self.data[i], self.data[smallest]) = (self.data[smallest], self.data[i]);
            i = smallest;
        }
    }

    function length(Uint256Heap storage self) internal view returns (uint256) {
        return self.data.length;
    }
}
