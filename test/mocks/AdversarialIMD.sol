// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Test-only ERC20 with recipient-specific transfer behavior.
contract AdversarialIMD {
    enum Mode {
        Normal,
        RevertTransfer,
        FalseAfterTransfer,
        NoReturn,
        GasGrief,
        Reenter,
        ShortReturn,
        ReturnBomb,
        NoTransfer,
        TaxedTransfer
    }

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => Mode) public mode;
    uint256 public totalSupply;
    address public reentryTarget;
    bytes public reentryData;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    function mint(address recipient, uint256 amount) external {
        balanceOf[recipient] += amount;
        totalSupply += amount;
    }

    function setMode(address recipient, Mode mode_) external {
        mode[recipient] = mode_;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 permitted = allowance[from][msg.sender];
        if (permitted != type(uint256).max) allowance[from][msg.sender] = permitted - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        Mode behavior = mode[to];
        if (behavior == Mode.RevertTransfer) revert("recipient transfer rejected");
        if (behavior == Mode.GasGrief) {
            assembly { for {} 1 {} {} }
        }
        if (behavior == Mode.NoTransfer) return true;
        balanceOf[msg.sender] -= amount;
        if (behavior == Mode.TaxedTransfer) {
            uint256 received = amount - 1;
            balanceOf[to] += received;
            totalSupply -= 1;
        } else {
            balanceOf[to] += amount;
        }
        if (behavior == Mode.FalseAfterTransfer) return false;
        if (behavior == Mode.NoReturn) {
            assembly { return(0, 0) }
        }
        if (behavior == Mode.ShortReturn) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (behavior == Mode.ReturnBomb) {
            assembly { revert(0, 1000000) }
        }
        if (behavior == Mode.Reenter) {
            reentryAttempted = true;
            (reentrySucceeded,) = reentryTarget.call(reentryData);
        }
        return true;
    }
}
