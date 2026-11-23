// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20P {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IVaultRegistryP {
    function isVault(address account) external view returns (bool);
}

/// @title PerpStrategy
/// @notice Funding-harvest strategy for Quiver vaults, built around Lighter
///         on Robinhood Chain (see PERP_STRATEGY_DESIGN.md).
///
///         How it fits the vault architecture:
///         - Vaults deploy capital here exactly like SimpleStrategy
///           (deployToStrategy sends ETH / USDG; recall calls withdraw()).
///         - ETH sent here is the long spot leg. It never leaves this
///           contract except back to the calling vault.
///         - USDG is the margin leg. The executor may move USDG margin to
///           ONE whitelisted recipient (the executor wallet that owns the
///           Lighter account) via sendMargin(), bounded by an admin-set cap
///           that defaults to 0 (disabled / fail-closed).
///         - The off-chain bot trades a 1x short ETH perp against the spot
///           held here, collects funding in USDG, and settles realised
///           profit by funding each vault's yield reserve directly
///           (vault.fundYield) — this contract never credits yield itself,
///           so the vault rule "yield only against real funded tokens"
///           is preserved end-to-end.
///         - Margin is pooled on the exchange by necessity (one account);
///           per-vault accounting stays in the vaults (deployedIn) and the
///           bot distributes pro-rata from those on-chain figures.
///
/// @dev    Recall caveat: capital currently out as exchange margin is not
///         instantly liquid. withdraw() pays from the idle balance and
///         reverts if it is insufficient; the executor must first return
///         margin (the bot watches UnwindRequested). The idle buffer is an
///         operational parameter, not a guarantee.
contract PerpStrategy {
    address public immutable factory;
    address public immutable usdg;          // margin token (USDG on Robinhood Chain)
    address public admin;                   // protocol admin (cap, recipient, pause)
    address public executor;                // strategy executor (margin moves)
    address public marginRecipient;         // the ONLY address margin may be sent to
    uint256 public marginCap;               // max USDG allowed out as margin (0 = disabled)
    uint256 public marginOut;               // USDG currently out as margin (ledger)
    bool public marginPaused;               // blocks sendMargin only

    event MarginSent(uint256 amount, uint256 marginOut);
    event MarginReturned(uint256 amount, uint256 marginOut);
    event UnwindRequested(address indexed by, uint256 amount);
    event MarginCapSet(uint256 cap);
    event MarginRecipientSet(address recipient);
    event ExecutorSet(address executor);
    event AdminSet(address admin);
    event MarginPausedSet(bool paused);

    modifier onlyAdmin() { require(msg.sender == admin, "not admin"); _; }
    modifier onlyExecutor() { require(msg.sender == executor, "not executor"); _; }

    constructor(
        address _factory,
        address _admin,
        address _executor,
        address _marginRecipient,
        address _usdg
    ) {
        factory = _factory;
        admin = _admin;
        executor = _executor;
        marginRecipient = _marginRecipient;
        usdg = _usdg;
    }

    // ---------- Admin ----------
    function setMarginCap(uint256 cap) external onlyAdmin {
        marginCap = cap;
        emit MarginCapSet(cap);
    }

    function setMarginRecipient(address recipient) external onlyAdmin {
        require(recipient != address(0), "zero recipient");
        marginRecipient = recipient;
        emit MarginRecipientSet(recipient);
    }

    function setExecutor(address _executor) external onlyAdmin {
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    function setAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "zero admin");
        admin = _admin;
        emit AdminSet(_admin);
    }

    function setMarginPaused(bool paused) external onlyAdmin {
        marginPaused = paused;
        emit MarginPausedSet(paused);
    }

    // ---------- Vault recall (same guard pattern as SimpleStrategy) ----------
    /// Called by a QuiverVault to recall capital. `to` must be the caller vault.
    /// Pays from idle balance; reverts if the amount is out as margin.
    function withdraw(address token, uint256 amount, address to) external {
        require(IVaultRegistryP(factory).isVault(msg.sender), "caller not a vault");
        require(to == msg.sender, "recall only to the vault itself");
        if (token == address(0)) {
            require(address(this).balance >= amount, "insufficient idle ETH");
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH send failed");
        } else {
            require(IERC20P(token).balanceOf(address(this)) >= amount, "insufficient idle balance (margin out?)");
            require(IERC20P(token).transfer(to, amount), "token send failed");
        }
    }

    // ---------- Margin leg (executor only, whitelisted, capped) ----------
    /// Move USDG margin to the whitelisted executor account wallet.
    /// The bot deposits it into Lighter from there (the Lighter account is
    /// owned by that wallet; Lighter withdrawals can only return to it).
    function sendMargin(uint256 amount) external onlyExecutor {
        require(!marginPaused, "margin paused");
        require(amount > 0, "zero amount");
        require(marginRecipient != address(0), "no margin recipient");
        require(marginOut + amount <= marginCap, "margin cap exceeded");
        require(IERC20P(usdg).balanceOf(address(this)) >= amount, "insufficient USDG");
        marginOut += amount;
        require(IERC20P(usdg).transfer(marginRecipient, amount), "margin send failed");
        emit MarginSent(amount, marginOut);
    }

    /// Record margin that the executor has sent back to this contract
    /// (the USDG transfer itself is a plain transfer to this address;
    /// this updates the ledger the bot and anyone else reconciles against).
    function recordMarginReturn(uint256 amount) external onlyExecutor {
        require(amount > 0, "zero amount");
        require(amount <= marginOut, "exceeds margin out");
        marginOut -= amount;
        emit MarginReturned(amount, marginOut);
    }

    /// Signal the bot that margin should be unwound back to this contract.
    /// Callable by any factory vault (for its own recall needs) or executor/admin.
    function requestUnwind(uint256 amount) external {
        require(
            msg.sender == executor || msg.sender == admin || IVaultRegistryP(factory).isVault(msg.sender),
            "not authorised"
        );
        emit UnwindRequested(msg.sender, amount);
    }

    // ---------- Views ----------
    function idleBalance(address token) external view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20P(token).balanceOf(address(this));
    }

    /// ETH held as the long spot leg.
    function spotETH() external view returns (uint256) {
        return address(this).balance;
    }

    receive() external payable {}
}
