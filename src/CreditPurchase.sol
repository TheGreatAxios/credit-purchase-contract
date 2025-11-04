// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InsufficientFunds();
error InvalidCreditToken();

contract CreditPurchase is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address => uint256) public paymentAmounts; // Use this directly without multiplying by NUMBER_OF_CREDITS

    uint256 public constant NUMBER_OF_CREDITS = 20_000e18;
    address public paymentReceiver;

    event CreditPriceSet(address indexed creditToken, uint256 price);
    event CreditsBought(address indexed creditToken, uint256 amount, uint256 price);

    constructor(address _owner, address _paymentReceiver) Ownable(_owner) {
        paymentReceiver = _paymentReceiver;
    }

    function setCreditPrice(address _creditToken, uint256 _price) external onlyOwner {
        paymentAmounts[_creditToken] = _price;
        emit CreditPriceSet(_creditToken, _price);
    }

    function purchaseCreditsWithEth() external payable nonReentrant whenNotPaused {
        uint256 price = paymentAmounts[address(0)];
        if (msg.value < price) {
            revert InsufficientFunds();
        }
        payable(paymentReceiver).transfer(price);
        emit CreditsBought(address(0), NUMBER_OF_CREDITS, price);
    }

    function purchaseCreditsWithERC20(address creditToken) external nonReentrant whenNotPaused {
        if (creditToken == address(0)) {
            revert InvalidCreditToken();
        }
        uint256 price = paymentAmounts[creditToken];
        IERC20(creditToken).safeTransferFrom(msg.sender, paymentReceiver, price);
        emit CreditsBought(creditToken, NUMBER_OF_CREDITS, price);
    }
}

