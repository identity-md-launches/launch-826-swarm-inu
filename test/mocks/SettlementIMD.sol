// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Matches AdversarialIMD's balance/allowance slots so a fixture can replace only the
/// external token runtime. Models transferFrom quirks, which the payout mock does not exercise.
contract SettlementIMD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => uint256) private unusedPayoutModes;
    uint256 public totalSupply;
    uint256 public behavior;
    address public callback;
    bytes public callbackData;
    bool public callbackAttempted;
    bool public callbackSucceeded;

    function configure(uint256 behavior_, address callback_, bytes calldata data) external {
        behavior = behavior_;
        callback = callback_;
        callbackData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (behavior == 1) return false;
        if (behavior == 2) {
            assembly { return(0, 0) }
        }
        if (behavior == 3) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (behavior == 4) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        if (behavior == 5) {
            balanceOf[to] -= 1;
            totalSupply -= 1;
        }
        if (behavior == 6) {
            callbackAttempted = true;
            (callbackSucceeded,) = callback.call(callbackData);
        }
        return true;
    }
}
