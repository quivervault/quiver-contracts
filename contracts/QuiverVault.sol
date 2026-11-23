// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC20 interface (no external dependencies).
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice A strategy that can hold vault capital and return it on request.
///         Real strategies (staking / lending / hedged perps) implement this.
interface IQuiverStrategy {
    function withdraw(address token, uint256 amount, address to) external;
}

/// @title QuiverVault
/// @notice One isolated, non-custodial vault per depositor, as on quiver.finance.
///         Only the vault owner can withdraw principal or claim yield.
///         A protocol executor may deploy a capped share of capital to
///         factory-approved strategies and credit yield — but yield can only
///         be credited against real tokens already funded into the yield
///         reserve, and the executor can never withdraw to itself.
contract QuiverVault {
    // ---------- Risk profiles (0 = Conservative ... 5 = Aggressive) ----------
    uint8 public immutable riskProfile;
    /// Max share of a vault's assets deployable to strategies, in basis points.
    uint16 public immutable maxStrategyBps;

    address public immutable factory;
    address public owner;          // the depositor — sole withdrawal authority
    address public executor;       // protocol strategy executor (no withdrawal rights)
    bool public depositsPaused;

    // ---------- Assets ----------
    /// address(0) represents native ETH.
    mapping(address => bool) public supportedAsset;
    address[] public assetList;

    // ---------- Accounting (per token) ----------
    mapping(address => uint256) public principal;      // total deposited - withdrawn (incl. deployed)
    mapping(address => uint256) public deployedTotal;  // currently inside strategies
    mapping(address => mapping(address => uint256)) public deployedIn; // per strategy
    mapping(address => uint256) public yieldReserve;   // real tokens funded to back yield
    mapping(address => uint256) public yieldAccrued;   // credited, claimable by owner
    mapping(address => uint256) public yieldClaimed;   // lifetime claimed

    // ---------- Claim schedule ----------
    enum ClaimSchedule { Manual, Weekly, Monthly }
    ClaimSchedule public claimSchedule;
    uint256 public lastClaimAt;

    // ---------- Events ----------
    event Deposited(address indexed token, uint256 amount);
    event Withdrawn(address indexed token, uint256 amount);
    event Deployed(address indexed strategy, address indexed token, uint256 amount);
    event Recalled(address indexed strategy, address indexed token, uint256 amount);
    event YieldFunded(address indexed token, uint256 amount);
    event YieldCredited(address indexed token, uint256 amount);
    event YieldClaimed(address indexed token, uint256 amount);
    event ScheduleSet(ClaimSchedule schedule);
    event ExecutorSet(address executor);
    event DepositsPausedSet(bool paused);

    // ---------- Reentrancy guard ----------
    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }
    modifier onlyOwner() { require(msg.sender == owner, "not owner"); _; }
    modifier onlyExecutor() { require(msg.sender == executor, "not executor"); _; }
    modifier onlyFactory() { require(msg.sender == factory, "not factory"); _; }

    constructor(
        address _owner,
        address _executor,
        uint8 _riskProfile,
        uint16 _maxStrategyBps,
        address[] memory _assets
    ) {
        factory = msg.sender;
        owner = _owner;
        executor = _executor;
        riskProfile = _riskProfile;
        maxStrategyBps = _maxStrategyBps;
        lastClaimAt = block.timestamp;
        for (uint256 i = 0; i < _assets.length; i++) {
            _addAsset(_assets[i]);
        }
    }

    function _addAsset(address token) internal {
        if (!supportedAsset[token]) {
            supportedAsset[token] = true;
            assetList.push(token);
        }
    }

    /// Factory can extend the asset list (e.g. a new stablecoin).
    function addAsset(address token) external onlyFactory {
        _addAsset(token);
    }

    function setExecutor(address _executor) external onlyFactory {
        executor = _executor;
        emit ExecutorSet(_executor);
    }

    function setDepositsPaused(bool paused) external onlyFactory {
        depositsPaused = paused;
        emit DepositsPausedSet(paused);
    }

    // ---------- Views ----------
    function freeBalance(address token) public view returns (uint256) {
        uint256 bal = token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
        // Tokens backing credited yield are reserved for the owner, not deployable principal.
        return bal > yieldReserve[token] ? bal - yieldReserve[token] : 0;
    }

    function isClaimDue() public view returns (bool) {
        if (claimSchedule == ClaimSchedule.Weekly) return block.timestamp >= lastClaimAt + 7 days;
        if (claimSchedule == ClaimSchedule.Monthly) return block.timestamp >= lastClaimAt + 30 days;
        return false; // Manual
    }

    // ---------- Deposits ----------
    function depositETH() external payable {
        require(!depositsPaused, "paused");
        require(supportedAsset[address(0)], "ETH not supported");
        require(msg.value > 0, "zero amount");
        principal[address(0)] += msg.value;
        emit Deposited(address(0), msg.value);
    }

    function deposit(address token, uint256 amount) external nonReentrant {
        require(!depositsPaused, "paused");
        require(token != address(0), "use depositETH");
        require(supportedAsset[token], "asset not supported");
        require(amount > 0, "zero amount");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transfer failed");
        principal[token] += amount;
        emit Deposited(token, amount);
    }

    // ---------- Withdrawals (owner only — non-custodial) ----------
    function withdraw(address token, uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "zero amount");
        uint256 withdrawable = principal[token] - deployedTotal[token];
        uint256 free = freeBalance(token);
        uint256 available = withdrawable < free ? withdrawable : free;
        require(amount <= available, "exceeds free principal (rest is deployed)");
        principal[token] -= amount;
        _send(token, owner, amount);
        emit Withdrawn(token, amount);
    }

    // ---------- Strategy deployment (executor only, capped, approved targets) ----------
    /// The factory keeps the approved-strategy registry; the vault asks it.
    function _isApprovedStrategy(address s) internal view returns (bool) {
        (bool ok, bytes memory data) = factory.staticcall(
            abi.encodeWithSignature("approvedStrategy(address)", s)
        );
        return ok && data.length >= 32 && abi.decode(data, (bool));
    }

    function deployToStrategy(address strategy, address token, uint256 amount)
        external onlyExecutor nonReentrant
    {
        require(amount > 0, "zero amount");
        require(_isApprovedStrategy(strategy), "strategy not approved");
        uint256 newDeployed = deployedTotal[token] + amount;
        require(newDeployed * 10000 <= principal[token] * maxStrategyBps, "profile cap exceeded");
        require(amount <= freeBalance(token), "insufficient idle balance");
        deployedTotal[token] = newDeployed;
        deployedIn[strategy][token] += amount;
        _send(token, strategy, amount);
        emit Deployed(strategy, token, amount);
    }

    function recallFromStrategy(address strategy, address token, uint256 amount)
        external onlyExecutor nonReentrant
    {
        require(amount > 0, "zero amount");
        require(deployedIn[strategy][token] >= amount, "recall exceeds deployed");
        deployedIn[strategy][token] -= amount;
        deployedTotal[token] -= amount;
        IQuiverStrategy(strategy).withdraw(token, amount, address(this));
        emit Recalled(strategy, token, amount);
    }

    // ---------- Yield (backed by real funded tokens — never minted from thin air) ----------
    /// Executor (or anyone) funds the reserve with actual tokens from strategy returns.
    function fundYield(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "zero amount");
        if (token == address(0)) revert("fund ETH yield via fundYieldETH");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "transfer failed");
        yieldReserve[token] += amount;
        emit YieldFunded(token, amount);
    }

    function fundYieldETH() external payable {
        require(msg.value > 0, "zero amount");
        yieldReserve[address(0)] += msg.value;
        emit YieldFunded(address(0), msg.value);
    }

    /// Executor credits accrued yield to the owner, capped by the funded reserve.
    function creditYield(address token, uint256 amount) external onlyExecutor {
        require(amount > 0, "zero amount");
        require(amount <= yieldReserve[token] - _reservedForAccrued(token), "exceeds unallocated reserve");
        yieldAccrued[token] += amount;
        emit YieldCredited(token, amount);
    }

    function _reservedForAccrued(address token) internal view returns (uint256) {
        return yieldAccrued[token];
    }

    function claimYield(address token) external onlyOwner nonReentrant {
        if (claimSchedule != ClaimSchedule.Manual) {
            require(isClaimDue(), "scheduled claim not due yet");
        }
        uint256 amount = yieldAccrued[token];
        require(amount > 0, "nothing to claim");
        require(amount <= yieldReserve[token], "reserve shortfall");
        yieldAccrued[token] = 0;
        yieldReserve[token] -= amount;
        yieldClaimed[token] += amount;
        lastClaimAt = block.timestamp;
        _send(token, owner, amount);
        emit YieldClaimed(token, amount);
    }

    function setClaimSchedule(ClaimSchedule schedule) external onlyOwner {
        claimSchedule = schedule;
        lastClaimAt = block.timestamp;
        emit ScheduleSet(schedule);
    }

    // ---------- Internal send ----------
    function _send(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            (bool ok, ) = payable(to).call{value: amount}("");
            require(ok, "ETH send failed");
        } else {
            require(IERC20(token).transfer(to, amount), "token send failed");
        }
    }

    receive() external payable {}
}
