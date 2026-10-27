// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

interface ICLGaugeFactory {
    event WhitelistChanged(address indexed account, bool allowed);

    /// @notice Deployment owner, retained after position manager configuration.
    function owner() external view returns (address);

    /// @notice Trusted callers allowed to deposit NFTs for other accounts.
    function isWhitelisted(address account) external view returns (bool);

    /// @notice Allow or revoke a trusted third-party depositor.
    /// @dev Callable by the deployment owner or current VotingEscrow team.
    ///      Trusted callers must enforce recipient authorization themselves.
    function setWhitelisted(address account, bool allowed) external;

    /// @notice Address of the voter contract
    function voter() external view returns (address);

    /// @notice Address of the gauge implementation contract
    function implementation() external view returns (address);

    /// @notice Address of the NonfungiblePositionManager used to create nfts that gauges will accept
    function nft() external view returns (address);

    /// @notice Set Nonfungible Position Manager
    /// @dev Callable once only on initialize
    /// @param _nft The nonfungible position manager that will manage positions for this Factory
    function setNonfungiblePositionManager(address _nft) external;

    /// @notice Called by the voter contract via factory.createPool
    /// @param _forwarder The address of the forwarder contract
    /// @param _pool The address of the pool
    /// @param _feesVotingReward The address of the feesVotingReward contract
    /// @param _rewardToken The address of the reward token
    /// @param _isPool Whether the attached pool is a real pool or not
    /// @return The address of the created gauge
    function createGauge(
        address _forwarder,
        address _pool,
        address _feesVotingReward,
        address _rewardToken,
        bool _isPool
    ) external returns (address);
}
