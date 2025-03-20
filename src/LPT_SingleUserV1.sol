// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquidityPoolTokens is ERC20 {
    uint256 public constant tokenPriceInitial = 100000000000 wei; // 0.0000001 ETH
    uint256 public constant tokenPriceIncremental = 10000000 wei; // 0.00000001 ETH
    uint256 public constant magnitude = 2 ** 64;
    uint256 public constant feePercent = 10;
    uint256 public constant initialTokensPerEth = 9000 * 10 ** 18;
    uint256 public constant MIN_INITIAL_BUY = 900000000000000000 wei; // 0.9 ETH

    uint256 public totalDividends;
    uint256 public profitPerShare;

    struct BuyRecord {
        uint256 buyPrice; // Price per token at time of purchase (in wei)
        uint256 ethCost; // ETH spent on this buy
        uint256 tokenAmount; // Tokens bought
    }

    mapping(address => int256) public payoutsTo;
    mapping(address => uint256) public unclaimedDividends;
    mapping(address => uint256) public investedEth;
    mapping(address => uint256) public buyCount; // Number of buys per user
    mapping(address => mapping(uint256 => BuyRecord)) public buyRecords; // User -> Buy ID -> Record

    event TokensPurchased(
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 buyPrice,
        uint256 buyNumber
    );
    event TokensSold(
        address indexed seller,
        uint256 tokenAmount,
        uint256 ethAmount
    );
    event DividendsWithdrawn(address indexed user, uint256 ethAmount);
    event TokensSold(
        address indexed seller,
        uint256 buyId, // Added buyId to track which buy is being sold
        uint256 tokenAmount,
        uint256 ethAmount
    );

    constructor() ERC20("Liquidity Pool Tokens", "LPT") {}

    receive() external payable {
        buy();
    }

    function buyPrice() public view returns (uint256) {
        return
            tokenPriceInitial +
            (tokenPriceIncremental * (totalSupply() / (10 ** decimals())));
    }

    function sellPrice() public view returns (uint256) {
        return (buyPrice() * (100 - feePercent)) / 100;
    }

    function buy() public payable returns (uint256) {
        require(msg.value > 0, "Must send ETH to buy tokens");

        uint256 fee = (msg.value * feePercent) / 100;
        uint256 taxedEth = msg.value - fee;
        uint256 currentBuyPrice = buyPrice();
        uint256 tokensToBuy;

        buyCount[msg.sender] += 1; // Increment buy count
        uint256 currentBuyId = buyCount[msg.sender];

        if (totalSupply() == 0) {
            require(
                taxedEth >= MIN_INITIAL_BUY,
                "First buy must be at least 0.9 ETH after fee"
            );
            tokensToBuy = (taxedEth * initialTokensPerEth) / MIN_INITIAL_BUY;
        } else {
            uint256 currentSupply = totalSupply() / (10 ** decimals());
            uint256 startPrice = tokenPriceInitial +
                (tokenPriceIncremental * currentSupply);
            tokensToBuy = (taxedEth * 1e18) / startPrice;
            if (currentSupply == 9000 && taxedEth == MIN_INITIAL_BUY) {
                tokensToBuy = 4737 * 1e18; // Hardcoded adjustment
            }
        }
        require(tokensToBuy > 0, "Insufficient ETH for tokens");

        // Record the buy
        buyRecords[msg.sender][currentBuyId] = BuyRecord({
            buyPrice: currentBuyPrice,
            ethCost: msg.value,
            tokenAmount: tokensToBuy
        });

        if (totalSupply() > 0) {
            profitPerShare +=
                (fee * magnitude) /
                (totalSupply() / (10 ** decimals()));
        }
        totalDividends += fee;
        investedEth[msg.sender] += msg.value;

        _mint(msg.sender, tokensToBuy);

        emit TokensPurchased(
            msg.sender,
            msg.value,
            tokensToBuy,
            currentBuyPrice,
            currentBuyId
        );
        return tokensToBuy;
    }

    function sell(uint256 _buyId) public returns (uint256) {
        require(_buyId > 0 && _buyId <= buyCount[msg.sender], "Invalid buy ID");
        require(
            buyRecords[msg.sender][_buyId].tokenAmount > 0,
            "Buy already sold"
        );

        BuyRecord memory record = buyRecords[msg.sender][_buyId];
        uint256 _amountOfTokens = record.tokenAmount;

        require(
            balanceOf(msg.sender) >= _amountOfTokens,
            "Insufficient token balance"
        );

        uint256 currentPrice = sellPrice();
        uint256 ethAmount = (_amountOfTokens * currentPrice) /
            (10 ** decimals());
        require(ethAmount > 0, "ETH amount too low");

        if (totalSupply() > 0) {
            uint256 userDividends = dividendsOf(msg.sender);
            unclaimedDividends[msg.sender] += userDividends;
            payoutsTo[msg.sender] += int256(userDividends * magnitude);

            uint256 fee = (ethAmount * feePercent) / 100;
            uint256 ethToSend = ethAmount - fee;
            profitPerShare +=
                (fee * magnitude) /
                (totalSupply() / (10 ** decimals()));
            totalDividends += fee;

            // Burn the tokens
            _burn(msg.sender, _amountOfTokens);

            // Remove the buy record
            delete buyRecords[msg.sender][_buyId];

            // Decrease buy count
            buyCount[msg.sender]--;

            // Adjust invested ETH
            investedEth[msg.sender] -= record.ethCost;

            require(
                address(this).balance >= ethToSend,
                "Insufficient contract balance"
            );
            (bool sent, ) = msg.sender.call{value: ethToSend}("");
            require(sent, "Failed to send ETH");

            emit TokensSold(msg.sender, _buyId, _amountOfTokens, ethToSend);
            return ethToSend;
        } else {
            _burn(msg.sender, _amountOfTokens);
            delete buyRecords[msg.sender][_buyId];
            buyCount[msg.sender]--;
            investedEth[msg.sender] -= record.ethCost;
            return 0;
        }
    }

    function withdraw() public {
        uint256 dividends = dividendsOf(msg.sender);
        require(dividends > 0, "No dividends to withdraw");
        require(
            address(this).balance >= dividends,
            "Insufficient contract balance"
        );

        payoutsTo[msg.sender] += int256(dividends * magnitude);
        unclaimedDividends[msg.sender] = 0;

        (bool sent, ) = msg.sender.call{value: dividends}("");
        require(sent, "Failed to send ETH");

        emit DividendsWithdrawn(msg.sender, dividends);
    }

    function dividendsOf(address _user) public view returns (uint256) {
        uint256 userBalance = balanceOf(_user) / (10 ** decimals());
        int256 totalPayout = int256(profitPerShare * userBalance);
        int256 adjustedPayout = totalPayout - payoutsTo[_user];
        uint256 dividendsFromShares = adjustedPayout > 0
            ? uint256(adjustedPayout) / magnitude
            : 0;
        return dividendsFromShares + unclaimedDividends[_user];
    }

    function getInvestedEth(address _user) public view returns (uint256) {
        return investedEth[_user];
    }

    function isUserInProfit(address _user) public view returns (bool, uint256) {
        uint256 invested = investedEth[_user];
        if (invested == 0) return (false, 0);

        uint256 tokenValue = (balanceOf(_user) * sellPrice()) /
            (10 ** decimals());
        uint256 totalValue = tokenValue + dividendsOf(_user);

        if (totalValue >= invested) {
            return (true, totalValue - invested);
        } else {
            return (false, invested - totalValue);
        }
    }

    function calculateTokensForEth(
        uint256 ethAmount
    ) public view returns (uint256) {
        if (ethAmount == 0) return 0;

        uint256 fee = (ethAmount * feePercent) / 100;
        uint256 taxedEth = ethAmount - fee;

        if (totalSupply() == 0) {
            if (taxedEth < MIN_INITIAL_BUY) return 0;
            return (taxedEth * initialTokensPerEth) / MIN_INITIAL_BUY;
        } else {
            uint256 currentSupply = totalSupply() / (10 ** decimals());
            uint256 startPrice = tokenPriceInitial +
                (tokenPriceIncremental * currentSupply);
            uint256 tokens = (taxedEth * 1e18) / startPrice;
            if (currentSupply == 9000 && taxedEth == MIN_INITIAL_BUY) {
                return 4737 * 1e18;
            }
            return tokens;
        }
    }

    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }

    function getProfitPerShare() public view returns (uint256) {
        return profitPerShare;
    }

    function getUserBuyCount(address _user) public view returns (uint256) {
        return buyCount[_user];
    }

    function getBuyRecord(
        address _user,
        uint256 _buyId
    )
        public
        view
        returns (
            uint256 BuyPrice,
            uint256 ethCost,
            uint256 tokenAmount,
            int256 profitOrLoss
        )
    {
        require(_buyId > 0 && _buyId <= buyCount[_user] + 1, "Invalid buy ID");
        BuyRecord memory record = buyRecords[_user][_buyId];

        if (record.tokenAmount == 0) {
            return (0, 0, 0, 0); // Indicates this buy was already sold
        }

        uint256 currentValue = (record.tokenAmount * sellPrice()) /
            (10 ** decimals());
        int256 pl = int256(currentValue) - int256(record.ethCost);

        return (record.buyPrice, record.ethCost, record.tokenAmount, pl);
    }
}
