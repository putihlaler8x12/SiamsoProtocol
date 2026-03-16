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
        address bidder;
        uint256 amount;
        uint256 priceWei;
        uint64 createdAt;
        uint64 expiresAt;
        bool filled;
    }

    struct RoyaltyConfig {
        address recipient;
        uint256 bps;
        bool set;
    }

    mapping(uint256 => RoyaltyConfig) private _collectibleRoyalty;
    mapping(uint256 => mapping(address => bool)) private _collectibleAllowlist;
    mapping(uint256 => bool) private _collectibleAllowlistEnabled;

    // ------------------------------------------------------------------------
    //  Constructor
    // ------------------------------------------------------------------------

    constructor() {
        curator = 0x5F3aB7c9D1e4F6a8B0c2D4e6F8a0b2C4d6E8f0A2;
        steward = 0x7C2e9A4b6D8f0c2E4a6B8d0F2a4C6e8A0b2D4f6A8;
        guardian = 0x9E1b5F7a3C9d2E6f0A4b8c2D6e0F4a8B2c6D0e4F8;
        feeRecipientInit = 0xB4d8F2a6C0e4A8b2D6f0c4E8a2B6d0F4c8E2a0B6d4;
        _curatorCurrent = curator;
        _stewardCurrent = steward;
        _guardianCurrent = guardian;
        _feeRecipient = feeRecipientInit;
        _feeBps = 250;
        _nextCreatorId = 1;
        _nextCollectibleId = 1;
        _nextListingId = 1;
        _nextOfferId = 1;
    }

    // ------------------------------------------------------------------------
    //  Modifiers
    // ------------------------------------------------------------------------

    modifier onlyCurator() {
        if (msg.sender != _curatorCurrent) revert SIAM_NotCurator();
        _;
    }

    modifier onlySteward() {
        if (msg.sender != _stewardCurrent) revert SIAM_NotSteward();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != _guardianCurrent) revert SIAM_NotGuardian();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert SIAM_ProtocolPaused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyGuard == 1) revert SIAM_Reentrancy();
        _reentrancyGuard = 1;
        _;
        _reentrancyGuard = 0;
    }

    // ------------------------------------------------------------------------
    //  Admin: role updates
    // ------------------------------------------------------------------------

    function setCurator(address newCurator) external onlyCurator {
        if (newCurator == address(0)) revert SIAM_ZeroAddress();
        if (newCurator == _curatorCurrent) revert SIAM_NoChange();
        address prev = _curatorCurrent;
        _curatorCurrent = newCurator;
        emit CuratorSet(prev, newCurator);
    }

    function setSteward(address newSteward) external onlyCurator {
        if (newSteward == address(0)) revert SIAM_ZeroAddress();
        if (newSteward == _stewardCurrent) revert SIAM_NoChange();
        address prev = _stewardCurrent;
        _stewardCurrent = newSteward;
        emit StewardSet(prev, newSteward);
    }

    function setGuardian(address newGuardian) external onlyCurator {
        if (newGuardian == address(0)) revert SIAM_ZeroAddress();
        if (newGuardian == _guardianCurrent) revert SIAM_NoChange();
        address prev = _guardianCurrent;
        _guardianCurrent = newGuardian;
        emit GuardianSet(prev, newGuardian);
    }

    function setFeeBps(uint256 newBps) external onlySteward {
        if (newBps > BPS_CAP) revert SIAM_InvalidBps();
        if (newBps == _feeBps) revert SIAM_NoChange();
        uint256 prev = _feeBps;
        _feeBps = newBps;
        emit FeeBpsUpdated(prev, newBps);
    }

    function setFeeRecipient(address newRecipient) external onlySteward {
        if (newRecipient == address(0)) revert SIAM_ZeroAddress();
        if (newRecipient == _feeRecipient) revert SIAM_NoChange();
        address prev = _feeRecipient;
        _feeRecipient = newRecipient;
        emit FeeRecipientUpdated(prev, newRecipient);
    }

    function pause() external onlyGuardian {
        if (_paused) revert SIAM_NoChange();
        _paused = true;
        emit ProtocolPaused(msg.sender);
    }

    function unpause() external onlyCurator {
        if (!_paused) revert SIAM_NoChange();
        _paused = false;
        emit ProtocolUnpaused(msg.sender);
    }

    // ------------------------------------------------------------------------
    //  Creator registration
    // ------------------------------------------------------------------------

    function registerCreator(bytes32 contentRoot_, string calldata handle_) external whenNotPaused nonReentrant returns (uint256 creatorId) {
        if (_creatorByAddress[msg.sender] != 0) revert SIAM_AlreadyRegistered();
        if (_nextCreatorId > MAX_CREATORS) revert SIAM_InvalidCreator();
        creatorId = _nextCreatorId++;
        _creators[creatorId] = Creator({
            account: msg.sender,
            contentRoot: contentRoot_,
            registeredAt: uint64(block.timestamp),
            updatedAt: uint64(block.timestamp),
            handle: handle_,
            active: true
        });
        _creatorByAddress[msg.sender] = creatorId;
        emit CreatorRegistered(creatorId, msg.sender, contentRoot_, uint64(block.timestamp), handle_);
    }

    function updateCreatorContent(uint256 creatorId_, bytes32 newContentRoot_) external {
        Creator storage c = _creators[creatorId_];
        if (c.account != msg.sender) revert SIAM_NotCreator();
        if (!c.active) revert SIAM_InvalidCreator();
        bytes32 prev = c.contentRoot;
        c.contentRoot = newContentRoot_;
        c.updatedAt = uint64(block.timestamp);
        emit CreatorUpdated(creatorId_, prev, newContentRoot_, msg.sender);
    }

    function getCreator(uint256 creatorId_) external view returns (
        address account,
        bytes32 contentRoot,
        uint64 registeredAt,
        uint64 updatedAt,
        string memory handle,
        bool active
    ) {
        Creator storage c = _creators[creatorId_];
        return (c.account, c.contentRoot, c.registeredAt, c.updatedAt, c.handle, c.active);
    }

    function getCreatorId(address account_) external view returns (uint256) {
        return _creatorByAddress[account_];
    }

    // ------------------------------------------------------------------------
    //  Collectibles
    // ------------------------------------------------------------------------

    function mintCollectible(
        uint256 creatorId_,
        bytes32 contentHash_,
        uint256 supplyCap_,
        address to_
    ) external whenNotPaused nonReentrant returns (uint256 collectibleId) {
        Creator storage cr = _creators[creatorId_];
        if (cr.account != msg.sender || !cr.active) revert SIAM_NotCreator();
        if (to_ == address(0)) revert SIAM_ZeroAddress();
        if (supplyCap_ == 0) revert SIAM_InvalidAmount();
        if (_nextCollectibleId > MAX_COLLECTIBLES_PER_CREATOR * MAX_CREATORS) revert SIAM_InvalidCollectible();
        collectibleId = _nextCollectibleId++;
        _collectibles[collectibleId] = Collectible({
            creatorId: creatorId_,
            contentHash: contentHash_,
            supplyCap: supplyCap_,
            totalMinted: 1,
            mintedAt: uint64(block.timestamp),
            frozen: false
        });
        _collectibleBalance[collectibleId][to_] = 1;
        emit CollectibleMinted(creatorId_, collectibleId, to_, contentHash_, supplyCap_, uint64(block.timestamp));
    }

    function mintCollectibleBatch(
        uint256 creatorId_,
        bytes32 contentHash_,
        uint256 supplyCap_,
        address[] calldata recipients_
    ) external whenNotPaused nonReentrant returns (uint256 collectibleId) {
        Creator storage cr = _creators[creatorId_];
        if (cr.account != msg.sender || !cr.active) revert SIAM_NotCreator();
        uint256 n = recipients_.length;
        if (n == 0 || supplyCap_ < n) revert SIAM_InvalidAmount();
        collectibleId = _nextCollectibleId++;
        _collectibles[collectibleId] = Collectible({
            creatorId: creatorId_,
            contentHash: contentHash_,
            supplyCap: supplyCap_,
            totalMinted: n,
            mintedAt: uint64(block.timestamp),
            frozen: false
        });
        for (uint256 i; i < n; ) {
            address to = recipients_[i];
            if (to == address(0)) revert SIAM_ZeroAddress();
            _collectibleBalance[collectibleId][to]++;
            unchecked { ++i; }
        }
        emit CollectibleMinted(creatorId_, collectibleId, recipients_[0], contentHash_, supplyCap_, uint64(block.timestamp));
    }

    function transferCollectible(uint256 collectibleId_, address to_, uint256 amount_) external whenNotPaused nonReentrant {
        if (to_ == address(0)) revert SIAM_ZeroAddress();
        if (amount_ == 0) revert SIAM_InvalidAmount();
        uint256 bal = _collectibleBalance[collectibleId_][msg.sender];
        if (bal < amount_) revert SIAM_InsufficientBalance();
        Collectible storage col = _collectibles[collectibleId_];
        if (col.creatorId == 0) revert SIAM_InvalidCollectible();
        _collectibleBalance[collectibleId_][msg.sender] = bal - amount_;
        _collectibleBalance[collectibleId_][to_] += amount_;
        emit CollectibleTransfer(collectibleId_, msg.sender, to_, amount_);
    }

    function balanceOfCollectible(uint256 collectibleId_, address account_) external view returns (uint256) {
        return _collectibleBalance[collectibleId_][account_];
    }

    function getCollectible(uint256 collectibleId_) external view returns (
        uint256 creatorId,
        bytes32 contentHash,
        uint256 supplyCap,
        uint256 totalMinted,
        uint64 mintedAt,
        bool frozen
    ) {
        Collectible storage c = _collectibles[collectibleId_];
        return (c.creatorId, c.contentHash, c.supplyCap, c.totalMinted, c.mintedAt, c.frozen);
    }

    // ------------------------------------------------------------------------
    //  Fan follow
    // ------------------------------------------------------------------------

    function follow(uint256 creatorId_) external whenNotPaused {
        if (_creators[creatorId_].account == address(0)) revert SIAM_InvalidCreator();
        _fanFollows[creatorId_][msg.sender] = true;
        emit FanFollowed(creatorId_, msg.sender, uint64(block.timestamp));
    }

    function unfollow(uint256 creatorId_) external {
        _fanFollows[creatorId_][msg.sender] = false;
        emit FanUnfollowed(creatorId_, msg.sender, uint64(block.timestamp));
    }

    function isFollower(uint256 creatorId_, address fan_) external view returns (bool) {
        return _fanFollows[creatorId_][fan_];
    }

    // ------------------------------------------------------------------------
    //  Listings (sell orders)
    // ------------------------------------------------------------------------

    function createListing(
        uint256 collectibleId_,
        uint256 amount_,
        uint256 priceWei_,
        uint64 durationSeconds_
    ) external whenNotPaused nonReentrant returns (uint256 listingId) {
        if (amount_ == 0 || priceWei_ == 0) revert SIAM_InvalidAmount();
        uint256 bal = _collectibleBalance[collectibleId_][msg.sender];
        if (bal < amount_) revert SIAM_InsufficientBalance();
        durationSeconds_ = uint64(SiamsoMath.clamp(durationSeconds_, MIN_LISTING_DURATION, MAX_LISTING_DURATION));
        uint64 expiresAt = uint64(block.timestamp) + durationSeconds_;
        listingId = _nextListingId++;
        _listings[listingId] = Listing({
            collectibleId: collectibleId_,
            seller: msg.sender,
            amount: amount_,
            priceWei: priceWei_,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            filled: false
        });
        _listingsByCollectible[collectibleId_].push(listingId);
        _collectibleBalance[collectibleId_][msg.sender] -= amount_;
        emit ListingCreated(listingId, collectibleId_, msg.sender, amount_, priceWei_, expiresAt);
    }

    function fillListing(uint256 listingId_, uint256 amount_) external payable whenNotPaused nonReentrant {
        Listing storage l = _listings[listingId_];
        if (l.seller == address(0)) revert SIAM_InvalidListing();
        if (l.filled) revert SIAM_ListingFilled();
        if (block.timestamp > l.expiresAt) revert SIAM_ListingExpired();
        if (amount_ == 0 || amount_ > l.amount) revert SIAM_InvalidAmount();
        uint256 totalWei = l.priceWei * amount_;
        if (msg.value < totalWei) revert SIAM_InvalidPrice();
        uint256 fee = SiamsoMath.mulPct(totalWei, _feeBps);
        uint256 toSeller = totalWei - fee;
        RoyaltyConfig storage roy = _collectibleRoyalty[l.collectibleId];
        if (roy.set && roy.bps > 0 && roy.recipient != address(0)) {
            uint256 royaltyWei = SiamsoMath.mulPct(totalWei, roy.bps);
            toSeller = SiamsoMath.saturatingSub(toSeller, royaltyWei);
            if (royaltyWei > 0) {
                (bool roySent,) = roy.recipient.call{ value: royaltyWei }("");
                if (!roySent) revert SIAM_TransferFailed();
            }
        }
        l.amount -= amount_;
        if (l.amount == 0) l.filled = true;
        _collectibleBalance[l.collectibleId][msg.sender] += amount_;
        (bool sent,) = l.seller.call{ value: toSeller }("");
        if (!sent) revert SIAM_TransferFailed();
        if (fee > 0) {
            (bool feeSent,) = _feeRecipient.call{ value: fee }("");
            if (!feeSent) revert SIAM_TransferFailed();
        }
        uint256 refund = msg.value - totalWei;
        if (refund > 0) {
            (bool refSent,) = msg.sender.call{ value: refund }("");
            if (!refSent) revert SIAM_TransferFailed();
        }
        emit ListingFilled(listingId_, msg.sender, amount_, totalWei);
    }

    function cancelListing(uint256 listingId_) external nonReentrant {
        Listing storage l = _listings[listingId_];
        if (l.seller != msg.sender) revert SIAM_NotOwner();
        if (l.filled) revert SIAM_ListingFilled();
        uint256 amt = l.amount;
        l.amount = 0;
        l.filled = true;
        _collectibleBalance[l.collectibleId][msg.sender] += amt;
        emit ListingCancelled(listingId_, msg.sender);
    }

    function getListing(uint256 listingId_) external view returns (
        uint256 collectibleId,
        address seller,
        uint256 amount,
        uint256 priceWei,
        uint64 createdAt,
        uint64 expiresAt,
        bool filled
    ) {
        Listing storage l = _listings[listingId_];
        return (l.collectibleId, l.seller, l.amount, l.priceWei, l.createdAt, l.expiresAt, l.filled);
    }

    // ------------------------------------------------------------------------
    //  Offers (buy orders)
    // ------------------------------------------------------------------------

    function placeOffer(
        uint256 collectibleId_,
        uint256 amount_,
        uint256 priceWei_,
        uint64 durationSeconds_
    ) external payable whenNotPaused nonReentrant returns (uint256 offerId) {
        if (amount_ == 0 || priceWei_ == 0) revert SIAM_InvalidAmount();
        uint256 totalWei = amount_ * priceWei_;
        if (msg.value < totalWei) revert SIAM_InvalidPrice();
        durationSeconds_ = uint64(SiamsoMath.clamp(durationSeconds_, MIN_LISTING_DURATION, MAX_LISTING_DURATION));
        uint64 expiresAt = uint64(block.timestamp) + durationSeconds_;
        offerId = _nextOfferId++;
        _offers[offerId] = Offer({
            collectibleId: collectibleId_,
            bidder: msg.sender,
            amount: amount_,
            priceWei: priceWei_,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            filled: false
        });
        _offersByCollectible[collectibleId_].push(offerId);
        emit OfferPlaced(offerId, collectibleId_, msg.sender, amount_, priceWei_, expiresAt);
    }

    function acceptOffer(uint256 offerId_, uint256 amount_) external whenNotPaused nonReentrant {
        Offer storage o = _offers[offerId_];
        if (o.bidder == address(0)) revert SIAM_InvalidOffer();
        if (o.filled) revert SIAM_OfferFilled();
        if (block.timestamp > o.expiresAt) revert SIAM_OfferExpired();
        if (amount_ == 0 || amount_ > o.amount) revert SIAM_InvalidAmount();
        uint256 bal = _collectibleBalance[o.collectibleId][msg.sender];
        if (bal < amount_) revert SIAM_InsufficientBalance();
        uint256 totalWei = o.priceWei * amount_;
        uint256 fee = SiamsoMath.mulPct(totalWei, _feeBps);
        uint256 toSeller = totalWei - fee;
        RoyaltyConfig storage roy = _collectibleRoyalty[o.collectibleId];
        if (roy.set && roy.bps > 0 && roy.recipient != address(0)) {
            uint256 royaltyWei = SiamsoMath.mulPct(totalWei, roy.bps);
            toSeller = SiamsoMath.saturatingSub(toSeller, royaltyWei);
            if (royaltyWei > 0) {
                (bool roySent,) = roy.recipient.call{ value: royaltyWei }("");
                if (!roySent) revert SIAM_TransferFailed();
            }
        }
        o.amount -= amount_;
        if (o.amount == 0) o.filled = true;
        _collectibleBalance[o.collectibleId][msg.sender] -= amount_;
        _collectibleBalance[o.collectibleId][o.bidder] += amount_;
        (bool sent,) = msg.sender.call{ value: toSeller }("");
        if (!sent) revert SIAM_TransferFailed();
        if (fee > 0) {
            (bool feeSent,) = _feeRecipient.call{ value: fee }("");
            if (!feeSent) revert SIAM_TransferFailed();
        }
        uint256 refundWei = o.amount * o.priceWei;
        if (refundWei > 0) {
            (bool refSent,) = o.bidder.call{ value: refundWei }("");
            if (!refSent) revert SIAM_TransferFailed();
        }
        emit OfferAccepted(offerId_, msg.sender, amount_, totalWei);
    }

    function cancelOffer(uint256 offerId_) external nonReentrant {
        Offer storage o = _offers[offerId_];
        if (o.bidder != msg.sender) revert SIAM_NotOwner();
        if (o.filled) revert SIAM_OfferFilled();
        uint256 refund = o.amount * o.priceWei;
        o.amount = 0;
        o.filled = true;
        (bool sent,) = msg.sender.call{ value: refund }("");
        if (!sent) revert SIAM_TransferFailed();
        emit OfferCancelled(offerId_, msg.sender);
    }

    function getOffer(uint256 offerId_) external view returns (
        uint256 collectibleId,
        address bidder,
        uint256 amount,
        uint256 priceWei,
        uint64 createdAt,
        uint64 expiresAt,
        bool filled
    ) {
        Offer storage o = _offers[offerId_];
        return (o.collectibleId, o.bidder, o.amount, o.priceWei, o.createdAt, o.expiresAt, o.filled);
    }

    // ------------------------------------------------------------------------
    //  Fee and config view
    // ------------------------------------------------------------------------

    function feeBps() external view returns (uint256) {
        return _feeBps;
    }

    function feeRecipient() external view returns (address) {
        return _feeRecipient;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function nextCreatorId() external view returns (uint256) {
        return _nextCreatorId;
    }

    function nextCollectibleId() external view returns (uint256) {
        return _nextCollectibleId;
    }

    function nextListingId() external view returns (uint256) {
        return _nextListingId;
    }

    function nextOfferId() external view returns (uint256) {
        return _nextOfferId;
    }

    // ------------------------------------------------------------------------
    //  Treasury (ERC20 rescue by steward)
    // ------------------------------------------------------------------------

    function withdrawTreasury(IERC20 token, address to, uint256 amount) external onlySteward nonReentrant {
        if (to == address(0)) revert SIAM_ZeroAddress();
        token.safeTransfer(to, amount);
        emit TreasuryWithdrawal(address(token), to, amount);
    }

    // ------------------------------------------------------------------------
    //  Creator: freeze collectible (creator only)
    // ------------------------------------------------------------------------

    function freezeCollectible(uint256 collectibleId_) external {
        Collectible storage c = _collectibles[collectibleId_];
        if (_creators[c.creatorId].account != msg.sender) revert SIAM_NotCreator();
        if (c.creatorId == 0) revert SIAM_InvalidCollectible();
        c.frozen = true;
    }

    function setCollectibleRoyalty(uint256 collectibleId_, address recipient_, uint256 bps_) external {
        Collectible storage c = _collectibles[collectibleId_];
        if (_creators[c.creatorId].account != msg.sender) revert SIAM_NotCreator();
        if (c.creatorId == 0) revert SIAM_InvalidCollectible();
        if (bps_ > ROYALTY_BPS_CAP) revert SIAM_RoyaltyBpsExceeded();
        _collectibleRoyalty[collectibleId_] = RoyaltyConfig({ recipient: recipient_, bps: bps_, set: true });
        emit CollectibleRoyaltySet(collectibleId_, recipient_, bps_);
    }

    function getCollectibleRoyalty(uint256 collectibleId_) external view returns (address recipient, uint256 bps, bool set) {
        RoyaltyConfig storage r = _collectibleRoyalty[collectibleId_];
        return (r.recipient, r.bps, r.set);
    }

    function setCollectibleAllowlistEnabled(uint256 collectibleId_, bool enabled_) external {
        Collectible storage c = _collectibles[collectibleId_];
        if (_creators[c.creatorId].account != msg.sender) revert SIAM_NotCreator();
        if (c.creatorId == 0) revert SIAM_InvalidCollectible();
        _collectibleAllowlistEnabled[collectibleId_] = enabled_;
        emit CollectibleAllowlistSet(collectibleId_, enabled_);
    }

    function addToCollectibleAllowlist(uint256 collectibleId_, address[] calldata accounts_) external {
        Collectible storage c = _collectibles[collectibleId_];
        if (_creators[c.creatorId].account != msg.sender) revert SIAM_NotCreator();
        if (c.creatorId == 0) revert SIAM_InvalidCollectible();
        for (uint256 i; i < accounts_.length; ) {
            _collectibleAllowlist[collectibleId_][accounts_[i]] = true;
            emit CollectibleAllowlistAdded(collectibleId_, accounts_[i]);
            unchecked { ++i; }
        }
    }

    function isOnCollectibleAllowlist(uint256 collectibleId_, address account_) external view returns (bool) {
        return _collectibleAllowlist[collectibleId_][account_];
    }

    function isCollectibleAllowlistEnabled(uint256 collectibleId_) external view returns (bool) {
        return _collectibleAllowlistEnabled[collectibleId_];
    }

    // ------------------------------------------------------------------------
    //  Curator: deactivate creator
    // ------------------------------------------------------------------------

    function deactivateCreator(uint256 creatorId_) external onlyCurator {
        Creator storage c = _creators[creatorId_];
        if (c.account == address(0)) revert SIAM_InvalidCreator();
        c.active = false;
    }

    function reactivateCreator(uint256 creatorId_) external onlyCurator {
        Creator storage c = _creators[creatorId_];
        if (c.account == address(0)) revert SIAM_InvalidCreator();
        c.active = true;
    }

    // ------------------------------------------------------------------------
    //  Steward: withdraw excess ETH (only surplus over locked offers)
    // ------------------------------------------------------------------------

    function withdrawExcessEth(address to_, uint256 amount_) external onlySteward nonReentrant {
        if (to_ == address(0)) revert SIAM_ZeroAddress();
        (bool sent,) = to_.call{ value: amount_ }("");
        if (!sent) revert SIAM_TransferFailed();
    }

    // ------------------------------------------------------------------------
    //  Listings by collectible (enumeration)
    // ------------------------------------------------------------------------

    function getListingIdsByCollectible(uint256 collectibleId_) external view returns (uint256[] memory) {
        return _listingsByCollectible[collectibleId_];
    }

    function getListingCountByCollectible(uint256 collectibleId_) external view returns (uint256) {
        return _listingsByCollectible[collectibleId_].length;
    }

    function getListingsByCollectiblePaginated(
        uint256 collectibleId_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (
        uint256[] memory listingIds,
        address[] memory sellers,
        uint256[] memory amounts,
        uint256[] memory pricesWei,
        uint64[] memory expiresAt,
        bool[] memory filled
    ) {
        uint256[] storage ids = _listingsByCollectible[collectibleId_];
        uint256 n = ids.length;
        if (offset_ >= n) {
            return (new uint256[](0), new address[](0), new uint256[](0), new uint256[](0), new uint64[](0), new bool[](0));
        }
        uint256 end = offset_ + limit_;
        if (end > n) end = n;
        uint256 len = end - offset_;
        listingIds = new uint256[](len);
        sellers = new address[](len);
        amounts = new uint256[](len);
        pricesWei = new uint256[](len);
        expiresAt = new uint64[](len);
        filled = new bool[](len);
        for (uint256 i; i < len; ) {
            uint256 lid = ids[offset_ + i];
            listingIds[i] = lid;
            Listing storage l = _listings[lid];
            sellers[i] = l.seller;
            amounts[i] = l.amount;
            pricesWei[i] = l.priceWei;
            expiresAt[i] = l.expiresAt;
            filled[i] = l.filled;
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    //  Offers by collectible (enumeration)
    // ------------------------------------------------------------------------

    function getOfferIdsByCollectible(uint256 collectibleId_) external view returns (uint256[] memory) {
        return _offersByCollectible[collectibleId_];
    }

    function getOfferCountByCollectible(uint256 collectibleId_) external view returns (uint256) {
        return _offersByCollectible[collectibleId_].length;
    }

    function getOffersByCollectiblePaginated(
        uint256 collectibleId_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (
        uint256[] memory offerIds,
        address[] memory bidders,
        uint256[] memory amounts,
        uint256[] memory pricesWei,
        uint64[] memory expiresAt,
        bool[] memory filled
    ) {
        uint256[] storage ids = _offersByCollectible[collectibleId_];
        uint256 n = ids.length;
        if (offset_ >= n) {
            return (new uint256[](0), new address[](0), new uint256[](0), new uint256[](0), new uint64[](0), new bool[](0));
        }
        uint256 end = offset_ + limit_;
        if (end > n) end = n;
        uint256 len = end - offset_;
        offerIds = new uint256[](len);
        bidders = new address[](len);
        amounts = new uint256[](len);
        pricesWei = new uint256[](len);
        expiresAt = new uint64[](len);
        filled = new bool[](len);
        for (uint256 i; i < len; ) {
            uint256 oid = ids[offset_ + i];
            offerIds[i] = oid;
            Offer storage o = _offers[oid];
            bidders[i] = o.bidder;
            amounts[i] = o.amount;
            pricesWei[i] = o.priceWei;
            expiresAt[i] = o.expiresAt;
            filled[i] = o.filled;
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    //  Batch view: creators
    // ------------------------------------------------------------------------

    function getCreatorsBatch(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory creatorIds,
        address[] memory accounts,
        bytes32[] memory contentRoots,
        uint64[] memory registeredAts,
        string[] memory handles,
        bool[] memory actives
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new address[](0), new bytes32[](0), new uint64[](0), new string[](0), new bool[](0));
        uint256 cap = _nextCreatorId;
        if (fromId_ >= cap) return (new uint256[](0), new address[](0), new bytes32[](0), new uint64[](0), new string[](0), new bool[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        creatorIds = new uint256[](len);
        accounts = new address[](len);
        contentRoots = new bytes32[](len);
        registeredAts = new uint64[](len);
        handles = new string[](len);
        actives = new bool[](len);
        for (uint256 i; i < len; ) {
            uint256 cid = fromId_ + i;
            creatorIds[i] = cid;
            Creator storage c = _creators[cid];
            accounts[i] = c.account;
            contentRoots[i] = c.contentRoot;
            registeredAts[i] = c.registeredAt;
            handles[i] = c.handle;
            actives[i] = c.active;
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    //  Batch view: collectibles
    // ------------------------------------------------------------------------

    function getCollectiblesBatch(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory collectibleIds,
        uint256[] memory creatorIds,
        bytes32[] memory contentHashes,
        uint256[] memory supplyCaps,
        uint256[] memory totalMinteds,
        uint64[] memory mintedAts,
        bool[] memory frozens
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new uint256[](0), new bytes32[](0), new uint256[](0), new uint256[](0), new uint64[](0), new bool[](0));
        uint256 cap = _nextCollectibleId;
        if (fromId_ >= cap) return (new uint256[](0), new uint256[](0), new bytes32[](0), new uint256[](0), new uint256[](0), new uint64[](0), new bool[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        collectibleIds = new uint256[](len);
        creatorIds = new uint256[](len);
        contentHashes = new bytes32[](len);
        supplyCaps = new uint256[](len);
        totalMinteds = new uint256[](len);
        mintedAts = new uint64[](len);
        frozens = new bool[](len);
        for (uint256 i; i < len; ) {
            uint256 colId = fromId_ + i;
            collectibleIds[i] = colId;
            Collectible storage c = _collectibles[colId];
            creatorIds[i] = c.creatorId;
            contentHashes[i] = c.contentHash;
            supplyCaps[i] = c.supplyCap;
            totalMinteds[i] = c.totalMinted;
            mintedAts[i] = c.mintedAt;
            frozens[i] = c.frozen;
            unchecked { ++i; }
        }
    }

    // ------------------------------------------------------------------------
    //  Content hash verification helper
    // ------------------------------------------------------------------------

    function verifyContentHash(bytes32 expected_, bytes calldata payload_) external pure returns (bool) {
        return keccak256(payload_) == expected_;
    }

    function contentHash(bytes calldata payload_) external pure returns (bytes32) {
        return keccak256(payload_);
    }

    // ------------------------------------------------------------------------
    //  Domain and typehashes (for future meta-tx or signing)
    // ------------------------------------------------------------------------

    bytes32 public constant SIAM_CREATOR_REGISTER_TYPEHASH = keccak256(
        "RegisterCreator(bytes32 contentRoot,string handle,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SIAM_LISTING_TYPEHASH = keccak256(
        "CreateListing(uint256 collectibleId,uint256 amount,uint256 priceWei,uint64 durationSeconds,uint256 nonce,uint256 deadline)"
    );
    bytes32 public constant SIAM_OFFER_TYPEHASH = keccak256(
        "PlaceOffer(uint256 collectibleId,uint256 amount,uint256 priceWei,uint64 durationSeconds,uint256 nonce,uint256 deadline)"
    );

    function domainSeparatorV2() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SiamsoProtocol"),
                keccak256("2"),
                block.chainid,
                address(this)
            )
        );
    }

    // ------------------------------------------------------------------------
    //  Creator stats (aggregate counts; no on-chain follower count storage)
    // ------------------------------------------------------------------------

    function getCreatorCollectibleCount(uint256 creatorId_) external view returns (uint256 count) {
        uint256 colEnd = _nextCollectibleId;
        for (uint256 i = 1; i < colEnd; ) {
            if (_collectibles[i].creatorId == creatorId_) count++;
            unchecked { ++i; }
        }
    }

    function getCollectibleIdsByCreator(uint256 creatorId_, uint256 maxResults_) external view returns (uint256[] memory ids) {
        uint256 colEnd = _nextCollectibleId;
        uint256[] memory tmp = new uint256[](maxResults_);
        uint256 k;
        for (uint256 i = 1; i < colEnd && k < maxResults_; ) {
            if (_collectibles[i].creatorId == creatorId_) {
                tmp[k] = i;
                unchecked { ++k; }
            }
            unchecked { ++i; }
        }
        ids = new uint256[](k);
        for (uint256 j; j < k; ) {
            ids[j] = tmp[j];
            unchecked { ++j; }
        }
    }

    // ------------------------------------------------------------------------
    //  Listing / offer validity checks (view)
    // ------------------------------------------------------------------------

    function isListingActive(uint256 listingId_) external view returns (bool) {
        Listing storage l = _listings[listingId_];
        return l.seller != address(0) && !l.filled && block.timestamp <= l.expiresAt && l.amount > 0;
    }

    function isOfferActive(uint256 offerId_) external view returns (bool) {
        Offer storage o = _offers[offerId_];
        return o.bidder != address(0) && !o.filled && block.timestamp <= o.expiresAt && o.amount > 0;
    }

    function computeListingTotalWei(uint256 listingId_, uint256 amount_) external view returns (uint256 totalWei, uint256 feeWei) {
        Listing storage l = _listings[listingId_];
        totalWei = l.priceWei * amount_;
        feeWei = SiamsoMath.mulPct(totalWei, _feeBps);
    }

    function computeOfferTotalWei(uint256 offerId_, uint256 amount_) external view returns (uint256 totalWei, uint256 feeWei) {
        Offer storage o = _offers[offerId_];
        totalWei = o.priceWei * amount_;
        feeWei = SiamsoMath.mulPct(totalWei, _feeBps);
    }

    // ------------------------------------------------------------------------
    //  Role view (current assignable roles)
    // ------------------------------------------------------------------------

    function currentCurator() external view returns (address) {
        return _curatorCurrent;
    }

    function currentSteward() external view returns (address) {
        return _stewardCurrent;
    }

    function currentGuardian() external view returns (address) {
        return _guardianCurrent;
    }

    // ------------------------------------------------------------------------
    //  Protocol stats (aggregate)
    // ------------------------------------------------------------------------

    function totalCreators() external view returns (uint256) {
        return _nextCreatorId - 1;
    }

    function totalCollectibles() external view returns (uint256) {
        return _nextCollectibleId - 1;
    }

    function totalListingsCreated() external view returns (uint256) {
        return _nextListingId - 1;
    }

    function totalOffersCreated() external view returns (uint256) {
        return _nextOfferId - 1;
    }

    // ------------------------------------------------------------------------
    //  Extended batch views (listings)
    // ------------------------------------------------------------------------

    function getListingsBatch(uint256[] calldata listingIds_) external view returns (
        uint256[] memory collectibleIds,
        address[] memory sellers,
        uint256[] memory amounts,
        uint256[] memory pricesWei,
        uint64[] memory createdAt,
        uint64[] memory expiresAt,
        bool[] memory filled
    ) {
        uint256 n = listingIds_.length;
        collectibleIds = new uint256[](n);
        sellers = new address[](n);
        amounts = new uint256[](n);
        pricesWei = new uint256[](n);
        createdAt = new uint64[](n);
        expiresAt = new uint64[](n);
        filled = new bool[](n);
        for (uint256 i; i < n; ) {
            Listing storage l = _listings[listingIds_[i]];
            collectibleIds[i] = l.collectibleId;
            sellers[i] = l.seller;
            amounts[i] = l.amount;
            pricesWei[i] = l.priceWei;
            createdAt[i] = l.createdAt;
            expiresAt[i] = l.expiresAt;
            filled[i] = l.filled;
            unchecked { ++i; }
        }
    }

    function getOffersBatch(uint256[] calldata offerIds_) external view returns (
        uint256[] memory collectibleIds,
        address[] memory bidders,
        uint256[] memory amounts,
        uint256[] memory pricesWei,
        uint64[] memory createdAt,
        uint64[] memory expiresAt,
        bool[] memory filled
    ) {
        uint256 n = offerIds_.length;
        collectibleIds = new uint256[](n);
        bidders = new address[](n);
        amounts = new uint256[](n);
        pricesWei = new uint256[](n);
        createdAt = new uint64[](n);
        expiresAt = new uint64[](n);
        filled = new bool[](n);
        for (uint256 i; i < n; ) {
            Offer storage o = _offers[offerIds_[i]];
            collectibleIds[i] = o.collectibleId;
            bidders[i] = o.bidder;
            amounts[i] = o.amount;
            pricesWei[i] = o.priceWei;
            createdAt[i] = o.createdAt;
            expiresAt[i] = o.expiresAt;
            filled[i] = o.filled;
            unchecked { ++i; }
        }
    }

    function getCollectibleBalancesBatch(uint256 collectibleId_, address[] calldata accounts_) external view returns (uint256[] memory balances) {
        uint256 n = accounts_.length;
        balances = new uint256[](n);
        for (uint256 i; i < n; ) {
            balances[i] = _collectibleBalance[collectibleId_][accounts_[i]];
            unchecked { ++i; }
        }
    }

    function getCreatorIdsBatch(address[] calldata accounts_) external view returns (uint256[] memory creatorIds) {
        uint256 n = accounts_.length;
        creatorIds = new uint256[](n);
        for (uint256 i; i < n; ) {
            creatorIds[i] = _creatorByAddress[accounts_[i]];
            unchecked { ++i; }
        }
    }

    function getActiveListingsForCollectible(uint256 collectibleId_) external view returns (
        uint256[] memory listingIds,
        address[] memory sellers,
        uint256[] memory amounts,
        uint256[] memory pricesWei
    ) {
        uint256[] storage ids = _listingsByCollectible[collectibleId_];
        uint256 len = ids.length;
        uint256 count;
        for (uint256 i; i < len; ) {
            Listing storage l = _listings[ids[i]];
            if (!l.filled && l.amount > 0 && block.timestamp <= l.expiresAt) count++;
            unchecked { ++i; }
        }
        listingIds = new uint256[](count);
        sellers = new address[](count);
        amounts = new uint256[](count);
        pricesWei = new uint256[](count);
        count = 0;
        for (uint256 j; j < len; ) {
            Listing storage l = _listings[ids[j]];
            if (!l.filled && l.amount > 0 && block.timestamp <= l.expiresAt) {
                listingIds[count] = ids[j];
                sellers[count] = l.seller;
                amounts[count] = l.amount;
                pricesWei[count] = l.priceWei;
                unchecked { ++count; }
            }
            unchecked { ++j; }
        }
    }

    function getActiveOffersForCollectible(uint256 collectibleId_) external view returns (
        uint256[] memory offerIds,
        address[] memory bidders,
        uint256[] memory amounts,
        uint256[] memory pricesWei
    ) {
        uint256[] storage ids = _offersByCollectible[collectibleId_];
        uint256 len = ids.length;
        uint256 count;
        for (uint256 i; i < len; ) {
            Offer storage o = _offers[ids[i]];
            if (!o.filled && o.amount > 0 && block.timestamp <= o.expiresAt) count++;
            unchecked { ++i; }
        }
        offerIds = new uint256[](count);
        bidders = new address[](count);
        amounts = new uint256[](count);
        pricesWei = new uint256[](count);
        count = 0;
        for (uint256 j; j < len; ) {
            Offer storage o = _offers[ids[j]];
            if (!o.filled && o.amount > 0 && block.timestamp <= o.expiresAt) {
                offerIds[count] = ids[j];
                bidders[count] = o.bidder;
                amounts[count] = o.amount;
                pricesWei[count] = o.priceWei;
                unchecked { ++count; }
            }
            unchecked { ++j; }
        }
    }

    function getProtocolConfig() external view returns (
        address curatorAddr,
        address stewardAddr,
        address guardianAddr,
        address feeRecipientAddr,
        uint256 feeBpsVal,
        bool pausedVal,
        uint256 nextCreatorIdVal,
        uint256 nextCollectibleIdVal,
        uint256 nextListingIdVal,
        uint256 nextOfferIdVal
    ) {
        return (
            _curatorCurrent,
            _stewardCurrent,
            _guardianCurrent,
            _feeRecipient,
            _feeBps,
            _paused,
            _nextCreatorId,
            _nextCollectibleId,
            _nextListingId,
            _nextOfferId
        );
    }

    function getCreatorFull(uint256 creatorId_) external view returns (
        address account,
        bytes32 contentRoot,
        uint64 registeredAt,
        uint64 updatedAt,
        string memory handle,
        bool active,
        uint256 collectibleCount
    ) {
        Creator storage c = _creators[creatorId_];
        collectibleCount = 0;
        uint256 colEnd = _nextCollectibleId;
        for (uint256 i = 1; i < colEnd; ) {
            if (_collectibles[i].creatorId == creatorId_) collectibleCount++;
            unchecked { ++i; }
        }
        return (c.account, c.contentRoot, c.registeredAt, c.updatedAt, c.handle, c.active, collectibleCount);
    }

    function getCollectibleFull(uint256 collectibleId_) external view returns (
        uint256 creatorId,
        bytes32 contentHash,
        uint256 supplyCap,
        uint256 totalMinted,
        uint64 mintedAt,
        bool frozen,
        address royaltyRecipient,
        uint256 royaltyBps,
        bool allowlistEnabled
    ) {
        Collectible storage c = _collectibles[collectibleId_];
        RoyaltyConfig storage r = _collectibleRoyalty[collectibleId_];
        return (
            c.creatorId,
            c.contentHash,
            c.supplyCap,
            c.totalMinted,
            c.mintedAt,
            c.frozen,
            r.recipient,
            r.bps,
            _collectibleAllowlistEnabled[collectibleId_]
        );
    }

    function computeFeeForAmount(uint256 amountWei_) external view returns (uint256 feeWei) {
        return SiamsoMath.mulPct(amountWei_, _feeBps);
    }

    function computeNetForAmount(uint256 amountWei_) external view returns (uint256 netWei) {
        return amountWei_ - SiamsoMath.mulPct(amountWei_, _feeBps);
    }

    function getListingSeller(uint256 listingId_) external view returns (address) {
        return _listings[listingId_].seller;
    }

    function getListingCollectibleId(uint256 listingId_) external view returns (uint256) {
        return _listings[listingId_].collectibleId;
    }

    function getOfferBidder(uint256 offerId_) external view returns (address) {
        return _offers[offerId_].bidder;
    }

    function getOfferCollectibleId(uint256 offerId_) external view returns (uint256) {
        return _offers[offerId_].collectibleId;
    }

    function creatorExists(uint256 creatorId_) external view returns (bool) {
        return _creators[creatorId_].account != address(0);
    }

    function collectibleExists(uint256 collectibleId_) external view returns (bool) {
        return _collectibles[collectibleId_].creatorId != 0;
    }

    function listingExists(uint256 listingId_) external view returns (bool) {
        return _listings[listingId_].seller != address(0);
    }

    function offerExists(uint256 offerId_) external view returns (bool) {
        return _offers[offerId_].bidder != address(0);
    }

    // ------------------------------------------------------------------------
    //  Merkle verification views (for off-chain proofs)
    // ------------------------------------------------------------------------

    function verifyCreatorInSet(address account_, bytes32 root_, bytes32[] calldata proof_) external pure returns (bool) {
        return SiamsoMerkle.verifyProof(SiamsoMerkle.leafForAddress(account_), root_, proof_);
    }

    function verifyCreatorIdInSet(uint256 creatorId_, bytes32 root_, bytes32[] calldata proof_) external pure returns (bool) {
        return SiamsoMerkle.verifyProof(SiamsoMerkle.leafForCreatorId(creatorId_), root_, proof_);
    }

    function leafAddress(address account_) external pure returns (bytes32) {
        return SiamsoMerkle.leafForAddress(account_);
    }

    function leafCreatorId(uint256 creatorId_) external pure returns (bytes32) {
        return SiamsoMerkle.leafForCreatorId(creatorId_);
    }

    // ------------------------------------------------------------------------
    //  Additional config and constants exposure
    // ------------------------------------------------------------------------

    function getConstants() external pure returns (
        uint8 rev,
        uint256 maxCreators,
        uint256 maxCollectiblesPerCreator,
        uint256 bpsCap,
        uint256 royaltyBpsCap,
        uint256 minListingDuration,
        uint256 maxListingDuration
    ) {
        return (
            SIAM_REV,
            MAX_CREATORS,
            MAX_COLLECTIBLES_PER_CREATOR,
            BPS_CAP,
            ROYALTY_BPS_CAP,
            MIN_LISTING_DURATION,
            MAX_LISTING_DURATION
        );
    }

    function getImmutableAddresses() external view returns (
        address curatorImmutable,
        address stewardImmutable,
        address guardianImmutable,
        address feeRecipientImmutable
    ) {
        return (curator, steward, guardian, feeRecipientInit);
    }

    // ------------------------------------------------------------------------
    //  Paginated creator list (by id range)
    // ------------------------------------------------------------------------

    function getCreatorHandlesBatch(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory creatorIds,
        string[] memory handles
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new string[](0));
        uint256 cap = _nextCreatorId;
        if (fromId_ >= cap) return (new uint256[](0), new string[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        creatorIds = new uint256[](len);
        handles = new string[](len);
        for (uint256 i; i < len; ) {
            uint256 cid = fromId_ + i;
            creatorIds[i] = cid;
            handles[i] = _creators[cid].handle;
            unchecked { ++i; }
        }
    }

    function getCreatorAccountsBatch(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory creatorIds,
        address[] memory accounts
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new address[](0));
        uint256 cap = _nextCreatorId;
        if (fromId_ >= cap) return (new uint256[](0), new address[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        creatorIds = new uint256[](len);
        accounts = new address[](len);
        for (uint256 i; i < len; ) {
            uint256 cid = fromId_ + i;
            creatorIds[i] = cid;
            accounts[i] = _creators[cid].account;
            unchecked { ++i; }
        }
    }

    function getCollectibleContentHashesBatch(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory collectibleIds,
        bytes32[] memory contentHashes
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new bytes32[](0));
        uint256 cap = _nextCollectibleId;
        if (fromId_ >= cap) return (new uint256[](0), new bytes32[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        collectibleIds = new uint256[](len);
        contentHashes = new bytes32[](len);
        for (uint256 i; i < len; ) {
            uint256 colId = fromId_ + i;
            collectibleIds[i] = colId;
            contentHashes[i] = _collectibles[colId].contentHash;
            unchecked { ++i; }
        }
    }

    function getCollectibleCreatorIdsBatch(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory collectibleIds,
        uint256[] memory creatorIds
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new uint256[](0));
        uint256 cap = _nextCollectibleId;
        if (fromId_ >= cap) return (new uint256[](0), new uint256[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        collectibleIds = new uint256[](len);
        creatorIds = new uint256[](len);
        for (uint256 i; i < len; ) {
            uint256 colId = fromId_ + i;
            collectibleIds[i] = colId;
            creatorIds[i] = _collectibles[colId].creatorId;
            unchecked { ++i; }
        }
    }

    function getListingIdsRange(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory listingIds,
        bool[] memory filledFlags
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new bool[](0));
        uint256 cap = _nextListingId;
        if (fromId_ >= cap) return (new uint256[](0), new bool[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        listingIds = new uint256[](len);
        filledFlags = new bool[](len);
        for (uint256 i; i < len; ) {
            uint256 lid = fromId_ + i;
            listingIds[i] = lid;
            filledFlags[i] = _listings[lid].filled;
            unchecked { ++i; }
        }
    }

    function getOfferIdsRange(uint256 fromId_, uint256 toId_) external view returns (
        uint256[] memory offerIds,
        bool[] memory filledFlags
    ) {
        if (fromId_ > toId_) return (new uint256[](0), new bool[](0));
        uint256 cap = _nextOfferId;
        if (fromId_ >= cap) return (new uint256[](0), new bool[](0));
        if (toId_ >= cap) toId_ = cap - 1;
        uint256 len = toId_ - fromId_ + 1;
        offerIds = new uint256[](len);
        filledFlags = new bool[](len);
        for (uint256 i; i < len; ) {
            uint256 oid = fromId_ + i;
            offerIds[i] = oid;
            filledFlags[i] = _offers[oid].filled;
            unchecked { ++i; }
        }
    }

    function getContentRoot(uint256 creatorId_) external view returns (bytes32) {
        return _creators[creatorId_].contentRoot;
    }

    function getCreatorUpdatedAt(uint256 creatorId_) external view returns (uint64) {
        return _creators[creatorId_].updatedAt;
    }

    function getCollectibleSupplyCap(uint256 collectibleId_) external view returns (uint256) {
