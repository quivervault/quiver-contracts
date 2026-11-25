// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./QuiverVault.sol";

/// @title QuiverVaultFactory
/// @notice Creates one isolated QuiverVault per depositor per risk profile on
///         Robinhood Chain. Holds the shared registries the vaults consult:
///         supported assets, approved strategies, the strategy executor and
///         the per-profile deployment caps.
/// @dev    Admin is the deployer. Admin can configure registries and pause
///         deposits, but has NO path to user funds: withdrawals in every
///         vault are owner-only by construction. Strategy approvals and cap
///         changes sit behind a timelock, and only contracts can be approved
///         as strategies, so the admin can never point vault capital at its
///         own wallet (HeyResearch review GHSA-mgpc-wcqx-fc7x, finding 2).
///         Revoking a strategy is instant: removing a target must never wait.
contract QuiverVaultFactory {
    address public admin;
    address public executor;

    /// Delay between proposing a strategy approval / cap change and being
    /// able to execute it. Long enough for depositors to react.
    uint256 public constant TIMELOCK_DELAY = 2 days;

    /// Pending strategy approvals: strategy => earliest execution time.
    mapping(address => uint256) public strategyApprovalEta;
    /// Pending cap changes: profile => proposed cap. A proposal exists iff
    /// profileCapEta[profile] != 0 (so a proposed cap of 0 is representable).
    mapping(uint8 => uint16) public pendingProfileCapBps;
    mapping(uint8 => uint256) public profileCapEta;

    /// Supported deposit assets. address(0) = native ETH.
    mapping(address => bool) public supportedAsset;
    address[] public assetList;

    /// Strategies the executor may deploy vault capital into.
    mapping(address => bool) public approvedStrategy;

    /// Deployment cap per risk profile (basis points of principal).
    /// 0 Conservative, 1 Balanced, 2 Growth, 3 Active, 4 Aggressive, 5 Degen —
    /// matching the six profiles on the Quiver site (8.2% floor to 20% APR).
    uint16[6] public profileCapBps = [uint16(2000), 3500, 5000, 6500, 8000, 9500];

    mapping(address => bool) public isVault;
    mapping(address => address[]) public vaultsOf;
    address[] public allVaults;

    event VaultCreated(address indexed owner, address indexed vault, uint8 riskProfile);
    event AssetSet(address indexed token, bool supported);
    event StrategySet(address indexed strategy, bool approved);
    event StrategyProposed(address indexed strategy, uint256 eta);
    event ExecutorSet(address executor);
    event ProfileCapSet(uint8 profile, uint16 capBps);
    event ProfileCapProposed(uint8 profile, uint16 capBps, uint256 eta);
    event AdminSet(address admin);

    modifier onlyAdmin() { require(msg.sender == admin, "not admin"); _; }

    /// @param _executor  Protocol strategy executor address.
    /// @param _usdt      USDT contract on Robinhood Chain (or address(0) to add later).
    /// @param _usdg      USDG contract on Robinhood Chain (or address(0) to add later).
    /// @param _usdc      USDC contract on Robinhood Chain (or address(0) to add later).
    constructor(address _executor, address _usdt, address _usdg, address _usdc) {
        require(_executor != address(0), "zero executor");
        admin = msg.sender;
        executor = _executor;
        _setAsset(address(0), true); // ETH always supported
        if (_usdt != address(0)) _setAsset(_usdt, true);
        if (_usdg != address(0)) _setAsset(_usdg, true);
        if (_usdc != address(0)) _setAsset(_usdc, true);
    }

    function _setAsset(address token, bool supported) internal {
        if (supported && !supportedAsset[token]) assetList.push(token);
        supportedAsset[token] = supported;
        emit AssetSet(token, supported);
    }

    function setAsset(address token, bool supported) external onlyAdmin {
        _setAsset(token, supported);
    }

    /// Propose approving a strategy. Only contracts can ever be approved —
    /// never a wallet — and execution waits out the timelock.
    function proposeStrategy(address strategy) external onlyAdmin {
        require(strategy.code.length > 0, "strategy not a contract");
        require(!approvedStrategy[strategy], "already approved");
        require(strategyApprovalEta[strategy] == 0, "already proposed");
        strategyApprovalEta[strategy] = block.timestamp + TIMELOCK_DELAY;
        emit StrategyProposed(strategy, strategyApprovalEta[strategy]);
    }

    /// Execute a strategy approval once the timelock has elapsed.
    function executeStrategyApproval(address strategy) external onlyAdmin {
        uint256 eta = strategyApprovalEta[strategy];
        require(eta != 0, "not proposed");
        require(block.timestamp >= eta, "timelock not elapsed");
        require(strategy.code.length > 0, "strategy not a contract");
        delete strategyApprovalEta[strategy];
        approvedStrategy[strategy] = true;
        emit StrategySet(strategy, true);
    }

    /// Cancel a pending strategy approval before it executes.
    function cancelStrategyProposal(address strategy) external onlyAdmin {
        require(strategyApprovalEta[strategy] != 0, "not proposed");
        delete strategyApprovalEta[strategy];
        emit StrategySet(strategy, false);
    }

    /// Revoke an approved strategy. Instant by design: removing a deployment
    /// target must never wait out a timelock.
    function revokeStrategy(address strategy) external onlyAdmin {
        approvedStrategy[strategy] = false;
        delete strategyApprovalEta[strategy];
        emit StrategySet(strategy, false);
    }

    function setExecutor(address _executor) external onlyAdmin {
        require(_executor != address(0), "zero executor");
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    /// Propose a profile cap change (affects vaults created afterwards;
    /// existing vaults keep their immutable cap). Executes after timelock.
    function proposeProfileCap(uint8 profile, uint16 capBps) external onlyAdmin {
        require(profile < 6, "bad profile");
        require(capBps <= 10000, "cap > 100%");
        pendingProfileCapBps[profile] = capBps;
        profileCapEta[profile] = block.timestamp + TIMELOCK_DELAY;
        emit ProfileCapProposed(profile, capBps, profileCapEta[profile]);
    }

    function executeProfileCap(uint8 profile) external onlyAdmin {
        require(profile < 6, "bad profile");
        uint256 eta = profileCapEta[profile];
        require(eta != 0, "not proposed");
        require(block.timestamp >= eta, "timelock not elapsed");
        uint16 capBps = pendingProfileCapBps[profile];
        delete pendingProfileCapBps[profile];
        delete profileCapEta[profile];
        profileCapBps[profile] = capBps;
        emit ProfileCapSet(profile, capBps);
    }

    function setAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "zero address");
        admin = _admin;
        emit AdminSet(_admin);
    }

    /// @notice Create your own isolated vault. One call, no approval needed,
    ///         no fee taken by this contract.
    function createVault(uint8 riskProfile) external returns (address vault) {
        require(riskProfile < 6, "bad profile");
        address[] memory assets = new address[](assetList.length);
        uint256 n;
        for (uint256 i = 0; i < assetList.length; i++) {
            if (supportedAsset[assetList[i]]) assets[n++] = assetList[i];
        }
        assembly { mstore(assets, n) }

        QuiverVault v = new QuiverVault(
            msg.sender,
            executor,
            riskProfile,
            profileCapBps[riskProfile],
            assets
        );
        vault = address(v);
        isVault[vault] = true;
        vaultsOf[msg.sender].push(vault);
        allVaults.push(vault);
        emit VaultCreated(msg.sender, vault, riskProfile);
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function vaultsOfCount(address user) external view returns (uint256) {
        return vaultsOf[user].length;
    }

    /// Propagate an executor rotation to an existing vault.
    function syncVaultExecutor(address vault) external onlyAdmin {
        require(isVault[vault], "not a vault");
        QuiverVault(payable(vault)).setExecutor(executor);
    }

    /// Emergency: pause/unpause deposits on one vault (withdrawals never pause).
    function setVaultDepositsPaused(address vault, bool paused) external onlyAdmin {
        require(isVault[vault], "not a vault");
        QuiverVault(payable(vault)).setDepositsPaused(paused);
    }
}
