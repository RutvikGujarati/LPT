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
    mapping(address => uint256) public unclaimedDividends; // Tracks dividends
    mapping(address => uint256) public sellProceeds; // Tracks stuck ETH from sells
    mapping(address => uint256) public investedEth; // Total ETH invested
    mapping(address => uint256) public buyCount; // Total buys ever made
    mapping(address => mapping(uint256 => BuyRecord)) public buyRecords;
    mapping(address => uint256) public reinvestedEth;
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
    event Reinvested(
        address indexed user,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 buyNumber
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

        buyCount[msg.sender] += 1;
        uint256 currentBuyId = buyCount[msg.sender];

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
        require(_buyId > 0 && _buyId <= buyCount[msg.sender], "Invalid buy ID");
        BuyRecord storage record = buyRecords[msg.sender][_buyId];
        require(!record.sold, "Tokens from this buy already sold");
        require(
            balanceOf(msg.sender) >= record.tokenAmount,
            "Insufficient token balance"
        );

        uint256 _amountOfTokens = record.tokenAmount;
        uint256 ethAmount = calculateEthForTokens(_amountOfTokens);
        require(ethAmount > 0, "ETH amount too low");

        uint256 fee = (ethAmount * feePercent) / 100;
        uint256 ethToSend = ethAmount;

        if (totalSupply() > 0) {
            uint256 userDividends = dividendsOf(msg.sender);
            unclaimedDividends[msg.sender] += userDividends;
            payoutsTo[msg.sender] += int256(userDividends * magnitude);

            profitPerShare +=
                (fee * magnitude) /
                (totalSupply() / (10 ** decimals()));
            totalDividends += fee;

            record.sold = true;
            sellProceeds[msg.sender] += ethToSend;

            _burn(msg.sender, _amountOfTokens);

            emit TokensSold(msg.sender, _buyId, _amountOfTokens, ethToSend);
            return ethToSend;
        } else {
            record.sold = true;
            _burn(msg.sender, _amountOfTokens);
            return 0;
        }
    }

    function reinvest(uint256 stuckEth) public returns (uint256) {
        require(
            stuckEth <= sellProceeds[msg.sender],
            "Insufficient sell proceeds"
        );
        require(stuckEth > 0, "Amount must be greater than 0");

        uint256 tokensToBuy = calculateTokensForEth(stuckEth);
        require(tokensToBuy > 0, "Insufficient ETH for tokens");

        uint256 fee = (stuckEth * feePercent) / 100;
        uint256 currentBuyPrice = buyPrice();

        buyCount[msg.sender] += 1;
        uint256 currentBuyId = buyCount[msg.sender];

        buyRecords[msg.sender][currentBuyId] = BuyRecord({
            buyPrice: currentBuyPrice,
            ethCost: stuckEth,
            tokenAmount: tokensToBuy,
            sold: false
        });

        if (totalSupply() > 0) {
            profitPerShare +=
                (fee * magnitude) /
                (totalSupply() / (10 ** decimals()));
        }
        totalDividends += fee;
        reinvestedEth[msg.sender] += stuckEth;
        sellProceeds[msg.sender] -= stuckEth; // Subtract only the used amount

        _mint(msg.sender, tokensToBuy);

        emit Reinvested(msg.sender, stuckEth, tokensToBuy, currentBuyId);
        return tokensToBuy;
    }

    function dividendsOf(address _user) public view returns (uint256) {
        // Check contract balance first - if no ETH, return 0
        uint256 contractBalance = address(this).balance;
        if (contractBalance == 0) return 0;

        uint256 userBalance = balanceOf(_user);
        uint256 totalDividendsForUser;

        if (userBalance == 0) {
            totalDividendsForUser = unclaimedDividends[_user];
        } else {
            // Calculate theoretical dividends from shares
            uint256 totalPayout = (profitPerShare * userBalance) /
                (10 ** decimals());
            int256 adjustedPayout = int256(totalPayout) - payoutsTo[_user];
            uint256 dividendsFromShares = adjustedPayout > 0
                ? uint256(adjustedPayout) / magnitude
                : 0;
            totalDividendsForUser =
                dividendsFromShares +
                unclaimedDividends[_user];
        }

        // Cap at available contract balance or user's share, whichever is less
        return
            totalDividendsForUser > contractBalance
                ? contractBalance
                : totalDividendsForUser;
    }

    function withdraw(uint256 amount) public {
        uint256 totalWithdrawable = dividendsOf(msg.sender);
        require(totalWithdrawable > 0, "No ETH to withdraw");
        require(amount > 0, "Amount must be greater than 0");
        require(
            amount <= totalWithdrawable,
            "Amount exceeds withdrawable balance"
        );
        require(
            address(this).balance >= amount,
            "Insufficient contract balance"
        );

        uint256 dividends = unclaimedDividends[msg.sender];
        uint256 proceeds = sellProceeds[msg.sender];

        // Calculate dividends from shares
        uint256 userBalance = balanceOf(msg.sender);
        uint256 dividendsFromShares = 0;
        if (userBalance > 0) {
            uint256 totalPayout = (profitPerShare * userBalance) /
                (10 ** decimals());
            int256 adjustedPayout = int256(totalPayout) - payoutsTo[msg.sender];
            dividendsFromShares = adjustedPayout > 0
                ? uint256(adjustedPayout) / magnitude
                : 0;
        }

        // Theoretical total for proportional distribution
        uint256 theoreticalTotal = dividendsFromShares + dividends + proceeds;
        require(theoreticalTotal > 0, "No theoretical total to withdraw from");

        // Calculate reductions based on actual withdrawable amount
        uint256 dividendShare = 0;
        uint256 proceedsShare = 0;
        uint256 shareReduction = 0;

        if (dividends > 0) {
            dividendShare = (amount * dividends) / totalWithdrawable;
            unclaimedDividends[msg.sender] -= dividendShare;
        }

        if (proceeds > 0) {
            proceedsShare = (amount * proceeds) / totalWithdrawable;
            sellProceeds[msg.sender] -= proceedsShare;
        }

        if (dividendsFromShares > 0) {
            shareReduction = (amount * dividendsFromShares) / totalWithdrawable;
            payoutsTo[msg.sender] += int256(shareReduction * magnitude);
        }

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Failed to send ETH");

        emit DividendsWithdrawn(msg.sender, amount);
    }
    function getUserProfit(address _user) public view returns (int256) {
        uint256 initialInvested = investedEth[_user];
        uint256 reinvested = reinvestedEth[_user];

        if (initialInvested == 0 && reinvested == 0) return 0;

        uint256 tokenValue = calculateEthForTokens(balanceOf(_user));
        uint256 dividends = dividendsOf(_user);
        uint256 stuckEth = sellProceeds[_user];
        uint256 totalValue = tokenValue + dividends + stuckEth;

        if (initialInvested == 0) {
            return int256(totalValue);
        } else {
            return int256(totalValue) - int256(initialInvested);
        }
    }
    function getInvestedEth(address _user) public view returns (uint256) {
        return investedEth[_user];
    }

    function getStuckEth(address _user) public view returns (uint256) {
        return sellProceeds[_user]; // Only stuck ETH from sells
    }

    function isUserInProfit(address _user) public view returns (bool, uint256) {
        uint256 invested = investedEth[_user];
        if (invested == 0) return (false, 0);

        uint256 tokenValue = calculateEthForTokens(balanceOf(_user));
        uint256 totalValue = tokenValue +
            dividendsOf(_user) +
            sellProceeds[_user];

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

    function getActiveBuyCount(address _user) public view returns (uint256) {
        uint256 activeCount = 0;
        for (uint256 i = 1; i <= buyCount[_user]; i++) {
            if (!buyRecords[_user][i].sold) {
                activeCount++;
            }
        }
        return activeCount;
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
        require(_buyId > 0 && _buyId <= buyCount[_user], "Invalid buy ID");
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

    function getActiveBuyIds(
        address _user
    ) public view returns (uint256[] memory) {
        uint256 activeCount = getActiveBuyCount(_user);
        uint256[] memory activeIds = new uint256[](activeCount);
        uint256 index = 0;

        for (uint256 i = 1; i <= buyCount[_user]; i++) {
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
