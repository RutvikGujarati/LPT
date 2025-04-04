// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LiquidityPoolTokens is ERC20 {
    uint256 public constant tokenPriceInitial = 100000000000 wei; // 0.0000001 ETH
    uint256 public constant tokenPriceIncremental = 10000000 wei; // 0.00000001 ETH
    uint256 public constant magnitude = 2 ** 64;
    uint256 public constant feePercent = 10;
    uint256 public constant scalingFactor = 1000;
    uint256 public totalDividends;
    uint256 public profitPerShare;
    struct BuyRecord {
        uint256 buyPrice;
        uint256 ethCost;
        uint256 tokenAmount;
        bool sold;
    }

    mapping(address => int256) public payoutsTo;
    mapping(address => uint256) public unclaimedDividends; // Tracks withdrawable dividends
    mapping(address => uint256) public reinvestableFunds; // Tracks reinvestable ETH
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

        tokens = tokens / scalingFactor; // Scale down token issuance

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

        uint256 fee = (msg.value * feePercent) / 100; // 10% fee
        uint256 currentBuyPrice = buyPrice();

        buyCount[msg.sender] += 1;
        uint256 currentBuyId = buyCount[msg.sender];

        buyRecords[msg.sender][currentBuyId] = BuyRecord({
            buyPrice: currentBuyPrice,
            ethCost: msg.value,
            tokenAmount: tokensToBuy,
            sold: false
        });

        reinvestableFunds[msg.sender] += fee; // Track 10% fee per user
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

    // Updated sell function (unchanged from last version, included for clarity)
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
            profitPerShare +=
                (fee * magnitude) /
                (totalSupply() / (10 ** decimals()));
            totalDividends += fee;
            unclaimedDividends[msg.sender] += fee; // Fee from sell to dividends
            reinvestableFunds[msg.sender] += ethToSend; // Track sell proceeds as reinvestable

            record.sold = true;
            _burn(msg.sender, _amountOfTokens);

            emit TokensSold(msg.sender, _buyId, _amountOfTokens, ethToSend);
            return ethToSend;
        } else {
            record.sold = true;
            _burn(msg.sender, _amountOfTokens);
            return 0;
        }
    }

    function reinvest(uint256 amount) public returns (uint256) {
        require(
            amount <= reinvestableFunds[msg.sender],
            "Insufficient reinvestable funds"
        );
        require(amount > 0, "Amount must be greater than 0");

        uint256 tokensToBuy = calculateTokensForEth(amount);
        require(tokensToBuy > 0, "Insufficient ETH for tokens");

        uint256 fee = (amount * feePercent) / 100; // 10% fee on reinvestment
        uint256 currentBuyPrice = buyPrice();

        buyCount[msg.sender] += 1;
        uint256 currentBuyId = buyCount[msg.sender];

        buyRecords[msg.sender][currentBuyId] = BuyRecord({
            buyPrice: currentBuyPrice,
            ethCost: amount,
            tokenAmount: tokensToBuy,
            sold: false
        });

        if (totalSupply() > 0) {
            profitPerShare +=
                (fee * magnitude) /
                (totalSupply() / (10 ** decimals()));
        }
        totalDividends += fee;
        unclaimedDividends[msg.sender] += fee; // Fee from reinvest goes to dividends
        reinvestableFunds[msg.sender] -= amount; // Deduct used amount
        reinvestedEth[msg.sender] += amount;

        _mint(msg.sender, tokensToBuy);

        emit Reinvested(msg.sender, amount, tokensToBuy, currentBuyId);
        return tokensToBuy;
    }

    function withdraw(uint256 amount) public {
        uint256 withdrawable = unclaimedDividends[msg.sender];
        require(withdrawable > 0, "No ETH to withdraw");
        require(amount > 0, "Amount must be greater than 0");
        require(amount <= withdrawable, "Amount exceeds withdrawable balance");
        require(
            address(this).balance >= amount,
            "Insufficient contract balance"
        );

        unclaimedDividends[msg.sender] -= amount;

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "Failed to send ETH");

        emit DividendsWithdrawn(msg.sender, amount);
    }

    function dividendsOf(address _user) public view returns (uint256) {
        uint256 contractBalance = address(this).balance;
        if (contractBalance == 0) return 0;

        uint256 userDividends = unclaimedDividends[_user];
        return
            userDividends > contractBalance ? contractBalance : userDividends;
    }

    function reinvestableOf(address _user) public view returns (uint256) {
        uint256 contractBalance = address(this).balance;
        if (contractBalance == 0) return 0;

        uint256 userReinvestable = reinvestableFunds[_user];
        return
            userReinvestable > contractBalance
                ? contractBalance
                : userReinvestable;
    }

    function getUserProfit(address _user) public view returns (int256) {
        uint256 initialInvested = investedEth[_user];
        uint256 reinvested = reinvestedEth[_user];

        if (initialInvested == 0 && reinvested == 0) return 0;

        uint256 tokenValue = calculateEthForTokens(balanceOf(_user));
        uint256 dividends = dividendsOf(_user);
        uint256 reinvestable = reinvestableFunds[_user]; // Includes 10% buy fees + sell proceeds
        uint256 totalValue = tokenValue + dividends + reinvestable;

        // Debugging output (for testing, can be removed later)
        // console.log("Token Value: ", tokenValue);
        // console.log("Dividends: ", dividends);
        // console.log("Reinvestable: ", reinvestable);
        // console.log("Total Value: ", totalValue);
        // console.log("Initial Invested: ", initialInvested);

        if (initialInvested == 0) {
            return int256(totalValue);
        } else {
            return int256(totalValue) - int256(initialInvested);
        }
    }

    // Updated isUserInProfit function
    function isUserInProfit(address _user) public view returns (bool, uint256) {
        uint256 invested = investedEth[_user];
        if (invested == 0) return (false, 0);

        uint256 tokenValue = calculateEthForTokens(balanceOf(_user));
        uint256 totalValue = tokenValue +
            dividendsOf(_user) +
            reinvestableFunds[_user]; // Includes 10% buy fees + sell proceeds

        if (totalValue >= invested) {
            return (true, totalValue - invested);
        } else {
            return (false, invested - totalValue);
        }
    }

    function getInvestedEth(address _user) public view returns (uint256) {
        return investedEth[_user];
    }

    function getReinvestableFunds(address _user) public view returns (uint256) {
        return reinvestableFunds[_user];
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
            uint256 fee = (record.ethCost * feePercent) / 100; // 10% fee from this buy
            pl = int256(currentValue + fee) - int256(record.ethCost); // Include fee as part of value
        } else {
            // For sold tokens, calculate profit based on reinvestable funds from that sale
            uint256 totalUserTokens = balanceOf(_user) + record.tokenAmount; // Include sold tokens
            uint256 sellValue = (reinvestableFunds[_user] *
                record.tokenAmount) / totalUserTokens; // Proportional value
            pl = int256(sellValue) - int256(record.ethCost);
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
