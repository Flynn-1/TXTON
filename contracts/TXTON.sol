// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title TXTON Token (Improved / configurable)
 * @notice Gas-optimized with clearer errors and configurable constructor parameters.
 * - MAX_AIRDROP_BATCH is now configurable (immutable).
 * - burnInterval & burnDivisor are configurable at deployment.
 * - admin mint percentage is configurable at deployment (0-100).
 * - clearer custom errors (no semantic reuse).
 */
contract TXTON is ERC20, ERC20Permit, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ────────────── Constants ──────────────
    /// @notice Token has 6 decimals; MAX_SUPPLY expressed with decimals accounted
    uint256 public constant MAX_SUPPLY = 200_000_000 * 10 ** 6; // decimals = 6

    // Configurable batch limit (immutable set at deployment)
    uint256 public immutable MAX_AIRDROP_BATCH;

    // Role identifiers
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AIRDROP_ROLE = keccak256("AIRDROP_ROLE");
    bytes32 public constant BURN_ROLE = keccak256("BURN_ROLE");
    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ────────────── Storage ──────────────
    uint64 public lastBurnTimestamp;
    uint64 public burnInterval; // configurable
    uint256 public burnDivisor; // configurable

    address public admin; // designated admin address (kept for ETH forwarding convenience)

    uint256 public initialSupply;
    uint256 private _burnBalance; // deposited tokens reserved for burn

    // ────────────── Events ──────────────
    event Burned(uint256 amount, uint256 timestamp);
    event Minted(address indexed to, uint256 amount);
    event BurnConfigUpdated(uint64 newInterval);
    event BurnDivisorUpdated(uint256 newDivisor);
    event ERC20Recovered(address indexed token, uint256 amount, address indexed to);
    event DepositForBurn(address indexed user, uint256 amount);
    event Airdropped(address indexed to, uint256 amount);
    event ETHWithdrawn(address indexed to, uint256 amount);
    event AdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event ETHForwardFailed(address indexed admin, uint256 amount);

    // ────────────── Custom Errors ──────────────
    error ZeroAddress();
    error ZeroAmount();
    error ExceedsMaxSupply();
    error ArrayLengthMismatch();
    error BatchTooLarge();
    error NotDue();
    error BurnAmountTooSmall();
    error NoDepositedTokens();
    error NothingRecoverable();
    error InsufficientETH();
    error InvalidDivisor();
    error InvalidInterval();
    error OutOfRange();
    error DecreasedBelowZero();
    error CannotRecoverSelf();
    error ExceedsAvailableRecoverable();
    error AlreadyAdmin();

    // ────────────── Constructor ──────────────
    /**
     * @param name_ token name
     * @param symbol_ token symbol
     * @param airdropBatchLimit max recipients per airdrop (must be > 0)
     * @param initialBurnInterval initial burn interval (seconds) (min 1 day)
     * @param initialBurnDivisor initial burn divisor (non-zero, within allowed range)
     * @param adminMintPercent percent of MAX_SUPPLY to mint initially to admin (0-100)
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 airdropBatchLimit,
        uint64 initialBurnInterval,
        uint256 initialBurnDivisor,
        uint8 adminMintPercent
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (airdropBatchLimit == 0) revert ZeroAmount();
        if (initialBurnInterval < 1 days) revert InvalidInterval();
        if (initialBurnDivisor == 0) revert InvalidDivisor();
        if (adminMintPercent > 100) revert OutOfRange();

        MAX_AIRDROP_BATCH = airdropBatchLimit;
        burnInterval = initialBurnInterval;
        burnDivisor = initialBurnDivisor;

        admin = msg.sender;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(MINT_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        // Initial mint: adminMintPercent% of MAX_SUPPLY to admin
        uint256 adminMint = (MAX_SUPPLY * adminMintPercent) / 100;
        if (adminMint > 0) {
            _mint(admin, adminMint);
            emit Minted(admin, adminMint);
        }
        initialSupply = adminMint;
        lastBurnTimestamp = uint64(block.timestamp);
    }

    // ────────────── Views ──────────────
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function depositedBalance() external view returns (uint256) {
        return _burnBalance;
    }

    function contractBalance() external view returns (uint256) {
        return balanceOf(address(this));
    }

    function nextBurnTime() external view returns (uint256) {
        return uint256(lastBurnTimestamp) + uint256(burnInterval);
    }

    function mintableSupply() public view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    // ────────────── Pausable Controls ──────────────
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

// Block transfers when paused
function _update(address from, address to, uint256 value)
    internal
    override(ERC20)
{
    // 1) Reject any transfers/mints/burns when paused
    if (paused()) {
        revert("Pausable: paused");
        // or use: require(!paused(), "Pausable: paused");
    }

    // 2) Proceed with the normal ERC20 logic
    super._update(from, to, value);
}


    // ────────────── Admin Config ──────────────
    function updateBurnConfig(uint64 newInterval) external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (newInterval < 1 days) revert InvalidInterval();
        burnInterval = newInterval;
        emit BurnConfigUpdated(newInterval);
    }

    function updateBurnDivisor(uint256 newDivisor) external onlyRole(ADMIN_ROLE) whenNotPaused {
        if (newDivisor == 0) revert InvalidDivisor();
        if (newDivisor < 10_000 || newDivisor > 1_000_000_000) revert OutOfRange();
        burnDivisor = newDivisor;
        emit BurnDivisorUpdated(newDivisor);
    }

    // ────────────── Minting ──────────────
    function mint(address to, uint256 amount)
        external
        onlyRole(MINT_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 _total = totalSupply();
        if (_total + amount > MAX_SUPPLY) revert ExceedsMaxSupply();

        _mint(to, amount);
        emit Minted(to, amount);
    }

    // ────────────── Deposit & Burn ──────────────
    function depositForBurn(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _transfer(msg.sender, address(this), amount);
        _burnBalance += amount;
        emit DepositForBurn(msg.sender, amount);
    }

    function adminBurn(uint256 amount) external onlyRole(ADMIN_ROLE) nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount); // burns from admin's own balance
        emit Burned(amount, block.timestamp);
    }

    function triggerBurnFromDeposits() external onlyRole(BURN_ROLE) nonReentrant whenNotPaused {
        if (block.timestamp < lastBurnTimestamp + burnInterval) revert NotDue();

        uint256 _total = totalSupply();
        uint256 burnAmt = _total / burnDivisor;
        if (burnAmt == 0) revert BurnAmountTooSmall();

        uint256 burnFromDeposits = burnAmt <= _burnBalance ? burnAmt : _burnBalance;
        if (burnFromDeposits == 0) revert NoDepositedTokens();

        _burnBalance -= burnFromDeposits;
        _burn(address(this), burnFromDeposits);

        lastBurnTimestamp = uint64(block.timestamp);
        emit Burned(burnFromDeposits, block.timestamp);
    }

    function burnAllDeposited() external onlyRole(BURN_ROLE) nonReentrant whenNotPaused {
        uint256 bal = _burnBalance;
        if (bal == 0) revert NoDepositedTokens();

        _burnBalance = 0;
        _burn(address(this), bal);
        emit Burned(bal, block.timestamp);
    }

    // ────────────── Airdrop ──────────────
    function airdrop(address[] calldata recipients, uint256[] calldata amounts)
        external
        onlyRole(AIRDROP_ROLE)
        nonReentrant
        whenNotPaused
    {
        uint256 len = recipients.length;
        if (len != amounts.length) revert ArrayLengthMismatch();
        if (len > MAX_AIRDROP_BATCH) revert BatchTooLarge();

        uint256 _total = totalSupply();

        for (uint256 i = 0; i < len; ) {
            address to = recipients[i];
            uint256 amt = amounts[i];

            if (to == address(0)) revert ZeroAddress();
            if (amt == 0) revert ZeroAmount();

            // ensure supply cap not exceeded
            if (_total + amt > MAX_SUPPLY) revert ExceedsMaxSupply();
            _total += amt;

            _mint(to, amt);
            emit Airdropped(to, amt);

            unchecked { ++i; }
        }
    }

    // ────────────── ERC20 Recovery ──────────────
    function recoverERC20(address token, address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (token == address(this)) revert CannotRecoverSelf();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransfer(to, amount);
        emit ERC20Recovered(token, amount, to);
    }

    /// @notice Recovers TXTON tokens not part of deposits
    function recoverOwnToken(uint256 amount, address to)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 currentBalance = balanceOf(address(this));
        if (currentBalance <= _burnBalance) revert NothingRecoverable();

        uint256 available = currentBalance - _burnBalance;
        if (amount > available) revert ExceedsAvailableRecoverable();

        _transfer(address(this), to, amount);
        emit ERC20Recovered(address(this), amount, to);
    }

    // ────────────── ETH Handling ──────────────
    receive() external payable nonReentrant whenNotPaused {
        _sendETHToAdmin(msg.value);
    }

    fallback() external payable nonReentrant whenNotPaused {
        _sendETHToAdmin(msg.value);
    }

    function _sendETHToAdmin(uint256 amount) internal {
        if (amount == 0) return;
        if (admin == address(0)) {
            emit ETHForwardFailed(admin, amount);
            return;
        }
        (bool success, ) = payable(admin).call{value: amount}("");
        if (!success) emit ETHForwardFailed(admin, amount);
    }

    function withdrawETH(address to, uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (to == address(0)) revert ZeroAddress();
        if (address(this).balance < amount) revert InsufficientETH();
        (bool success, ) = payable(to).call{value: amount}("");
        if (!success) revert InsufficientETH();
        emit ETHWithdrawn(to, amount);
    }

    // ────────────── Allowance Helpers ──────────────
    function increaseAllowance(address spender, uint256 addedValue) external whenNotPaused returns (bool) {
        _approve(msg.sender, spender, allowance(msg.sender, spender) + addedValue);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external whenNotPaused returns (bool) {
        uint256 currentAllowance = allowance(msg.sender, spender);
        if (currentAllowance < subtractedValue) revert DecreasedBelowZero();
        _approve(msg.sender, spender, currentAllowance - subtractedValue);
        return true;
    }

    // ────────────── Admin Transfer ──────────────
    /**
     * @notice Transfers the admin address and key roles to a newAdmin.
     * Grants DEFAULT_ADMIN_ROLE, ADMIN_ROLE, MINT_ROLE, PAUSER_ROLE to newAdmin,
     * then revokes those roles from previous admin. Keeps other roles untouched.
     */
    function transferAdmin(address newAdmin)
        external
        onlyRole(ADMIN_ROLE)
        nonReentrant
        whenNotPaused
    {
        if (newAdmin == address(0)) revert ZeroAddress();
        if (newAdmin == admin) revert AlreadyAdmin();

        address prevAdmin = admin;

        // grant roles to newAdmin first
        _grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        _grantRole(ADMIN_ROLE, newAdmin);
        _grantRole(MINT_ROLE, newAdmin);
        _grantRole(PAUSER_ROLE, newAdmin);

        // revoke roles from previous admin
        _revokeRole(ADMIN_ROLE, prevAdmin);
        _revokeRole(DEFAULT_ADMIN_ROLE, prevAdmin);
        _revokeRole(MINT_ROLE, prevAdmin);
        _revokeRole(PAUSER_ROLE, prevAdmin);

        admin = newAdmin;
        emit AdminTransferred(prevAdmin, newAdmin);
    }

    // NOTE: intentionally removed `renounceAdminRole()` to avoid accidental lockout of DEFAULT_ADMIN_ROLE.
    // If you want a renounce facility, implement it carefully (e.g., require another admin exists beforehand).
}
