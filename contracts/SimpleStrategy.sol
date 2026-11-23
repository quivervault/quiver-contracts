// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20S {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IVaultRegistry {
    function isVault(address account) external view returns (bool);
}

/// @title SimpleStrategy
/// @notice Starter strategy: holds deployed capital idle (0% yield) so the
///         full vault loop — deploy, recall, withdraw — works end-to-end on
///         day one. Real yield strategies (staking, lending, hedged perps)
///         replace this by implementing IQuiverStrategy and being approved
///         in the factory; vaults never need to change.
/// @dev    Only a vault created by the Quiver factory may recall funds, and
///         only to itself.
contract SimpleStrategy {
    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    /// Called by a QuiverVault to recall capital. `to` must be the caller vault.
    function withdraw(address token, uint256 amount, address to) external {
        require(IVaultRegistry(factory).isVault(msg.sender), "caller not a vault");
        require(to == msg.sender, "recall only to the vault itself");
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH send failed");
        } else {
            require(IERC20S(token).transfer(to, amount), "token send failed");
        }
    }

    function balanceOf(address token) external view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20S(token).balanceOf(address(this));
    }

    receive() external payable {}
}
