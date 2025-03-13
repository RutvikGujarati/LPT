// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LiquidityPoolTokens
 * @dev A simplified token contract for a single user to harvest profits via buy/sell cycles.
 * Features:
 * - Buy LPT with ETH, increasing price with each purchase
 * - Sell LPT for ETH when profitable, reducing price
 * - 10% fee on buy/sell added to dividends, withdrawable for reinvestment
 * - Core logic: dynamic pricing, profit harvesting, 10% reinvestment
 */
contract LiquidityPoolTokens {
    /*=================================
    =            MODIFIERS            =
    =================================*/
    modifier onlyHolder() {
        require(tokenBalanceLedger[msg.sender] > 0, "Must hold tokens");
        _;
    }

    modifier hasDividends() {
        require(myDividends() > 0, "No dividends available");
        _;
    }

    /*==============================
    =            EVENTS            =
    ==============================*/
    event TokenPurchase(address indexed buyer, uint256 ethIn, uint256 tokensMinted);
    event TokenSale(address indexed seller, uint256 tokensBurned, uint256 ethOut);
    event Withdraw(address indexed user, uint256 ethWithdrawn);

    /*=====================================
    =            CONFIGURABLES            =
    =====================================*/
    string public name = "Liquidity Pool Tokens";
    string public symbol = "LPT";
    uint8 public constant decimals = 18;
    uint256 public constant dividendFee = 10; // 10% fee for dividends
    uint256 public constant tokenPriceInitial = 0.0000001 ether;
    uint256 public constant tokenPriceIncremental = 0.00000001 ether;
    uint256 public constant magnitude = 2 ** 64; // Scaling factor for precision

    /*================================
    =            STORAGE            =
    ================================*/
    mapping(address => uint256) private tokenBalanceLedger; // Tracks LPT balances
    mapping(address => int256) private payoutsTo;          // Tracks dividend payouts
    uint256 private tokenSupply = 0;                       // Total LPT supply
    uint256 private profitPerShare = 0;                    // Dividends per token

    /*=======================================
    =            PUBLIC FUNCTIONS           =
    =======================================*/
    constructor() {
        // No admin or treasury needed for single-user focus
    }

    // Fallback to buy tokens
    receive() external payable {
        purchaseTokens(msg.value);
    }

    // Buy LPT with ETH
    function buy() external payable returns (uint256) {
        return purchaseTokens(msg.value);
    }

    // Sell LPT for ETH
    function sell(uint256 _amountOfTokens) external onlyHolder {
        address seller = msg.sender;
        require(_amountOfTokens <= tokenBalanceLedger[seller], "Insufficient tokens");

        uint256 eth = tokensToEthereum(_amountOfTokens);
        uint256 dividends = eth / dividendFee;
        uint256 taxedEth = eth - dividends;

        tokenSupply -= _amountOfTokens;
        tokenBalanceLedger[seller] -= _amountOfTokens;
        int256 updatedPayouts = int256(profitPerShare  * _amountOfTokens + (taxedEth * magnitude));
        payoutsTo[seller] -= updatedPayouts;

        if (tokenSupply > 0) {
            profitPerShare += (dividends * magnitude) / tokenSupply;
        }

        (bool success, ) = seller.call{value: taxedEth}("");
        require(success, "Transfer failed");
        emit TokenSale(seller, _amountOfTokens, taxedEth);
    }

    // Withdraw dividends (10% fee for reinvestment)
    function withdraw() external hasDividends {
        address user = msg.sender;
        uint256 dividends = myDividends();
        payoutsTo[user] += int256(dividends * magnitude);

        (bool success, ) = user.call{value: dividends}("");
        require(success, "Transfer failed");
        emit Withdraw(user, dividends);
    }

    /*----------  VIEW FUNCTIONS  ----------*/
    function totalEthereumBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function totalSupply() external view returns (uint256) {
        return tokenSupply;
    }

    function myTokens() public view returns (uint256) {
        return tokenBalanceLedger[msg.sender];
    }

    function myDividends() public view returns (uint256) {
        address user = msg.sender;
        return uint256((int256(profitPerShare * tokenBalanceLedger[user]) - payoutsTo[user]) / int256(magnitude));
    }

    function sellPrice() public view returns (uint256) {
        if (tokenSupply == 0) return tokenPriceInitial - tokenPriceIncremental;
        return tokenPriceInitial + (tokenPriceIncremental * tokenSupply)*  9 / 10; // 10% fee adjustment
    }

    function buyPrice() public view returns (uint256) {
        if (tokenSupply == 0) return tokenPriceInitial + tokenPriceIncremental;
        return tokenPriceInitial + (tokenPriceIncremental * tokenSupply);
    }

    function calculateTokensReceived(uint256 _eth) external view returns (uint256) {
        uint256 dividends = _eth / dividendFee;
        uint256 taxedEth = _eth - dividends;
        return ethereumToTokens(taxedEth);
    }

    function calculateEthereumReceived(uint256 _tokens) external view returns (uint256) {
        require(_tokens <= tokenSupply, "Insufficient supply");
        uint256 eth = tokensToEthereum(_tokens);
        uint256 dividends = eth / dividendFee;
        return eth - dividends;
    }

    /*==========================================
    =            INTERNAL FUNCTIONS            =
    ==========================================*/
    function purchaseTokens(uint256 _incomingEth) internal returns (uint256) {
        address buyer = msg.sender;
        uint256 dividends = _incomingEth / dividendFee;
        uint256 taxedEth = _incomingEth - dividends;
        uint256 amountOfTokens = ethereumToTokens(taxedEth);

        require(amountOfTokens > 0 && (amountOfTokens + tokenSupply) > tokenSupply, "Invalid token amount");

        if (tokenSupply > 0) {
            tokenSupply += amountOfTokens;
            profitPerShare += (dividends * magnitude) / tokenSupply;
        } else {
            tokenSupply = amountOfTokens;
        }

        tokenBalanceLedger[buyer] += amountOfTokens;
        int256 updatedPayouts = int256(profitPerShare * amountOfTokens - (dividends * magnitude));
        payoutsTo[buyer] += updatedPayouts;

        emit TokenPurchase(buyer, _incomingEth, amountOfTokens);
        return amountOfTokens;
    }

    function ethereumToTokens(uint256 _eth) internal view returns (uint256) {
        uint256 tokens = (_eth * 1e18) / (tokenPriceInitial + (tokenPriceIncremental * tokenSupply));
        return tokens;
    }

    function tokensToEthereum(uint256 _tokens) internal view returns (uint256) {
        return (_tokens * (tokenPriceInitial + (tokenPriceIncremental * tokenSupply))) / 1e18;
    }
}