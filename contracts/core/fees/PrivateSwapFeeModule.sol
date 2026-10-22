// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import "../interfaces/fees/ICustomFeeModule.sol";

/// @notice Per-pool swap fees for private pools, defaulting to zero.
contract PrivateSwapFeeModule is ICustomFeeModule {
    /// @inheritdoc IFeeModule
    ICLFactory public immutable override factory;
    /// @inheritdoc ICustomFeeModule
    mapping(address => uint24) public override customFee;

    uint256 public constant MAX_FEE = 30_000; // 3%
    // Retained for compatibility with CustomSwapFeeModule integrations; both zero and 420 mean zero fees.
    uint256 public constant ZERO_FEE_INDICATOR = 420;

    constructor(address _factory) {
        factory = ICLFactory(_factory);
    }

    /// @inheritdoc ICustomFeeModule
    function setCustomFee(address pool, uint24 fee) external override {
        require(msg.sender == factory.swapFeeManager());
        require(fee <= MAX_FEE || fee == ZERO_FEE_INDICATOR);
        require(factory.isPool(pool));

        customFee[pool] = fee;
        emit SetCustomFee(pool, fee);
    }

    /// @inheritdoc IFeeModule
    function getFee(address pool) external view override returns (uint24) {
        uint24 fee = customFee[pool];
        return fee == ZERO_FEE_INDICATOR ? 0 : fee;
    }
}
