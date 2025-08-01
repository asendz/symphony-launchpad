// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/FERC20.sol";

contract FERC20Test is Test {
    FERC20 token;
    uint256 initialSupply = 10_000;
    uint256 maxTxPercent = 5; // 5%
    uint256 maxTxAmount;
    address owner;
    address alice = address(0xA1);
    address bob   = address(0xB2);
    address taxReceiver = address(0xBEEF);

    function setUp() public {
        owner = address(this);
        token = new FERC20("Test","TST", initialSupply, maxTxPercent);
        // compute maxTxAmount = initialSupply * maxTxPercent / 100
        maxTxAmount = initialSupply * maxTxPercent / 100;
    }

    /// @notice Upon deployment, totalSupply is minted to owner and locked state
    function testInitialSupplyAndLock() public {
        assertEq(token.totalSupply(), initialSupply);
        assertEq(token.balanceOf(owner), initialSupply);
        assertTrue(token.isLocked(), "Token should start locked");
    }

    /// @notice Transfers revert when locked unless whitelisted
    function testTransferRevertsWhenLocked() public {
        // owner to alice should revert because neither whitelisted
        vm.expectRevert("Token is locked");
        token.transfer(alice, 100);
    }

    /// @notice addToWhitelist allows owner to whitelist and bypass lock
    function testWhitelistBypassesLock() public {
        token.addToWhitelist(alice);
        // now transfer should succeed
        token.transfer(alice, 200);
        assertEq(token.balanceOf(alice), 200);
    }

    /// @notice unlock() removes lock so transfers work
    function testUnlockAllowsTransfers() public {
        token.unlock();
        assertFalse(token.isLocked(), "Token should be unlocked");
        token.transfer(alice, 300);
        assertEq(token.balanceOf(alice), 300);
    }

    /// @notice lock() reverts if already locked or unlock then lock works
    function testLockBehavior() public {
        // initial locked
        vm.expectRevert("Token is already locked");
        token.lock();
        // unlock then lock
        token.unlock();
        token.lock();
        assertTrue(token.isLocked(), "Token should be locked again");
    }

    /// @notice Excluded addresses skip maxTx; others must respect maxTx amount
    function testMaxTxEnforced() public {
        token.unlock();
        // Owner is excludedFromMaxTx so can transfer above maxTx
        token.transfer(alice, maxTxAmount + 1);
        // alice tries to transfer above maxTxAmount and should revert
        vm.prank(alice);
        vm.expectRevert("Exceeds MaxTx");
        token.transfer(bob, maxTxAmount + 1);
    }

    /// @notice Tax settings apply correct fee when includedInTax
    function testTaxedTransfer() public {
        token.unlock();

        // fund alice up to the maxTxAmount
        token.transfer(alice, maxTxAmount);

        // set taxReceiver and 10% tax (1000 bps)
        token.updateTaxSettings(taxReceiver, 1000);
        // include alice in tax
        token.setIsIncludedInTax(alice);

        // alice transfers full maxTxAmount
        vm.prank(alice);
        token.transfer(bob, maxTxAmount);
        // 10% tax = maxTxAmount / 10, bob gets the rest
        uint256 expectedTax = maxTxAmount / 10;          // 50 if maxTxAmount is 500
        uint256 expectedReceived = maxTxAmount - expectedTax; // 450
        assertEq(token.balanceOf(taxReceiver), expectedTax);
        assertEq(token.balanceOf(bob), expectedReceived);
    }

    /// @notice forceApprove sets allowance correctly
    function testForceApprove() public {
        token.unlock();
        token.forceApprove(bob, 1234);
        assertEq(token.allowance(owner, bob), 1234);
    }

        /// @notice transferFrom enforces maxTx + tax when using allowances
    function testTransferFromWithTaxAndMaxTx() public {
        token.unlock();
        // fund Alice and exempt owner for that initial funding
        token.transfer(alice, maxTxAmount);
        // Alice approves Bob for maxTxAmount
        vm.prank(alice);
        token.approve(bob, maxTxAmount);
        // set 10% tax and include Alice
        token.updateTaxSettings(taxReceiver, 1000);
        token.setIsIncludedInTax(alice);
        // Bob does transferFrom(alice -> Charlie)
        address charlie = address(0xC3);
        vm.prank(bob);
        token.transferFrom(alice, charlie, maxTxAmount);
        // 10% tax = maxTxAmount/10
        uint256 tax = maxTxAmount / 10;
        assertEq(token.balanceOf(taxReceiver), tax);
        assertEq(token.balanceOf(charlie), maxTxAmount - tax);
    }

    /// @notice Transfers to taxReceiver should bypass tax
    function testNoTaxWhenSendingToTaxReceiver() public {
        token.unlock();
        // fund Alice
        token.transfer(alice, 500);
        // set tax and include Alice
        token.updateTaxSettings(taxReceiver, 1000);
        token.setIsIncludedInTax(alice);
        // Alice sends 500 to taxReceiver
        vm.prank(alice);
        token.transfer(taxReceiver, 500);
        // No tax taken: taxReceiver gets full 500
        assertEq(token.balanceOf(taxReceiver), 500);
    }

    /// @notice Transfers from taxReceiver should bypass tax
    function testNoTaxWhenSendingFromTaxReceiver() public {
        token.unlock();
        // give some to taxReceiver
        token.transfer(taxReceiver, 400);
        // set tax and include Bob
        token.updateTaxSettings(taxReceiver, 1000);
        token.setIsIncludedInTax(bob);
        // taxReceiver sends to Bob
        vm.prank(taxReceiver);
        token.transfer(bob, 400);
        // No tax: Bob gets full 400
        assertEq(token.balanceOf(bob), 400);
    }

    /// @notice Transfers where only recipient is taxed still incur fee
    function testTaxWhenRecipientOnly() public {
        token.unlock();
        // fund Alice up to the maxTxAmount
        token.transfer(alice, maxTxAmount);
        // set 5% tax and include only the recipient in tax
        token.updateTaxSettings(taxReceiver, 500);
        token.setIsIncludedInTax(bob);

        uint256 amt = maxTxAmount; // stay within the cap
        // Alice (not taxed) sends amt to Bob (taxed)
        vm.prank(alice);
        token.transfer(bob, amt);

        uint256 expectedTax = (amt * 5) / 100;  // 5% of amt
        uint256 expectedReceive = amt - expectedTax;
        assertEq(token.balanceOf(taxReceiver), expectedTax);
        assertEq(token.balanceOf(bob), expectedReceive);
    }

    /// @notice Dynamic maxTx updates are applied immediately
    function testDynamicMaxTxRecalculation() public {
        token.unlock();
        // initial maxTxAmount = 500
        assertEq(maxTxAmount, initialSupply * maxTxPercent / 100);
        // change maxTx to 1%
        token.updateMaxTx(1);
        uint256 newMax = initialSupply * 1 / 100;
        // owner can still send > newMax (excluded), but Alice cannot
        token.transfer(alice, newMax + 50);
        vm.prank(alice);
        vm.expectRevert("Exceeds MaxTx");
        token.transfer(bob, newMax + 1);
    }

    /// @notice updateTaxSettings bounds: zero receiver or bps>1000 revert
    function testUpdateTaxSettingsBounds() public {
        vm.expectRevert("ERC20: zero tax address");
        token.updateTaxSettings(address(0), 100);
        vm.expectRevert("ERC20: tax too high");
        token.updateTaxSettings(taxReceiver, 2000);
    }

    /// @notice Burning tokens reduces totalSupply and shrinks maxTxAmount accordingly
    function testBurnReducesMaxTx() public {
        token.unlock();
        // owner burns 50% of supply
        uint256 half = initialSupply / 2;
        token.burn(half);
        uint256 newSupply = initialSupply - half;
        uint256 expectedMax = newSupply * maxTxPercent / 100;
        // Try to send more than expectedMax from owner (excluded ok) to Alice
        token.transfer(alice, expectedMax + 1);
        // Alice now has expectedMax+1 but maxTx should block her:
        vm.prank(alice);
        vm.expectRevert("Exceeds MaxTx");
        token.transfer(bob, expectedMax + 1);
    }

        /// @notice Zero-value `transfer`, `transferFrom`, and `burn` all succeed without side-effects
    function testZeroValueOps() public {
        token.unlock();
        uint256 beforeOwner = token.balanceOf(owner);
        // zero transfer
        token.transfer(alice, 0);
        assertEq(token.balanceOf(owner), beforeOwner);
        // approve and zero transferFrom
        token.approve(alice, 100);
        vm.prank(alice);
        token.transferFrom(owner, bob, 0);
        assertEq(token.balanceOf(owner), beforeOwner);
        // zero burn
        token.burn(0);
        assertEq(token.totalSupply(), initialSupply);
    }

    /// @notice Edge tax settings: 0 bps (no tax) and 1000 bps (100% tax)
    function testExtremeTaxSettings() public {
        token.unlock();
        // fund Alice
        token.transfer(alice, 100);
        // No tax (0 bps)
        token.updateTaxSettings(taxReceiver, 0);
        token.setIsIncludedInTax(alice);
        vm.prank(alice);
        token.transfer(bob, 100);
        assertEq(token.balanceOf(taxReceiver), 0);
        assertEq(token.balanceOf(bob), 100);

        // Full tax (1000 bps = 10%)
        token.transfer(alice, 100); // refuel Alice
        token.updateTaxSettings(taxReceiver, 1000);
        token.setIsIncludedInTax(alice);
        vm.prank(alice);
        token.transfer(bob, 100);
        // Bob increases his balance by 90, vault gets  10
        assertEq(token.balanceOf(taxReceiver), 10);
        assertEq(token.balanceOf(bob), 190);
    }

    /// @notice Lock logic with partial whitelist: sender vs. recipient vs. both
    function testPartialWhitelistScenarios() public {
        // Start locked
        assertTrue(token.isLocked());
        // Fund Alice and Bob by unlocking briefly
        token.unlock();
        token.transfer(alice, 50);
        token.transfer(bob, 50);
        token.lock();

        // 1) Only sender whitelisted
        token.addToWhitelist(alice);
        vm.prank(alice);
        token.transfer(bob, 10);   // OK
        vm.prank(bob);
        token.transfer(alice, 5);  // OK (recipient whitelisted)

        // 2) Only recipient whitelisted
        token = new FERC20("X","X", initialSupply, maxTxPercent);
        token.unlock();
        token.transfer(alice, 50);
        token.transfer(bob, 50);
        token.lock();
        token.addToWhitelist(bob);

        vm.prank(alice);
        token.transfer(bob, 10);   // OK (recipient whitelisted)
        vm.prank(bob);
        token.transfer(alice, 5);  // OK (sender whitelisted)

        // 3) Both whitelisted
        token = new FERC20("X","X", initialSupply, maxTxPercent);
        token.unlock();
        token.transfer(alice, 50);
        token.transfer(bob, 50);
        token.lock();
        token.addToWhitelist(alice);
        token.addToWhitelist(bob);
        vm.prank(alice);
        token.transfer(bob, 20);   // OK
        vm.prank(bob);
        token.transfer(alice, 20); // OK
    }

    /// @notice Allowance edge-cases: increase, decrease, and transferFrom limits
    function testAllowanceIncreaseDecrease() public {
        token.unlock();
        // initial allowance = 0
        assertEq(token.allowance(owner, bob), 0);
        token.approve(bob, 30);
        assertEq(token.allowance(owner, bob), 30);
        token.increaseAllowance(bob, 20);
        assertEq(token.allowance(owner, bob), 50);
        token.decreaseAllowance(bob, 10);
        assertEq(token.allowance(owner, bob), 40);

        // Bob transferFrom up to allowance
        vm.prank(bob);
        token.transferFrom(owner, alice, 40);
        assertEq(token.balanceOf(alice), 40);
        // further transferFrom should revert
        vm.prank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        token.transferFrom(owner, alice, 1);
    }

    /// @notice Concurrent burn + transfer shouldn’t let users bypass updated maxTx
    function testConcurrentBurnAndTransfer() public {
        token.unlock();
        // fund Alice
        token.transfer(alice, maxTxAmount);
        // burn supply down just before transfer
        token.burn(1_000);                 // reduces totalSupply -> recomputes cap
        uint256 newCap = token.totalSupply() * maxTxPercent / 100;
        // Alice still holding old maxTxAmount
        vm.prank(alice);
        // Alice’s attempt to send old maxTxAmount should revert now
        vm.expectRevert("Exceeds MaxTx");
        token.transfer(bob, maxTxAmount);
        // But sending within newCap should succeed
        vm.prank(alice);
        token.transfer(bob, newCap);
        assertEq(token.balanceOf(bob), newCap);
    }

    /// @notice Max-Tx parameter boundary checks for 0% and 100%
    function testMaxTxBoundaryPct() public {
        token.unlock();
        // 0% cap: no transfers except owner
        token.updateMaxTx(0);
        token.transfer(alice, 10); // owner exempt
        vm.prank(alice);
        vm.expectRevert("Exceeds MaxTx");
        token.transfer(bob, 1);

        // 100% cap: full balance allowed
        token.updateMaxTx(100);
        token.transfer(alice, 500);
        vm.prank(alice);
        token.transfer(bob, 500);
        assertEq(token.balanceOf(bob), 500);
    }

    /// @notice For any valid transfer, total balances + vault == initialSupply
    function test_TransferConservation(uint256 maxPct, uint256 taxBps, uint256 rawAmount) public {
        maxPct = bound(maxPct, 0, 100);
        taxBps = bound(taxBps, 0, 1000);
        token.unlock();
        token.updateMaxTx(maxPct);
        token.updateTaxSettings(taxReceiver, taxBps);
        token.setIsIncludedInTax(owner);

        uint256 maxAmt = (initialSupply * maxPct) / 100;
        uint256 amount = maxAmt == 0 ? 0 : rawAmount % (maxAmt + 1);

        token.transfer(alice, amount);

        uint256 taxAmt = (amount * taxBps) / 10000;
        uint256 receiveAmt = amount - taxAmt;

        assertEq(token.balanceOf(alice), receiveAmt);
        assertEq(token.balanceOf(taxReceiver), taxAmt);
        assertEq(
            token.balanceOf(owner)
              + token.balanceOf(alice)
              + token.balanceOf(taxReceiver),
            initialSupply
        );
    }

    /// @notice Transfers over maxTxAmount always revert for non-excluded senders
    function test_RevertWhenAmountExceedsMax(uint256 maxPct, uint256 rawAmount) public {
        maxPct = bound(maxPct, 1, 99); // exclude zero%, so there's a positive cap
        token.unlock();
        token.updateMaxTx(maxPct);

        uint256 maxAmt = (initialSupply * maxPct) / 100;
        uint256 amount = (rawAmount % (initialSupply + 1));
        if (amount <= maxAmt) {
            amount = maxAmt + 1;
        }

        // Fund Alice with exactly `amount` (owner bypasses maxTx)
        token.transfer(alice, amount);
        // As Alice (non-excluded), transferring >maxTx must revert
        vm.prank(alice);
        vm.expectRevert("Exceeds MaxTx");
        token.transfer(bob, amount);
    }

}
