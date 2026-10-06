// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "./vendor/openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Plain OpenZeppelin ERC20. All supply is minted once to the deploying address.
/// @dev No extensions, overrides, owner, pause, upgrade or externally callable mint/burn.
contract SwarmInu is ERC20 {
    constructor() ERC20("Swarm Inu", "SI") {
        _mint(msg.sender, 1_000_000_000 * 10 ** 18);
    }
}
