// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice Test-only share-based rebasing token modeled on stETH: balances are `shares * pooled / totalShares` and
/// a transfer moves `amount * totalShares / pooled` shares rounded down, so the receiver can get a wei or two less
/// than requested. `rebase` changes the pooled amount (up or down) for every holder at once.
contract ShareRebasingToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    string public constant name = "Rebasing Token";
    string public constant symbol = "rTKN";
    uint8 public constant decimals = 18;

    uint256 public totalShares;
    uint256 public totalPooled;
    mapping(address => uint256) public sharesOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function totalSupply() external view returns (uint256) {
        return totalPooled;
    }

    function balanceOf(address account) public view returns (uint256) {
        return totalShares == 0 ? 0 : (sharesOf[account] * totalPooled) / totalShares;
    }

    function mint(address to, uint256 amount) external {
        uint256 shares = totalShares == 0 ? amount : (amount * totalShares) / totalPooled;
        totalShares += shares;
        totalPooled += amount;
        sharesOf[to] += shares;
        emit Transfer(address(0), to, amount);
    }

    /// @notice Scales every balance by `(totalPooled + delta) / totalPooled`.
    function rebase(int256 delta) external {
        totalPooled = delta >= 0 ? totalPooled + uint256(delta) : totalPooled - uint256(-delta);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        uint256 shares = (amount * totalShares) / totalPooled;
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }
}
