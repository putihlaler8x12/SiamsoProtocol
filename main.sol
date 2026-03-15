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
        uint64 registeredAt,
        string handle
    );
    event CreatorUpdated(
        uint256 indexed creatorId,
        bytes32 previousRoot,
        bytes32 newContentRoot,
        address indexed updater
    );
    event CollectibleMinted(
        uint256 indexed creatorId,
        uint256 indexed collectibleId,
        address indexed owner,
        bytes32 contentHash,
        uint256 supplyCap,
        uint64 mintedAt
    );
    event CollectibleTransfer(
        uint256 indexed collectibleId,
        address indexed from,
        address indexed to,
        uint256 amount
    );
    event FanFollowed(uint256 indexed creatorId, address indexed fan, uint64 followedAt);
    event FanUnfollowed(uint256 indexed creatorId, address indexed fan, uint64 unfollowedAt);
    event ListingCreated(
        uint256 indexed listingId,
        uint256 indexed collectibleId,
        address indexed seller,
        uint256 amount,
        uint256 priceWei,
        uint64 expiresAt
    );
    event ListingFilled(
        uint256 indexed listingId,
        address indexed buyer,
        uint256 filledAmount,
        uint256 totalWei
    );
    event ListingCancelled(uint256 indexed listingId, address indexed seller);
    event OfferPlaced(
        uint256 indexed offerId,
        uint256 indexed collectibleId,
        address indexed bidder,
        uint256 amount,
        uint256 priceWei,
        uint64 expiresAt
    );
    event OfferAccepted(
        uint256 indexed offerId,
        address indexed seller,
        uint256 acceptedAmount,
        uint256 totalWei
    );
    event OfferCancelled(uint256 indexed offerId, address indexed bidder);
    event ProtocolPaused(address indexed guardian);
    event ProtocolUnpaused(address indexed curator);
    event CuratorSet(address indexed previous, address indexed next);
    event StewardSet(address indexed previous, address indexed next);
    event GuardianSet(address indexed previous, address indexed next);
    event FeeBpsUpdated(uint256 previousBps, uint256 newBps);
    event FeeRecipientUpdated(address indexed previous, address indexed next);
    event TreasuryWithdrawal(address indexed token, address indexed to, uint256 amount);
    event CollectibleRoyaltySet(uint256 indexed collectibleId, address indexed recipient, uint256 bps);
    event CollectibleAllowlistSet(uint256 indexed collectibleId, bool enabled);
    event CollectibleAllowlistAdded(uint256 indexed collectibleId, address indexed account);

    // ------------------------------------------------------------------------
    //  Errors
    // ------------------------------------------------------------------------

    error SIAM_NotCurator();
    error SIAM_NotSteward();
    error SIAM_NotGuardian();
    error SIAM_ProtocolPaused();
    error SIAM_ZeroAddress();
    error SIAM_NoChange();
    error SIAM_Reentrancy();
    error SIAM_InvalidCreator();
    error SIAM_InvalidCollectible();
    error SIAM_InvalidListing();
    error SIAM_InvalidOffer();
    error SIAM_InvalidAmount();
    error SIAM_InvalidPrice();
    error SIAM_InvalidBps();
    error SIAM_AlreadyRegistered();
    error SIAM_NotCreator();
    error SIAM_NotOwner();
    error SIAM_SupplyExceeded();
    error SIAM_ListingExpired();
    error SIAM_OfferExpired();
    error SIAM_InsufficientBalance();
    error SIAM_ListingFilled();
    error SIAM_OfferFilled();
    error SIAM_TransferFailed();
    error SIAM_NotOnAllowlist();
    error SIAM_RoyaltyBpsExceeded();

    // ------------------------------------------------------------------------
    //  Constants
    // ------------------------------------------------------------------------

    uint8 public constant SIAM_REV = 2;
    uint256 public constant MAX_CREATORS = 50_000;
    uint256 public constant MAX_COLLECTIBLES_PER_CREATOR = 2_000;
    uint256 public constant MAX_LISTINGS_PER_COLLECTIBLE = 500;
    uint256 public constant MAX_OFFERS_PER_COLLECTIBLE = 500;
    uint256 public constant BPS_CAP = 2_500; // 25% max fee
    uint256 public constant ROYALTY_BPS_CAP = 1_000; // 10% max royalty
    uint256 public constant MIN_LISTING_DURATION = 1 hours;
    uint256 public constant MAX_LISTING_DURATION = 365 days;
    bytes32 public constant SIAM_DOMAIN = keccak256("SiamsoProtocol.FanCollective.v2");
    bytes32 public constant SIAM_CONTENT_ROOT_PREFIX = keccak256("SiamsoProtocol.ContentRoot");
    bytes32 public constant SIAM_COLLECTIBLE_PREFIX = keccak256("SiamsoProtocol.Collectible");
    uint256 public constant DEFAULT_LISTING_DURATION = 7 days;
    uint256 public constant DEFAULT_OFFER_DURATION = 3 days;
    uint256 public constant MIN_SUPPLY_CAP = 1;
    uint256 public constant MAX_SUPPLY_CAP = 1_000_000;

    // ------------------------------------------------------------------------
    //  Immutable state (set in constructor)
    // ------------------------------------------------------------------------

    address public immutable curator;
    address public immutable steward;
    address public immutable guardian;
    address public immutable feeRecipientInit;

    // ------------------------------------------------------------------------
    //  Mutable admin (assignable by roles)
    // ------------------------------------------------------------------------

    address private _curatorCurrent;
    address private _stewardCurrent;
    address private _guardianCurrent;
    address private _feeRecipient;
    uint256 private _feeBps;
    bool private _paused;
    uint256 private _reentrancyGuard;

    // ------------------------------------------------------------------------
    //  Registry state
    // ------------------------------------------------------------------------

    uint256 private _nextCreatorId;
    mapping(uint256 => Creator) private _creators;
    mapping(address => uint256) private _creatorByAddress;

    uint256 private _nextCollectibleId;
    mapping(uint256 => Collectible) private _collectibles;
    mapping(uint256 => mapping(address => uint256)) private _collectibleBalance;

    mapping(uint256 => mapping(address => bool)) private _fanFollows;

    uint256 private _nextListingId;
    mapping(uint256 => Listing) private _listings;
    mapping(uint256 => uint256[]) private _listingsByCollectible;

    uint256 private _nextOfferId;
    mapping(uint256 => Offer) private _offers;
    mapping(uint256 => uint256[]) private _offersByCollectible;

    mapping(address => mapping(address => uint256)) private _treasuryBalances;

    // ------------------------------------------------------------------------
    //  Structs
    // ------------------------------------------------------------------------

    struct Creator {
        address account;
        bytes32 contentRoot;
        uint64 registeredAt;
        uint64 updatedAt;
        string handle;
        bool active;
    }

    struct Collectible {
        uint256 creatorId;
        bytes32 contentHash;
        uint256 supplyCap;
        uint256 totalMinted;
        uint64 mintedAt;
        bool frozen;
    }

    struct Listing {
        uint256 collectibleId;
        address seller;
        uint256 amount;
        uint256 priceWei;
        uint64 createdAt;
        uint64 expiresAt;
        bool filled;
    }

    struct Offer {
        uint256 collectibleId;
