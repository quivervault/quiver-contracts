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
///         vault are owner-only by construction.
contract QuiverVaultFactory {
    address public admin;
    address public executor;

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
    event ExecutorSet(address executor);
    event ProfileCapSet(uint8 profile, uint16 capBps);
    event AdminSet(address admin);

    modifier onlyAdmin() { require(msg.sender == admin, "not admin"); _; }

    /// @param _executor  Protocol strategy executor address.
    /// @param _usdt      USDT contract on Robinhood Chain (or address(0) to add later).
    /// @param _usdg      USDG contract on Robinhood Chain (or address(0) to add later).
    /// @param _usdc      USDC contract on Robinhood Chain (or address(0) to add later).
    constructor(address _executor, address _usdt, address _usdg, address _usdc) {
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

    function setStrategy(address strategy, bool approved) external onlyAdmin {
        approvedStrategy[strategy] = approved;
        emit StrategySet(strategy, approved);
    }

    function setExecutor(address _executor) external onlyAdmin {
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    function setProfileCap(uint8 profile, uint16 capBps) external onlyAdmin {
        require(profile < 6, "bad profile");
        require(capBps <= 10000, "cap > 100%");
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
