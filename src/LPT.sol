// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title LiquidityPoolTokens
 * @dev A token contract implementing a buy/sell system with dividends and a treasury distribution.
 * Features:
 * - Token purchase/sale with dynamic pricing
 * - Dividend distribution to token holders (10% fee on transactions)
 * - Treasury wallet keeps tokens from first 24 hours, distributes 3.69% annually (daily payouts)
 * - Administrator controls
 * - Reinvestment functionality removed
 */
contract LiquidityPoolTokens {
    /*=================================
    =            MODIFIERS            =
    =================================*/
    // Ensures the caller holds tokens
    modifier onlyBelievers() {
        require(myTokens() > 0, "Must hold tokens");
        _;
    }

    // Ensures the caller has dividends to claim
    modifier onlyHodler() {
        require(myDividends() > 0, "No dividends available");
        _;
    }

    // Restricts access to administrators
    modifier onlyAdministrator() {
        require(administrators[msg.sender], "Not an administrator");
        _;
    }

    // Limits purchases during the treasury phase (first 24 hours)
    modifier treasuryPhase(uint256 _amountOfEthereum) {
        if (block.timestamp <= treasuryPhaseEnd) {
            require(msg.sender == treasuryWallet, "Only treasury can buy in first 24 hours");
            treasuryAccumulatedQuota += _amountOfEthereum;
        }
        _;
    }

    /*==============================
    =            EVENTS            =
    ==============================*/
    event TokenPurchase(address indexed customer, uint256 ethIn, uint256 tokensMinted);
    event TokenSell(address indexed customer, uint256 tokensBurned, uint256 ethOut);
    event Withdraw(address indexed customer, uint256 ethWithdrawn);
    event Transfer(address indexed from, address indexed to, uint256 tokens);
    event TreasuryDistribution(address indexed recipient, uint256 tokensDistributed);

    /*=====================================
    =            CONFIGURABLES            =
    =====================================*/
    string public name = "Liquidity Pool Tokens"; // Updated token name
    string public symbol = "LPT";                 // Updated token symbol
    uint8 public constant decimals = 18;
    uint256 public constant dividendFee = 10; // 10% fee for dividends
    uint256 public constant tokenPriceInitial = 0.0000001 ether;
    uint256 public constant tokenPriceIncremental = 0.00000001 ether;
    uint256 public constant magnitude = 2 ** 64; // Scaling factor for precision

    // Treasury phase configurations
    address public treasuryWallet; // Wallet that collects tokens in first 24 hours
    uint256 public treasuryPhaseEnd; // Timestamp when treasury phase ends (24 hours after deployment)
    uint256 public treasuryAccumulatedQuota; // Tracks ETH spent by treasury
    uint256 public treasuryTokenBalance; // Tokens held by treasury for distribution
    uint256 public constant DISTRIBUTION_RATE = 369; // 3.69% annual rate (in basis points: 3.69% = 369/10000)
    uint256 public constant SECONDS_PER_DAY = 86400; // Seconds in a day
    uint256 public constant SECONDS_PER_YEAR = 31536000; // Seconds in a year (365 days)
    uint256 public lastDistributionTimestamp; // Tracks last distribution time

    /*================================
    =            STORAGE            =
    ================================*/
    mapping(address => uint256) private tokenBalanceLedger;    // Tracks token balances
    mapping(address => int256) private payoutsTo;              // Tracks dividend payouts
    mapping(address => bool) public administrators;            // Admin access control

    uint256 private tokenSupply = 0;                           // Total token supply
    uint256 private profitPerShare = 0;                        // Dividends per token
    bool public paused = false;                                // Emergency pause flag

    /*=======================================
    =            PUBLIC FUNCTIONS           =
    =======================================*/
    constructor(address _treasuryWallet) {
        // Set initial admin and treasury wallet
        administrators[msg.sender] = true;
        treasuryWallet = _treasuryWallet;
        treasuryPhaseEnd = block.timestamp + 24 hours; // Treasury phase lasts 24 hours
        lastDistributionTimestamp = treasuryPhaseEnd; // Distribution starts after treasury phase
    }

    // Fallback function to handle direct ETH sends
    receive() external payable {
        purchaseTokens(msg.value);
    }

    // Buy tokens with ETH
    function buy() external payable returns (uint256) {
        require(!paused, "Contract is paused");
        return purchaseTokens(msg.value);
    }

    // Sell all tokens and withdraw
    function exit() external {
        address customer = msg.sender;
        uint256 tokens = tokenBalanceLedger[customer];
        if (tokens > 0) sell(tokens);
        withdraw();
    }

    // Withdraw accumulated dividends
    function withdraw() public onlyHodler {
        require(!paused, "Contract is paused");
        address customer = msg.sender;
        uint256 dividends = myDividends();
        payoutsTo[customer] += int256(dividends * magnitude);

        (bool success, ) = customer.call{value: dividends}(""); // Reentrancy-safe transfer
        require(success, "Transfer failed");
        emit Withdraw(customer, dividends);
    }

    // Sell tokens for ETH
    function sell(uint256 _amountOfTokens) public onlyBelievers {
        require(!paused, "Contract is paused");
        address customer = msg.sender;
        require(_amountOfTokens <= tokenBalanceLedger[customer], "Insufficient tokens");

        uint256 eth = tokensToEthereum(_amountOfTokens);
        uint256 dividends = eth / dividendFee;
        uint256 taxedEth = eth - dividends;

        tokenSupply -= _amountOfTokens;
        tokenBalanceLedger[customer] -= _amountOfTokens;
        int256 updatedPayouts = int256(profitPerShare * _amountOfTokens + (taxedEth * magnitude));
        payoutsTo[customer] -= updatedPayouts;

        if (tokenSupply > 0) {
            profitPerShare += (dividends * magnitude) / tokenSupply;
        }

        emit TokenSell(customer, _amountOfTokens, taxedEth);
    }

    // Transfer tokens to another address (with 10% fee)
    function transfer(address to, uint256 amountOfTokens) external onlyBelievers returns (bool) {
        require(!paused, "Contract is paused");
        require(to != address(0), "Invalid address");
        address customer = msg.sender;
        require(amountOfTokens <= tokenBalanceLedger[customer], "Insufficient tokens");

        if (myDividends() > 0) withdraw();

        uint256 tokenFee = amountOfTokens / dividendFee;
        uint256 taxedTokens = amountOfTokens - tokenFee;
        uint256 dividends = tokensToEthereum(tokenFee);

        tokenSupply -= tokenFee;
        tokenBalanceLedger[customer] -= amountOfTokens;
        tokenBalanceLedger[to] += taxedTokens;

        payoutsTo[customer] -= int256(profitPerShare * amountOfTokens);
        payoutsTo[to] += int256(profitPerShare * taxedTokens);
        profitPerShare += (dividends * magnitude) / tokenSupply;

        emit Transfer(customer, to, taxedTokens);
        return true;
    }

    // Distribute treasury tokens to all holders daily (3.69% annually)
    function distributeTreasuryTokens() external {
        require(block.timestamp > treasuryPhaseEnd, "Treasury phase not ended");
        require(block.timestamp >= lastDistributionTimestamp + SECONDS_PER_DAY, "Distribution already done today");

        if (treasuryTokenBalance == 0 || tokenSupply == 0) return;

        // Calculate daily distribution: 3.69% / 365 days
        uint256 dailyRate = (DISTRIBUTION_RATE * magnitude) / (10000 * 365); // Basis points to daily rate
        uint256 tokensToDistribute = (treasuryTokenBalance * dailyRate) / magnitude;

        if (tokensToDistribute > treasuryTokenBalance) {
            tokensToDistribute = treasuryTokenBalance; // Cap at remaining balance
        }

        treasuryTokenBalance -= tokensToDistribute;
        profitPerShare += (tokensToDistribute * magnitude) / tokenSupply; // Distribute as dividends
        lastDistributionTimestamp = block.timestamp;

        emit TreasuryDistribution(address(this), tokensToDistribute);
    }

    /*----------  ADMINISTRATOR FUNCTIONS  ----------*/
    function setTreasuryWallet(address _newTreasury) external onlyAdministrator {
        treasuryWallet = _newTreasury;
    }

    function setName(string calldata _name) external onlyAdministrator {
        name = _name;
    }

    function setSymbol(string calldata _symbol) external onlyAdministrator {
        symbol = _symbol;
    }

    function setPaused(bool _paused) external onlyAdministrator {
        paused = _paused;
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
        address customer = msg.sender;
        return uint256((int256(profitPerShare * tokenBalanceLedger[customer]) - payoutsTo[customer]) / int256(magnitude));
    }

    function balanceOf(address _customer) external view returns (uint256) {
        return tokenBalanceLedger[_customer];
    }

    function dividendsOf(address _customer) public view returns (uint256) {
        return uint256((int256(profitPerShare * tokenBalanceLedger[_customer]) - payoutsTo[_customer]) / int256(magnitude));
    }

    function sellPrice() public view returns (uint256) {
        if (tokenSupply == 0) return tokenPriceInitial - tokenPriceIncremental;
        uint256 eth = tokensToEthereum(1e18);
        uint256 dividends = eth / dividendFee;
        return eth - dividends;
    }

    function buyPrice() public view returns (uint256) {
        if (tokenSupply == 0) return tokenPriceInitial + tokenPriceIncremental;
        uint256 eth = tokensToEthereum(1e18);
        uint256 dividends = eth / dividendFee;
        return eth + dividends;
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
    function purchaseTokens(uint256 _incomingEth)
        internal
        treasuryPhase(_incomingEth)
        returns (uint256)
    {
        address customer = msg.sender;
        uint256 dividends = _incomingEth / dividendFee;
        uint256 taxedEth = _incomingEth - dividends;
        uint256 amountOfTokens = ethereumToTokens(taxedEth);
        uint256 fee = dividends * magnitude;

        require(amountOfTokens > 0 && (amountOfTokens + tokenSupply) > tokenSupply, "Invalid token amount");

        if (block.timestamp <= treasuryPhaseEnd && customer == treasuryWallet) {
            // Treasury keeps all tokens during first 24 hours
            treasuryTokenBalance += amountOfTokens;
        }

        if (tokenSupply > 0) {
            tokenSupply += amountOfTokens;
            profitPerShare += (dividends * magnitude) / tokenSupply;
            fee = fee - (fee - (amountOfTokens * (dividends *  magnitude / tokenSupply)));
        } else {
            tokenSupply = amountOfTokens;
        }

        // Only update ledger for non-treasury purchases
        if (customer != treasuryWallet || block.timestamp > treasuryPhaseEnd) {
            tokenBalanceLedger[customer] += amountOfTokens;
        }

        int256 updatedPayouts = int256((profitPerShare * amountOfTokens) - fee);
        payoutsTo[customer] += updatedPayouts;

        emit TokenPurchase(customer, _incomingEth, amountOfTokens);
        return amountOfTokens;
    }

    function ethereumToTokens(uint256 _eth) internal view returns (uint256) {
        uint256 tokenPriceInitialScaled = tokenPriceInitial * 1e18;
        uint256 tokensReceived = (
            (
                sqrt(
                    (tokenPriceInitialScaled ** 2) +
                    (2 * (tokenPriceIncremental * 1e18) * (_eth * 1e18)) +
                    ((tokenPriceIncremental * 2) * (tokenSupply ** 2)) +
                    (2 * tokenPriceIncremental * tokenPriceInitialScaled * tokenSupply)
                ) - tokenPriceInitialScaled
            ) / tokenPriceIncremental
        ) - tokenSupply;
        return tokensReceived;
    }

    function tokensToEthereum(uint256 _tokens) internal view returns (uint256) {
        uint256 tokensScaled = _tokens + 1e18;
        uint256 supplyScaled = tokenSupply + 1e18;
        uint256 ethReceived = (
            (
                (
                    (tokenPriceInitial + (tokenPriceIncremental * (supplyScaled / 1e18))) - tokenPriceIncremental
                ) * (tokensScaled - 1e18)
            ) - (tokenPriceIncremental * ((tokensScaled * 2 - tokensScaled) / 1e18)) / 2
        ) / 1e18;
        return ethReceived;
    }

    function sqrt(uint256 x) internal pure returns (uint256) {
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}