// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {ICLFactory} from "contracts/core/interfaces/ICLFactory.sol";
import {IVoter} from "contracts/core/interfaces/IVoter.sol";
import {ICLGauge} from "contracts/gauge/interfaces/ICLGauge.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";

/// @notice Mint an exact-range CL position and stake it for a recipient atomically.
/// @dev Requires a gauge supporting deposit(tokenId, recipient). ERC20 inputs only.
contract LiquidityStakeHelper is ReentrancyGuard {
    using SafeMath for uint256;

    INonfungiblePositionManager public immutable nft;
    ICLFactory public immutable factory;
    IVoter public immutable voter;

    event LiquidityStaked(
        address indexed caller, address indexed recipient, address indexed gauge, uint256 tokenId, uint128 liquidity
    );

    constructor(address _nft) {
        require(_nft != address(0), "ZA");
        nft = INonfungiblePositionManager(_nft);
        address _factory = INonfungiblePositionManager(_nft).factory();
        factory = ICLFactory(_factory);
        voter = ICLFactory(_factory).voter();
    }

    /// @notice Approve desired inputs to this helper first. Refunds go to caller.
    /// @param params Standard mint parameters; recipient receives gauge ownership rights.
    /// @param minLiquidity Minimum liquidity minted (not token amounts).
    /// @dev Existing pool/gauge only: sqrtPriceX96 must be zero. Tokens must be sorted.
    ///      Fee-on-transfer and rebasing tokens are unsupported. One-sided ranges supported.
    function mintAndStake(INonfungiblePositionManager.MintParams calldata params, uint128 minLiquidity)
        external
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        require(params.token0 != address(0) && params.token0 < params.token1, "TOK");
        require(params.recipient != address(0) && params.recipient != address(this), "ZA");
        require(params.sqrtPriceX96 == 0, "NEW");
        require(params.deadline >= block.timestamp, "Transaction too old");
        address pool = factory.getPool(params.token0, params.token1, params.tickSpacing);
        require(pool != address(0), "NP");
        address gauge = voter.gauges(pool);
        require(gauge != address(0) && voter.isAlive(gauge), "GK");
        require(
            address(ICLGauge(gauge).nft()) == address(nft) && address(ICLGauge(gauge).pool()) == pool
                && address(ICLGauge(gauge).voter()) == address(voter),
            "GM"
        );

        _pull(params.token0, params.amount0Desired);
        _pull(params.token1, params.amount1Desired);
        TransferHelper.safeApprove(params.token0, address(nft), params.amount0Desired);
        TransferHelper.safeApprove(params.token1, address(nft), params.amount1Desired);
        INonfungiblePositionManager.MintParams memory mintParams = params;
        mintParams.recipient = address(this);
        (tokenId, liquidity, amount0, amount1) = nft.mint(mintParams);
        require(liquidity > 0 && liquidity >= minLiquidity, "IL");
        TransferHelper.safeApprove(params.token0, address(nft), 0);
        TransferHelper.safeApprove(params.token1, address(nft), 0);
        nft.approve(gauge, tokenId);
        ICLGauge(gauge).deposit(tokenId, params.recipient);
        uint256 refund0 = params.amount0Desired.sub(amount0);
        uint256 refund1 = params.amount1Desired.sub(amount1);
        if (refund0 != 0) TransferHelper.safeTransfer(params.token0, msg.sender, refund0);
        if (refund1 != 0) TransferHelper.safeTransfer(params.token1, msg.sender, refund1);
        emit LiquidityStaked(msg.sender, params.recipient, gauge, tokenId, liquidity);
    }

    function _pull(address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 beforeBalance = IERC20(token).balanceOf(address(this));
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        require(IERC20(token).balanceOf(address(this)).sub(beforeBalance) == amount, "FOT");
    }
}
