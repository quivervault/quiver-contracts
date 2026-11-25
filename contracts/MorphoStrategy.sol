// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20M {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Minimal ERC-4626 interface for the Morpho vault.
interface IMorphoVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function balanceOf(address account) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

interface IVaultRegistryM {
    function isVault(address account) external view returns (bool);
}

/// @title MorphoStrategy
/// @notice Lending strategy for Quiver vaults: the base engine. USDG that
///         vaults deploy here is supplied into the Steakhouse USDG vault on
///         Morpho (Robinhood Chain), an ERC-4626 Morpho Vault V2 curated by
///         Steakhouse Financial, and earns the lending rate borrowers pay.
///
///         How it fits the vault architecture:
///         - Vaults deploy capital here exactly like SimpleStrategy
///           (deployToStrategy sends USDG; recall calls withdraw()).
///         - Deployed USDG first sits idle in this contract. The executor
///           calls supply() to sweep the idle balance into Morpho; interest
///           then accrues inside the Morpho share price.
///         - Recall pays idle USDG first and redeems only the shortfall
///           from Morpho, so ordinary withdrawals rarely touch the position.
///         - This contract never credits yield itself. The executor reads
///           accruedYield(), collects that amount with collectYield() into
///           its own wallet, and settles it into each vault's yield reserve
///           via vault.fundYield, pro-rata from the vaults' deployedIn
///           figures — the same settlement pattern as PerpStrategy, so the
///           vault rule "yield only against real funded tokens" holds.
///         - The Morpho position is pooled across vaults by necessity (one
///           strategy contract); per-vault accounting stays in the vaults.
///
/// @dev    Accounting: suppliedPrincipal is the USDG cost basis inside
///         Morpho. It rises by the swept amount in supply(), falls by the
///         redeemed amount when a recall dips into the position, and is
///         untouched by collectYield() — so accruedYield() is always
///         position value minus cost basis, never principal.
///         Recall caveat: if the Morpho vault itself cannot source the
///         liquidity (assets fully lent out), the redemption reverts and
///         the recall reverts with it; the executor retries once liquidity
///         returns. The idle buffer is an operational parameter.
contract MorphoStrategy {
    address public immutable factory;
    address public immutable usdg;        // USDG on Robinhood Chain
    address public immutable morphoVault; // Steakhouse USDG vault (ERC-4626)
    address public admin;                 // protocol admin (roles, pause)
    address public executor;              // strategy executor (supply, yield)
    bool public supplyPaused;             // blocks supply() only
    uint256 public suppliedPrincipal;     // USDG cost basis inside Morpho

    event Supplied(uint256 amount, uint256 shares);
    event YieldCollected(uint256 amount, address indexed to);
    event AdminSet(address admin);
    event ExecutorSet(address executor);
    event SupplyPausedSet(bool paused);

    modifier onlyAdmin() { require(msg.sender == admin, "not admin"); _; }
    modifier onlyExecutor() { require(msg.sender == executor, "not executor"); _; }

    constructor(
        address _factory,
        address _admin,
        address _executor,
        address _morphoVault,
        address _usdg
    ) {
        factory = _factory;
        admin = _admin;
        executor = _executor;
        morphoVault = _morphoVault;
        usdg = _usdg;
    }

    // ---------- Admin ----------
    function setExecutor(address _executor) external onlyAdmin {
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    function setAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "zero admin");
        admin = _admin;
        emit AdminSet(_admin);
    }

    function setSupplyPaused(bool paused) external onlyAdmin {
        supplyPaused = paused;
        emit SupplyPausedSet(paused);
    }

    // ---------- Supply (executor only) ----------
    /// Sweep this contract's whole idle USDG balance into the Morpho vault.
    function supply() external onlyExecutor returns (uint256 sharesOut) {
        require(!supplyPaused, "supply paused");
        uint256 amount = IERC20M(usdg).balanceOf(address(this));
        require(amount > 0, "nothing to supply");
        require(IERC20M(usdg).approve(morphoVault, amount), "approve failed");
        sharesOut = IMorphoVault(morphoVault).deposit(amount, address(this));
        suppliedPrincipal += amount;
        emit Supplied(amount, sharesOut);
    }

    // ---------- Vault recall (same guard pattern as SimpleStrategy) ----------
    /// Called by a QuiverVault to recall capital. `to` must be the caller vault.
    /// USDG pays from the idle balance first and redeems only the shortfall
    /// from Morpho. Other assets (incl. ETH) pay from idle balance only.
    function withdraw(address token, uint256 amount, address to) external {
        require(IVaultRegistryM(factory).isVault(msg.sender), "caller not a vault");
        require(to == msg.sender, "recall only to the vault itself");
        if (token == usdg) {
            uint256 idle = IERC20M(usdg).balanceOf(address(this));
            if (idle < amount) {
                uint256 need = amount - idle;
                IMorphoVault(morphoVault).withdraw(need, address(this), address(this));
                suppliedPrincipal = need < suppliedPrincipal ? suppliedPrincipal - need : 0;
            }
            require(IERC20M(usdg).transfer(to, amount), "token send failed");
        } else if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH send failed");
        } else {
            require(IERC20M(token).transfer(to, amount), "token send failed");
        }
    }

    // ---------- Yield collection (executor only, capped at real profit) ----------
    /// Redeem `amount` of accrued lending profit from Morpho to `to` (the
    /// executor wallet, which settles it into vault yield reserves).
    /// Reverts unless the amount is covered by profit above cost basis.
    function collectYield(address to, uint256 amount) external onlyExecutor {
        require(amount > 0, "zero amount");
        require(amount <= accruedYield(), "exceeds accrued yield");
        IMorphoVault(morphoVault).withdraw(amount, address(this), address(this));
        require(IERC20M(usdg).transfer(to, amount), "token send failed");
        emit YieldCollected(amount, to);
    }

    // ---------- Views ----------
    /// Shares of the Morpho vault held by this strategy.
    function shares() public view returns (uint256) {
        return IMorphoVault(morphoVault).balanceOf(address(this));
    }

    /// Current USDG value of the Morpho position.
    function positionValue() public view returns (uint256) {
        return IMorphoVault(morphoVault).convertToAssets(shares());
    }

    /// Profit accrued inside Morpho above the supplied cost basis.
    function accruedYield() public view returns (uint256) {
        uint256 value = positionValue();
        return value > suppliedPrincipal ? value - suppliedPrincipal : 0;
    }

    function idleBalance(address token) external view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20M(token).balanceOf(address(this));
    }

    /// Total value this strategy holds for `token`: for USDG, idle plus the
    /// Morpho position; for anything else, the idle balance.
    function balanceOf(address token) external view returns (uint256) {
        if (token == usdg) {
            return IERC20M(usdg).balanceOf(address(this)) + positionValue();
        }
        return token == address(0) ? address(this).balance : IERC20M(token).balanceOf(address(this));
    }

    receive() external payable {}
}
