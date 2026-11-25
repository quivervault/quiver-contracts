// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20L {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETHL {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @notice Minimal Uniswap V3 pool interface (identity, spacing, spot price).
interface IV3PoolL {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
    function factory() external view returns (address);
    function slot0() external view returns (
        uint160 sqrtPriceX96, int24 tick, uint16 observationIndex,
        uint16 observationCardinality, uint16 observationCardinalityNext,
        uint8 feeProtocol, bool unlocked
    );
}

/// @notice Minimal Uniswap V3 NonfungiblePositionManager interface.
interface INFPM {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params) external payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }
    function collect(CollectParams calldata params) external payable
        returns (uint256 amount0, uint256 amount1);
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function decreaseLiquidity(DecreaseLiquidityParams calldata params) external payable
        returns (uint256 amount0, uint256 amount1);
    function burn(uint256 tokenId) external payable;
    function positions(uint256 tokenId) external view returns (
        uint96 nonce, address operator, address token0, address token1, uint24 fee,
        int24 tickLower, int24 tickUpper, uint128 liquidity,
        uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128,
        uint128 tokensOwed0, uint128 tokensOwed1
    );
}

/// @notice Minimal Uniswap SwapRouter02 interface (single-hop exact input).
interface ISwapRouterL {
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
}

interface IVaultRegistryL {
    function isVault(address account) external view returns (bool);
}

