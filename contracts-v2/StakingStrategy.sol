// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20S {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETHS {
    function withdraw(uint256 amount) external;
}

/// @notice Minimal Uniswap V3 factory interface (pool lookup).
interface IV3FactoryS {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}

/// @notice Minimal Uniswap V3 pool interface (spot price only).
interface IV3PoolS {
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16 observationCardinality, uint16 observationCardinalityNext,
        uint8 feeProtocol, bool unlocked
    );
    function token0() external view returns (address);
}

/// @notice Minimal Uniswap SwapRouter02 interface (single-hop exact in/out).
interface ISwapRouterS {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

interface IVaultRegistryS {
    function isVault(address account) external view returns (bool);
}

/// @title StakingStrategy
/// @notice ETH staking strategy for Quiver vaults: the ballast leg. ETH that
///         vaults deploy here is swapped into wstETH (Lido's wrapped staked
///         ETH, bridged to Robinhood Chain via Chainlink CCIP) on Uniswap V3
///         and held; the position earns Ethereum's staking yield through the
///         wstETH exchange rate, which appreciates against ETH over time.
///
///         How it fits the vault architecture:
///         - Vaults deploy capital here exactly like SimpleStrategy
///           (deployToStrategy sends ETH; recall calls withdraw()).
///         - Deployed ETH first sits idle in this contract. The executor
///           calls stake() to sweep the idle balance into wstETH; staking
///           rewards then accrue inside the wstETH/ETH rate.
///         - Recall pays idle ETH first and swaps back only the shortfall,
///           so ordinary withdrawals rarely touch the position.
///         - This contract never credits yield itself. The executor reads
///           accruedYield(), collects that amount with collectYield() into
///           its own wallet, and settles it into each vault's yield reserve
///           via vault.fundYield, pro-rata from the vaults' deployedIn
///           figures — the same settlement pattern as PerpStrategy and
///           MorphoStrategy, so the vault rule "yield only against real
///           funded tokens" holds.
///         - The wstETH position is pooled across vaults by necessity (one
///           strategy contract); per-vault accounting stays in the vaults.
///
/// @dev    Venue reality on Robinhood Chain (verified 2026-11-25): wstETH
///         exists as a CCIP BurnMint token (0x2dC99af320BC317c567f24eE95811dcbd5983DfD)
///         but carries no on-chain rate function, and no WETH/wstETH pool
///         exists yet on the canonical Uniswap V3 deployment. Pricing here
///         therefore comes from the V3 pool's slot0 once a pool exists at
///         the configured fee tier; while no pool exists, rate() returns 0,
///         stake() and every swap-backed recall revert (fail closed), and
///         positionValue() falls back to the staked cost basis so vault
///         accounting never invents a gain or a loss.
///         Accounting: stakedPrincipal is the ETH cost basis converted into
///         wstETH. It rises by the ETH spent in stake(), falls by the ETH
///         amount a recall pulls back out of the position, and is untouched
///         by collectYield() — so accruedYield() is always position value
///         minus cost basis, never principal.
///         Slippage: swaps are bounded by maxSlippageBps around the pool's
///         spot rate (default 1%, admin-settable up to 10%). Spot pricing
///         from a young, thin pool is an accounting convenience, not an
///         oracle; the slippage bound is the protection on execution.
contract StakingStrategy {
    address public immutable factory;
    address public immutable weth;       // WETH on Robinhood Chain
    address public immutable wsteth;     // wstETH on Robinhood Chain (CCIP)
    address public immutable swapRouter; // Uniswap SwapRouter02
    address public immutable v3Factory;  // Uniswap V3 factory
    address public admin;                // protocol admin (roles, pause)
    address public executor;             // strategy executor (stake, yield)
    bool public stakePaused;             // blocks stake() only
    uint24 public poolFee;               // V3 fee tier of the WETH/wstETH pool
    uint256 public maxSlippageBps;       // swap bound around spot, in bps
    uint256 public stakedPrincipal;      // ETH cost basis inside wstETH

    event Staked(uint256 ethIn, uint256 wstOut);
    event YieldCollected(uint256 amount, address indexed to);
    event AdminSet(address admin);
    event ExecutorSet(address executor);
    event StakePausedSet(bool paused);
    event PoolFeeSet(uint24 fee);
    event MaxSlippageSet(uint256 bps);

    modifier onlyAdmin() { require(msg.sender == admin, "not admin"); _; }
    modifier onlyExecutor() { require(msg.sender == executor, "not executor"); _; }

    constructor(
        address _factory,
        address _admin,
        address _executor,
        address _weth,
        address _wsteth,
        address _swapRouter,
        address _v3Factory,
        uint24 _poolFee
    ) {
        factory = _factory;
        admin = _admin;
        executor = _executor;
        weth = _weth;
        wsteth = _wsteth;
        swapRouter = _swapRouter;
        v3Factory = _v3Factory;
        poolFee = _poolFee;
        maxSlippageBps = 100; // 1%
    }

    // ---------- Admin ----------
    function setExecutor(address _executor) external onlyAdmin {
        require(_executor != address(0), "zero executor");
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    function setAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "zero admin");
        admin = _admin;
        emit AdminSet(_admin);
    }

    function setStakePaused(bool paused) external onlyAdmin {
        stakePaused = paused;
        emit StakePausedSet(paused);
    }

    function setPoolFee(uint24 fee) external onlyAdmin {
        require(fee == 100 || fee == 500 || fee == 3000 || fee == 10000, "bad fee tier");
        poolFee = fee;
        emit PoolFeeSet(fee);
    }

