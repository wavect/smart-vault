// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "contracts/interfaces/ISEuro.sol";
import "contracts/interfaces/IChainlink.sol";
import "contracts/interfaces/ISmartVault.sol";
import "contracts/interfaces/ISmartVaultManager.sol";
import "contracts/interfaces/ITokenManager.sol";

import "hardhat/console.sol";

contract SmartVault is ISmartVault {
    using SafeERC20 for IERC20;

    string private constant INVALID_USER = "err-invalid-user";
    string private constant UNDER_COLL = "err-under-coll";
    bytes32 private constant ETH = bytes32("ETH");

    address public owner;
    uint256 private minted;
    ISmartVaultManager public manager;
    ISEuro public seuro;

    constructor(address _manager, address _owner, address _seuro) {
        owner = _owner;
        manager = ISmartVaultManager(_manager);
        seuro = ISEuro(_seuro);
    }

    modifier onlyOwnerOrVaultManager {
        require(msg.sender == owner || msg.sender == address(manager), INVALID_USER);
        _;
    }

    modifier onlyVaultManager {
        require(msg.sender == address(manager), INVALID_USER);
        _;
    }

    modifier onlyOwner {
        require(msg.sender == owner, INVALID_USER);
        _;
    }

    modifier ifMinted(uint256 _amount) {
        require(minted >= _amount, "err-insuff-minted");
        _;
    }

    function getTokenManager() private view returns (ITokenManager) {
        return ITokenManager(manager.tokenManager());
    }

    function tokenToEur(ITokenManager.Token memory _token, uint256 _amount) private view returns (uint256) {
        ITokenManager tokenManager = ITokenManager(manager.tokenManager());
        IChainlink clEurUsd = IChainlink(tokenManager.clEurUsd());
        IChainlink tokenUsdClFeed = IChainlink(_token.clAddr);
        uint256 clScaleDiff = clEurUsd.decimals() - tokenUsdClFeed.decimals();
        uint256 scaledCollateral = _amount * 10 ** getTokenScaleDiff(_token.symbol, _token.addr);
        uint256 collateralUsd = scaledCollateral * 10 ** clScaleDiff * uint256(tokenUsdClFeed.latestAnswer());
        return collateralUsd / uint256(clEurUsd.latestAnswer());
    }

    function euroCollateral() private view returns (uint256 euros) {
        ITokenManager tokenManager = ITokenManager(manager.tokenManager());
        ITokenManager.Token[] memory acceptedTokens = tokenManager.getAcceptedTokens();
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            euros += tokenToEur(token, getAssetCollateral(token.symbol, token.addr));
        }
    }

    function maxMintable() private view returns (uint256) {
        return euroCollateral() * manager.HUNDRED_PC() / manager.collateralRate();
    }

    function currentCollateralPercentage() private view returns (uint256) {
        return minted == 0 ? 0 : euroCollateral() * manager.HUNDRED_PC() / minted;
    }

    function getTokenScaleDiff(bytes32 _symbol, address _tokenAddress) private view returns (uint256 scaleDiff) {
        return _symbol == ETH ? 0 : 18 - ERC20(_tokenAddress).decimals();
    }

    function getAssetCollateral(bytes32 _symbol, address _tokenAddress) private view returns (uint256 amount) {
        return _symbol == ETH ? address(this).balance : IERC20(_tokenAddress).balanceOf(address(this));
    }

    function getAssets() private view returns (Asset[] memory) {
        ITokenManager tokenManager = ITokenManager(manager.tokenManager());
        ITokenManager.Token[] memory acceptedTokens = tokenManager.getAcceptedTokens();
        Asset[] memory assets = new Asset[](acceptedTokens.length);
        for (uint256 i = 0; i < acceptedTokens.length; i++) {
            ITokenManager.Token memory token = acceptedTokens[i];
            assets[i] = Asset(token.symbol, getAssetCollateral(token.symbol, token.addr));
        }
        return assets;
    }

    function status() external view returns (Status memory) {
        return Status(minted, maxMintable(), currentCollateralPercentage(), getAssets());
    }

    function undercollateralised() external view returns (bool) {
        return minted > maxMintable();
    }

    function liquidateETH() private {
        (bool sent,) = payable(manager.protocol()).call{value: address(this).balance}("");
        require(sent, "err-eth-liquidate");
    }

    function liquidateERC20(IERC20 _token) private {
        _token.safeTransfer(manager.protocol(), _token.balanceOf(address(this)));
    }

    function liquidate() external {
        liquidateETH();
        ITokenManager.Token[] memory tokens = ITokenManager(manager.tokenManager()).getAcceptedTokens();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i].symbol != ETH) liquidateERC20(IERC20(tokens[i].addr));
        }
    }

    receive() external payable {}

    function canRemoveCollateral(ITokenManager.Token memory _token, uint256 _amount) private view returns (bool) {
        if (minted == 0) return true;
        uint256 currentMintable = maxMintable();
        uint256 eurValueToRemove = tokenToEur(_token, _amount);
        return currentMintable >= eurValueToRemove &&
            minted <= currentMintable - eurValueToRemove;
    }

    function removeCollateralETH(uint256 _amount, address payable _to) external onlyOwnerOrVaultManager {
        require(canRemoveCollateral(getTokenManager().getToken(ETH), _amount), UNDER_COLL);
        (bool sent,) = _to.call{value: _amount}("");
        require(sent, "err-eth-call");
    }

    function removeCollateral(bytes32 _symbol, uint256 _amount, address _to) external onlyOwnerOrVaultManager {
        ITokenManager.Token memory token = getTokenManager().getToken(_symbol);
        require(canRemoveCollateral(token, _amount), UNDER_COLL);
        IERC20(token.addr).safeTransfer(_to, _amount);
    }

    function removeAsset(address _tokenAddr, uint256 _amount, address _to) external onlyOwnerOrVaultManager {
        require(IERC20(_tokenAddr).balanceOf(address(this)) > 0, "err-insuff-funds");
        ITokenManager.Token memory token = getTokenManager().getTokenIfExists(_tokenAddr);
        if (token.addr == _tokenAddr) require(canRemoveCollateral(token, _amount), UNDER_COLL);
        IERC20(_tokenAddr).safeTransfer(_to, _amount);
    }

    function fullyCollateralised(uint256 _amount) private view returns (bool) {
        return minted + _amount <= maxMintable();
    }

    function mint(address _to, uint256 _amount) external onlyOwnerOrVaultManager {
        uint256 fee = _amount * manager.feeRate() / manager.HUNDRED_PC();
        require(fullyCollateralised(_amount + fee), UNDER_COLL);
        minted += _amount + fee;
        seuro.mint(_to, _amount);
        seuro.mint(manager.protocol(), fee);
    }

    function burn(uint256 _amount) external ifMinted(_amount) {
        uint256 fee = _amount * manager.feeRate() / manager.HUNDRED_PC();
        minted -= _amount;
        seuro.burn(msg.sender, _amount);
        IERC20(address(seuro)).safeTransferFrom(msg.sender, manager.protocol(), fee);
    }

    function setOwner(address _newOwner) external onlyVaultManager {
        owner = _newOwner;
    }
}
