// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquidityPoolTokens is ERC20 {
    uint256 public constant tokenPriceInitial = 100000000000 wei; // 0.0000001 ETH
    uint256 public constant tokenPriceIncremental = 10000000 wei; // 0.00000001 ETH
    uint256 public constant magnitude = 2 ** 64;
    uint256 public constant feePercent = 10;

    uint256 public totalDividends;
    uint256 public profitPerShare;

    struct BuyRecord {
        uint256 buyPrice;
        uint256 ethCost;
        uint256 tokenAmount;
        bool sold;
    }

    mapping(address => int256) public payoutsTo;
    mapping(address => uint256) public unclaimedDividends;
    mapping(address => uint256) public investedEth;
    mapping(address => uint256) public buyCount; // Active (unsold) buys
    mapping(address => uint256) public totalBuyCount; // Total buys ever made
    mapping(address => mapping(uint256 => BuyRecord)) public buyRecords;

    event TokensPurchased(
        address indexed buyer,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 buyPrice,
        uint256 buyNumber
    );
    event TokensSold(
        address indexed seller,
        uint256 buyId,
        uint256 tokenAmount,
        uint256 ethAmount
    );
    event DividendsWithdrawn(address indexed user, uint256 ethAmount);

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

    function calculateTokensForEth(
        uint256 ethAmount
    ) public view returns (uint256) {
        if (ethAmount == 0) return 0;

        uint256 fee = (ethAmount * feePercent) / 100;
        uint256 taxedEth = ethAmount - fee;

        uint256 S1 = totalSupply() / (10 ** decimals());
        uint256 a = tokenPriceIncremental / 2;
        uint256 b = tokenPriceInitial + (tokenPriceIncremental * S1);
        uint256 discriminant = b * b + 4 * a * taxedEth;
        uint256 tokens = (sqrt(discriminant) - b) / (2 * a);

        return tokens * (10 ** decimals());
    }

    function calculateEthForTokens(
        uint256 tokenAmount
    ) public view returns (uint256) {
        if (tokenAmount == 0) return 0;

        uint256 S2 = totalSupply() / (10 ** decimals());
        uint256 S1 = S2 - (tokenAmount / (10 ** decimals()));
        uint256 baseAmount = (tokenPriceInitial * (S2 - S1)) +
            (tokenPriceIncremental * (S2 * S2 - S1 * S1)) /
            2;
        uint256 fee = (baseAmount * feePercent) / 100;
        return baseAmount - fee;
    }

    function buy() public payable returns (uint256) {
        require(msg.value > 0, "Must send ETH to buy tokens");

        uint256 tokensToBuy = calculateTokensForEth(msg.value);
        require(tokensToBuy > 0, "Insufficient ETH for tokens");

        uint256 fee = (msg.value * feePercent) / 100;
        uint256 currentBuyPrice = buyPrice();

        totalBuyCount[msg.sender] += 1; // Unique, incrementing ID for every buy
        buyCount[msg.sender] += 1; // Track active buys
        uint256 currentBuyId = totalBuyCount[msg.sender];

        buyRecords[msg.sender][currentBuyId] = BuyRecord({
            buyPrice: currentBuyPrice,
            ethCost: msg.value,
            tokenAmount: tokensToBuy,
            sold: false
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
        require(
            _buyId > 0 && _buyId <= totalBuyCount[msg.sender],
            "Invalid buy ID"
        );
        BuyRecord storage record = buyRecords[msg.sender][_buyId];
        require(!record.sold, "Tokens from this buy already sold");
        require(
            balanceOf(msg.sender) >= record.tokenAmount,
            "Insufficient token balance"
        );

        uint256 _amountOfTokens = record.tokenAmount;
        uint256 ethAmount = calculateEthForTokens(_amountOfTokens);
        require(ethAmount > 0, "ETH amount too low");

        if (totalSupply() > 0) {
            uint256 userDividends = dividendsOf(msg.sender);
            unclaimedDividends[msg.sender] += userDividends;
            payoutsTo[msg.sender] += int256(userDividends * magnitude);

            uint256 fee = (ethAmount * feePercent) / 100;
            uint256 ethToSend = ethAmount;

            profitPerShare +=
                (fee * magnitude) /
                (totalSupply() / (10 ** decimals()));
            totalDividends += fee;

            record.sold = true;

            _burn(msg.sender, _amountOfTokens);
            require(
                address(this).balance >= ethToSend,
                "Insufficient contract balance"
            );
            (bool sent, ) = msg.sender.call{value: ethToSend}("");
            require(sent, "Failed to send ETH");

            emit TokensSold(msg.sender, _buyId, _amountOfTokens, ethToSend);
            return ethToSend;
        } else {
            record.sold = true;
            buyCount[msg.sender]--;
            _burn(msg.sender, _amountOfTokens);
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

        uint256 tokenValue = calculateEthForTokens(balanceOf(_user));
        uint256 totalValue = tokenValue + dividendsOf(_user);

        if (totalValue >= invested) {
            return (true, totalValue - invested);
        } else {
            return (false, invested - totalValue);
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

    function getUserTotalBuyCount(address _user) public view returns (uint256) {
        return totalBuyCount[_user];
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
            bool sold,
            int256 profitOrLoss
        )
    {
        require(_buyId > 0 && _buyId <= totalBuyCount[_user], "Invalid buy ID");
        BuyRecord memory record = buyRecords[_user][_buyId];

        int256 pl = 0;
        if (!record.sold) {
            uint256 currentValue = calculateEthForTokens(record.tokenAmount);
            pl = int256(currentValue) - int256(record.ethCost);
        }

        return (
            record.buyPrice,
            record.ethCost,
            record.tokenAmount,
            record.sold,
            pl
        );
    }

    // Helper function to get all active buy IDs for a user
    function getActiveBuyIds(
        address _user
    ) public view returns (uint256[] memory) {
        uint256 activeCount = buyCount[_user];
        uint256[] memory activeIds = new uint256[](activeCount);
        uint256 index = 0;

        for (
            uint256 i = 1;
            i <= totalBuyCount[_user] && index < activeCount;
            i++
        ) {
            if (!buyRecords[_user][i].sold) {
                activeIds[index] = i;
                index++;
            }
        }
        return activeIds;
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