    function setMaxSlippageBps(uint256 bps) external onlyAdmin {
        require(bps <= 1000, "slippage too high");
        maxSlippageBps = bps;
        emit MaxSlippageSet(bps);
    }

    // ---------- Pricing ----------
    /// The configured WETH/wstETH pool, or address(0) while none exists.
    function pool() public view returns (address) {
        return IV3FactoryS(v3Factory).getPool(weth, wsteth, poolFee);
    }

    /// Spot rate: WETH per 1 wstETH, scaled 1e18, from the pool's slot0.
    /// Returns 0 while no pool exists (the strategy is then inert).
    function rate() public view returns (uint256) {
        address p = pool();
        if (p == address(0)) return 0;
        (uint160 sqrtPriceX96, , , , , , ) = IV3PoolS(p).slot0();
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        if (IV3PoolS(p).token0() == wsteth) {
            // price is WETH (token1) per wstETH (token0)
            return priceX192 * 1e18 / (1 << 192);
        }
        // price is wstETH (token1) per WETH (token0); invert
        return (uint256(1e18) << 192) / priceX192;
    }

    // ---------- Stake (executor only) ----------
    /// Sweep this contract's whole idle ETH balance into wstETH.
    function stake() external onlyExecutor returns (uint256 wstOut) {
        require(!stakePaused, "stake paused");
        uint256 amount = address(this).balance;
        require(amount > 0, "nothing to stake");
        uint256 r = rate();
        require(r > 0, "no pool");
        uint256 expected = amount * 1e18 / r;
        uint256 minOut = expected * (10000 - maxSlippageBps) / 10000;
        wstOut = ISwapRouterS(swapRouter).exactInputSingle{value: amount}(
            ISwapRouterS.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: wsteth,
                fee: poolFee,
                recipient: address(this),
                amountIn: amount,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        stakedPrincipal += amount;
        emit Staked(amount, wstOut);
    }

    // ---------- Internal swap back to ETH ----------
    /// Swap wstETH for exactly `ethOut` ETH (received as WETH, then
    /// unwrapped). Returns the wstETH spent. Reverts while no pool exists.
    function _swapToEth(uint256 ethOut) internal returns (uint256 wstSpent) {
        uint256 r = rate();
        require(r > 0, "no pool");
        // rate is WETH per wstETH, so wstETH needed = ethOut / rate.
        uint256 wstNeeded = (ethOut * 1e18 + r - 1) / r;
        uint256 maxIn = wstNeeded * (10000 + maxSlippageBps) / 10000;
        require(IERC20S(wsteth).approve(swapRouter, maxIn), "approve failed");
        wstSpent = ISwapRouterS(swapRouter).exactOutputSingle(
            ISwapRouterS.ExactOutputSingleParams({
                tokenIn: wsteth,
                tokenOut: weth,
                fee: poolFee,
                recipient: address(this),
                amountOut: ethOut,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0
            })
        );
        require(IERC20S(wsteth).approve(swapRouter, 0), "approve reset failed");
        IWETHS(weth).withdraw(ethOut);
    }

    // ---------- Vault recall (same guard pattern as SimpleStrategy) ----------
    /// Called by a QuiverVault to recall capital. `to` must be the caller vault.
    /// ETH pays from the idle balance first and swaps back only the shortfall
    /// from the wstETH position. Other assets pay from idle balance only.
    function withdraw(address token, uint256 amount, address to) external {
        require(IVaultRegistryS(factory).isVault(msg.sender), "caller not a vault");
        require(to == msg.sender, "recall only to the vault itself");
        if (token == address(0)) {
            uint256 idle = address(this).balance;
            if (idle < amount) {
                uint256 need = amount - idle;
                _swapToEth(need);
                stakedPrincipal = need < stakedPrincipal ? stakedPrincipal - need : 0;
            }
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH send failed");
        } else {
            require(IERC20S(token).transfer(to, amount), "token send failed");
        }
    }

    // ---------- Yield collection (executor only, capped at real profit) ----------
    /// Swap `amount` of accrued staking profit back to ETH and send it to
    /// `to` (the executor wallet, which settles it into vault yield
    /// reserves). Reverts unless the amount is covered by profit above the
    /// staked cost basis.
    function collectYield(address to, uint256 amount) external onlyExecutor {
        require(amount > 0, "zero amount");
        require(amount <= accruedYield(), "exceeds accrued yield");
        _swapToEth(amount);
        (bool ok, ) = payable(to).call{value: amount}("");
        require(ok, "ETH send failed");
        emit YieldCollected(amount, to);
    }

    // ---------- Views ----------
    /// wstETH held by this strategy.
    function wstBalance() public view returns (uint256) {
        return IERC20S(wsteth).balanceOf(address(this));
    }

    /// Current ETH value of the wstETH position. While no pool exists the
    /// position is carried at cost basis (no invented gain or loss).
    function positionValue() public view returns (uint256) {
        uint256 bal = wstBalance();
        if (bal == 0) return 0;
        uint256 r = rate();
        if (r == 0) return stakedPrincipal;
        return bal * r / 1e18;
    }

    /// Profit accrued in the wstETH position above the staked cost basis.
    function accruedYield() public view returns (uint256) {
        uint256 value = positionValue();
        return value > stakedPrincipal ? value - stakedPrincipal : 0;
    }

    function idleBalance(address token) external view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20S(token).balanceOf(address(this));
    }

    /// Total value this strategy holds for `token`: for ETH, idle plus the
    /// wstETH position; for anything else, the idle balance.
    function balanceOf(address token) external view returns (uint256) {
        if (token == address(0)) {
            return address(this).balance + positionValue();
        }
        return IERC20S(token).balanceOf(address(this));
    }

    receive() external payable {}
}
