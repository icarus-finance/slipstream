// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@nomad-xyz/src/ExcessivelySafeCall.sol";
import "./interfaces/ICLPrivateFactory.sol";
import "./interfaces/fees/IFeeModule.sol";
import "./interfaces/IVoter.sol";
import "./interfaces/IFactoryRegistry.sol";
import "./CLPrivatePool.sol";
import "./fees/PrivateSwapFeeModule.sol";

/// @title Permissioned CL factory
/// @notice Deploys CL pools and manages ownership and control over pool protocol fees
contract CLPrivateFactory is ICLPrivateFactory {
    using ExcessivelySafeCall for address;

    /// @inheritdoc ICLFactory
    IVoter public immutable override voter;
    /// @inheritdoc ICLFactory
    address public immutable override poolImplementation;
    /// @inheritdoc ICLFactory
    IFactoryRegistry public immutable override factoryRegistry;
    /// @inheritdoc ICLFactory
    address public override nft;
    /// @inheritdoc ICLFactory
    address public override gaugeFactory;
    /// @inheritdoc ICLFactory
    address public override gaugeImplementation;
    /// @inheritdoc ICLFactory
    address public override owner;
    /// @inheritdoc ICLFactory
    address public override swapFeeManager;
    /// @inheritdoc ICLFactory
    address public override swapFeeModule;
    /// @inheritdoc ICLFactory
    address public override unstakedFeeManager;
    /// @inheritdoc ICLFactory
    address public override unstakedFeeModule;
    /// @inheritdoc ICLFactory
    uint24 public override defaultUnstakedFee;
    /// @inheritdoc ICLFactory
    mapping(int24 => uint24) public override tickSpacingToFee;
    /// @dev Used in VotingEscrow to determine if a contract is a valid pool
    mapping(address => bool) private _isPool;
    /// @inheritdoc ICLFactory
    address[] public override allPools;

    /// @inheritdoc ICLPrivateFactory
    mapping(address => bool) public override isWhitelisted;

    modifier onlyWhitelisted() {
        require(isWhitelisted[msg.sender], "NW");
        _;
    }

    int24[] private _tickSpacings;
    mapping(address => mapping(address => mapping(int24 => address))) internal _getPool;

    constructor(address _voter, address _poolImplementation, address _gaugeFactory, address _gaugeImplementation) {
        owner = msg.sender;
        swapFeeManager = msg.sender;
        unstakedFeeManager = msg.sender;
        voter = IVoter(_voter);
        factoryRegistry = IVoter(_voter).factoryRegistry();
        gaugeFactory = _gaugeFactory;
        gaugeImplementation = _gaugeImplementation;
        poolImplementation = _poolImplementation;
        defaultUnstakedFee = 100_000;
        emit OwnerChanged(address(0), msg.sender);
        emit SwapFeeManagerChanged(address(0), msg.sender);
        emit UnstakedFeeManagerChanged(address(0), msg.sender);
        emit DefaultUnstakedFeeChanged(0, 100_000);

        swapFeeModule = address(new PrivateSwapFeeModule(address(this)));
        emit SwapFeeModuleChanged(address(0), swapFeeModule);

        _enableTickSpacing(1, 100);
        _enableTickSpacing(50, 500);
        _enableTickSpacing(100, 500);
        _enableTickSpacing(200, 3_000);
        _enableTickSpacing(2_000, 10_000);
    }

    /// @inheritdoc ICLFactory
    function createPool(address tokenA, address tokenB, uint24 tickSpacing) external override returns (address) {
        return createPool({
            tokenA: tokenA,
            tokenB: tokenB,
            tickSpacing: int24(tickSpacing),
            sqrtPriceX96: 79228162514264337593543950336 // encodePriceSqrt(1, 1)
        });
    }

    /// @inheritdoc ICLFactory
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        public
        override
        onlyWhitelisted
        returns (address pool)
    {
        require(tokenA != tokenB);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0));
        require(tickSpacingToFee[tickSpacing] != 0);
        require(_getPool[token0][token1][tickSpacing] == address(0));
        bytes32 _salt = keccak256(abi.encode(token0, token1, tickSpacing));
        pool = Clones.cloneDeterministic({master: poolImplementation, salt: _salt});
        address gauge =
            Clones.predictDeterministicAddress({master: gaugeImplementation, salt: _salt, deployer: gaugeFactory});
        CLPrivatePool(pool)
            .initialize({
            _factory: address(this),
            _token0: token0,
            _token1: token1,
            _tickSpacing: tickSpacing,
            _gauge: gauge,
            _nft: nft,
            _sqrtPriceX96: sqrtPriceX96
        });
        allPools.push(pool);
        _isPool[pool] = true;
        _getPool[token0][token1][tickSpacing] = pool;
        // populate mapping in the reverse direction, deliberate choice to avoid the cost of comparing addresses
        _getPool[token1][token0][tickSpacing] = pool;
        emit PoolCreated(token0, token1, tickSpacing, pool);
    }

    /// @inheritdoc ICLPrivateFactory
    function setWhitelist(address account, bool allowed) external override {
        require(msg.sender == owner);
        require(account != address(0));
        isWhitelisted[account] = allowed;
        emit WhitelistUpdated(account, allowed);
    }

    /// @inheritdoc ICLFactory
    function setOwner(address _owner) external override {
        address cachedOwner = owner;
        require(msg.sender == cachedOwner);
        require(_owner != address(0));
        emit OwnerChanged(cachedOwner, _owner);
        owner = _owner;
    }

    /// @inheritdoc ICLFactory
    function setSwapFeeManager(address _swapFeeManager) external override {
        address cachedSwapFeeManager = swapFeeManager;
        require(msg.sender == cachedSwapFeeManager);
        require(_swapFeeManager != address(0));
        swapFeeManager = _swapFeeManager;
        emit SwapFeeManagerChanged(cachedSwapFeeManager, _swapFeeManager);
    }

    /// @inheritdoc ICLFactory
    function setUnstakedFeeManager(address _unstakedFeeManager) external override {
        address cachedUnstakedFeeManager = unstakedFeeManager;
        require(msg.sender == cachedUnstakedFeeManager);
        require(_unstakedFeeManager != address(0));
        unstakedFeeManager = _unstakedFeeManager;
        emit UnstakedFeeManagerChanged(cachedUnstakedFeeManager, _unstakedFeeManager);
    }

    /// @inheritdoc ICLFactory
    function setSwapFeeModule(address _swapFeeModule) external override {
        require(msg.sender == swapFeeManager);
        require(_swapFeeModule != address(0));
        address oldFeeModule = swapFeeModule;
        swapFeeModule = _swapFeeModule;
        emit SwapFeeModuleChanged(oldFeeModule, _swapFeeModule);
    }

    /// @inheritdoc ICLFactory
    function setUnstakedFeeModule(address _unstakedFeeModule) external override {
        require(msg.sender == unstakedFeeManager);
        require(_unstakedFeeModule != address(0));
        address oldFeeModule = unstakedFeeModule;
        unstakedFeeModule = _unstakedFeeModule;
        emit UnstakedFeeModuleChanged(oldFeeModule, _unstakedFeeModule);
    }

    /// @inheritdoc ICLFactory
    function setDefaultUnstakedFee(uint24 _defaultUnstakedFee) external override {
        require(msg.sender == unstakedFeeManager);
        require(_defaultUnstakedFee <= 500_000);
        uint24 oldUnstakedFee = defaultUnstakedFee;
        defaultUnstakedFee = _defaultUnstakedFee;
        emit DefaultUnstakedFeeChanged(oldUnstakedFee, _defaultUnstakedFee);
    }

    /// @inheritdoc ICLFactory
    function getSwapFee(address pool) external view override returns (uint24) {
        if (swapFeeModule != address(0)) {
            (bool success, bytes memory data) = swapFeeModule.excessivelySafeStaticCall(
                500_000, 32, abi.encodeWithSelector(IFeeModule.getFee.selector, pool)
            );
            if (success) {
                uint24 fee = abi.decode(data, (uint24));
                if (fee <= 100_000) {
                    return fee;
                }
            }
        }
        return tickSpacingToFee[CLPrivatePool(pool).tickSpacing()];
    }

    /// @inheritdoc ICLFactory
    function getUnstakedFee(address pool) external view override returns (uint24) {
        address gauge = voter.gauges(pool);
        // Gagues that do not exist yet should still acrrue Unstaked Fees.
        // Only when gauge exists but was "killed" it should not keep receiving Unstaked Fees.
        if (gauge != address(0) && !voter.isAlive(gauge)) {
            return 0;
        }
        if (unstakedFeeModule != address(0)) {
            (bool success, bytes memory data) = unstakedFeeModule.excessivelySafeStaticCall(
                500_000, 32, abi.encodeWithSelector(IFeeModule.getFee.selector, pool)
            );
            if (success) {
                uint24 fee = abi.decode(data, (uint24));
                if (fee <= 1_000_000) {
                    return fee;
                }
            }
        }
        return defaultUnstakedFee;
    }

    /// @inheritdoc ICLFactory
    function enableTickSpacing(int24 tickSpacing, uint24 fee) public override {
        require(msg.sender == owner);
        _enableTickSpacing(tickSpacing, fee);
    }

    function _enableTickSpacing(int24 tickSpacing, uint24 fee) internal {
        require(fee > 0 && fee <= 100_000);
        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(tickSpacing > 0 && tickSpacing < 16384);
        require(tickSpacingToFee[tickSpacing] == 0);
        tickSpacingToFee[tickSpacing] = fee;
        _tickSpacings.push(tickSpacing);
        emit TickSpacingEnabled(tickSpacing, fee);
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view override returns (address) {
        return _getPool[tokenA][tokenB][tickSpacing];
    }

    function getPool(address tokenA, address tokenB, uint24 tickSpacing) external view override returns (address) {
        return _getPool[tokenA][tokenB][int24(tickSpacing)];
    }

    /// @inheritdoc ICLFactory
    function tickSpacings() external view override returns (int24[] memory) {
        return _tickSpacings;
    }

    /// @inheritdoc ICLFactory
    function allPoolsLength() external view override returns (uint256) {
        return allPools.length;
    }

    /// @inheritdoc ICLFactory
    function isPair(address pool) external view override returns (bool) {
        return _isPool[pool];
    }

    /// @inheritdoc ICLFactory
    function isPool(address pool) external view override returns (bool) {
        return _isPool[pool];
    }

    /// @inheritdoc ICLFactory
    function setNonfungiblePositionManager(address _nft) external override {
        require(nft == address(0), "AI");
        require(owner == msg.sender, "NA");
        require(_nft != address(0));
        nft = _nft;
    }
}
