// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FUDeploy, Common} from "./Deploy.t.sol";
import {ERC20Base} from "../src/core/ERC20Base.sol";
import {Settings} from "../src/core/Settings.sol";

import {Test} from "@forge-std/Test.sol";
import {VmSafe} from "@forge-std/Vm.sol";
import {StdCheats} from "@forge-std/StdCheats.sol";

import {console} from "@forge-std/console.sol";

address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

function saturatingAdd(uint256 x, uint256 y) pure returns (uint256 r) {
    assembly ("memory-safe") {
        r := add(x, y)
        r := or(r, sub(0x00, lt(r, y)))
    }
}

contract FUApprovalsTest is FUDeploy, Test {
    function setUp() public override {
        super.setUp();
        actors.push(pair);
        isActor[pair] = true;
    }

    function _transferFromShouldFail(address from, address to, uint256 amount, uint256 balance, uint256 allowance)
        internal
        view
        returns (bool)
    {
        return from == DEAD || to == DEAD || to == address(fu) || to == from || amount > balance
            || uint160(to) / Settings.ADDRESS_DIVISOR == 0 || amount > allowance;
    }

    function testTemporaryApprove(uint256 actorIndex, address spender, uint256 amount, bool boundSpender, bool boundAmount) external {
        address actor = getActor(actorIndex);
        if (boundAmount) {
            amount = bound(amount, 0, type(uint256).max);
        }
        console.log("amount", amount);
        console.log("spender", spender);

        if (boundSpender) {
            spender = getActor(spender);
        } else {
            maybeCreateActor(spender);
        }

        uint256 beforePersistentAllowance = uint256(
            vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8)))))
        ); //allowance mapping offset is 8, see https://github.com/duncancmt/fu/blob/c64c7b7fbafd1ea362c056e4fecef44ed4ac5688/src/FUStorage.sol#L16-L26

        vm.recordLogs();
        vm.startStateDiffRecording();
        prank(actor);

        (bool success,) = callOptionalReturn(abi.encodeCall(fu.temporaryApprove, (spender, amount)));

        VmSafe.AccountAccess[] memory accountAccesses = vm.stopAndReturnStateDiff();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        uint256 afterPersistentAllowance = uint256(
            vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8)))))
        );

        if (spender == PERMIT2) {
            assertEq(beforePersistentAllowance, afterPersistentAllowance, "permit2 allowance should already be maximum");
        }
    }

    function testTransferFrom(address actorIndex, address to, uint256 amount, bool boundTo, bool boundAmount) external {
        address actor = getActor(actorIndex);
        address spender = msg.sender;

        if (boundAmount) {
            amount = bound(amount, 0, fu.balanceOf(actor));
        } else {
            console.log("amount", amount);
        }
        if (actor == pair) {
            assume(amount < fu.balanceOf(actor));
        }
        if (boundTo) {
            to = getActor(to);
        } else {
            maybeCreateActor(to);
        }

        uint256 beforePersistentAllowance = uint256(vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8))))));
        uint256 beforeTransientAllowance = ~beforePersistentAllowance == 0 ? 0 : fu.allowance(actor, spender) - beforePersistentAllowance; // TODO: we probably need to get more advanced here to actually get the transient allowance
        uint256 beforeBalance = fu.balanceOf(actor);
        uint256 beforeBalanceTo = fu.balanceOf(to);

        // TODO: we don't need to record logs. we can get by with just `expectEmit`
        vm.recordLogs();
        vm.startStateDiffRecording();
        prank(actor);

        (bool success,) = callOptionalReturn(abi.encodeCall(ERC20Base.transferFrom, (actor, to, amount)));
        assertEq(success, !_transferFromShouldFail(actor, to, amount, beforeBalance, saturatingAdd(beforePersistentAllowance, beforeTransientAllowance)), "unexpected failure");

        if (!success) {
            return;
        }

        VmSafe.AccountAccess[] memory accountAccesses = vm.stopAndReturnStateDiff();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        //TODO: stuff with these logs

        saveActor(actor);
        saveActor(to);

        uint256 afterPersistentAllowance = uint256(vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8))))));
        uint256 afterBalance = fu.balanceOf(actor);
        uint256 afterBalanceTo = fu.balanceOf(to);

        assertEq((beforeBalance - afterBalance), (beforePersistentAllowance - afterPersistentAllowance), "change in balances and allowances don't match");
        assertEq((beforeBalance - afterBalance), (afterBalanceTo - beforeBalanceTo), "changes in `from` and `to` balances don't match");
    }

    function testBurnFrom(address actorIndex, uint256 amount, bool boundAmount) external {
        address actor = getActor(actorIndex);
        address spender = msg.sender;

        if (boundAmount) {
            amount = bound(amount, 0, fu.balanceOf(actor));
        } else {
            console.log("amount", amount);
        }
        if (actor == pair) {
            assume(amount < fu.balanceOf(actor));
        }

        uint256 beforePersistentAllowance = uint256(vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8))))));
        console.log("beforePersistentAllowance:", beforePersistentAllowance);
        uint256 beforeBalance = fu.balanceOf(actor);

        vm.recordLogs();
        vm.startStateDiffRecording();
        prank(actor);

        (bool success, bytes memory returndata) = callOptionalReturn(abi.encodeCall(ERC20Base.burnFrom, (actor, amount)));

        VmSafe.AccountAccess[] memory accountAccesses = vm.stopAndReturnStateDiff();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        uint256 afterPersistentAllowance = uint256(vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8))))));
        uint256 afterBalance = fu.balanceOf(actor);

        assertEq((beforeBalance - afterBalance), (beforePersistentAllowance - afterPersistentAllowance), "change in balances and allowances don't match");
    }

        function testDeliverFrom(address actorIndex, uint256 amount, bool boundAmount) external {
        address actor = getActor(actorIndex);
        address spender = msg.sender;

        if (boundAmount) {
            amount = bound(amount, 0, fu.balanceOf(actor));
        } else {
            console.log("amount", amount);
        }
        if (actor == pair) {
            assume(amount < fu.balanceOf(actor));
        }

        uint256 beforePersistentAllowance = uint256(vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8))))));
        uint256 beforeBalance = fu.balanceOf(actor);

        vm.recordLogs();
        vm.startStateDiffRecording();
        prank(actor);

        (bool success,) = callOptionalReturn(abi.encodeCall(ERC20Base.deliverFrom, (actor, amount)));

        VmSafe.AccountAccess[] memory accountAccesses = vm.stopAndReturnStateDiff();
        VmSafe.Log[] memory logs = vm.getRecordedLogs();

        uint256 afterPersistentAllowance = uint256(vm.load(address(fu), keccak256(abi.encode(spender, keccak256(abi.encode(actor, uint256(BASE_SLOT) + 8))))));
        uint256 afterBalance = fu.balanceOf(actor);

        assertEq((beforeBalance - afterBalance), (beforePersistentAllowance - afterPersistentAllowance), "change in balances and allowances don't match");
    }

    // Solidity inheritance is dumb
    function deal(address who, uint256 value) internal virtual override(Common, StdCheats) {
        return super.deal(who, value);
    }
}
