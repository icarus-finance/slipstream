// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;

import {IVotingEscrow} from "contracts/core/interfaces/IVotingEscrow.sol";

contract MockVotingEscrow is IVotingEscrow {
    address private immutable _team;

    constructor(address _t) {
        _team = _t;
    }

    function createLock(uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

    function team() external override returns (address) {
        return _team;
    }

    function getApproved(uint256 tokenId) external override view returns (address operator) {
        return address(0);
    }

    function isApprovedForAll(address owner, address operator) external override view returns (bool) {
        return false;
    }

    function setApprovalForAll(address operator, bool _approved) external override {}

    function transferFrom(address from, address to, uint256 tokenId) external override {}

    function isApprovedOrOwner(address _spender, uint256 _tokenId) external override returns (bool) {}

    function ownerOf(uint256 tokenId) external override view returns (address owner) {
        return address(0);
    }

    function supportsInterface(bytes4 interfaceId) external override view returns (bool) {
        return false;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external override {}

    function safeTransferFrom(address from, address to, uint256 tokenId) external override {}

    function balanceOf(address owner) external override view returns (uint256 balance) {
        return 0;
    }

    function approve(address to, uint256 tokenId) external override {}
}
