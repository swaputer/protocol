// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {SwaputerToken} from "../src/SwaputerToken.sol";

contract SwaputerTokenIdentityTest is Test {
    function test_sPuterIdentityAndFixedIssuance() public {
        SwaputerToken token = new SwaputerToken(10_000 ether, address(this));

        assertEq(token.name(), "Swaputer");
        assertEq(token.symbol(), "sPuter");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 10_000 ether);
        assertEq(token.balanceOf(address(this)), 10_000 ether);
    }
}
