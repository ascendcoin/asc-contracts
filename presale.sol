// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./interfaces/uniswap-factory.sol";
import "./interfaces/uniswap-v2.sol";
import "./interfaces/token-timelock.sol";

import "./libs/ownable.sol";
import "./libs/erc20.sol";
import "./libs/safe-math.sol";
import "./libs/reentrancy-guard.sol";

contract AscendPresale is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // the token being sold
    IERC20 public token;

    // the addresses where collected funds are sent
    address public treasury;

    // timelock contract
    address public timelock;

    // presale duration
    uint256 public start;
    uint256 public duration = 7 days;
    uint256 public grace = 14 days;

    // token max cap
    uint256 public cap = 400000 * 10**9; // 400.000 ASC

    // presale threshold to close
    uint256 public threshold = 75; // 75 % of token cap

    // total to be distributed
    uint256 public total;

    // total wei deposited
    uint256 public deposited;

    // total number of depositors
    uint256 public depositors;

    // limits for investment
    uint256 public min = 50000000000000000; // 0.05 ETH
    uint256 public max = 25000000000000000000; // 25 ETH

    // token exchange rate for base amount (1 ETH = 1320 ASC)
    uint256 public rate = 1320 * 10**9;

    // public contact information
    string public contact;

    // is the distribution finished
    bool public completed = false;

    // is the presale cancelled
    bool public cancelled = false;

    // is the presale closed
    bool public closed = false;

    // mappings for deposited, claimable
    mapping(address => uint256) public deposits;
    mapping(address => uint256) public balances;

    IUniswapV2Router02 internal quickswap = IUniswapV2Router02(0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff);
    IUniswapV2Factory internal factory = IUniswapV2Factory(0x5757371414417b8C6CAad45bAeF941aBc7d3Ab32);

    address internal weth = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619;
    address internal dead = 0x000000000000000000000000000000000000dEaD;

    /**
    * event for presale enter logging
    * @param account who will receive the tokens
    * @param value weis entered into presale
    * @param amount amount of tokens to be distributed
    */ 
    event PresaleEntered(address indexed account, uint256 value, uint256 amount);

    /**
    * event for claim of tokens
    * @param recipient that received the tokens
    * @param amount amount of tokens received
    */ 
    event Claimed(address indexed recipient, uint256 amount);

    /**
    * event for refund of wei
    * @param recipient that received the wei
    * @param amount amount of wei received
    */ 
    event Refunded(address indexed recipient, uint256 amount);

    /**
    * event for signaling liquidity creation & lock
    * @param amount amount of lp tokens created
    * @param timelock address of timelock contract
    */
    event LiquidityAddedAndLocked(uint256 amount, address timelock);

    /**
    * event for signaling salvaged non-token assets
    * @param token salvaged token address
    * @param amount amount of tokens salvaged
    */
    event Salvaged(address token, uint256 amount);

    /**
    * event for signaling dist collection of wei
    * @param recipient address that received the wei
    * @param amount amount of wei collected
    */
    event DustCollected(address recipient, uint256 amount);

    /**
    * event for signaling destruction of leftover tokens
    * @param amount amount of tokens burned
    */
    event Destroyed(uint256 amount);

    /**
    * event for signaling presale completion
    */
    event Completed();

    // CONSTRUCTOR

    constructor(
        address _token,
        address _timelock,
        uint256 _start,
        string memory _contact
    ) public {
        require(_start >= block.timestamp);
        
        token = IERC20(_token);
        timelock = _timelock;
        start = _start;
        contact = _contact;

        treasury = address(0x2D924EE1652995fFA9A2DA02666A940CecaDB820);
    }

    /**
    * Low level presale enter function
    * @param _amount the wei amount
    */
    function enter(uint256 _amount) public active nonReentrant {
        require(msg.sender != address(0));
        require(IERC20(weth).balanceOf(msg.sender) >= _amount, '!balance');
        require(valid(msg.sender, _amount), '!valid');

        uint256 amount;
        uint256 acquired;

        // calculate base tokens
        acquired = _amount.mul(rate).div(1e18);
        require(distributable(amount), "!distribution");

        deposits[msg.sender] = deposits[msg.sender].add(_amount);
        balances[msg.sender] = balances[msg.sender].add(acquired);
        emit PresaleEntered(msg.sender, _amount, acquired);

        deposited = deposited.add(_amount);
        depositors = depositors.add(1);
        total = total.add(acquired);
        IERC20(weth).safeTransferFrom(msg.sender, address(this), _amount);
    }

    /**
    * Refund collected eth from user if presale is cancelled
    */
    function refund() external nonReentrant {
        require(cancelled, "presale is not cancelled");
        require(deposits[msg.sender] > 0, "you have not deposited anything");

        // return collected ether
        uint256 amount = deposits[msg.sender];

        total = total.sub(balances[msg.sender]);
        deposited = deposited.sub(amount);
        deposits[msg.sender] = 0;
        balances[msg.sender] = 0;
        
        IERC20(weth).safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }

    /**
    * Claim tokens after presale is distributed
    */
    function claim() external distributed nonReentrant {
        require(balances[msg.sender]> 0, "you can not claim any tokens");

        // send claimable token to user
        uint256 amount = balances[msg.sender];
        balances[msg.sender] = 0;

        token.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /**
    * Distribute wei, create liquidity pair and start rewards after presale end
    */
    function distribute() external {
        require(concluded(), "presale is not concluded");
        require(IERC20(weth).balanceOf(address(this)) >= deposited, "!balance >= deposited");
        
        if (deposited > 0) {
            // calculate distribution amounts
            uint256 _liquidity = deposited.mul(65).div(100); // 65 % to liquidity
            uint256 _treasury = deposited
                .sub(_liquidity); // 35 % to treasury

            // calculate token quickswap liquidity amount
            uint256 _quickswap = _liquidity.mul(rate).div(1e18);

            // create quickswap pair
            token.safeApprove(address(quickswap), _quickswap);
            IERC20(weth).safeApprove(address(quickswap), _liquidity);
            ( , , uint256 added) = quickswap.addLiquidity(address(token), weth, _quickswap, _liquidity, 0, 0, address(timelock), block.timestamp + 5 minutes);
            emit LiquidityAddedAndLocked(added, timelock);

            // get uniswap pair address
            address pair = factory.getPair(address(token), weth);

            // set token in timelock contract
            ITokenTimelock(timelock).set_token(pair);

            // transfer wei to addresses
            IERC20(weth).safeTransfer(treasury, _treasury);
        }

        // signal distribution complete
        completed = true;
        emit Completed();
    }

    /**
    * Salvage unrelated tokens to presale
    * @param _token address of token to salvage
    */
    function salvage(address _token) external distributed onlyOwner {
        require(_token != address(token) &&
            _token != address(weth), "can not salvage token or weth");

        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(_token).safeTransfer(treasury, balance);
            emit Salvaged(_token, balance);
        }
    }

    /**
    * Collect wei left as dust on contract after grace period
    */
    function collect_dust() external distributed onlyOwner {
        require(!cancelled);
        require(block.timestamp >= start.add(grace), "grace period not over");

        uint256 balance = IERC20(weth).balanceOf(address(this));
        if (balance > 0) {
            IERC20(weth).safeTransfer(treasury, balance);
            emit DustCollected(treasury, balance);
        }
    }

    /**
    * Destroy (burn) leftover tokens from presale
    */
    function destroy() external distributed onlyOwner {
        require(!cancelled);
        require(block.timestamp >= start.add(grace), "grace period not over");

        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.safeTransfer(dead, balance);
            emit Destroyed(balance);
        }
    }

    // *** RESTRICTED ***

    /**
    * Update contact information on the contract
    * @param _contact text to set as contact information
    */
    function update(string memory _contact) external onlyOwner {
        contact = _contact;
    }

    /**
    * Cancel presale, stop accepting wei and enable refunds
    */
    function cancel() external onlyOwner {
        require(!completed, "distributed");
        cancelled = true;
    }

    /**
    * Close presale if threshold is reached
    */
    function close() external onlyOwner {
        require(reached(), "threshold is not reached");

        closed = true;
    }

    // *** VIEWS **** //

    /**
    * Returns claimable amount for address
    */
    function claimable() external view returns (uint256 amount) {
        if (!cancelled) {
            amount = balances[msg.sender];
        }
    }

    /**
    * Check if wei amount is within limits
    */
    function valid(address account, uint256 amount) internal view returns (bool) {
        bool above = deposits[account].add(amount) >= min;
        bool below = deposits[account].add(amount) <= max;

        return (above && below);
    }

    /**
    * Check if token amount can be distributed
    */
    function distributable(uint256 amount) internal view returns (bool) {
        bool below = total.add(amount) <= cap;

        return (below);
    }

    /**
    * Check if presale if concluded
    */
    function concluded() internal view returns (bool) {
        if (closed) {
            return true;
        }

        if (block.timestamp > start.add(duration) && !cancelled) {
            return true;
        }

        return false;
    }

    /**
    * Check if threshold is reached
    */
    function reached() internal view returns (bool) {
        bool above = total.mul(100).div(cap) >= threshold;

        return (above);
    }

    // *** MODIFIERS **** //

    modifier distributed {
        require(
            completed,
            "tokens were not distributed yet"
        );

        _;
    }

    modifier active {
        require(
            block.timestamp >= start,
            "presale has not started yet"
        );

        require(
            block.timestamp <= start.add(duration),
            "presale has concluded"
        );

        require(
            !cancelled,
            "presale was cancelled"
        );

        require(
            !closed,
            "presale was closed"
        );

        _;
    }
}