/// @title LPStrategy
/// @notice Uniswap V3 concentrated-liquidity strategy for Quiver vaults: the
///         third leg (staking + Morpho lending + Uniswap LP), replacing the
///         retired Lighter perps leg. Vaults deploy ETH and/or USDG here; the
///         executor provides concentrated liquidity on the WETH/USDG 0.01%
///         pool (the deepest on Robinhood Chain) through the canonical
///         NonfungiblePositionManager, and the position earns the pool's
///         trading fees.
///
///         How it fits the vault architecture:
///         - Vaults deploy capital here exactly like SimpleStrategy
///           (deployToStrategy sends ETH/USD G; recall calls withdraw()).
///         - Deployed capital first sits idle in this contract. The executor
///           mints ONE pooled NFPM position (single active position per
///           strategy, by design) with executor-chosen ticks and amounts.
///         - Recall pays idle principal first; only a recall the idle
///           balance cannot cover exits the position (full burn), so
///           ordinary withdrawals rarely touch the position.
///         - This contract never credits yield itself. The executor reads
///           accruedYield(token), collects that amount with collectYield()
///           into its own wallet, and settles it into each vault's yield
///           reserve via vault.fundYield, pro-rata from the vaults' deployedIn
///           figures — the same settlement pattern as PerpStrategy,
///           MorphoStrategy and StakingStrategy, so the vault rule "yield
///           only against real funded tokens" holds.
///         - The LP position is pooled across vaults by necessity (one
///           strategy contract); per-vault accounting stays in the vaults.
///
/// @dev    Accounting — fees only, no invented value:
///         - principal0/principal1 are the WETH/USD G amounts actually spent
///           at mint (from the NFPM mint return). They are the position's
///           cost basis and reset to 0 on a full exit.
///         - feeBalance0/feeBalance1 are trading fees already collected into
///           this contract and not yet settled to the executor. They rise
///           ONLY from collect() payouts of accrued fees (collectFees(), and
///           the fee-harvest step of a full exit) and fall in collectYield().
///           The principal a full exit returns — in whatever token mix the
///           price produced — is never booked as fees: a position that
///           swapped into one token as the price moved returns principal,
///           not yield. (HeyResearch review GHSA-mgpc-wcqx-fc7x, finding 1.)
///         - unminted0()/unminted1() are COMPUTED from live balances minus
///           feeBalance: everything held that is not a tracked fee is
///           principal. ETH and WETH count as one bucket (1:1 on wrap).
///         - accruedYield(token) is exactly feeBalance for that token: yield
///           is only recognised once fees are collected out of the position.
///           Uncollected fees and unrealised P&L (including impermanent
///           loss) are NOT counted. balanceOf(token) carries the position at
///           COST BASIS (principal0/1), not mark-to-market; the market value
///           is computed off-chain from positionInfo() + the pool price.
///         - A recall the position cannot cover (impermanent loss ate the
///           principal) REVERTS — fail closed, never short-pays a vault.
///         - The executor owns the token mix: swaps change pooled principal
///           between WETH and USDG while the vaults track deployed principal
///           per token, so the executor must keep (or swap back) enough of
///           each token to cover recalls. A recall in a token the strategy
///           no longer holds reverts until the executor rebalances the mix.
///         - Exit slippage: a withdraw-driven exit uses amountMin 0 on the
///           decrease, and the shortfall check after the exit is the
///           protection (a sandwiched exit reverts instead of paying short).
///           A rebalance takes executor-supplied amountMin bounds.
///         - v1 limits: one position at a time; any strategy withdrawal that
///           dips into the position exits it fully (the executor re-mints
///           after); no on-chain position valuation (no vendored TickMath /
///           LiquidityAmounts) — positionInfo() exposes the raw reads for
///           exact off-chain valuation.
contract LPStrategy {
    address public immutable factory;
    address public immutable weth;       // WETH on Robinhood Chain
    address public immutable usdg;       // USDG on Robinhood Chain
    address public immutable pool;       // WETH/USDG 0.01% V3 pool
    address public immutable nfpm;       // Uniswap V3 NonfungiblePositionManager
    address public immutable swapRouter; // Uniswap SwapRouter02
    uint24 public immutable poolFee;     // V3 fee tier of the pool (100)
    address public admin;                // protocol admin (roles, pause)
    address public executor;             // strategy executor (mint, yield)
    bool public mintPaused;              // blocks mint() / rebalance() only

    uint256 public tokenId;              // 0 = no active position
    int24 public tickLower;
    int24 public tickUpper;
    uint256 public principal0;           // WETH actually spent at mint
    uint256 public principal1;           // USDG actually spent at mint
    uint256 public feeBalance0;          // collected WETH fees, unsettled
    uint256 public feeBalance1;          // collected USDG fees, unsettled

    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    event Minted(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event YieldCollected(address indexed token, uint256 amount, address indexed to);
    event PositionExited(uint256 indexed tokenId, uint256 received0, uint256 received1, uint256 fees0, uint256 fees1);
    event Swapped(address indexed tokenIn, uint256 amountIn, uint256 amountOut);
    event AdminSet(address admin);
    event ExecutorSet(address executor);
    event MintPausedSet(bool paused);

    modifier onlyAdmin() { require(msg.sender == admin, "not admin"); _; }
    modifier onlyExecutor() { require(msg.sender == executor, "not executor"); _; }

    constructor(
        address _factory,
        address _admin,
        address _executor,
        address _weth,
        address _usdg,
        address _pool,
        address _nfpm,
        address _swapRouter,
        uint24 _poolFee
    ) {
        require(_factory != address(0) && _weth != address(0) && _usdg != address(0), "zero address");
        require(_pool != address(0) && _nfpm != address(0) && _swapRouter != address(0), "zero address");
        require(IV3PoolL(_pool).token0() == _weth, "pool token0 != weth");
        require(IV3PoolL(_pool).token1() == _usdg, "pool token1 != usdg");
        require(IV3PoolL(_pool).fee() == _poolFee, "pool fee mismatch");
        require(INFPM(_nfpm).factory() == IV3PoolL(_pool).factory(), "nfpm factory mismatch");
        require(INFPM(_nfpm).WETH9() == _weth, "nfpm weth mismatch");
        factory = _factory;
        admin = _admin;
        executor = _executor;
        weth = _weth;
        usdg = _usdg;
        pool = _pool;
        nfpm = _nfpm;
        swapRouter = _swapRouter;
        poolFee = _poolFee;
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

    function setMintPaused(bool paused) external onlyAdmin {
        mintPaused = paused;
        emit MintPausedSet(paused);
    }

    // ---------- Views ----------
    /// Deployed WETH-side principal not yet in the position (ETH + WETH,
    /// net of unsettled WETH fees). Computed from live balances.
    function unminted0() public view returns (uint256) {
        uint256 bal = IERC20L(weth).balanceOf(address(this)) + address(this).balance;
        return bal > feeBalance0 ? bal - feeBalance0 : 0;
    }

    /// Deployed USDG principal not yet in the position, net of unsettled fees.
    function unminted1() public view returns (uint256) {
        uint256 bal = IERC20L(usdg).balanceOf(address(this));
        return bal > feeBalance1 ? bal - feeBalance1 : 0;
    }

    /// Fees collected and not yet settled, per token. ETH fees are the WETH
    /// fees (unwrappable 1:1).
    function accruedYield(address token) public view returns (uint256) {
        if (token == weth || token == address(0)) return feeBalance0;
        if (token == usdg) return feeBalance1;
        return 0;
    }

    /// Raw position reads for exact off-chain valuation: (tokenId, tickLower,
    /// tickUpper, liquidity, tokensOwed0, tokensOwed1).
    function positionInfo() external view returns (
        uint256 _tokenId, int24 _tickLower, int24 _tickUpper,
        uint128 _liquidity, uint128 _tokensOwed0, uint128 _tokensOwed1
    ) {
        if (tokenId == 0) return (0, 0, 0, 0, 0, 0);
        (, , , , , int24 tl, int24 tu, uint128 liq, , , uint128 o0, uint128 o1) =
            INFPM(nfpm).positions(tokenId);
        return (tokenId, tl, tu, liq, o0, o1);
    }

    /// Spot price: USDG per 1 WETH, scaled 1e18, from the pool's slot0.
    /// A convenience for the executor's ratio math, not an oracle.
    function poolPrice() public view returns (uint256) {
        (uint160 sqrtPriceX96, , , , , , ) = IV3PoolL(pool).slot0();
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        // raw = USDG smallest units per 1 wei; USDG per WETH = raw * 1e18,
        // then scaled 1e18 with the 12-decimal gap (18 - 6).
        return priceX192 * 1e12 / (uint256(1) << 192) * 1e18;
    }

    function idleBalance(address token) external view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20L(token).balanceOf(address(this));
    }

    /// Total tokens held for `token`, with the position carried at COST BASIS
    /// (principal0/1) — NOT a mark-to-market value. Use positionInfo() +
    /// the pool price off-chain for the market value.
    function balanceOf(address token) external view returns (uint256) {
        if (token == weth || token == address(0)) {
            return IERC20L(weth).balanceOf(address(this)) + address(this).balance + principal0;
        }
        if (token == usdg) {
            return IERC20L(usdg).balanceOf(address(this)) + principal1;
        }
        return IERC20L(token).balanceOf(address(this));
    }

    // ---------- Mint (executor only) ----------
    /// Mint the single pooled position. Wraps all idle ETH first. Amounts are
    /// the executor's choice (computed off-chain from the pool price and the
    /// target range); amountMin bounds are the slippage protection.
    function mint(
        int24 _tickLower,
        int24 _tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyExecutor returns (uint256 _tokenId) {
        require(!mintPaused, "mint paused");
        require(tokenId == 0, "position active");
        return _mint(_tickLower, _tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min);
    }

    function _mint(
        int24 _tickLower,
        int24 _tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal returns (uint256 _tokenId) {
        int24 spacing = IV3PoolL(pool).tickSpacing();
        require(_tickLower < _tickUpper, "bad ticks");
        require(_tickLower >= MIN_TICK && _tickUpper <= MAX_TICK, "tick out of range");
        require(_tickLower % spacing == 0 && _tickUpper % spacing == 0, "tick not spaced");
        // Wrap all idle ETH so the whole ETH-side principal is WETH.
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) IWETHL(weth).deposit{value: ethBal}();
        require(amount0Desired <= unminted0(), "amount0 exceeds unminted");
        require(amount1Desired <= unminted1(), "amount1 exceeds unminted");
        require(IERC20L(weth).approve(nfpm, amount0Desired), "weth approve failed");
        require(IERC20L(usdg).approve(nfpm, amount1Desired), "usdg approve failed");
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        (_tokenId, liquidity, amount0, amount1) = INFPM(nfpm).mint(
            INFPM.MintParams({
                token0: weth,
                token1: usdg,
                fee: poolFee,
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        tokenId = _tokenId;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
        principal0 = amount0;
        principal1 = amount1;
        emit Minted(_tokenId, _tickLower, _tickUpper, amount0, amount1);
    }

    // ---------- Rebalance (executor only) ----------
    /// Exit the current position (if any) and mint a fresh one around the new
    /// ticks, in a single transaction. Exit proceeds stay idle until minted.
    function rebalance(
        int24 _tickLower,
        int24 _tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min
    ) external onlyExecutor returns (uint256 _tokenId) {
        require(!mintPaused, "mint paused");
        if (tokenId != 0) _exitPosition();
        return _mint(_tickLower, _tickUpper, amount0Desired, amount1Desired, amount0Min, amount1Min);
    }

    // ---------- Fee collection (executor only) ----------
    /// Collect accrued trading fees out of the position into this contract.
    /// The position (and its liquidity) is untouched; fees land in feeBalance.
    function collectFees() external onlyExecutor returns (uint256 amount0, uint256 amount1) {
        require(tokenId != 0, "no position");
        (amount0, amount1) = INFPM(nfpm).collect(
            INFPM.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        feeBalance0 += amount0;
        feeBalance1 += amount1;
        emit FeesCollected(amount0, amount1);
    }

    // ---------- Ratio swaps (executor only, principal only) ----------
    /// Swap WETH-side principal into USDG (exact input, min-out guard).
    /// Wraps idle ETH first if the WETH balance is short. Only principal
    /// moves: the input must fit inside unminted0().
    function swapWethForUsdg(uint256 amountIn, uint256 amountOutMin) external onlyExecutor returns (uint256 amountOut) {
        require(amountIn > 0, "zero amount");
        require(amountIn <= unminted0(), "exceeds unminted principal");
        uint256 wethBal = IERC20L(weth).balanceOf(address(this));
        if (wethBal < amountIn) {
            IWETHL(weth).deposit{value: amountIn - wethBal}();
        }
        require(IERC20L(weth).approve(swapRouter, amountIn), "approve failed");
        amountOut = ISwapRouterL(swapRouter).exactInputSingle(
            ISwapRouterL.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: usdg,
                fee: poolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
        emit Swapped(weth, amountIn, amountOut);
    }

    /// Swap USDG principal into WETH (exact input, min-out guard).
    function swapUsdgForWeth(uint256 amountIn, uint256 amountOutMin) external onlyExecutor returns (uint256 amountOut) {
        require(amountIn > 0, "zero amount");
        require(amountIn <= unminted1(), "exceeds unminted principal");
        require(IERC20L(usdg).approve(swapRouter, amountIn), "approve failed");
        amountOut = ISwapRouterL(swapRouter).exactInputSingle(
            ISwapRouterL.ExactInputSingleParams({
                tokenIn: usdg,
                tokenOut: weth,
                fee: poolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: amountOutMin,
                sqrtPriceLimitX96: 0
            })
        );
        emit Swapped(usdg, amountIn, amountOut);
    }

    // ---------- Internal full exit ----------
    /// Burn the whole position. Fees are harvested FIRST with a collect-only
    /// call (which pays out accrued trading fees without touching
    /// liquidity); only that amount is booked as yield. The liquidity is
    /// then decreased and the principal collected in whatever token mix the
    /// price produced — principal is never booked as fees, no matter how
    /// the mix changed since mint. Resets position state.
    function _exitPosition() internal {
        uint256 id = tokenId;
        // 1. Harvest fees only.
        (uint256 fees0, uint256 fees1) = INFPM(nfpm).collect(
            INFPM.CollectParams({
                tokenId: id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        feeBalance0 += fees0;
        feeBalance1 += fees1;
        // 2. Exit the liquidity; proceeds are principal, in the live mix.
        (, , , , , , , uint128 liquidity, , , , ) = INFPM(nfpm).positions(id);
        if (liquidity > 0) {
            INFPM(nfpm).decreaseLiquidity(
                INFPM.DecreaseLiquidityParams({
                    tokenId: id,
                    liquidity: liquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: block.timestamp
                })
            );
        }
        (uint256 received0, uint256 received1) = INFPM(nfpm).collect(
            INFPM.CollectParams({
                tokenId: id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        INFPM(nfpm).burn(id);
        principal0 = 0;
        principal1 = 0;
        tokenId = 0;
        tickLower = 0;
        tickUpper = 0;
        emit PositionExited(id, received0, received1, fees0, fees1);
    }

    // ---------- Vault recall (same guard pattern as SimpleStrategy) ----------
    /// Called by a QuiverVault to recall capital. `to` must be the caller vault.
    /// Pays from idle principal first; only a recall the idle balance cannot
    /// cover exits the position (full burn). Fees are never spent as
    /// principal. Reverts instead of short-paying when the position cannot
    /// cover the recall (impermanent loss realised on exit).
    function withdraw(address token, uint256 amount, address to) external {
        require(IVaultRegistryL(factory).isVault(msg.sender), "caller not a vault");
        require(to == msg.sender, "recall only to the vault itself");
        if (token == address(0)) {
            uint256 wethBal = IERC20L(weth).balanceOf(address(this));
            uint256 cover = address(this).balance + (wethBal > feeBalance0 ? wethBal - feeBalance0 : 0);
            if (cover < amount && tokenId != 0) _exitPosition();
            uint256 ethBal = address(this).balance;
            uint256 wethNet = IERC20L(weth).balanceOf(address(this));
            wethNet = wethNet > feeBalance0 ? wethNet - feeBalance0 : 0;
            require(ethBal + wethNet >= amount, "insufficient after exit");
            if (ethBal < amount) IWETHL(weth).withdraw(amount - ethBal);
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH send failed");
        } else if (token == usdg) {
            uint256 usdgBal = IERC20L(usdg).balanceOf(address(this));
            uint256 cover = usdgBal > feeBalance1 ? usdgBal - feeBalance1 : 0;
            if (cover < amount && tokenId != 0) _exitPosition();
            uint256 afterBal = IERC20L(usdg).balanceOf(address(this));
            afterBal = afterBal > feeBalance1 ? afterBal - feeBalance1 : 0;
            require(afterBal >= amount, "insufficient after exit");
            require(IERC20L(usdg).transfer(to, amount), "token send failed");
        } else if (token == weth) {
            uint256 wethBal = IERC20L(weth).balanceOf(address(this));
            uint256 net = wethBal > feeBalance0 ? wethBal - feeBalance0 : 0;
            require(net >= amount, "insufficient WETH");
            require(IERC20L(weth).transfer(to, amount), "token send failed");
        } else {
            require(IERC20L(token).balanceOf(address(this)) >= amount, "insufficient balance");
            require(IERC20L(token).transfer(to, amount), "token send failed");
        }
    }

    // ---------- Yield collection (executor only, capped at real profit) ----------
    /// Send `amount` of collected fees for `token` to `to` (the executor
    /// wallet, which settles it into vault yield reserves). Reverts unless
    /// the amount is covered by collected-but-unsettled fees. ETH is paid by
    /// unwrapping WETH fees.
    function collectYield(address token, address to, uint256 amount) external onlyExecutor {
        require(amount > 0, "zero amount");
        require(to != address(0), "zero to");
        if (token == address(0)) {
            require(amount <= feeBalance0, "exceeds accrued yield");
            feeBalance0 -= amount;
            IWETHL(weth).withdraw(amount);
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH send failed");
        } else if (token == weth) {
            require(amount <= feeBalance0, "exceeds accrued yield");
            feeBalance0 -= amount;
            require(IERC20L(weth).transfer(to, amount), "token send failed");
        } else if (token == usdg) {
            require(amount <= feeBalance1, "exceeds accrued yield");
            feeBalance1 -= amount;
            require(IERC20L(usdg).transfer(to, amount), "token send failed");
        } else {
            revert("unsupported yield token");
        }
        emit YieldCollected(token, amount, to);
    }

    receive() external payable {}
}
