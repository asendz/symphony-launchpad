// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract FERC20 is ERC20, ERC20Burnable, Ownable {
    uint256 public maxTx; // The maximum percentage of the token that can be bought at once
    uint256 private _maxTxAmount; // The maximum amount of token that can be bought at once, derived from maxTx
    mapping(address => bool) private isExcludedFromMaxTx;
    mapping(address => bool) public isIncludedInTax;

    address public taxReceiver;
    uint256 public taxBasisPoints; // 100 = 1%, 1000 = 10%, etc.

    // Lock mechanism
    bool public isLocked;
    mapping(address => bool) public isWhitelisted;

    event MaxTxUpdated(uint256 _maxTx);
    event TaxSettingsUpdated(address receiver, uint256 bps);
    event TokenLocked();
    event TokenUnlocked();
    event AddressWhitelisted(address indexed addr);
    
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 supply,
        uint256 _maxTx
    ) ERC20(name_, symbol_) Ownable() {
        _mint(msg.sender, supply);
        isExcludedFromMaxTx[msg.sender] = true;
        isExcludedFromMaxTx[address(this)] = true;
        _updateMaxTx(_maxTx);
        
        // Token starts locked - only launchpad contracts can transfer until graduation
        isLocked = true;
    }

    function _updateMaxTx(uint256 _maxTx) internal {
        maxTx = _maxTx;
        _maxTxAmount = (maxTx * totalSupply()) / 100;
        emit MaxTxUpdated(_maxTx);
    }

    function updateMaxTx(uint256 _maxTx) public onlyOwner {
        _updateMaxTx(_maxTx);
    }

    function excludeFromMaxTx(address user) public onlyOwner {
        require(user != address(0), "ERC20: Exclude Max Tx from zero address");
        isExcludedFromMaxTx[user] = true;
    }

    function setIsIncludedInTax(address addr) public onlyOwner {
        isIncludedInTax[addr] = true;
    }

    function updateTaxSettings(
        address _receiver,
        uint256 _taxBps
    ) external onlyOwner {
        require(_receiver != address(0), "ERC20: zero tax address");
        require(_taxBps <= 1000, "ERC20: tax too high"); // max 10%
        taxReceiver = _receiver;
        taxBasisPoints = _taxBps;
        emit TaxSettingsUpdated(_receiver, _taxBps);
    }

    function addToWhitelist(address addr) external onlyOwner {
        require(addr != address(0), "ERC20: Cannot whitelist zero address");
        isWhitelisted[addr] = true;
        emit AddressWhitelisted(addr);
    }

    function lock() external onlyOwner {
        require(!isLocked, "Token is already locked");
        isLocked = true;
        emit TokenLocked();
    }

    function unlock() external onlyOwner {
        require(isLocked, "Token is not locked");
        isLocked = false;
        emit TokenUnlocked();
    }

    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _checkMaxTx(_msgSender(), amount);
        _checkLock(_msgSender(), recipient);
        _transferWithTax(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        _checkMaxTx(sender, amount);
        _checkLock(sender, recipient);
        address spender = _msgSender();
        _spendAllowance(sender, spender, amount);
        _transferWithTax(sender, recipient, amount);
        return true;
    }

    function forceApprove(address spender, uint256 amount) public returns (bool) {
        _approve(_msgSender(), spender, 0);
        _approve(_msgSender(), spender, amount);
        return true;
    }

    // burn with recomputing the maxTx
    /// @notice Burns `amount` of tokens from the caller.
    function burn(uint256 amount) public override {
        super.burn(amount);
        // Re‐calculate maxTxAmount so it remains maxTx% of the new totalSupply
        _updateMaxTx(maxTx);
    }

    /// @notice Burns `amount` of tokens from `account`, using the allowance mechanism.
    function burnFrom(address account, uint256 amount) public override {
        super.burnFrom(account, amount);
        // Re‐calculate maxTxAmount so it remains maxTx% of the new totalSupply
        _updateMaxTx(maxTx);
    }

    function _checkMaxTx(address sender, uint256 amount) internal view {
        if (!isExcludedFromMaxTx[sender]) {
            require(amount <= _maxTxAmount, "Exceeds MaxTx");
        }
    }

    function _checkLock(address from, address to) internal view {
        if (isLocked) {
            require(isWhitelisted[from] || isWhitelisted[to], "Token is locked");
        }
    }

    function _transferWithTax(address from, address to, uint256 amount) internal {
        if (
            taxBasisPoints > 0 &&
            (isIncludedInTax[from] || isIncludedInTax[to]) &&
            from != taxReceiver &&
            to != taxReceiver
        ) {
            uint256 tax = (amount * taxBasisPoints) / 10_000;
            uint256 remaining = amount - tax;
            super._transfer(from, taxReceiver, tax);
            super._transfer(from, to, remaining);
        } else {
            super._transfer(from, to, amount);
        }
    }
}
