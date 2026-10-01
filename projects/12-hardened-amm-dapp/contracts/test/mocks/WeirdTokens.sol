// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.37;

/// @notice Minimal ERC-20 base with an overridable transfer hook, used to build the weird-token matrix.
abstract contract WeirdERC20Base {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    string public name;
    string public symbol;
    uint8 public immutable decimals;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function totalSupply() public view virtual returns (uint256);

    function balanceOf(address account) public view virtual returns (uint256);

    function mint(address to, uint256 amount) external virtual;

    function _move(address from, address to, uint256 amount) internal virtual;

    function _approve(address owner, address spender, uint256 amount) internal {
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spend(address from, uint256 amount) internal {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
    }
}

/// @notice Standard-balance token whose transfers burn `feeBps` of the amount (the recipient gets less).
contract FeeOnTransferToken is WeirdERC20Base {
    uint256 public immutable feeBps;
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;

    constructor(uint8 decimals_, uint256 feeBps_) WeirdERC20Base("Fee Token", "FEE", decimals_) {
        feeBps = feeBps_;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external override {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spend(from, amount);
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(_balances[from] >= amount, "balance");
        uint256 fee = amount * feeBps / 10_000;
        _balances[from] -= amount;
        _balances[to] += amount - fee;
        _totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
        if (fee > 0) emit Transfer(from, address(0), fee);
    }
}

/// @notice Share-based rebasing token (stETH/AMPL style): balances are shares * index / 1e18 and the index can
///         move up or down, changing every holder's balance, including the pair's, without a transfer.
contract RebasingToken is WeirdERC20Base {
    uint256 public index = 1e18;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;

    constructor(uint8 decimals_) WeirdERC20Base("Rebasing Token", "REB", decimals_) {}

    function totalSupply() public view override returns (uint256) {
        return totalShares * index / 1e18;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return sharesOf[account] * index / 1e18;
    }

    /// @dev Positive or negative rebase: scales every balance by newIndex / index.
    function rebase(uint256 newIndex) external {
        require(newIndex > 0, "index");
        index = newIndex;
    }

    function mint(address to, uint256 amount) external override {
        uint256 shares = amount * 1e18 / index;
        totalShares += shares;
        sharesOf[to] += shares;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spend(from, amount);
        _move(from, to, amount);
        return true;
    }

    /// @dev Rounds shares up so the sender never transfers less value than requested (the recipient may be
    ///      credited 1 wei more or less than `amount` after conversion, like real share-based tokens).
    function _move(address from, address to, uint256 amount) internal override {
        uint256 shares = (amount * 1e18 + index - 1) / index;
        require(sharesOf[from] >= shares, "balance");
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }
}

/// @notice USDT-style token: `transfer`, `transferFrom` and `approve` return nothing.
contract NoReturnToken is WeirdERC20Base {
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;

    constructor(uint8 decimals_) WeirdERC20Base("No Return Token", "NORET", decimals_) {}

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external override {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external {
        _approve(msg.sender, spender, amount);
    }

    function transfer(address to, uint256 amount) external {
        _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external {
        _spend(from, amount);
        _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(_balances[from] >= amount, "balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Token that reports failure by returning `false` instead of reverting once `failing` is set.
contract ReturnsFalseToken is WeirdERC20Base {
    bool public failing;
    uint256 internal _totalSupply;
    mapping(address => uint256) internal _balances;

    constructor() WeirdERC20Base("Returns False Token", "FALSE", 18) {}

    function setFailing(bool failing_) external {
        failing = failing_;
    }

    function totalSupply() public view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _balances[account];
    }

    function mint(address to, uint256 amount) external override {
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failing) return false;
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failing) return false;
        _spend(from, amount);
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(_balances[from] >= amount, "balance");
        _balances[from] -= amount;
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
}
