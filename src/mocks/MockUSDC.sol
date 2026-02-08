// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockUSDC
/// @notice A minimal ERC-20 mock of USDC for testnet deployments.
///         The deployer is the initial owner and can mint tokens to any address.
///         Ownership can be transferred. Anyone can call `faucet()` to mint
///         themselves a small amount for testing.
contract MockUSDC {
    string public constant NAME = "USD Coin (Mock)";
    string public constant SYMBOL = "USDC";
    uint8 public constant DECIMALS = 6;

    /// @dev ERC-20 compatible getters (lowercase) for tooling that expects them.
    function name() external pure returns (string memory) {
        return NAME;
    }

    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    uint256 public totalSupply;
    address public owner;

    uint256 public constant FAUCET_AMOUNT = 1_000e6; // $1 000 per faucet call

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyOwner() internal view {
        require(msg.sender == owner, "Not owner");
    }

    constructor() {
        owner = msg.sender;
    }

    // ----------------------------------------------------------------
    //  ERC-20 core
    // ----------------------------------------------------------------

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "Insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        return _transfer(from, to, amount);
    }

    // ----------------------------------------------------------------
    //  Minting
    // ----------------------------------------------------------------

    /// @notice Owner can mint any amount to any address.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Anyone can call this to get FAUCET_AMOUNT (1 000 USDC) for testing.
    function faucet() external {
        _mint(msg.sender, FAUCET_AMOUNT);
    }

    // ----------------------------------------------------------------
    //  Owner management
    // ----------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ----------------------------------------------------------------
    //  Internals
    // ----------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        require(to != address(0), "Transfer to zero address");
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}
