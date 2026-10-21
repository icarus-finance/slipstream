pragma solidity ^0.7.6;
pragma abicoder v2;

import "./CLGaugeFactory.t.sol";

contract SetWhitelistedTest is CLGaugeFactoryTest {
    event WhitelistChanged(address indexed account, bool allowed);

    function test_InitiallyUnwhitelistedAndOwnerRetainedAfterNFTSetup() public {
        assertEq(gaugeFactory.owner(), users.owner);
        assertFalse(gaugeFactory.isWhitelisted(users.alice));
        vm.prank(users.owner);
        gaugeFactory.setWhitelisted(users.alice, true);
        assertTrue(gaugeFactory.isWhitelisted(users.alice));
    }

    function test_OwnerCanWhitelistAndRevokeWithEvents() public {
        vm.startPrank(users.owner);
        vm.expectEmit(true, false, false, true, address(gaugeFactory));
        emit WhitelistChanged(users.alice, true);
        gaugeFactory.setWhitelisted(users.alice, true);
        assertTrue(gaugeFactory.isWhitelisted(users.alice));
        vm.expectEmit(true, false, false, true, address(gaugeFactory));
        emit WhitelistChanged(users.alice, false);
        gaugeFactory.setWhitelisted(users.alice, false);
        assertFalse(gaugeFactory.isWhitelisted(users.alice));
    }

    function test_CurrentTeamCanWhitelistAndRevoke() public {
        vm.mockCall(address(escrow), abi.encodeWithSignature("team()"), abi.encode(users.bob));
        vm.startPrank(users.bob);
        gaugeFactory.setWhitelisted(users.alice, true);
        assertTrue(gaugeFactory.isWhitelisted(users.alice));
        gaugeFactory.setWhitelisted(users.alice, false);
        assertFalse(gaugeFactory.isWhitelisted(users.alice));
    }

    function test_RevertIf_CallerNotOwnerOrTeam() public {
        vm.prank(users.alice);
        vm.expectRevert(bytes("NA"));
        gaugeFactory.setWhitelisted(users.charlie, true);
        assertFalse(gaugeFactory.isWhitelisted(users.charlie));
    }

    function test_RevertIf_ZeroAccount() public {
        vm.prank(users.owner);
        vm.expectRevert(bytes("ZA"));
        gaugeFactory.setWhitelisted(address(0), true);
    }

    function test_FormerTeamLosesAuthorization() public {
        vm.mockCall(address(escrow), abi.encodeWithSignature("team()"), abi.encode(users.bob));
        vm.prank(users.bob);
        gaugeFactory.setWhitelisted(users.alice, true);
        vm.mockCall(address(escrow), abi.encodeWithSignature("team()"), abi.encode(users.charlie));
        vm.prank(users.bob);
        vm.expectRevert(bytes("NA"));
        gaugeFactory.setWhitelisted(users.alice, false);
        vm.prank(users.charlie);
        gaugeFactory.setWhitelisted(users.alice, false);
        assertFalse(gaugeFactory.isWhitelisted(users.alice));
    }
}
