// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";

/// @notice An immutable token sink. Donate by transferring SI or IMD to this address.
/// @dev There is deliberately no owner, withdrawal, approval, execution, or upgrade function.
contract SICommunityVault {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    IERC20 public immutable si;
    IERC20 public immutable imd;

    error InvalidTokens();

    constructor(address si_, address imd_) {
        if (si_ == imd_ || si_.code.length == 0 || imd_.code.length == 0) revert InvalidTokens();
        si = IERC20(si_);
        imd = IERC20(imd_);
    }

    function totalIMDHeld() external view returns (uint256) {
        return imd.balanceOf(address(this));
    }

    function totalSILocked() external view returns (uint256) {
        return si.balanceOf(address(this));
    }

    /// @notice All SI sent to the dead address, including direct transfers outside the hook.
    /// @dev Dead-address transfers do not reduce the ERC20's fixed totalSupply.
    function totalSIBurned() external view returns (uint256) {
        return si.balanceOf(DEAD);
    }
}
