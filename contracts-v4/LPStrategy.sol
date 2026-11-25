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

/// @notice Minimal Uniswap V3 pool interface (identity, spacing, spot price,
///         TWAP oracle).
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
    function observe(uint32[] calldata secondsAgos) external view returns (
        int56[] memory tickCumulatives,
        uint160[] memory secondsPerLiquidityCumulativeX128s
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
///           balance cannot cover dips into the position, and then only
///           PROPORTIONALLY: the strategy decreases just enough liquidity
///           to cover the shortfall, so one vault's recall can never force
///           a full exit that stops everyone's fees (re-test of
///           GHSA-mgpc-wcqx-fc7x). Per-vault records live in the vaults
///           (deployedIn per strategy per token) and cap every recall at
///           what that vault actually deployed.
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
///         - Exit slippage: every trade (swaps, mint) is bounded on-chain.
///           Spot must sit within MAX_TICK_DEVIATION of the pool's
///           30-minute TWAP, swap outputs must clear 99.5% of the
///           TWAP-expected amount, and mint minimums must clear 99.5% of
///           desired — so even a compromised executor key cannot sandwich
///           its own trades (re-test of GHSA-mgpc-wcqx-fc7x). Trades revert
///           (fail closed) while spot deviates beyond the bound. Decreases
///           (recalls, exits) carry no deviation check: they do not trade,
///           they return the position's current composition, so owner
///           recalls keep working during a deviation; their minimums
///           clear 99.5% of the spot-expected amounts. A recall the
///           position cannot cover reverts BEFORE touching the position —
///           it never burns the whole position for an underfunded recall.
///         - Swap volume: executor swaps are capped per rolling window
///           (SWAP_WINDOW) at MAX_SWAP_VOLUME_BPS of the TWAP-valued
///           principal, so repeated bounded swaps cannot bleed the
///           position trade after trade (v3 re-test of GHSA-mgpc-wcqx-fc7x).
///         - Executor rotation is timelocked and admin transfer is
///           two-step, matching the factory (re-test of GHSA-mgpc-wcqx-fc7x).
///         - v1 limits: one position at a time; no on-chain position
///           valuation beyond the TWAP/spot amount math used for bounds —
///           positionInfo() exposes the raw reads for exact off-chain
///           valuation.
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

    /// TWAP window for the on-chain price bound (30 minutes).
    uint32 public constant TWAP_WINDOW = 1800;
    /// Spot may deviate from TWAP by at most this many ticks (~0.5%) before
    /// price-sensitive operations revert.
    int24 public constant MAX_TICK_DEVIATION = 50;
    /// Minimum-output floors: swaps/mints/decreases must clear
    /// (10000 - MAX_SLIPPAGE_BPS) / 10000 of the expected amount (99.5%).
    uint256 public constant MAX_SLIPPAGE_BPS = 50;
    /// Rolling window for the executor swap-volume cap.
    uint256 public constant SWAP_WINDOW = 1 days;
    /// Executor swaps in one window may move at most this share (bps) of
    /// the strategy's TWAP-valued principal. Bounds how much a compromised
    /// or careless executor key can bleed through repeated bounded swaps:
    /// worst case per window is roughly cap x slippage floor.
    uint256 public constant MAX_SWAP_VOLUME_BPS = 5000;
    /// sqrt(1.0001) scaled by 2^128, for sqrtRatioAtTick.
    uint256 internal constant SQRT_10001_Q128 = 340299380613952818054172298683778356828;

    /// Delay between proposing an executor rotation and executing it.
    uint256 public constant TIMELOCK_DELAY = 2 days;
    /// Pending executor rotation (timelocked).
    address public pendingExecutor;
    uint256 public executorEta;
    /// Pending admin transfer (two-step: the new admin must accept).
    address public pendingAdmin;
    /// Swap-volume accounting for the current window (input valued in USDG
    /// at the TWAP when each swap ran).
    uint256 public swapWindowStart;
    uint256 public swapVolumeUsdg;

    event Minted(uint256 indexed tokenId, int24 tickLower, int24 tickUpper, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 amount0, uint256 amount1);
    event YieldCollected(address indexed token, uint256 amount, address indexed to);
    event PositionExited(uint256 indexed tokenId, uint256 received0, uint256 received1, uint256 fees0, uint256 fees1);
    event PositionPartiallyExited(uint256 indexed tokenId, uint128 liquidityRemoved, uint256 received0, uint256 received1, uint256 fees0, uint256 fees1);
    event Swapped(address indexed tokenIn, uint256 amountIn, uint256 amountOut);
    event AdminSet(address admin);
    event AdminProposed(address admin);
    event AdminProposalCancelled(address admin);
    event ExecutorSet(address executor);
    event ExecutorProposed(address executor, uint256 eta);
    event ExecutorProposalCancelled(address executor);
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
    /// Propose rotating the executor. Execution waits out the timelock, so
    /// the admin can never become the executor instantly.
    function proposeExecutor(address _executor) external onlyAdmin {
        require(_executor != address(0), "zero executor");
        require(executorEta == 0, "already proposed");
        pendingExecutor = _executor;
        executorEta = block.timestamp + TIMELOCK_DELAY;
        emit ExecutorProposed(_executor, executorEta);
    }

    /// Execute a proposed executor rotation once the timelock has elapsed.
    function executeExecutor() external onlyAdmin {
        require(executorEta != 0, "not proposed");
        require(block.timestamp >= executorEta, "timelock not elapsed");
        executor = pendingExecutor;
        delete pendingExecutor;
        delete executorEta;
        emit ExecutorSet(executor);
    }

    /// Cancel a pending executor rotation before it executes.
    function cancelExecutorProposal() external onlyAdmin {
        require(executorEta != 0, "not proposed");
        address cancelled = pendingExecutor;
        delete pendingExecutor;
        delete executorEta;
        emit ExecutorProposalCancelled(cancelled);
    }

    /// Propose a new admin. The transfer completes only when the new admin
    /// accepts, so a wrong address can never brick the role.
    function proposeAdmin(address _admin) external onlyAdmin {
        require(_admin != address(0), "zero admin");
        pendingAdmin = _admin;
        emit AdminProposed(_admin);
    }

    /// Accept a proposed admin transfer (callable only by the pending admin).
    function acceptAdmin() external {
        require(msg.sender == pendingAdmin, "not pending admin");
        admin = pendingAdmin;
        delete pendingAdmin;
        emit AdminSet(admin);
    }

    /// Cancel a pending admin transfer.
    function cancelAdminProposal() external onlyAdmin {
        address cancelled = pendingAdmin;
        delete pendingAdmin;
        emit AdminProposalCancelled(cancelled);
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

    // ---------- Price math (TWAP bound) ----------
    /// 512-bit multiply-divide: floor(a * b / denominator) without overflow.
    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0 = a * b;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / denominator;
            require(denominator > prod1, "mulDiv overflow");
            uint256 remainder;
            assembly { remainder := mulmod(a, b, denominator) }
            assembly {
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            result = prod0 * inverse;
        }
    }

    /// sqrtPriceX96 at a tick: sqrt(1.0001^tick) * 2^96, computed by
    /// exponentiation by squaring in Q128 fixed point (relative error
    /// ~1e-25 at working ticks, far inside the 1-2% bound tolerances).
    function _sqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick out of range");
        uint256 n = tick >= 0 ? uint256(int256(tick)) : uint256(int256(-tick));
        uint256 result = uint256(1) << 128;
        uint256 b = SQRT_10001_Q128;
        while (n > 0) {
            if (n & 1 == 1) result = _mulDiv(result, b, uint256(1) << 128);
            b = _mulDiv(b, b, uint256(1) << 128);
            n >>= 1;
        }
        if (tick < 0) result = _mulDiv(uint256(1) << 128, uint256(1) << 128, result);
        return uint160(result >> 32);
    }

    /// Token amounts for `liquidity` between two sqrt prices (amount0 side).
    function _amount0ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _mulDiv(uint256(liquidity) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
    }

    /// Token amounts for `liquidity` between two sqrt prices (amount1 side).
    function _amount1ForLiquidity(uint160 sqrtA, uint160 sqrtB, uint128 liquidity) internal pure returns (uint256) {
        if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
        return _mulDiv(liquidity, sqrtB - sqrtA, uint256(1) << 96);
    }

    /// Token amounts a position of `liquidity` over [tickLower, tickUpper]
    /// holds at sqrt price `sqrtP`.
    function _amountsForLiquidity(uint160 sqrtP, uint128 liquidity) internal view returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtLower = _sqrtRatioAtTick(tickLower);
        uint160 sqrtUpper = _sqrtRatioAtTick(tickUpper);
        if (sqrtP <= sqrtLower) {
            amount0 = _amount0ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        } else if (sqrtP < sqrtUpper) {
            amount0 = _amount0ForLiquidity(sqrtP, sqrtUpper, liquidity);
            amount1 = _amount1ForLiquidity(sqrtLower, sqrtP, liquidity);
        } else {
            amount1 = _amount1ForLiquidity(sqrtLower, sqrtUpper, liquidity);
        }
    }

    /// The pool's TWAP tick over TWAP_WINDOW seconds.
    function _twapTick() internal view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = TWAP_WINDOW;
        secondsAgos[1] = 0;
        (int56[] memory cumulatives, ) = IV3PoolL(pool).observe(secondsAgos);
        int56 diff = cumulatives[1] - cumulatives[0];
        int56 window = int56(uint56(TWAP_WINDOW));
        int56 twap = diff / window;
        if (diff < 0 && diff % window != 0) twap--; // round toward -inf
        return int24(twap);
    }

    /// Spot sqrt price from slot0.
    function _spotSqrtPrice() internal view returns (uint160) {
        (uint160 sqrtPriceX96, , , , , , ) = IV3PoolL(pool).slot0();
        return sqrtPriceX96;
    }

    /// Revert unless spot sits within MAX_TICK_DEVIATION of the TWAP.
    function _checkDeviation() internal view {
        (, int24 spotTick, , , , , ) = IV3PoolL(pool).slot0();
        int24 twap = _twapTick();
        int24 dev = spotTick > twap ? spotTick - twap : twap - spotTick;
        require(dev <= MAX_TICK_DEVIATION, "price deviates from TWAP");
    }

    /// Minimum acceptable output for a WETH->USDG swap of `amountIn`:
    /// 99.5% of the TWAP-expected amount.
    function _twapMinOutWethToUsdg(uint256 amountIn) internal view returns (uint256) {
        uint160 s = _sqrtRatioAtTick(_twapTick());
        uint256 expected = _mulDiv(_mulDiv(amountIn, s, uint256(1) << 96), s, uint256(1) << 96);
        return expected * (10000 - MAX_SLIPPAGE_BPS) / 10000;
    }

    /// Minimum acceptable output for a USDG->WETH swap of `amountIn`:
    /// 99.5% of the TWAP-expected amount.
    function _twapMinOutUsdgToWeth(uint256 amountIn) internal view returns (uint256) {
        uint160 s = _sqrtRatioAtTick(_twapTick());
        uint256 expected = _mulDiv(_mulDiv(amountIn, uint256(1) << 96, s), uint256(1) << 96, s);
        return expected * (10000 - MAX_SLIPPAGE_BPS) / 10000;
    }

    /// TWAP-expected USDG value of a WETH amount (raw units, no floor).
    function _wethValueUsdg(uint256 wethAmount) internal view returns (uint256) {
        uint160 s = _sqrtRatioAtTick(_twapTick());
        return _mulDiv(_mulDiv(wethAmount, s, uint256(1) << 96), s, uint256(1) << 96);
    }

    /// Total principal under management, valued in USDG at the TWAP
    /// (idle + in-position cost basis; unsettled fees excluded).
    function _positionValueUsdg() internal view returns (uint256) {
        return unminted1() + principal1 + _wethValueUsdg(unminted0() + principal0);
    }

    /// Account one executor swap against the rolling volume cap. The
    /// input is valued in USDG at the TWAP. Reverts when the window's
    /// cumulative volume would exceed MAX_SWAP_VOLUME_BPS of the
    /// strategy's principal, so repeated bounded swaps cannot bleed the
    /// position trade after trade.
    function _accountSwapVolume(uint256 inputValueUsdg) internal {
        if (block.timestamp >= swapWindowStart + SWAP_WINDOW) {
            swapWindowStart = block.timestamp;
            swapVolumeUsdg = 0;
        }
        uint256 cap = _positionValueUsdg() * MAX_SWAP_VOLUME_BPS / 10000;
        require(swapVolumeUsdg + inputValueUsdg <= cap, "swap volume cap exceeded");
        swapVolumeUsdg += inputValueUsdg;
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
        // Price bound: spot must sit near the TWAP, and the executor's
        // minimums must clear 99.5% of desired (never 0).
        _checkDeviation();
        require(amount0Min >= amount0Desired * (10000 - MAX_SLIPPAGE_BPS) / 10000, "amount0Min below floor");
        require(amount1Min >= amount1Desired * (10000 - MAX_SLIPPAGE_BPS) / 10000, "amount1Min below floor");
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
        // Price bound: spot near TWAP, and the minimum output must clear
        // 99.5% of the TWAP-expected amount (the executor cannot set 0).
        _checkDeviation();
        require(amountOutMin >= _twapMinOutWethToUsdg(amountIn), "amountOutMin below TWAP floor");
        // Volume bound: cumulative swaps per window are capped.
        _accountSwapVolume(_wethValueUsdg(amountIn));
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
        // Price bound: spot near TWAP, and the minimum output must clear
        // 99.5% of the TWAP-expected amount (the executor cannot set 0).
        _checkDeviation();
        require(amountOutMin >= _twapMinOutUsdgToWeth(amountIn), "amountOutMin below TWAP floor");
        // Volume bound: cumulative swaps per window are capped.
        _accountSwapVolume(amountIn);
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

    // ---------- Internal exits ----------
    /// Current position liquidity (0 when no position).
    function _positionLiquidity() internal view returns (uint128) {
        if (tokenId == 0) return 0;
        (, , , , , , , uint128 liq, , , , ) = INFPM(nfpm).positions(tokenId);
        return liq;
    }

    /// Burn the whole position. Fees are harvested FIRST with a collect-only
    /// call (which pays out accrued trading fees without touching
    /// liquidity); only that amount is booked as yield. The liquidity is
    /// then decreased and the principal collected in whatever token mix the
    /// price produced — principal is never booked as fees, no matter how
    /// the mix changed since mint. The decrease carries minimums at 99.5%
    /// of the spot-expected amounts. No TWAP deviation check here: a
    /// decrease does not trade with a counterparty, it only returns the
    /// position's current composition, and any following mint or swap
    /// re-checks the bound (rebalance is atomic, so a deviated price
    /// reverts the whole call). Resets position state.
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
        uint128 liquidity = _positionLiquidity();
        if (liquidity > 0) {
            (uint256 exp0, uint256 exp1) = _amountsForLiquidity(_spotSqrtPrice(), liquidity);
            INFPM(nfpm).decreaseLiquidity(
                INFPM.DecreaseLiquidityParams({
                    tokenId: id,
                    liquidity: liquidity,
                    amount0Min: exp0 * (10000 - MAX_SLIPPAGE_BPS) / 10000,
                    amount1Min: exp1 * (10000 - MAX_SLIPPAGE_BPS) / 10000,
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

    /// Decrease `remove` liquidity from position `id` with minimums at 99.5%
    /// of the spot-expected amounts, then collect the proceeds (principal).
    function _decreaseSlice(uint256 id, uint128 remove) internal returns (uint256 received0, uint256 received1) {
        (uint256 exp0, uint256 exp1) = _amountsForLiquidity(_spotSqrtPrice(), remove);
        INFPM(nfpm).decreaseLiquidity(
            INFPM.DecreaseLiquidityParams({
                tokenId: id,
                liquidity: remove,
                amount0Min: exp0 * (10000 - MAX_SLIPPAGE_BPS) / 10000,
                amount1Min: exp1 * (10000 - MAX_SLIPPAGE_BPS) / 10000,
                deadline: block.timestamp
            })
        );
        (received0, received1) = INFPM(nfpm).collect(
            INFPM.CollectParams({
                tokenId: id,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    /// Size a partial-exit slice: the liquidity whose spot-valued holdings
    /// of the needed token cover `shortfall` (all of it, when the position
    /// holds less than the shortfall or none of the needed token).
    function _sliceSize(address token, uint256 shortfall, uint128 liq) internal view returns (uint128) {
        (uint256 pos0, uint256 pos1) = _amountsForLiquidity(_spotSqrtPrice(), liq);
        uint256 posNeeded = token == usdg ? pos1 : pos0;
        if (posNeeded == 0 || shortfall >= posNeeded) return liq;
        uint128 remove = uint128(_mulDiv(liq, shortfall, posNeeded)) + 1;
        return remove > liq ? liq : remove;
    }

    /// Decrease only enough liquidity to cover a recall shortfall of
    /// `amount` of `token` (address(0)/WETH = token0 side, USDG = token1),
    /// leaving the rest of the pooled position alive for the other vaults.
    /// Fees are harvested first (collect-only, booked as yield); the
    /// decreased slice returns principal in the live mix, never booked as
    /// fees. Cost basis scales down with the liquidity removed. If the
    /// slice takes the last liquidity, the position is burned and reset.
    /// Bounded loop: at most 3 decreases, then the caller's cover check
    /// decides (fail closed).
    ///
    /// No TWAP deviation check: a decrease does not trade, it returns the
    /// position's current composition, so owner recalls keep working while
    /// spot sits away from the TWAP. Any swap or mint that follows still
    /// enforces the bound.
    ///
    /// Fail closed BEFORE touching the position when idle cover plus the
    /// position's spot holdings of the needed token cannot reach `amount`:
    /// an underfunded recall must never burn the whole position.
    function _partialExit(address token, uint256 amount) internal {
        uint256 id = tokenId;
        // 0. Underfunded guard: never burn the position for a recall it
        //    cannot satisfy.
        {
            (uint256 pos0, uint256 pos1) = _amountsForLiquidity(_spotSqrtPrice(), _positionLiquidity());
            uint256 posNeeded = token == usdg ? pos1 : pos0;
            require(_cover(token) + posNeeded >= amount, "insufficient position balance");
        }
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
        // 2. Decrease proportional slices until the idle cover reaches
        //    `amount` or the position is empty.
        uint128 liqBefore = _positionLiquidity();
        uint256 totalReceived0;
        uint256 totalReceived1;
        for (uint256 i = 0; i < 3; i++) {
            if (_cover(token) >= amount) break;
            uint128 liq = _positionLiquidity();
            if (liq == 0) break;
            uint128 remove = _sliceSize(token, amount - _cover(token), liq);
            (uint256 received0, uint256 received1) = _decreaseSlice(id, remove);
            totalReceived0 += received0;
            totalReceived1 += received1;
            // Scale the cost basis down with the liquidity removed.
            principal0 = principal0 * (liq - remove) / liq;
            principal1 = principal1 * (liq - remove) / liq;
            if (liq == remove) {
                INFPM(nfpm).burn(id);
                principal0 = 0;
                principal1 = 0;
                tokenId = 0;
                tickLower = 0;
                tickUpper = 0;
                emit PositionExited(id, totalReceived0, totalReceived1, fees0, fees1);
                return;
            }
        }
        emit PositionPartiallyExited(id, liqBefore - _positionLiquidity(), totalReceived0, totalReceived1, fees0, fees1);
    }

    /// Idle principal available to cover a recall of `token` (fees excluded).
    function _cover(address token) internal view returns (uint256) {
        if (token == usdg) return unminted1();
        return unminted0(); // address(0) and WETH share the ETH-side bucket
    }

    // ---------- Vault recall (same guard pattern as SimpleStrategy) ----------
    /// Called by a QuiverVault to recall capital. `to` must be the caller vault.
    /// Pays from idle principal first; only a recall the idle balance cannot
    /// cover dips into the position, and then only proportionally (see
    /// _partialExit). Fees are never spent as principal. Reverts instead of
    /// short-paying when the position cannot cover the recall (impermanent
    /// loss realised on exit, or the needed token's mix is depleted).
    function withdraw(address token, uint256 amount, address to) external {
        require(IVaultRegistryL(factory).isVault(msg.sender), "caller not a vault");
        require(to == msg.sender, "recall only to the vault itself");
        if (token == address(0)) {
            uint256 wethBal = IERC20L(weth).balanceOf(address(this));
            uint256 cover = address(this).balance + (wethBal > feeBalance0 ? wethBal - feeBalance0 : 0);
            if (cover < amount && tokenId != 0) _partialExit(token, amount);
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
            if (cover < amount && tokenId != 0) _partialExit(token, amount);
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
