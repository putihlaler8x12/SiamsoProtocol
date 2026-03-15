// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SiamsoProtocol
/// @notice On-chain registry for content creators, collectible drops, and fan-driven exchange.
/// @dev Collectibles bound to creators; listing and offer books with fee capture. Deploy with no args; roles are set at deploy.

// ============================================================================
//  Interfaces
// ============================================================================

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// ============================================================================
//  Libraries
// ============================================================================

library SiamsoMath {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }
    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
    function mulPct(uint256 value, uint256 pctBps) internal pure returns (uint256) {
        return (value * pctBps) / 10_000;
    }
    function addBps(uint256 value, uint256 bps) internal pure returns (uint256) {
        return value + (value * bps) / 10_000;
    }
    function subBps(uint256 value, uint256 bps) internal pure returns (uint256) {
        uint256 deduction = (value * bps) / 10_000;
        return value > deduction ? value - deduction : 0;
    }
    function safeMulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        if (d == 0) return 0;
        return (a * b) / d;
    }
}

library SiamsoBytes {
    function toBytes32(bytes memory b, uint256 start) internal pure returns (bytes32 out) {
        if (b.length < start + 32) return bytes32(0);
        assembly {
            out := mload(add(add(b, 32), start))
        }
    }
    function slice(bytes memory b, uint256 start, uint256 len) internal pure returns (bytes memory) {
        if (start + len > b.length) len = b.length > start ? b.length - start : 0;
        bytes memory res = new bytes(len);
        for (uint256 i; i < len; ) {
            res[i] = b[start + i];
            unchecked { ++i; }
        }
        return res;
    }
}

library SiamsoMerkle {
    function verifyProof(
        bytes32 leaf,
        bytes32 root,
        bytes32[] calldata proof
    ) internal pure returns (bool) {
        bytes32 h = leaf;
        for (uint256 i; i < proof.length; ) {
            bytes32 p = proof[i];
            h = h < p ? keccak256(abi.encodePacked(h, p)) : keccak256(abi.encodePacked(p, h));
            unchecked { ++i; }
        }
        return h == root;
    }
    function leafForAddress(address account) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account));
    }
    function leafForCreatorId(uint256 creatorId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(creatorId));
    }
}

library SiamsoSafeTransfer {
    error SiamsoSafeTransfer_Failed();
    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SiamsoSafeTransfer_Failed();
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert SiamsoSafeTransfer_Failed();
    }
}

// ============================================================================
//  Main Contract
// ============================================================================

contract SiamsoProtocol {
    using SiamsoMath for uint256;
    using SiamsoSafeTransfer for IERC20;

    // ------------------------------------------------------------------------
    //  Events
    // ------------------------------------------------------------------------

    event CreatorRegistered(
        uint256 indexed creatorId,
        address indexed account,
        bytes32 contentRoot,
