// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract LiquidityPoolTokens is ERC20, Ownable {
    /*===================================== 
    =        CONFIGURABLES & CONSTANTS     = 
    =====================================*/
    uint256 public constant dividendFee = 10; // 10% fee for dividends
    uint256 public constant tokenPriceInitial = 0.0000001 ether;
    uint256 public constant tokenPriceIncremental = 0.00000001 ether;
    uint256 public constant magnitude = 2**64; // Scaling factor for precision

    /*================================ 
    =            STORAGE            = 
    ================================*/
    mapping(address => int256) private payoutsTo; // Tracks dividend payouts
    uint256 private profitPerShare = 0; // Dividends per token

    /*============================== 
    =            EVENTS            = 
    ==============================*/
    event TokenPurchase(
        address indexed buyer,
        uint256 ethIn,
        uint256 tokensMinted
    );
    event TokenSale(
        address indexed seller,
        uint256 tokensBurned,
        uint256 ethOut
    );
    event Withdraw(address indexed user, uint256 ethWithdrawn);

    /*======================================= 
    =            CONSTRUCTOR               = 
    =======================================*/
    constructor() ERC20("Liquidity Pool Tokens", "LPT") Ownable(msg.sender) {}

    /*======================================= 
    =            PUBLIC FUNCTIONS          = 
    =======================================*/
    // Fallback to buy tokens
    receive() external payable {
        purchaseTokens(msg.value);
    }

    // Buy LPT with ETH
    function buy() external payable {
        purchaseTokens(msg.value);
    }

    // Sell LPT for ETH
    function sell(uint256 _amountOfTokens) external {
        require(
            _amountOfTokens <= balanceOf(msg.sender),
            "Insufficient tokens"
        );

        address seller = msg.sender;
        uint256 eth = tokensToEthereum(_amountOfTokens);
        uint256 dividends = eth / dividendFee;
        uint256 taxedEth = eth - dividends;

        _burn(seller, _amountOfTokens);

        int256 updatedPayouts = int256(
            profitPerShare * _amountOfTokens + (taxedEth * magnitude)
        );
        payoutsTo[seller] -= updatedPayouts;

        if (totalSupply() > 0) {
            profitPerShare += (dividends * magnitude) / totalSupply();
        }

        (bool success, ) = seller.call{value: taxedEth}("");
        require(success, "Transfer failed");
        emit TokenSale(seller, _amountOfTokens, taxedEth);
    }

    // Withdraw dividends
    function withdraw() external {
        uint256 dividends = myDividends();
        require(dividends > 0, "No dividends available");

        address user = msg.sender;
        payoutsTo[user] += int256(dividends * magnitude);

        (bool success, ) = user.call{value: dividends}("");
        require(success, "Transfer failed");
        emit Withdraw(user, dividends);
    }

    /*----------  VIEW FUNCTIONS  ----------*/
    function totalEthereumBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function myTokens() public view returns (uint256) {
        return balanceOf(msg.sender);
    }

    function myDividends() public view returns (uint256) {
        address user = msg.sender;
        return
            uint256(
                (int256(profitPerShare * balanceOf(user)) - payoutsTo[user]) /
                    int256(magnitude)
            );
    }

    function sellPrice() public view returns (uint256) {
        if (totalSupply() == 0)
            return tokenPriceInitial - tokenPriceIncremental;
        return
            tokenPriceInitial +
            ((tokenPriceIncremental * totalSupply()) * 9) /
            10;
    }

    function buyPrice() public view returns (uint256) {
        if (totalSupply() == 0)
            return tokenPriceInitial + tokenPriceIncremental;
        return tokenPriceInitial + (tokenPriceIncremental * totalSupply());
    }

    function calculateTokensReceived(uint256 _eth)
        external
        pure
        returns (uint256)
    {
        uint256 dividends = _eth / dividendFee;
        uint256 taxedEth = _eth - dividends;
        return ethereumToTokens(taxedEth);
    }

    function calculateEthereumReceived(uint256 _tokens)
        external
        view
        returns (uint256)
    {
        require(_tokens <= totalSupply(), "Insufficient supply");
        uint256 eth = tokensToEthereum(_tokens);
        uint256 dividends = eth / dividendFee;
        return eth - dividends;
    }

    /*========================================== 
    =           INTERNAL FUNCTIONS            = 
    ==========================================*/
    function purchaseTokens(uint256 _incomingEth) internal returns (uint256) {
        uint256 dividends = (_incomingEth * dividendFee) / 100;
        uint256 taxedEth = _incomingEth - dividends;
        uint256 amountOfTokens = ethereumToTokens(taxedEth);

        // Debugging print
        emit TokenPurchase(msg.sender, _incomingEth, amountOfTokens);

        require(amountOfTokens > 0, "Invalid token amount");

        _mint(msg.sender, amountOfTokens);
        return amountOfTokens;
    }

    function ethereumToTokens(uint256 _eth) internal pure returns (uint256) {
        return sqrt((_eth * 2) / (tokenPriceIncremental + tokenPriceInitial));
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function tokensToEthereum(uint256 _tokens) internal view returns (uint256) {
        return
            (_tokens *
                (tokenPriceInitial + (tokenPriceIncremental * totalSupply()))) /
            10**18;
    }
}
